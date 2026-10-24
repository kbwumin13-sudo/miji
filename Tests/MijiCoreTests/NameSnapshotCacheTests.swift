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
        // Version 1, as written by earlier releases.
        try NameSnapshotCache.saveStreamed(NameSnapshotCache.load(database:url,revision:1),database:url)
        let cache=NameSnapshotCache.url(for:url),original=try Data(contentsOf:cache)
        XCTAssertEqual(original.prefix(8),Data("MJNAME01".utf8))
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
    func testMappedCacheRejectsChecksummedInvalidSectionsAndTables() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles(["correct.txt","数学分析.pdf","other.txt","correct.txt.bak"].map(file),generation:1)
        let engine=try NameSearchEngine(databaseURL:url);try engine.load();try engine.saveCache()
        let cache=NameSnapshotCache.url(for:url),original=try Data(contentsOf:cache)
        XCTAssertEqual(original.prefix(8),Data("MJNAME02".utf8))
        let length=Int(original.withUnsafeBytes {$0.loadUnaligned(fromByteOffset:8,as:UInt64.self).littleEndian})
        let header=try XCTUnwrap(JSONSerialization.jsonObject(with:original[16..<(16+length)]) as? [String:Any])
        let sections=try XCTUnwrap(header["sections"] as? [[String:Any]])
        func section(_ name:String)throws->(offset:Int,count:Int) {
            let item=try XCTUnwrap(sections.first {$0["name"] as? String == name})
            return (try XCTUnwrap(item["offset"] as? Int),try XCTUnwrap(item["count"] as? Int))
        }
        func rehashed(_ bytes:Data)->Data {
            var bytes=bytes;bytes.replaceSubrange((bytes.count-32)..<bytes.count,with:Data(SHA256.hash(data:bytes.dropLast(32))));return bytes
        }
        // Edit the JSON text itself, so every other value keeps its exact bytes.
        let text=String(decoding:original[16..<(16+length)],as:UTF8.self)
        func rewriteHeader(_ edit:(String)->String)throws->Data {
            let edited=edit(text)
            XCTAssertNotEqual(edited,text)
            let json=Data(edited.utf8)
            XCTAssertLessThanOrEqual(16+json.count,16_384)
            var bytes=original
            var size=UInt64(json.count).littleEndian
            bytes.replaceSubrange(8..<16,with:withUnsafeBytes(of:&size) {Data($0)})
            bytes.replaceSubrange(16..<(16+length),with:Data(count:length))
            bytes.replaceSubrange(16..<(16+json.count),with:json)
            return rehashed(bytes)
        }
        func renamedSection(_ name:String,_ count:Int)throws->Data {
            let old=try section(name)
            return try rewriteHeader { text in
                // The encoder's key order is unspecified: edit inside this section's object.
                guard let label=text.range(of:"\"name\":\"\(name)\""),
                      let open=text[..<label.lowerBound].lastIndex(of:"{"),
                      let close=text[label.upperBound...].firstIndex(of:"}") else {return text}
                let object=String(text[open...close])
                return text.replacingCharacters(in:open...close,with:object.replacingOccurrences(of:"\"count\":\(old.count)",with:"\"count\":\(count)"))
            }
        }
        let lookup=try section("core.lookup"),rows=try section("core.rows")
        var tamperedLookup=original
        // Move one name's slot: its probe chain now misses it.
        let slots=(0..<lookup.count).map { i in original.withUnsafeBytes {$0.loadUnaligned(fromByteOffset:lookup.offset+i*4,as:UInt32.self)} }
        let filled=try XCTUnwrap(slots.firstIndex {$0 != 0}),empty=try XCTUnwrap(slots.indices.first {slots[$0] == 0 && $0 != filled})
        tamperedLookup.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of:slots[filled],toByteOffset:lookup.offset+empty*4,as:UInt32.self)
            bytes.storeBytes(of:UInt32(0),toByteOffset:lookup.offset+filled*4,as:UInt32.self)
        }
        var outOfRangeRow=original
        outOfRangeRow.withUnsafeMutableBytes {$0.storeBytes(of:UInt32(99),toByteOffset:rows.offset,as:UInt32.self)}
        let corrupt=[try renamedSection("ids",7),try renamedSection("ids",Int(Int32.max)),try renamedSection("core.unique.names.offsets",1),
                     try rewriteHeader { text in
                         // The key may come last, before "}" rather than ",".
                         guard let value=text.range(of:"\"baseCount\":4"),
                               [",","}"].contains(text[value.upperBound...].first) else {return text}
                         return text.replacingCharacters(in:value,with:"\"baseCount\":99")
                     },
                     rehashed(tamperedLookup),rehashed(outOfRangeRow)]
        for bytes in corrupt {
            try bytes.write(to:cache)
            XCTAssertThrowsError(try NameSnapshotCache.load(database:url,revision:4))
            let recovered=try NameSearchEngine(databaseURL:url);try recovered.load()
            XCTAssertEqual(try recovered.search("correct").count,2)
            XCTAssertEqual(try recovered.search("shuxue").count,1)
        }
    }
    func testMappedRestoreSurvivesEditsAppendsAndSaves() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        try db.upsertFiles((0..<3_000).map {file("文件\($0).txt")}+[file("数学分析.pdf"),file("readme.md")],generation:1)
        let first=try NameSearchEngine(databaseURL:url);try first.load()
        let restored=try NameSnapshotCache.load(database:url,revision:3_002)
        XCTAssertTrue(restored.isMapped,"重建后应立即改用映射缓存")
        let engine=try NameSearchEngine(databaseURL:url);try engine.load()
        XCTAssertEqual(try engine.search("shuxue").count,1)
        // In-place edits (copy-on-write pages) and appends past the mapped rows.
        try db.execute("UPDATE files SET size=size+7 WHERE name LIKE '文件1%'")
        try db.execute("UPDATE files SET name='重命名'||name WHERE name LIKE '文件2%'")
        try db.upsertFiles((0..<2_000).map {file("新增\($0).txt")},generation:2)
        try engine.refresh(rootID:"r",relativePaths:[""],fullRescan:true)
        XCTAssertEqual(try engine.search("新增",options:SearchOptions(limit:5_000)).count,2_000)
        XCTAssertEqual(try engine.search("重命名",options:SearchOptions(limit:5_000)).count,1_111)
        XCTAssertEqual(try engine.search("文件2",options:SearchOptions(limit:5_000)).count,1_111)
        let bigger=try engine.search("文件1",options:SearchOptions(sort:.size,limit:1))
        XCTAssertEqual(try db.nameHits(ids:bigger,query:"文件1").first?.file.size,8)
        try engine.saveCache()
        let again=try NameSearchEngine(databaseURL:url);try again.load()
        XCTAssertEqual(try again.search("新增",options:SearchOptions(limit:5_000)).count,2_000)
        XCTAssertEqual(try again.search("重命名",options:SearchOptions(limit:5_000)).count,1_111)
        XCTAssertEqual(try again.search("readme"),try engine.search("readme"))
        XCTAssertEqual(try again.search("文件",options:SearchOptions(sort:.name,limit:5_000)),try engine.search("文件",options:SearchOptions(sort:.name,limit:5_000)))
        let snapshot=try NameSnapshotCache.load(database:url,revision:10_000)
        XCTAssertTrue(snapshot.isMapped)
        XCTAssertEqual(snapshot.liveCount,5_002)
    }
    func testAbandonedTemporaryCachesAreRemovedOnLoad() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("index.sqlite"),db=try SearchDatabase(url:url)
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path));try db.upsertFiles([file("a.txt")],generation:1)
        let stale=directory.appendingPathComponent(".index.sqlite.names.cache.\(UUID().uuidString).tmp")
        let fresh=directory.appendingPathComponent(".index.sqlite.names.cache.\(UUID().uuidString).tmp")
        try Data(count:1024).write(to:stale);try Data(count:1024).write(to:fresh)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-7200)],ofItemAtPath:stale.path)
        let engine=try NameSearchEngine(databaseURL:url);try engine.load()
        _=try? NameSnapshotCache.load(database:url,revision:1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:fresh.path),"可能仍在写入的新临时文件不能删")
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
