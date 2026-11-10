import AppKit
import XCTest
@testable import MijiCore
@testable import MijiApp

final class SearchResultValidityTests: XCTestCase {
    private var directory: URL!
    private var oldDirectory: String?, oldAuto: String?
    override func setUpWithError() throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("miji-validity-\(UUID().uuidString)")
        oldDirectory=ProcessInfo.processInfo.environment["MIJI_DATA_DIR"]
        oldAuto=ProcessInfo.processInfo.environment["MIJI_NO_AUTOSTART"]
        setenv("MIJI_DATA_DIR",directory.path,1);setenv("MIJI_NO_AUTOSTART","1",1)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {
        if let oldDirectory {setenv("MIJI_DATA_DIR",oldDirectory,1)}else{unsetenv("MIJI_DATA_DIR")}
        if let oldAuto {setenv("MIJI_NO_AUTOSTART",oldAuto,1)}else{unsetenv("MIJI_NO_AUTOSTART")}
        try FileManager.default.removeItem(at:directory)
    }
    private func populate() throws -> [SearchHit] {
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=IndexedRoot(id:"desk",path:directory.path,name:"工作盘")
        try db.saveRoot(root)
        for (i,name) in ["Alpha.txt","Beta.txt"].enumerated() {
            let url=directory.appendingPathComponent(name)
            try Data("fixture body".utf8).write(to:url)
            let signature=try FileSignature.read(url)
            try db.upsertFiles([FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:"txt",kind:.document,size:signature.size,modified:signature.modified,inode:Int64(i+1))],generation:1)
        }
        return try db.search("",options:SearchOptions(scope:.name))
    }
    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() {return};try await Task.sleep(nanoseconds:10_000_000) }
        XCTFail("异步状态未及时到达")
    }
    @MainActor func testOldDisplayedSnapshotRejectsEveryOperationBeforeNewQueryReturns() async throws {
        let records=try populate()
        let model=AppModel(searchExecutor:{_,query,_,_ in records.filter {$0.file.name.hasPrefix(query)}})
        model.service?.stop();defer {model.service?.stop()}
        model.setSearchVisible(true);model.query="Alpha"
        try await waitUntil {!model.hits.isEmpty && !model.searching}
        let old=try XCTUnwrap(model.selected),snapshot=model.displayedSnapshot
        XCTAssertTrue(model.validateResult(old,for:.copyPath))
        let pasteboard=NSPasteboard.withUniqueName();defer{pasteboard.releaseGlobally()}
        pasteboard.setString("untouched",forType:.string)
        model.query="Beta"
        XCTAssertEqual(model.hits.first?.id,old.id,"旧列表可以保留防闪烁")
        XCTAssertEqual(model.searchStatus.phase,.searching)
        XCTAssertEqual(model.searchStatus.count,0,"旧列表不算新查询的命中")
        for action in [FileAction.open,.openAtLine,.reveal,.copyFile,.copyPath,.quickLook,.preview] {
            XCTAssertFalse(model.validateResult(old,for:action,snapshot:snapshot))
            XCTAssertNotNil(model.message)
        }
        model.performFileAction(.copyPath,hit:old,snapshot:snapshot,pasteboard:pasteboard)
        XCTAssertEqual(pasteboard.string(forType:.string),"untouched")
        try await waitUntil {model.hits.first?.file.name == "Beta.txt"}
        XCTAssertFalse(model.validateResult(old,for:.copyPath,snapshot:snapshot))
        XCTAssertTrue(model.validateResult(try XCTUnwrap(model.selected),for:.copyFile))
        XCTAssertGreaterThan(try XCTUnwrap(model.currentSnapshot).generation,try XCTUnwrap(snapshot).generation)
    }
    @MainActor func testAllFilterChangesInvalidateImmediatelyAndResetPreservesInputAndDisplayPreferences() async throws {
        let records=try populate()
        let model=AppModel(searchExecutor:{_,_,_,_ in records});defer{model.service?.stop()}
        model.setSearchVisible(true);model.query="Alpha ext:txt path:资料"
        try await waitUntil {!model.hits.isEmpty && !model.searching}
        let hit=try XCTUnwrap(model.selected)
        model.previewMode = .hidden;model.gridEnabled=true
        let mutations:[() -> Void]=[{model.kind = .document},{model.rootID="desk"},{model.scope = .content},{model.sort = .modified},{model.preferences.retainOffline=false;model.savePreferences()}]
        for change in mutations {
            change();XCTAssertFalse(model.isCurrentResult(hit))
            try await waitUntil {!model.searching}
        }
        XCTAssertEqual(Set(model.activeFilters.map(\.id)),Set([.kind,.root,.scope,.sort,.onlineOnly]))
        model.removeFilter(.scope);XCTAssertEqual(model.scope,.all)
        model.resetInterfaceFilters()
        XCTAssertTrue(model.activeFilters.isEmpty)
        XCTAssertEqual(model.query,"Alpha ext:txt path:资料")
        XCTAssertEqual(model.previewMode,.hidden);XCTAssertTrue(model.gridEnabled)
    }
    @MainActor func testCurrentNameResultCanBeUsedWhileBodyIsBlockedAndEmptySearchRemainsPending() async throws {
        _=try populate()
        let gate=DispatchSemaphore(value:0)
        let entered=expectation(description:"正文开始");entered.assertForOverFulfill=false
        let model=AppModel(supplementaryExecutor:{_,query,_,_ in if query == "Beta" { entered.fulfill();_ = gate.wait(timeout:.now()+3) };return []})
        model.service?.stop();defer {gate.signal();model.service?.stop()}
        model.setSearchVisible(true);model.query="Beta"
        await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(model.searchPhase,.supplementing)
        XCTAssertTrue(model.searching)
        let hit=try XCTUnwrap(model.selected)
        XCTAssertTrue(model.validateResult(hit,for:.copyFile),"正文补充中名称结果可操作")
        XCTAssertEqual(model.searchStatus.timing,.firstBatch)
        model.query="missing"
        try await waitUntil {model.displayedSnapshot == model.currentSnapshot}
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertEqual(model.searchPhase,.searching,"正文未完成不宣告无匹配")
        gate.signal()
        try await waitUntil {!model.searching}
        XCTAssertEqual(model.searchPhase,.complete);XCTAssertEqual(model.searchStatus.count,0)
        XCTAssertEqual(model.searchStatus.timing,.complete)
    }
    @MainActor func testBudgetLimitedBodySearchFinishesWithVerifiedResultsAndTiming() async throws {
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=IndexedRoot(id:"desk",path:directory.path,name:"工作盘");try db.saveRoot(root)
        let records=(0..<4_110).map { FileRecord(rootID:root.id,relativePath:"\($0).txt",name:"\($0).txt",fileExtension:"txt",kind:.document,size:6,modified:1) }
        try db.upsertFiles(records,generation:1)
        let first=try XCTUnwrap(db.pendingFiles(rootID:root.id,limit:1).first)
        XCTAssertTrue(try db.completeContent(file:first,content:ExtractedContent(text:"needle")))
        try db.run("UPDATE files SET content_id=(SELECT content_id FROM files WHERE content_id IS NOT NULL LIMIT 1)")
        let model=AppModel();model.service?.stop();defer{model.service?.stop()}
        model.previewMode = .hidden;model.scope = .content;model.setSearchVisible(true);model.query="needle"
        try await waitUntil {model.searchPhase == .complete}
        XCTAssertFalse(model.searching);XCTAssertNil(model.searchError)
        XCTAssertTrue(model.searchStatus.isLimited);XCTAssertEqual(model.searchStatus.timing,.complete)
        XCTAssertNotNil(model.completedMilliseconds);XCTAssertEqual(model.hits.count,500)
        XCTAssertTrue(model.hits.allSatisfy {$0.snippet.contains("needle")})
    }
    @MainActor func testOfflineAndOnlineMissingFilesHaveDifferentMessagesAndPathRemainsCopyable() async throws {
        let records=try populate()
        var offline=try XCTUnwrap(records.first)
        offline.root.isOnline=false;offline.root.isExternal=true;offline.root.path="/Volumes/归档盘/课程"
        let model=AppModel(searchExecutor:{_,_,_,_ in [offline]});defer{model.service?.stop()}
        model.setSearchVisible(true);model.query="fixture"
        try await waitUntil {!model.hits.isEmpty && !model.searching}
        model.roots=[offline.root]
        XCTAssertEqual(model.resultAvailability(offline).state,.diskOffline)
        XCTAssertTrue(model.resultLocation(offline).short.contains("归档盘"))
        XCTAssertTrue(model.validateResult(offline,for:.copyPath));XCTAssertFalse(model.validateResult(offline,for:.open))
        XCTAssertTrue(model.message?.contains("归档盘")==true)
        var missing=offline;missing.root.isOnline=true
        model.hits=[missing]
        XCTAssertEqual(model.resultAvailability(missing).state,.fileUnavailable)
        model.roots=[]
        XCTAssertFalse(model.validateResult(missing,for:.reveal))
        XCTAssertTrue(model.message?.contains("磁盘在线")==true)
    }
    @MainActor func testSelectionSurvivesProgressiveSupplement() async throws {
        let records=try populate(),gate=DispatchSemaphore(value:0)
        let entered=expectation(description:"名称结果已发布")
        let second=try XCTUnwrap(records.last)
        var extra=second;extra.file.id=999;extra.file.relativePath="Third.txt";extra.file.name="Third.txt"
        let lock=NSLock();var enteredOnce=false
        let model=AppModel(supplementaryExecutor:{_,_,_,_ in
            lock.lock();let first = !enteredOnce;enteredOnce=true;lock.unlock()
            if first {entered.fulfill();_ = gate.wait(timeout:.now()+3)}
            return [extra]
        })
        model.service?.stop();defer{gate.signal()}
        model.setSearchVisible(true);model.query="txt"
        await fulfillment(of:[entered],timeout:2)
        model.selectedID=second.id
        gate.signal()
        try await waitUntil {!model.searching}
        XCTAssertEqual(model.selected?.file.relativePath,second.file.relativePath)
    }
    @MainActor func testFailureHasExplicitPhaseAndNoCompletedEmptyClaim() async throws {
        _=try populate()
        let model=AppModel(searchExecutor:{_,_,_,_ in throw NSError(domain:"fixture",code:1,userInfo:[NSLocalizedDescriptionKey:"合成查询失败"])})
        model.service?.stop()
        model.setSearchVisible(true);model.query="failure"
        try await waitUntil {model.searchPhase == .failed}
        XCTAssertEqual(model.searchStatus.error,"合成查询失败")
        XCTAssertFalse(model.searching)
        XCTAssertNil(model.completedMilliseconds)
    }

    @MainActor func testUnavailableOriginalKeepsStoredTextAndExtractionStatesAreDistinct() async throws {
        _=try populate()
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=try XCTUnwrap(db.roots().first)
        var hits:[SearchHit]=[]
        for (name,state) in [("unpreviewable.pdf","done"),("partial.txt","partial"),("failed.txt","error")] {
            let file=directory.appendingPathComponent(name)
            try Data("invalid original fixture".utf8).write(to:file)
            let signature=try FileSignature.read(file)
            try db.upsertFiles([FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:file.pathExtension,kind:.document,size:signature.size,modified:signature.modified,inode:signature.inode)],generation:1)
            let record=try XCTUnwrap(db.pendingFiles(rootID:root.id).first {$0.name == name})
            if state == "error" { try db.failContent(file:record,message:"合成提取错误") }
            else { XCTAssertTrue(try db.completeContent(file:record,content:ExtractedContent(text:"saved fixture body",warning:state == "partial" ? "只提取了部分内容" : nil))) }
            hits.append(try XCTUnwrap(db.search(name,options:SearchOptions(scope:.name)).first))
        }
        let model=AppModel(searchExecutor:{_,_,_,_ in hits});model.service?.stop()
        model.setSearchVisible(true);model.query="fixture"
        try await waitUntil {!model.previewLoading && !model.previewText.isEmpty}
        let pdf=try XCTUnwrap(hits.first)
        model.selectedID=pdf.id
        try await waitUntil {!model.previewLoading && !model.previewText.isEmpty}
        XCTAssertEqual(model.resultAvailability(pdf).state,.indexedOnly)
        XCTAssertTrue(model.previewText.contains("saved fixture body"))
        model.selectedID=hits[1].id
        try await waitUntil {!model.previewLoading && model.previewWarning != nil}
        XCTAssertEqual(model.resultAvailability(hits[1]).state,.partial)
        XCTAssertEqual(model.resultAvailability(hits[2]).state,.extractionFailed)
    }

}
