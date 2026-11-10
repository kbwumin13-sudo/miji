import Foundation
import MijiCore

/// Synthetic corpus ingestion and JSONL evaluation; never used by the app.
enum QualityEvaluation {
    struct Document: Decodable {
        var path: String
        var text: String
        var root: String
        var kind: FileKind
        var modified: Double
        var labels: [String]
    }
    struct Manifest: Decodable { var documents: [Document] }
    static func option(_ name: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
        return args[i + 1]
    }
    static func required(_ name: String, _ args: [String]) throws -> String {
        guard let value = option(name, args) else { throw NSError(domain: "MijiCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 \(name)"]) }
        return value
    }
    static func index(arguments args: [String]) throws {
        let source = URL(fileURLWithPath: try required("--manifest", args))
        var docs = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: source)).documents
        switch option("--order", args) ?? "forward" {
        case "reverse": docs.reverse()
        case "random":
            var seed: UInt64 = 741_219
            for i in docs.indices.reversed() where i > 0 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                docs.swapAt(i, Int(seed % UInt64(i + 1)))
            }
        default: break
        }
        let db = try SearchDatabase(url: URL(fileURLWithPath: try required("--database", args)))
        for root in Set(docs.map(\.root)).sorted() {
            try db.saveRoot(IndexedRoot(id: root, path: source.deletingLastPathComponent().appendingPathComponent(root).path,
                                       name: root == "desk" ? "工作盘" : "资料盘", isExternal: root != "desk", isOnline: root != "offline"))
        }
        // Insert and complete in the requested order; paths and timestamps are identical.
        for doc in docs {
            let name = (doc.path as NSString).lastPathComponent
            let file = FileRecord(rootID: doc.root, relativePath: doc.path, name: name,
                                  fileExtension: (name as NSString).pathExtension, kind: doc.kind,
                                  size: Int64(doc.text.utf8.count), modified: doc.modified)
            try db.upsertFiles([file], generation: 1)
            guard let pending = try db.pendingFiles(rootID: doc.root, limit: 1).first else { continue }
            _ = try db.completeContent(file: pending, content: ExtractedContent(text: doc.text, labels: doc.labels))
        }
        try emit(["documents": docs.count, "order": option("--order", args) ?? "forward"])
    }
    static func search(arguments args: [String]) throws {
        let url = URL(fileURLWithPath: try required("--database", args))
        let db = try SearchDatabase(url: url, readOnly: true)
        let scope = option("--scope", args).flatMap(SearchScope.init(rawValue:)) ?? .content
        let options = SearchOptions(kind: option("--kind", args).flatMap(FileKind.init(rawValue:)),
                                    rootID: option("--root-id", args), scope: scope,
                                    sort: option("--sort", args).flatMap(SearchSort.init(rawValue:)) ?? .relevance,
                                    onlineOnly: args.contains("--online-only"), limit: Int(option("--limit", args) ?? "500") ?? 500)
        let queries = (try? String(contentsOfFile: required("--queries-file", args), encoding: .utf8))?.components(separatedBy: .newlines).filter { !$0.isEmpty }
            ?? [option("--query", args) ?? ""]
        let rounds = max(1, Int(option("--rounds", args) ?? "1") ?? 1)
        let engine = scope == .content ? nil : try NameSearchEngine(databaseURL: url)
        try engine?.load()
        for round in 0..<rounds {
            for query in queries {
                var metrics = SearchMetrics()
                var partials: [[String: Any]] = []
                let start = DispatchTime.now().uptimeNanoseconds
                func ms() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
                var nameOptions = options; nameOptions.scope = .name
                var names: [SearchHit] = []
                if let engine {
                    var examined = 0
                    let exclusions = scope == .all && QueryParser.parse(query).terms.contains { $0.field == .text && $0.isExcluded }
                    repeat {
                        let ids = try engine.search(query, options: nameOptions)
                        names += try db.nameHits(ids: Array(ids.dropFirst(examined)), query: query, verifyContentExclusions: exclusions)
                        if !exclusions || names.count >= options.limit || ids.count < nameOptions.limit { break }
                        examined = ids.count; nameOptions.limit *= 2
                    } while true
                    names = Array(names.prefix(options.limit))
                }
                let nameMS = ms()
                let content = scope == .name ? [] : try db.searchSupplementary(query, options: options, onPartial: { hits in
                    partials.append(["ms": ms(), "paths": hits.prefix(10).map { $0.root.id + "/" + $0.file.relativePath }])
                }, traceCandidates: args.contains("--trace"), onMetrics: { metrics = $0 })
                let merged = SearchResultMerger.merge(nameResults: names, contentResults: content, scope: scope,
                    sort: options.sort, limit: options.limit, query: query)
                let value: [String: Any] = ["query": query, "round": round, "name_ms": nameMS, "final_ms": ms(),
                    "metrics": try encoded(metrics), "partials": partials,
                    "hits": merged.map { ["path": $0.root.id + "/" + $0.file.relativePath, "matchedIn": $0.matchedIn, "snippet": $0.snippet] },
                    "content_paths": content.map { $0.root.id + "/" + $0.file.relativePath }]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
                FileHandle.standardOutput.write(Data([10]))
            }
        }
    }
}
