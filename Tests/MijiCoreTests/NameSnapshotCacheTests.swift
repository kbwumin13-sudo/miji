import XCTest
import CSQLite
import CryptoKit
@testable import MijiCore

final class NameSnapshotCacheTests:XCTestCase {
    func testEmptyCacheNumericColumnsRoundTrip() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        let engine=try NameSearchEngine(databaseURL:url);try engine.load();try engine.saveCache()
        let snapshot=try NameSnapshotCache.load(database:url,revision:0)
        XCTAssertEqual(snapshot.ids.count,0)
        XCTAssertEqual(snapshot.core.count,0)
        let restarted=try NameSearchEngine(databaseURL:url);try restarted.load()
        XCTAssertEqual(try restarted.search("anything"),[])
    }
    func testChecksummedInvalidNumericColumnLengthsAreRejected() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path));try db.upsertFiles([file("correct.txt")],generation:1)
        let engine=try NameSearchEngine(databaseURL:url);try engine.load();try engine.saveCache()
        let cache=NameSnapshotCache.url(for:url),original=try Data(contentsOf:cache)
        let headerSize=original.withUnsafeBytes {$0.loadUnaligned(fromByteOffset:8,as:UInt64.self).littleEndian}
        let firstColumn=16+Int(headerSize)
        for length in [UInt64(7),UInt64.max] {
            var bytes=original
            for i in 0..<8 {bytes[firstColumn+i]=UInt8(truncatingIfNeeded:length >> (i*8))}
            bytes.replaceSubrange((bytes.count-32)..<bytes.count,with:Data(SHA256.hash(data:bytes.dropLast(32))))
            try bytes.write(to:cache)
            XCTAssertThrowsError(try NameSnapshotCache.load(database:url,revision:1))
            let recovered=try NameSearchEngine(databaseURL:url);try recovered.load()
            XCTAssertEqual(try recovered.search("correct").count,1)
        }
    }
    func testStartupCompactsRenameTombstonesAndDoesNotRewriteCleanCache() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles((0..<17_000).map {file("old-\($0).txt")},generation:1)
        let first=try NameSearchEngine(databaseURL:url);try first.load();try first.saveCache()
        let cacheURL=NameSnapshotCache.url(for:url)
        let before=try FileManager.default.attributesOfItem(atPath:cacheURL.path)[.systemFileNumber] as? NSNumber
        let clean=try NameSearchEngine(databaseURL:url);try clean.load();try clean.saveCache()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:cacheURL.path)[.systemFileNumber] as? NSNumber,before)
        try db.execute("UPDATE files SET name='renamed-'||name")
        let restarted=try NameSearchEngine(databaseURL:url);try restarted.load();try restarted.saveCache()
        let compact=try NameSnapshotCache.load(database:url,revision:34_000)
        XCTAssertEqual(compact.liveCount,17_000)
        XCTAssertEqual(compact.ids.count,17_000,"关闭期间反复改名不能使持久缓存累积墓碑")
        XCTAssertEqual(try restarted.search("renamed",options:SearchOptions(limit:20_000)).count,17_000)
    }
    func testCacheRoundTripAppliesJournalAndKeepsDeletedRowsDeleted() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles([file("数学分析.txt"),file("old.txt")],generation:1)
        let engine=try NameSearchEngine(databaseURL:url);try engine.load();try engine.saveCache()
        let initial=try NameSnapshotCache.load(database:url,revision:2)
        XCTAssertEqual(initial.liveCount,2)
        try db.finishIncrementalScan(rootID:"r",relativePath:"old.txt",generation:2)
        try db.upsertFiles([file("README.txt")],generation:2)
        let restarted=try NameSearchEngine(databaseURL:url);try restarted.load()
        XCTAssertEqual(try restarted.search("shuxue").count,1)
        XCTAssertEqual(try restarted.search("README").count,1)
        XCTAssertTrue(try restarted.search("old").isEmpty)
        // Save after a rename/upsert adds a tail entry and a tombstone.
        try db.execute("UPDATE files SET name='New数学.txt' WHERE name='数学分析.txt'")
        try restarted.refresh(rootID:"r",relativePaths:[""],fullRescan:true)
        try restarted.saveCache()
        let again=try NameSearchEngine(databaseURL:url);try again.load()
        XCTAssertEqual(try again.search("New数学").count,1)
        XCTAssertTrue(try again.search("数学分析").isEmpty)
        XCTAssertEqual(try again.search("README").count,1)
    }
    func testCorruptOrOtherDatabaseCacheFallsBackToSQLite() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite")
        let db=try SearchDatabase(url:url);try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles([file("correct.txt")],generation:1)
        let first=try NameSearchEngine(databaseURL:url);try first.load();try first.saveCache()
        let cache=NameSnapshotCache.url(for:url)
        var bytes=try Data(contentsOf:cache);bytes[bytes.count/2] ^= 0xff;try bytes.write(to:cache)
        let recovered=try NameSearchEngine(databaseURL:url);try recovered.load();try recovered.saveCache()
        XCTAssertEqual(try recovered.search("correct").count,1)
        let otherURL=directory.appendingPathComponent("other.sqlite"),other=try SearchDatabase(url:directory.appendingPathComponent("other.sqlite"))
        try other.saveRoot(IndexedRoot(id:"r",path:directory.path));try other.upsertFiles([file("different.txt")],generation:1)
        try FileManager.default.copyItem(at:cache,to:NameSnapshotCache.url(for:otherURL))
        let replacement=try NameSearchEngine(databaseURL:otherURL);try replacement.load()
        XCTAssertTrue(try replacement.search("correct").isEmpty)
        XCTAssertEqual(try replacement.search("different").count,1)
    }
    private func file(_ name:String)->FileRecord {
        FileRecord(rootID:"r",relativePath:name,name:name,fileExtension:"txt",kind:.document,size:1,modified:1,inode:1)
    }
}
