import SwiftUI
import AppKit
import Carbon
import QuickLookUI
import Combine
import MijiCore

@main
@MainActor
enum MijiEntry {
    static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate=AppDelegate()
        app.delegate=delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
private final class SearchPanel:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {true}
}
@MainActor
final class AppDelegate:NSObject,NSApplicationDelegate,@preconcurrency QLPreviewPanelDataSource {
    static weak var shared:AppDelegate?
    let model=AppModel()
    private var searchPanel:NSPanel!
    private var settingsWindow:NSWindow?
    private var pdfWindow:NSWindow?
    private var statusItem:NSStatusItem?
    private var hotKey:EventHotKeyRef?
    private var handler:EventHandlerRef?
    private var monitor:Any?
    private var previewURL:NSURL?
    private var subscriptions=Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification:Notification) {
        Self.shared=self
        NSApp.setActivationPolicy(.accessory)
        let panel=SearchPanel(contentRect:NSRect(x:0,y:0,width:800,height:100),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.title="觅迹";panel.level = .floating;panel.isOpaque=false;panel.backgroundColor = .clear
        panel.hasShadow=true;panel.isMovableByWindowBackground=true;panel.hidesOnDeactivate=false
        panel.isReleasedWhenClosed=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView=NSHostingView(rootView:MainView(model:model))
        searchPanel=panel
        model.openMain={ [weak self] in self?.showSearch() }
        Publishers.CombineLatest4(model.$query,model.$hits,model.$previewEnabled,model.$gridEnabled).sink{[weak self] _ in
            // @Published emits before assignment; size using the completed model state.
            DispatchQueue.main.async {self?.resizeSearchPanel()}
        }.store(in:&subscriptions)
        model.$showSettings.filter{$0}.sink{[weak self] _ in DispatchQueue.main.async{self?.openSettings();self?.model.showSettings=false}}.store(in:&subscriptions)
        NotificationCenter.default.publisher(for:NSWindow.willCloseNotification).sink{[weak self] notification in
            guard let self,let window=notification.object as? NSWindow,window===self.pdfWindow else{return}
            window.contentView=nil;self.pdfWindow=nil
        }.store(in:&subscriptions)
        setupMenus()
        var event=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{_,_,_ in DispatchQueue.main.async{AppDelegate.shared?.toggleSearch()};return noErr},1,&event,nil,&handler)
        let keyID=EventHotKeyID(signature:OSType(0x4d494a49),id:1)
        let status=RegisterEventHotKey(UInt32(kVK_Space),UInt32(controlKey | optionKey),keyID,GetApplicationEventTarget(),0,&hotKey)
        NSLog("Miji launched; hotkey status %d",status)
        if status != noErr {model.message="全局快捷键 ⌃⌥Space 已被占用。仍可从菜单栏打开觅迹。"}
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
            guard let self,NSApp.keyWindow===self.searchPanel else{return event}
            switch SearchKeyAction.action(for:event,firstResponder:self.searchPanel.firstResponder) {
            case .focusSearch: self.model.focusSearch=UUID()
            case .reveal: self.model.revealSelected()
            case .preview: self.preview()
            case .copyPath: self.model.copySelectedPath()
            case .copyFile: self.model.copySelectedFile()
            case .moveLeft: if self.model.gridEnabled {self.model.moveSelection(-1)}else{return event}
            case .moveRight: if self.model.gridEnabled {self.model.moveSelection(1)}else{return event}
            case .hide: self.hideSearch()
            case .settings: self.openSettings()
            case .moveDown: self.model.moveSelection(self.model.gridEnabled ? self.model.gridColumns : 1)
            case .moveUp: self.model.moveSelection(self.model.gridEnabled ? -self.model.gridColumns : -1)
            case .open: self.model.openSelected()
            case nil: return event
            }
            return nil
        }
        DispatchQueue.main.async{self.showSearch()}
    }
    private func resizeSearchPanel() {
        guard let panel=searchPanel else{return}
        let old=panel.frame, width=model.panelWidth, height=model.panelHeight
        let screen=(panel.screen ?? NSScreen.main)?.visibleFrame ?? old
        let x=min(max(screen.minX,old.midX-width/2),max(screen.minX,screen.maxX-width))
        let y=min(max(screen.minY,old.maxY-height),max(screen.minY,screen.maxY-height))
        panel.setFrame(NSRect(x:x,y:y,width:width,height:height),display:true)
    }
    func showPDFMatch() {
        guard let document=model.previewPDF,let page=model.previewPage else{return}
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:700),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title=model.selected?.file.name ?? "PDF 预览"
        window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:PDFDocumentPreview(document:document,page:page,terms:PreviewResolver.terms(in:model.query)))
        hideSearch()
        pdfWindow?.close();pdfWindow=window
        window.center();window.makeKeyAndOrderFront(nil)
    }
    private func setupMenus() {
        let main=NSMenu();let appItem=NSMenuItem();let appMenu=NSMenu()
        let settings=NSMenuItem(title:"索引与设置…",action:#selector(openSettings),keyEquivalent:",");settings.target=self;appMenu.addItem(settings)
        appMenu.addItem(.separator());appMenu.addItem(NSMenuItem(title:"退出觅迹",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        appItem.submenu=appMenu;main.addItem(appItem)
        let editItem=NSMenuItem(title:"编辑",action:nil,keyEquivalent:"");let edit=NSMenu(title:"编辑")
        for (title,selector,key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {edit.addItem(NSMenuItem(title:title,action:NSSelectorFromString(selector),keyEquivalent:key))}
        editItem.submenu=edit;main.addItem(editItem);NSApp.mainMenu=main
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem?.button?.image=NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:"觅迹")
        let menu=NSMenu()
        let open=NSMenuItem(title:"打开觅迹    ⌃⌥Space",action:#selector(showSearch),keyEquivalent:"");open.target=self;menu.addItem(open)
        let setting=NSMenuItem(title:"索引与设置…",action:#selector(openSettings),keyEquivalent:"");setting.target=self;menu.addItem(setting)
        let pause=NSMenuItem(title:"暂停／继续索引",action:#selector(togglePause),keyEquivalent:"");pause.target=self;menu.addItem(pause)
        menu.addItem(.separator());menu.addItem(NSMenuItem(title:"退出觅迹",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"));statusItem?.menu=menu
    }
    @objc func showSearch() {
        guard let panel=searchPanel else{return}
        NSLog("Miji showSearch")
        if !panel.isVisible,let screen=NSScreen.main {
            let rect=screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x:rect.midX-panel.frame.width/2,y:rect.maxY-150-panel.frame.height))
        }
        NSApp.unhide(nil);NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil);model.setSearchVisible(true);model.focusSearch=UUID()
        NSLog("Miji search panel id %d visible %d frame %@",panel.windowNumber,panel.isVisible ? 1 : 0,NSStringFromRect(panel.frame))
    }
    private func hideSearch() { searchPanel?.orderOut(nil);model.setSearchVisible(false) }
    func toggleSearch() {if searchPanel.isKeyWindow && searchPanel.isVisible {hideSearch()}else{showSearch()}}
    @objc func togglePause(){model.togglePause()}
    @objc func openSettings() {
        if settingsWindow==nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="觅迹 · 索引与设置";window.isReleasedWhenClosed=false
            window.contentView=NSHostingView(rootView:SettingsView(model:model));window.center();settingsWindow=window
        }
        hideSearch();NSApp.activate(ignoringOtherApps:true);settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func closeSettings(){settingsWindow?.orderOut(nil);showSearch()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        model.prepareForTermination {sender.reply(toApplicationShouldTerminate:true)}
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool{showSearch();return true}
    func applicationDidResignActive(_ notification:Notification){if ProcessInfo.processInfo.environment["MIJI_UI_TESTING"] != "1" {hideSearch()}}
    func applicationWillTerminate(_ notification:Notification){model.service?.stop();if let hotKey{UnregisterEventHotKey(hotKey)};if let handler{RemoveEventHandler(handler)};if let monitor{NSEvent.removeMonitor(monitor)}}
    func preview() {
        guard let hit=model.selected,let url=PreviewResolver.localURL(for:hit) else{return}
        previewURL=url as NSURL
        guard let panel=QLPreviewPanel.shared() else{return}
        panel.dataSource=self;panel.reloadData();panel.level = .floating;panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel:QLPreviewPanel!)->Int{previewURL == nil ? 0 : 1}
    func previewPanel(_ panel:QLPreviewPanel!,previewItemAt index:Int)->QLPreviewItem!{previewURL}
}
