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
        // Start from the version 1 layout that earlier releases wrote.
        try NameSnapshotCache.saveStreamed(NameSnapshotCache.load(database: url, revision: 3), database: url)
        let saved = try Data(contentsOf: cacheURL)
        XCTAssertEqual(saved.prefix(8), Data("MJNAME01".utf8))
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
        XCTAssertEqual(try Data(contentsOf: cacheURL).prefix(8), Data("MJNAME02".utf8), "不兼容的旧缓存回退重建后写成新格式")
        let restarted = try NameSearchEngine(databaseURL: url)
        try restarted.load()
        XCTAssertTrue(try NameSnapshotCache.load(database: url, revision: 3).isMapped)
        XCTAssertEqual(try restarted.search("shuxue"), Array(originalIDs.prefix(2)))
        XCTAssertEqual(try database.search("离线正文哨兵", options: SearchOptions(scope: .content)).map(\.id).sorted(), originalIDs)
    }

    /// The version 1 cache that 1.1.3 and 1.1.4 write restores at once; its
    /// tiers arrive with completeUpgrade, which then writes version 2.
    func testVersionOneCacheSearchesAtOnceAndUpgradesInBackground() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let database = try SearchDatabase(url: url)
        try database.saveRoot(IndexedRoot(id: "r", path: "/"))
        let paths = ["Users/me/Library/Caches/notes.txt", "Users/me/Documents/notes.txt"]
        try database.upsertFiles(paths.enumerated().map { i, path in
            FileRecord(rootID: "r", relativePath: path, name: "notes.txt", fileExtension: "txt", kind: .document, size: 1, modified: 1, inode: Int64(i + 1))
        }, generation: 1)
        let ids = Dictionary(uniqueKeysWithValues: try database.pendingFiles(rootID: "r", limit: 10).map { ($0.relativePath, $0.id) })
        let cached = ids[paths[0]]!, own = ids[paths[1]]!
        let first = try NameSearchEngine(databaseURL: url)
        try first.load()
        try NameSnapshotCache.saveStreamed(NameSnapshotCache.load(database: url, revision: 2), database: url)
        let cacheURL = NameSnapshotCache.url(for: url)
        XCTAssertEqual(try Data(contentsOf: cacheURL).prefix(8), Data("MJNAME01".utf8))

        let upgraded = try NameSearchEngine(databaseURL: url)
        try upgraded.load()
        XCTAssertEqual(try upgraded.search("notes"), [cached, own], "层级补齐前同分按 ID")
        XCTAssertThrowsError(try NameSnapshotCache.save(NameSnapshotCache.load(database: url, revision: 2), database: url), "缺层级的旧缓存不能写成新格式")
        try upgraded.saveCache()
        XCTAssertEqual(try Data(contentsOf: cacheURL).prefix(8), Data("MJNAME01".utf8), "补齐层级前保留旧缓存")
        try upgraded.completeUpgrade()
        XCTAssertEqual(try upgraded.search("notes"), [own, cached], "补齐层级后用户目录在前")
        XCTAssertEqual(try Data(contentsOf: cacheURL).prefix(8), Data("MJNAME02".utf8))
        XCTAssertTrue(try NameSnapshotCache.load(database: url, revision: 2).isMapped)
        try upgraded.completeUpgrade()   // nothing pending: returns at once
        let restarted = try NameSearchEngine(databaseURL: url)
        try restarted.load()
        XCTAssertEqual(try restarted.search("notes"), [own, cached])
    }

    /// The app refreshes the index while the upgrade runs; a refresh detaches
    /// the snapshot for its duration, which must not make the upgrade give up.
    func testUpgradeCompletesWhileRefreshesRun() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let database = try SearchDatabase(url: url)
        try database.saveRoot(IndexedRoot(id: "r", path: "/"))
        try database.upsertFiles((0..<5_000).map { i in
            FileRecord(rootID: "r", relativePath: "Users/me/Library/f\(i).txt", name: "f\(i).txt", fileExtension: "txt",
                       kind: .document, size: 1, modified: 1, inode: Int64(i + 1))
        }, generation: 1)
        try NameSearchEngine(databaseURL: url).load()
        try NameSnapshotCache.saveStreamed(NameSnapshotCache.load(database: url, revision: 5_000), database: url)
        let engine = try NameSearchEngine(databaseURL: url)
        try engine.load()
        let lock = NSLock(); var running = true, refreshes = 0
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while lock.withLock({ running }) {
                try? engine.refresh(rootID: "r", relativePaths: ["Users/me/Library"], fullRescan: false)
                lock.withLock { refreshes += 1 }
            }
            finished.signal()
        }
        while lock.withLock({ refreshes }) < 3 { usleep(1_000) }
        try engine.completeUpgrade()
        lock.withLock { running = false }
        finished.wait()
        XCTAssertEqual(try Data(contentsOf: NameSnapshotCache.url(for: url)).prefix(8), Data("MJNAME02".utf8))
        XCTAssertEqual(try engine.search("f4999").count, 1)
    }
}
