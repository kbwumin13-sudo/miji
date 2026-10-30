import XCTest
import Foundation
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import MijiCore

final class ExtractionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MijiExtractionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func file(_ name: String, data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url); return url
    }
    private func file(_ name: String, text: String) throws -> URL { try file(name, data: Data(text.utf8)) }
    private func process(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        if process.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }
    private func archive(_ name: String, members: [String: String]) throws -> URL {
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in members {
            let member = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: member.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: member)
        }
        let destination = directory.appendingPathComponent(name)
        try process("/usr/bin/zip", ["-q", "-r", destination.path, "."], cwd: root)
        return destination
    }
    private func drawText(_ string: String, into context: CGContext, y: CGFloat = 220, size: CGFloat = 32) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.textMatrix = .identity; context.textPosition = CGPoint(x: 30, y: y)
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)), context)
    }
    private func image(_ lines: [String]) throws -> CGImage {
        let context = CGContext(data: nil, width: 1500, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1500, height: 500))
        for (index, line) in lines.enumerated() { drawText(line, into: context, y: CGFloat(380 - index * 100), size: 52) }
        return try XCTUnwrap(context.makeImage())
    }
    private func png(_ name: String, lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(lines), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
    }
    private func pdf(_ name: String, selectablePages: Int, rasterText: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var box = CGRect(x: 0, y: 0, width: 750, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<selectablePages {
            context.beginPDFPage(nil); drawText("Selectable page \(index + 1)", into: context); context.endPDFPage()
        }
        if let rasterText {
            context.beginPDFPage(nil)
            context.draw(try image([rasterText]), in: CGRect(x: 0, y: 0, width: 750, height: 250))
            context.endPDFPage()
        }
        context.closePDF(); return url
    }

    func testSupportedFormatsAndUnsupportedFiles() throws {
        for ext in ["PDF", "DOCX", "pptx", "xlsx", "ppt", "xls", "epub", "pages", "numbers", "key", "rtf", "doc", "html", "swift", "jpeg"] {
            XCTAssertTrue(ContentExtractor.supports(directory.appendingPathComponent("sample.\(ext)")))
        }
        XCTAssertFalse(ContentExtractor.supports(URL(string: "https://example.test/a.txt")!))
        XCTAssertFalse(ContentExtractor.supports(directory.appendingPathComponent("archive.zip")))
        XCTAssertThrowsError(try ContentExtractor.extract(url: directory.appendingPathComponent("a.xyz"))) { error in
            XCTAssertEqual(error as? ContentExtractionError, .unsupportedFormat("xyz"))
        }
    }

    func testPlainTextCSVAndSourcePreserveBoundaries() throws {
        for ext in ["txt", "md", "csv", "swift"] {
            let text = "搜索 繁體 日本語\nalpha,beta\nlet answer = 42\n"
            let result = try ContentExtractor.extract(url: file("sample.\(ext)", text: text))
            XCTAssertEqual(result.text, text); XCTAssertNil(result.warning)
        }
    }

    func testUTF16AndLegacyChineseText() throws {
        let text = "中文搜索\n第二自然段"
        var data = Data([0xff, 0xfe]); data.append(text.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try ContentExtractor.extract(url: file("utf16.txt", data: data)).text, text)
        let bomless = "Alpha\nBeta 中文"
        let inferred = try ContentExtractor.extract(url: file("bomless.txt", data: bomless.data(using: .utf16LittleEndian)!))
        XCTAssertEqual(inferred.text, bomless); XCTAssertNotNil(inferred.warning)
        XCTAssertEqual(try ContentExtractor.extract(url: file("bomless-be.txt", data: bomless.data(using: .utf16BigEndian)!)).text, bomless)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let result = try ContentExtractor.extract(url: file("legacy.txt", data: text.data(using: encoding)!))
        XCTAssertEqual(result.text, text); XCTAssertNotNil(result.warning)
    }

    func testHTMLRemovesResourcesAndPreservesParagraphsEntitiesAndCells() throws {
        let url = try file("page.html", text: "<html><head><style>private-style</style></head><body><!--private-comment--><script>private-script</script><p title='a > b'>苹果 &amp; 梨</p><p>日本語 &#x1F600;</p><table><tr><td>A</td><td>B &lt; C</td></tr></table></body></html>")
        let result = try ContentExtractor.extract(url: url)
        XCTAssertTrue(result.text.contains("苹果 & 梨\n日本語 😀"))
        XCTAssertTrue(result.text.contains("A\tB < C"))
        XCTAssertFalse(result.text.contains("private")); XCTAssertNil(result.warning)
    }

    func testDOCXParagraphRunsTableAndHeaders() throws {
        let url = try archive("tiny.docx", members: [
            "word/document.xml": "<w:document xmlns:w='urn:word'><w:body><w:p><w:r><w:t>第一</w:t></w:r><w:r><w:t>段落</w:t></w:r></w:p><w:p><w:r><w:t>second</w:t><w:tab/><w:t>tab</w:t><w:br/><w:t>line</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>左格</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>右格</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>",
            "word/header1.xml": "<w:hdr xmlns:w='urn:word'><w:p><w:r><w:t>页眉关键词</w:t></w:r></w:p></w:hdr>"
        ])
        let result = try ContentExtractor.extract(url: url)
        XCTAssertTrue(result.text.contains("第一段落\nsecond\ttab\nline"))
        XCTAssertTrue(result.text.contains("左格\t右格")); XCTAssertTrue(result.text.contains("页眉关键词"))
        XCTAssertNil(result.warning)
    }

    func testPPTXSlidesAndNotesBeyondTen() throws {
        var members: [String: String] = [:]
        for index in 1...12 { members["ppt/slides/slide\(index).xml"] = "<p:sld xmlns:p='urn:p' xmlns:a='urn:a'><a:p><a:r><a:t>slide \(index)</a:t></a:r></a:p><a:p><a:r><a:t>paragraph \(index)</a:t></a:r></a:p></p:sld>" }
        members["ppt/notesSlides/notesSlide12.xml"] = "<p:notes xmlns:p='urn:p' xmlns:a='urn:a'><a:p><a:r><a:t>speaker note</a:t></a:r></a:p></p:notes>"
        let result = try ContentExtractor.extract(url: archive("slides.pptx", members: members))
        XCTAssertEqual(result.pages, 12); XCTAssertTrue(result.text.contains("slide 12\nparagraph 12"))
        XCTAssertTrue(result.text.contains("speaker note"))
        XCTAssertNil(result.warning)
    }

    func testXLSXSharedInlineSparseAndCachedFormulaCells() throws {
        let url = try archive("book.xlsx", members: [
            "xl/sharedStrings.xml": "<sst><si><r><t>共享</t></r><r><t>文字</t></r></si></sst>",
            "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row r='1'><c r='A1' t='s'><v>0</v></c><c r='C1' t='inlineStr'><is><t>内联文字</t></is></c><c r='D1'><f>1+2</f><v>3</v></c></row><row r='2'><c r='A2' t='b'><v>1</v></c><c r='B2'><v>42</v></c></row></sheetData></worksheet>",
            "xl/worksheets/sheet2.xml": "<worksheet><sheetData><row><c r='A1' t='inlineStr'><is><t>第二工作表</t></is></c></row></sheetData></worksheet>"
        ])
        let result = try ContentExtractor.extract(url: url)
        XCTAssertTrue(result.text.contains("共享文字\t\t内联文字\t3\nTRUE\t42"))
        XCTAssertTrue(result.text.contains("第二工作表")); XCTAssertEqual(result.pages, 2); XCTAssertNil(result.warning)
    }

    func testXLSXMissingCachedFormulaWarns() throws {
        let url = try archive("formula.xlsx", members: ["xl/worksheets/sheet1.xml": "<worksheet><sheetData><row><c r='A1'><f>1+2</f></c><c r='B1' t='s'><v>99</v></c></row></sheetData></worksheet>"])
        let result = try ContentExtractor.extract(url: url)
        XCTAssertTrue(result.warning?.contains("公式") == true); XCTAssertTrue(result.warning?.contains("共享字符串") == true)
    }

    func testOfficeRelationshipsPreserveReorderedSlidesNotesAndSheets() throws {
        let slides = try archive("reordered.pptx", members: [
            "ppt/presentation.xml": "<p:presentation xmlns:p='urn:p' xmlns:r='urn:r'><p:sldIdLst><p:sldId r:id='second'/><p:sldId r:id='first'/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels": "<Relationships><Relationship Id='first' Type='urn:office/slide' Target='slides/one.xml'/><Relationship Id='second' Type='urn:office/slide' Target='slides/two.xml'/></Relationships>",
            "ppt/slides/one.xml": "<slide><p><r><t>first slide</t></r></p></slide>",
            "ppt/slides/two.xml": "<slide><p><r><t>second slide</t></r></p></slide>",
            "ppt/slides/_rels/two.xml.rels": "<Relationships><Relationship Id='note' Type='urn:office/notesSlide' Target='../notesSlides/custom.xml'/></Relationships>",
            "ppt/notesSlides/custom.xml": "<notes><p><r><t>related notes</t></r></p></notes>"
        ])
        let presentation = try ContentExtractor.extract(url: slides)
        XCTAssertEqual(presentation.text, "second slide\nrelated notes\n\nfirst slide"); XCTAssertEqual(presentation.pages, 2)
        XCTAssertNil(presentation.warning)
        let sheets = try archive("reordered.xlsx", members: [
            "xl/workbook.xml": "<workbook xmlns:r='urn:r'><sheets><sheet r:id='second'/><sheet r:id='first'/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id='first' Type='urn:office/worksheet' Target='worksheets/one.xml'/><Relationship Id='second' Type='urn:office/worksheet' Target='worksheets/two.xml'/></Relationships>",
            "xl/worksheets/one.xml": "<worksheet><sheetData><row><c r='A1' t='inlineStr'><is><t>first sheet</t></is></c></row></sheetData></worksheet>",
            "xl/worksheets/two.xml": "<worksheet><sheetData><row><c r='A1' t='inlineStr'><is><t>second sheet</t></is></c></row></sheetData></worksheet>"
        ])
        let workbook = try ContentExtractor.extract(url: sheets)
        XCTAssertEqual(workbook.text, "second sheet\n\nfirst sheet"); XCTAssertNil(workbook.warning)
    }

    func testEPUBUsesSpineOrderAndLiteralZIPMemberNames() throws {
        let url = try archive("novel.epub", members: [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='OPS/book.opf'/></rootfiles></container>",
            "OPS/book.opf": "<package><manifest><item id='first' href='chapters/../chapters/%5B01%5D.xhtml'/><item id='second' href='chapters/02.xhtml'/></manifest><spine><itemref idref='second'/><itemref idref='first'/></spine></package>",
            "OPS/chapters/[01].xhtml": "<html><body><p>第一章</p><p>自然段</p></body></html>",
            "OPS/chapters/02.xhtml": "<html><body><p>先阅读第二章</p></body></html>"
        ])
        let result = try ContentExtractor.extract(url: url)
        XCTAssertEqual(result.text, "先阅读第二章\n\n第一章\n自然段"); XCTAssertEqual(result.pages, 2); XCTAssertNil(result.warning)
    }

    func testRTFAndLegacyDOCUseSystemConversion() throws {
        let text = "Rich document 中文搜索\nSecond paragraph"
        let data = try NSAttributedString(string: text).data(from: NSRange(location: 0, length: (text as NSString).length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtf = try file("rich.rtf", data: data)
        XCTAssertTrue(try ContentExtractor.extract(url: rtf).text.contains(text))
        let doc = directory.appendingPathComponent("legacy.doc")
        try process("/usr/bin/textutil", ["-convert", "doc", "-output", doc.path, "--", rtf.path])
        XCTAssertTrue(try ContentExtractor.extract(url: doc).text.contains(text))
    }

    func testPDFReadsEverySelectablePage() throws {
        let result = try ContentExtractor.extract(url: pdf("long.pdf", selectablePages: 14), options: ExtractionOptions(ocrPDF: false))
        XCTAssertEqual(result.pages, 14); XCTAssertTrue(result.text.contains("Selectable page 14")); XCTAssertNil(result.warning)
    }

    func testMixedPDFOCRsImagePageAfterTen() throws {
        let result = try ContentExtractor.extract(url: pdf("mixed.pdf", selectablePages: 11, rasterText: "MIXED OCR PROBE 9281"))
        XCTAssertEqual(result.pages, 12); XCTAssertTrue(result.text.contains("Selectable page 11"))
        XCTAssertTrue(result.text.contains("MIXED OCR PROBE"), result.text); XCTAssertNil(result.warning)
        let range = try XCTUnwrap(result.pageRanges?.first { $0.page == 12 })
        let bytes = Array(result.text.utf8)
        let pageText = try XCTUnwrap(String(bytes: bytes[range.utf8Offset..<(range.utf8Offset + range.utf8Length)], encoding: .utf8))
        XCTAssertTrue(pageText.contains("MIXED OCR PROBE"), "扫描页OCR必须保存原始页码及正确UTF8范围")
    }

    func testDisabledPDFOCRWarnsForMissingTextLayer() throws {
        let result = try ContentExtractor.extract(url: pdf("scan.pdf", selectablePages: 0, rasterText: "SCAN TEXT"), options: ExtractionOptions(ocrPDF: false))
        XCTAssertTrue(result.text.isEmpty); XCTAssertTrue(result.warning?.contains("PDF OCR 已关闭") == true)
    }

    func testImageOCRMultilingualAndOptions() throws {
        let url = try png("ocr.png", lines: ["Miji Search OCR 2026", "简体中文 搜索内容", "繁體中文 日本語"])
        let result = try ContentExtractor.extract(url: url, options: ExtractionOptions(classifyImages: false))
        XCTAssertTrue(result.text.contains("Miji Search OCR"), result.text)
        XCTAssertTrue(result.text.contains("搜索"), result.text); XCTAssertTrue(result.text.contains("日本語"), result.text)
        XCTAssertEqual(result.pages, 1); XCTAssertTrue(result.labels.isEmpty); XCTAssertNil(result.warning)
        let disabled = try ContentExtractor.extract(url: url, options: ExtractionOptions(recognizeImages: false, classifyImages: false))
        XCTAssertTrue(disabled.text.isEmpty); XCTAssertNotNil(disabled.warning)
    }

    func testImageClassificationAndChineseAliases() throws {
        let result = try ContentExtractor.extract(url: png("classification.png", lines: ["Receipt", "Total 128.00", "Thank you"]), options: ExtractionOptions(recognizeImages: false))
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertFalse(result.labels.isEmpty, result.warning ?? "No classifications")
        let labels = ImageSearchAliases.labels(for: ["cat", "beach", "mountain", "screenshot", "dogs"])
        for label in ["cat", "猫", "貓", "海滩", "山", "截图", "狗"] { XCTAssertTrue(labels.contains(label)) }
    }

    func testIWorkPreviewAndMissingPreviewWarning() throws {
        let preview = try pdf("preview.pdf", selectablePages: 1)
        let package = directory.appendingPathComponent("tiny.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("QuickLook"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: preview, to: package.appendingPathComponent("QuickLook/Preview.pdf"))
        let result = try ContentExtractor.extract(url: package)
        XCTAssertTrue(result.text.contains("Selectable page 1")); XCTAssertTrue(result.warning?.contains("预览") == true)
        let missing = try archive("empty.numbers", members: ["Index/Document.iwa": "fixture"])
        let empty = try ContentExtractor.extract(url: missing)
        XCTAssertTrue(empty.text.isEmpty); XCTAssertTrue(empty.warning?.contains("IWA") == true)
    }

    func testSystemImporterReadsCurrentFileAfterModification() throws {
        let url = try file("fresh.rtf", text: "{\\rtf1\\ansi Initial Miji text 3291\\par Original paragraph}")
        let first = try SystemDocumentImporter.extract(url, context: ExtractionContext(cancelled: { false }))
        XCTAssertTrue(first.text.contains("Initial Miji text 3291"))
        _ = try file("fresh.rtf", text: "{\\rtf1\\ansi Updated Miji text 7942\\par Changed paragraph}")
        let updated = try SystemDocumentImporter.extract(url, context: ExtractionContext(cancelled: { false }))
        XCTAssertTrue(updated.text.contains("Updated Miji text 7942"))
        XCTAssertFalse(updated.text.contains("Initial Miji text 3291"))
    }

    func testSystemImportPlistFormatsNullAndInvalidResults() throws {
        let context = ExtractionContext(cancelled: { false })
        let attributes: [String: Any] = ["kMDItemTextContent": "first\n搜索 日本語", "kMDItemNumberOfPages": 3]
        for format: PropertyListSerialization.PropertyListFormat in [.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: attributes, format: format, options: 0)
            let parsed = try SystemDocumentImporter.parse(data, context: context)
            XCTAssertEqual(parsed.text, "first\n搜索 日本語"); XCTAssertEqual(parsed.pages, 3)
        }
        let openStep = Data("{ kMDItemTextContent = \"first\\nsecond \\U641c\\U7d22\"; kMDItemNumberOfPages = 3; }".utf8)
        let parsed = try SystemDocumentImporter.parse(openStep, context: context)
        XCTAssertEqual(parsed.text, "first\nsecond 搜索"); XCTAssertEqual(parsed.pages, 3)
        for text in ["<null>", "(null)"] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["kMDItemTextContent": text], format: .binary, options: 0)
            XCTAssertTrue(try SystemDocumentImporter.parse(data, context: context).text.isEmpty)
        }
        XCTAssertTrue(try SystemDocumentImporter.parse(Data("{}".utf8), context: context).text.isEmpty)
        XCTAssertThrowsError(try SystemDocumentImporter.parse(Data("not a plist".utf8), context: context))
        XCTAssertThrowsError(try SystemDocumentImporter.parse(Data("{ kMDItemTextContent = (a, b); }".utf8), context: context))
    }

    func testSystemImporterTextBudgetAndProcessOutputFileLimits() throws {
        let text = String(repeating: "x", count: ExtractionLimits.textBytes + 100)
        let data = try PropertyListSerialization.data(fromPropertyList: ["kMDItemTextContent": text], format: .binary, options: 0)
        let context = ExtractionContext(cancelled: { false })
        context.append(try SystemDocumentImporter.parse(data, context: context).text)
        let result = context.result()
        XCTAssertEqual(result.text.utf8.count, ExtractionLimits.textBytes)
        XCTAssertTrue(result.warning?.contains("截断") == true)
        let output = directory.appendingPathComponent("oversized.plist")
        XCTAssertThrowsError(try runExtractionProcess("/bin/dd", arguments: ["if=/dev/zero", "of=\(output.path)", "bs=4096", "count=1"], limit: 1000,
                                                     context: ExtractionContext(cancelled: { false }), outputFile: output, outputFileLimit: 1024)) { error in
            guard case ContentExtractionError.resourceLimit = error else { return XCTFail("Expected output file limit: \(error)") }
        }
        let start = Date()
        XCTAssertThrowsError(try runExtractionProcess("/bin/sleep", arguments: ["2"], limit: 100,
                                                     context: ExtractionContext(cancelled: { false }), timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testIWorkJPEGPreviewFallbackForPackageAndZIP() throws {
        let picture = directory.appendingPathComponent("preview.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(picture as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(["PREVIEW ONLY 4821"]), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        for (name, filename, zipped) in [("picture.pages", "preview.jpg", false), ("picture.key", "Preview.jpg", true)] {
            let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("QuickLook"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: picture, to: root.appendingPathComponent("QuickLook/\(filename)"))
            let url = directory.appendingPathComponent(name)
            if zipped { try process("/usr/bin/zip", ["-q", "-r", url.path, "."], cwd: root) }
            else { try FileManager.default.moveItem(at: root, to: url) }
            let result = try ContentExtractor.extract(url: url)
            XCTAssertTrue(result.text.contains("PREVIEW ONLY 4821"), result.text)
            XCTAssertTrue(result.warning?.contains("无法代表完整正文") == true)
            XCTAssertTrue(result.warning?.contains("系统即时导入") == true)
            let disabled = try ContentExtractor.extract(url: url, options: ExtractionOptions(recognizeImages: false))
            XCTAssertTrue(disabled.text.isEmpty); XCTAssertTrue(disabled.warning?.contains("OCR 已关闭") == true)
        }
    }

    func testLegacyOfficeWithoutImportableTextHasWarning() throws {
        for ext in ["ppt", "xls"] {
            let result = try ContentExtractor.extract(url: file("corrupt.\(ext)", text: "not an Office document"))
            XCTAssertTrue(result.text.isEmpty); XCTAssertTrue(result.warning?.contains("系统即时导入") == true)
        }
    }


    func testLegacyOfficeImporterReadsGeneratedBinaryFixtures() throws {
        // Independently authored one-cell/one-slide documents, converted once from
        // our FODS/FODP XML with headless LibreOffice. Only document streams remain.
        // The embedded ZIP keeps this regression independent of fixture generators.
        let encoded = """
        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
        """
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let fixture = try file("legacy-fixtures.zip", data: data)
        let archive = try BoundedArchive(url: fixture, context: ExtractionContext(cancelled: { false }))
        for (name, keyword) in [("sheet.xls", "Miji legacy XLS 8246"), ("slides.ppt", "Miji legacy PPT 5391")] {
            let url = try file(name, data: archive.read(name))
            let result = try ContentExtractor.extract(url: url)
            XCTAssertTrue(result.text.contains(keyword), result.text)
            XCTAssertNil(result.warning)
        }
    }

    func testTextTruncationHasWarningAndValidUnicode() throws {
        let data = Data(String(repeating: "搜索🙂", count: 900_000).utf8)
        let result = try ContentExtractor.extract(url: file("large.txt", data: data))
        XCTAssertFalse(result.text.contains("�")); XCTAssertTrue(result.text.utf8.count <= ExtractionLimits.textBytes)
        XCTAssertTrue(result.warning?.contains("截断") == true)
    }

    func testRejectsOversizedInputZIPExpansionAndInvalidXML() throws {
        let large = try file("oversized.pdf", data: Data())
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: UInt64(ExtractionLimits.inputBytes + 1)); try handle.close()
        XCTAssertThrowsError(try ContentExtractor.extract(url: large)) { XCTAssertTrue($0 is ContentExtractionError) }
        let archiveURL = try archive("bomb.docx", members: ["word/document.xml": "<document/>" ])
        var bytes = try Data(contentsOf: archiveURL)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let entry = try XCTUnwrap(bytes.range(of: signature))
        let offset = entry.lowerBound + 24, size = UInt32(ExtractionLimits.memberBytes + 1)
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: size >> (index * 8)) }
        try bytes.write(to: archiveURL)
        XCTAssertThrowsError(try ContentExtractor.extract(url: archiveURL)) { error in
            guard case ContentExtractionError.resourceLimit = error else { return XCTFail("Expected resource limit: \(error)") }
        }
        let invalid = try archive("broken.docx", members: ["word/document.xml": "<document><unclosed>" ])
        XCTAssertThrowsError(try ContentExtractor.extract(url: invalid))
        let entity = try archive("entities.docx", members: ["word/document.xml": "<!DOCTYPE document [<!ENTITY private 'injected'>]><document><p><t>&private;</t></p></document>" ])
        XCTAssertThrowsError(try ContentExtractor.extract(url: entity))
    }

    func testCancellationBeforeReadsAndDuringParsingAndProcess() throws {
        XCTAssertThrowsError(try ContentExtractor.extract(url: directory.appendingPathComponent("missing.txt"), cancelled: { true })) { XCTAssertEqual($0 as? ContentExtractionError, .cancelled) }
        var checks = 0
        let xmlContext = ExtractionContext(cancelled: { checks += 1; return checks > 20 })
        let xml = "<document>" + String(repeating: "<p><t>paragraph</t></p>", count: 100) + "</document>"
        XCTAssertThrowsError(try parseDocumentXML(Data(xml.utf8), context: xmlContext)) { XCTAssertEqual($0 as? ContentExtractionError, .cancelled) }
        let start = Date()
        let processContext = ExtractionContext(cancelled: { Date().timeIntervalSince(start) > 0.1 })
        XCTAssertThrowsError(try runExtractionProcess("/bin/sleep", arguments: ["5"], limit: 100, context: processContext)) { XCTAssertEqual($0 as? ContentExtractionError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCorruptImagesPDFAndEmptyTextDoNotSilentlySucceed() throws {
        for ext in ["png", "pdf", "docx"] {
            XCTAssertThrowsError(try ContentExtractor.extract(url: file("bad.\(ext)", text: "not a document")))
        }
        let result = try ContentExtractor.extract(url: file("empty.txt", text: ""))
        XCTAssertTrue(result.text.isEmpty); XCTAssertNotNil(result.warning)
    }
}
