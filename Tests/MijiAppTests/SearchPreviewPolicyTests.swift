import XCTest
import MijiCore
@testable import MijiApp

final class SearchPreviewPolicyTests: XCTestCase {
    private func hit(_ kind: FileKind, id: Int64 = 1, online: Bool = true, snippet: String = "", matchedIn: String = "文件名") -> SearchHit {
        SearchHit(file: FileRecord(id: id, rootID: "r", relativePath: "sample", name: "sample", fileExtension: "", kind: kind, size: 1, modified: 1),
                  root: IndexedRoot(id: "r", path: "/missing", isOnline: online), snippet: snippet, matchedIn: matchedIn)
    }

    func testAutomaticPolicyRequiresContentAndNeverProbesFiles() {
        for kind in [FileKind.application, .folder, .archive, .other] {
            XCTAssertFalse(SearchPreviewPolicy.showsPane(mode: .automatic, hits: [hit(kind)]))
        }
        for kind in [FileKind.image, .document, .code, .audio, .video] {
            // Even an unavailable file can have useful stored content; loading is separate.
            XCTAssertTrue(SearchPreviewPolicy.showsPane(mode: .automatic, hits: [hit(kind, online: false)]))
        }
        XCTAssertTrue(SearchPreviewPolicy.hasContent(hit(.other, snippet: "stored needle", matchedIn: "正文")))
        XCTAssertFalse(SearchPreviewPolicy.hasContent(hit(.other, snippet: "   ", matchedIn: "正文")))
        XCTAssertFalse(SearchPreviewPolicy.hasContent(hit(.other, snippet: "name only")))
    }

    func testExplicitModesOverrideAutomaticAndEmptyResultsHaveNoPane() {
        XCTAssertTrue(SearchPreviewPolicy.showsPane(mode: .shown, hits: [hit(.application)]))
        XCTAssertFalse(SearchPreviewPolicy.showsPane(mode: .hidden, hits: [hit(.image)]))
        for mode in SearchPreviewMode.allCases {
            XCTAssertFalse(SearchPreviewPolicy.showsPane(mode: mode, hits: []))
        }
        XCTAssertTrue(SearchPreviewPolicy.showsPane(mode: .automatic, hits: [hit(.application), hit(.document, id: 2)]))
    }

    @MainActor
    func testMetadataSelectionSkipsLoadingAndMixedSelectionKeepsSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldDir = getenv("MIJI_DATA_DIR").map { String(cString: $0) }
        let oldAuto = getenv("MIJI_NO_AUTOSTART").map { String(cString: $0) }
        setenv("MIJI_DATA_DIR", directory.path, 1); setenv("MIJI_NO_AUTOSTART", "1", 1)
        defer {
            if let oldDir { setenv("MIJI_DATA_DIR", oldDir, 1) } else { unsetenv("MIJI_DATA_DIR") }
            if let oldAuto { setenv("MIJI_NO_AUTOSTART", oldAuto, 1) } else { unsetenv("MIJI_NO_AUTOSTART") }
            try? FileManager.default.removeItem(at: directory)
        }
        let app = hit(.application), document = hit(.document, id: 2, online: false)
        let model = AppModel(searchExecutor: { _, _, _, _ in [app] })
        defer { model.service?.stop() }
        model.setSearchVisible(true); model.query = "sample"
        for _ in 0..<100 where model.hits.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.previewVisible); XCTAssertFalse(model.previewLoading)
        XCTAssertEqual(model.panelWidth, 800)
        model.previewMode = .shown
        XCTAssertTrue(model.previewVisible); XCTAssertFalse(model.previewLoading, "Metadata must not load content or thumbnails")
        model.previewMode = .automatic
        model.hits = [app, document]
        let width = model.panelWidth, height = model.panelHeight, columns = model.gridColumns
        XCTAssertEqual(width, 1060)
        model.selectedID = document.id
        for _ in 0..<100 where model.previewLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.previewLocalURL)
        XCTAssertEqual(model.panelWidth, width); XCTAssertEqual(model.panelHeight, height)
        model.selectedID = app.id
        XCTAssertFalse(model.previewLoading); XCTAssertTrue(model.previewText.isEmpty)
        XCTAssertEqual(model.panelWidth, width); XCTAssertEqual(model.panelHeight, height)
        XCTAssertEqual(model.gridColumns, columns)
        model.previewMode = .hidden
        XCTAssertFalse(model.previewVisible); XCTAssertEqual(model.panelWidth, 800)
        model.previewEnabled = true
        XCTAssertEqual(model.previewMode, .shown)
        model.setSearchVisible(false)
        XCTAssertNil(model.previewLocalURL); XCTAssertFalse(model.previewVisible)
    }
}
