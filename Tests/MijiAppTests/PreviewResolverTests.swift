import XCTest
import AppKit
import PDFKit
import MijiCore
@testable import MijiApp

final class PreviewResolverTests: XCTestCase {
    private func hit(_ name: String = "sample.swift", root: URL = URL(fileURLWithPath: "/missing"), online: Bool = false, kind: FileKind = .code) -> SearchHit {
        SearchHit(file: FileRecord(id: 1, rootID: "r", relativePath: name, name: name,
                                  fileExtension: URL(fileURLWithPath: name).pathExtension, kind: kind, size: 1, modified: 1),
                  root: IndexedRoot(id: "r", path: root.path, isOnline: online))
    }

    func testTermsIgnoreFiltersAndExclusionsButKeepQuotedOperators() {
        XCTAssertEqual(PreviewResolver.terms(in: "ext:pdf -草稿 path:课程 苹果 \"ext:pdf\" 苹果"), ["苹果", "ext:pdf"])
    }

    func testChineseEmojiCodeUsesRealLineAndBoundedContext() {
        let text = (1...90).map { $0 == 60 ? "let 标记 = \"👩🏽‍💻 数学\"" : "// 第\($0)行" }.joined(separator: "\n")
        let result = PreviewResolver.resolve(hit: hit(), content: ExtractedContent(text: text), query: "数学 -行 ext:swift", cancelled: { false })
        XCTAssertEqual(result.line, 60)
        XCTAssertTrue(result.text.contains("60  let 标记"))
        XCTAssertFalse(result.text.contains("1  // 第1行"))
        XCTAssertLessThanOrEqual(result.text.count, 16_000)
    }

    func testCRLFCodeLineNumbers() {
        let result = PreviewResolver.resolve(hit: hit(), content: ExtractedContent(text: "one\r\ntwo\r\nneedle"), query: "needle", cancelled: { false })
        XCTAssertEqual(result.line, 3)
    }

    func testFilenameOnlyMatchHasNoInventedLineOrPage() {
        let result = PreviewResolver.resolve(hit: hit("数学.pdf", kind: .document), content: ExtractedContent(text: "毫无关联"), query: "数学", cancelled: { false })
        XCTAssertNil(result.line)
        XCTAssertNil(result.page)
    }

    func testOfflinePDFMapUsesUTF8OffsetsAndKeepsBlankPageNumber() {
        let first = "第一页😀\n\n", second = "第三页中的数学"
        let content = ExtractedContent(text: first + second, pages: 3, pageRanges: [
            ContentPageRange(page: 1, utf8Offset: 0, utf8Length: "第一页😀".utf8.count),
            ContentPageRange(page: 3, utf8Offset: first.utf8.count, utf8Length: second.utf8.count)
        ])
        let result = PreviewResolver.resolve(hit: hit("scan.pdf", kind: .document), content: content, query: "数学", cancelled: { false })
        XCTAssertEqual(result.page, 3)
    }

    func testCancelledDoesNotReturnStaleText() {
        let result = PreviewResolver.resolve(hit: hit(), content: ExtractedContent(text: "needle"), query: "needle", cancelled: { true })
        XCTAssertEqual(result.text, "")
        XCTAssertNil(result.line)
    }

    func testContextIsCenteredOnLateMatchAndBounded() {
        let body = String(repeating: "甲", count: 30_000) + "needle" + String(repeating: "乙", count: 30_000)
        let result = PreviewResolver.resolve(hit: hit("text.txt", kind: .document), content: ExtractedContent(text: body), query: "needle", cancelled: { false })
        XCTAssertTrue(result.text.contains("needle"))
        XCTAssertEqual(result.text.count, 16_000)
    }

    func testLocalAvailabilityRejectsSymlinksAndOfflineRoots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello".utf8).write(to: directory.appendingPathComponent("local.txt"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.txt").path, withDestinationPath: "local.txt")
        XCTAssertNotNil(PreviewResolver.localURL(for: hit("local.txt", root: directory, online: true)))
        XCTAssertNil(PreviewResolver.localURL(for: hit("local.txt", root: directory)))
        XCTAssertNil(PreviewResolver.localURL(for: hit("link.txt", root: directory, online: true)))
    }

    @MainActor
    func testOldPDFTextLayerFallbackFindsActualPage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = PDFDocument()
        for (index, text) in ["unrelated first page", "needle on second page"].enumerated() {
            let data = NSMutableData()
            let consumer = CGDataConsumer(data: data)!
            var box = CGRect(x: 0, y: 0, width: 300, height: 300)
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            (text as NSString).draw(at: NSPoint(x: 20, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage(); context.closePDF()
            let page = try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
            document.insert(page, at: index)
        }
        let url = directory.appendingPathComponent("old.pdf")
        XCTAssertTrue(document.write(to: url))
        let result = PreviewResolver.resolve(hit: hit("old.pdf", root: directory, online: true, kind: .document), content: ExtractedContent(text: "unrelated first page\nneedle on second page"), query: "needle", cancelled: { false })
        XCTAssertEqual(result.page, 2)
    }
}
