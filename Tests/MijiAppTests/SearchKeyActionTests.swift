import AppKit
import XCTest
@testable import MijiApp

final class SearchKeyActionTests: XCTestCase {
    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil, characters: "",
                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @MainActor
    func testMarkedPinyinKeepsReturnAndCandidateKeysInInputMethod() {
        let editor = NSTextView()
        editor.setMarkedText("shuxue", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        for code: UInt16 in [36, 76, 125, 126, 49, 53] {
            XCTAssertNil(SearchKeyAction.action(for: key(code), firstResponder: editor),
                         "Composition key \(code) must reach the input method")
        }
        XCTAssertNil(SearchKeyAction.action(for: key(36, modifiers: .command), firstResponder: editor))
        editor.unmarkText()
        XCTAssertEqual(editor.string, "shuxue")
        XCTAssertEqual(SearchKeyAction.action(for: key(36), firstResponder: editor), .open,
                       "The next Return after committing text still opens the result")
    }

    @MainActor
    func testNormalSearchNavigationAndShortcutsRemainAvailable() {
        let editor = NSTextView()
        editor.string = "README"
        XCTAssertEqual(SearchKeyAction.action(for: key(125), firstResponder: editor), .moveDown)
        XCTAssertEqual(SearchKeyAction.action(for: key(126), firstResponder: editor), .moveUp)
        XCTAssertEqual(SearchKeyAction.action(for: key(36), firstResponder: editor), .open)
        XCTAssertEqual(SearchKeyAction.action(for: key(76), firstResponder: editor), .open)
        XCTAssertEqual(SearchKeyAction.action(for: key(36, modifiers: .command), firstResponder: editor), .reveal)
        XCTAssertEqual(SearchKeyAction.action(for: key(53), firstResponder: editor), .hide)
        XCTAssertEqual(SearchKeyAction.action(for: key(8, modifiers: [.command, .shift]), firstResponder: editor), .copyPath)
        XCTAssertNil(SearchKeyAction.action(for: key(49), firstResponder: editor), "Spaces in a query remain text")
        XCTAssertEqual(SearchKeyAction.action(for: key(49), firstResponder: NSView()), .preview)
        XCTAssertNil(SearchKeyAction.action(for: key(0), firstResponder: editor))
    }
}
