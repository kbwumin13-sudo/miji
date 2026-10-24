import XCTest
@testable import MijiCore

final class LightIndexingTests: XCTestCase {
    func testEventsBehindSuspendedCursorSurviveLiveResumeAndRestart() throws {
        for restart in [false,true] {
            let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:base)}
            let source=base.appendingPathComponent("source")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            for i in 0..<901 {try Data().write(to:source.appendingPathComponent("f-\(i).bin"))}
            let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite")),root=try VolumeIdentity.root(for:source)
            try db.saveRoot(root)
            var service=IndexService(database:db,extractor:{_,_ in ExtractedContent(text:"")},watchEvents:false)
            var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.images=false;prefs.documents=false
            let paused=expectation(description:"pause after committed metadata")
            var didPause=false
            service.onProgress = { [weak service] progress in
                if !didPause,progress.processed == 300 {didPause=true;service?.setPaused(true);paused.fulfill()}
            }
            service.configure(prefs)
            wait(for:[paused],timeout:5)
            let settled=expectation(description:"checkpoint committed")
            service.mutate({_ in},completion:{_ in settled.fulfill()})
            wait(for:[settled],timeout:5)
            let saved=IncrementalIndexState.read(db.url.appendingPathExtension("incremental.json"))
            let generation=try XCTUnwrap(saved.roots[root.id]?.scan?.generation)
            let file=try XCTUnwrap(db.search("f-").first?.file)
            let changed=source.appendingPathComponent(file.relativePath)
            try Data("changed behind cursor".utf8).write(to:changed)
            service.receiveEvents([FileChangeEvent(path:changed.path)])
            if restart {
                service.stop()
                service=IndexService(database:db,extractor:{_,_ in ExtractedContent(text:"")},watchEvents:false)
            }
            let done=expectation(description:"resumed traversal and queued change finished")
            done.assertForOverFulfill=false
            var resumedAt:Int?
            service.onProgress = {progress in
                if progress.phase == "正在建立文件目录",resumedAt == nil {resumedAt=progress.processed}
                if progress.phase == "索引已更新" {done.fulfill()}
            }
            if restart {service.configure(prefs)} else {service.setPaused(false)}
            wait(for:[done],timeout:8)
            service.setPaused(true)
            let ended=expectation(description:"finished service settled")
            service.mutate({_ in},completion:{_ in ended.fulfill()})
            wait(for:[ended],timeout:5);service.stop()
            XCTAssertEqual(resumedAt,300)
            XCTAssertEqual(try db.statistics().files,901)
            XCTAssertEqual(try db.search(file.name).first?.file.size,21)
            let after=IncrementalIndexState.read(db.url.appendingPathExtension("incremental.json"))
            XCTAssertTrue(after.roots[root.id]?.pending.isEmpty == true)
            XCTAssertTrue(after.roots[root.id]?.inFlight.isEmpty == true)
            XCTAssertNil(after.roots[root.id]?.scan)
            XCTAssertGreaterThan(generation,0)
        }
    }
    func testEventStormCompactsAffectedSubdirectoriesWithoutEscalatingRoot() {
        let paths=(0..<6_000).map {"Users/test/project/build/part-\($0/20)/file-\($0).txt"}
            + ["Users/test/notes/new.md","Library/another/file.txt"]
        let compressed=IndexRelativePath.compacting(paths)
        XCTAssertLessThanOrEqual(compressed.count,2_048)
        XCTAssertFalse(compressed.contains(""))
        XCTAssertTrue(compressed.contains("Users/test/notes/new.md"))
        XCTAssertTrue(compressed.contains("Library/another/file.txt"))
        XCTAssertTrue(paths.allSatisfy {path in compressed.contains {IndexRelativePath.contains($0,path)}})
        XCTAssertFalse(compressed.contains {IndexRelativePath.contains($0,"Users/test/unrelated/keep.txt")})
    }
    func testDirectRootFilesAreRetainedAndRealRootRecoveryStillWins() {
        let paths=(0..<2_100).map {"file-\($0)"}
        XCTAssertEqual(Set(IndexRelativePath.compacting(paths)),Set(paths))
        XCTAssertEqual(IndexRelativePath.compacting(paths+[""]),[""])
        XCTAssertEqual(Set(IndexRelativePath.coalescing(["a","a/b","a-b/c","a0/z"])),Set(["a","a-b/c","a0/z"]))
    }
    func testSuspendedScannerContinuesSameEnumeratorAndPreservesUnvisitedHistory() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:base)}
        let source=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        for i in 0..<901 {try Data().write(to:source.appendingPathComponent("file-\(i).bin"))}
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite")),root=try VolumeIdentity.root(for:source)
        try db.saveRoot(root)
        try db.upsertFiles([FileRecord(rootID:root.id,relativePath:"gone.txt",name:"gone.txt",fileExtension:"txt",kind:.document,size:1,modified:1)],generation:1)
        let session=try FileScanner(database:db).session(root:root,relativePath:"",options:ScanOptions())
        let generation=session.checkpoint.generation
        var pause=false
        let partial=try session.advance(cancelled:{pause},progress:{if $0>=300 {pause=true}})
        XCTAssertFalse(partial.complete);XCTAssertEqual(partial.count,300)
        XCTAssertEqual(try db.search("gone.txt").count,1)
        pause=false
        let complete=try session.advance(cancelled:{false},progress:{_ in})
        XCTAssertTrue(complete.complete);XCTAssertEqual(complete.count,901)
        XCTAssertEqual(session.checkpoint.generation,generation)
        XCTAssertEqual(try db.statistics().files,901)
        XCTAssertTrue(try db.search("gone.txt").isEmpty)
    }
    func testPersistedDirectoryStackRestartsOnlyCurrentDirectory() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:base)}
        let source=base.appendingPathComponent("source")
        for d in 0..<6 {
            let folder=source.appendingPathComponent("dir-\(d)")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for f in 0..<200 {try Data().write(to:folder.appendingPathComponent("f-\(f).bin"))}
        }
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite")),root=try VolumeIdentity.root(for:source)
        let scanner=FileScanner(database:db)
        var first:FileScanSession?=try scanner.session(root:root,relativePath:"",options:ScanOptions())
        var stop=false
        _=try first!.advance(cancelled:{stop},progress:{if $0>=600 {stop=true}})
        let saved=try JSONDecoder().decode(FileScanCheckpoint.self,from:JSONEncoder().encode(first!.checkpoint))
        first=nil
        let second=try scanner.session(root:root,relativePath:"",options:ScanOptions(),checkpoint:saved)
        let result=try second.advance(cancelled:{false},progress:{_ in})
        XCTAssertTrue(result.complete)
        XCTAssertEqual(try db.statistics().files,1206)
        XCTAssertLessThanOrEqual(result.count,1406,"At most the current 200-entry directory should be revisited")
        XCTAssertEqual(second.checkpoint.generation,saved.generation)
    }
}
