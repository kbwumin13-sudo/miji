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
private final class SearchAuxiliaryWindow:NSWindow {
    override var canBecomeKey:Bool {!AppDelegate.isBackgroundUITesting && super.canBecomeKey}
    override var canBecomeMain:Bool {!AppDelegate.isBackgroundUITesting && super.canBecomeMain}
}
@MainActor
final class AppDelegate:NSObject,NSApplicationDelegate,@preconcurrency QLPreviewPanelDataSource {
    static weak var shared:AppDelegate?
    nonisolated static func usesBackgroundPresentation(environment:[String:String],bundleIdentifier:String?) -> Bool {
        guard environment["MIJI_UI_TESTING"] == "1",let bundleIdentifier,!bundleIdentifier.isEmpty else{return false}
        return bundleIdentifier != "com.haiyu.miji"
    }
    static var isBackgroundUITesting:Bool {
        usesBackgroundPresentation(environment:ProcessInfo.processInfo.environment,bundleIdentifier:Bundle.main.bundleIdentifier)
    }
    private static let previewShortcut: String? = Bundle.main.bundleIdentifier == "com.haiyu.miji"
        ? nil : ProcessInfo.processInfo.environment["MIJI_PREVIEW_HOTKEY"]
    static var searchShortcutLabel: String {
        switch previewShortcut {
        case "1": return "⌃⌥⇧Space"
        case "2": return "⌃⌥⌘Space"
        case "3": return "⌃⇧⌘Space"
        case "4": return "⌃⌥⇧⌘Space"
        default: return "⌃⌥Space"
        }
    }
    let model=AppModel()
    private var searchPanel:SearchPanel!
    private var settingsWindow:NSWindow?
    private var pdfWindow:NSWindow?
    private var statusItem:NSStatusItem?
    private var hotKey:EventHotKeyRef?
    private var handler:EventHandlerRef?
    private var monitor:Any?
    private var previewURL:NSURL?
    private var previewHit:SearchHit?
    private var previewSnapshot:SearchSnapshot?
    private var subscriptions=Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification:Notification) {
        Self.shared=self
        NSApp.setActivationPolicy(.accessory)
        let panel=SearchPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.compactWidth, height: PanelMetrics.searchHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title="觅迹";panel.level = .floating;panel.isOpaque=false;panel.backgroundColor = .clear
        panel.hasShadow=true;panel.isMovableByWindowBackground=true;panel.hidesOnDeactivate=false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView=NSHostingView(rootView:MainView(model:model))
        searchPanel=panel
        model.openMain={ [weak self] in self?.showSearch() }
        Publishers.CombineLatest4(model.$query,model.$hits,model.$previewMode,model.$gridEnabled).sink{[weak self] _ in
            // @Published emits before assignment; size using the completed model state.
            DispatchQueue.main.async {self?.resizeSearchPanel()}
        }.store(in:&subscriptions)
        Publishers.CombineLatest(model.$mode, model.$showsFileSelectionFeedback.removeDuplicates()).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeSearchPanel() }
        }.store(in:&subscriptions)
        model.$currentSnapshot.sink { [weak self] _ in
            DispatchQueue.main.async { self?.invalidateQuickLook() }
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
        let modifiers: Int
        switch Self.previewShortcut {
        case "1": modifiers = controlKey | optionKey | shiftKey
        case "2": modifiers = controlKey | optionKey | cmdKey
        case "3": modifiers = controlKey | shiftKey | cmdKey
        case "4": modifiers = controlKey | optionKey | shiftKey | cmdKey
        default: modifiers = controlKey | optionKey
        }
        let status:OSStatus = Self.isBackgroundUITesting ? noErr : RegisterEventHotKey(UInt32(kVK_Space),UInt32(modifiers),keyID,GetApplicationEventTarget(),0,&hotKey)
        NSLog("Miji launched; hotkey status %d",status)
        if status != noErr {model.message="全局快捷键 \(Self.searchShortcutLabel) 已被占用。仍可从菜单栏打开觅迹。"}
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
            guard let self,NSApp.keyWindow===self.searchPanel else{return event}
            guard !self.searchPanel.isDismissing else{return nil}
            let mode = self.model.mode
            let horizontal = (mode == .apps || self.model.browsingRecent) && self.model.query.isEmpty
            switch SearchKeyAction.action(for:event,firstResponder:self.searchPanel.firstResponder,navigateHorizontally:horizontal) {
            case .selectMode(let target): self.model.selectMode(target)
            case .focusSearch: self.model.focusSearch=UUID()
            case .reveal:
                if mode == .apps, let app = self.selectedApplication() { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                else { self.model.revealSelected() }
            case .preview: self.preview()
            case .copyPath: self.model.copySelectedPath()
            case .copyFile: self.model.copySelectedFile()
            case .moveLeft:
                if mode == .apps { self.model.browse.moveApps(-1, query:self.model.query) }
                else if self.model.showsFileGrid || self.model.browsingRecent { self.model.moveSelection(-1) }
                else { return event }
            case .moveRight:
                if mode == .apps { self.model.browse.moveApps(1, query:self.model.query) }
                else if self.model.showsFileGrid || self.model.browsingRecent { self.model.moveSelection(1) }
                else { return event }
            case .hide:
                if mode == .all { self.hideSearch() }
                else if self.model.browsingRecent && self.model.previewVisible {
                    self.model.clearSelectionFeedback()
                    self.model.focusSearch = UUID()
                }
                else { self.model.selectMode(.all) }
            case .settings: self.openSettings()
            case .moveDown: self.moveBrowseSelection(1)
            case .moveUp: self.moveBrowseSelection(-1)
            case .open:
                switch mode {
                case .apps: if let app = self.selectedApplication() { self.openApplication(app) }
                case .clipboard:
                    let entries = self.model.browse.visibleClipboard(query:self.model.query)
                    if let item = entries.first(where: { $0.id == self.model.browse.clipboardSelection }) ?? entries.first { self.copyClipboardEntry(item) }
                case .all, .files: self.model.openSelected()
                }
            case nil:
                if (mode == .apps && self.model.browse.appSelection != nil) || self.model.showsFileSelectionFeedback,
                   let editor = self.searchPanel.firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText() {
                    // The IME can start editing before SwiftUI publishes a new query.
                    DispatchQueue.main.async { [weak self, weak editor] in
                        guard let self, let editor, NSApp.keyWindow === self.searchPanel,
                              self.searchPanel.firstResponder === editor, editor.hasMarkedText() else { return }
                        self.model.focusSearch = UUID()
                    }
                }
                return event
            }
            return nil
        }
        DispatchQueue.main.async {
            self.applyUITestPreset()
            self.showSearch()
            if !Self.isBackgroundUITesting { self.model.browse.loadApps() }
        }
    }
    private func moveBrowseSelection(_ direction: Int) {
        switch model.mode {
        case .apps: model.browse.moveApps(direction * InstalledApp.gridColumns, query:model.query)
        case .clipboard: model.browse.moveClipboard(direction, query:model.query)
        case .all, .files:
            if model.browsingRecent, !model.hits.isEmpty {
                let current = model.hits.firstIndex { $0.id == model.selectedID }
                let featuredCount = min(5, model.hits.count)
                if !model.showsFileSelectionFeedback {
                    let target = direction > 0 ? (model.hits.count > featuredCount ? featuredCount : 0) : model.hits.count - 1
                    model.selectFile(model.hits[target].id)
                } else if let current {
                    if direction > 0 && current < featuredCount && model.hits.count > featuredCount {
                        model.selectFile(model.hits[featuredCount].id)
                    } else if direction < 0 && current == featuredCount {
                        model.selectFile(model.hits[0].id)
                    } else {
                        model.moveSelection(direction)
                    }
                } else {
                    model.moveSelection(direction)
                }
            } else {
                model.moveSelection(direction * (model.showsFileGrid ? model.gridColumns : 1))
            }
        }
    }
    private func selectedApplication() -> InstalledApp? {
        let apps = model.browse.visibleApps(query:model.query)
        return apps.first(where: { $0.id == model.browse.appSelection }) ?? apps.first
    }
    func openApplication(_ app: InstalledApp) {
        if NSWorkspace.shared.open(app.url) { hideSearch(animated:false) }
        else { model.message = "未能打开「\(app.title)」" }
    }
    func copyClipboardEntry(_ entry: ClipboardEntry) {
        if model.browse.copyClipboardEntry(entry) { hideSearch() }
        else { model.message = "无法写入剪贴板。" }
    }
    /// Deterministic launch state for isolated native-app acceptance. These set
    /// the same model bindings as the UI and never inject results or search phases.
    private func applyUITestPreset() {
        let env=ProcessInfo.processInfo.environment
        guard Self.isBackgroundUITesting else{return}
        if env["MIJI_UI_PAUSE_INDEX"] == "1" {model.paused=true;model.service?.setPaused(true)}
        if let kind=env["MIJI_UI_KIND"].flatMap(FileKind.init(rawValue:)) {model.kind=kind}
        if let scope=env["MIJI_UI_SCOPE"].flatMap(SearchScope.init(rawValue:)) {model.scope=scope}
        if let sort=env["MIJI_UI_SORT"].flatMap(SearchSort.init(rawValue:)) {model.sort=sort}
        if let root=env["MIJI_UI_ROOT_ID"] {model.rootID=root}
        if let preview=env["MIJI_UI_PREVIEW"].flatMap(SearchPreviewMode.init(rawValue:)) {model.previewMode=preview}
        model.gridEnabled=env["MIJI_UI_GRID"] == "1"
        if let query=env["MIJI_UI_QUERY"] {model.query=query}
    }
    private func present(_ window:NSWindow,activate:Bool = false) {
        if Self.isBackgroundUITesting {
            window.ignoresMouseEvents=true
            window.orderFrontRegardless()
        } else {
            if activate {NSApp.activate(ignoringOtherApps:true)}
            window.makeKeyAndOrderFront(nil)
        }
    }
    private func resizeSearchPanel() {
        guard let panel=searchPanel else{return}
        panel.resize(to: searchFrame(for: panel, centered: false))
    }
    private func searchFrame(for panel: SearchPanel, centered: Bool) -> NSRect {
        let anchor = panel.destinationFrame
        let screen = (centered ? NSScreen.main : (panel.screen ?? NSScreen.main))?.visibleFrame ?? anchor
        let fitsScreenWidth = model.mode == .apps || (model.browsingRecent && model.previewVisible)
        let width = fitsScreenWidth ? min(model.panelWidth, screen.width) : model.panelWidth
        let height = model.mode == .apps ? min(model.panelHeight, screen.height) : model.panelHeight
        let leading = (centered ? screen.midX : anchor.midX) - width / 2
        let top = centered ? screen.maxY - 153 : anchor.maxY
        let x = min(max(screen.minX, leading), max(screen.minX, screen.maxX - width))
        let y = min(max(screen.minY, top - height), max(screen.minY, screen.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }
    func showPDFMatch() {
        guard let hit=model.selected,model.validateResult(hit,for:.preview),let document=model.previewPDF,let page=model.previewPage else{return}
        let window=SearchAuxiliaryWindow(contentRect:NSRect(x:0,y:0,width:800,height:700),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title=model.selected?.file.name ?? "PDF 预览"
        window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:PDFDocumentPreview(document:document,page:page,terms:PreviewResolver.terms(in:model.query)))
        hideSearch(animated: false)
        pdfWindow?.close();pdfWindow=window
        window.center();present(window)
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
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "觅迹"
        statusItem?.button?.image=NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:appName)
        statusItem?.button?.toolTip = appName
        let menu=NSMenu()
        let open=NSMenuItem(title:"打开觅迹    \(Self.searchShortcutLabel)",action:#selector(showSearch),keyEquivalent:"");open.target=self;menu.addItem(open)
        let setting=NSMenuItem(title:"索引与设置…",action:#selector(openSettings),keyEquivalent:"");setting.target=self;menu.addItem(setting)
        let pause=NSMenuItem(title:"暂停／继续索引",action:#selector(togglePause),keyEquivalent:"");pause.target=self;menu.addItem(pause)
        menu.addItem(.separator());menu.addItem(NSMenuItem(title:"退出觅迹",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"));statusItem?.menu=menu
    }
    @objc func showSearch() {
        guard let panel=searchPanel else{return}
        NSLog("Miji showSearch")
        let entering = !panel.isVisible
        model.setSearchVisible(true)
        let target = searchFrame(for: panel, centered: entering)
        if entering {
            model.panelActivation = UUID()
            panel.prepareEntrance(at: target, compact: model.mode == .all && model.query.isEmpty)
        }
        panel.ignoresMouseEvents = Self.isBackgroundUITesting
        if !Self.isBackgroundUITesting {NSApp.unhide(nil)}
        present(panel,activate:true)
        panel.reveal(at: target, entering: entering)
        model.focusSearch=UUID()
        NSLog("Miji search panel id %d visible %d frame %@",panel.windowNumber,panel.isVisible ? 1 : 0,NSStringFromRect(panel.frame))
    }
    private func hideSearch(animated: Bool = true) {
        searchPanel?.dismiss(animated: animated) { [weak self] in
            self?.model.setSearchVisible(false)
        }
    }
    func toggleSearch() {
        if searchPanel.isKeyWindow && searchPanel.isVisible && !searchPanel.isDismissing { hideSearch() }
        else { showSearch() }
    }
    @objc func togglePause(){model.togglePause()}
    @objc func openSettings() {
        if settingsWindow==nil {
            let window=SearchAuxiliaryWindow(contentRect:NSRect(x:0,y:0,width:720,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="觅迹 · 索引与设置";window.isReleasedWhenClosed=false
            window.contentView=NSHostingView(rootView:SettingsView(model:model));window.center();settingsWindow=window
        }
        hideSearch(animated: false);if let window=settingsWindow {present(window,activate:true)}
    }
    func closeSettings(){settingsWindow?.orderOut(nil);showSearch()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        model.prepareForTermination {sender.reply(toApplicationShouldTerminate:true)}
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool{showSearch();return true}
    func applicationDidResignActive(_ notification:Notification){if !Self.isBackgroundUITesting {hideSearch()}}
    func applicationWillTerminate(_ notification:Notification){model.service?.stop();if let hotKey{UnregisterEventHotKey(hotKey)};if let handler{RemoveEventHandler(handler)};if let monitor{NSEvent.removeMonitor(monitor)}}
    func preview(hit:SearchHit? = nil,snapshot:SearchSnapshot? = nil) {
        guard let hit=hit ?? model.selectedFileForAction,let url=model.fileOperationURL(for:hit,action:.quickLook,snapshot:snapshot) else{return}
        previewURL=url as NSURL;previewHit=hit;previewSnapshot=model.displayedSnapshot
        guard let panel=QLPreviewPanel.shared() else{return}
        panel.dataSource=self;panel.reloadData();panel.level = .floating;present(panel)
    }
    private var quickLookIsCurrent:Bool {
        guard let hit=previewHit else{return false}
        return model.isCurrentResult(hit,snapshot:previewSnapshot) && PreviewResolver.localURL(for:hit) != nil
    }
    private func invalidateQuickLook() {
        guard !quickLookIsCurrent else{return}
        previewURL=nil;previewHit=nil;previewSnapshot=nil
        if QLPreviewPanel.sharedPreviewPanelExists() {QLPreviewPanel.shared()?.orderOut(nil)}
    }
    func numberOfPreviewItems(in panel:QLPreviewPanel!)->Int{quickLookIsCurrent ? 1 : 0}
    func previewPanel(_ panel:QLPreviewPanel!,previewItemAt index:Int)->QLPreviewItem!{quickLookIsCurrent ? previewURL : nil}
}
