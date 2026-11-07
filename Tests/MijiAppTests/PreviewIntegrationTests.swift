import AppKit
import PDFKit
import XCTest
import MijiCore
@testable import MijiApp

final class PreviewIntegrationTests: XCTestCase {
    @MainActor
    func testReadableTextWithoutIndexedBodyKeepsOriginalPreview() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldDir=getenv("MIJI_DATA_DIR").map{String(cString:$0)},oldAuto=getenv("MIJI_NO_AUTOSTART").map{String(cString:$0)}
        setenv("MIJI_DATA_DIR",directory.path,1);setenv("MIJI_NO_AUTOSTART","1",1)
        defer {
            if let oldDir {setenv("MIJI_DATA_DIR",oldDir,1)}else{unsetenv("MIJI_DATA_DIR")}
            if let oldAuto {setenv("MIJI_NO_AUTOSTART",oldAuto,1)}else{unsetenv("MIJI_NO_AUTOSTART")}
            try? FileManager.default.removeItem(at:directory)
        }
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=IndexedRoot(id:"r",path:directory.path);try db.saveRoot(root)
        for ext in ["txt","md"] {
            for failed in [false,true] {
                let name="unindexed-\(failed).\(ext)",url=directory.appendingPathComponent("unindexed-\(failed).\(ext)")
                let original=Data("# Local original\nNot yet in the content index.".utf8)
                try original.write(to:url)
                let signature=try FileSignature.read(url)
                try db.upsertFiles([FileRecord(rootID:root.id,relativePath:name,name:name,fileExtension:ext,kind:.document,size:signature.size,modified:signature.modified,inode:signature.inode)],generation:1)
                let pending=try XCTUnwrap(db.pendingFiles(rootID:root.id).first(where:{$0.name==name}))
                if failed {try db.failContent(file:pending,message:"fixture extraction failed")}
                let hit=try XCTUnwrap(db.search(name,options:SearchOptions(scope:.name)).first)
                let state=hit.file.contentState
                let model=AppModel(searchExecutor:{_,_,_,_ in [hit]})
                model.setSearchVisible(true);model.query=name
                for _ in 0..<100 where model.previewLocalURL==nil {try await Task.sleep(nanoseconds:10_000_000)}
                XCTAssertTrue(model.previewVisible);XCTAssertFalse(model.previewLoading)
                XCTAssertEqual(model.previewLocalURL,url);XCTAssertTrue(model.previewText.isEmpty)
                XCTAssertTrue(SearchPreviewPolicy.usesSystemPreview(hit,hasIndexedText:!model.previewText.isEmpty))
                XCTAssertFalse(SearchPreviewPolicy.usesSystemPreview(hit,hasIndexedText:true),"Ready indexed text keeps the dedicated reader")
                XCTAssertNil(try db.storedContent(fileID:hit.id))
                XCTAssertEqual(try db.search(name,options:SearchOptions(scope:.name)).first?.file.contentState,state)
                XCTAssertEqual(try Data(contentsOf:url),original)
                model.setSearchVisible(false);model.service?.stop()
            }
        }
    }

    @MainActor
    func testOfflineTextSurvivesAndExplicitHideCancelsPendingPreview() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldDir=getenv("MIJI_DATA_DIR").map{String(cString:$0)},oldAuto=getenv("MIJI_NO_AUTOSTART").map{String(cString:$0)}
        setenv("MIJI_DATA_DIR",directory.path,1);setenv("MIJI_NO_AUTOSTART","1",1)
        defer {
            if let oldDir {setenv("MIJI_DATA_DIR",oldDir,1)}else{unsetenv("MIJI_DATA_DIR")}
            if let oldAuto {setenv("MIJI_NO_AUTOSTART",oldAuto,1)}else{unsetenv("MIJI_NO_AUTOSTART")}
            try? FileManager.default.removeItem(at:directory)
        }
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=IndexedRoot(id:"r",path:"/missing-preview-disk",isOnline:false)
        try db.saveRoot(root)
        try db.upsertFiles([FileRecord(rootID:"r",relativePath:"needle.swift",name:"needle.swift",fileExtension:"swift",kind:.code,size:1,modified:1)],generation:1)
        let record=try XCTUnwrap(db.pendingFiles(rootID:"r").first)
        XCTAssertTrue(try db.completeContent(file:record,content:ExtractedContent(text:"first\nneedle\nlast")))
        let hit=SearchHit(file:record,root:root)
        let model=AppModel(searchExecutor:{_,_,_,_ in [hit]});defer{model.service?.stop()}
        model.setSearchVisible(true);model.query="needle"
        for _ in 0..<100 where model.previewText.isEmpty {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(model.previewText.contains("needle"));XCTAssertNil(model.previewLocalURL)
        let width=model.panelWidth,height=model.panelHeight
        XCTAssertTrue(model.previewVisible);XCTAssertEqual(model.previewLine,2)
        model.previewMode = .hidden
        XCTAssertTrue(model.previewText.isEmpty)
        model.previewMode = .shown
        model.previewMode = .hidden
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertTrue(model.previewText.isEmpty);XCTAssertFalse(model.previewLoading)
        model.previewMode = .automatic
        for _ in 0..<100 where model.previewText.isEmpty {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(model.previewText.contains("needle"))
        XCTAssertEqual(model.panelWidth,width);XCTAssertEqual(model.panelHeight,height)
        model.setSearchVisible(false)
    }

    @MainActor
    func testSameSelectionKeepsLoadedPreviewAndHideReleasesIt() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldDir=getenv("MIJI_DATA_DIR").map{String(cString:$0)},oldAuto=getenv("MIJI_NO_AUTOSTART").map{String(cString:$0)}
        setenv("MIJI_DATA_DIR",directory.path,1);setenv("MIJI_NO_AUTOSTART","1",1)
        defer {
            if let oldDir {setenv("MIJI_DATA_DIR",oldDir,1)}else{unsetenv("MIJI_DATA_DIR")}
            if let oldAuto {setenv("MIJI_NO_AUTOSTART",oldAuto,1)}else{unsetenv("MIJI_NO_AUTOSTART")}
            try? FileManager.default.removeItem(at:directory)
        }
        let db=try SearchDatabase(url:directory.appendingPathComponent("index.sqlite"))
        let root=IndexedRoot(id:"r",path:directory.path);try db.saveRoot(root)
        let file=directory.appendingPathComponent("needle.swift")
        try Data("first\nneedle\nlast".utf8).write(to:file)
        let signature=try FileSignature.read(file)
        try db.upsertFiles([FileRecord(rootID:"r",relativePath:file.lastPathComponent,name:file.lastPathComponent,fileExtension:"swift",kind:.code,size:signature.size,modified:signature.modified,inode:signature.inode)],generation:1)
        let record=try XCTUnwrap(db.pendingFiles(rootID:"r").first)
        XCTAssertTrue(try db.completeContent(file:record,content:ExtractedContent(text:"first\nneedle\nlast")))
        let model=AppModel();defer{model.service?.stop()}
        model.setSearchVisible(true);model.query="needle"
        for _ in 0..<200 where model.previewLine==nil {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.previewLine,2)
        let loaded=model.previewText
        model.loadPreview()
        XCTAssertFalse(model.previewLoading,"同一请求不能销毁正在显示的预览")
        XCTAssertEqual(model.previewText,loaded)
        let pasteboard=NSPasteboard.withUniqueName();defer{pasteboard.releaseGlobally()}
        model.copySelectedFile(to:pasteboard)
        let copied=pasteboard.readObjects(forClasses:[NSURL.self]) as? [URL]
        XCTAssertEqual(copied,[file])
        model.setSearchVisible(false)
        XCTAssertTrue(model.previewText.isEmpty);XCTAssertNil(model.previewLocalURL);XCTAssertNil(model.previewPDF)
        XCTAssertFalse(model.searchPresented)
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertTrue(model.previewText.isEmpty,"取消的回调不能恢复隐藏预览")
        try Data("changed before indexing".utf8).write(to:file)
        model.setSearchVisible(true)
        for _ in 0..<100 where model.previewWarning==nil {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNil(model.previewLine,"旧正文的行号不能用来打开已变化的文件")
        XCTAssertTrue(model.previewWarning?.contains("文件已变化")==true)
        model.setSearchVisible(false)
    }
    @MainActor
    func testCopyAndNavigationBelongToEmbeddedPDF() {
        let pdf=PDFView(),child=NSView();pdf.addSubview(child)
        func key(_ code:UInt16,_ flags:NSEvent.ModifierFlags=[])->NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
        }
        XCTAssertNil(SearchKeyAction.action(for:key(8,.command),firstResponder:child))
        XCTAssertNil(SearchKeyAction.action(for:key(125),firstResponder:child))
        XCTAssertEqual(SearchKeyAction.action(for:key(8,.command),firstResponder:NSView()),.copyFile)
        let editor=NSTextView();editor.string="query"
        XCTAssertNil(SearchKeyAction.action(for:key(8,.command),firstResponder:editor))
        XCTAssertEqual(SearchKeyAction.action(for:key(8,[.command,.shift]),firstResponder:editor),.copyPath)
    }
    func testEditorLineURLPreservesSpecialCharactersAsPath() throws {
        let file=URL(fileURLWithPath:"/tmp/中文 #?%: name.swift")
        let url=try XCTUnwrap(CodeFileOpener.locationURL(file:file,line:42,bundleID:"com.microsoft.VSCode"))
        XCTAssertNil(url.query);XCTAssertNil(url.fragment)
        XCTAssertEqual(url.path,file.path+":42:1")
        XCTAssertNil(CodeFileOpener.locationURL(file:file,line:42,bundleID:"unknown.editor"))
    }
}
