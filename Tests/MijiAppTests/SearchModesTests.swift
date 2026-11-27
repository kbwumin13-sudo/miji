import AppKit
import MijiCore
import XCTest
@testable import MijiApp

final class SearchModesTests: XCTestCase {
    @MainActor
    func testFilesBrowseAndSearchExcludeAppsWithoutChangingGlobalQuery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldDirectory = ProcessInfo.processInfo.environment["MIJI_DATA_DIR"]
        let oldAuto = ProcessInfo.processInfo.environment["MIJI_NO_AUTOSTART"]
        setenv("MIJI_DATA_DIR", directory.path, 1)
        setenv("MIJI_NO_AUTOSTART", "1", 1)
        defer {
            if let oldDirectory { setenv("MIJI_DATA_DIR", oldDirectory, 1) } else { unsetenv("MIJI_DATA_DIR") }
            if let oldAuto { setenv("MIJI_NO_AUTOSTART", oldAuto, 1) } else { unsetenv("MIJI_NO_AUTOSTART") }
            try? FileManager.default.removeItem(at: directory)
        }
        let database = try SearchDatabase(url: directory.appendingPathComponent("index.sqlite"))
        let root = IndexedRoot(id: "sample", path: directory.path)
        try database.saveRoot(root)
        let names: [(String, FileKind, Double)] = [("harbor.app", .application, 3), ("harbor.txt", .document, 2), ("harbor.png", .image, 1)]
        try database.upsertFiles(names.map { name, kind, modified in
            FileRecord(rootID: root.id, relativePath: name, name: name,
                       fileExtension: URL(fileURLWithPath: name).pathExtension, kind: kind, size: 1, modified: modified)
        }, generation: 1)
        let textFile = try XCTUnwrap(try database.pendingFiles(rootID: root.id).first { $0.name == "harbor.txt" })
        let body = "潮位观测已记录。"
        XCTAssertTrue(try database.completeContent(file: textFile, content: ExtractedContent(text: body)))
        let model = AppModel()
        defer { model.service?.stop() }
        model.setSearchVisible(true)
        model.selectMode(.files)
        try await awaitResults(model)
        XCTAssertEqual(model.hits.map(\.file.name), ["harbor.txt", "harbor.png"])
        XCTAssertFalse(model.showsFileSelectionFeedback)
        XCTAssertNil(model.selectedFileForAction)
        XCTAssertFalse(model.previewVisible)
        XCTAssertEqual(model.panelWidth, PanelMetrics.fileWidth)
        model.openSelected()
        XCTAssertNil(model.message, "Return must not act on an unhighlighted file")
        // Clicking the implicit first result must load its preview even though its ID is unchanged.
        model.selectFile(textFile.id)
        XCTAssertTrue(model.previewVisible)
        XCTAssertEqual(model.panelWidth, PanelMetrics.previewWidth)
        for _ in 0..<100 where model.previewLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.previewText, body)
        model.previewMode = .hidden
        XCTAssertFalse(model.previewVisible)
        XCTAssertTrue(model.previewText.isEmpty)
        model.clearSelectionFeedback()
        model.previewMode = .automatic
        XCTAssertFalse(model.previewVisible)
        model.moveSelection(1)
        XCTAssertTrue(model.showsFileSelectionFeedback)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selected?.file.name, "harbor.png")
        XCTAssertTrue(model.previewVisible)
        XCTAssertEqual(model.panelWidth, PanelMetrics.previewWidth)
        XCTAssertTrue(model.previewText.isEmpty)
        model.openSelected()
        XCTAssertTrue(model.message?.contains("harbor.png") == true, "Return targets the explicitly selected file")
        model.message = nil
        model.clearSelectionFeedback()
        XCTAssertNil(model.selectedFileForAction)
        XCTAssertFalse(model.previewVisible)
        XCTAssertEqual(model.panelWidth, PanelMetrics.fileWidth)
        model.fileKind = .document
        model.query = "harbor"
        try await awaitResults(model)
        XCTAssertEqual(model.hits.map(\.file.name), ["harbor.txt"])
        XCTAssertFalse(model.showsFileSelectionFeedback)
        XCTAssertEqual(model.selectedFileForAction?.file.name, "harbor.txt", "Typed search still defaults to the first visible result")
        model.selectMode(.clipboard)
        XCTAssertTrue(model.hits.isEmpty)
        model.selectMode(.all)
        try await awaitResults(model)
        XCTAssertEqual(model.query, "harbor")
        XCTAssertEqual(Set(model.hits.map(\.file.name)), Set(names.map { $0.0 }))
    }

    @MainActor
    private func awaitResults(_ model: AppModel) async throws {
        for _ in 0..<150 {
            if model.searchStatus.phase == .complete { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected the current search to finish")
    }

    @MainActor
    func testClipboardHistoryIsOptInSkipsConcealedDataAndCanRestorePayloads() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let browser = BrowseContent(pasteboard: board)
        let previous = ClipboardPayload.text("previous clipboard")
        XCTAssertTrue(previous.copy(to: board))
        browser.checkClipboard()
        XCTAssertTrue(browser.history.isEmpty)
        browser.setClipboardRecording(true)
        defer { browser.setClipboardRecording(false) }
        browser.checkClipboard()
        XCTAssertTrue(browser.history.isEmpty)

        XCTAssertTrue(ClipboardPayload.text("Harbor sample").copy(to: board))
        browser.checkClipboard()
        let text = try XCTUnwrap(browser.visibleClipboard(query: "harbor").first)
        let urls = [URL(fileURLWithPath: "/tmp/harbor.txt"), URL(fileURLWithPath: "/tmp/sunset.txt")]
        XCTAssertTrue(ClipboardPayload.files(urls).copy(to: board))
        browser.checkClipboard()
        XCTAssertEqual(browser.history.first?.payload, .files(urls))
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9v8l8AAAAASUVORK5CYII="))
        XCTAssertTrue(ClipboardPayload.image(png, .png).copy(to: board))
        browser.checkClipboard()
        XCTAssertEqual(browser.history.first?.payload, .image(png, .png))

        let concealed = NSPasteboardItem()
        concealed.setString("secret", forType: .string)
        concealed.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([concealed]))
        browser.checkClipboard()
        XCTAssertEqual(browser.history.count, 3)
        XCTAssertTrue(browser.copyClipboardEntry(text))
        XCTAssertEqual(board.string(forType: .string), "Harbor sample")
        browser.checkClipboard()
        XCTAssertEqual(browser.history.count, 3)
        browser.clearClipboardHistory()
        XCTAssertTrue(browser.history.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "Harbor sample")
    }

    func testClipboardImagePreviewFitsLargeImagesAndHandlesInvalidData() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 800, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))

        for format: NSBitmapImageRep.FileType in [.png, .tiff] {
            let data = try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
            let image = try XCTUnwrap(ClipboardImagePreview.makeImage(from: data))
            XCTAssertEqual(image.width, 1280)
            XCTAssertEqual(image.height, 640)
        }

        XCTAssertNil(ClipboardImagePreview.makeImage(from: Data("broken image".utf8)))
    }
}
