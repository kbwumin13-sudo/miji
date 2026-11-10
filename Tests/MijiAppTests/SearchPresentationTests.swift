import XCTest
import MijiCore
@testable import MijiApp

final class SearchPresentationTests: XCTestCase {
    func testBackgroundPresentationRequiresExplicitTestingAndAnIsolatedBundle() {
        XCTAssertTrue(AppDelegate.usesBackgroundPresentation(environment:["MIJI_UI_TESTING":"1"],bundleIdentifier:"com.haiyu.miji.qa.mac9"))
        XCTAssertFalse(AppDelegate.usesBackgroundPresentation(environment:["MIJI_UI_TESTING":"1"],bundleIdentifier:"com.haiyu.miji"))
        XCTAssertFalse(AppDelegate.usesBackgroundPresentation(environment:[:],bundleIdentifier:"com.haiyu.miji.qa.mac9"))
        XCTAssertFalse(AppDelegate.usesBackgroundPresentation(environment:["MIJI_UI_TESTING":"1"],bundleIdentifier:nil))
    }

    @MainActor func testPausedQALaunchPreservesIndexedMissingFileBeforePresentation() async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-qa-freeze-\(UUID().uuidString)")
        let source=base.appendingPathComponent("source"),data=base.appendingPathComponent("data")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        let file=source.appendingPathComponent("待恢复.txt")
        try Data("已保存的内容".utf8).write(to:file)
        let db=try SearchDatabase(url:data.appendingPathComponent("index.sqlite"))
        let root=try VolumeIdentity.root(for:source);try db.saveRoot(root)
        _=try FileScanner(database:db).scan(root:root)
        try FileManager.default.removeItem(at:file)
        let values=["MIJI_DATA_DIR":data.path,"MIJI_NO_AUTOSTART":"1","MIJI_UI_TESTING":"1","MIJI_UI_PAUSE_INDEX":"1"]
        var saved:[String:String]=[:]
        for key in values.keys {if let value=ProcessInfo.processInfo.environment[key] {saved[key]=value}}
        for (key,value) in values {setenv(key,value,1)}
        defer {
            for key in values.keys {if let value=saved[key] {setenv(key,value,1)}else{unsetenv(key)}}
            try? FileManager.default.removeItem(at:base)
        }
        let model=AppModel();defer{model.service?.stop()}
        XCTAssertTrue(model.paused,"QA must pause before AppDelegate presents a window")
        model.service?.configure(model.preferences);model.service?.setUserActive(false)
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertEqual(try db.search("待恢复",options:SearchOptions(scope:.name)).count,1)
    }
}
