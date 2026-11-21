import Foundation
import AppKit
import CoreServices
import Darwin

public struct IndexProgress: Sendable {
    public var phase: String
    public var detail: String
    public var processed: Int
    public var busy: Bool
    public init(phase: String = "准备就绪", detail: String = "", processed: Int = 0, busy: Bool = false) { self.phase=phase; self.detail=detail; self.processed=processed; self.busy=busy }
}
public struct IndexingPreferences: Codable, Equatable, Sendable {
    public var images = true
    public var documents = true
    public var externalImages = true
    public var externalDocuments = true
    public var retainOffline = true
    public var includeHidden = true
    public var excludeDevelopmentCaches = false
    public var autoAddExternal = true
    public var ignoredExternalVolumes: [String] = []
    public init() {}
}

public final class IndexService: @unchecked Sendable {
    public let database: SearchDatabase
    public var onProgress: ((IndexProgress) -> Void)?
    public var onChange: (() -> Void)?
    public var onIndexChange: ((IndexChange) -> Void)?
    public var onContentChange: (() -> Void)?
    private let lock = NSLock()
    private let work = DispatchQueue(label: "local.miji.index", qos: .utility)
    private let control = DispatchQueue(label: "local.miji.control", qos: .utility)
    private var running = false
    private var requested = false
    private var fullRequested = false
    private var userActive = false
    private var sleeping = false
    private var lastSavedState: IncrementalIndexState
    private var state: IncrementalIndexState
    private let stateURL: URL
    private let watchEvents: Bool
    private var watchedPaths: [String] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var paused = false
    private var stopped = false
    private var mutations = 0
    private var preferences = IndexingPreferences()
    private var watcher: FileWatcher?
    // Only used on work; suspended sessions retain their directory iterator.
    private var scanSessions: [String:FileScanSession] = [:]
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private let ignoredPaths: [String]
    private var nextScanAfter = Date.distantPast
    private let rescanInterval: TimeInterval = 10
    private let extractor: (URL, @escaping () -> Bool) throws -> ExtractedContent
    // Accessed only by the single heavy worker.
    private let extractionReuse: ExtractionReuse?
    private static let heavyDocumentExtensions = ["pdf","pages","numbers","key","keynote","rtfd","doc","ppt","xls","docx","pptx","xlsx","epub"]
    static let heavyDocumentExtensionsSQL = heavyDocumentExtensions.map { "'" + $0 + "'" }.joined(separator:",")
    private static func isHeavy(_ file: FileRecord) -> Bool {
        file.kind == .image || Self.heavyDocumentExtensions.contains(file.fileExtension)
    }
    private enum ContentLane: CaseIterable { case light, heavy }
    private struct ContentPath: Hashable {
        var rootID: String
        var path: String
    }
    private struct FreshContent {
        var first: TimeInterval
        var ready: TimeInterval
    }
    private struct ContentClaim {
        var key: ContentPath
        var root: IndexedRoot
        var file: FileRecord
        var epoch: UInt64
    }
    private enum ExtractionResult {
        case done(Data), failed(String), changed, interrupted
    }
    private let lightWorker = DispatchQueue(label:"local.miji.index.light-content", qos:.utility)
    private let heavyWorker = DispatchQueue(label:"local.miji.index.heavy-content", qos:.utility)
    // The writer queue owns these claims. The lock protects only epoch and
    // lifecycle flags consulted by the workers, and the durable event inbox.
    private var claims: [ContentLane:ContentClaim] = [:]
    private var contentEpoch: UInt64 = 0
    private var freshContent: [ContentPath:FreshContent] = [:]
    private var freshRuns: [ContentLane:Int] = [:]
    private var contentCursors: [ContentLane:Int] = [:]
    private var contentWake: DispatchWorkItem?
    private var contentWakeDeadline: TimeInterval?
    private var emptyContentLanes = Set<ContentLane>()
    private var scanRootCursor = 0
    private var rootsNeedRefresh = true
    private var currentRoots: [IndexedRoot] = []
    private var idlePublished = false
    private var scanCheckpointWrite: TimeInterval = 0
    private var delayedFullScan: DispatchWorkItem?
    private let currentEventID: () -> UInt64
    private let probeRoot: (IndexedRoot) -> IndexedRoot
    private let detectClockReset: Bool
    public convenience init(database: SearchDatabase, ignoredPaths: [String] = [], extractionWorker: URL? = nil) {
        self.init(database:database,ignoredPaths:ignoredPaths,extractor: { url,cancelled in
            let ext=url.pathExtension.lowercased()
            if let extractionWorker, FileKind.classify(extension:ext) == .image || ["pdf","pages","numbers","key","keynote"].contains(ext) {
                return try IsolatedContentExtractor.extract(url:url,executable:extractionWorker,cancelled:cancelled)
            }
            return try ContentExtractor.extract(url:url,cancelled:cancelled)
        }, reuseHeavyInputs: ProcessInfo.processInfo.environment["MIJI_DISABLE_EXTRACTION_REUSE"] != "1")
    }
    init(database: SearchDatabase, ignoredPaths: [String] = [], extractor: @escaping (URL, @escaping () -> Bool) throws -> ExtractedContent,
         watchEvents: Bool = true, stateURL: URL? = nil, reuseHeavyInputs: Bool = false,
         currentEventID: (() -> UInt64)? = nil,
         probeRoot: @escaping (IndexedRoot) -> IndexedRoot = VolumeIdentity.refreshed) {
        self.database = database
        let inboxURL=stateURL ?? database.url.appendingPathExtension("incremental.json")
        self.stateURL=inboxURL
        let saved=IncrementalIndexState.read(inboxURL)
        self.state=saved
        self.lastSavedState=saved
        for (id,root) in self.state.roots where root.scan == nil {
            // Older versions have no saved traversal cursor. They start a new
            // scan, so overlapping legacy queues can safely be combined once.
            self.state.roots[id]?.pending=IndexRelativePath.compacting(root.pending + root.inFlight)
            self.state.roots[id]?.inFlight=[]
        }
        self.watchEvents=watchEvents
        self.ignoredPaths = ignoredPaths + [inboxURL.path,inboxURL.appendingPathExtension("tmp").path]
        self.extractor = extractor
        extractionReuse = reuseHeavyInputs ? ExtractionReuse() : nil
        self.currentEventID = currentEventID ?? { FSEventsGetCurrentEventId() }
        self.probeRoot = probeRoot
        self.detectClockReset = watchEvents || currentEventID != nil
    }
    private func locked<T>(_ block: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try block() }
    public func configure(_ preferences: IndexingPreferences) {
        let rescan=locked { () -> Bool in
            let changed=self.preferences.includeHidden != preferences.includeHidden || self.preferences.excludeDevelopmentCaches != preferences.excludeDevelopmentCaches
            if self.preferences != preferences { contentEpoch &+= 1 }
            self.preferences=preferences
            rootsNeedRefresh=true
            return changed
        }
        if rescan { requestScan() } else { wakeWork() }
    }
    public func start() {
        control.async { [weak self] in
            guard let self, self.timer == nil, !self.locked({self.stopped}) else { return }
            let timer=DispatchSource.makeTimerSource(queue:self.control)
            timer.schedule(deadline:.now()+30,repeating:30)
            // Probe mount/root changes and continue pending extraction. This
            // heartbeat never requests a periodic whole-root enumeration.
            timer.setEventHandler { [weak self] in self?.requestIncrementalUpdate() }
            self.timer=timer;timer.resume()
            let center=NSWorkspace.shared.notificationCenter
            self.workspaceObservers=[
                center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:nil) { [weak self] _ in self?.setSystemSleeping(true) },
                center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:nil) { [weak self] _ in self?.setSystemSleeping(false) },
                center.addObserver(forName:NSWorkspace.didMountNotification,object:nil,queue:nil) { [weak self] _ in self?.requestIncrementalUpdate() },
                center.addObserver(forName:NSWorkspace.didUnmountNotification,object:nil,queue:nil) { [weak self] _ in self?.requestIncrementalUpdate() }
            ]
        }
        wakeWork()
    }
    public func stop() {
        locked { stopped=true;contentEpoch &+= 1 }
        control.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel();self.timer=nil;self.watcher=nil;self.debounce?.cancel();self.debounce=nil
            for observer in self.workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            self.workspaceObservers=[]
        }
    }
    public func setPaused(_ value: Bool) {
        locked { if value && !paused { contentEpoch &+= 1 }; paused=value }
        if value { emit("已暂停","搜索现有索引仍然可用") } else { wakeWork() }
    }
    /// Finish the current valid extraction, then yield metadata and content work
    /// while the user is typing. No completed result is discarded to yield.
    public func setUserActive(_ value: Bool) { locked { userActive=value }; if !value { wakeWork() } }
    func setSystemSleeping(_ value: Bool) { locked { if value && !sleeping { contentEpoch &+= 1 }; sleeping=value }; if !value { requestIncrementalUpdate() } }
    /// Explicit refresh remains a full reconciliation, with storm coalescing.
    public func requestScan() { locked { fullRequested=true;rootsNeedRefresh=true }; wakeWork() }
    public func requestIncrementalUpdate() { locked { rootsNeedRefresh=true };wakeWork() }
    private func wakeWork() {
        let start=locked { () -> Bool in
            requested=true
            guard !running, !stopped, !paused, !sleeping, !userActive, mutations == 0 else { return false }
            running=true
            return true
        }
        if start { work.async { [weak self] in autoreleasepool { self?.run() } } }
    }
    public func mutate(_ action: @escaping (SearchDatabase) throws -> Void, completion: @escaping (Error?) -> Void = {_ in}) {
        locked { mutations += 1;contentEpoch &+= 1;rootsNeedRefresh=true }
        work.async { [weak self] in
            guard let self else { return }
            var failure:Error?
            let changesBefore=self.database.dataChangeCount()
            do {
                let before=try self.database.roots()
                try action(self.database)
                let after=try self.database.roots()
                // A disabled root has no active watcher. Re-enabling it must
                // reconcile changes made while it was outside the stream.
                for root in after where root.enabled && before.contains(where:{$0.id == root.id && !$0.enabled}) {
                    try self.locked { self.state.enqueue([""],rootID:root.id);try self.persistState() }
                }
                for id in Set(before.map(\.id) + after.map(\.id)) where before.first(where:{$0.id == id}) != after.first(where:{$0.id == id}) {
                    self.onIndexChange?(IndexChange(rootID:id,relativePaths:[""],fullRescan:true))
                }
            } catch { failure=error }
            self.locked { self.mutations -= 1 }
            completion(failure)
            if self.database.dataChangeCount() != changesBefore {self.onContentChange?()}
            self.onChange?()
            self.wakeWork()
        }
    }
    private var interrupted: Bool { locked { stopped || paused || sleeping || mutations > 0 } }
    private var yielding: Bool { interrupted || locked { userActive } }
    private func emit(_ phase: String, _ detail: String = "", count: Int = 0, busy: Bool = false) { onProgress?(IndexProgress(phase:phase,detail:detail,processed:count,busy:busy)) }
    private func persistState() throws {
        guard state != lastSavedState else {return}
        try state.write(stateURL)
        lastSavedState=state
    }

    /// Called by the watcher, and exposed internally for deterministic fixtures.
    /// Event IDs are checkpointed only together with their durable dirty scopes.
    func receiveEvents(_ events: [FileChangeEvent]) {
        do {
            try locked {
                let filter=IndexPathFilter(ignoredPaths:ignoredPaths)
                // FSEvents may coalesce/reorder IDs within one callback. Test
                // against the checkpoint from before this batch, not an ID
                // advanced by another path in the same callback.
                let cursors=state.roots.mapValues(\.cursor)
                var scopes:[String:[String]]=[:]
                for event in events {
                    for (id,checkpoint) in state.roots {
                        if event.id > 0 && event.id <= (cursors[id] ?? 0) && !event.requiresFullScan { continue }
                        if event.requiresFullScan {
                            // A dropped stream may not identify the affected
                            // subtree. Conservatively reconcile all stream roots.
                            scopes[id,default:[]].append("")
                        } else if !event.historyDone, !filter.ignores(event.path),
                                  let relative=IndexRelativePath.from(event.path,root:checkpoint.path) {
                            scopes[id,default:[]].append(IndexRelativePath.packageScope(relative))
                        }
                        // RootChanged can carry ID 0; never move a cursor back.
                        state.roots[id]?.cursor=max(checkpoint.cursor,event.id)
                    }
                }
                for (id,paths) in scopes {state.enqueue(paths,rootID:id)}
                try persistState()
            }
        } catch { emit("增量状态无法保存",error.localizedDescription);return }
        control.async { [weak self] in
            guard let self, self.debounce == nil, !self.locked({self.stopped}) else { return }
            let item=DispatchWorkItem { [weak self] in
                guard let self else { return };self.debounce=nil;self.wakeWork()
            }
            self.debounce=item;self.control.asyncAfter(deadline:.now()+0.2,execute:item)
        }
    }
    private func updateWatchers(_ roots: [IndexedRoot]) {
        guard watchEvents else { return }
        let paths=roots.filter { $0.enabled && $0.isOnline }.map(\.path).sorted()
        let since=locked { state.roots.values.map(\.cursor).min() ?? FSEventsGetCurrentEventId() }
        control.async { [weak self] in
            guard let self, !self.locked({self.stopped}), self.watchedPaths != paths || (self.watcher == nil && !paths.isEmpty) else { return }
            self.watchedPaths=paths
            self.watcher=FileWatcher(paths:paths,ignoredPaths:self.ignoredPaths,since:since,events:{ [weak self] in self?.receiveEvents($0) })
            if !paths.isEmpty && self.watcher?.isWatching != true {
                self.receiveEvents(paths.map { FileChangeEvent(path:$0,flags:UInt32(kFSEventStreamEventFlagUserDropped)) })
            }
        }
    }
    private func refreshRoots(preferences prefs: IndexingPreferences) throws -> [IndexedRoot] {
        var roots=try database.roots()
        if prefs.autoAddExternal {
            for url in VolumeIdentity.externalVolumes() {
                if let candidate=try? VolumeIdentity.root(for:url),
                   !prefs.ignoredExternalVolumes.contains(candidate.volumeUUID ?? candidate.path),
                   !roots.contains(where:{$0.volumeUUID == candidate.volumeUUID && $0.isExternal}) {
                    try database.saveRoot(candidate);roots.append(candidate)
                }
            }
        }
        let oldRoots=Dictionary(uniqueKeysWithValues:roots.map { ($0.id,$0) })
        let ids=Set(roots.map(\.id))
        scanSessions=scanSessions.filter {ids.contains($0.key)}
        locked {
            state.roots=state.roots.filter { ids.contains($0.key) }
        }
        for index in roots.indices {
            roots[index]=probeRoot(roots[index])
            let root=roots[index]
            let existing=oldRoots[root.id]
            try database.saveRoot(root)
            let changed=locked { () -> Bool in
                // Sample the event clock under the same lock as receiveEvents.
                // A cursor advanced during mount probing is not a clock reset.
                let currentID=currentEventID()
                if let old=state.roots[root.id] {
                    if old.path != root.path || (detectClockReset && old.cursor > currentID) ||
                        (existing?.isOnline == false && root.isOnline) {
                        state.roots[root.id] = .init(path:root.path,cursor:currentID,pending:[""])
                        return true
                    }
                    if root.isOnline, root.enabled, let paths=old.deferredRetry {
                        state.roots[root.id]?.deferredRetry=nil
                        state.enqueue(paths,rootID:root.id)
                    }
                    return existing?.isOnline != root.isOnline
                }
                state.roots[root.id] = .init(path:root.path,cursor:currentID,pending:[""])
                return true
            }
            if changed {
                scanSessions.removeValue(forKey:root.id)
                onIndexChange?(IndexChange(rootID:root.id,relativePaths:[""],fullRescan:true))
                onChange?()
            }
        }
        try locked { try persistState() }
        updateWatchers(roots)
        return roots
    }

    private func processFullRequest() throws {
        guard locked({ fullRequested }) else { return }
        let delay=nextScanAfter.timeIntervalSinceNow
        if delay > 0 {
            guard delayedFullScan == nil else {return}
            let item=DispatchWorkItem { [weak self] in
                self?.delayedFullScan=nil
                self?.requestIncrementalUpdate()
            }
            delayedFullScan=item
            work.asyncAfter(deadline:.now()+delay,execute:item)
            return
        }
        delayedFullScan?.cancel()
        delayedFullScan=nil
        try locked {
            fullRequested=false
            for root in currentRoots {
                // An existing full traversal already reconciles the root.
                if state.roots[root.id]?.inFlight.first != "" {
                    state.enqueue([""],rootID:root.id)
                }
            }
            try persistState()
        }
    }

    private func options(_ preferences: IndexingPreferences) -> ScanOptions {
        ScanOptions(includeHidden:preferences.includeHidden,excludeDevelopmentCaches:preferences.excludeDevelopmentCaches)
    }

    private func exactScope(_ path: String, root: IndexedRoot) -> Bool {
        var info=stat()
        let absolute=URL(fileURLWithPath:root.path).appendingPathComponent(path).path
        if lstat(absolute,&info) == 0 {return info.st_mode & S_IFMT != S_IFDIR}
        return errno == ENOENT || errno == ENOTDIR
    }

    private func scanSlice(root: IndexedRoot, preferences: IndexingPreferences) throws -> Bool {
        guard let scope=try locked({ () throws -> String? in
            guard var inbox=state.roots[root.id] else {return nil}
            if inbox.inFlight.isEmpty, !inbox.pending.isEmpty {
                inbox.inFlight=inbox.pending
                inbox.pending=[]
                state.roots[root.id]=inbox
                try persistState()
            }
            return inbox.inFlight.first
        }) else {return false}

        let online=probeRoot(root)
        guard online.isOnline, online.path == root.path else {
            locked { rootsNeedRefresh=true;requested=true }
            return false
        }
        let opts=options(preferences)
        let saved=locked {state.roots[root.id]?.scan}
        let scanner=FileScanner(database:database,ignoredPaths:ignoredPaths)
        let session:FileScanSession
        if let live=scanSessions[root.id], !live.finished,
           live.checkpoint.rootPath == root.path, live.checkpoint.scope == scope,
           live.checkpoint.options == opts {session=live}
        else {
            guard let current=try database.indexedRoot(id:root.id) else {return false}
            session=try scanner.session(root:current,relativePath:scope,options:opts,checkpoint:saved)
            scanSessions[root.id]=session
        }

        // Keep one durable primary scan. A few exact paths can jump ahead of
        // it each turn. Broad subtree work uses a primary session of its own.
        if scope.isEmpty && session.checkpoint.started {
            for _ in 0..<4 {
                guard !yielding else {return true}
                guard try scanInterleaved(root:root,scanner:scanner,primary:session,options:opts) else {break}
            }
        }
        let stopAt=ProcessInfo.processInfo.systemUptime + 0.05
        try advance(session,root:root,scope:scope,deadline:stopAt,saveCheckpoint:true)
        if session.finished { scanSessions.removeValue(forKey:root.id) }
        return true
    }

    private func scanInterleaved(root: IndexedRoot, scanner: FileScanner, primary: FileScanSession, options: ScanOptions) throws -> Bool {
        guard let snapshot=locked({state.roots[root.id]}) else {return false}
        let candidate=snapshot.interleaved ?? snapshot.pending.prefix(16).first(where:{ !$0.isEmpty && exactScope($0,root:root) })
        guard let scope=candidate, !scope.isEmpty else {return false}
        let exact=exactScope(scope,root:root)
        let claimed=try locked { () throws -> Bool in
            guard var inbox=state.roots[root.id], inbox.interleaved == scope || inbox.pending.contains(scope) else {return false}
            if !exact {
                // It became a directory. Keep it queued for a sliced traversal.
                inbox.interleaved=nil
                inbox.pending=IndexRelativePath.compacting(inbox.pending + [scope])
            } else {
                if inbox.interleaved == nil { inbox.pending.removeAll { $0 == scope } }
                inbox.interleaved=scope
                primary.preserveReconciledScope(scope)
                inbox.scan=primary.checkpoint
            }
            state.roots[root.id]=inbox
            try persistState()
            return exact
        }
        guard claimed else {return false}
        guard let current=try database.indexedRoot(id:root.id) else {return false}
        let local=try scanner.session(root:current,relativePath:scope,options:options)
        try advance(local,root:root,scope:scope,
                    deadline:ProcessInfo.processInfo.systemUptime + 0.05,saveCheckpoint:false)
        if !local.finished, !yielding {
            // If the exact entry was replaced with a directory during stat,
            // restart it later as an ordinary resumable subtree.
            try locked {
                guard var inbox=state.roots[root.id] else {return}
                inbox.interleaved=nil
                inbox.pending=IndexRelativePath.compacting(inbox.pending + [scope])
                state.roots[root.id]=inbox
                try persistState()
            }
        }
        return local.finished
    }

    private func advance(_ session: FileScanSession, root: IndexedRoot, scope: String, deadline: TimeInterval, saveCheckpoint: Bool) throws {
        var revision=try database.catalogRevision()
        let originalRevision=revision
        var eligibility=session.contentEligibilityRevision
        func notify() {
            if session.contentEligibilityRevision != eligibility {
                eligibility=session.contentEligibilityRevision
                emptyContentLanes.removeAll()
                onContentChange?()
                onChange?()
            }
            if let current=try? database.catalogRevision(), current != revision {
                revision=current
                emptyContentLanes.removeAll()
                onIndexChange?(IndexChange(rootID:root.id,relativePaths:[scope],fullRescan:false))
                onChange?()
            }
        }
        let phase=scope.isEmpty ? "正在建立文件目录" : "正在更新文件目录"
        let detail=scope.isEmpty ? root.name : scope
        if !session.checkpoint.started {emit(phase,detail,busy:true)}
        let result=try session.advance(cancelled:{self.yielding},
            shouldYield:{ProcessInfo.processInfo.systemUptime >= deadline},maximumItems:300) { count in
            notify()
            self.emit(phase,detail,count:count,busy:true)
        }
        notify()
        let now=ProcessInfo.processInfo.systemUptime
        if session.finished || yielding || now - scanCheckpointWrite >= 1 {
            try locked {
                guard var inbox=state.roots[root.id] else {return}
                if saveCheckpoint { inbox.scan=session.finished ? nil : session.checkpoint }
                if session.finished {
                    if saveCheckpoint {inbox.inFlight.removeAll { $0 == scope }}
                    else {inbox.interleaved=nil}
                    // Preserve failures for the next root probe or heartbeat.
                    // Immediate retries would spin on inaccessible directories.
                    if !result.preservingPaths.isEmpty {
                        inbox.deferredRetry=IndexRelativePath.compacting((inbox.deferredRetry ?? []) + result.preservingPaths)
                    }
                }
                state.roots[root.id]=inbox
                try persistState()
                scanCheckpointWrite=now
            }
        }
        if session.finished && scope.isEmpty {
            nextScanAfter=Date().addingTimeInterval(rescanInterval)
            if originalRevision != revision {
                onIndexChange?(IndexChange(rootID:root.id,relativePaths:[scope],fullRescan:true))
            }
        }
        if session.finished && !scope.isEmpty {
            emptyContentLanes.removeAll()
            if try prioritizeContent(root:root,scope:scope,now:now) {onContentChange?()}
        }
        if session.finished, let error=result.errors.first { emit("部分位置无法读取",error) }
    }

    private func prioritizeContent(root: IndexedRoot, scope: String, now: TimeInterval) throws -> Bool {
        let key=ContentPath(rootID:root.id,path:scope)
        guard try database.pendingFile(rootID:root.id,path:scope) != nil else {
            freshContent.removeValue(forKey:key)
            return false
        }
        if freshContent[key] == nil && freshContent.count >= 4096 {return true}
        let first=freshContent[key]?.first ?? now
        freshContent[key]=FreshContent(first:first,ready:min(now+0.25,first+1))
        return true
    }

    private func contentAllowed(_ kind: FileKind, root: IndexedRoot, preferences: IndexingPreferences) -> Bool {
        guard root.enabled && root.isOnline else {return false}
        if kind == .image {return preferences.images && (!root.isExternal || preferences.externalImages)}
        return preferences.documents && (!root.isExternal || preferences.externalDocuments)
    }

    private func selectContent(lane: ContentLane, preferences: IndexingPreferences, now: TimeInterval) throws -> (IndexedRoot, FileRecord)? {
        let roots=Dictionary(uniqueKeysWithValues:currentRoots.map { ($0.id,$0) })
        var fresh: (IndexedRoot, FileRecord)?
        for (key, time) in freshContent.sorted(by:{ $0.value.first < $1.value.first }) where time.ready <= now {
            guard let root=roots[key.rootID], let file=try database.pendingFile(rootID:key.rootID,path:key.path) else {
                freshContent.removeValue(forKey:key)
                continue
            }
            if Self.isHeavy(file) == (lane == .heavy), contentAllowed(file.kind,root:root,preferences:preferences) {
                fresh=(root,file)
                break
            }
        }
        let freshRun=freshRuns[lane,default:0]
        if let fresh, freshRun < 3 {freshRuns[lane]=freshRun+1;return fresh}

        let kinds:[FileKind]=lane == .heavy ? [.image,.document] : [.document,.code]
        let pools=currentRoots.flatMap { root in
            kinds.filter {contentAllowed($0,root:root,preferences:preferences)}.map { (root,$0) }
        }
        if !pools.isEmpty && !emptyContentLanes.contains(lane) {
            for _ in pools {
                let cursor=contentCursors[lane,default:0] % pools.count
                contentCursors[lane]=(cursor+1)%pools.count
                let (root,kind)=pools[cursor]
                var after:Int64=0
                while true {
                    let pending=try database.pendingFiles(rootID:root.id,limit:32,kind:kind,heavy:lane == .heavy,afterID:after)
                    if let row=pending.first(where:{freshContent[ContentPath(rootID:root.id,path:$0.relativePath)] == nil}) {
                        freshRuns[lane]=0
                        return (root,row)
                    }
                    guard let last=pending.last, pending.count == 32 else {break}
                    after=last.id
                }
            }
        }
        emptyContentLanes.insert(lane)
        if fresh != nil {freshRuns[lane]=1}
        return fresh
    }

    private func launchContent(preferences: IndexingPreferences, epoch: UInt64) throws {
        let now=ProcessInfo.processInfo.systemUptime
        for lane in ContentLane.allCases where claims[lane] == nil && !yielding {
            guard let (root,file)=try selectContent(lane:lane,preferences:preferences,now:now) else {continue}
            let key=ContentPath(rootID:root.id,path:file.relativePath)
            let claim=ContentClaim(key:key,root:root,file:file,epoch:epoch)
            guard !claimCancelled(claim) else {return}
            claims[lane]=claim
            let worker=lane == .heavy ? heavyWorker : lightWorker
            emit(file.kind == .image ? "正在识别图片" : "正在提取文档",file.name,busy:true)
            worker.async { [weak self] in
                guard let self else {return}
                let result=autoreleasepool { self.extract(claim) }
                self.work.async { [weak self] in
                    autoreleasepool { self?.finishContent(lane:lane,claim:claim,result:result) }
                }
            }
        }
        if let next=freshContent.values.map(\.ready).filter({$0 > now}).min(), contentWakeDeadline != next {
            contentWake?.cancel()
            let item=DispatchWorkItem { [weak self] in
                self?.contentWakeDeadline=nil
                self?.wakeWork()
            }
            contentWake=item
            contentWakeDeadline=next
            work.asyncAfter(deadline:.now()+max(0,next-now),execute:item)
        }
    }

    private func claimCancelled(_ claim: ContentClaim) -> Bool {
        locked { !canCommit(claim) }
    }

    // Called with the lifecycle lock held.
    private func canCommit(_ claim: ContentClaim) -> Bool {
        contentEpoch == claim.epoch && !stopped && !paused && !sleeping && mutations == 0
    }

    private struct ChangeStamp: Equatable {
        var device: Int32
        var inode: UInt64
        var seconds: Int
        var nanoseconds: Int
    }

    private func stamp(_ url: URL) -> ChangeStamp? {
        var info=stat()
        guard lstat(url.path,&info) == 0 else {return nil}
        return ChangeStamp(device:info.st_dev,inode:info.st_ino,seconds:info.st_ctimespec.tv_sec,nanoseconds:info.st_ctimespec.tv_nsec)
    }

    private func extract(_ claim: ContentClaim) -> (ExtractionResult, ChangeStamp?) {
        let url=URL(fileURLWithPath:claim.root.path).appendingPathComponent(claim.key.path)
        guard !claimCancelled(claim) else {return (.interrupted,nil)}
        let before=stamp(url)
        do {
            guard try FileSignature.read(url).matches(claim.file) else {return (.changed,before)}
            let reuse = Self.isHeavy(claim.file) ? extractionReuse : nil
            let key = reuse == nil ? nil : ExtractionReuse.key(url,file:claim.file,cancelled:{self.claimCancelled(claim)})
            if let key, let raw=reuse?.get(key) {
                guard stamp(url) == before else {return (.changed,before)}
                return (.done(raw),before)
            }
            guard !claimCancelled(claim) else {return (.interrupted,nil)}
            let content=try extractor(url,{ self.claimCancelled(claim) })
            guard !claimCancelled(claim) else {return (.interrupted,nil)}
            guard stamp(url) == before, try FileSignature.read(url).matches(claim.file) else {return (.changed,before)}
            let raw=try JSONEncoder().encode(content)
            if let key, content.warning == nil {reuse?.save(raw,for:key)}
            return (.done(raw),before)
        } catch {
            guard !claimCancelled(claim) else {return (.interrupted,nil)}
            if stamp(url) != before || stamp(url) == nil {return (.changed,before)}
            return (.failed(error.localizedDescription),before)
        }
    }

    private func finishContent(lane: ContentLane, claim: ContentClaim, result: (ExtractionResult, ChangeStamp?)) {
        defer { claims.removeValue(forKey:lane);wakeWork() }
        guard !claimCancelled(claim) else {return}
        let current=VolumeIdentity.refreshed(claim.root)
        guard current.isOnline, current.path == claim.root.path else {
            locked { rootsNeedRefresh=true }
            return
        }
        let url=URL(fileURLWithPath:current.path).appendingPathComponent(claim.key.path)
        do {
            var changed=false
            switch result.0 {
            case .interrupted: return
            case .changed:
                recheckChangedContent(claim,url:url)
                return
            case .done(let raw):
                guard stamp(url) == result.1 else {recheckChangedContent(claim,url:url);return}
                changed=try locked {
                    guard canCommit(claim) else {return false}
                    return try database.completeContent(file:claim.file,raw:raw,requirePending:true)
                }
            case .failed(let message):
                guard stamp(url) == result.1 else {recheckChangedContent(claim,url:url);return}
                changed=try locked {
                    guard canCommit(claim) else {return false}
                    return try database.failPendingContent(file:claim.file,message:message)
                }
            }
            if changed {
                freshContent.removeValue(forKey:claim.key)
                onContentChange?()
                onChange?()
            }
        } catch {emit("索引遇到问题",error.localizedDescription)}
    }

    private func recheckChangedContent(_ claim: ContentClaim, url: URL) {
        // Put the rescan ahead of another extraction attempt against the
        // obsolete row. The scan will submit the latest stable signature.
        let now=ProcessInfo.processInfo.systemUptime
        freshContent[claim.key]=FreshContent(first:freshContent[claim.key]?.first ?? now,ready:now+1)
        receiveEvents([FileChangeEvent(path:url.path)])
    }

    private func run() {
        var more=false
        defer {
            let again=locked { () -> Bool in
                running=false
                return more || requested
            }
            if again {wakeWork()}
        }
        guard !yielding else {return}
        do {
            let (prefs,epoch,refresh)=locked { () -> (IndexingPreferences,UInt64,Bool) in
                requested=false
                let result=(preferences,contentEpoch,rootsNeedRefresh)
                rootsNeedRefresh=false
                return result
            }
            if refresh {
                emptyContentLanes.removeAll()
                currentRoots=try refreshRoots(preferences:prefs)
            }
            try processFullRequest()
            try launchContent(preferences:prefs,epoch:epoch)
            let eligible=currentRoots.filter { $0.enabled && $0.isOnline }
            for offset in eligible.indices {
                let index=(scanRootCursor+offset)%eligible.count
                if try scanSlice(root:eligible[index],preferences:prefs) {
                    scanRootCursor=(index+1)%eligible.count
                    more=true
                    break
                }
            }
            try launchContent(preferences:prefs,epoch:epoch)
            if more || !claims.isEmpty || freshContent.values.contains(where:{$0.ready > ProcessInfo.processInfo.systemUptime}) {
                idlePublished=false
            } else if !idlePublished && !yielding {
                idlePublished=true
                IndexBenchmarkTrace.active?.idle(database:database)
                emit("索引已更新","新增或修改文件后会自动更新")
                onChange?()
            }
        } catch {
            locked { rootsNeedRefresh=true }
            emit("索引遇到问题",error.localizedDescription)
            onChange?()
        }
    }
}
