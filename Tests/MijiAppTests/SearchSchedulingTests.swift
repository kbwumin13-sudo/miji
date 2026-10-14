import XCTest
import MijiCore
@testable import MijiApp

final class SearchSchedulingTests: XCTestCase {
    @MainActor
    func testFullNamePageDoesNotRunUnusedGlobalContentQuery() async throws {
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
        let model=AppModel(supplementaryExecutor:{_,_,_,_ in XCTFail("500个文件名已占满默认结果页，无需再全库找正文");return []})
        defer {model.service?.stop()}
        model.setSearchVisible(true);model.query="README"
        for _ in 0..<300 where model.hits.count<500 || model.searching {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.hits.count,500);XCTAssertFalse(model.searching)
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
    @MainActor
    func testContentCommittedDuringQueryRefreshesWithoutChangingQuery() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("miji-query-refresh-\(UUID().uuidString)")
        let oldDirectory=ProcessInfo.processInfo.environment["MIJI_DATA_DIR"]
        let oldAutoStart=ProcessInfo.processInfo.environment["MIJI_NO_AUTOSTART"]
        setenv("MIJI_DATA_DIR",directory.path,1);setenv("MIJI_NO_AUTOSTART","1",1)
        let gate=FirstSnapshotGate()
        defer {
            gate.resume.signal()
            if let oldDirectory{setenv("MIJI_DATA_DIR",oldDirectory,1)}else{unsetenv("MIJI_DATA_DIR")}
            if let oldAutoStart{setenv("MIJI_NO_AUTOSTART",oldAutoStart,1)}else{unsetenv("MIJI_NO_AUTOSTART")}
            try? FileManager.default.removeItem(at:directory)
        }
        let database=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=IndexedRoot(path:directory.path);try database.saveRoot(root)
        func record(_ name:String)->FileRecord {FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)}
        try database.upsertFiles([record("fixture-one.txt")],generation:1)
        let model=AppModel(searchExecutor:{ database,query,options,cancelled in
            let snapshot=try database.search(query,options:options,cancelled:cancelled)
            gate.holdFirst()
            return snapshot
        })
        defer{model.service?.stop()}
        for _ in 0..<60 where model.statistics.files != 1 {try await Task.sleep(nanoseconds:50_000_000)}
        model.setSearchVisible(true);model.query="fixture"
        for _ in 0..<60 where !gate.isCaptured {try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertTrue(gate.isCaptured)
        try database.upsertFiles([record("fixture-two.txt")],generation:1)
        model.refresh()
        for _ in 0..<60 where model.statistics.files != 2 {try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertEqual(model.statistics.files,2);XCTAssertTrue(model.searching)
        gate.resume.signal()
        for _ in 0..<60 where model.hits.count != 2 {try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertEqual(model.hits.count,2,"查询期间到达的最后一次内容刷新必须在完成后补查")
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
