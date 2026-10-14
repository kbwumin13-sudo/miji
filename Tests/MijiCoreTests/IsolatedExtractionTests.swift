import XCTest
import Foundation
import Darwin
@testable import MijiCore

final class IsolatedExtractionTests: XCTestCase {
    private var directory: URL!
    private var input: URL { directory.appendingPathComponent("有 空格 ' 文档.pdf") }
    private var pidFile: URL { URL(fileURLWithPath: input.path + ".pid") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func helper(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("fixture helper")
        let script = """
        #!/bin/sh
        [ "$1" = extract ] && [ "$2" = --file ] && [ "$#" = 3 ] || exit 91
        printf '%s' "$$" > "$3.pid"
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func assertReaped(pidURL: URL? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL ?? pidFile)), file: file, line: line)
        XCTAssertEqual(kill(pid, 0), -1, "worker must be gone", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, file: file, line: line)
        XCTAssertEqual(errno, ECHILD, "worker must already be reaped", file: file, line: line)
    }

    private func payload(_ content: ExtractedContent) throws {
        try JSONEncoder().encode(content).write(to: URL(fileURLWithPath: input.path + ".json"))
    }

    func testSuccessPreservesContentAndPassesPathAsOneArgument() throws {
        let expected = ExtractedContent(text: "OCR 中文\n正文", labels: ["文档", "截图"], pages: 3, warning: "部分页面")
        try payload(expected)
        let executable = try helper("exec /bin/cat \"$3.json\"")
        let result = try IsolatedContentExtractor.extract(url: input, executable: executable, cancelled: { false })
        XCTAssertEqual(result.text, expected.text)
        XCTAssertEqual(result.labels, expected.labels)
        XCTAssertEqual(result.pages, expected.pages)
        XCTAssertEqual(result.warning, expected.warning)
        try assertReaped()
    }

    func testDeadlineKillsAndReapsUncooperativeWorker() throws {
        let executable = try helper("trap '' TERM\nwhile :; do :; done")
        let start = Date()
        XCTAssertThrowsError(try IsolatedContentExtractor.extract(url: input, executable: executable,
                                                                  cancelled: { false }, timeout: 0.75)) {
            guard case .invalidDocument = $0 as? ContentExtractionError else {
                return XCTFail("Expected parent timeout, got \($0)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try assertReaped()
    }

    func testCancellationKillsAndReapsUncooperativeWorker() throws {
        let executable = try helper("trap '' TERM\nwhile :; do :; done")
        let start = Date()
        XCTAssertThrowsError(try IsolatedContentExtractor.extract(url: input, executable: executable,
            cancelled: { (try? String(contentsOf: self.pidFile)).flatMap(Int32.init) != nil }, timeout: 5)) {
            XCTAssertEqual($0 as? ContentExtractionError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try assertReaped()
    }

    func testAlreadyCancelledDoesNotLaunch() throws {
        let executable = try helper("exit 0")
        XCTAssertThrowsError(try IsolatedContentExtractor.extract(url: input, executable: executable,
                                                                  cancelled: { true })) {
            XCTAssertEqual($0 as? ContentExtractionError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testExcessiveStdoutKillsAndReapsWorker() throws {
        let executable = try helper("exec /usr/bin/yes")
        XCTAssertThrowsError(try IsolatedContentExtractor.extract(url: input, executable: executable,
                                                                  cancelled: { false }, timeout: 60)) {
            guard case .resourceLimit = $0 as? ContentExtractionError else {
                return XCTFail("Expected bounded stdout, got \($0)")
            }
        }
        try assertReaped()
    }

    func testLargeStderrAndNonzeroExitHaveBoundedDiagnostics() throws {
        let executable = try helper("/bin/dd if=/dev/zero bs=4096 count=512 1>&2 2>/dev/null\nprintf 'failure' >&2\nexit 7")
        XCTAssertThrowsError(try IsolatedContentExtractor.extract(url: input, executable: executable,
                                                                  cancelled: { false }, timeout: 10)) {
            guard case .invalidDocument(let message) = $0 as? ContentExtractionError else {
                return XCTFail("Expected helper failure, got \($0)")
            }
            XCTAssertLessThanOrEqual(message.utf8.count, 4096)
        }
        try assertReaped()
    }

    func testMalformedJSONIsInvalidDocument() throws {
        let executable = try helper("printf 'not JSON'")
        XCTAssertThrowsError(try IsolatedContentExtractor.extract(url: input, executable: executable,
                                                                  cancelled: { false })) {
            guard case .invalidDocument = $0 as? ContentExtractionError else {
                return XCTFail("Expected decoding failure, got \($0)")
            }
        }
        try assertReaped()
    }

    func testDecodedTextOverLimitIsRejected() throws {
        try payload(ExtractedContent(text: String(repeating: "a", count: 8 * 1024 * 1024 + 1)))
        let executable = try helper("exec /bin/cat \"$3.json\"")
        XCTAssertThrowsError(try IsolatedContentExtractor.extract(url: input, executable: executable,
                                                                  cancelled: { false }, timeout: 30)) {
            guard case .resourceLimit = $0 as? ContentExtractionError else {
                return XCTFail("Expected decoded text limit, got \($0)")
            }
        }
        try assertReaped()
    }

    func testMaximumEscapedTextIsAccepted() throws {
        let text = String(repeating: "\u{1}", count: 8 * 1024 * 1024)
        try payload(ExtractedContent(text: text))
        let executable = try helper("exec /bin/cat \"$3.json\"")
        let result = try IsolatedContentExtractor.extract(url: input, executable: executable,
                                                          cancelled: { false }, timeout: 60)
        XCTAssertEqual(result.text, text)
        try assertReaped()
    }

    func testTimeoutCannotExceedProductionDeadline() throws {
        let executable = try helper("exit 0")
        for timeout in [0, -1, 181, TimeInterval.infinity, TimeInterval.nan] {
            XCTAssertThrowsError(try IsolatedContentExtractor.extract(url: input, executable: executable,
                                                                      cancelled: { false }, timeout: timeout)) {
                guard case .invalidDocument = $0 as? ContentExtractionError else {
                    return XCTFail("Expected invalid timeout, got \($0)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testIndexServiceContinuesAfterHungImageAndFinishesTask() throws {
        let folder = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try SearchDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let root = try VolumeIdentity.root(for: folder)
        try database.saveRoot(root)
        let names = ["hung.png", "first.pdf", "next.pdf", "last.pdf", "ok1.png", "ok2.png", "ok3.png"]
        var records: [FileRecord] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: url)
            let signature = try FileSignature.read(url)
            records.append(FileRecord(rootID: root.id, relativePath: name, name: name,
                fileExtension: url.pathExtension, kind: FileKind.classify(extension: url.pathExtension),
                size: signature.size, modified: signature.modified, inode: signature.inode))
        }
        try database.upsertFiles(records, generation: 1)
        let executable = try helper("""
        case "$3" in
          */hung.png) trap '' TERM; while :; do :; done ;;
          *) printf '%s' '{"text":"fixture extracted","labels":["document"],"pages":1}' ;;
        esac
        """)
        let stateLock = NSLock()
        var timeoutObserved = false
        var completedAfterTimeout: [String] = []
        let service = IndexService(database: database,
            ignoredPaths: names.map { folder.appendingPathComponent($0).path + ".pid" },
            extractor: { url, cancelled in
                do {
                    let content = try IsolatedContentExtractor.extract(url: url, executable: executable,
                                                                        cancelled: cancelled, timeout: 1)
                    stateLock.lock()
                    if timeoutObserved { completedAfterTimeout.append(url.lastPathComponent) }
                    stateLock.unlock()
                    return content
                } catch {
                    if url.lastPathComponent == "hung.png" {
                        stateLock.lock(); timeoutObserved = true; stateLock.unlock()
                    }
                    throw error
                }
            })
        defer { service.stop() }
        let finished = expectation(description: "挂起图片失败后其余内容完成并更新任务")
        service.onProgress = { if $0.phase == "索引已更新" { finished.fulfill() } }
        var preferences = IndexingPreferences()
        preferences.autoAddExternal = false
        service.configure(preferences)
        wait(for: [finished], timeout: 8)
        let hung = try XCTUnwrap(database.search("hung.png").first?.file)
        XCTAssertEqual(hung.contentState, "error")
        XCTAssertFalse(hung.contentError?.isEmpty ?? true)
        for name in names where name != "hung.png" {
            XCTAssertEqual(try database.search(name).first?.file.contentState, "done", name)
        }
        let stats = try database.statistics()
        XCTAssertEqual(stats.pending, 0)
        XCTAssertEqual(stats.errors, 1)
        XCTAssertEqual(stats.indexedContent, names.count - 1)
        stateLock.lock()
        let afterTimeout = completedAfterTimeout
        stateLock.unlock()
        XCTAssertTrue(afterTimeout.contains { $0.hasSuffix(".png") })
        XCTAssertTrue(afterTimeout.contains { $0.hasSuffix(".pdf") })
        try assertReaped(pidURL: folder.appendingPathComponent("hung.png.pid"))
    }
}
