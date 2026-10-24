import XCTest
import Darwin
@testable import MijiCore

final class ScannerTests:XCTestCase {
    private final class DrainWitness:NSObject {
        let released:()->Void
        init(_ released:@escaping ()->Void) {self.released=released}
        deinit {released()}
    }
    var temporary:URL!
    var folder:URL!
    var database:SearchDatabase!
    override func setUpWithError() throws {
        temporary=FileManager.default.temporaryDirectory.appendingPathComponent("miji-scanner-\(UUID().uuidString)")
        folder=temporary.appendingPathComponent("资料")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        database=try SearchDatabase(url:temporary.appendingPathComponent("index.sqlite"))
    }
    override func tearDownWithError() throws {database=nil;try FileManager.default.removeItem(at:temporary)}
    func testLongScanReleasesAutoreleasedObjectsBetweenBatches() throws {
        for index in 0..<1_500 {
            try autoreleasepool {try Data().write(to:folder.appendingPathComponent("file-\(index).txt"))}
        }
        let root=try VolumeIdentity.root(for:folder)
        var issued=0,released=0,maximumLive=0
        try autoreleasepool {
            _=try FileScanner(database:database).scan(root:root,progress:{_ in
                maximumLive=max(maximumLive,issued-released)
                issued += 1
                _=Unmanaged.passRetained(DrainWitness {released += 1}).autorelease()
            })
        }
        XCTAssertEqual(released,issued)
        XCTAssertEqual(maximumLive,0,"扫描及回调临时对象须在批次之间释放，不能留到百万文件扫描结束")
    }
    func testIncrementalDeletionAndMissingRootKeepsOfflineResults() throws {
        let file=folder.appendingPathComponent("数学分析.md")
        try "一致收敛".write(to:file,atomically:true,encoding:.utf8)
        let root=try VolumeIdentity.root(for:folder)
        let scanner=FileScanner(database:database)
        XCTAssertTrue(try scanner.scan(root:root).complete)
        XCTAssertEqual(try database.search("数学").count,1)
        let pending=try XCTUnwrap(database.pendingFiles(rootID:root.id).first)
        XCTAssertTrue(try database.completeContent(file:pending,content:ExtractedContent(text:"一致收敛")))
        let away=temporary.appendingPathComponent("临时移走")
        try FileManager.default.moveItem(at:folder,to:away)
        XCTAssertFalse(try scanner.scan(root:root).complete)
        let offline=try XCTUnwrap(database.search("一致收敛").first)
        XCTAssertFalse(offline.root.isOnline)
        XCTAssertEqual(try database.search("一致收敛",options:SearchOptions(onlineOnly:true)).count,0)
        try FileManager.default.moveItem(at:away,to:folder)
        XCTAssertTrue(try scanner.scan(root:root).complete)
        XCTAssertTrue(try XCTUnwrap(database.search("一致收敛").first).root.isOnline)
        try FileManager.default.removeItem(at:file)
        XCTAssertTrue(try scanner.scan(root:root).complete)
        XCTAssertEqual(try database.search("数学").count,0)
    }
    func testCancelledScanDoesNotPruneAndSkipsSymlinkCycles() throws {
        try "x".write(to:folder.appendingPathComponent("保留.txt"),atomically:true,encoding:.utf8)
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("循环"),withDestinationURL:folder)
        let root=try VolumeIdentity.root(for:folder)
        let scanner=FileScanner(database:database)
        XCTAssertEqual(try scanner.scan(root:root).count,1)
        XCTAssertFalse(try scanner.scan(root:root,cancelled:{true}).complete)
        XCTAssertEqual(try database.search("保留").count,1)
    }
    func testUnreadableSubtreesPreserveOnlyTheirRecordsAndRootFailurePreservesAll() throws {
        let locked = folder.appendingPathComponent("禁止访问")
        let sibling = folder.appendingPathComponent("禁止访问-other")
        for directory in [locked,sibling] {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
        let protected = locked.appendingPathComponent("保护.txt")
        let gone = sibling.appendingPathComponent("消失.txt")
        for url in [protected,gone] {try "fixture".write(to:url,atomically:true,encoding:.utf8)}
        let root = try VolumeIdentity.root(for:folder)
        let scanner = FileScanner(database:database)
        XCTAssertTrue(try scanner.scan(root:root).complete)
        try FileManager.default.removeItem(at:gone)
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:locked.path)
        defer {
            // Restore the parent before accessing the locked child for cleanup.
            try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
            try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:locked.path)
        }
        guard !FileManager.default.isReadableFile(atPath:locked.path) else {throw XCTSkip("当前执行身份可绕过目录权限，无法制造真实拒绝访问")}
        let partial = try scanner.scan(root:root)
        XCTAssertFalse(partial.complete)
        XCTAssertFalse(partial.errors.isEmpty)
        XCTAssertEqual(try database.search("保护.txt").count,1)
        XCTAssertEqual(try database.search("消失.txt").count,0)
        let before = try database.statistics().files
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:folder.path)
        do {
            let inaccessible = try scanner.scan(root:root)
            XCTAssertFalse(inaccessible.complete)
        } catch { /* A wholly unreadable root may fail before enumeration starts. */ }
        XCTAssertEqual(try database.statistics().files,before)
    }
    func testDevelopmentCachesAndHiddenSettings() throws {
        let cache=folder.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        try "x".write(to:cache.appendingPathComponent("依赖.txt"),atomically:true,encoding:.utf8)
        try "x".write(to:folder.appendingPathComponent(".隐藏.txt"),atomically:true,encoding:.utf8)
        let root=try VolumeIdentity.root(for:folder);let scanner=FileScanner(database:database)
        XCTAssertEqual(try scanner.scan(root:root,options:ScanOptions(includeHidden:false,excludeDevelopmentCaches:true)).count,0)
        XCTAssertEqual(try scanner.scan(root:root).count,3)
    }
    func testLogicalBootRootAllowsDataButSkipsMountAliases() throws {
        let root = IndexedRoot(path:"/",volumeUUID:"system")
        let policy = ScanVolumePolicy(root:root,dataVolumeUUID:"data")
        XCTAssertFalse(policy.skipsDirectory(path:"/Users",volumeUUID:"data"))
        XCTAssertFalse(policy.skipsDirectory(path:"/Library",volumeUUID:"data"))
        XCTAssertFalse(policy.skipsDirectory(path:"/System/Library",volumeUUID:"system"))
        XCTAssertTrue(policy.skipsDirectory(path:"/System/Volumes",volumeUUID:"system"))
        XCTAssertTrue(policy.skipsDirectory(path:"/System/Volumes/Data/Users",volumeUUID:"data"))
        XCTAssertTrue(policy.skipsDirectory(path:"/Volumes",volumeUUID:"data"))
        XCTAssertTrue(policy.skipsDirectory(path:"/Volumes/External",volumeUUID:"external"))
        XCTAssertTrue(policy.skipsDirectory(path:"/.nofollow",volumeUUID:"system"))
        XCTAssertTrue(policy.skipsDirectory(path:"/.nofollow/",volumeUUID:"system"))
        XCTAssertTrue(policy.skipsDirectory(path:"/Users/mounted",volumeUUID:"external"))
        let ordinary = ScanVolumePolicy(root:IndexedRoot(path:"/Users",volumeUUID:"data"),dataVolumeUUID:"data")
        XCTAssertTrue(ordinary.skipsDirectory(path:"/Users/mounted",volumeUUID:"external"))
        let external = ScanVolumePolicy(root:IndexedRoot(path:"/Volumes/External",volumeUUID:"external",isExternal:true))
        XCTAssertFalse(external.skipsDirectory(path:"/Volumes/External/folder",volumeUUID:"external"))
        // Only resource metadata is read; never enumerate the real boot root.
        let actualRoot = try VolumeIdentity.root(for:URL(fileURLWithPath:"/"))
        let usersUUID = try URL(fileURLWithPath:"/Users").resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString
        XCTAssertFalse(ScanVolumePolicy(root:actualRoot).skipsDirectory(path:"/Users",volumeUUID:usersUUID))
    }
    func testVirtualNoFollowRootAliasDoesNotQueueFullRootRecovery() throws {
        let root=try VolumeIdentity.root(for:URL(fileURLWithPath:"/"))
        let result=try FileScanner(database:database).scan(root:root,relativePath:".nofollow")
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.count,0)
        XCTAssertTrue(result.preservingPaths.isEmpty)
    }
    func testCodeIsPendingAndSelfIndexPathsArePreciselyExcluded() throws {
        let appData = folder.appendingPathComponent("MijiData")
        let sibling = folder.appendingPathComponent("MijiData-other")
        for directory in [appData,sibling] { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
        try "private".write(to:appData.appendingPathComponent("self.txt"),atomically:true,encoding:.utf8)
        try "public".write(to:sibling.appendingPathComponent("public.txt"),atomically:true,encoding:.utf8)
        try "let searchable = true".write(to:folder.appendingPathComponent("source.swift"),atomically:true,encoding:.utf8)
        let root = try VolumeIdentity.root(for:folder)
        XCTAssertTrue(try FileScanner(database:database,ignoredPaths:[appData.path]).scan(root:root).complete)
        XCTAssertEqual(try database.search("self.txt").count,0)
        XCTAssertEqual(try database.search("public.txt").count,1)
        let code = try XCTUnwrap(database.pendingFiles(rootID:root.id,kind:.code).first)
        XCTAssertEqual(code.relativePath,"source.swift")
        let filter = IndexPathFilter(ignoredPaths:["/Users/example/Library/Miji/index.sqlite"])
        XCTAssertTrue(filter.ignores("/Users/example/Library/Miji/index.sqlite-wal"))
        XCTAssertTrue(filter.ignores("/System/Volumes/Data/Users/example/Library/Miji/index.sqlite-shm"))
        XCTAssertFalse(filter.ignores("/Users/example/Library/Miji/index.sqlite-other"))
        XCTAssertFalse(filter.ignores("/Users/example/Library/Documents/note.txt"))
    }
    func testAliasedRootAndPackageChildChanges() throws {
        let package=folder.appendingPathComponent("资料.rtfd")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        let member=package.appendingPathComponent("TXT.rtf")
        try "old content".write(to:member,atomically:true,encoding:.utf8)
        let alias=temporary.appendingPathComponent("目录别名")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:folder)
        let root=IndexedRoot(path:alias.path)
        let scanner=FileScanner(database:database)
        XCTAssertTrue(try scanner.scan(root:root).complete)
        let original=try XCTUnwrap(database.pendingFiles(rootID:root.id).first)
        XCTAssertEqual(original.relativePath,"资料.rtfd")
        _=try database.completeContent(file:original,content:ExtractedContent(text:"old content"))
        let packageDate=try FileManager.default.attributesOfItem(atPath:package.path)[.modificationDate] as! Date
        try "new content with a new version".write(to:member,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.modificationDate:packageDate],ofItemAtPath:package.path)
        XCTAssertTrue(try scanner.scan(root:root).complete)
        XCTAssertEqual(try database.search("old content").count,0)
        XCTAssertEqual(try database.pendingFiles(rootID:root.id).count,1)
        XCTAssertFalse(try FileSignature.read(package).matches(original))
    }
    func testReplacementWithSameSizeAndDateChangesSignature() throws {
        let url=folder.appendingPathComponent("替换.txt")
        try "old".write(to:url,atomically:true,encoding:.utf8)
        let root=try VolumeIdentity.root(for:folder)
        _=try FileScanner(database:database).scan(root:root)
        let original=try XCTUnwrap(database.pendingFiles(rootID:root.id).first)
        XCTAssertTrue(try FileSignature.read(url).matches(original))
        try "new".write(to:url,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:original.modified)],ofItemAtPath:url.path)
        XCTAssertFalse(try FileSignature.read(url).matches(original))
    }
    func testSignatureKeepsFoundationTimestampAndInodeCompatibility() throws {
        let url=folder.appendingPathComponent("保留已有正文.txt")
        try Data("preserved".utf8).write(to:url)
        for seconds in [0,978_307_200,1_791_913_257,4_102_444_800] {
          for nanoseconds in stride(from:0,to:1_000_000_000,by:7_654_321) {
            var times=[timespec(tv_sec:seconds,tv_nsec:nanoseconds),timespec(tv_sec:seconds,tv_nsec:nanoseconds)]
            XCTAssertEqual(utimensat(AT_FDCWD,url.path,&times,0),0)
            let old=try FileManager.default.attributesOfItem(atPath:url.path)
            let signature=try FileSignature.read(url)
            XCTAssertEqual(signature.modified,(old[.modificationDate] as! Date).timeIntervalSince1970,"新版本不能使未修改文件的旧正文失效")
            XCTAssertEqual(signature.inode,(old[.systemFileNumber] as! NSNumber).int64Value)
            XCTAssertEqual(signature.size,(old[.size] as! NSNumber).int64Value)
          }
        }
    }
}

extension ScannerTests {
    func testScopedScanPrunesOnlyItsSubtreeAndKeepsDoneSiblings() throws {
        let root=try VolumeIdentity.root(for:folder)
        for name in ["tree/gone.txt","tree/keep.txt","tree-other/sibling.txt"] {
            let url=folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data("original".utf8).write(to:url)
        }
        let scanner=FileScanner(database:database)
        _=try scanner.scan(root:root)
        for file in try database.pendingFiles(rootID:root.id) { _=try database.completeContent(file:file,content:ExtractedContent(text:"retained")) }
        let sibling=try XCTUnwrap(database.search("sibling.txt").first?.file)
        try FileManager.default.removeItem(at:folder.appendingPathComponent("tree/gone.txt"))
        try Data("new".utf8).write(to:folder.appendingPathComponent("tree/new.txt"))
        let result=try scanner.scan(root:root,relativePath:"tree")
        XCTAssertTrue(result.complete);XCTAssertEqual(result.count,3)
        XCTAssertEqual(try database.search("gone.txt").count,0)
        XCTAssertEqual(try database.search("new.txt").count,1)
        XCTAssertEqual(try database.search("sibling.txt").first?.file.id,sibling.id)
        XCTAssertEqual(try database.search("sibling.txt").first?.file.contentState,"done")
        XCTAssertEqual(try database.search("keep.txt").first?.file.contentState,"done")
        try FileManager.default.removeItem(at:folder.appendingPathComponent("tree"))
        XCTAssertTrue(try scanner.scan(root:root,relativePath:"tree").complete)
        XCTAssertEqual(try database.search("new.txt").count,0)
        XCTAssertEqual(try database.search("sibling.txt").count,1)
    }
    func testScopedCancellationOfflineAndPermissionFailureKeepHistory() throws {
        let tree=folder.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at:tree,withIntermediateDirectories:true)
        try Data("fixture".utf8).write(to:tree.appendingPathComponent("keep.txt"))
        let root=try VolumeIdentity.root(for:folder), scanner=FileScanner(database:database)
        _=try scanner.scan(root:root)
        XCTAssertFalse(try scanner.scan(root:root,relativePath:"tree",cancelled:{true}).complete)
        XCTAssertEqual(try database.search("keep.txt").count,1)
        let away=temporary.appendingPathComponent("away")
        try FileManager.default.moveItem(at:folder,to:away)
        XCTAssertFalse(try scanner.scan(root:root,relativePath:"tree").complete)
        XCTAssertEqual(try database.search("keep.txt").count,1)
        try FileManager.default.moveItem(at:away,to:folder)
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:tree.path)
        defer {try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:tree.path)}
        guard !FileManager.default.isReadableFile(atPath:tree.path) else {throw XCTSkip("执行身份绕过目录权限")}
        let result=try scanner.scan(root:root,relativePath:"tree")
        XCTAssertFalse(result.complete)
        XCTAssertTrue(result.preservingPaths.contains("tree"))
        XCTAssertEqual(try database.search("keep.txt").count,1)
    }
    func testBootRootAndAliasesProduceCanonicalRelativePathsWithoutProductionScan() throws {
        XCTAssertEqual(IndexRelativePath.from("//Users/example/file.txt",root:"/"),"Users/example/file.txt")
        XCTAssertEqual(IndexRelativePath.from("/System/Volumes/Data/Users/example/file.txt",root:"/"),"Users/example/file.txt")
        XCTAssertEqual(IndexRelativePath.from("/System/Volumes/Data",root:"/"),"")
        XCTAssertNil(IndexRelativePath.from("/Users/example-other/file.txt",root:"/Users/example"))
        XCTAssertFalse(IndexRelativePath.validated("a//b"))
        XCTAssertFalse(IndexRelativePath.validated("a/../b"))
        let alias=temporary.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:folder)
        let file=folder.appendingPathComponent("scope.txt")
        try Data("fixture".utf8).write(to:file)
        XCTAssertEqual(IndexRelativePath.from(alias.appendingPathComponent("removed.txt").path,root:folder.path),"removed.txt","删除事件必须解析仍存在的别名祖先")
        if folder.path.hasPrefix("/var/") {
            XCTAssertEqual(IndexRelativePath.from("/private" + folder.path + "/removed.txt",root:folder.path),"removed.txt")
        }
        let root=IndexedRoot(path:alias.path)
        XCTAssertTrue(try FileScanner(database:database).scan(root:root,relativePath:"scope.txt").complete)
        XCTAssertEqual(try database.search("scope.txt").first?.file.relativePath,"scope.txt")
    }
}
