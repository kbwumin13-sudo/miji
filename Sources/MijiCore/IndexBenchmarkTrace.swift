import Darwin
import Foundation
import SQLite3

/// Experimental instrumentation for an explicitly isolated UI test launch.
/// Capture timestamps on the calling queue and encode/write on a separate queue.
final class IndexBenchmarkTrace: @unchecked Sendable {
    private static let environment = ProcessInfo.processInfo.environment
    private static let isolatedTest: Bool = {
        guard environment["MIJI_UI_TESTING"] == "1",
              let data = environment["MIJI_DATA_DIR"], data.hasPrefix("/") else { return false }
        let production = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Miji").path
        return IndexPathFilter.canonicalPath(data) != IndexPathFilter.canonicalPath(production)
    }()
    static let useLegacyEventLatency = isolatedTest && environment["MIJI_INDEX_EVENT_LATENCY_MS"] == "1000"
    static let active: IndexBenchmarkTrace? = {
        guard isolatedTest, let path = environment["MIJI_INDEX_TRACE_FILE"], path.hasPrefix("/") else { return nil }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        return IndexBenchmarkTrace(file: FileHandle(fileDescriptor: fd, closeOnDealloc: true),
                                   prefix: environment["MIJI_INDEX_TRACE_PATH_PREFIX"])
    }()

    struct Record: Encodable, Sendable {
        var phase: String
        var uptime_ns = DispatchTime.now().uptimeNanoseconds
        var path: String?
        var paths: [String]?
        var revision: Int64?
        var previous_revision: Int64?
        var operation: String?
        var event_id: UInt64?
        var batch: UInt64?
        var flags: UInt32?
        var latency_ms: Int?
        var complete: Bool?
    }

    private let file: FileHandle
    private let prefix: String?
    private let output = DispatchQueue(label: "local.miji.index-benchmark-trace", qos: .utility)

    private init(file: FileHandle, prefix: String?) {
        self.file = file
        self.prefix = prefix.flatMap { $0.hasPrefix("/") ? Self.comparablePath($0) : nil }
    }

    private static func comparablePath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        var path = path.hasPrefix(data + "/") ? String(path.dropFirst(data.count)) : path
        if ["/private/var/", "/private/tmp/"].contains(where: { path.hasPrefix($0) }) {
            path = String(path.dropFirst("/private".count))
        }
        return path
    }

    private func matches(_ path: String, includeAncestor: Bool = false) -> Bool {
        guard let prefix else { return true }
        let path = Self.comparablePath(path)
        return path.hasPrefix(prefix) || (includeAncestor && prefix.hasPrefix(path == "/" ? "/" : path + "/"))
    }

    func events(_ events: [FileChangeEvent], receivedAt: UInt64) {
        let records = events.compactMap { event -> Record? in
            guard matches(event.path) else { return nil }
            return Record(phase: "event", uptime_ns: receivedAt, path: event.path,
                          event_id: event.id, batch: receivedAt, flags: event.flags)
        }
        append(records)
    }

    func append(_ record: Record) {
        append([record])
    }

    private func append(_ records: [Record]) {
        guard !records.isEmpty else { return }
        output.async { [file] in
            let encoder = JSONEncoder()
            var lines = Data()
            for record in records {
                if let line = try? encoder.encode(record) {
                    lines.append(line)
                    lines.append(0x0A)
                }
            }
            try? file.write(contentsOf: lines)
        }
    }

    private static func absolutePath(_ relative: String, root: IndexedRoot) -> String {
        guard !relative.isEmpty else { return root.path }
        return (root.path == "/" ? "" : root.path) + "/" + relative
    }

    /// Read the catalog revision around the successful transaction only for
    /// matching scopes. The name journal verifies which traced upserts changed.
    static func scanCommit<T>(database: SearchDatabase, root: IndexedRoot, scope: String,
                              upserts: [FileRecord]? = nil, _ body: () throws -> T) rethrows -> T {
        guard let trace = active else { return try body() }
        let path = absolutePath(scope, root: root)
        guard trace.matches(path, includeAncestor: true) else { return try body() }
        let inputs: [FileRecord]
        if let upserts, trace.prefix != nil {
            inputs = upserts.filter { trace.matches(absolutePath($0.relativePath, root: root)) }
            guard !inputs.isEmpty else { return try body() }
        } else {
            inputs = []
        }
        let before = try? database.catalogRevision()
        let result = try body()
        let committedAt = DispatchTime.now().uptimeNanoseconds
        if let before, let after = try? database.catalogRevision(), after > before {
            let paths = inputs.compactMap { record -> String? in
                let changed = try? database.synchronized {
                    let row = try database.prepare("""
                        SELECT 1 FROM files f JOIN name_changes c ON c.file_id=f.id
                        WHERE f.root_id=? AND f.relative_path=? AND c.revision>?
                        """)
                    defer { sqlite3_finalize(row) }
                    try database.bind([.string(root.id), .string(record.relativePath), .integer(before)], to: row)
                    return try database.next(row)
                }
                return changed == true ? absolutePath(record.relativePath, root: root) : nil
            }
            if inputs.isEmpty || !paths.isEmpty {
                trace.append(Record(phase: "commit", uptime_ns: committedAt, path: path,
                                    paths: paths, revision: after, previous_revision: before,
                                    operation: upserts == nil ? "prune" : "upsert"))
            }
        }
        return result
    }

    func scanFinished(database: SearchDatabase, root: IndexedRoot, scope: String, complete: Bool) {
        let path = Self.absolutePath(scope, root: root)
        guard matches(path, includeAncestor: true) else { return }
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        append(Record(phase: "scan_finished", uptime_ns: finishedAt, path: path,
                      revision: try? database.catalogRevision(), complete: complete))
    }

    func idle(database: SearchDatabase) {
        let idleAt = DispatchTime.now().uptimeNanoseconds
        append(Record(phase: "idle", uptime_ns: idleAt, revision: try? database.catalogRevision()))
    }
}
