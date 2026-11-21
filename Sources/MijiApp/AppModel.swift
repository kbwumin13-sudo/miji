import SwiftUI
import AppKit
import MijiCore
import PDFKit

private final class SearchTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Every condition that affects the result set, plus a monotonic request generation.
struct SearchSnapshot: Equatable {
    let generation: UInt64
    let query: String
    let kind: FileKind?
    let rootID: String?
    let scope: SearchScope
    let sort: SearchSort
    let onlineOnly: Bool
    let limit: Int
}

enum SearchPhase: Equatable { case idle, searching, supplementing, complete, failed }
enum SearchTiming: Equatable { case firstBatch, complete }
struct SearchStatus {
    let phase: SearchPhase
    let count: Int
    let milliseconds: Double?
    let timing: SearchTiming?
    let error: String?
    let isLimited: Bool
}
enum SearchFilterID: String { case kind, root, scope, sort, onlineOnly }
struct SearchFilter: Identifiable {
    let id: SearchFilterID
    let label: String
}
struct ResultLocation {
    let short: String
    let fullPath: String
}
enum ResultAvailabilityState { case available, diskOffline, fileUnavailable, indexedOnly, partial, extractionFailed }
struct ResultAvailability {
    let state: ResultAvailabilityState
    let message: String?
    let volumeName: String
    let contentMessage: String?
}
enum FileAction { case open, reveal, copyFile, copyPath, quickLook, preview, openAtLine }

@MainActor
final class AppModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var hits: [SearchHit] = []
    @Published var selectedID: Int64? { didSet { loadPreview() } }
    @Published var roots: [IndexedRoot] = []
    @Published var statistics = IndexStatistics()
    @Published var progress = IndexProgress()
    @Published var lastProgressAt: Date?
    @Published var preferences = IndexingPreferences()
    @Published var kind: FileKind? { didSet { if kind != oldValue { scheduleSearch() } } }
    @Published var rootID: String? { didSet { if rootID != oldValue { scheduleSearch() } } }
    @Published var scope = SearchScope.all { didSet { if scope != oldValue { scheduleSearch() } } }
    @Published var sort = SearchSort.relevance { didSet { if sort != oldValue { scheduleSearch() } } }
    @Published var paused = false
    @Published private(set) var currentSnapshot: SearchSnapshot?
    @Published private(set) var displayedSnapshot: SearchSnapshot?
    @Published private(set) var searchPhase = SearchPhase.idle
    @Published private(set) var firstBatchMilliseconds: Double?
    @Published private(set) var completedMilliseconds: Double?
    @Published private(set) var searchLimited = false
    @Published private(set) var searchError: String?
    private var generation: UInt64 = 0
    private var searchStartedAt = Date()
    @Published var searching = false
    @Published var searchMilliseconds:Double = 0
    @Published var message: String?
    @Published var previewText = ""
    @Published var previewWarning: String?
    @Published var previewPage: Int?
    @Published var previewLine: Int?
    @Published var previewLocalURL: URL?
    @Published var previewPDF: PDFDocument?
    @Published var previewLoading = false
    @Published var previewMode = SearchPreviewMode.automatic { didSet { loadPreview() } }
    // Compatibility for callers that explicitly enable/disable the pane.
    var previewEnabled: Bool {
        get { previewMode != .hidden }
        set { previewMode = newValue ? .shown : .hidden }
    }
    var previewVisible: Bool { searchPresented && SearchPreviewPolicy.showsPane(mode: previewMode, hits: hits) }
    @Published var gridEnabled = false
    @Published var searchPresented = false
    @Published var showSettings = false
    @Published var focusSearch = UUID()
    let database: SearchDatabase?
    private let searchDatabase: SearchDatabase?
    private let statusDatabase: SearchDatabase?
    private let contentDatabase: SearchDatabase?
    private let previewDatabase: SearchDatabase?
    private let nameEngine: NameSearchEngine?
    private let contentQueue = DispatchQueue(label:"local.miji.content-search",qos:.userInitiated)
    private let previewQueue = DispatchQueue(label:"local.miji.preview",qos:.utility)
    private var previewTicket: SearchTicket?
    private var previewKey: String?
    private var previewContentIdentity: Data?
    private var previewNeedsContentCheck = false
    private var activityWork: DispatchWorkItem?
    let service: IndexService?
    private let searchQueue = DispatchQueue(label:"local.miji.search",qos:.userInitiated)
    private let statusQueue = DispatchQueue(label:"local.miji.status",qos:.utility)
    private var searchWork: DispatchWorkItem?
    private var refreshWork: DispatchWorkItem?
    private var indexRefreshWork: DispatchWorkItem?
    private var pendingCatalogChanges: [String: IndexChange] = [:]
    private var searchToken = UUID()
    private var searchTicket: SearchTicket?
    private let lifetimeTicket=SearchTicket()
    private var searchVisible = false
    private var refreshInFlight = false
    private var refreshAgain = false
    private var searchNeedsRefresh = false
    private var searchNeedsCatalogRefresh = false
    private var committedContentResults: [SearchHit] = []
    private let searchExecutor: ((SearchDatabase,String,SearchOptions,@escaping () -> Bool) throws -> [SearchHit])?
    private let testContentDelay: TimeInterval
    private let supplementaryExecutor: ((SearchDatabase,String,SearchOptions,@escaping () -> Bool) throws -> [SearchHit])?
    private var observers: [NSObjectProtocol] = []
    var openMain: (() -> Void)?
    var selected: SearchHit? { hits.first { $0.id == selectedID } }
    static func panelHeight(query: String, resultCount: Int) -> CGFloat {
        query.isEmpty ? 100 : CGFloat(150 + min(7, max(2, resultCount)) * 59)
    }
    static let previewWidth: CGFloat = 440
    var panelHeight: CGFloat { query.isEmpty ? 100 : (previewVisible || gridEnabled ? 563 : Self.panelHeight(query: query, resultCount: hits.count)) }
    var gridColumns:Int {max(1,Int((panelWidth - (previewVisible ? Self.previewWidth : 0) - 24)/180))}
    var panelWidth: CGFloat { !query.isEmpty && previewVisible ? 1060 : 800 }

    init(searchExecutor: ((SearchDatabase,String,SearchOptions,@escaping () -> Bool) throws -> [SearchHit])? = nil,
         supplementaryExecutor: ((SearchDatabase,String,SearchOptions,@escaping () -> Bool) throws -> [SearchHit])? = nil) {
        self.searchExecutor=searchExecutor
        self.supplementaryExecutor=supplementaryExecutor
        let env=ProcessInfo.processInfo.environment
        // A bounded, cancellable QA delay makes the real pending state observable.
        // It is disabled outside explicitly isolated UI test launches.
        testContentDelay = env["MIJI_UI_TESTING"] == "1" ? min(5000,max(0,Double(env["MIJI_UI_CONTENT_DELAY_MS"] ?? "0") ?? 0))/1000 : 0
        let support=env["MIJI_DATA_DIR"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Miji")
        do {
            try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let url=support.appendingPathComponent("index.sqlite")
            let writer=try SearchDatabase(url:url)
            let reader=try SearchDatabase(url:url,readOnly:true)
            let status=try SearchDatabase(url:url,readOnly:true)
            let content=try SearchDatabase(url:url,readOnly:true)
            let preview=try SearchDatabase(url:url,readOnly:true)
            let engine=try NameSearchEngine(databaseURL:url)
            database=writer; searchDatabase=reader; statusDatabase=status
            contentDatabase=content; previewDatabase=preview; nameEngine=engine
            let worker=Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("miji-extract")
            service=IndexService(database:writer,ignoredPaths:[support.path],extractionWorker:worker)
            // Freeze authored QA data before refresh/configuration can wake work.
            if AppDelegate.isBackgroundUITesting && env["MIJI_UI_PAUSE_INDEX"] == "1" {
                paused=true;service?.setPaused(true)
            }
        } catch { database=nil; searchDatabase=nil; statusDatabase=nil; contentDatabase=nil; previewDatabase=nil; nameEngine=nil; service=nil; message="索引数据库无法打开：\(error.localizedDescription)" }
        if let data=UserDefaults.standard.data(forKey:"indexingPreferences"), let saved=try? JSONDecoder().decode(IndexingPreferences.self,from:data) { preferences=saved }
        if env["MIJI_NO_AUTOSTART"] == "1" { preferences.autoAddExternal=false }
        do {
            if let database, try database.roots().isEmpty, env["MIJI_NO_AUTOSTART"] != "1" {
                let initial=env["MIJI_INITIAL_ROOT"].map { URL(fileURLWithPath:$0) } ?? URL(fileURLWithPath:"/")
                var root=try VolumeIdentity.root(for:initial); if root.path == "/" {root.name="这台 Mac"}; try database.saveRoot(root)
            }
        } catch { message=error.localizedDescription }
        service?.onProgress = { [weak self] value in DispatchQueue.main.async { self?.progress=value; self?.lastProgressAt=Date() } }
        service?.onChange = { [weak self] in DispatchQueue.main.async { self?.scheduleRefresh() } }
        for notification in [NSWorkspace.didMountNotification,NSWorkspace.didUnmountNotification,NSWorkspace.didRenameVolumeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:notification,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.service?.requestIncrementalUpdate(); self?.scheduleRefresh() }
            })
        }
        if let engine=nameEngine, searchExecutor == nil {
            let lifetime=lifetimeTicket
            searchQueue.async { [weak self] in
                do {
                    try engine.load(cancelled:{lifetime.isCancelled})
                    Self.completeUpgrade(engine,lifetime:lifetime)
                }
                catch { if !lifetime.isCancelled {DispatchQueue.main.async { self?.message="文件名索引加载失败：\(error.localizedDescription)" }} }
            }
        }
        service?.onIndexChange = { [weak self] change in
            DispatchQueue.main.async { self?.recordCatalogChange(change) }
        }
        service?.onContentChange = { [weak self] in
            DispatchQueue.main.async { self?.scheduleIndexRefresh() }
        }
        refresh()
        if env["MIJI_NO_AUTOSTART"] != "1" { service?.configure(preferences); service?.start() }
    }
    /// A cache from an earlier version gets its ranking data off the search
    /// queue after each load; searching continues meanwhile.
    private nonisolated static func completeUpgrade(_ engine:NameSearchEngine,lifetime:SearchTicket) {
        DispatchQueue.global(qos:.utility).async { try? engine.completeUpgrade(cancelled:{lifetime.isCancelled}) }
    }
    func prepareForTermination(completion:@escaping ()->Void) {
        lifetimeTicket.cancel();searchTicket?.cancel();previewTicket?.cancel();searchWork?.cancel();refreshWork?.cancel();indexRefreshWork?.cancel();activityWork?.cancel()
        service?.stop()
        let engine=nameEngine
        searchQueue.async {
            try? engine?.saveCache()
            DispatchQueue.main.async(execute:completion)
        }
    }
    func scheduleRefresh() {
        guard !lifetimeTicket.isCancelled else {return}
        guard refreshWork == nil else { return }
        let item=DispatchWorkItem { [weak self] in self?.refreshWork=nil; self?.refresh() }; refreshWork=item
        DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:item)
    }
    func refresh() {
        guard !lifetimeTicket.isCancelled else {return}
        guard let database=statusDatabase else { return }
        guard !refreshInFlight else { refreshAgain=true; return }
        refreshInFlight=true
        statusQueue.async { [weak self] in
            do {
                let roots=try database.roots(); let stats=try database.statistics()
                DispatchQueue.main.async {
                    guard let self,!self.lifetimeTicket.isCancelled else { return }
                    if self.roots != roots { self.roots=roots }
                    self.statistics=stats
                    self.finishRefresh()
                }
            } catch { DispatchQueue.main.async { self?.message=error.localizedDescription; self?.finishRefresh() } }
        }
    }
    private func finishRefresh() {
        refreshInFlight=false
        if refreshAgain { refreshAgain=false; scheduleRefresh() }
    }
    private var canSearch: Bool {
        searchVisible && !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    private func recordCatalogChange(_ change:IndexChange) {
        if let previous=pendingCatalogChanges[change.rootID],!change.fullRescan {
            if !previous.fullRescan {
                let paths=Array(Set(previous.relativePaths+change.relativePaths))
                pendingCatalogChanges[change.rootID]=IndexChange(rootID:change.rootID,relativePaths:paths,fullRescan:false)
            }
        } else { pendingCatalogChanges[change.rootID]=change }
        scheduleIndexRefresh()
    }
    private func scheduleIndexRefresh() {
        guard !lifetimeTicket.isCancelled,indexRefreshWork == nil,canSearch || !pendingCatalogChanges.isEmpty else { return }
        // A fixed window also makes progress when commits keep arriving.
        let item=DispatchWorkItem { [weak self] in self?.applyIndexChanges() }
        indexRefreshWork=item
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:item)
    }
    private func applyIndexChanges() {
        indexRefreshWork=nil
        let changes=pendingCatalogChanges
        pendingCatalogChanges=[:]
        if !changes.isEmpty,let engine=nameEngine,searchExecutor == nil {
            let lifetime=lifetimeTicket
            searchQueue.async { [weak self] in
                do {
                    for change in changes.values {
                        try engine.refresh(rootID:change.rootID,relativePaths:change.relativePaths,fullRescan:change.fullRescan,cancelled:{lifetime.isCancelled})
                    }
                } catch {
                    guard !lifetime.isCancelled else {return}
                    do { try engine.load(cancelled:{lifetime.isCancelled}); Self.completeUpgrade(engine,lifetime:lifetime) }
                    catch { if !lifetime.isCancelled {DispatchQueue.main.async { self?.message=error.localizedDescription }} }
                }
            }
        }
        searchNeedsRefresh=canSearch
        searchNeedsCatalogRefresh=searchNeedsCatalogRefresh || !changes.isEmpty
        searchIndexChangesIfReady()
    }
    private func searchIndexChangesIfReady() {
        guard searchNeedsRefresh,canSearch,searchTicket == nil else { return }
        searchNeedsRefresh=false
        let preservePresentation=searchPhase == .complete && displayedSnapshot == currentSnapshot
        if !preservePresentation { beginSearchPresentation() }
        let publishNames=preservePresentation && searchNeedsCatalogRefresh && scope == .all
        searchNeedsCatalogRefresh=false
        startSearch(preservePresentation:preservePresentation,publishNames:publishNames,delay:0)
    }
    func setSearchVisible(_ visible:Bool) {
        guard searchVisible != visible else { return }
        searchVisible=visible
        searchPresented=visible
        if !visible { PreviewThumbnails.clear() }
        scheduleSearch()
        if visible { scheduleRefresh() }
    }
    private func scheduleSearch() {
        searchWork?.cancel(); searchWork=nil
        searchTicket?.cancel(); searchTicket=nil
        searchNeedsRefresh=false
        searchNeedsCatalogRefresh=false
        committedContentResults=[]
        generation += 1
        currentSnapshot=makeSnapshot(generation: generation)
        previewTicket?.cancel(); previewKey=nil; clearPreview()
        beginSearchPresentation()
        if canSearch {
            if activityWork == nil { service?.setUserActive(true) }
            activityWork?.cancel()
            let release=DispatchWorkItem { [weak self] in self?.endUserActivity() }
            activityWork=release
            DispatchQueue.main.asyncAfter(deadline:.now()+0.8,execute:release)
            startSearch(preservePresentation:false,delay:0.035)
        } else {
            endUserActivity()
            if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { hits=[]; selectedID=nil; searchMilliseconds=0 }
        }
    }
    private func endUserActivity() {
        guard let activityWork else { return }
        activityWork.cancel()
        self.activityWork=nil
        service?.setUserActive(false)
    }
    private func beginSearchPresentation() {
        firstBatchMilliseconds=nil; completedMilliseconds=nil; searchError=nil; searchLimited=false
        searchPhase=canSearch ? .searching : .idle
        searching=canSearch
        searchStartedAt=Date()
    }
    private func startSearch(preservePresentation:Bool,publishNames:Bool = false,delay:TimeInterval) {
        let token=UUID(); searchToken=token
        let ticket=SearchTicket(); searchTicket=ticket
        let text=query; let options=SearchOptions(kind:kind,rootID:rootID,scope:scope,sort:sort,onlineOnly:!preferences.retainOffline,limit:500)
        let startedAt=Date()
        let previousContent=publishNames ? committedContentResults : []
        let item=DispatchWorkItem { [weak self] in
            guard let self, !ticket.isCancelled else { return }
            self.searchWork=nil
            guard let database=self.searchDatabase else {
                self.searchFailed(NSError(domain:"Miji.Search",code:1,userInfo:[NSLocalizedDescriptionKey:"索引数据库无法打开"]),token:token,ticket:ticket,preservePresentation:preservePresentation); return
            }
            let execute=self.searchExecutor, engine=self.nameEngine
            self.searchQueue.async { [weak self] in
                guard !ticket.isCancelled else { return }
                do {
                    if let execute {
                        let result=try execute(database,text,options,{ticket.isCancelled})
                        DispatchQueue.main.async { self?.publish(result,token:token,ticket:ticket,elapsed:Date().timeIntervalSince(startedAt)*1000,finished:true,preservePresentation:preservePresentation) }
                        return
                    }
                    var first:[SearchHit]=[]
                    if options.scope != .content,let engine {
                        var nameOptions=options; nameOptions.scope = .name
                        let exclusions=options.scope == .all && QueryParser.parse(text).terms.contains {$0.field == .text && $0.isExcluded}
                        var examined=0
                        repeat {
                            let ids=try engine.search(text,options:nameOptions,cancelled:{ticket.isCancelled})
                            first += try database.nameHits(ids:Array(ids.dropFirst(examined)),query:text,verifyContentExclusions:exclusions,cancelled:{ticket.isCancelled})
                            if !exclusions || first.count>=options.limit || ids.count<nameOptions.limit {break}
                            examined=ids.count
                            nameOptions.limit *= 2
                        } while !ticket.isCancelled
                        first=Array(first.prefix(options.limit))
                    }
                    let names=first
                    // During a catalog refresh, show fresh names without
                    // temporarily dropping unchanged body matches.
                    let initial: [SearchHit]
                    if publishNames {
                        let retained=try Self.retainCurrentBodyHits(previousContent,database:database,options:options,cancelled:{ticket.isCancelled})
                        initial=SearchResultMerger.merge(nameResults:names,contentResults:retained,scope:options.scope,sort:options.sort,limit:options.limit,query:text)
                    } else { initial=names }
                    DispatchQueue.main.async {
                        guard let self,self.searchToken==token,!ticket.isCancelled else { return }
                        let finished=options.scope == .name
                        if finished || !preservePresentation || publishNames {
                            self.publish(initial,token:token,ticket:ticket,elapsed:finished || !names.isEmpty ? Date().timeIntervalSince(startedAt)*1000 : nil,finished:finished,preservePresentation:preservePresentation)
                        }
                        guard !finished,let contentDatabase=self.contentDatabase else { return }
                        let supplement=self.supplementaryExecutor, testDelay=self.testContentDelay
                        self.contentQueue.async { [weak self] in
                            guard !ticket.isCancelled else { return }
                            if testDelay > 0 {
                                let until=Date().addingTimeInterval(testDelay)
                                while Date() < until && !ticket.isCancelled { Thread.sleep(forTimeInterval:0.01) }
                                guard !ticket.isCancelled else {return}
                            }
                            do {
                                func merge(_ extra:[SearchHit])->[SearchHit] {
                                    SearchResultMerger.merge(nameResults:names,contentResults:extra,scope:options.scope,sort:options.sort,limit:options.limit,query:text)
                                }
                                var deliveredPartial=false
                                var limited=false
                                let extra:[SearchHit]
                                if let supplement {extra=try supplement(contentDatabase,text,options,{ticket.isCancelled})}
                                else {
                                    extra=try contentDatabase.searchSupplementary(text,options:options,cancelled:{ticket.isCancelled},onPartial:{ partial in
                                        guard !ticket.isCancelled,!preservePresentation else {return}
                                        let result=merge(partial)
                                        let elapsed=names.isEmpty && !deliveredPartial ? Date().timeIntervalSince(startedAt)*1000 : nil
                                        deliveredPartial=true
                                        DispatchQueue.main.async {self?.publish(result,token:token,ticket:ticket,elapsed:elapsed,finished:false)}
                                    },onMetrics:{ metrics in limited=metrics.budgetExhausted || metrics.resultTruncated })
                                }
                                let result=merge(extra)
                                let elapsed=names.isEmpty && !deliveredPartial ? Date().timeIntervalSince(startedAt)*1000 : nil
                                let finalLimited=limited
                                DispatchQueue.main.async {
                                    self?.publish(result,token:token,ticket:ticket,elapsed:elapsed,finished:true,
                                                  limited:finalLimited,preservePresentation:preservePresentation,contentResults:extra)
                                }
                            } catch { DispatchQueue.main.async { self?.searchFailed(error,token:token,ticket:ticket,preservePresentation:preservePresentation) } }
                        }
                    }
                } catch { DispatchQueue.main.async { self?.searchFailed(error,token:token,ticket:ticket,preservePresentation:preservePresentation) } }
            }
        }
        searchWork=item; DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:item)
    }
    private nonisolated static func retainCurrentBodyHits(_ previous:[SearchHit],database:SearchDatabase,options:SearchOptions,
                                                        cancelled:() -> Bool) throws -> [SearchHit] {
        guard !previous.isEmpty else { return [] }
        let refreshed=try database.nameHits(ids:previous.map(\.id),query:"",cancelled:cancelled)
        let current=Dictionary(uniqueKeysWithValues:refreshed.map { ($0.id,$0) })
        return previous.compactMap { old in
            guard let new=current[old.id],(!options.onlineOnly || new.root.isOnline),
                  old.file.rootID == new.file.rootID,old.file.relativePath == new.file.relativePath,
                  old.file.name == new.file.name,old.file.kind == new.file.kind,old.file.fileExtension == new.file.fileExtension,
                  old.file.inode == new.file.inode,old.file.modified == new.file.modified,old.file.size == new.file.size,
                  old.file.contentState == new.file.contentState,old.file.contentError == new.file.contentError else { return nil }
            var hit=old
            hit.file=new.file; hit.root=new.root
            return hit
        }
    }
    private func publish(_ result:[SearchHit],token:UUID,ticket:SearchTicket,elapsed:Double?,finished:Bool,
                         limited:Bool? = nil,preservePresentation:Bool = false,contentResults:[SearchHit] = []) {
        guard searchToken==token,!ticket.isCancelled else { return }
        let previous=selected
        let preserved=previous.flatMap { old in result.first { $0.file.rootID == old.file.rootID && $0.file.relativePath == old.file.relativePath } }
        if preservePresentation && !finished && (result.isEmpty || (previous != nil && preserved == nil)) { return }
        if let limited {searchLimited=limited}
        hits=result
        if !preservePresentation {
            displayedSnapshot=currentSnapshot; searching = !finished
            searchPhase = finished ? .complete : (result.isEmpty ? .searching : .supplementing)
            if firstBatchMilliseconds == nil && !result.isEmpty { firstBatchMilliseconds=Date().timeIntervalSince(searchStartedAt)*1000 }
            if finished { completedMilliseconds=Date().timeIntervalSince(searchStartedAt)*1000 }
            if let elapsed { searchMilliseconds=elapsed }
        }
        if let preserved {
            if selectedID != preserved.id { selectedID=preserved.id }
            else { loadPreview(checkStoredContent:preservePresentation && finished) }
        }
        else { selectedID=result.first?.id }
        if finished {
            committedContentResults=contentResults
            finishSearch()
        }
    }
    private func searchFailed(_ error:Error,token:UUID,ticket:SearchTicket,preservePresentation:Bool) {
        guard searchToken==token,!ticket.isCancelled else { return }
        if !preservePresentation {
            searching=false
            if !(error is CancellationError) {
                searchPhase = .failed; searchError=error.localizedDescription
                message="搜索失败：\(error.localizedDescription)"
            }
        }
        finishSearch()
    }
    private func finishSearch() {
        searchTicket=nil
        searchIndexChangesIfReady()
    }
    func loadPreview(checkStoredContent:Bool = false) {
        guard searchVisible,previewVisible,let hit=selected,isCurrentResult(hit),SearchPreviewPolicy.hasContent(hit),let database=previewDatabase else {
            if previewKey != nil { previewTicket?.cancel();previewKey=nil;clearPreview() }
            return
        }
        let key="\(hit.id)|\(hit.path)|\(hit.file.inode)|\(hit.file.modified)|\(hit.file.size)|\(hit.file.contentState)|\(hit.file.contentError ?? "")|\(hit.root.isOnline)|\(query)|\(hit.matchedIn)|\(hit.snippet)|\(hit.labels)"
        let keyChanged=key != previewKey
        guard keyChanged || checkStoredContent else { return }
        if !keyChanged && previewLoading { previewNeedsContentCheck=true;return }
        let previousIdentity=previewContentIdentity
        previewTicket?.cancel();previewKey=key
        if keyChanged { clearPreview(); previewLoading=true }
        let ticket=SearchTicket();previewTicket=ticket
        let query=query, snapshot=displayedSnapshot
        previewQueue.async { [weak self] in
            guard !ticket.isCancelled else{return}
            let identity: Data?
            do { identity=try database.storedContentIdentity(fileID:hit.id) }
            catch { guard keyChanged else {return}; identity=nil }
            if !keyChanged && identity == previousIdentity { return }
            let content=try? database.storedContent(fileID:hit.id)
            var resolution=PreviewResolver.resolve(hit:hit,content:content,query:query,cancelled:{ticket.isCancelled})
            guard !ticket.isCancelled else{return}
            let localURL=PreviewResolver.localURL(for:hit)
            if (hit.file.kind == .code || hit.file.fileExtension.lowercased()=="pdf"),let url=localURL,
               let signature=try? FileSignature.read(url),!signature.matches(hit.file) {
                resolution.page=nil;resolution.line=nil
                resolution.warning=[resolution.warning,"文件已变化，正文为上次索引内容；位置将在索引更新后恢复"].compactMap{$0}.joined(separator:"；")
            }
            var document:PDFDocument?
            if hit.file.fileExtension.lowercased()=="pdf",let url=localURL {
                let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize
                if let size, size<=64*1024*1024 {
                    document=PDFDocument(url:url)
                    if document?.isLocked == true { document=nil;resolution.warning="PDF 已加密，无法显示原文预览" }
                    else if document == nil { resolution.warning="PDF 无法读取，显示已索引内容" }
                } else { resolution.warning="PDF 较大，使用快速查看打开原文件" }
            }
            DispatchQueue.main.async {
                guard let self,!ticket.isCancelled,self.searchVisible,self.selectedID==hit.id,self.displayedSnapshot==snapshot,self.isCurrentResult(hit) else { return }
                self.previewContentIdentity=identity
                self.previewText=resolution.text;self.previewWarning=resolution.warning
                self.previewLocalURL=localURL;self.previewPage=resolution.page;self.previewLine=resolution.line;self.previewPDF=document;self.previewLoading=false
                if self.previewNeedsContentCheck {
                    self.previewNeedsContentCheck=false
                    self.loadPreview(checkStoredContent:true)
                }
            }
        }
    }
    private func clearPreview() {
        previewContentIdentity=nil
        previewNeedsContentCheck=false
        previewText="";previewWarning=nil;previewPage=nil;previewLine=nil;previewPDF=nil;previewLocalURL=nil;previewLoading=false
    }
    func addFolder() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=true; panel.prompt="加入索引"; panel.message="选择文件夹或磁盘。内容只保存在这台 Mac。"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let root=try VolumeIdentity.root(for:url)
                if root.isExternal { preferences.ignoredExternalVolumes.removeAll { $0 == (root.volumeUUID ?? root.path) }; savePreferences() }
                if roots.contains(where:{ root.path == $0.path || root.path.hasPrefix($0.path + "/") }) { continue }
                service?.mutate({try $0.saveRoot(root)}) { [weak self] error in if let error {DispatchQueue.main.async {self?.message=error.localizedDescription}} }
            } catch { message=error.localizedDescription }
        }
        refresh(); service?.requestScan()
    }
    func removeRoot(_ root: IndexedRoot) {
        if rootID==root.id { rootID=nil }
        if root.isExternal {preferences.ignoredExternalVolumes.append(root.volumeUUID ?? root.path);savePreferences()}
        service?.mutate({try $0.removeRoot(id:root.id)}) { [weak self] error in if let error {DispatchQueue.main.async {self?.message=error.localizedDescription}} }
    }
    func setRoot(_ root: IndexedRoot,enabled:Bool) {
        var root=root; root.enabled=enabled
        service?.mutate({try $0.saveRoot(root)}) { [weak self] error in if let error {DispatchQueue.main.async {self?.message=error.localizedDescription}} }
    }
    func retryContent() {
        let roots=roots
        service?.mutate({db in for root in roots {try db.resetContent(rootID:root.id,kind:nil)}}) { [weak self] error in if let error {DispatchQueue.main.async {self?.message=error.localizedDescription}} }
    }
    func savePreferences() {
        if let data=try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data,forKey:"indexingPreferences") }
        service?.configure(preferences)
        if let snapshot=currentSnapshot,snapshot != makeSnapshot(generation:generation) { scheduleSearch() }
    }
    func togglePause() { paused.toggle(); service?.setPaused(paused) }
    private func makeSnapshot(generation: UInt64) -> SearchSnapshot {
        SearchSnapshot(generation:generation,query:query,kind:kind,rootID:rootID,scope:scope,sort:sort,onlineOnly:!preferences.retainOffline,limit:500)
    }
    var searchStatus: SearchStatus {
        SearchStatus(phase:searchPhase,count:displayedSnapshot == currentSnapshot ? hits.count : 0,
                     milliseconds:completedMilliseconds ?? firstBatchMilliseconds,
                     timing:completedMilliseconds != nil ? .complete : (firstBatchMilliseconds != nil ? .firstBatch : nil),error:searchError,isLimited:searchLimited)
    }
    var activeFilters: [SearchFilter] {
        var result: [SearchFilter] = []
        if let kind { result.append(SearchFilter(id:.kind,label:kind.title)) }
        if let rootID { result.append(SearchFilter(id:.root,label:roots.first { $0.id == rootID }?.name ?? "指定位置")) }
        if scope != .all { result.append(SearchFilter(id:.scope,label:scope == .name ? "仅文件名" : "仅内容")) }
        if sort != .relevance { result.append(SearchFilter(id:.sort,label:sort == .modified ? "最近修改" : sort == .size ? "按大小" : "按名称")) }
        if !preferences.retainOffline { result.append(SearchFilter(id:.onlineOnly,label:"仅在线")) }
        return result
    }
    func removeFilter(_ id: SearchFilterID) {
        switch id {
        case .kind: kind=nil
        case .root: rootID=nil
        case .scope: scope = .all
        case .sort: sort = .relevance
        case .onlineOnly: preferences.retainOffline=true; savePreferences()
        }
    }
    func resetInterfaceFilters() {
        kind=nil; rootID=nil; scope = .all; sort = .relevance
        if !preferences.retainOffline { preferences.retainOffline=true; savePreferences() }
    }
    private static func volumeName(_ root: IndexedRoot) -> String {
        let parts=URL(fileURLWithPath:root.path).pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : (root.isExternal ? root.name : "这台 Mac")
    }
    func resultLocation(_ hit: SearchHit) -> ResultLocation {
        let parent=URL(fileURLWithPath:hit.path).deletingLastPathComponent()
        let label=parent.path == "/" ? "/" : parent.lastPathComponent
        let volume=Self.volumeName(hit.root)
        return ResultLocation(short:"\(label) · \(volume)",fullPath:hit.path)
    }
    func resultAvailability(_ hit: SearchHit) -> ResultAvailability {
        let volume=Self.volumeName(hit.root)
        let contentMessage=hit.file.contentError ?? (selectedID == hit.id ? previewWarning : nil)
        let state: ResultAvailabilityState
        let text: String?
        if !hit.root.isOnline { state = .diskOffline; text="磁盘「\(volume)」未连接 · 可查看已索引内容" }
        else if PreviewResolver.localURL(for:hit) == nil { state = .fileUnavailable; text="磁盘在线，但文件已移动、删除、未下载或无法读取" }
        else if hit.file.contentState == "error" { state = .extractionFailed; text="内容提取失败 · 文件名仍可搜索" }
        else if selectedID == hit.id && !previewLoading && !previewText.isEmpty && hit.file.fileExtension.lowercased() == "pdf" && previewPDF == nil { state = .indexedOnly; text="原文不可预览 · 显示已索引内容" }
        else if contentMessage != nil { state = .partial; text="仅有部分已索引内容或位置受限" }
        else { state = .available; text=nil }
        return ResultAvailability(state:state,message:text,volumeName:volume,contentMessage:contentMessage)
    }
    func isCurrentResult(_ hit: SearchHit, snapshot: SearchSnapshot? = nil) -> Bool {
        guard let current=currentSnapshot, displayedSnapshot == current,
              current == makeSnapshot(generation:generation),
              snapshot == nil || snapshot == current else { return false }
        return hits.contains { $0.id == hit.id && $0.file.rootID == hit.file.rootID && $0.path == hit.path && $0.file.inode == hit.file.inode && $0.file.modified == hit.file.modified && $0.file.size == hit.file.size }
    }
    /// One gate for every keyboard, row, menu, Quick Look and preview action.
    @discardableResult
    func validateResult(_ hit: SearchHit, for action: FileAction, snapshot: SearchSnapshot? = nil) -> Bool {
        guard isCurrentResult(hit,snapshot:snapshot) else {
            message="搜索条件已变化，请等待当前结果返回后再操作。"; return false
        }
        if action == .copyPath { return true }
        let currentRoot=roots.first { $0.id == hit.root.id } ?? hit.root
        guard currentRoot.isOnline else {
            message="请连接磁盘「\(Self.volumeName(currentRoot))」后再操作此文件。"; return false
        }
        guard PreviewResolver.localURL(for:hit) != nil else {
            message="磁盘在线，但文件已移动、删除、尚未下载或无法读取：\(hit.file.name)。"; return false
        }
        return true
    }
    func fileOperationURL(for hit: SearchHit, action: FileAction, snapshot: SearchSnapshot? = nil) -> URL? {
        validateResult(hit,for:action,snapshot:snapshot) ? URL(fileURLWithPath:hit.path) : nil
    }
    func performFileAction(_ action: FileAction, hit: SearchHit? = nil, snapshot: SearchSnapshot? = nil,
                           line: Int? = nil, pasteboard: NSPasteboard = .general) {
        guard let hit=hit ?? selected, validateResult(hit,for:action,snapshot:snapshot) else { return }
        let url=URL(fileURLWithPath:hit.path)
        switch action {
        case .copyPath:
            pasteboard.clearContents(); pasteboard.setString(hit.path,forType:.string)
        case .copyFile:
            pasteboard.clearContents(); pasteboard.writeObjects([url as NSURL])
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url]); recordOpen(hit.id)
        case .open, .openAtLine:
            if hit.file.kind == .code, let line=line ?? (hit.id == selectedID ? previewLine : nil), CodeFileOpener.open(url,line:line) { recordOpen(hit.id); return }
            if NSWorkspace.shared.open(url) { recordOpen(hit.id) }
            else { message="未能打开此文件，请检查文件是否仍存在。" }
        case .quickLook: AppDelegate.shared?.preview(hit:hit,snapshot:snapshot)
        case .preview: break // URL consumers call fileOperationURL after this same gate.
        }
    }
    func openSelected() { performFileAction(.open) }
    func revealSelected() { performFileAction(.reveal) }
    func copySelectedPath() { performFileAction(.copyPath) }
    func copySelectedFile(to pasteboard:NSPasteboard = .general) { performFileAction(.copyFile,pasteboard:pasteboard) }
    /// Opened results rank higher in later searches (OpenHistory).
    private func recordOpen(_ id:Int64) {
        let engine=nameEngine
        DispatchQueue.global(qos:.utility).async { engine?.recordOpen(id) }
    }
    func moveSelection(_ step:Int) {
        guard !hits.isEmpty else { return }
        let current=hits.firstIndex { $0.id==selectedID } ?? (step>0 ? -1 : hits.count)
        selectedID=hits[min(max(current+step,0),hits.count-1)].id
    }
    func showMainWindow() { openMain?(); if AppDelegate.isBackgroundUITesting {return}; NSApp.activate(ignoringOtherApps:true); NSApp.windows.first(where:{$0.identifier?.rawValue == "main" || $0.title.contains("觅迹")})?.makeKeyAndOrderFront(nil); focusSearch=UUID() }
}
