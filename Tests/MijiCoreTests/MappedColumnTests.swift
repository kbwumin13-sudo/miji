import XCTest
import Foundation
import Darwin
import OilFindCore

final class MappedColumnTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private let page = 16_384
    /// Writes columns page-aligned, as the name cache does; returns name -> (offset, count).
    private func writeColumns(_ columns: [(String, RawColumn)], to url: URL) throws -> [String: (Int, Int)] {
        var data = Data(count: page), layout: [String: (Int, Int)] = [:]
        for (name, column) in columns {
            layout[name] = (data.count, column.count)
            column.withUnsafeRawBytes { data.append(contentsOf: $0) }
            data.append(Data(count: (page - data.count % page) % page))
        }
        try data.write(to: url)
        return layout
    }
    private struct Source: ColumnSource {
        let descriptor: Int32, size: Int, layout: [String: (Int, Int)]
        func column<T>(_ name: String, as type: T.Type) throws -> MappedColumn<T> {
            guard let (offset, count) = layout[name] else { throw CocoaError(.fileReadCorruptFile) }
            return try MappedColumn<T>(mapping: descriptor, offset: offset, count: count, fileSize: size)
        }
    }

    func testAnonymousColumnGrowsAcrossReservationsAndKeepsValues() {
        let column = MappedColumn<UInt32>()
        for i in 0..<300_000 { column.append(UInt32(i) &* 2_654_435_761) }
        XCTAssertEqual(column.count, 300_000)
        XCTAssertTrue(column.indices.allSatisfy { column[$0] == UInt32($0) &* 2_654_435_761 })
        column.append(contentsOf: [7, 8, 9])
        XCTAssertEqual(Array(column.suffix(3)), [7, 8, 9])
        XCTAssertGreaterThanOrEqual(column.capacity, column.count)
        let filled = MappedColumn<Int8>(repeating: -3, count: 40_000)
        XCTAssertTrue(filled.allSatisfy { $0 == -3 })
        XCTAssertEqual(MappedColumn<Double>().count, 0)
        MappedColumn<Double>().withUnsafeBufferPointer { XCTAssertNotNil($0.baseAddress) }
    }

    func testMappedPagesAreReadInPlaceAndWritesNeverReachTheFile() throws {
        let url = directory.appendingPathComponent("columns.bin")
        let values = MappedColumn<Int64>((0..<5_000).map { Int64($0) * 1_000_003 })
        let bytes = MappedColumn<UInt8>(Array("映射列".utf8))
        let layout = try writeColumns([("values", values), ("bytes", bytes), ("empty", MappedColumn<UInt32>())], to: url)
        let before = try Data(contentsOf: url)
        let descriptor = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let source = Source(descriptor: descriptor, size: before.count, layout: layout)
        let mapped = try source.column("values", as: Int64.self)
        XCTAssertTrue(mapped.elementsEqual(values))
        XCTAssertEqual(String(decoding: Array(try source.column("bytes", as: UInt8.self)), as: UTF8.self), "映射列")
        XCTAssertEqual(try source.column("empty", as: UInt32.self).count, 0)
        mapped[17] = -1
        for i in 0..<600_000 { mapped.append(Int64(i)) }   // past the mapped pages and the reservation
        XCTAssertEqual(mapped[17], -1)
        XCTAssertEqual(mapped[16], 16 * 1_000_003)
        XCTAssertEqual(mapped[4_999], 4_999 * 1_000_003)
        XCTAssertEqual(mapped.last, 599_999)
        XCTAssertEqual(try Data(contentsOf: url), before, "私有映射的写入只复制页面，不改缓存文件")
    }

    func testAppendsToALargeMappedColumnStayInItsReservation() throws {
        // Over 4 MiB: growing by doubling would exceed the reservation and copy
        // every mapped page into anonymous memory on the first new file.
        let url = directory.appendingPathComponent("large.bin")
        let values = MappedColumn<Int64>((0..<1_000_000).map { Int64($0) })
        let layout = try writeColumns([("values", values)], to: url)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        let size = Int((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        let mapped = try Source(descriptor: descriptor, size: size, layout: layout).column("values", as: Int64.self)
        let before = mapped.withUnsafeBufferPointer { $0.baseAddress }
        for i in 0..<10_000 { mapped.append(Int64(-i)) }
        mapped[3] = 42
        XCTAssertEqual(mapped.withUnsafeBufferPointer { $0.baseAddress }, before, "追加留在预留区内，映射页不被整体复制")
        XCTAssertEqual(mapped[3], 42); XCTAssertEqual(mapped[999_999], 999_999); XCTAssertEqual(mapped.last, -9_999)
        XCTAssertGreaterThanOrEqual(mapped.capacity, mapped.count)
    }

    func testEmptyPoolRejectsALookupTable() throws {
        let empty = DeduplicatedNameIndex()
        var columns = empty.columns()
        columns.removeAll { $0.0 == "lookup" }
        columns.append(("lookup", MappedColumn<UInt32>(repeating: 0, count: 1)))
        let url = directory.appendingPathComponent("empty.bin")
        let layout = try writeColumns(columns, to: url)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        let size = Int((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        XCTAssertThrowsError(try DeduplicatedNameIndex(columns: Source(descriptor: descriptor, size: size, layout: layout)))
        let fine = try writeColumns(empty.columns(), to: directory.appendingPathComponent("fine.bin"))
        let fineDescriptor = open(directory.appendingPathComponent("fine.bin").path, O_RDONLY)
        defer { close(fineDescriptor) }
        let restored = try DeduplicatedNameIndex(columns: Source(descriptor: fineDescriptor, size: page * 16, layout: fine))
        try restored.append("a"); try restored.append("b"); try restored.append("a")
        XCTAssertEqual(restored.uniqueCount, 2)
    }

    func testMappingRejectsUnalignedOrOutOfFileRegions() throws {
        let url = directory.appendingPathComponent("short.bin")
        try Data(count: page * 2).write(to: url)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        XCTAssertThrowsError(try MappedColumn<UInt8>(mapping: descriptor, offset: 4096 + 1, count: 1, fileSize: page * 2))
        XCTAssertThrowsError(try MappedColumn<UInt32>(mapping: descriptor, offset: page, count: page, fileSize: page * 2))
        XCTAssertThrowsError(try MappedColumn<UInt64>(mapping: descriptor, offset: 0, count: Int.max / 4, fileSize: page * 2))
        XCTAssertThrowsError(try MappedColumn<UInt8>(mapping: descriptor, offset: 0, count: Int.max - 10, fileSize: page * 2), "取整前先按文件大小拒绝")
        XCTAssertThrowsError(try MappedColumn<UInt8>(mapping: descriptor, offset: page * 3, count: 1, fileSize: page * 2))
        XCTAssertEqual(try MappedColumn<UInt8>(mapping: descriptor, offset: page * 2, count: 0, fileSize: page * 2).count, 0)
        XCTAssertEqual(try MappedColumn<UInt8>(mapping: descriptor, offset: page, count: page, fileSize: page * 2).count, page)
    }

    func testMappedDeduplicatedIndexMatchesItsSourceAndAcceptsAppends() throws {
        let names = ["数学分析.pdf", "数学分析.pdf", "readme.txt", "café.txt", "cafe\u{301}.txt", "foo\0bar", "", "a-b-c-d-e-f-g-h-i", "report notes.txt"]
        let source = DeduplicatedNameIndex()
        for name in names { try source.append(name) }
        source.remove(1)
        try source.prepareNameOrder(cancelled: { false })
        let url = directory.appendingPathComponent("names.bin")
        let layout = try writeColumns(source.columns(), to: url)
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        let size = Int((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        let restored = try DeduplicatedNameIndex(columns: Source(descriptor: descriptor, size: size, layout: layout))
        func matches(_ index: DeduplicatedNameIndex, _ value: String) throws -> [[Int32]] {
            var result: [[Int32]] = []
            try index.forEachMatch([.init(value: value, excluded: false)], cancelled: { false }) { result.append([Int32($0), $1]) }
            return result
        }
        for query in ["shuxue", "sxfx", "数学", "readme", "cafe", "café", "\0", "abc", ""] {
            XCTAssertEqual(try matches(restored, query), try matches(source, query), query)
        }
        XCTAssertEqual(restored.compareNames(2, 3), source.compareNames(2, 3))
        try restored.append("readme.txt"); try restored.append("全新名称.md")
        XCTAssertEqual(restored.uniqueCount, source.uniqueCount + 1, "持久化的查找表仍能去重")
        XCTAssertEqual(try matches(restored, "quanxin").map { $0[0] }, [Int32(names.count + 1)])
    }

    func testCompletedNameOrderEqualsBinaryOrderAfterAppends() throws {
        let index = DeduplicatedNameIndex()
        var all = ["b", "a", "数学", "B", "", "a\0", "café", "cafe\u{301}", "zz", "z"]
        for name in all { try index.append(name) }
        try index.prepareNameOrder(cancelled: { false })
        let added = ["aa", "0", "数学分析", "\u{10FFFF}", "y", "ab"]
        for name in added { try index.append(name) }
        all += added
        try index.completeNameOrder()
        let rows = (0..<UInt32(all.count)).sorted { index.compareNames($0, $1) < 0 }
        let expected = (0..<UInt32(all.count)).sorted {
            Array(all[Int($0)].utf8).lexicographicallyPrecedes(Array(all[Int($1)].utf8))
        }
        XCTAssertEqual(rows.map { all[Int($0)] }, expected.map { all[Int($0)] })
        XCTAssertEqual(index.storageStatistics.orderBytes, all.count * 4)
    }
}
