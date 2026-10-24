import Foundation
import CryptoKit

/// Shared name layer. Names have the same NFC + lowercase precondition
/// as CompactNameIndex. Publish after building; readers must not mutate it.
/// Row IDs never move. Removed rows and unreferenced unique names remain until
/// the owner rebuilds the index; this type starts no background work.
public final class DeduplicatedNameIndex {
    public typealias BuildError = CompactNameIndex.BuildError

    private var names = CompactNameIndex()
    private var rowNames = MappedColumn<UInt32>()
    private var live = MappedColumn<UInt8>()
    // Open addressing, linear probing, <= 75% full. Zero is empty; other slots
    // contain uniqueID + 1. No per-name String objects or stored hash array.
    private var lookup = MappedColumn<UInt32>()
    // Immutable ordering for the unique-name prefix prepared at publication.
    // Appended names use byte comparison until the owner's next full rebuild.
    private var nameOrder = MappedColumn<UInt32>()

    public var count: Int { rowNames.count }
    /// Includes unique names whose file rows have all been removed.
    public var uniqueCount: Int { names.count }

    public struct StorageStatistics {
        public let uniqueNameBytes: Int
        public let uniqueNameAllocatedBytes: Int
        public let rowIDBytes: Int
        public let rowIDAllocatedBytes: Int
        public let liveBytes: Int
        public let liveAllocatedBytes: Int
        public let lookupBytes: Int
        public let lookupAllocatedBytes: Int
        public let orderBytes: Int
        public let orderAllocatedBytes: Int
        public var totalBytes: Int { uniqueNameBytes + rowIDBytes + liveBytes + lookupBytes + orderBytes }
        public var allocatedBytes: Int {
            uniqueNameAllocatedBytes + rowIDAllocatedBytes + liveAllocatedBytes + lookupAllocatedBytes + orderAllocatedBytes
        }
    }

    /// Array element counts/capacities (including retained builder scratch), not
    /// process RSS. Excludes object/allocator overhead and temporary Data/query
    /// buffers. Queries allocate one Int32 score per unique name, plus the
    /// existing CompactNameIndex bounded matching scratch and compiled terms.
    public var storageStatistics: StorageStatistics {
        StorageStatistics(uniqueNameBytes: names.storageBytes,
                          uniqueNameAllocatedBytes: names.allocatedStorageBytes,
                          rowIDBytes: rowNames.count * MemoryLayout<UInt32>.stride,
                          rowIDAllocatedBytes: rowNames.capacity * MemoryLayout<UInt32>.stride,
                          liveBytes: live.count, liveAllocatedBytes: live.capacity,
                          lookupBytes: lookup.count * MemoryLayout<UInt32>.stride,
                          lookupAllocatedBytes: lookup.capacity * MemoryLayout<UInt32>.stride,
                          orderBytes: nameOrder.count * MemoryLayout<UInt32>.stride,
                          orderAllocatedBytes: nameOrder.capacity * MemoryLayout<UInt32>.stride)
    }
    public var storageBytes: Int { storageStatistics.totalBytes }
    public var allocatedStorageBytes: Int { storageStatistics.allocatedBytes }

    public init() {}

    public func append(_ name: String) throws {
        guard count < Int(UInt32.max) else { throw BuildError.capacityExceeded }
        let hash = CompactNameIndex.hashNameBytes(name.utf8)
        if !lookup.isEmpty {
            var slot = Int(truncatingIfNeeded: hash) & (lookup.count - 1)
            while lookup[slot] != 0 {
                let id = lookup[slot] - 1
                if names.nameEquals(id, name) {
                    rowNames.append(id); live.append(1)
                    return
                }
                slot = (slot + 1) & (lookup.count - 1)
            }
        }
        if lookup.isEmpty || uniqueCount + 1 > lookup.count - lookup.count / 4 {
            try rebuildLookup(capacity: lookup.isEmpty ? 16 : lookup.count * 2)
        }
        let id = UInt32(uniqueCount)
        try names.append(name)
        var slot = Int(truncatingIfNeeded: hash) & (lookup.count - 1)
        while lookup[slot] != 0 { slot = (slot + 1) & (lookup.count - 1) }
        lookup[slot] = id + 1
        rowNames.append(id); live.append(1)
    }

    public func remove(_ index: UInt32) { live[Int(index)] = 0 }
    public func nameEquals(_ index: UInt32, _ normalized: String) -> Bool {
        names.nameEquals(rowNames[Int(index)], normalized)
    }
    public func compareNames(_ lhs: UInt32, _ rhs: UInt32) -> Int {
        let a = rowNames[Int(lhs)], b = rowNames[Int(rhs)]
        if a == b { return 0 }
        if Int(a) < nameOrder.count, Int(b) < nameOrder.count {
            return nameOrder[Int(a)] < nameOrder[Int(b)] ? -1 : 1
        }
        return names.compareNames(a, b)
    }

    /// Prepare once before publishing the snapshot. Existing unique names never
    /// change, so their relative ranks remain valid across appends and removals.
    /// New tail names compare by bytes; ordinary events never re-sort the pool.
    public func prepareNameOrder(cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        guard nameOrder.isEmpty, uniqueCount > 0 else { return }
        var ordered = (0..<uniqueCount).map { UInt32($0) }
        var comparisons = 0
        try ordered.sort { a, b in
            comparisons += 1
            if comparisons % 4096 == 0, cancelled() { throw CancellationError() }
            return names.compareNames(a, b) < 0
        }
        nameOrder = try ranks(of: ordered, cancelled: cancelled)
    }

    private func ranks(of ordered: [UInt32], cancelled: () -> Bool) throws -> MappedColumn<UInt32> {
        let ranks = MappedColumn<UInt32>(repeating: 0, count: ordered.count)
        try ranks.withUnsafeMutableBufferPointer { ranks in
            for (rank, name) in ordered.enumerated() {
                if rank % 4096 == 0, cancelled() { throw CancellationError() }
                ranks[Int(name)] = UInt32(rank)
            }
        }
        if cancelled() { throw CancellationError() }
        return ranks
    }

    /// Rank names appended since the order was prepared, so a saved cache
    /// restores a complete order: sort only the new names, then merge.
    public func completeNameOrder() throws {
        guard !nameOrder.isEmpty, nameOrder.count < uniqueCount else { return }
        var ordered = [UInt32](repeating: 0, count: nameOrder.count)
        nameOrder.withUnsafeBufferPointer { ranks in
            for (name, rank) in ranks.enumerated() { ordered[Int(rank)] = UInt32(name) }
        }
        let added = (nameOrder.count..<uniqueCount).map { UInt32($0) }.sorted { names.compareNames($0, $1) < 0 }
        var merged: [UInt32] = []
        merged.reserveCapacity(uniqueCount)
        var i = 0, j = 0
        while i < ordered.count || j < added.count {
            if j == added.count || (i < ordered.count && names.compareNames(ordered[i], added[j]) <= 0) {
                merged.append(ordered[i]); i += 1
            } else { merged.append(added[j]); j += 1 }
        }
        nameOrder = try ranks(of: merged, cancelled: { false })
    }

    public func forEachMatch(_ terms: [CompactNameIndex.Term], cancelled: () -> Bool,
                             _ body: (UInt32, Int32) throws -> Void) throws {
        if cancelled() { throw CancellationError() }
        // A metadata-only query accepts every live row with score zero. Avoid
        // matching unique names and allocating scores for that common case.
        if terms.isEmpty {
            try live.withUnsafeBufferPointer { active in
                for row in active.indices {
                    if row % 4096 == 0, cancelled() { throw CancellationError() }
                    if active[row] != 0 { try body(UInt32(row), 0) }
                }
            }
            if cancelled() { throw CancellationError() }
            return
        }
        // Mapped scratch goes back to the system when the query ends, rather
        // than staying with the allocator after every search.
        let scores = MappedColumn<Int32>(repeating: -1, count: uniqueCount)
        try scores.withUnsafeMutableBufferPointer { scores in
            try names.forEachMatch(terms, cancelled: cancelled) { scores[Int($0)] = $1 }
        }
        try live.withUnsafeBufferPointer { active in
            try rowNames.withUnsafeBufferPointer { ids in
                try scores.withUnsafeBufferPointer { values in
                    for row in active.indices {
                        if row % 4096 == 0, cancelled() { throw CancellationError() }
                        if active[row] != 0 {
                            let score = values[Int(ids[row])]
                            if score != -1 { try body(UInt32(row), score) }
                        }
                    }
                }
            }
        }
        if cancelled() { throw CancellationError() }
    }

    private func rebuildLookup(capacity: Int) throws {
        let table = MappedColumn<UInt32>(repeating: 0, count: capacity)
        try table.withUnsafeMutableBufferPointer { table in
            for i in 0..<uniqueCount {
                let id = UInt32(i)
                var slot = Int(truncatingIfNeeded: names.normalizedNameHash(id)) & (capacity - 1)
                while table[slot] != 0 {
                    // Rebuilding on load also rejects duplicate unique-name rows.
                    guard names.compareNames(table[slot] - 1, id) != 0 else {
                        throw BuildError.invalidSerializedData
                    }
                    slot = (slot + 1) & (capacity - 1)
                }
                table[slot] = id + 1
            }
        }
        lookup = table
    }

    /// Derived cache only: new magic, version, file-row count, UInt64 embedded
    /// CompactNameIndex byte length, its bytes, row uniqueIDs, live flags, SHA256.
    /// All words are little endian. Lookup and name order are rebuilt, never persisted.
    public func serialized() -> Data {
        let uniqueData = names.serialized()
        var data = Data()
        data.reserveCapacity(56 + uniqueData.count + count * 5)
        data.append(contentsOf: "MIJIDEDU".utf8)
        func word(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(1); word(UInt32(count))
        word(UInt32(truncatingIfNeeded: uniqueData.count))
        word(UInt32(UInt64(uniqueData.count) >> 32))
        data.append(uniqueData)
        for id in rowNames { word(id) }
        live.withUnsafeBufferPointer { data.append($0) }
        data.append(contentsOf: SHA256.hash(data: data))
        return data
    }

    /// Storage for a page-aligned cache, by stable name, in writing order. The
    /// lookup table and name order are kept, so a restore rebuilds neither.
    public func columns() -> [(String, RawColumn)] {
        names.columns(prefix: "unique.") + [("rows", rowNames), ("rows.live", live), ("lookup", lookup), ("order", nameOrder)]
    }

    /// Adopt columns written by `columns()`. Rejects what init(serialized:)
    /// rejects, and a lookup table whose probes miss a name or meet a duplicate.
    public convenience init(columns source: ColumnSource) throws {
        self.init()
        names = try CompactNameIndex(columns: source, prefix: "unique.")
        rowNames = try source.column("rows", as: UInt32.self)
        live = try source.column("rows.live", as: UInt8.self)
        lookup = try source.column("lookup", as: UInt32.self)
        nameOrder = try source.column("order", as: UInt32.self)
        let unique = uniqueCount
        guard live.count == rowNames.count, unique <= rowNames.count, names.allLive,
              live.withUnsafeBufferPointer({ $0.allSatisfy { $0 <= 1 } }) else { throw BuildError.invalidSerializedData }
        var seen = [UInt8](repeating: 0, count: unique)
        let referenced = rowNames.withUnsafeBufferPointer { ids -> Bool in
            for id in ids {
                guard Int(id) < unique else { return false }
                seen[Int(id)] = 1
            }
            return true
        }
        guard referenced, seen.allSatisfy({ $0 == 1 }) else { throw BuildError.invalidSerializedData }
        let capacity = lookup.count
        if unique == 0 {
            // The writer keeps no table for an empty pool; any other would
            // never be resized by append and could be probed forever.
            guard capacity == 0 else { throw BuildError.invalidSerializedData }
        } else {
            guard capacity >= 16, capacity & (capacity - 1) == 0, unique <= capacity - capacity / 4 else { throw BuildError.invalidSerializedData }
            var filled = 0
            for slot in lookup where slot != 0 {
                guard Int(slot) <= unique else { throw BuildError.invalidSerializedData }
                filled += 1
            }
            guard filled == unique else { throw BuildError.invalidSerializedData }
            for i in 0..<unique {
                let id = UInt32(i)
                var slot = Int(truncatingIfNeeded: names.normalizedNameHash(id)) & (capacity - 1)
                while lookup[slot] != id + 1 {
                    guard lookup[slot] != 0, names.compareNames(lookup[slot] - 1, id) != 0 else { throw BuildError.invalidSerializedData }
                    slot = (slot + 1) & (capacity - 1)
                }
            }
        }
        guard nameOrder.count <= unique else { throw BuildError.invalidSerializedData }
        var ranked = [UInt8](repeating: 0, count: nameOrder.count)
        for rank in nameOrder {
            guard Int(rank) < ranked.count, ranked[Int(rank)] == 0 else { throw BuildError.invalidSerializedData }
            ranked[Int(rank)] = 1
        }
    }

    public convenience init(serialized data: Data) throws {
        self.init()
        guard data.count >= 131,
              SHA256.hash(data: data.dropLast(32)).elementsEqual(data.suffix(32)) else {
            throw BuildError.invalidSerializedData
        }
        try data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let end = bytes.count - 32
            guard bytes.prefix(8).elementsEqual("MIJIDEDU".utf8) else { throw BuildError.invalidSerializedData }
            var position = 8
            func word() throws -> UInt32 {
                guard position <= end - 4 else { throw BuildError.invalidSerializedData }
                defer { position += 4 }
                return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
                    | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
            }
            guard try word() == 1 else { throw BuildError.invalidSerializedData }
            let rows = Int(try word())
            let low = UInt64(try word()), high = UInt64(try word())
            let length = low | high << 32
            guard length <= UInt64(end - position) else { throw BuildError.invalidSerializedData }
            let size = Int(length)
            guard end - position - size == rows * 5 else { throw BuildError.invalidSerializedData }
            // The nested decoder copies its columns synchronously. Borrow the
            // enclosing cache's bytes for that call rather than copying the
            // entire unique-name payload a second time.
            let uniqueData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!.advanced(by:position)),
                                  count:size, deallocator:.none)
            names = try CompactNameIndex(serialized: uniqueData)
            position += size
            guard uniqueCount <= rows else { throw BuildError.invalidSerializedData }
            // Unique rows must all be live; only file rows may carry tombstones.
            var uniqueLiveCount = 0
            try names.forEachMatch([], cancelled: { false }) { _, _ in uniqueLiveCount += 1 }
            guard uniqueLiveCount == uniqueCount else { throw BuildError.invalidSerializedData }
            var seen = [UInt8](repeating: 0, count: uniqueCount)
            rowNames.reserveCapacity(rows)
            for _ in 0..<rows {
                let id = try word()
                guard Int(id) < uniqueCount else { throw BuildError.invalidSerializedData }
                rowNames.append(id); seen[Int(id)] = 1
            }
            guard seen.allSatisfy({ $0 == 1 }) else { throw BuildError.invalidSerializedData }
            live = MappedColumn(bytes[position..<end])
            guard live.allSatisfy({ $0 <= 1 }) else { throw BuildError.invalidSerializedData }
            if uniqueCount > 0 {
                var capacity = 16
                while uniqueCount > capacity - capacity / 4 { capacity *= 2 }
                try rebuildLookup(capacity: capacity)
            }
        }
    }
}
