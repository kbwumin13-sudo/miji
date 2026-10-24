import XCTest
import AppKit
@testable import MijiCore

final class IndexServiceTests:XCTestCase {
    private final class DrainWitness:NSObject {
        let released:()->Void
        init(_ released:@escaping ()->Void) {self.released=released}
        deinit {released()}
    }
    func testContentBacklogReleasesTemporariesBetweenBatches() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-content-pool-\(UUID().uuidString)")
        let folder=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
        let root=try VolumeIdentity.root(for:folder);try db.saveRoot(root)
        for index in 0..<80 {try Data("pooltest".utf8).write(to:folder.appendingPathComponent("\(index).txt"))}
        let stateLock=NSLock()
        var live=0,maximumLive=0
        let service=IndexService(database:db,extractor:{_,_ in ExtractedContent(text:"pooltest")})
        service.onChange = {
            stateLock.lock();live += 1;maximumLive=max(maximumLive,live);stateLock.unlock()
            _=Unmanaged.passRetained(DrainWitness {stateLock.lock();live -= 1;stateLock.unlock()}).autorelease()
        }
        let finished=expectation(description:"批量正文写入完成")
        service.onProgress = {if $0.phase == "索引已更新" {finished.fulfill()}}
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs)
        wait(for:[finished],timeout:12)
        XCTAssertEqual(try db.statistics().indexedContent,80)
        stateLock.lock();let peak=maximumLive;stateLock.unlock()
        XCTAssertLessThanOrEqual(peak,12,"目录扫描后的正文积压也须按小批释放，不能等任务全部完成")
    }
    func testFirstRealScanExtractsContentBeforeEnumerationFinishesWithoutRescanning() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-interleave-\(UUID().uuidString)")
        let folder=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
        let root=try VolumeIdentity.root(for:folder);try db.saveRoot(root)
        let total=1_203
        for index in 0..<total {
            try "firstscancontent".write(to:folder.appendingPathComponent("file-\(index).txt"),atomically:true,encoding:.utf8)
        }
        let stateLock=NSLock()
        var phase="", scanStarts=0, completedDuringScan=false, namesDuringScan=false, wrongExtractionPhase=false
        var attempts:[String:Int]=[:]
        let engine=try NameSearchEngine(databaseURL:db.url);try engine.load()
        let service=IndexService(database:db,extractor:{url,cancelled in
            stateLock.lock()
            attempts[url.lastPathComponent,default:0] += 1
            if phase != "正在提取文档" {wrongExtractionPhase=true}
            stateLock.unlock()
            return ExtractedContent(text:try String(contentsOf:url,encoding:.utf8))
        })
        let finished=expectation(description:"首轮目录与正文完成")
        service.onIndexChange = {change in
            do {
                try engine.refresh(rootID:change.rootID,relativePaths:change.relativePaths,fullRescan:change.fullRescan)
                if !change.fullRescan,try db.statistics().files < total,try !engine.search("file-").isEmpty {
                    stateLock.lock();namesDuringScan=true;stateLock.unlock()
                }
            } catch {XCTFail("名称批次刷新失败：\(error)")}
        }
        service.onProgress = { progress in
            stateLock.lock()
            phase=progress.phase
            if progress.phase == "正在建立文件目录" && progress.processed == 0 {scanStarts += 1}
            stateLock.unlock()
            if progress.phase == "索引已更新" {finished.fulfill()}
        }
        service.onChange = {
            if let stats=try? db.statistics(), stats.files < total, stats.indexedContent > 0,
               (try? db.roots().first?.lastScan) == nil {
                stateLock.lock();completedDuringScan=true;stateLock.unlock()
            }
        }
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        service.configure(prefs)
        wait(for:[finished],timeout:18)
        let stats=try db.statistics()
        XCTAssertEqual(stats.files,total);XCTAssertEqual(stats.indexedContent,total)
        stateLock.lock()
        let interleaved=completedDuringScan, namesVisible=namesDuringScan, starts=scanStarts, wrongPhase=wrongExtractionPhase, calls=attempts
        stateLock.unlock()
        XCTAssertTrue(interleaved,"真实 scanner 尚未枚举完整根时，已提交批次应已有正文完成")
        XCTAssertTrue(namesVisible,"首扫未结束时，已提交名称应能通过增量journal搜索")
        XCTAssertEqual(starts,1,"提取首批正文不能依赖第二轮扫描")
        XCTAssertFalse(wrongPhase,"提取正文时进度不能仍显示正在建立文件目录")
        XCTAssertEqual(calls.count,total);XCTAssertTrue(calls.values.allSatisfy{$0 == 1})
    }

    func testExistingPendingStartsBeforeScanAndPausedPartialScanRetainsHistoryThenResumes() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-backlog-\(UUID().uuidString)")
        let folder=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
        let root=try VolumeIdentity.root(for:folder);try db.saveRoot(root)
        var records:[FileRecord]=[]
        for ext in ["txt","png","swift"] {
            for index in 0..<32 {
                let name="pending-\(index).\(ext)",url=folder.appendingPathComponent("pending-\(index).\(ext)")
                try Data("backlogcontent".utf8).write(to:url)
                let signature=try FileSignature.read(url)
                records.append(FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:ext,kind:FileKind.classify(extension:ext),size:signature.size,modified:signature.modified,inode:signature.inode))
            }
        }
        let historical=FileRecord(rootID:root.id,relativePath:"old-unseen.bin",name:"old-unseen.bin",fileExtension:"bin",kind:.other,size:0,modified:0,contentState:"skipped")
        try db.upsertFiles(records+[historical],generation:1)
        for index in 0..<900 {try Data().write(to:folder.appendingPathComponent("filler-\(index).bin"))}
        let stateLock=NSLock()
        var scanStarts=0, firstExtractionStarts:Int?, extractedKinds=Set<String>(), wrongPhase=false
        var phase="", paused=false
        let service=IndexService(database:db,extractor:{url,cancelled in
            stateLock.lock()
            if firstExtractionStarts == nil {firstExtractionStarts=scanStarts}
            extractedKinds.insert(url.pathExtension)
            if phase != (url.pathExtension == "png" ? "正在识别图片" : "正在提取文档") {wrongPhase=true}
            stateLock.unlock()
            return ExtractedContent(text:"backlogcontent")
        })
        let partial=expectation(description:"扫描在首批提交后暂停并退出")
        let finished=expectation(description:"恢复后扫描和正文完成")
        service.onProgress = { [weak service] progress in
            stateLock.lock()
            phase=progress.phase
            if progress.phase == "正在建立文件目录" && progress.processed == 0 {scanStarts += 1}
            let pauseNow = !paused && progress.phase == "正在建立文件目录" && progress.processed == 300
            if pauseNow {paused=true}
            stateLock.unlock()
            if pauseNow {service?.setPaused(true);partial.fulfill()}
            if progress.phase == "索引已更新" {finished.fulfill()}
        }
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        service.configure(prefs)
        wait(for:[partial],timeout:8)
        // A worker-queue barrier observes finishScan after cancellation, rather
        // than racing enumeration's final flush from the progress callback.
        let settled=expectation(description:"暂停扫描已退出 worker 队列")
        service.mutate({_ in},completion:{_ in settled.fulfill()})
        wait(for:[settled],timeout:5)
        let before=try db.statistics()
        XCTAssertGreaterThan(before.indexedContent,0,"旧 pending 应在目录扫描开始前先提取一小批")
        XCTAssertLessThanOrEqual(before.indexedContent,20,"单次正文预算应给目录扫描让出执行机会")
        XCTAssertNil(try db.roots().first?.lastScan)
        XCTAssertEqual(try db.search("old-unseen.bin").count,1,"中断扫描不能删除尚未枚举的历史记录")
        stateLock.lock()
        let firstStarts=firstExtractionStarts, kinds=extractedKinds, phaseMismatch=wrongPhase
        stateLock.unlock()
        XCTAssertEqual(firstStarts,0)
        XCTAssertEqual(kinds,Set(["txt","png","swift"]),"旧 pending 的文档、图片、代码应公平轮换")
        XCTAssertFalse(phaseMismatch)
        service.requestScan()
        XCTAssertEqual(try db.statistics().indexedContent,before.indexedContent)
        service.setPaused(false)
        wait(for:[finished],timeout:18)
        XCTAssertEqual(try db.statistics().indexedContent,96)
        XCTAssertEqual(try db.statistics().errors,0)
        XCTAssertEqual(try db.search("old-unseen.bin").count,0,"完整恢复扫描才能清理旧 generation")
        XCTAssertNotNil(try db.roots().first?.lastScan)
    }

    func testSlowSlicesYieldToRealScannerAndRotateAcrossRootsAndKinds() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-slices-\(UUID().uuidString)")
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
        var roots:[IndexedRoot]=[]
        for id in ["a","b"] {
            let folder=base.appendingPathComponent(id)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let root=IndexedRoot(id:id,path:folder.path);try db.saveRoot(root);roots.append(root)
            var records:[FileRecord]=[]
            for ext in ["txt","png","swift"] {
                for index in 0..<2 {
                    let name="pending-\(index).\(ext)",url=folder.appendingPathComponent("pending-\(index).\(ext)")
                    try Data("boundedcontent".utf8).write(to:url)
                    let signature=try FileSignature.read(url)
                    records.append(FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:ext,kind:FileKind.classify(extension:ext),size:signature.size,modified:signature.modified,inode:signature.inode))
                }
            }
            try db.upsertFiles(records,generation:1)
        }
        for index in 0..<1_200 {try Data().write(to:URL(fileURLWithPath:roots[0].path).appendingPathComponent("filler-\(index).bin"))}
        let stateLock=NSLock()
        var calls:[String]=[], startupCount:Int?, checkpoints:[Int]=[], lastCheckpoint=0
        // A deterministic monotonic clock models one long extraction without
        // sleeping or cancelling/retrying that file to satisfy a time slice.
        var clock:TimeInterval=0
        let service=IndexService(database:db,extractor:{url,cancelled in
            clock += 1
            stateLock.lock();calls.append("\(url.deletingLastPathComponent().lastPathComponent):\(url.pathExtension)");stateLock.unlock()
            return ExtractedContent(text:"boundedcontent")
        },contentClock:{clock})
        let finished=expectation(description:"两个根的限时小批完成")
        service.onProgress = { progress in
            stateLock.lock()
            if progress.phase == "正在建立文件目录" && progress.detail == "a" {
                if progress.processed == 0 && startupCount == nil {startupCount=calls.count}
                if progress.processed > lastCheckpoint {
                    lastCheckpoint=progress.processed;checkpoints.append(calls.count)
                }
            }
            stateLock.unlock()
            if progress.phase == "索引已更新" {finished.fulfill()}
        }
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        service.configure(prefs)
        wait(for:[finished],timeout:18)
        stateLock.lock();let startup=startupCount, batches=checkpoints, firstSix=Array(calls.prefix(6));stateLock.unlock()
        XCTAssertEqual(startup,1,"超时的第一份内容完成后应立即交还 scanner")
        XCTAssertEqual(Array(batches.prefix(4)),[1,2,3,4],"每个提交点只处理一份超出时间片的内容")
        XCTAssertEqual(Set(firstSix),Set(["a:txt","a:png","a:swift","b:txt","b:png","b:swift"]),"时间片不能重置类型或根的轮换游标")
        XCTAssertEqual(try db.statistics().indexedContent,12)
        XCTAssertEqual(try db.statistics().errors,0)
    }

    func testPauseStopAndRootMutationDuringSliceNeverCommitCancelledContent() throws {
        for mode in ["pause","stop","remove"] {
            let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-cancel-slice-\(UUID().uuidString)")
            let folder=base.appendingPathComponent("source")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
            let root=try VolumeIdentity.root(for:folder);try db.saveRoot(root)
            let url=folder.appendingPathComponent("pending.png")
            try Data("fixture".utf8).write(to:url)
            let signature=try FileSignature.read(url)
            let pending=FileRecord(rootID:root.id,relativePath:"pending.png",name:"pending.png",fileExtension:"png",kind:.image,size:signature.size,modified:signature.modified,inode:signature.inode)
            let historical=FileRecord(rootID:root.id,relativePath:"unseen.bin",name:"unseen.bin",fileExtension:"bin",kind:.other,size:0,modified:0,contentState:"skipped")
            try db.upsertFiles([pending,historical],generation:1)
            var interrupt:(()->Void)?
            let entered=expectation(description:"\(mode) 在内容提取内中断")
            let service=IndexService(database:db,extractor:{_,cancelled in
                interrupt?()
                XCTAssertTrue(cancelled(),"\(mode) 应传播到提取器的取消闭包")
                entered.fulfill()
                return ExtractedContent(text:"cancelledcontent")
            })
            interrupt = { [weak service] in
                switch mode {
                case "pause": service?.setPaused(true)
                case "stop": service?.stop()
                default: service?.mutate{try $0.removeRoot(id:root.id)}
                }
            }
            defer {service.stop();try? FileManager.default.removeItem(at:base)}
            var prefs=IndexingPreferences();prefs.autoAddExternal=false
            service.configure(prefs)
            wait(for:[entered],timeout:5)
            let settled=expectation(description:"\(mode) worker 已退出且 mutation 已执行")
            service.mutate({_ in},completion:{_ in settled.fulfill()})
            wait(for:[settled],timeout:5)
            XCTAssertEqual(try db.statistics().indexedContent,0)
            XCTAssertEqual(try db.statistics().errors,0)
            XCTAssertEqual(try db.statistics().files,mode == "remove" ? 0 : 2)
            XCTAssertEqual(try db.statistics().pending,mode == "remove" ? 0 : 1)
            XCTAssertEqual(try db.roots().count,mode == "remove" ? 0 : 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        }
    }

    func testRootGoingOfflineDuringStartupSliceRetainsPendingAndRestoresOnReconnect() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-slice-offline-\(UUID().uuidString)")
        let folder=base.appendingPathComponent("source"),away=base.appendingPathComponent("disconnected")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
        let root=try VolumeIdentity.root(for:folder);try db.saveRoot(root)
        let url=folder.appendingPathComponent("pending.txt")
        try Data("fixture".utf8).write(to:url)
        let signature=try FileSignature.read(url)
        let pending=FileRecord(rootID:root.id,relativePath:"pending.txt",name:"pending.txt",fileExtension:"txt",kind:.document,size:signature.size,modified:signature.modified,inode:signature.inode)
        let historical=FileRecord(rootID:root.id,relativePath:"unseen.bin",name:"unseen.bin",fileExtension:"bin",kind:.other,size:0,modified:0,contentState:"skipped")
        try db.upsertFiles([pending,historical],generation:1)
        var disconnect=true
        let service=IndexService(database:db,extractor:{_,_ in
            if disconnect {disconnect=false;try FileManager.default.moveItem(at:folder,to:away)}
            return ExtractedContent(text:"reconnectedcontent")
        })
        let idle=expectation(description:"离线根结束本轮处理")
        let stateLock=NSLock();var updates=0
        service.onProgress = { progress in
            if progress.phase == "索引已更新" {
                stateLock.lock();updates += 1;let first=updates == 1;stateLock.unlock()
                if first {idle.fulfill()}
            }
        }
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        service.configure(prefs)
        wait(for:[idle],timeout:5)
        XCTAssertEqual(try db.statistics().indexedContent,0)
        XCTAssertEqual(try db.statistics().pending,1)
        XCTAssertEqual(try db.statistics().errors,0)
        XCTAssertEqual(try db.statistics().files,2)
        XCTAssertFalse(try XCTUnwrap(db.roots().first).isOnline)
        XCTAssertNil(try db.roots().first?.lastScan)
        try FileManager.default.moveItem(at:away,to:folder)
        service.requestScan()
        // Content drains before reconciliation. Wait for the stale metadata
        // removal too, rather than racing the scanner after content commits.
        eventually{(try? db.statistics().indexedContent)==1 && (try? db.statistics().files)==1}
        XCTAssertTrue(try XCTUnwrap(db.search("reconnectedcontent").first).root.isOnline)
        XCTAssertEqual(try db.statistics().files,1)
    }

    func eventually(_ condition:()->Bool,timeout:TimeInterval=18,file:StaticString=#filePath,line:UInt=#line) {
        let deadline=Date().addingTimeInterval(timeout)
        while Date()<deadline {if condition(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
        XCTAssertTrue(condition(),"未在期限内完成索引",file:file,line:line)
    }
    func testRefreshStormStillExtractsCodeAndImagesAndPublishesBatches() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-storm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let dbURL=base.appendingPathComponent("index.sqlite")
        let db=try SearchDatabase(url:dbURL)
        // This regression tests scheduling; Vision behavior is covered by
        // ExtractionTests and must not determine the scheduler's deadline.
        let service=IndexService(database:db,ignoredPaths:[dbURL.path],extractor:{url,_ in
            ExtractedContent(text:url.pathExtension == "swift" ? try String(contentsOf:url) : "fixture image")
        })
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        let root=try VolumeIdentity.root(for:base);try db.saveRoot(root)
        for index in 0..<301 { try Data().write(to:base.appendingPathComponent("fixture-\(index).bin")) }
        try "stormcodecontent".write(to:base.appendingPathComponent("source.swift"),atomically:true,encoding:.utf8)
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:256,bitsPerPixel:32))
        memset(try XCTUnwrap(bitmap.bitmapData),255,bitmap.bytesPerRow*bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:base.appendingPathComponent("image.png"))
        let stateLock=NSLock()
        var publishedWhileScanning=false
        var scanStarts=0
        var lastPhase=""
        service.onProgress = { [weak service] progress in
            stateLock.lock()
            lastPhase=progress.phase
            if progress.phase == "正在建立文件目录" && progress.processed == 0 {scanStarts += 1}
            stateLock.unlock()
            // Requests during both enumeration and extraction used to starve OCR.
            service?.requestScan()
        }
        service.onChange = {
            let count=(try? db.statistics().files) ?? 0
            stateLock.lock()
            if lastPhase == "正在建立文件目录" && count == 300 {publishedWhileScanning=true}
            stateLock.unlock()
        }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        XCTAssertTrue(prefs.includeHidden);XCTAssertFalse(prefs.excludeDevelopmentCaches)
        service.configure(prefs)
        eventually { (try? db.statistics().indexedContent) == 2 }
        service.setPaused(true)
        XCTAssertEqual(try db.search("stormcodecontent").count,1)
        XCTAssertEqual(try db.statistics().files,303)
        XCTAssertEqual(try db.statistics().errors,0)
        stateLock.lock();let published=publishedWhileScanning;let starts=scanStarts;stateLock.unlock()
        XCTAssertTrue(published,"首批提交后应能刷新搜索结果")
        XCTAssertEqual(starts,1,"忙碌期的扫描请求应合并并限频")
    }
    func testChangingHeadFileDoesNotBlockStableFilesAndRetriesAfterRescan() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-changing-\(UUID().uuidString)")
        let folder=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
        let root=try VolumeIdentity.root(for:folder);try db.saveRoot(root)
        var seeded:[FileRecord]=[]
        for name in ["changing.txt"]+(0..<25).map({"stable-\($0).txt"}) {
            let url=folder.appendingPathComponent(name)
            try "initial".write(to:url,atomically:true,encoding:.utf8)
            let signature=try FileSignature.read(url)
            seeded.append(FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:"txt",kind:.document,size:signature.size,modified:signature.modified,inode:signature.inode))
        }
        // Deterministic queue order, including stable work beyond the first batch.
        try db.upsertFiles(seeded,generation:1)
        let stateLock=NSLock();var changing=true;var attempts=0
        let service=IndexService(database:db,extractor:{url,cancelled in
            if url.lastPathComponent == "changing.txt" {
                stateLock.lock();attempts += 1;let rewrite=changing;stateLock.unlock()
                if rewrite {try "new changing version".write(to:url,atomically:true,encoding:.utf8)}
                return ExtractedContent(text:"recoveredchangingcontent")
            }
            return ExtractedContent(text:"stablequeuecontent")
        })
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs)
        eventually({(try? db.statistics().indexedContent)==25},timeout:5)
        XCTAssertEqual(try db.search("stablequeuecontent").count,25)
        let active=try XCTUnwrap(db.search("changing.txt").first?.file)
        XCTAssertEqual(active.contentState,"error")
        XCTAssertTrue(active.contentError?.contains("正在修改") == true)
        XCTAssertEqual(try db.search("recoveredchangingcontent").count,0)
        stateLock.lock();let firstAttempts=attempts;changing=false;stateLock.unlock()
        // Startup sees the seeded signature, then enumeration discovers its
        // changed signature. Each version leaves pending after one attempt.
        XCTAssertEqual(firstAttempts,2,"启动与首轮扫描发现的两个版本应各尝试一次，不能在 drain 内无限重试")
        service.requestScan()
        eventually {(try? db.search("recoveredchangingcontent").count)==1}
        XCTAssertEqual(try db.statistics().indexedContent,26)
    }
    func testCodeUsesDocumentPreferencesAndIgnoresSelfDatabaseEvents() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-codeprefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let dbURL=base.appendingPathComponent("index.sqlite")
        let db=try SearchDatabase(url:dbURL)
        let service=IndexService(database:db,ignoredPaths:[dbURL.path])
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        try "documentprefcontent".write(to:base.appendingPathComponent("source.py"),atomically:true,encoding:.utf8)
        let root=try VolumeIdentity.root(for:base);try db.saveRoot(root)
        let stateLock=NSLock();var scanStarts=0
        service.onProgress = { progress in
            if progress.phase == "正在建立文件目录" && progress.processed == 0 {stateLock.lock();scanStarts += 1;stateLock.unlock()}
        }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;prefs.documents=false
        service.configure(prefs)
        eventually {(try? db.statistics().pending)==1}
        XCTAssertEqual(try db.search("documentprefcontent").count,0)
        // Let creation events for the fixture directory settle before measuring
        // explicit WAL writes (FSEvents can deliver creation events after setup).
        RunLoop.current.run(until:Date().addingTimeInterval(13))
        stateLock.lock();let starts=scanStarts;stateLock.unlock()
        for _ in 0..<3 {try db.saveRoot(root)}
        RunLoop.current.run(until:Date().addingTimeInterval(13))
        stateLock.lock();let afterWrites=scanStarts;stateLock.unlock()
        XCTAssertEqual(afterWrites,starts,"数据库 WAL 写入不应触发额外扫描")
        XCTAssertEqual(try db.statistics().files,1)
        prefs.documents=true;service.configure(prefs)
        eventually {(try? db.search("documentprefcontent").count)==1}
    }
    func testAutomaticUpdatesPauseResumeAndRootRemoval() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-service-\(UUID().uuidString)")
        let folder=base.appendingPathComponent("资料")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
        let service=IndexService(database:db)
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        let root=try VolumeIdentity.root(for:folder);try db.saveRoot(root)
        let file=folder.appendingPathComponent("课堂.txt")
        try "初始正文".write(to:file,atomically:true,encoding:.utf8)
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        service.configure(prefs);service.start()
        eventually{(try? db.search("初始正文").count)==1}
        // Only the watcher can request this update; no direct requestScan here.
        try "更新后的正文".write(to:file,atomically:true,encoding:.utf8)
        eventually{(try? db.search("更新后的正文").count)==1}
        XCTAssertEqual(try db.search("初始正文").count,0)
        service.setPaused(true)
        let later=folder.appendingPathComponent("暂停期间.txt")
        try "恢复后可搜".write(to:later,atomically:true,encoding:.utf8)
        service.requestScan()
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        XCTAssertEqual(try db.search("恢复后可搜").count,0)
        service.setPaused(false)
        eventually{(try? db.search("恢复后可搜").count)==1}
        try FileManager.default.removeItem(at:file)
        eventually{(try? db.search("更新后的正文").count)==0}
        service.mutate{try $0.removeRoot(id:root.id)}
        eventually{(try? db.roots().count)==0 && (try? db.statistics().files)==0}
        XCTAssertTrue(FileManager.default.fileExists(atPath:later.path))
    }
}

extension IndexServiceTests {
    private func incrementalFixture(_ names: [String] = ["changed.txt","stable.txt"]) throws -> (URL, URL, SearchDatabase, IndexedRoot) {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("miji-incremental-\(UUID().uuidString)")
        let folder=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let db=try SearchDatabase(url:base.appendingPathComponent("index.sqlite"))
        let root=try VolumeIdentity.root(for:folder)
        for name in names {
            let url=folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data("original".utf8).write(to:url)
        }
        _=try FileScanner(database:db).scan(root:root)
        var state=IncrementalIndexState()
        state.roots[root.id] = .init(path:root.path,cursor:FileWatcher.currentEventID,pending:[])
        try state.write(db.url.appendingPathExtension("incremental.json"))
        return (base,folder,db,try XCTUnwrap(db.roots().first))
    }
    private func finishFixtureContent(_ db: SearchDatabase, _ root: IndexedRoot) throws {
        for file in try db.pendingFiles(rootID:root.id) { _=try db.completeContent(file:file,content:ExtractedContent(text:"original")) }
    }
    private func settle(_ service: IndexService) {
        let done=expectation(description:"worker 队列已排空")
        service.mutate({_ in},completion:{_ in done.fulfill()})
        wait(for:[done],timeout:5)
    }
    func testOrdinaryEventsScanOnlyChangedPathAndDoNotReextractStableFiles() throws {
        let (base,folder,db,root)=try incrementalFixture(["a/changed.txt","b/stable.txt"])
        try finishFixtureContent(db,root)
        let stable=try XCTUnwrap(db.search("stable.txt").first?.file)
        var extracted:[String]=[],changes:[IndexChange]=[]
        let service=IndexService(database:db,extractor:{url,_ in extracted.append(url.lastPathComponent);return ExtractedContent(text:try String(contentsOf:url))},watchEvents:false)
        defer { service.stop();try? FileManager.default.removeItem(at:base) }
        service.onIndexChange = { changes.append($0) }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs)
        settle(service)
        let changed=folder.appendingPathComponent("a/changed.txt")
        try Data("updated unique content".utf8).write(to:changed)
        service.receiveEvents([FileChangeEvent(path:changed.path)])
        eventually { (try? db.search("updated unique content").count) == 1 }
        service.setPaused(true);settle(service)
        XCTAssertEqual(extracted,["changed.txt"])
        XCTAssertFalse(changes.contains(where:{$0.fullRescan}))
        XCTAssertTrue(changes.contains(where:{$0.relativePaths == ["a/changed.txt"]}))
        XCTAssertEqual(try db.search("stable.txt").first?.file.id,stable.id)
        XCTAssertEqual(try db.search("stable.txt").first?.file.contentState,"done")
        XCTAssertEqual(try db.search("stable.txt").first?.file.modified,stable.modified)
    }
    func testDroppedEventsRecoverWholeRootAndRetainCompletedContent() throws {
        let (base,folder,db,root)=try incrementalFixture()
        try finishFixtureContent(db,root)
        var calls=0,fullScans=0
        let service=IndexService(database:db,extractor:{_,_ in calls += 1;return ExtractedContent(text:"new file content")},watchEvents:false)
        defer { service.stop();try? FileManager.default.removeItem(at:base) }
        service.onIndexChange = { if $0.fullRescan { fullScans += 1 } }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs);settle(service)
        try FileManager.default.removeItem(at:folder.appendingPathComponent("changed.txt"))
        try Data("new".utf8).write(to:folder.appendingPathComponent("new.txt"))
        service.receiveEvents([FileChangeEvent(path:folder.path,flags:FileWatcher.droppedEventFlag)])
        eventually { (try? db.search("new file content").count) == 1 && (try? db.search("changed.txt").isEmpty) == true }
        service.setPaused(true);settle(service)
        XCTAssertGreaterThan(fullScans,0)
        XCTAssertEqual(calls,1)
        XCTAssertEqual(try db.search("stable.txt").first?.file.contentState,"done")
    }
    func testPauseSleepAndUserActivityRetainEventsAndResumeWithoutFullScan() throws {
        for mode in ["pause","sleep","active"] {
            let (base,folder,db,root)=try incrementalFixture()
            try finishFixtureContent(db,root)
            let service=IndexService(database:db,extractor:{_,_ in ExtractedContent(text:"resumed content")},watchEvents:false)
            defer { service.stop();try? FileManager.default.removeItem(at:base) }
            let flag:(Bool)->Void = { value in
                switch mode { case "pause":service.setPaused(value);case "sleep":service.setSystemSleeping(value);default:service.setUserActive(value) }
            }
            var fullScans=0
            service.onIndexChange = { if $0.fullRescan { fullScans += 1 } }
            var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs);settle(service)
            flag(true)
            let file=folder.appendingPathComponent("changed.txt")
            try Data("changed while suspended".utf8).write(to:file)
            service.receiveEvents([FileChangeEvent(path:file.path)])
            XCTAssertEqual(IncrementalIndexState.read(db.url.appendingPathExtension("incremental.json")).roots[root.id]?.pending,["changed.txt"])
            XCTAssertEqual(try db.search("resumed content").count,0)
            flag(false)
            eventually { (try? db.search("resumed content").count) == 1 }
            service.setPaused(true);settle(service)
            XCTAssertEqual(fullScans,0,mode)
        }
    }
    func testDurableInboxSurvivesRestartAndStartupContinuesPendingWithoutRootScan() throws {
        let (base,folder,db,root)=try incrementalFixture()
        var prefs=IndexingPreferences();prefs.autoAddExternal=false
        let first=IndexService(database:db,extractor:{_,_ in XCTFail("暂停时不可提取");return ExtractedContent()},watchEvents:false)
        first.setPaused(true);first.configure(prefs)
        let file=folder.appendingPathComponent("changed.txt")
        try Data("after restart".utf8).write(to:file)
        first.receiveEvents([FileChangeEvent(path:file.path)])
        first.stop()
        var fullScans=0,attempts:[String:Int]=[:]
        let second=IndexService(database:db,extractor:{url,_ in attempts[url.lastPathComponent,default:0] += 1;return ExtractedContent(text:try String(contentsOf:url))},watchEvents:false)
        defer { second.stop();try? FileManager.default.removeItem(at:base) }
        second.onIndexChange = { if $0.fullRescan { fullScans += 1 } }
        second.configure(prefs)
        eventually { (try? db.statistics().indexedContent) == 2 && (try? db.search("after restart").count) == 1 }
        second.setPaused(true);settle(second)
        XCTAssertEqual(fullScans,0)
        XCTAssertEqual(attempts["stable.txt"],1)
        XCTAssertTrue(IncrementalIndexState.read(db.url.appendingPathExtension("incremental.json")).roots[root.id]?.pending.isEmpty == true)
    }
    func testEventsArrivingDuringScanAreNotAcknowledgedEarly() throws {
        let (base,folder,db,root)=try incrementalFixture((0..<301).map {"tree/file-\($0).txt"})
        try finishFixtureContent(db,root)
        let service=IndexService(database:db,extractor:{_,_ in ExtractedContent(text:"late event content")},watchEvents:false)
        defer { service.stop();try? FileManager.default.removeItem(at:base) }
        var sent=false
        service.onIndexChange = { change in
            if !sent && change.relativePaths == ["tree"] {
                sent=true
                let file=folder.appendingPathComponent("late.txt")
                try! Data("late".utf8).write(to:file)
                service.receiveEvents([FileChangeEvent(path:file.path)])
            }
        }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs);settle(service)
        service.receiveEvents([FileChangeEvent(path:folder.appendingPathComponent("tree").path)])
        eventually { (try? db.search("late.txt").count) == 1 }
        service.setPaused(true);settle(service)
        XCTAssertTrue(sent)
    }
    func testUserActivityDuringExtractionCommitsCurrentFileThenYields() throws {
        let (base,_,db,_)=try incrementalFixture()
        var service:IndexService!
        var calls=0
        let first=expectation(description:"当前提取让出资源")
        service=IndexService(database:db,extractor:{_,_ in calls += 1;service.setUserActive(true);first.fulfill();return ExtractedContent(text:"finished current file")},watchEvents:false)
        defer { service.stop();try? FileManager.default.removeItem(at:base) }
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs)
        wait(for:[first],timeout:5);settle(service)
        XCTAssertEqual(calls,1)
        XCTAssertEqual(try db.statistics().indexedContent,1)
        XCTAssertEqual(try db.statistics().pending,1)
        service.setPaused(true)
    }
}

extension IndexServiceTests {
    func testInterruptedInFlightScopesSurviveCrashStyleRestart() throws {
        let (base,_,db,root)=try incrementalFixture()
        var journal=IncrementalIndexState.read(db.url.appendingPathExtension("incremental.json"))
        journal.roots[root.id]?.inFlight=["changed.txt"]
        journal.roots[root.id]?.pending=["stable.txt"]
        try journal.write(db.url.appendingPathExtension("incremental.json"))
        let service=IndexService(database:db,extractor:{_,_ in ExtractedContent(text:"recovered pending")},watchEvents:false)
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        var full=false
        service.onIndexChange = {full = full || $0.fullRescan}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs)
        eventually {(try? db.statistics().indexedContent)==2}
        service.setPaused(true);settle(service)
        let after=IncrementalIndexState.read(db.url.appendingPathExtension("incremental.json"))
        XCTAssertFalse(full)
        XCTAssertTrue(after.roots[root.id]?.pending.isEmpty == true)
        XCTAssertTrue(after.roots[root.id]?.inFlight.isEmpty == true)
    }
    func testRestartReplaysChangesThatOccurredWhileWatcherWasAbsent() throws {
        let (base,folder,db,root)=try incrementalFixture()
        try finishFixtureContent(db,root)
        // Let the fixture's creation reach the filesystem journal, then retain
        // an ID captured before the changes made with no watcher running.
        RunLoop.current.run(until:Date().addingTimeInterval(2))
        var journal=IncrementalIndexState.read(db.url.appendingPathExtension("incremental.json"))
        journal.roots[root.id]?.cursor=FileWatcher.currentEventID
        try journal.write(db.url.appendingPathExtension("incremental.json"))
        try Data("history replay content".utf8).write(to:folder.appendingPathComponent("changed.txt"))
        try FileManager.default.removeItem(at:folder.appendingPathComponent("stable.txt"))
        RunLoop.current.run(until:Date().addingTimeInterval(2))
        let service=IndexService(database:db,extractor:{url,_ in ExtractedContent(text:try String(contentsOf:url))})
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs)
        eventually {(try? db.search("history replay content").count)==1 && (try? db.search("stable.txt").isEmpty)==true}
        service.setPaused(true);settle(service)
        XCTAssertEqual(try db.statistics().indexedContent,1)
    }
}

extension IndexServiceTests {
    func testEventBatchUsesPreviousCursorForEveryPathEvenWhenIDsAreReordered() throws {
        let (base,folder,db,root)=try incrementalFixture()
        let url=db.url.appendingPathExtension("incremental.json")
        var state=IncrementalIndexState.read(url)
        state.roots[root.id]?.cursor=0
        try state.write(url)
        let service=IndexService(database:db,extractor:{_,_ in ExtractedContent()},watchEvents:false)
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        service.setUserActive(true)
        service.receiveEvents([
            FileChangeEvent(path:folder.appendingPathComponent("changed.txt").path,id:3),
            FileChangeEvent(path:folder.appendingPathComponent("stable.txt").path,id:2)
        ])
        let after=IncrementalIndexState.read(url)
        XCTAssertEqual(Set(after.roots[root.id]?.pending ?? []),Set(["changed.txt","stable.txt"]))
        XCTAssertEqual(after.roots[root.id]?.cursor,3)
        service.receiveEvents([FileChangeEvent(path:folder.appendingPathComponent("duplicate.txt").path,id:2)])
        XCTAssertFalse(IncrementalIndexState.read(url).roots[root.id]?.pending.contains("duplicate.txt") == true)
    }
}

extension IndexServiceTests {
    func testReenabledRootReconcilesUnwatchedChangesAndRemovalNotifiesNameEngine() throws {
        let (base,folder,db,root)=try incrementalFixture()
        try finishFixtureContent(db,root)
        var changes:[IndexChange]=[]
        let service=IndexService(database:db,extractor:{url,_ in ExtractedContent(text:try String(contentsOf:url))},watchEvents:false)
        defer {service.stop();try? FileManager.default.removeItem(at:base)}
        service.onIndexChange = {changes.append($0)}
        var prefs=IndexingPreferences();prefs.autoAddExternal=false;service.configure(prefs);settle(service)
        var disabled=root;disabled.enabled=false
        service.mutate {try $0.saveRoot(disabled)}
        settle(service)
        try Data("changed while root disabled".utf8).write(to:folder.appendingPathComponent("changed.txt"))
        service.requestIncrementalUpdate();settle(service)
        XCTAssertEqual(try db.search("changed while root disabled").count,0)
        service.mutate {try $0.saveRoot(root)}
        eventually {(try? db.search("changed while root disabled").count)==1}
        service.setPaused(true);settle(service)
        XCTAssertEqual(try db.search("stable.txt").first?.file.contentState,"done")
        let count=changes.count
        service.mutate {try $0.removeRoot(id:root.id)}
        settle(service)
        XCTAssertGreaterThan(changes.count,count)
        XCTAssertEqual(changes.last?.rootID,root.id)
        XCTAssertEqual(changes.last?.fullRescan,true)
        XCTAssertEqual(try db.statistics().files,0)
    }
}
