import Combine
import Foundation
import XCTest
import MijiCore
@testable import MijiApp

/// Optional authored-corpus evaluation through the actual AppModel scheduler.
/// MIJI_GUI_EVALUATION_DIR contains an isolated index.sqlite and queries.json.
final class GUIQualityEvaluationTests: XCTestCase {
    private struct Corpus: Decodable { let queries: [Query] }
    private struct Query: Decodable {
        let id: String, query: String, scope: String
        let filters: Filters
        let targets: [String]
        let labels: [String: Int]
        let holdout: Bool
    }
    private struct Filters: Decodable {
        let kind: String?, rootID: String?, sort: String?, onlineOnly: Bool?
    }
    private struct Frame {
        let ms: Double
        let paths: [String]
        let snippets: [String]
    }
    @MainActor func testAuthoredCorpusThroughRealScheduler() async throws {
        guard let directory=ProcessInfo.processInfo.environment["MIJI_GUI_EVALUATION_DIR"] else {
            throw XCTSkip("Set MIJI_GUI_EVALUATION_DIR to an isolated authored quality corpus")
        }
        let oldDirectory=ProcessInfo.processInfo.environment["MIJI_DATA_DIR"]
        let oldAuto=ProcessInfo.processInfo.environment["MIJI_NO_AUTOSTART"]
        setenv("MIJI_DATA_DIR",directory,1);setenv("MIJI_NO_AUTOSTART","1",1)
        defer {
            if let oldDirectory {setenv("MIJI_DATA_DIR",oldDirectory,1)}else{unsetenv("MIJI_DATA_DIR")}
            if let oldAuto {setenv("MIJI_NO_AUTOSTART",oldAuto,1)}else{unsetenv("MIJI_NO_AUTOSTART")}
        }
        let corpus=try JSONDecoder().decode(Corpus.self,from:Data(contentsOf:URL(fileURLWithPath:directory).appendingPathComponent("queries.json")))
        let model=AppModel();model.service?.stop() // The source corpus is frozen for evaluation.
        model.previewMode = .hidden
        model.setSearchVisible(true)
        var reports: [[String: Any]]=[]
        for query in corpus.queries {
            model.query="";model.kind=query.filters.kind.flatMap(FileKind.init(rawValue:));model.rootID=query.filters.rootID;model.scope=SearchScope(rawValue:query.scope) ?? .all
            model.sort=query.filters.sort.flatMap(SearchSort.init(rawValue:)) ?? .relevance;model.preferences.retainOffline = !(query.filters.onlineOnly ?? false)
            var frames:[Frame]=[]
            let started=ProcessInfo.processInfo.systemUptime
            let observation=model.$hits.sink { hits in
                frames.append(Frame(ms:(ProcessInfo.processInfo.systemUptime-started)*1000,
                                    paths:hits.map {$0.root.id + "/" + $0.file.relativePath},snippets:hits.map(\.snippet)))
            }
            model.query=query.query
            for _ in 0..<1500 {
                if model.searchPhase == .complete || model.searchPhase == .failed {break}
                try await Task.sleep(nanoseconds:10_000_000)
            }
            observation.cancel()
            XCTAssertEqual(model.searchPhase,.complete,"\(query.id): query must reach completion")
            let finalPaths=model.hits.map {$0.root.id + "/" + $0.file.relativePath}
            let finalSnippets=model.hits.map(\.snippet)
            XCTAssertTrue(finalPaths.allSatisfy {query.labels[$0] != nil},"\(query.id): unlabelled results must be reviewed")
            let first=frames.first { frame in frame.paths.contains { (query.labels[$0] ?? 0) >= 2 } }?.ms
            let stable=frames.first { Array($0.paths.prefix(10)) == Array(finalPaths.prefix(10)) && Array($0.snippets.prefix(10)) == Array(finalSnippets.prefix(10)) }?.ms
            let firstTarget=finalPaths.firstIndex { query.labels[$0] == 3 }.map {$0+1}
            reports.append(["id":query.id,"query":query.query,"scope":query.scope,"holdout":query.holdout,
                            "isLimited":model.searchStatus.isLimited,"successAt5":finalPaths.prefix(5).contains {query.labels[$0] == 3},
                            "firstCorrectRank":firstTarget as Any? ?? NSNull(),"firstRelevantMS":first as Any? ?? NSNull(),
                            "topTenStableAndReadyMS":stable as Any? ?? NSNull(),
                            "completedMS":model.completedMilliseconds as Any? ?? NSNull(),"paths":finalPaths,
                            "topTenSnippets":Array(finalSnippets.prefix(10))])
        }
        model.setSearchVisible(false)
        let output=URL(fileURLWithPath:directory).appendingPathComponent("gui-evaluation.json")
        try JSONSerialization.data(withJSONObject:["annotation":"agent provisional, synthetic corpus","scheduler":"AppModel","queries":reports],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("GUI_EVALUATION \(output.path)")
    }
}
