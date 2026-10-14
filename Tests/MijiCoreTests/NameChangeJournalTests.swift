import XCTest
import CSQLite
@testable import MijiCore

final class NameChangeJournalTests:XCTestCase {
    func testReopeningDatabaseReplacesObsoleteJournalTrigger() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite")
        do {
            let db=try SearchDatabase(url:url)
            try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
            try db.upsertFiles([FileRecord(rootID:"r",relativePath:"file.txt",name:"file.txt",fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)],generation:1)
            try db.execute("DROP TRIGGER names_update; CREATE TRIGGER names_update AFTER UPDATE OF size ON files BEGIN UPDATE catalog_state SET revision=revision+1 WHERE id=1; INSERT OR REPLACE INTO name_changes(file_id,revision) VALUES(new.id,(SELECT revision FROM catalog_state WHERE id=1)); END;")
        }
        let reopened=try SearchDatabase(url:url)
        try reopened.upsertFiles([FileRecord(rootID:"r",relativePath:"file.txt",name:"file.txt",fileExtension:"txt",kind:.document,size:2,modified:2,inode:1)],generation:2)
        XCTAssertEqual(try reopened.pendingFiles(rootID:"r").first?.size,2)
    }

    func testFullScanDescendsNestedFolderAfterOrdinaryFiles() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let source=directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        for i in 0..<20 {try Data("text".utf8).write(to:source.appendingPathComponent("file\(i).txt"))}
        let child=source.appendingPathComponent("课程 资料/下层")
        try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        try Data("不可遗漏".utf8).write(to:child.appendingPathComponent("数学.txt"))
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=try VolumeIdentity.root(for:source);try db.saveRoot(root)
        let result=try FileScanner(database:db).scan(root:root)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.count,23)
        XCTAssertEqual(try db.search("数学",options:SearchOptions(scope:.name)).first?.file.relativePath,"课程 资料/下层/数学.txt")
    }

    func testChangedIDsRefreshNamesWithoutWholeRootReconciliation() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        func file(_ name:String)->FileRecord {FileRecord(rootID:"r",relativePath:name,name:name,fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)}
        try db.upsertFiles([file("keep.txt"),file("gone.txt")],generation:1)
        let engine=try NameSearchEngine(databaseURL:url);try engine.load()
        let keep=try XCTUnwrap(db.pendingFiles(rootID:"r").first {$0.name=="keep.txt"})
        XCTAssertTrue(try db.completeContent(file:keep,content:ExtractedContent(text:"正文不会改变名称游标")))
        try db.upsertFiles([file("keep.txt")],generation:2)
        let revision=try db.prepare("SELECT revision FROM catalog_state")
        XCTAssertTrue(try db.next(revision));XCTAssertEqual(sqlite3_column_int(revision,0),2)
        sqlite3_finalize(revision)
        try db.finishIncrementalScan(rootID:"r",relativePath:"gone.txt",generation:2)
        try db.upsertFiles([file("new.txt")],generation:2)
        // Any notification drains the committed journal, including a deletion
        // outside the notified path, without keeping full paths in memory.
        try engine.refresh(rootID:"r",relativePaths:["new.txt"],fullRescan:false)
        XCTAssertTrue(try engine.search("gone").isEmpty)
        XCTAssertEqual(try engine.search("new").count,1)
        XCTAssertEqual(try engine.search("keep"),[keep.id])
        try db.removeRoot(id:"r")
        try engine.refresh(rootID:"r",relativePaths:[""],fullRescan:true)
        XCTAssertTrue(try engine.search("").isEmpty)
    }

    func testPrunedJournalGapFallsBackToCompleteMetadataSnapshot() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        let engine=try NameSearchEngine(databaseURL:url);try engine.load()
        try db.execute("UPDATE catalog_state SET revision=100001")
        try db.upsertFiles([FileRecord(rootID:"r",relativePath:"after-gap.txt",name:"after-gap.txt",fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)],generation:1)
        try engine.refresh(rootID:"r",relativePaths:["unrelated"],fullRescan:false)
        XCTAssertEqual(try engine.search("after-gap").count,1)
    }
}
