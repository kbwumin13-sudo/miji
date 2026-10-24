import Foundation
import Compression
import CryptoKit

public enum ContentCodecError: Error, Equatable {
    case invalidData
    case resourceLimit
    case compressionFailed
}

/// Stable v1 envelope: MJC1, codec (0 = raw, 1 = LZFSE), three zero bytes,
/// little-endian UInt64 original length, SHA256 of payload bytes, payload.
/// Integrity is checked for both codecs, before the content reaches JSONDecoder.
public enum ContentCodec {
    public static let maximumRawBytes = 128 * 1024 * 1024
    private static let headerBytes = 48
    private static let magic: [UInt8] = [0x4d, 0x4a, 0x43, 0x31]

    public static func digest(_ raw: Data) -> Data { Data(SHA256.hash(data: raw)) }

    public static func pack(_ raw: Data) throws -> Data {
        guard raw.count <= maximumRawBytes else { throw ContentCodecError.resourceLimit }
        var codec: UInt8 = 0
        var payload = raw
        if !raw.isEmpty {
            // A full-size destination is enough: only a strictly smaller result is useful.
            var compressed = Data(count: raw.count)
            let capacity = compressed.count
            let size = compressed.withUnsafeMutableBytes { destination in
                raw.withUnsafeBytes { source in
                    compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                              nil, COMPRESSION_LZFSE)
                }
            }
            if size > 0 && size < raw.count {
                compressed.count = size
                payload = compressed
                codec = 1
            }
        }
        var result = Data(magic)
        result.append(contentsOf: [codec, 0, 0, 0])
        let length = UInt64(raw.count)
        for byte in 0..<8 { result.append(UInt8(truncatingIfNeeded: length >> (byte * 8))) }
        result.append(digest(payload))
        result.append(payload)
        return result
    }

    public static func unpack(_ packed: Data) throws -> Data {
        guard packed.count >= headerBytes else { throw ContentCodecError.invalidData }
        // Data slices need not have zero-based indices.
        let header = Array(packed.prefix(headerBytes))
        guard Array(header[0..<4]) == magic, header[5..<8].allSatisfy({ $0 == 0 }),
              header[4] <= 1 else { throw ContentCodecError.invalidData }
        var length: UInt64 = 0
        for byte in 0..<8 { length |= UInt64(header[8 + byte]) << (byte * 8) }
        guard length <= UInt64(maximumRawBytes) else { throw ContentCodecError.resourceLimit }
        let size = Int(length)
        let payloadSize = packed.count - headerBytes
        guard header[4] == 0 ? payloadSize == size : (size > 0 && payloadSize > 0 && payloadSize < size)
        else { throw ContentCodecError.invalidData }
        let payload = Data(packed.dropFirst(headerBytes))
        guard digest(payload) == Data(header[16..<48]) else { throw ContentCodecError.invalidData }
        let raw: Data
        if header[4] == 0 {
            guard payload.count == size else { throw ContentCodecError.invalidData }
            raw = payload
        } else {
            guard size > 0, !payload.isEmpty, payload.count < size else { throw ContentCodecError.invalidData }
            // The spare byte detects streams that exceed the advertised original length.
            var decoded = Data(count: size + 1)
            try decoded.withUnsafeMutableBytes { destination in
                try payload.withUnsafeBytes { source in
                    var stream = compression_stream(dst_ptr: destination.bindMemory(to: UInt8.self).baseAddress!, dst_size: 0,
                                                    src_ptr: source.bindMemory(to: UInt8.self).baseAddress!, src_size: 0, state: nil)
                    guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR
                    else { throw ContentCodecError.compressionFailed }
                    defer { compression_stream_destroy(&stream) }
                    stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = size + 1
                    stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
                    stream.src_size = payload.count
                    while true {
                        let previousInput = stream.src_size, previousOutput = stream.dst_size
                        let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                        if status == COMPRESSION_STATUS_END {
                            guard stream.src_size == 0, stream.dst_size == 1 else { throw ContentCodecError.invalidData }
                            break
                        }
                        guard status == COMPRESSION_STATUS_OK, stream.dst_size > 0,
                              stream.src_size < previousInput || stream.dst_size < previousOutput
                        else { throw ContentCodecError.invalidData }
                    }
                }
            }
            decoded.count = size
            raw = decoded
        }
        return raw
    }

    public static func searchableText(_ packed: Data) throws -> String {
        let content = try JSONDecoder().decode(ExtractedContent.self, from: unpack(packed))
        return QueryParser.normalize(content.text + "\n" + content.labels.joined(separator: "\n"))
    }

    /// Candidate-only intersection; the caller must verify the exact normalized substring.
    /// Input has already been normalized using QueryParser.normalize.
    public static func matchExpression(_ normalizedTerm: String) -> String? {
        let scalars = Array(normalizedTerm.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        let width = min(3, scalars.count)
        let starts = scalars.count - width + 1
        let samples = min(16, starts)
        var tokens: [String] = []
        var seen = Set<String>()
        let hex = Array("0123456789abcdef".utf8)
        for sample in 0..<samples {
            let start = samples == 1 ? 0 : sample * (starts - 1) / (samples - 1)
            var gram = String.UnicodeScalarView()
            for index in start..<(start + width) { gram.append(scalars[index]) }
            var encoded: [UInt8] = [0x67]
            for byte in String(gram).utf8 { encoded.append(hex[Int(byte >> 4)]); encoded.append(hex[Int(byte & 15)]) }
            let token = String(decoding: encoded, as: UTF8.self)
            if seen.insert(token).inserted { tokens.append("\"" + token + "\"") }
        }
        return tokens.joined(separator: " AND ")
    }
}

extension ContentCodec {
    /// ExtractedContent from its stored JSON. JSONEncoder escapes every newline
    /// and "/", and JSONDecoder rebuilds such strings piece by piece, which made
    /// decoding most of a broad full-text query. The fields are read here in
    /// one pass; JSONDecoder decides anything this reader does not accept.
    public static func content(_ raw: Data, decoder: JSONDecoder) throws -> ExtractedContent {
        if let content = raw.withUnsafeBytes({ bytes -> ExtractedContent? in
            var reader = ContentJSONReader(bytes: bytes.bindMemory(to: UInt8.self))
            return reader.read()
        }) { return content }
        return try decoder.decode(ExtractedContent.self, from: raw)
    }
}

/// `{"text":…,"labels":[…],"pages":…,"warning":…}` in any key order, with
/// JSON whitespace. Other or repeated keys, numbers that are not plain
/// integers, unknown escapes, unpaired surrogates and invalid UTF-8 give nil.
struct ContentJSONReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var at = 0

    mutating func read() -> ExtractedContent? {
        var text: String?, labels: [String]?, pages: Int?, warning: String?, warningSeen = false
        space()
        guard take(0x7B) else { return nil }                       // {
        repeat {
            space()
            guard let key = string() else { return nil }
            space()
            guard take(0x3A) else { return nil }                   // :
            space()
            switch key {
            case "text" where text == nil: guard let value = string() else { return nil }; text = value
            case "labels" where labels == nil: guard let value = strings() else { return nil }; labels = value
            case "pages" where pages == nil: guard let value = integer() else { return nil }; pages = value
            case "warning" where !warningSeen:
                warningSeen = true
                if !null() { guard let value = string() else { return nil }; warning = value }
            default: return nil
            }
            space()
        } while take(0x2C)                                          // ,
        guard take(0x7D) else { return nil }                       // }
        space()
        guard at == bytes.count, let text, let labels, let pages else { return nil }
        return ExtractedContent(text: text, labels: labels, pages: pages, warning: warning)
    }

    private mutating func space() {
        while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x0A || bytes[at] == 0x0D || bytes[at] == 0x09 { at += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        guard at < bytes.count, bytes[at] == byte else { return false }
        at += 1
        return true
    }
    private mutating func null() -> Bool {
        guard bytes.count - at >= 4, bytes[at] == 0x6E, bytes[at + 1] == 0x75, bytes[at + 2] == 0x6C, bytes[at + 3] == 0x6C else { return false }
        at += 4
        return true
    }
    private func digit(_ index: Int) -> Bool { index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 }

    private mutating func integer() -> Int? {
        let negative = take(0x2D)                                   // -
        guard digit(at), !(bytes[at] == 0x30 && digit(at + 1)) else { return nil }
        var value = 0
        while digit(at) {
            let digit = Int(bytes[at] - 0x30)
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 10)
            let (next, carry) = negative ? shifted.subtractingReportingOverflow(digit) : shifted.addingReportingOverflow(digit)
            guard !overflow, !carry else { return nil }
            value = next
            at += 1
        }
        if at < bytes.count, bytes[at] == 0x2E || bytes[at] | 0x20 == 0x65 { return nil } // fraction or exponent
        return value
    }

    private mutating func strings() -> [String]? {
        guard take(0x5B) else { return nil }                       // [
        var values: [String] = []
        space()
        if take(0x5D) { return values }                             // ]
        repeat {
            space()
            guard let value = string() else { return nil }
            values.append(value)
            space()
        } while take(0x2C)
        return take(0x5D) ? values : nil
    }

    private func hex(_ index: Int) -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            switch byte {
            case 0x30...0x39: value = value << 4 | UInt32(byte - 0x30)
            case 0x41...0x46: value = value << 4 | UInt32(byte - 0x37)
            case 0x61...0x66: value = value << 4 | UInt32(byte - 0x57)
            default: return nil
            }
        }
        return value
    }

    private mutating func string() -> String? {
        guard take(0x22) else { return nil }                       // "
        var run = at
        var decoded: [UInt8]?                                       // only once there is an escape
        while at < bytes.count {
            let byte = bytes[at]
            if byte == 0x22 {
                let tail = UnsafeBufferPointer(rebasing: bytes[run..<at])
                at += 1
                if decoded == nil { return Self.validated(tail) }
                decoded!.append(contentsOf: tail)
                return decoded!.withUnsafeBufferPointer { Self.validated($0) }
            }
            if byte < 0x20 { return nil }                           // raw control character
            guard byte == 0x5C else { at += 1; continue }           // backslash
            if decoded == nil { decoded = []; decoded!.reserveCapacity(bytes.count - run) }
            decoded!.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[run..<at]))
            at += 1
            guard at < bytes.count else { return nil }
            switch bytes[at] {
            case 0x22, 0x5C, 0x2F: decoded!.append(bytes[at])
            case 0x62: decoded!.append(0x08)
            case 0x66: decoded!.append(0x0C)
            case 0x6E: decoded!.append(0x0A)
            case 0x72: decoded!.append(0x0D)
            case 0x74: decoded!.append(0x09)
            case 0x75:                                              // \uXXXX, a surrogate pair as two
                guard var value = hex(at + 1) else { return nil }
                at += 4
                if value >= 0xDC00 && value <= 0xDFFF { return nil }
                if value >= 0xD800 && value <= 0xDBFF {
                    guard at + 2 < bytes.count, bytes[at + 1] == 0x5C, bytes[at + 2] == 0x75,
                          let low = hex(at + 3), low >= 0xDC00 && low <= 0xDFFF else { return nil }
                    value = 0x10000 + (value - 0xD800) << 10 + (low - 0xDC00)
                    at += 6
                }
                switch value {
                case ..<0x80: decoded!.append(UInt8(value))
                case ..<0x800: decoded! += [0xC0 | UInt8(value >> 6), 0x80 | UInt8(value & 0x3F)]
                case ..<0x10000: decoded! += [0xE0 | UInt8(value >> 12), 0x80 | UInt8(value >> 6 & 0x3F), 0x80 | UInt8(value & 0x3F)]
                default: decoded! += [0xF0 | UInt8(value >> 18), 0x80 | UInt8(value >> 12 & 0x3F), 0x80 | UInt8(value >> 6 & 0x3F), 0x80 | UInt8(value & 0x3F)]
                }
            default: return nil
            }
            at += 1
            run = at
        }
        return nil                                                  // unterminated
    }

    /// The string, if these bytes are valid UTF-8: decoding repairs anything
    /// else, so only an exact copy shows they were.
    private static func validated(_ utf8: UnsafeBufferPointer<UInt8>) -> String? {
        guard let base = utf8.baseAddress, !utf8.isEmpty else { return "" }
        var string = String(decoding: utf8, as: UTF8.self)
        let exact = string.withUTF8 { $0.count == utf8.count && memcmp($0.baseAddress!, base, utf8.count) == 0 }
        return exact ? string : nil
    }
}
