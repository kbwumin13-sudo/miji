import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MijiCore

struct MainView:View {
    @ObservedObject var model:AppModel
    @FocusState private var searchFocused:Bool
    @State private var showHelp=false
    @State private var showDetails=false
    private var expanded:Bool {!model.query.isEmpty}
    private let tabs:[FileKind?]=[nil,.folder,.application,.document,.image,.video,.audio,.code,.archive]
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:15) {
                Image(systemName:"magnifyingglass").font(.system(size:23,weight:.regular)).foregroundStyle(.secondary)
                TextField("搜索这台 Mac",text:$model.query).font(.system(size:25,weight:.regular)).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("搜索文件")
                if model.searching {ProgressView().controlSize(.small)}
                if expanded {Button {model.query=""} label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.tertiary)}.buttonStyle(.plain).help("清空搜索")}
                Button {openSettings()} label:{Image(systemName:"gearshape").font(.system(size:15)).foregroundStyle(.secondary)}.buttonStyle(.plain).help("索引与设置")
            }.padding(.horizontal,24).frame(height:72)
            if expanded {
                Divider().padding(.horizontal,16)
                HStack(spacing:3) {
                    ForEach(tabs,id:\.self) {kind in
                        Button {model.kind=kind} label: {Text(kind?.title ?? "全部").font(.system(size:12,weight:.medium)).padding(.horizontal,10).padding(.vertical,6).foregroundStyle(model.kind == kind ? Color.accentColor : .secondary).background(model.kind == kind ? Color.accentColor.opacity(0.15) : .clear,in:Capsule())}.buttonStyle(.plain)
                    }
                    Spacer(minLength:2)
                    Menu {
                        Picker("搜索范围",selection:$model.scope) {Text("全部").tag(SearchScope.all);Text("文件名").tag(SearchScope.name);Text("内容").tag(SearchScope.content)}
                        Picker("索引位置",selection:$model.rootID) {Text("所有位置").tag(String?.none);ForEach(model.roots){Text($0.name + ($0.isOnline ? "" : " · 未连接")).tag(Optional($0.id))}}
                        Divider()
                        Picker("排序",selection:$model.sort) {Text("相关度").tag(SearchSort.relevance);Text("最近修改").tag(SearchSort.modified);Text("名称").tag(SearchSort.name);Text("大小").tag(SearchSort.size)}
                    } label:{Label(model.scope == .content ? "内容" : model.scope == .name ? "文件名" : "筛选",systemImage:"line.3.horizontal.decrease")}.menuStyle(.borderlessButton).fixedSize().font(.system(size:11)).foregroundStyle(.secondary)
                }.padding(.horizontal,16).frame(height:44)
                results
            }
            footer
        }
        .frame(width:800,height:model.panelHeight)
        .background(GlassBackground().overlay(Color.black.opacity(0.48)))
        .environment(\.colorScheme,.dark)
        .clipShape(RoundedRectangle(cornerRadius:20))
        .overlay(RoundedRectangle(cornerRadius:20).strokeBorder(.white.opacity(0.13),lineWidth:0.7))
        .background(SearchWindowConfiguration())
        .ignoresSafeArea()
        .onAppear {searchFocused=true}
        .onChange(of:model.focusSearch) {searchFocused=true}
        .alert("觅迹",isPresented:Binding(get:{model.message != nil},set:{if !$0{model.message=nil}})) {Button("好"){model.message=nil}} message:{Text(model.message ?? "")}
    }
    private func openSettings() {AppDelegate.shared?.openSettings()}
    @ViewBuilder private var results:some View {
        if model.hits.isEmpty {
            VStack(spacing:10) {Image(systemName:"magnifyingglass").font(.system(size:28,weight:.light));Text(model.statistics.files==0 ? "正在建立文件目录…" : "没有找到匹配项").font(.system(size:14));Text("可搜索文件名、文档文字和图片内容").font(.system(size:12)).foregroundStyle(.tertiary)}.foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            ScrollViewReader {proxy in
                ScrollView {
                    LazyVStack(spacing:2) {
                        ForEach(model.hits) {hit in
                            CompactResultRow(hit:hit,query:model.query,selected:model.selectedID==hit.id)
                                .contentShape(Rectangle()).onTapGesture(count:2){model.selectedID=hit.id;model.openSelected()}
                                .onTapGesture{model.selectedID=hit.id;searchFocused=false}
                                .contextMenu {
                                    Button("打开"){model.selectedID=hit.id;model.openSelected()}.disabled(!hit.root.isOnline)
                                    Button("在 Finder 中显示"){model.selectedID=hit.id;model.revealSelected()}.disabled(!hit.root.isOnline)
                                    Button("快速查看"){model.selectedID=hit.id;AppDelegate.shared?.preview()}.disabled(!hit.root.isOnline)
                                    Button("查看已索引内容"){model.selectedID=hit.id;showDetails=true}
                                    Button("复制路径"){model.selectedID=hit.id;model.copySelectedPath()}
                                }.id(hit.id)
                        }
                    }.padding(.horizontal,10).padding(.bottom,5)
                }.onChange(of:model.selectedID){if let id=model.selectedID {proxy.scrollTo(id)}}
            }
        }
    }
    private var footer:some View {
        VStack(spacing:0) {
            if expanded {Divider()}
            HStack(spacing:8) {
                if expanded {Text("\(model.hits.count == 500 ? "前 " : "共 ")\(model.hits.count) 项 · \(model.searchMilliseconds,specifier:"%.1f") ms")}
                else {Text(model.progress.busy ? "\(model.progress.phase) · \(max(model.statistics.files,model.progress.processed).formatted()) 项" : "觅迹 · \(model.statistics.files.formatted()) 个文件")}
                if model.progress.busy && expanded {Circle().fill(Color.accentColor).frame(width:4,height:4).help(model.progress.phase)}
                Spacer(minLength:5)
                if expanded {
                    Text("↩ 打开    ⌘↩ 定位")
                    Button("⌘Y 预览"){AppDelegate.shared?.preview()}.buttonStyle(.plain)
                    Button("内容"){showDetails.toggle()}.buttonStyle(.plain).popover(isPresented:$showDetails){detailPreview}.onChange(of:showDetails){model.setPreviewVisible(showDetails)}
                } else {Text("⌃⌥Space 唤起")}
                Button {showHelp.toggle()} label:{Image(systemName:"questionmark.circle")}.buttonStyle(.plain).popover(isPresented:$showHelp) {
                    VStack(alignment:.leading,spacing:10) {Text("搜索语法").font(.headline);Text("多个词：全部匹配\n\"完整短语\"：连续匹配\next:pdf：限定格式\npath:课程：限定路径\n-草稿：排除词\n支持中文、拼音与首字母");Divider();Text("↑ ↓ 选择 · Return 打开\n⌘Return / ⌘R 定位 · ⌘Y / 空格预览\n⌘⇧C 复制路径 · Esc 收起").font(.caption)}.padding(20)
                }
            }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,22).frame(height:28)
        }
    }
    private var detailPreview:some View {
        ScrollView {VStack(alignment:.leading,spacing:14) {
            if let hit=model.selected {
                Text(hit.file.name).font(.headline)
                Text(hit.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !hit.root.isOnline {Label("未连接 · 已保留内容",systemImage:"externaldrive.badge.exclamationmark").foregroundStyle(.orange)}
                if let image=model.previewImage {Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:180)}
                if !hit.labels.isEmpty {Text(hit.labels).font(.callout)}
                Text(model.previewText.isEmpty ? "暂无提取内容" : model.previewText).font(.system(size:12)).textSelection(.enabled)
                if let warning=model.previewWarning {Text(warning).font(.caption).foregroundStyle(.orange)}
                if let error=hit.file.contentError {Text(error).font(.caption).foregroundStyle(.orange)}
            } else {Text("选择一项结果查看内容")}
        }.padding(20)}.frame(width:460,height:400)
    }
}
private struct CompactResultRow:View {
    let hit:SearchHit
    let query:String
    let selected:Bool
    private var parentPath:String {
        let path=URL(fileURLWithPath:hit.path).deletingLastPathComponent().path
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        return path==home ? "~" : (path.hasPrefix(home+"/") ? "~"+path.dropFirst(home.count) : path)
    }
    private var title:AttributedString {
        var text=AttributedString(hit.file.name)
        for term in QueryParser.parse(query).terms where term.field == .text && !term.isExcluded {
            if let range=text.range(of:term.value,options:.caseInsensitive) {text[range].foregroundColor = .accentColor}
        }
        return text
    }
    var body:some View {
        HStack(spacing:13) {
            Image(nsImage:FileIconCache.icon(hit)).resizable().scaledToFit().frame(width:32,height:32)
            VStack(alignment:.leading,spacing:3) {
                Text(title).font(.system(size:14,weight:.medium)).lineLimit(1)
                if (hit.matchedIn.contains("正文") || hit.matchedIn.contains("标签")),!hit.snippet.isEmpty {
                    Text(hit.snippet).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                } else {Text(parentPath).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)}
            }
            Spacer(minLength:10)
            VStack(alignment:.trailing,spacing:3) {
                if !hit.root.isOnline {Text("未连接").foregroundStyle(.orange)}
                else {Text(Date(timeIntervalSince1970:hit.file.modified).formatted(.dateTime.month().day()))}
                Text(hit.file.kind == .folder ? "文件夹" : ByteCountFormatter.string(fromByteCount:hit.file.size,countStyle:.file)).foregroundStyle(.tertiary)
            }.font(.system(size:10)).foregroundStyle(.secondary)
        }.padding(.horizontal,15).frame(height:57)
        .background(selected ? Color.accentColor.opacity(0.27) : .clear,in:RoundedRectangle(cornerRadius:10))
        .accessibilityElement(children:.combine).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
private enum FileIconCache {
    static let cache=NSCache<NSString,NSImage>()
    static func icon(_ hit:SearchHit)->NSImage {
        let key=(hit.file.kind == .application ? hit.path : hit.file.kind.rawValue+":"+hit.file.fileExtension) as NSString
        if let icon=cache.object(forKey:key){return icon}
        let icon:NSImage
        if hit.file.kind == .folder {icon=NSWorkspace.shared.icon(for:.folder)}
        else if hit.file.kind == .application && hit.root.isOnline {icon=NSWorkspace.shared.icon(forFile:hit.path)}
        else {icon=NSWorkspace.shared.icon(for:UTType(filenameExtension:hit.file.fileExtension) ?? .data)}
        icon.size=NSSize(width:32,height:32);cache.setObject(icon,forKey:key);return icon
    }
}
private struct GlassBackground:NSViewRepresentable {
    func makeNSView(context:Context)->NSVisualEffectView {let view=NSVisualEffectView();view.appearance=NSAppearance(named:.darkAqua);view.material = .hudWindow;view.blendingMode = .behindWindow;view.state = .active;return view}
    func updateNSView(_ view:NSVisualEffectView,context:Context){}
}
private struct SearchWindowConfiguration:NSViewRepresentable {
    func makeNSView(context:Context)->NSView {NSView()}
    func updateNSView(_ view:NSView,context:Context) {
        DispatchQueue.main.async {guard let window=view.window else{return};window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.isOpaque=false;window.backgroundColor = .clear;window.isMovableByWindowBackground=true;window.level = .floating;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];for button in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton]{window.standardWindowButton(button)?.isHidden=true}}
    }
}
extension FileKind {
    var symbol:String {switch self {case .document:return "doc.text";case .image:return "photo";case .folder:return "folder";case .application:return "app";case .code:return "curlybraces";case .audio:return "waveform";case .video:return "film";case .archive:return "archivebox";case .other:return "doc"}}
}
