import XCTest
import Foundation
@testable import MijiCore

/// The direct reader of stored content must agree with JSONDecoder: the same
/// value wherever it accepts the JSON, and JSONDecoder's answer elsewhere.
final class ContentReaderTests: XCTestCase {
    private func direct(_ data: Data) -> ExtractedContent? {
        data.withUnsafeBytes { bytes in
            var reader = ContentJSONReader(bytes: bytes.bindMemory(to: UInt8.self))
            return reader.read()
        }
    }
    /// String equality is canonical equivalence; the reader must return the same bytes.
    private func exact(_ content: ExtractedContent?) -> [[UInt8]]? {
        content.map { [Array($0.text.utf8), Array(String($0.pages).utf8), $0.warning.map { Array($0.utf8) } ?? [0xFF]] + $0.labels.map { Array($0.utf8) } }
    }
    private func assertAgrees(_ data: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let reference = try? JSONDecoder().decode(ExtractedContent.self, from: data)
        if let value = direct(data) { XCTAssertEqual(exact(value), exact(reference), message, file: file, line: line) }
        switch (Result { try ContentCodec.content(data, decoder: JSONDecoder()) }, reference) {
        case (.success(let value), let reference?): XCTAssertEqual(exact(value), exact(reference), message, file: file, line: line)
        case (.failure, nil): break
        default: XCTFail("与 JSONDecoder 结果不一致：\(message)", file: file, line: line)
        }
    }

    func testEncodedContentReadsDirectlyAndEqualsJSONDecoder() throws {
        var pieces = ["", "a", "\"", "\\", "/", "//", "\u{7F}", "\u{2028}\u{2029}", "数学分析", "👍🏽", "𝒳", "e\u{301}", "é", "\u{AC00}\u{11A8}", "\u{FEFF}",
                      "line\nnext\r\n\ttab", "\u{0}\u{1}\u{1F}\u{8}\u{C}", "\\u0041", "</script>", "引号\"与\\反斜杠"]
        pieces += (0..<32).map { String(UnicodeScalar(UInt8($0))) }
        var generator = SystemRandomNumberGenerator()
        var contents = [ExtractedContent(), ExtractedContent(text: "", labels: [""], pages: Int.max, warning: ""),
                        ExtractedContent(text: "x", labels: ["猫", "狗/犬"], pages: Int.min, warning: "部分页面未识别")]
        for _ in 0..<300 {
            let text = (0..<Int.random(in: 0...60, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            let labels = (0..<Int.random(in: 0...3, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }
            contents.append(ExtractedContent(text: text, labels: labels, pages: Int.random(in: -5...5_000, using: &generator),
                                             warning: Bool.random(using: &generator) ? nil : pieces.randomElement(using: &generator)))
        }
        contents.append(ExtractedContent(text: String(repeating: "第\(1)页/共\n\"引\"\\ ", count: 40_000), labels: [], pages: 7))
        let formats: [JSONEncoder.OutputFormatting] = [[], .sortedKeys, .prettyPrinted, .withoutEscapingSlashes, [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]]
        for format in formats {
            let encoder = JSONEncoder()
            encoder.outputFormatting = format
            for content in contents {
                let data = try encoder.encode(content)
                XCTAssertEqual(exact(direct(data)), exact(content), "直接读取 \(format)")
                XCTAssertEqual(exact(try ContentCodec.content(data, decoder: JSONDecoder())), exact(content))
            }
        }
    }

    func testOtherJSONGetsJSONDecodersAnswer() {
        let cases: [String] = [
            #"{"text":"a","labels":[],"pages":1}"#,
            " \n{ \"text\" : \"a\" ,\t\"labels\" : [ \"x\" , \"y\" ] , \"pages\" : 0 , \"warning\" : null }\r\n",
            #"{"pages":2,"warning":"w","labels":["b"],"text":"éé😀\/\b\f\n\r\t\"\\"}"#,
            #"{"text":"\ud83d","labels":[],"pages":1}"#,
            #"{"text":"\udc00x","labels":[],"pages":1}"#,
            #"{"text":"\ud83dA","labels":[],"pages":1}"#,
            #"{"text":"\x","labels":[],"pages":1}"#,
            #"{"text":"\u12","labels":[],"pages":1}"#,
            #"{"text":"\u12g4","labels":[],"pages":1}"#,
            #"{"text":"abc"#,
            "{\"text\":\"a\u{1}b\",\"labels\":[],\"pages\":1}",
            "{\"text\":\"a\nb\",\"labels\":[],\"pages\":1}",
            #"{"text":"a","text":"b","labels":[],"pages":1}"#,
            #"{"text":"a","labels":[],"pages":1,"warning":null,"warning":"x"}"#,
            #"{"text":"a","labels":[],"pages":1,"extra":5}"#,
            #"{"text":"a","labels":[],"pages":1}"#,
            #"{"text":"a","labels":[],"pages":1.0}"#,
            #"{"text":"a","labels":[],"pages":1e2}"#,
            #"{"text":"a","labels":[],"pages":-0}"#,
            #"{"text":"a","labels":[],"pages":01}"#,
            #"{"text":"a","labels":[],"pages":-}"#,
            #"{"text":"a","labels":[],"pages":9223372036854775807}"#,
            #"{"text":"a","labels":[],"pages":9223372036854775808}"#,
            #"{"text":"a","labels":[],"pages":-9223372036854775808}"#,
            #"{"text":"a","labels":[],"pages":-9223372036854775809}"#,
            #"{"text":"a","labels":[],"pages":"1"}"#,
            #"{"text":"a","pages":1}"#,
            #"{"text":null,"labels":[],"pages":1}"#,
            #"{"text":"a","labels":[1],"pages":1}"#,
            #"{"text":"a","labels":["x",],"pages":1}"#,
            #"{"text":"a","labels":[],"pages":1,}"#,
            #"{"text":"a","labels":[],"pages":1} x"#,
            #"{"text":"a","labels":[],"pages":1}}"#,
            #"{"text":"a","labels":[],"pages":1,"warning":nul}"#,
            #"{"text":"a","labels":[],"pages":1,"warning":nullx}"#,
            "\u{FEFF}{\"text\":\"a\",\"labels\":[],\"pages\":1}",
            "", "{}", "[]", "null", #""text""#,
        ]
        for json in cases { assertAgrees(Data(json.utf8), json) }
        // Bytes that are not UTF-8 inside a string: a lone continuation, an
        // overlong form, a truncated four-byte sequence, a surrogate encoding.
        for bad: [UInt8] in [[0x80], [0xFF], [0xC0, 0xAF], [0xF0, 0x9F, 0x98], [0xED, 0xA0, 0x80], [0xE6, 0x95]] {
            var data = Data(#"{"text":"a"#.utf8)
            data.append(contentsOf: bad)
            data.append(contentsOf: Array(#"b","labels":[],"pages":1}"#.utf8))
            XCTAssertNil(direct(data))
            assertAgrees(data, "\(bad)")
        }
    }
}
