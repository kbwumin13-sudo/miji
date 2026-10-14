import Foundation
import Darwin

/// Paths are relative to the owning root, including an empty path for a whole
/// root. Consumers can refresh these subtrees after committed metadata batches.
public struct IndexChange: Sendable {
    public var rootID: String
    public var relativePaths: [String]
    public var fullRescan: Bool
    public init(rootID: String, relativePaths: [String], fullRescan: Bool) {
        self.rootID=rootID; self.relativePaths=relativePaths; self.fullRescan=fullRescan
    }
}

enum IndexRelativePath {
    static func validated(_ path: String) -> Bool {
        path.isEmpty || (!path.hasPrefix("/") && !path.utf8.contains(0) && !path.split(separator:"/",omittingEmptySubsequences:false).contains { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    static func from(_ path: String, root: String) -> String? {
        // Compare complete components, rather than dropping root.count from a
        // Foundation URL that may contain // or a physical Data-volume alias.
        let base=IndexPathFilter.canonicalPath(root)
        let candidate=IndexPathFilter.canonicalPath(path)
        if candidate == base { return "" }
        let prefix=base == "/" ? "/" : base + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        let relative=String(candidate.dropFirst(prefix.count))
        return validated(relative) ? relative : nil
    }
    static func contains(_ parent: String, _ child: String) -> Bool {
        parent.isEmpty || parent == child || child.hasPrefix(parent + "/")
    }
    static func coalescing(_ paths: [String]) -> [String] {
        var result:[String]=[]
        for path in Set(paths).sorted(by:{ $0.count < $1.count }) where validated(path) {
            if !result.contains(where:{ contains($0,path) }) { result.append(path) }
        }
        return result
    }
    /// Package children contribute to the package signature, not separate rows.
    static func packageScope(_ relative: String) -> String {
        var parts:[String]=[]
        for part in relative.split(separator:"/") {
            parts.append(String(part))
            if ["app","pages","numbers","key","keynote","rtfd","bundle","framework"].contains((String(part) as NSString).pathExtension.lowercased()) { break }
        }
        return parts.joined(separator:"/")
    }
}

/// A durable inbox: advancing an event cursor and recording its paths is one
/// atomic write. Paths remain here until a complete scan commits. A crash during
/// enumeration therefore replays work without losing deletions or new files.
struct IncrementalIndexState: Codable {
    struct Root: Codable {
        var path: String
        var cursor: UInt64
        var pending: [String]
        var inFlight: [String] = []
    }
    var roots: [String:Root] = [:]
    static func read(_ url: URL) -> IncrementalIndexState {
        (try? JSONDecoder().decode(Self.self,from:Data(contentsOf:url))) ?? Self()
    }
    func write(_ url: URL) throws {
        // A predictable sibling is excluded from events and enumeration too.
        // Foundation's .atomic uses random temporary names, which can otherwise
        // turn the index's own journal writes into an endless event feedback loop.
        let staging=url.appendingPathExtension("tmp")
        try JSONEncoder().encode(self).write(to:staging)
        guard rename(staging.path,url.path) == 0 else {
            let code=errno
            try? FileManager.default.removeItem(at:staging)
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
        }
    }
    mutating func enqueue(_ paths: [String], rootID: String) {
        guard var root=roots[rootID] else { return }
        root.pending=IndexRelativePath.coalescing(root.pending + paths)
        // Bound the inbox even during a large move. This is the deliberate
        // recovery path, rather than allowing unbounded metadata in memory.
        if root.pending.count > 2_048 { root.pending=[""] }
        roots[rootID]=root
    }
}
