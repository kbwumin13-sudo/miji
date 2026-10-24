import XCTest
import Foundation
@testable import MijiCore

/// Full-text pages that stop once filled, and name ranking by match type,
/// location and recent opens.
final class RankingAndPagingTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var db: SearchDatabase!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("miji-ranking-\(UUID().uuidString)")
        url = directory.appendingPathComponent("index.sqlite")
        db = try SearchDatabase(url: url)
        try db.saveRoot(IndexedRoot(id: "r", path: "/"))
    }
    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Doc { let path: String; let size: Int64; let modified: Double; let text: String }
    @discardableResult
    private func add(_ docs: [Doc]) throws -> [String: Int64] {
        try db.upsertFiles(docs.enumerated().map { i, doc in
            let name = (doc.path as NSString).lastPathComponent
            return FileRecord(rootID: "r", relativePath: doc.path, name: name, fileExtension: (name as NSString).pathExtension,
                              kind: .document, size: doc.size, modified: doc.modified, inode: Int64(i + 1))
        }, generation: 1)
        var ids: [String: Int64] = [:]
        let pending = try db.pendingFiles(rootID: "r", limit: 100_000)
        for doc in docs {
            let file = try XCTUnwrap(pending.first { $0.relativePath == doc.path })
            XCTAssertTrue(try db.completeContent(file: file, content: ExtractedContent(text: doc.text)))
            ids[doc.path] = file.id
        }
        return ids
    }

    func testSortedContentPagesEqualTheFullRanking() throws {
        // Matches, near misses (all trigrams, not the phrase), a shared body
        // reached out of content order, and an excluded word in some bodies.
        var docs: [Doc] = []
        for i in 0..<900 {
            let text: String
            switch i % 6 {
            case 0: text = "公共正文 needle phrase \(i % 2)"   // two shared bodies
            case 1: text = "needle phrase and blocked word \(i)"
            case 2: text = "phrase needle reversed \(i)"
            default: text = "the needle phrase number \(i)"
            }
            docs.append(Doc(path: "Users/me/Documents/d\(i % 7)/file-\(String(format: "%04d", (i * 37) % 900)).txt",
                            size: Int64((i * 7919) % 4_000), modified: Double((i * 104_729) % 100_000), text: text))
        }
        let ids = try add(docs)
        let matching = docs.filter { $0.text.contains("needle phrase") && !$0.text.contains("blocked") }
        for sort in [SearchSort.modified, .size, .name] {
            let expected = matching.sorted { a, b in
                let na = QueryParser.normalize((a.path as NSString).lastPathComponent), nb = QueryParser.normalize((b.path as NSString).lastPathComponent)
                switch sort {
                case .modified where a.modified != b.modified: return a.modified > b.modified
                case .size where a.size != b.size: return a.size > b.size
                default: return na == nb ? ids[a.path]! < ids[b.path]! : na < nb
                }
            }.prefix(120).map { ids[$0.path]! }
            let page = try db.searchSupplementary("\"needle phrase\" -blocked", options: SearchOptions(scope: .content, sort: sort, limit: 120))
            XCTAssertEqual(page.map(\.id), Array(expected), "\(sort)")
            XCTAssertTrue(page.allSatisfy { $0.snippet.contains("needle phrase") })
        }
    }

    func testRelevancePagesListOwnRecentFilesFirstAndStayVerified() throws {
        var docs: [Doc] = []
        for i in 0..<60 {
            let folder = ["Users/me/Documents", "Users/me/Library/Caches/app", "Users/me/code/node_modules/pkg", "Users/me/.config", "System/Library"][i % 5]
            docs.append(Doc(path: "\(folder)/n\(i).txt", size: 1, modified: Double(i), text: i % 10 == 9 ? "no match here" : "target words \(i)"))
        }
        let ids = try add(docs)
        var partials: [[Int64]] = []
        let page = try db.searchSupplementary("target", options: SearchOptions(scope: .content, limit: 20), onPartial: { partials.append($0.map(\.id)) })
        // The page is the 20 most recently stored verified bodies (here the
        // last ones added), shown with own files first, newest first.
        let first = docs.filter { $0.text.contains("target") }.suffix(20)
        let own = first.filter { $0.path.hasPrefix("Users/me/Documents") }.sorted { $0.modified > $1.modified }
        let others = first.filter { !$0.path.hasPrefix("Users/me/Documents") }.sorted { $0.modified > $1.modified }
        XCTAssertEqual(page.map(\.id), (own + others).map { ids[$0.path]! })
        XCTAssertEqual(page.count, 20, "页面填满即停")
        XCTAssertTrue(partials.allSatisfy { $0.count <= 20 })
        // The full pass (search) keeps name matches first, then the same body order.
        let all = try db.search("n1", options: SearchOptions(scope: .all, limit: 5)).map(\.id)
        XCTAssertEqual(all.first, ids["Users/me/Documents/n1.txt"] ?? ids[docs[1].path])
    }

    func testNameRankingPrefersExactPrefixOwnFoldersAndRecentOpens() throws {
        try db.upsertFiles(["Users/me/Documents/report.pdf", "Users/me/Documents/old report draft.pdf",
                            "Users/me/Library/Caches/report.pdf", "Users/me/Documents/report-2024.pdf"].enumerated().map { i, path in
            FileRecord(rootID: "r", relativePath: path, name: (path as NSString).lastPathComponent, fileExtension: "pdf",
                       kind: .document, size: 1, modified: 1, inode: Int64(i + 1))
        }, generation: 1)
        let ids = Dictionary(uniqueKeysWithValues: try db.pendingFiles(rootID: "r", limit: 10).map { ($0.relativePath, $0.id) })
        let engine = try NameSearchEngine(databaseURL: url)
        try engine.load()
        let own = ids["Users/me/Documents/report.pdf"]!, draft = ids["Users/me/Documents/old report draft.pdf"]!
        let cached = ids["Users/me/Library/Caches/report.pdf"]!, dated = ids["Users/me/Documents/report-2024.pdf"]!
        // Stem match 210 > prefix 190 = cached stem match 190 (less 20 for its
        // folder; the tie goes by name) > substring 169.
        XCTAssertEqual(try engine.search("report"), [own, dated, cached, draft])
        for _ in 0..<10 { engine.recordOpen(draft) }
        XCTAssertEqual(try engine.search("report"), [own, draft, dated, cached], "打开过的文件在同类匹配中上浮")
        XCTAssertEqual(try engine.search("report", options: SearchOptions(sort: .name)), [draft, dated, own, cached], "非相关度排序不受影响")
        // Opens persist beside the index.
        let restarted = try NameSearchEngine(databaseURL: url)
        try restarted.load()
        XCTAssertEqual(try restarted.search("report"), [own, draft, dated, cached])
    }

    func testBodyTermChecksMatchNormalizedContains() {
        let bodies = ["README for the Project", "readme.md\nSecond LINE", "数学分析期末复习 README", "混合 Mixed Café 数学",
                      "cafe\u{301} au lait", "ÉCOLE École école", "Ｆｕｌｌ width ＡＢＣ", "", "数学", "x\u{0}y needle",
                      String(repeating: "abc", count: 5_000) + "needle", "İstanbul KELVIN \u{212A}", "ǅungla ǆ", "tab\tsep",
                      // Clusters that a byte match would split (review findings).
                      "भारतीय संविधान", "किताब", "👍🏽 ok 👍", "葛\u{FE00}城 葛", "q\u{301}x q", "line\r\nnext\n",
                      "👨\u{200D}👩\u{200D}👧 family 👩", "🇺🇸🇫🇷 flags", "\u{1100}\u{1161}\u{11A8} 각", "\u{F900} 豈 compat",
                      "\u{0600}123 arabic", "ab\u{200C}cd zwnj", "e\u{301}\u{323}x ẹ́x",
                      "क्षमा स्त्री", "ক্ষমা", "กำลังทำงาน", "ນຳ", "x\u{200B}\u{301}y", "a\u{2028}\u{301}b",
                      "가\u{11A8} only", "각 composed", "क\u{94D}🏻र", "ก\u{200B}ท co\u{AD}operate", "\u{600}123 \u{E0067}x"]
        let terms = ["readme", "the", "数学", "数学分析", "café", "école", "ａｂｃ", "needle", "x\u{0}y", "istanbul", "k", "ǆ", "\t", "absent",
                     "भारत", "क", "👍", "葛", "q", "\n", "\r", "👩", "🇸🇫", "🇫🇷", "\u{1100}", "각", "豈", "123", "ab", "cd", "x", "ẹ́",
                     "षमा", "त्री", "स्", "ষমা", "ก", "ท", "ນ", "\u{301}y", "\u{301}b",
                     "각", "가\u{11A8}", "only", "क\u{94D}🏻", "operate", "x"]
            .map(QueryParser.normalize)
        for body in bodies {
            for han in [false, true] {
                let group = han ? terms.filter { $0.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains($0.value) } } : terms
                guard !group.isEmpty else { continue }
                let reference = group.map { term -> Bool in
                    if han && group.allSatisfy({ body.contains($0) }) { return true }
                    return QueryParser.normalize(body).contains(term)
                }
                XCTAssertEqual(SearchDatabase.bodyHits(body, group, hanTerms: han), reference, body.debugDescription)
            }
        }
    }

    func testOpenHistoryDecaysPrunesAndCapsItsLift() throws {
        let history = OpenHistory(url: directory.appendingPathComponent("opens.json"), database: "db-1")
        let start = 1_000_000.0, day = 86_400.0
        history.record(7, now: start)
        XCTAssertEqual(history.boosts(now: start)[7], 8)                   // 12·ln 2
        XCTAssertEqual(history.boosts(now: start + 14 * day)[7], 4)        // half life
        XCTAssertNil(history.boosts(now: start + 70 * day)[7])
        for _ in 0..<200 { history.record(8, now: start) }
        XCTAssertEqual(history.boosts(now: start)[8], 30)
        history.record(9, now: start + 70 * day)
        let reloaded = OpenHistory(url: directory.appendingPathComponent("opens.json"), database: "db-1")
        XCTAssertNil(reloaded.boosts(now: start + 70 * day)[7], "衰减殆尽的记录被清理")
        XCTAssertEqual(reloaded.boosts(now: start + 70 * day)[9], 8)
        let recreated = OpenHistory(url: directory.appendingPathComponent("opens.json"), database: "db-2")
        XCTAssertTrue(recreated.boosts(now: start + 70 * day).isEmpty, "重建的数据库不继承旧 ID 的打开记录")
    }
}
