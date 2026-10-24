import SwiftUI
import AppKit
import MijiCore
import ImageIO

private final class SearchTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var hits: [SearchHit] = []
    @Published var selectedID: Int64? { didSet { loadPreview() } }
    @Published var roots: [IndexedRoot] = []
    @Published var statistics = IndexStatistics()
    @Published var progress = IndexProgress()
    @Published var lastProgressAt: Date?
    @Published var preferences = IndexingPreferences()
    @Published var kind: FileKind? { didSet { scheduleSearch() } }
    @Published var rootID: String? { didSet { scheduleSearch() } }
    @Published var scope = SearchScope.all { didSet { scheduleSearch() } }
    @Published var sort = SearchSort.relevance { didSet { scheduleSearch() } }
    @Published var paused = false
    @Published var searching = false
    @Published var searchMilliseconds:Double = 0
    @Published var message: String?
    @Published var previewText = ""
    @Published var previewImage: NSImage?
    @Published var previewWarning: String?
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
    private var previewVisible = false
    private var activityWork: DispatchWorkItem?
    let service: IndexService?
    private let searchQueue = DispatchQueue(label:"local.miji.search",qos:.userInitiated)
    private let statusQueue = DispatchQueue(label:"local.miji.status",qos:.utility)
    private var searchWork: DispatchWorkItem?
    private var refreshWork: DispatchWorkItem?
    private var searchToken = UUID()
    private var searchTicket: SearchTicket?
    private let lifetimeTicket=SearchTicket()
    private var searchVisible = false
    private var refreshInFlight = false
    private var refreshAgain = false
    private var searchNeedsRefresh = false
    private let searchExecutor: ((SearchDatabase,String,SearchOptions,@escaping () -> Bool) throws -> [SearchHit])?
    private let supplementaryExecutor: ((SearchDatabase,String,SearchOptions,@escaping () -> Bool) throws -> [SearchHit])?
    private var observers: [NSObjectProtocol] = []
    var openMain: (() -> Void)?
    var selected: SearchHit? { hits.first { $0.id == selectedID } }
    static func panelHeight(query: String, resultCount: Int) -> CGFloat {
        query.isEmpty ? 100 : CGFloat(150 + min(7, max(2, resultCount)) * 59)
    }
    var panelHeight: CGFloat { Self.panelHeight(query: query, resultCount: hits.count) }

    init(searchExecutor: ((SearchDatabase,String,SearchOptions,@escaping () -> Bool) throws -> [SearchHit])? = nil,
         supplementaryExecutor: ((SearchDatabase,String,SearchOptions,@escaping () -> Bool) throws -> [SearchHit])? = nil) {
        self.searchExecutor=searchExecutor
        self.supplementaryExecutor=supplementaryExecutor
        let env=ProcessInfo.processInfo.environment
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
            DispatchQueue.main.async {
                guard let self,!self.lifetimeTicket.isCancelled,let engine=self.nameEngine else { return }
                let lifetime=self.lifetimeTicket
                self.searchQueue.async { [weak self] in
                    guard !lifetime.isCancelled else {return}
                    do {
                        try engine.refresh(rootID:change.rootID,relativePaths:change.relativePaths,fullRescan:change.fullRescan,cancelled:{lifetime.isCancelled})
                    }
                    catch {
                        guard !lifetime.isCancelled else {return}
                        do { try engine.load(cancelled:{lifetime.isCancelled}); Self.completeUpgrade(engine,lifetime:lifetime) }
                        catch { if !lifetime.isCancelled {DispatchQueue.main.async { self?.message=error.localizedDescription }} }
                    }
                }
            }
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
        lifetimeTicket.cancel();searchTicket?.cancel();searchWork?.cancel();refreshWork?.cancel();activityWork?.cancel()
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
                    guard let self else { return }
                    self.roots=roots; self.statistics=stats
                    self.finishRefresh()
                    if self.searchVisible && !self.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        if self.searching || self.searchWork != nil { self.searchNeedsRefresh=true }
                        else { self.scheduleSearch() }
                    }
                }
            } catch { DispatchQueue.main.async { self?.message=error.localizedDescription; self?.finishRefresh() } }
        }
    }
    private func finishRefresh() {
        refreshInFlight=false
        if refreshAgain { refreshAgain=false; scheduleRefresh() }
    }
    func setSearchVisible(_ visible:Bool) {
        searchVisible=visible
        scheduleSearch()
        if visible { scheduleRefresh() }
    }
    func scheduleSearch() {
        searchWork?.cancel(); searchWork=nil; searchTicket?.cancel(); searching=false; searchNeedsRefresh=false
        activityWork?.cancel()
        let token=UUID(); searchToken=token
        guard searchVisible, !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            service?.setUserActive(false)
            if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { hits=[]; selectedID=nil; searchMilliseconds=0 }
            return
        }
        service?.setUserActive(true)
        let release=DispatchWorkItem { [weak self] in self?.service?.setUserActive(false) }
        activityWork=release; DispatchQueue.main.asyncAfter(deadline:.now()+0.8,execute:release)
        let ticket=SearchTicket(); searchTicket=ticket
        let text=query; let options=SearchOptions(kind:kind,rootID:rootID,scope:scope,sort:sort,onlineOnly:!preferences.retainOffline,limit:500)
        let typedAt=Date()
        let item=DispatchWorkItem { [weak self] in
            guard let self, !ticket.isCancelled, let database=self.searchDatabase else { return }
            self.searchWork=nil; self.searching=true
            let execute=self.searchExecutor, engine=self.nameEngine
            self.searchQueue.async { [weak self] in
                guard !ticket.isCancelled else { return }
                do {
                    if let execute {
                        let result=try execute(database,text,options,{ticket.isCancelled})
                        DispatchQueue.main.async { self?.publish(result,token:token,ticket:ticket,elapsed:Date().timeIntervalSince(typedAt)*1000,finished:true) }
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
                    DispatchQueue.main.async {
                        guard let self,self.searchToken==token,!ticket.isCancelled else { return }
                        let finished=options.scope == .name || (options.scope == .all && options.sort == .relevance && names.count>=options.limit)
                        self.publish(names,token:token,ticket:ticket,elapsed:options.scope == .name || !names.isEmpty ? Date().timeIntervalSince(typedAt)*1000 : nil,finished:finished)
                        guard !finished,let contentDatabase=self.contentDatabase else { return }
                        let supplement=self.supplementaryExecutor
                        self.contentQueue.async { [weak self] in
                            guard !ticket.isCancelled else { return }
                            do {
                                func merge(_ extra:[SearchHit])->[SearchHit] {
                                    let decorated=Dictionary(uniqueKeysWithValues:extra.map {($0.id,$0)})
                                    var ids=Set(names.map(\.id))
                                    var merged=names.map {decorated[$0.id] ?? $0} + extra.filter { ids.insert($0.id).inserted }
                                    if options.sort != .relevance {
                                        merged.sort {
                                            if options.sort == .modified && $0.file.modified != $1.file.modified { return $0.file.modified > $1.file.modified }
                                            if options.sort == .size && $0.file.size != $1.file.size { return $0.file.size > $1.file.size }
                                            let a=$0.file.name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                                            let b=$1.file.name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                                            return a == b ? $0.id < $1.id : a < b
                                        }
                                    }
                                    return Array(merged.prefix(options.limit))
                                }
                                var deliveredPartial=false
                                let extra:[SearchHit]
                                if let supplement {extra=try supplement(contentDatabase,text,options,{ticket.isCancelled})}
                                else {
                                    extra=try contentDatabase.searchSupplementary(text,options:options,cancelled:{ticket.isCancelled},onPartial:{ partial in
                                        guard !ticket.isCancelled else {return}
                                        let result=merge(partial)
                                        let elapsed=names.isEmpty && !deliveredPartial ? Date().timeIntervalSince(typedAt)*1000 : nil
                                        deliveredPartial=true
                                        DispatchQueue.main.async {self?.publish(result,token:token,ticket:ticket,elapsed:elapsed,finished:false)}
                                    })
                                }
                                let result=merge(extra)
                                let elapsed=names.isEmpty && !deliveredPartial ? Date().timeIntervalSince(typedAt)*1000 : nil
                                DispatchQueue.main.async { self?.publish(result,token:token,ticket:ticket,elapsed:elapsed,finished:true) }
                            } catch { DispatchQueue.main.async { self?.searchFailed(error,token:token,ticket:ticket) } }
                        }
                    }
                } catch { DispatchQueue.main.async { self?.searchFailed(error,token:token,ticket:ticket) } }
            }
        }
        searchWork=item; DispatchQueue.main.asyncAfter(deadline:.now()+0.035,execute:item)
    }
    private func publish(_ result:[SearchHit],token:UUID,ticket:SearchTicket,elapsed:Double?,finished:Bool) {
        guard searchToken==token,!ticket.isCancelled else { return }
        hits=result; searching = !finished
        if let elapsed { searchMilliseconds=elapsed }
        if !result.contains(where:{$0.id==selectedID}) { selectedID=result.first?.id }
        if finished && searchNeedsRefresh { scheduleSearch() }
    }
    private func searchFailed(_ error:Error,token:UUID,ticket:SearchTicket) {
        guard searchToken==token,!ticket.isCancelled else { return }
        searching=false
        if !(error is CancellationError) { message=error.localizedDescription }
    }
    func setPreviewVisible(_ visible:Bool) { previewVisible=visible; loadPreview() }
    func loadPreview() {
        previewText=""; previewImage=nil; previewWarning=nil
        guard previewVisible,let hit=selected,let database=previewDatabase else { return }
        let id=hit.id
        previewQueue.async { [weak self] in
            let content=try? database.storedContent(fileID:id)
            var thumbnail:NSImage?
            if hit.file.kind == .image && hit.root.isOnline,
               let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:hit.path) as CFURL,nil),
               let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:700,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) { thumbnail=NSImage(cgImage:cg,size:.zero) }
            DispatchQueue.main.async {
                guard let self,self.previewVisible,self.selectedID==id else { return }
                self.previewText=String((content?.text ?? hit.snippet).prefix(16000)); self.previewImage=thumbnail; self.previewWarning=content?.warning
            }
        }
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
        service?.configure(preferences); scheduleSearch()
    }
    func togglePause() { paused.toggle(); service?.setPaused(paused) }
    func openSelected() {
        guard let hit=selected else { return }
        guard hit.root.isOnline, FileManager.default.fileExists(atPath:hit.path) else { message="请连接「\(hit.root.name)」后打开此文件。"; return }
        if !NSWorkspace.shared.open(URL(fileURLWithPath:hit.path)) { message="未能打开此文件，请检查文件是否仍存在。"; return }
        recordOpen(hit.id)
    }
    func revealSelected() {
        guard let hit=selected,hit.root.isOnline else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:hit.path)])
        recordOpen(hit.id)
    }
    /// Opened results rank higher in later searches (OpenHistory).
    private func recordOpen(_ id:Int64) {
        let engine=nameEngine
        DispatchQueue.global(qos:.utility).async { engine?.recordOpen(id) }
    }
    func copySelectedPath() { guard let hit=selected else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hit.path,forType:.string) }
    func moveSelection(_ step:Int) {
        guard !hits.isEmpty else { return }
        let current=hits.firstIndex { $0.id==selectedID } ?? (step>0 ? -1 : hits.count)
        selectedID=hits[min(max(current+step,0),hits.count-1)].id
    }
    func showMainWindow() { openMain?(); NSApp.activate(ignoringOtherApps:true); NSApp.windows.first(where:{$0.identifier?.rawValue == "main" || $0.title.contains("觅迹")})?.makeKeyAndOrderFront(nil); focusSearch=UUID() }
}
