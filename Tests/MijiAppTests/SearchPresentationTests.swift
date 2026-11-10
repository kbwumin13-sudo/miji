import XCTest
@testable import MijiApp

final class SearchPresentationTests: XCTestCase {
    func testBackgroundPresentationRequiresExplicitTestingAndAnIsolatedBundle() {
        XCTAssertTrue(AppDelegate.usesBackgroundPresentation(environment:["MIJI_UI_TESTING":"1"],bundleIdentifier:"com.haiyu.miji.qa.mac9"))
        XCTAssertFalse(AppDelegate.usesBackgroundPresentation(environment:["MIJI_UI_TESTING":"1"],bundleIdentifier:"com.haiyu.miji"))
        XCTAssertFalse(AppDelegate.usesBackgroundPresentation(environment:[:],bundleIdentifier:"com.haiyu.miji.qa.mac9"))
        XCTAssertFalse(AppDelegate.usesBackgroundPresentation(environment:["MIJI_UI_TESTING":"1"],bundleIdentifier:nil))
    }
}
