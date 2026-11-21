import XCTest
import MijiCore
@testable import MijiApp

final class SearchSchedulingTests: XCTestCase {
    @MainActor
    func testFullNamePageStillRunsSupplementaryContentQuery() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldDirectory=getenv("MIJI_DATA_DIR").map {String(cString:$0)},oldAuto=getenv("MIJI_NO_AUTOSTART").map {String(cString:$0)}
        setenv("MIJI_DATA_DIR",directory.path,1);setenv("MIJI_NO_AUTOSTART","1",1)
        defer {
            if let oldDirectory {setenv("MIJI_DATA_DIR",oldDirectory,1)} else {unsetenv("MIJI_DATA_DIR")}
            if let oldAuto {setenv("MIJI_NO_AUTOSTART",oldAuto,1)} else {unsetenv("MIJI_NO_AUTOSTART")}
            try? FileManager.default.removeItem(at:directory)
        }
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles((0..<501).map {i in
            let name="README-\(i).txt"
            return FileRecord(rootID:"r",relativePath:name,name:name,fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)
        },generation:1)
        let supplementary=expectation(description:"名称满页仍检索正文");supplementary.assertForOverFulfill=false
        let model=AppModel(supplementaryExecutor:{_,_,_,_ in supplementary.fulfill();return []})
        defer {model.service?.stop()}
        model.setSearchVisible(true);model.query="README"
        for _ in 0..<300 where model.hits.count<500 || model.searching {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.hits.count,500);XCTAssertFalse(model.searching)
        await fulfillment(of:[supplementary],timeout:1)
    }
    @MainActor
    func testBodyExclusionsDoNotHideNameCandidateBeyondFirstPage() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldDirectory=getenv("MIJI_DATA_DIR").map {String(cString:$0)},oldAuto=getenv("MIJI_NO_AUTOSTART").map {String(cString:$0)}
        setenv("MIJI_DATA_DIR",directory.path,1);setenv("MIJI_NO_AUTOSTART","1",1)
        defer {
            if let oldDirectory {setenv("MIJI_DATA_DIR",oldDirectory,1)} else {unsetenv("MIJI_DATA_DIR")}
            if let oldAuto {setenv("MIJI_NO_AUTOSTART",oldAuto,1)} else {unsetenv("MIJI_NO_AUTOSTART")}
            try? FileManager.default.removeItem(at:directory)
        }
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        let files=(0...500).map {i -> FileRecord in
            let name=String(format:"needle-%04d.txt",i)
            return FileRecord(rootID:"r",relativePath:name,name:name,fileExtension:"txt",kind:.document,size:1,modified:1,inode:Int64(i+1))
        }
        try db.upsertFiles(files,generation:1)
        for file in try db.pendingFiles(rootID:"r",limit:501) where file.name != "needle-0500.txt" {
            XCTAssertTrue(try db.completeContent(file:file,content:ExtractedContent(text:"blocked")))
        }
        let model=AppModel();defer {model.service?.stop()}
        model.setSearchVisible(true);model.query="needle -blocked"
        for _ in 0..<300 where model.hits.isEmpty {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.hits.map(\.file.name),["needle-0500.txt"])
    }

    @MainActor
    func testNamesAndNewInputStayResponsiveWhileFullTextIsBlocked() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("miji-first-screen-\(UUID().uuidString)")
        let oldDirectory=ProcessInfo.processInfo.environment["MIJI_DATA_DIR"],oldAuto=ProcessInfo.processInfo.environment["MIJI_NO_AUTOSTART"]
        setenv("MIJI_DATA_DIR",directory.path,1); setenv("MIJI_NO_AUTOSTART","1",1)
        let gate=FirstSnapshotGate()
        defer {
            gate.resume.signal()
            if let oldDirectory {setenv("MIJI_DATA_DIR",oldDirectory,1)} else {unsetenv("MIJI_DATA_DIR")}
            if let oldAuto {setenv("MIJI_NO_AUTOSTART",oldAuto,1)} else {unsetenv("MIJI_NO_AUTOSTART")}
            try? FileManager.default.removeItem(at:directory)
        }
        let database=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=IndexedRoot(id:"root",path:directory.path);try database.saveRoot(root)
        try database.upsertFiles(["数学分析.pdf","README.txt"].map { FileRecord(rootID:root.id,relativePath:$0,name:$0,fileExtension:URL(fileURLWithPath:$0).pathExtension,kind:.document,size:1,modified:1,inode:1) },generation:1)
        let model=AppModel(supplementaryExecutor:{ database,query,options,cancelled in
            gate.holdFirst()
            return try database.searchSupplementary(query,options:options,cancelled:cancelled)
        })
        defer {model.service?.stop()}
        model.previewEnabled=false
        model.setSearchVisible(true); model.query="数学"
        for _ in 0..<100 where !gate.isCaptured {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(gate.isCaptured)
        XCTAssertEqual(model.hits.map(\.file.name),["数学分析.pdf"])
        XCTAssertTrue(model.searching,"全文尚未返回，文件名首屏应已显示")
        XCTAssertTrue(model.previewText.isEmpty,"没有打开内容面板时不加载正文")
        let start=Date(); model.query="README"
        for _ in 0..<100 where model.hits.first?.file.name != "README.txt" {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.hits.map(\.file.name),["README.txt"])
        XCTAssertLessThan(Date().timeIntervalSince(start),0.5,"新的文件名查询不应排在旧全文任务后")
        gate.resume.signal()
        for _ in 0..<100 where model.searching {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.hits.map(\.file.name),["README.txt"],"旧查询不能覆盖新查询")
    }

    private final class FirstSnapshotGate: @unchecked Sendable {
        let resume = DispatchSemaphore(value:0)
        private let lock = NSLock()
        private var captured = false
        var isCaptured: Bool {lock.lock();defer{lock.unlock()};return captured}
        func holdFirst() {
            lock.lock();let first = !captured;captured=true;lock.unlock()
            if first { _ = resume.wait(timeout:.now()+5) }
        }
    }

    private final class SearchAttempts: @unchecked Sendable {
        let resume = DispatchSemaphore(value:0)
        private let lock = NSLock()
        private var attempts = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
        func begin(blocking blockedAttempt:Int? = nil) {
            lock.lock(); attempts += 1; let current=attempts; lock.unlock()
            if current == blockedAttempt { _=resume.wait(timeout:.now()+5) }
        }
    }

    @MainActor
    private func waitUntil(_ message:String,timeout:TimeInterval = 2,_ predicate:() -> Bool) async throws {
        let deadline=Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(predicate(),message)
    }

    @MainActor
    private func withIsolatedDirectory(_ test:(URL) async throws -> Void) async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("miji-search-refresh-\(UUID().uuidString)")
        let oldDirectory=getenv("MIJI_DATA_DIR").map {String(cString:$0)}
        let oldAutoStart=getenv("MIJI_NO_AUTOSTART").map {String(cString:$0)}
        setenv("MIJI_DATA_DIR",directory.path,1)
        setenv("MIJI_NO_AUTOSTART","1",1)
        defer {
            if let oldDirectory { setenv("MIJI_DATA_DIR",oldDirectory,1) } else { unsetenv("MIJI_DATA_DIR") }
            if let oldAutoStart { setenv("MIJI_NO_AUTOSTART",oldAutoStart,1) } else { unsetenv("MIJI_NO_AUTOSTART") }
            try? FileManager.default.removeItem(at:directory)
        }
        try await test(directory)
    }

    @MainActor
    func testContentCommittedDuringQueryRefreshesWithoutChangingQuery() async throws {
        try await withIsolatedDirectory { directory in
            let gate=FirstSnapshotGate()
            defer { gate.resume.signal() }
            let database=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
            let root=IndexedRoot(path:directory.path);try database.saveRoot(root)
            let names=["old.txt","new.txt"]
            try database.upsertFiles(names.map { name in
                FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)
            },generation:1)
            let pending=try database.pendingFiles(rootID:root.id)
            let old=try XCTUnwrap(pending.first { $0.name == names[0] })
            let new=try XCTUnwrap(pending.first { $0.name == names[1] })
            XCTAssertTrue(try database.completeContent(file:old,content:ExtractedContent(text:"uniquefixturetoken")))
            let model=AppModel(searchExecutor:{ database,query,options,cancelled in
                let snapshot=try database.search(query,options:options,cancelled:cancelled)
                gate.holdFirst()
                return snapshot
            })
            model.service?.stop()
            model.scope = .content
            model.setSearchVisible(true);model.query="uniquefixturetoken"
            try await waitUntil("原查询已读到提交前的正文") { gate.isCaptured }
            let snapshot=model.currentSnapshot
            XCTAssertTrue(try database.completeContent(file:old,content:ExtractedContent(text:"replacement")))
            XCTAssertTrue(try database.completeContent(file:new,content:ExtractedContent(text:"uniquefixturetoken")))
            model.service?.onContentChange?()
            try await Task.sleep(nanoseconds:350_000_000)
            XCTAssertTrue(model.searching)
            gate.resume.signal()
            try await waitUntil("静置的查询收到新命中并移除旧正文命中") { model.hits.map(\.id) == [new.id] }
            XCTAssertEqual(model.currentSnapshot,snapshot)
        }
    }

    @MainActor
    func testSameFileBodyChangeRefreshesNamePreviewWithoutResettingQuery() async throws {
        try await withIsolatedDirectory { directory in
            let database=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
            let root=IndexedRoot(path:directory.path);try database.saveRoot(root)
            try database.upsertFiles([FileRecord(rootID:root.id,relativePath:"report.txt",name:"report.txt",fileExtension:"txt",kind:.document,size:1,modified:1)],generation:1)
            let file=try XCTUnwrap(database.pendingFiles(rootID:root.id).first)
            XCTAssertTrue(try database.completeContent(file:file,content:ExtractedContent(text:"old selected body")))
            let model=AppModel();model.service?.stop()
            model.scope = .name; model.previewEnabled=true
            model.setSearchVisible(true);model.query="report"
            try await waitUntil("名称命中的原正文预览") { model.previewText.contains("old selected body") }
            let snapshot=model.displayedSnapshot, timing=model.completedMilliseconds
            XCTAssertTrue(try database.completeContent(file:file,content:ExtractedContent(text:"new selected body")))
            model.service?.onContentChange?()
            try await waitUntil("同一路径与签名的名称命中已刷新正文预览") { model.previewText.contains("new selected body") }
            XCTAssertEqual(model.selectedID,file.id)
            XCTAssertEqual(model.displayedSnapshot,snapshot)
            XCTAssertEqual(model.completedMilliseconds,timing)
        }
    }

    @MainActor
    func testCatalogBurstPublishesNamesWhileBodySearchWaitsAndPreservesSelection() async throws {
        try await withIsolatedDirectory { directory in
            let attempts=SearchAttempts()
            defer { attempts.resume.signal() }
            let database=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
            let root=IndexedRoot(path:directory.path);try database.saveRoot(root)
            func record(_ name:String)->FileRecord {
                FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)
            }
            try database.upsertFiles([record("body.txt")],generation:1)
            let body=try XCTUnwrap(database.pendingFiles(rootID:root.id).first)
            XCTAssertTrue(try database.completeContent(file:body,content:ExtractedContent(text:"needle body is already visible")))
            let model=AppModel(supplementaryExecutor:{ database,query,options,cancelled in
                attempts.begin(blocking:2)
                return try database.searchSupplementary(query,options:options,cancelled:cancelled)
            })
            model.service?.stop()
            model.previewEnabled=true
            model.setSearchVisible(true);model.query="needle"
            try await waitUntil("首轮正文与预览均已完成") { !model.searching && !model.previewText.isEmpty }
            let selected=try XCTUnwrap(model.selected)
            let snapshot=model.displayedSnapshot, timing=model.completedMilliseconds, preview=model.previewText
            let newName="needle-new.txt"
            try database.upsertFiles([record(newName)],generation:1)
            for _ in 0..<8 {
                model.service?.onIndexChange?(IndexChange(rootID:root.id,relativePaths:[newName],fullRescan:false))
                model.service?.onContentChange?()
            }
            try await waitUntil("自动刷新中的文件名首屏已更新") {
                attempts.count == 2 && model.hits.contains { $0.file.name == newName }
            }
            XCTAssertEqual(model.searchPhase,.complete)
            XCTAssertEqual(model.displayedSnapshot,snapshot)
            XCTAssertEqual(model.completedMilliseconds,timing)
            XCTAssertEqual(model.selectedID,selected.id)
            XCTAssertEqual(model.previewText,preview)
            XCTAssertTrue(model.validateResult(selected,for:.copyPath,snapshot:snapshot))
            attempts.resume.signal()
            try await Task.sleep(nanoseconds:350_000_000)
            XCTAssertEqual(attempts.count,2,"一个提交窗口只补查一次")
            model.setSearchVisible(false)
            let hiddenName="needle-hidden.txt"
            try database.upsertFiles([record(hiddenName)],generation:1)
            model.service?.onIndexChange?(IndexChange(rootID:root.id,relativePaths:[hiddenName],fullRescan:false))
            try await Task.sleep(nanoseconds:350_000_000)
            XCTAssertEqual(attempts.count,2)
            XCTAssertFalse(model.hits.contains { $0.file.name == hiddenName })
            model.setSearchVisible(true)
            try await waitUntil("重新显示时读取隐藏期间提交的索引") {
                attempts.count == 3 && model.hits.contains { $0.file.name == hiddenName }
            }
        }
    }

    @MainActor
    func testStatisticsNotifyWithoutSchedulingAnotherVisibleQuery() async throws {
        try await withIsolatedDirectory { directory in
            let attempts=SearchAttempts()
            let database=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
            let root=IndexedRoot(path:directory.path);try database.saveRoot(root)
            let model=AppModel(searchExecutor:{ _,_,_,_ in attempts.begin(); return [] })
            model.service?.stop()
            model.setSearchVisible(true);model.query="needle"
            try await waitUntil("用户查询已完成") { model.searchPhase == .complete }
            let snapshot=model.displayedSnapshot
            try database.upsertFiles([FileRecord(rootID:root.id,relativePath:"extra.txt",name:"extra.txt",fileExtension:"txt",kind:.document,size:1,modified:1)],generation:1)
            for _ in 0..<8 { model.service?.onChange?() }
            try await waitUntil("统计通知更新计数",timeout:3) { model.statistics.files == 1 }
            try await Task.sleep(nanoseconds:100_000_000)
            XCTAssertEqual(attempts.count,1)
            XCTAssertEqual(model.displayedSnapshot,snapshot)
        }
    }
    @MainActor
    func testEmptyQueryDoesNotPopulateHiddenResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("miji-app-test-\(UUID().uuidString)")
        let oldDirectory = ProcessInfo.processInfo.environment["MIJI_DATA_DIR"]
        let oldAutoStart = ProcessInfo.processInfo.environment["MIJI_NO_AUTOSTART"]
        setenv("MIJI_DATA_DIR", directory.path, 1)
        setenv("MIJI_NO_AUTOSTART", "1", 1)
        defer {
            if let oldDirectory { setenv("MIJI_DATA_DIR",oldDirectory,1) } else { unsetenv("MIJI_DATA_DIR") }
            if let oldAutoStart { setenv("MIJI_NO_AUTOSTART",oldAutoStart,1) } else { unsetenv("MIJI_NO_AUTOSTART") }
            try? FileManager.default.removeItem(at:directory)
        }
        let database = try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root = IndexedRoot(path:directory.path)
        try database.saveRoot(root)
        try database.upsertFiles([FileRecord(rootID:root.id,relativePath:"fixture.txt",name:"fixture.txt",fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)],generation:1)
        let model = AppModel()
        defer { model.service?.stop() }
        try await Task.sleep(nanoseconds:1_000_000_000)
        XCTAssertEqual(model.statistics.files,1)
        XCTAssertTrue(model.hits.isEmpty,"空搜索框不应执行全库排序并载入隐藏结果")
        XCTAssertFalse(model.searching)
        model.setSearchVisible(true)
        model.query="fixture"
        for _ in 0..<60 where model.hits.isEmpty { try await Task.sleep(nanoseconds:50_000_000) }
        XCTAssertEqual(model.hits.count,1,"显示窗口时正常搜索")
        model.setSearchVisible(false)
        model.query="not-present"
        try await Task.sleep(nanoseconds:500_000_000)
        XCTAssertEqual(model.hits.count,1,"隐藏窗口保留原结果，不重新查询")
        XCTAssertFalse(model.searching)
        model.setSearchVisible(true)
        for _ in 0..<60 where !model.hits.isEmpty { try await Task.sleep(nanoseconds:50_000_000) }
        XCTAssertTrue(model.hits.isEmpty,"重新唤起时查询最新关键词")
        model.query="   "
        model.refresh()
        try await Task.sleep(nanoseconds:500_000_000)
        XCTAssertTrue(model.hits.isEmpty,"空白与状态刷新不会恢复全库查询")
    }
}
