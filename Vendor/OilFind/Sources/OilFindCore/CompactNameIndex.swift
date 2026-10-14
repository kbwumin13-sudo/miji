import Foundation
import CryptoKit
import COilFind

/// Miji-specific streaming builder over Oil Find's matching and pinyin core.
/// Publish only after building; concurrent readers must not append.
public final class CompactNameIndex {
    public struct Term {
        public let value: String
        public let excluded: Bool
        public init(value: String, excluded: Bool) { self.value = value; self.excluded = excluded }
    }
    public enum BuildError: Error { case capacityExceeded, invalidSerializedData }
    private struct Column {
        // Keep a valid base address even for an empty index/alternate column.
        var bytes: [UInt8] = [0]
        var offsets: [UInt32] = [1]
        mutating func append(_ key: [UInt8]) throws {
            guard bytes.count <= Int(UInt32.max) - key.count else { throw BuildError.capacityExceeded }
            bytes.append(contentsOf: key)
            offsets.append(UInt32(bytes.count))
        }
    }
    private var names = Column(), full = Column(), initials = Column()
    private var live: [UInt8] = []
    private var aliases: [UInt8] = []
    private var fullKey: [UInt8] = [], initialKey: [UInt8] = []
    public var count: Int { names.offsets.count - 1 }
    public init() {}

    /// Stable v1, little-endian: magic/version/count, then three columns
    /// (byteCount/bytes/count+1 offsets), live/aliases, and SHA-256 of all prior
    /// bytes. No Swift object layout or metadata is persisted.
    public func serialized() -> Data {
        var data = Data()
        data.reserveCapacity(72 + names.bytes.count + full.bytes.count + initials.bytes.count + count * 14)
        data.append(contentsOf: "MIJINAME".utf8)
        func word(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(1); word(UInt32(count))
        for column in [names, full, initials] {
            word(UInt32(column.bytes.count))
            data.append(contentsOf: column.bytes)
            for offset in column.offsets { word(offset) }
        }
        data.append(contentsOf: live)
        data.append(contentsOf: aliases)
        data.append(contentsOf: SHA256.hash(data: data))
        return data
    }

    /// Reject corrupt/incompatible caches. The owner decides when to rebuild.
    public convenience init(serialized data: Data) throws {
        self.init()
        guard data.count >= 75,
              SHA256.hash(data: data.dropLast(32)).elementsEqual(data.suffix(32)) else {
            throw BuildError.invalidSerializedData
        }
        try data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let end = bytes.count - 32
            guard bytes.prefix(8).elementsEqual("MIJINAME".utf8) else { throw BuildError.invalidSerializedData }
            var position = 8
            func word() throws -> UInt32 {
                guard position <= end - 4 else { throw BuildError.invalidSerializedData }
                defer { position += 4 }
                return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
                    | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
            }
            guard try word() == 1 else { throw BuildError.invalidSerializedData }
            let rows = Int(try word())
            // Check the minimum size before allocating anything proportional to
            // an untrusted count. Every column includes its sentinel byte.
            guard rows <= (end - 43) / 14 else { throw BuildError.invalidSerializedData }
            func column() throws -> Column {
                let length = Int(try word())
                guard length >= 1, length <= end - position,
                      (rows + 1) <= (end - position - length) / 4 else { throw BuildError.invalidSerializedData }
                let contents = Array(bytes[position..<(position + length)])
                position += length
                var offsets: [UInt32] = []
                offsets.reserveCapacity(rows + 1)
                var previous: UInt32 = 1
                for i in 0...rows {
                    let offset = try word()
                    guard offset >= previous, offset <= length, i != 0 || offset == 1 else { throw BuildError.invalidSerializedData }
                    offsets.append(offset); previous = offset
                }
                guard contents[0] == 0, previous == length else { throw BuildError.invalidSerializedData }
                return Column(bytes: contents, offsets: offsets)
            }
            let names = try column(), full = try column(), initials = try column()
            guard end - position == rows * 2 else { throw BuildError.invalidSerializedData }
            let live = Array(bytes[position..<(position + rows)])
            position += rows
            let aliases = Array(bytes[position..<end])
            for i in 0..<rows {
                let flag = aliases[i]
                guard live[i] <= 1, flag & ~31 == 0,
                      flag & 18 != 18, flag & 12 != 12,
                      flag & 16 == 0 || flag & 1 != 0,
                      flag & 18 == 0 || full.offsets[i] == full.offsets[i + 1],
                      flag & 12 == 0 || initials.offsets[i] == initials.offsets[i + 1] else {
                    throw BuildError.invalidSerializedData
                }
                if flag & 1 != 0 {
                    guard names.bytes[Int(names.offsets[i])..<Int(names.offsets[i + 1])].allSatisfy({ $0 < 128 }) else {
                        throw BuildError.invalidSerializedData
                    }
                    for key in [full, initials] {
                        guard key.bytes[Int(key.offsets[i])..<Int(key.offsets[i + 1])].allSatisfy({
                            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
                        }) else { throw BuildError.invalidSerializedData }
                    }
                }
            }
            self.names = names; self.full = full; self.initials = initials
            self.live = live; self.aliases = aliases
        }
    }
    public func remove(_ index: UInt32) { live[Int(index)] = 0 }
    public func nameEquals(_ index: UInt32, _ normalized: String) -> Bool {
        let start = Int(names.offsets[Int(index)]), end = Int(names.offsets[Int(index) + 1])
        return names.bytes[start..<end].elementsEqual(normalized.utf8)
    }

    /// Names must already use Miji's NFC + lowercase normalization.
    public func append(_ name: String) throws {
        guard count < Int(UInt32.max) else { throw BuildError.capacityExceeded }
        let raw = Array(name.utf8)
        if raw.allSatisfy({ $0 < 128 }) {
            // Derive once, rather than walking every ASCII name twice per query.
            fullKey.removeAll(keepingCapacity: true)
            initialKey.removeAll(keepingCapacity: true)
            var wordStart = true
            for byte in raw {
                let word = (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                if word {
                    fullKey.append(byte)
                    if wordStart { initialKey.append(byte) }
                }
                wordStart = !word
            }
            try append(raw, ascii: true)
            return
        }
        let hasHan = raw.withUnsafeBufferPointer { Pinyin.shared.keys(for: $0, full: &fullKey, initials: &initialKey, wordInitials: true) }
        if !hasHan {
            // Also preserve Miji's Latin filename abbreviations (e.g. rnt).
            let latin = (name.applyingTransform(.toLatin, reverse: false) ?? name).applyingTransform(.stripDiacritics, reverse: false) ?? name
            let words = latin.lowercased().split { !$0.isLetter && !$0.isNumber }
            fullKey = Array(words.joined().utf8)
            initialKey = Array(String(words.compactMap(\.first)).utf8)
        } else {
            // Oil Find retains punctuation; Miji historically joins words.
            fullKey = Array(String(decoding: fullKey, as: UTF8.self).filter { $0.isLetter || $0.isNumber }.utf8)
            initialKey = Array(String(decoding: initialKey, as: UTF8.self).filter { $0.isLetter || $0.isNumber }.utf8)
        }
        try append(raw, ascii: false)
    }

    private func append(_ raw: [UInt8], ascii: Bool) throws {
        try names.append(raw)
        var alias: UInt8 = ascii ? 1 : 0
        if fullKey == raw { alias |= 2 }
        if initialKey == raw { alias |= 4 }
        else if initialKey == fullKey { alias |= 8 }
        // For an ASCII alphanumeric needle, one word has exactly the same
        // matches in the name and full key, even with surrounding punctuation.
        if ascii && initialKey.count == 1 { alias |= 2 }
        // Long ASCII full keys would duplicate most of the largest name column.
        // Store short keys; verify long ones in-place only after literal misses.
        if ascii && alias & 2 == 0 && fullKey.count > 8 { alias |= 16 }
        try full.append(alias & 18 != 0 ? [] : fullKey)
        try initials.append(alias & 12 != 0 ? [] : initialKey)
        live.append(1)
        aliases.append(alias)
    }

    public func compareNames(_ lhs: UInt32, _ rhs: UInt32) -> Int {
        // SQLite BINARY ordering of normalized UTF-8, including embedded NUL.
        names.bytes.withUnsafeBufferPointer { bytes in
            let a = Int(names.offsets[Int(lhs)]), z = Int(names.offsets[Int(lhs) + 1])
            let b = Int(names.offsets[Int(rhs)]), y = Int(names.offsets[Int(rhs) + 1])
            let common = min(z - a, y - b)
            let order = memcmp(bytes.baseAddress!.advanced(by: a), bytes.baseAddress!.advanced(by: b), common)
            return order == 0 ? (z - a) - (y - b) : Int(order)
        }
    }

    /// Bounded scratch (256 KiB), synchronous scan, serial callbacks in row order.
    public func forEachMatch(_ terms: [Term], cancelled: () -> Bool,
                             _ body: (UInt32, Int32) throws -> Void) throws {
        let needleBytes: [UInt8] = terms.flatMap { Array($0.value.utf8) } + [UInt8(0)]
        try needleBytes.withUnsafeBufferPointer { needles in
            var position = 0
            let compiled = terms.map { term -> MijiNameTerm in
                let length = term.value.utf8.count
                defer { position += length }
                let asciiKey = term.value.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }
                return MijiNameTerm(needle: needles.baseAddress!.advanced(by: position), length: length, excluded: term.excluded ? 1 : 0, ascii_key: asciiKey ? 1 : 0)
            }
            try compiled.withUnsafeBufferPointer { terms in
                try names.bytes.withUnsafeBufferPointer { names in
                    try self.names.offsets.withUnsafeBufferPointer { nameOff in
                        try full.bytes.withUnsafeBufferPointer { full in
                            try self.full.offsets.withUnsafeBufferPointer { fullOff in
                                try initials.bytes.withUnsafeBufferPointer { initials in
                                    try self.initials.offsets.withUnsafeBufferPointer { initialOff in
                                        let batch = count >= 32768 ? 32768 : 4096
                                        var ids = [UInt32](repeating: 0, count: batch)
                                        var scores = [Int32](repeating: 0, count: batch)
                                        try live.withUnsafeBufferPointer { live in
                                            try aliases.withUnsafeBufferPointer { aliases in
                                                for first in stride(from: 0, to: count, by: batch) {
                                                    if cancelled() { throw CancellationError() }
                                                    let n = miji_match_names_batch(names.baseAddress, nameOff.baseAddress, full.baseAddress, fullOff.baseAddress,
                                                                             initials.baseAddress, initialOff.baseAddress, live.baseAddress, aliases.baseAddress, UInt32(first), UInt32(min(first + batch, count)),
                                                                             terms.baseAddress, terms.count, &ids, &scores)
                                                    for j in 0..<n {
                                                        if j % 4096 == 0, cancelled() { throw CancellationError() }
                                                        try body(ids[j], scores[j])
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if cancelled() { throw CancellationError() }
    }
}
