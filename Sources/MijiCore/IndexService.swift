import Foundation
import AppKit
import CoreServices

public struct IndexProgress: Sendable {
    public var phase: String
    public var detail: String
    public var processed: Int
    public var busy: Bool
    public init(phase: String = "准备就绪", detail: String = "", processed: Int = 0, busy: Bool = false) { self.phase=phase; self.detail=detail; self.processed=processed; self.busy=busy }
}
public struct IndexingPreferences: Codable, Sendable {
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
    private let lock = NSLock()
    private let work = DispatchQueue(label: "local.miji.index", qos: .utility)
    private let control = DispatchQueue(label: "local.miji.control", qos: .utility)
    private var running = false
    private var requested = false
    private var fullRequested = false
    private var userActive = false
    private var sleeping = false
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
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private let ignoredPaths: [String]
    private var nextScanAfter = Date.distantPast
    private let rescanInterval: TimeInterval = 10
    private let extractor: (URL, @escaping () -> Bool) throws -> ExtractedContent
    private let contentClock: () -> TimeInterval
    // Only accessed on work. Keep both roots and content kinds moving, even
    // when a slow image consumes the entire time slice by itself.
    private var contentLaneCursor = 0
    private let contentBatchLimit = 6
    private let contentBatchSeconds: TimeInterval = 0.25
    public convenience init(database: SearchDatabase, ignoredPaths: [String] = [], extractionWorker: URL? = nil) {
        self.init(database:database,ignoredPaths:ignoredPaths,extractor: { url,cancelled in
            let ext=url.pathExtension.lowercased()
            if let extractionWorker, FileKind.classify(extension:ext) == .image || ["pdf","pages","numbers","key","keynote"].contains(ext) {
                return try IsolatedContentExtractor.extract(url:url,executable:extractionWorker,cancelled:cancelled)
            }
            return try ContentExtractor.extract(url:url,cancelled:cancelled)
        })
    }
    init(database: SearchDatabase, ignoredPaths: [String] = [], extractor: @escaping (URL, @escaping () -> Bool) throws -> ExtractedContent,
         contentClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         watchEvents: Bool = true, stateURL: URL? = nil) {
        self.database = database
        let inboxURL=stateURL ?? database.url.appendingPathExtension("incremental.json")
        self.stateURL=inboxURL
        self.state=IncrementalIndexState.read(inboxURL)
        for (id,root) in self.state.roots {
            self.state.roots[id]?.pending=IndexRelativePath.coalescing(root.pending + root.inFlight)
            self.state.roots[id]?.inFlight=[]
        }
        self.watchEvents=watchEvents
        self.ignoredPaths = ignoredPaths + [inboxURL.path,inboxURL.appendingPathExtension("tmp").path]
        self.extractor = extractor
        self.contentClock = contentClock
    }
    private func locked<T>(_ block: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try block() }
    public func configure(_ preferences: IndexingPreferences) {
        let rescan=locked { () -> Bool in
            let changed=self.preferences.includeHidden != preferences.includeHidden || self.preferences.excludeDevelopmentCaches != preferences.excludeDevelopmentCaches
            self.preferences=preferences
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
            timer.setEventHandler { [weak self] in self?.wakeWork() }
            self.timer=timer;timer.resume()
            let center=NSWorkspace.shared.notificationCenter
            self.workspaceObservers=[
                center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:nil) { [weak self] _ in self?.setSystemSleeping(true) },
                center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:nil) { [weak self] _ in self?.setSystemSleeping(false) },
                center.addObserver(forName:NSWorkspace.didMountNotification,object:nil,queue:nil) { [weak self] _ in self?.wakeWork() },
                center.addObserver(forName:NSWorkspace.didUnmountNotification,object:nil,queue:nil) { [weak self] _ in self?.wakeWork() }
            ]
        }
        wakeWork()
    }
    public func stop() {
        locked { stopped=true }
        control.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel();self.timer=nil;self.watcher=nil;self.debounce?.cancel();self.debounce=nil
            for observer in self.workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            self.workspaceObservers=[]
        }
    }
    public func setPaused(_ value: Bool) {
        locked { paused=value }
        if value { emit("已暂停","搜索现有索引仍然可用") } else { wakeWork() }
    }
    /// Finish the current valid extraction, then yield metadata and content work
    /// while the user is typing. No completed result is discarded to yield.
    public func setUserActive(_ value: Bool) { locked { userActive=value }; if !value { wakeWork() } }
    func setSystemSleeping(_ value: Bool) { locked { sleeping=value }; if !value { wakeWork() } }
    /// Explicit refresh remains a full reconciliation, with storm coalescing.
    public func requestScan() { locked { fullRequested=true }; wakeWork() }
    public func requestIncrementalUpdate() { wakeWork() }
    private func wakeWork() {
        let delay=locked { () -> TimeInterval? in
            requested=true
            guard !running, !stopped, !paused, !sleeping, !userActive, mutations == 0 else { return nil }
            running=true
            return fullRequested ? max(0,nextScanAfter.timeIntervalSinceNow) : 0
        }
        if let delay { work.asyncAfter(deadline:.now()+delay) { [weak self] in self?.run() } }
    }
    public func mutate(_ action: @escaping (SearchDatabase) throws -> Void, completion: @escaping (Error?) -> Void = {_ in}) {
        locked { mutations += 1 }
        work.async { [weak self] in
            guard let self else { return }
            var failure:Error?
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
            completion(failure);self.onChange?();self.wakeWork()
        }
    }
    private var interrupted: Bool { locked { stopped || paused || sleeping || mutations > 0 } }
    private var yielding: Bool { interrupted || locked { userActive } }
    private var contentInterrupted: Bool { interrupted }
    private func emit(_ phase: String, _ detail: String = "", count: Int = 0, busy: Bool = false) { onProgress?(IndexProgress(phase:phase,detail:detail,processed:count,busy:busy)) }
    private func persistState() throws { try state.write(stateURL) }

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
                for event in events {
                    for (id,checkpoint) in state.roots {
                        if event.id > 0 && event.id <= (cursors[id] ?? 0) && !event.requiresFullScan { continue }
                        if event.requiresFullScan {
                            // A dropped stream may not identify the affected
                            // subtree. Conservatively reconcile all stream roots.
                            state.enqueue([""],rootID:id)
                        } else if !event.historyDone, !filter.ignores(event.path),
                                  let relative=IndexRelativePath.from(event.path,root:checkpoint.path) {
                            state.enqueue([IndexRelativePath.packageScope(relative)],rootID:id)
                        }
                        // RootChanged can carry ID 0; never move a cursor back.
                        state.roots[id]?.cursor=max(checkpoint.cursor,event.id)
                    }
                }
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
        let currentID=FSEventsGetCurrentEventId()
        let manualFull=locked { () -> Bool in
            if fullRequested && Date() >= nextScanAfter { fullRequested=false;return true }
            return false
        }
        try locked {
            let ids=Set(roots.map(\.id))
            state.roots=state.roots.filter { ids.contains($0.key) }
            try persistState()
        }
        for existing in roots {
            let root=VolumeIdentity.refreshed(existing)
            try database.saveRoot(root)
            try locked {
                if let old=state.roots[root.id] {
                    // A previous run may have yielded or been cancelled after
                    // claiming scopes. They remain durable until acknowledged.
                    state.roots[root.id]?.pending=IndexRelativePath.coalescing(old.pending + old.inFlight)
                    state.roots[root.id]?.inFlight=[]
                    if old.path != root.path || old.cursor > currentID || (!existing.isOnline && root.isOnline) {
                        state.roots[root.id]?.path=root.path
                        state.roots[root.id]?.cursor=currentID
                        state.enqueue([""],rootID:root.id)
                    }
                } else {
                    // First installation/migration has no replay cursor. Seed
                    // before scanning, so events during the scan are durable.
                    state.roots[root.id] = .init(path:root.path,cursor:currentID,pending:[""])
                }
                if manualFull { state.enqueue([""],rootID:root.id) }
                try persistState()
            }
        }
        roots=roots.map(VolumeIdentity.refreshed)
        updateWatchers(roots)
        return roots
    }
    /// A bounded slice shared by startup, scan checkpoints and the final drain.
    /// The deadline is checked between files: cancelling an otherwise valid OCR
    /// for scheduling would discard its work and repeatedly starve that file.
    private func drainContent(roots: [IndexedRoot], preferences prefs: IndexingPreferences) throws -> Bool {
        // Includes metadata validation and database encoding, not just Vision.
        try autoreleasepool { try drainContentBatch(roots:roots,preferences:prefs) }
    }
    private func drainContentBatch(roots: [IndexedRoot], preferences prefs: IndexingPreferences) throws -> Bool {
        var lanes: [(root: IndexedRoot, kind: FileKind)] = []
        for root in roots where root.enabled && root.isOnline {
            if prefs.documents && (!root.isExternal || prefs.externalDocuments) { lanes.append((root,.document)) }
            if prefs.images && (!root.isExternal || prefs.externalImages) { lanes.append((root,.image)) }
            if prefs.documents && (!root.isExternal || prefs.externalDocuments) { lanes.append((root,.code)) }
        }
        guard !lanes.isEmpty else { return false }
        let deadline=contentClock() + contentBatchSeconds
        var handled=false, attempts=0, emptyLanes=0
        var offlineRoots=Set<String>()
        while !yielding && attempts < contentBatchLimit && emptyLanes < lanes.count {
            // Empty-lane lookups must not turn a time slice into a false idle
            // result while another kind/root still has pending work.
            if attempts > 0 && contentClock() >= deadline { break }
            let lane=lanes[contentLaneCursor % lanes.count]
            contentLaneCursor=(contentLaneCursor + 1) % lanes.count
            let root=VolumeIdentity.refreshed(lane.root)
            guard !offlineRoots.contains(root.id), root.isOnline,
                  let file=try database.pendingFiles(rootID:root.id,limit:1,kind:lane.kind).first else {
                emptyLanes += 1; continue
            }
            emptyLanes=0; attempts += 1
            if contentInterrupted { break }
            emit(lane.kind == .image ? "正在识别图片" : "正在提取文档",file.name,busy:true)
            // onProgress may synchronously pause, stop or enqueue a mutation.
            if yielding { break }
            let url=URL(fileURLWithPath:root.path).appendingPathComponent(file.relativePath)
            do {
                let content=try autoreleasepool { try extractor(url,{ self.contentInterrupted }) }
                if contentInterrupted { break }
                guard VolumeIdentity.refreshed(root).isOnline else {
                    offlineRoots.insert(root.id); wakeWork(); continue
                }
                if try !FileSignature.read(url).matches(file) {
                    try database.failContent(file:file,message:"文件正在修改，将在下次扫描后重试")
                    handled=true; receiveEvents([FileChangeEvent(path:url.path)]); onChange?(); continue
                }
                _ = try database.completeContent(file:file,content:content)
                handled=true
            } catch {
                if contentInterrupted { break }
                if !VolumeIdentity.refreshed(root).isOnline {
                    offlineRoots.insert(root.id); wakeWork(); continue
                }
                try database.failContent(file:file,message:error.localizedDescription)
                handled=true
            }
            onChange?()
        }
        return handled
    }
    private func run() {
        let activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"在本机建立文件全文和图片索引")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            let restart=locked { () -> Bool in
                running=false
                return requested && !paused && !stopped && !sleeping && !userActive && mutations == 0
            }
            if restart { wakeWork() }
        }
        do {
            while !yielding {
                locked { requested=false }
                let prefs=locked { preferences }
                let roots=try refreshRoots(preferences:prefs)
                // Always continue an existing backlog before directory work.
                _=try drainContent(roots:roots,preferences:prefs)
                for root in roots where root.enabled && root.isOnline {
                    if yielding { return }
                    let scopes=try locked { () throws -> [String] in
                        let scopes=state.roots[root.id]?.pending ?? []
                        state.roots[root.id]?.pending=[]
                        state.roots[root.id]?.inFlight=scopes
                        try persistState()
                        return scopes
                    }
                    for scope in scopes {
                        if yielding { return }
                        emit(scope.isEmpty ? "正在建立文件目录" : "正在更新文件目录",scope.isEmpty ? root.name : scope,busy:true)
                        var contentFailure:Error?
                        let change=IndexChange(rootID:root.id,relativePaths:[scope],fullRescan:scope.isEmpty)
                        let result=try FileScanner(database:database,ignoredPaths:ignoredPaths).scan(root:root,relativePath:scope,options:ScanOptions(includeHidden:prefs.includeHidden,excludeDevelopmentCaches:prefs.excludeDevelopmentCaches),cancelled:{self.yielding || contentFailure != nil}) { count in
                            guard !self.yielding,contentFailure == nil else { return }
                            self.emit(scope.isEmpty ? "正在建立文件目录" : "正在更新文件目录",scope.isEmpty ? root.name : scope,count:count,busy:true)
                            // The committed ID journal makes a batch refresh
                            // bounded even while the first whole-root scan runs.
                            self.onIndexChange?(IndexChange(rootID:root.id,relativePaths:[scope],fullRescan:false))
                            self.onChange?()
                            do { _=try self.drainContent(roots:roots,preferences:prefs) } catch { contentFailure=error }
                            if !self.yielding && contentFailure == nil {
                                self.emit(scope.isEmpty ? "正在建立文件目录" : "正在更新文件目录",scope.isEmpty ? root.name : scope,count:count,busy:true)
                            }
                        }
                        if let contentFailure { throw contentFailure }
                        autoreleasepool { self.onIndexChange?(change);self.onChange?() }
                        if result.complete || (!yielding && !result.errors.isEmpty && VolumeIdentity.refreshed(root).isOnline) {
                            try locked {
                                // Incoming events go to a separate inbox while
                                // this scope is inFlight. A long first scan can
                                // finish even under continuous file changes.
                                state.roots[root.id]?.inFlight.removeAll { $0 == scope }
                                if !result.complete {
                                    let pending=state.roots[root.id]?.pending ?? []
                                    state.roots[root.id]?.pending=IndexRelativePath.coalescing(pending + result.preservingPaths)
                                }
                                try persistState()
                            }
                        }
                        if !result.errors.isEmpty && !yielding { emit("部分位置无法读取",result.errors[0]) }
                        if scope.isEmpty { locked { nextScanAfter=Date().addingTimeInterval(rescanInterval) } }
                    }
                }
                if yielding { return }
                // Drain bounded batches with a fresh autorelease pool each time.
                // Dirty events arriving during extraction interrupt only at a
                // batch boundary, never invalidate an otherwise valid result.
                while !yielding {
                    let handled=try drainContent(roots:roots,preferences:prefs)
                    if locked({requested}) { break }
                    if !handled {
                        emit("索引已更新","新增或修改文件后会自动更新");onChange?();return
                    }
                }
                if !locked({requested}) { return }
            }
        } catch { emit("索引遇到问题",error.localizedDescription);onChange?() }
    }
}
