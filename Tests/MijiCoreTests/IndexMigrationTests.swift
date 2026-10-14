import XCTest
import CSQLite
@testable import MijiCore

final class IndexMigrationTests: XCTestCase {
    func testLosslessMigrationPreservesSignaturesOfflineAndPendingWithoutExtraction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.sqlite"), new = directory.appendingPathComponent("new.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(old.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let root = IndexedRoot(id: "disk", path: "/Volumes/离线", isExternal: true, isOnline: false)
        let content = ExtractedContent(text: "数学\u{0}OCR 中文 😀 " + String(repeating: "same text\n", count: 5000), labels: ["图片", "train"], pages: 12, warning: "历史部分内容")
        let encoder = JSONEncoder()
        let raw = String(decoding: try encoder.encode(content), as: UTF8.self)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let schema = """
            CREATE TABLE roots(id TEXT PRIMARY KEY,payload TEXT,online INTEGER,enabled INTEGER);
            CREATE TABLE files(id INTEGER PRIMARY KEY,root_id TEXT,relative_path TEXT,name TEXT,extension TEXT,kind TEXT,size INTEGER,modified REAL,inode INTEGER,content_state TEXT,content_error TEXT,generation INTEGER,name_search TEXT,pinyin_search TEXT,initials_search TEXT,path_search TEXT,content TEXT);
            PRAGMA user_version=1;
            INSERT INTO roots VALUES('disk',\(quote(String(decoding: try encoder.encode(root), as: UTF8.self))),0,1);
            INSERT INTO files VALUES(42,'disk','数学.pdf','数学.pdf','pdf','document',123,1234.5,88,'done',NULL,19,'数学.pdf','shuxuepdf','sxpdf','数学.pdf',\(quote(raw)));
            INSERT INTO files VALUES(99,'disk','副本.pdf','副本.pdf','pdf','document',123,1234.5,89,'error','保留错误',19,'副本.pdf','fubenpdf','fbpdf','副本.pdf',\(quote(raw)));
            INSERT INTO files VALUES(100,'disk','pending.png','pending.png','png','image',32,5678,99,'pending',NULL,20,'pending.png','pendingpng','pp','pending.png',NULL);
            """
        XCTAssertEqual(sqlite3_exec(connection, schema, nil,nil,nil), SQLITE_OK)
        let original = try Data(contentsOf: old)
        try SearchDatabase.migrateLegacy(from: old, to: new)
        XCTAssertEqual(try Data(contentsOf: old), original)
        let database = try SearchDatabase(url: new)
        XCTAssertEqual(try database.statistics().files, 3)
        XCTAssertEqual(try database.statistics().indexedContent, 2)
        XCTAssertEqual(try database.statistics().pending, 1)
        XCTAssertEqual(try database.statistics().errors, 1)
        XCTAssertEqual(try database.roots(), [root])
        XCTAssertEqual(try database.storedContent(fileID: 42), content)
        XCTAssertEqual(try database.storedContent(fileID: 99), content)
        XCTAssertEqual(Set(try database.search("OCR", options: SearchOptions(scope: .content)).map(\.id)), [42,99])
        XCTAssertTrue(try database.search("OCR", options: SearchOptions(onlineOnly: true)).isEmpty)
        let names = try database.nameHits(ids: [42,99], query: "数学")
        XCTAssertTrue(names.allSatisfy { $0.snippet.isEmpty })
        XCTAssertEqual(names.first?.file.inode, 88)
        XCTAssertEqual(names.first?.file.modified, 1234.5)
        let bodyCount = try database.prepare("SELECT count(*) FROM content_blobs")
        XCTAssertTrue(try database.next(bodyCount)); XCTAssertEqual(sqlite3_column_int(bodyCount,0), 1)
        sqlite3_finalize(bodyCount)
        // A restart at the last committed ID is idempotent, with no OCR work.
        try SearchDatabase.migrateLegacy(from: old, to: new)
        XCTAssertEqual(try database.statistics().files, 3)
        var unchanged = try XCTUnwrap(names.first?.file)
        unchanged.contentState = "pending"
        try database.upsertFiles([unchanged], generation: 21)
        XCTAssertEqual(try database.storedContent(fileID: 42), content)
        XCTAssertEqual(try database.pendingFiles(rootID: "disk").map(\.id), [100])
    }

    func testSharedBodySurvivesDeletingOneReferenceAndChangedSignaturesRequeue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try SearchDatabase(url: directory.appendingPathComponent("index.sqlite"))
        try db.saveRoot(IndexedRoot(id:"r",path:directory.path))
        for name in ["a.txt","b.txt"] { try db.upsertFiles([FileRecord(rootID:"r",relativePath:name,name:name,fileExtension:"txt",kind:.document,size:10,modified:1,inode:1)],generation:1) }
        let files = try db.pendingFiles(rootID:"r")
        let content = ExtractedContent(text:"内容不应重识别")
        for file in files { XCTAssertTrue(try db.completeContent(file:file,content:content)) }
        var first = files[0]; first.size += 1
        try db.upsertFiles([first],generation:2)
        XCTAssertNil(try db.storedContent(fileID:first.id))
        XCTAssertEqual(try db.storedContent(fileID:files[1].id),content)
        XCTAssertEqual(try db.search("不应重识别").map(\.id),[files[1].id])
        XCTAssertFalse(try db.completeContent(file:files[0],content:content))
    }
}
