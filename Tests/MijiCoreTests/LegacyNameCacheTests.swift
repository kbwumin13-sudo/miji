import XCTest
import Foundation
import CryptoKit
import OilFindCore
@testable import MijiCore

final class LegacyNameCacheTests: XCTestCase {
    func testLegacyDerivedCacheFallsBackWithoutChangingExistingContentOrFileIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let database = try SearchDatabase(url: url)
        try database.saveRoot(IndexedRoot(id: "offline", path: directory.path, isExternal: true, isOnline: false))
        let names = ["数学分析.pdf", "数学分析.pdf", "README.txt"]
        try database.upsertFiles(names.enumerated().map { i, name in
            FileRecord(rootID: "offline", relativePath: "\(i)/\(name)", name: name,
                       fileExtension: i == 2 ? "txt" : "pdf", kind: .document, size: 10, modified: 1, inode: Int64(i + 1))
        }, generation: 1)
        let pending = try database.pendingFiles(rootID: "offline", limit: 10)
        for file in pending {
            XCTAssertTrue(try database.completeContent(file: file, content: ExtractedContent(text: "离线正文哨兵", labels: ["文档"], pages: 1)))
        }
        let originalIDs = pending.map(\.id).sorted()
        let engine = try NameSearchEngine(databaseURL: url)
        try engine.load(); try engine.saveCache()
        let cacheURL = NameSnapshotCache.url(for: url)
        let saved = try Data(contentsOf: cacheURL)
        // The outer metadata blocks are unchanged. Replace just the derived
        // name payload with the exact previous-version CompactNameIndex format.
        var cursor = 8
        for _ in 0..<8 {
            let length = saved.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self).littleEndian }
            cursor += 8 + Int(length)
        }
        let previous = CompactNameIndex()
        for name in names { try previous.append(QueryParser.normalize(name)) }
        let payload = previous.serialized()
        var legacy = Data(saved.prefix(cursor)), size = UInt64(payload.count).littleEndian
        withUnsafeBytes(of: &size) { legacy.append(contentsOf: $0) }
        legacy.append(payload)
        legacy.append(contentsOf: SHA256.hash(data: legacy))
        try legacy.write(to: cacheURL, options: .atomic)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber

        let upgraded = try NameSearchEngine(databaseURL: url)
        try upgraded.load()
        XCTAssertEqual(try upgraded.search("shuxue"), Array(originalIDs.prefix(2)))
        XCTAssertEqual(try upgraded.search("sxfx"), Array(originalIDs.prefix(2)))
        XCTAssertEqual(try upgraded.search("README"), [originalIDs[2]])
        XCTAssertTrue(try upgraded.search("数学", options: SearchOptions(onlineOnly: true)).isEmpty)
        XCTAssertEqual(try database.search("离线正文哨兵", options: SearchOptions(scope: .content)).map(\.id).sorted(), originalIDs)
        XCTAssertEqual(try database.statistics().indexedContent, 3)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode)
        try upgraded.saveCache()
        let restarted = try NameSearchEngine(databaseURL: url)
        try restarted.load()
        XCTAssertEqual(try restarted.search("shuxue"), Array(originalIDs.prefix(2)))
        XCTAssertEqual(try database.search("离线正文哨兵", options: SearchOptions(scope: .content)).map(\.id).sorted(), originalIDs)
    }
}
