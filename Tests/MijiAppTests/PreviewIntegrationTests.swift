import AppKit
import PDFKit
import XCTest
import MijiCore
@testable import MijiApp

final class PreviewIntegrationTests: XCTestCase {
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
