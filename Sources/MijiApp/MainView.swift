import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MijiCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showHelp = false
    @State private var appearance = SearchAppearance.darkGlass
    private var expanded: Bool { !model.query.isEmpty }
    private var scheme: ColorScheme { appearance == .darkGlass ? .dark : systemScheme }
    private var currentResults: Bool { model.displayedSnapshot != nil && model.displayedSnapshot == model.currentSnapshot }
    private let tabs: [FileKind?] = [nil, .folder, .application, .document, .image, .video, .audio, .code, .archive]

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if expanded {
                Divider().padding(.horizontal, 20)
                toolbar
                HStack(spacing: 0) {
                    if model.searchPresented { results.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if model.previewVisible {
                        Divider()
                        ResultPreviewPane(model: model).frame(width: AppModel.previewWidth)
                            .background(Color.primary.opacity(0.025))
                    }
                }
            }
            footer
        }
        .frame(width: model.panelWidth, height: model.panelHeight)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else {
                SearchMaterial(scheme: scheme)
                    .overlay(scheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.28))
            }
        }
        .environment(\.colorScheme, scheme)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder((scheme == .dark ? Color.white : Color.black).opacity(contrast == .increased ? 0.4 : 0.14), lineWidth: contrast == .increased ? 1 : 0.5))
        .background(SearchWindowConfiguration())
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearch) { searchFocused = true }
        .alert("觅迹", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var searchField: some View {
        HStack(spacing: 16) {
            Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("搜索这台 Mac", text: $model.query)
                .font(.system(size: 25, weight: .regular)).textFieldStyle(.plain)
                .focused($searchFocused).accessibilityLabel("搜索文件")
            if model.searching {
                ProgressView().controlSize(.small).accessibilityLabel("正在搜索")
            }
            if expanded {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(SearchIconButtonStyle()).help("清空搜索").accessibilityLabel("清空搜索")
            }
            Menu {
                Button("索引与设置…") { AppDelegate.shared?.openSettings() }
                Divider()
                Picker("浮窗外观", selection: $appearance) {
                    ForEach(SearchAppearance.allCases) { Text($0.title).tag($0) }
                }
            } label: { Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("索引、设置与浮窗外观").accessibilityLabel("索引、设置与浮窗外观")
        }.padding(.horizontal, 24).frame(height: 72)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(tabs, id: \.self) { kind in
                        Button { model.kind = kind } label: {
                            Text(kind?.title ?? "全部").font(.system(size: 12, weight: model.kind == kind ? .semibold : .medium))
                                .padding(.horizontal, 10).frame(height: 27)
                                .foregroundStyle(model.kind == kind ? Color.primary : Color.secondary)
                                .background(model.kind == kind ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel("类型：\(kind?.title ?? "全部")")
                            .accessibilityAddTraits(model.kind == kind ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden).frame(minWidth: 140)
            if !model.activeFilters.isEmpty {
                HStack(spacing: 5) {
                    ForEach(model.activeFilters.filter { $0.id != .kind }) { filter in
                        Button { model.removeFilter(filter.id) } label: {
                            HStack(spacing: 4) {
                                Text(filter.label).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
                            }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).frame(height: 25)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).foregroundStyle(Color.primary)
                            .frame(maxWidth: filter.id == .root ? 100 : nil)
                            .help("移除条件：\(filter.label)").accessibilityLabel("移除筛选：\(filter.label)")
                    }
                    Button { model.resetInterfaceFilters() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(SearchIconButtonStyle()).help("重置界面筛选，保留搜索词与视图偏好")
                        .accessibilityLabel("重置界面筛选")
                }.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            }
            filterMenu
        }.padding(.horizontal, 16).frame(height: 44)
    }

    private var filterMenu: some View {
        Menu {
            Picker("搜索范围", selection: $model.scope) {
                Text("全部").tag(SearchScope.all); Text("文件名").tag(SearchScope.name); Text("内容").tag(SearchScope.content)
            }
            Picker("索引位置", selection: $model.rootID) {
                Text("所有位置").tag(String?.none)
                ForEach(model.roots) { Text($0.name + ($0.isOnline ? "" : " · 未连接")).tag(Optional($0.id)) }
            }
            Picker("排序", selection: $model.sort) {
                Text("相关度").tag(SearchSort.relevance); Text("最近修改").tag(SearchSort.modified)
                Text("名称").tag(SearchSort.name); Text("大小").tag(SearchSort.size)
            }
            Divider()
            Button("重置界面筛选") { model.resetInterfaceFilters() }.disabled(model.activeFilters.isEmpty)
        } label: {
            Image(systemName: model.activeFilters.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 14)).foregroundStyle(model.activeFilters.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 25, height: 27)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("搜索范围、位置与排序").accessibilityLabel("筛选：\(model.activeFilters.map(\.label).joined(separator: "、"))")
    }

    @ViewBuilder private var results: some View {
        if model.hits.isEmpty { emptyState }
        else {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.gridEnabled {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: model.gridColumns), spacing: 10) {
                            ForEach(model.hits) { hit in
                                resultActions(ResultGridCell(hit: hit, query: model.query, location: model.resultLocation(hit).short, selected: model.selectedID == hit.id), hit: hit)
                            }
                        }.padding(12)
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(model.hits) { hit in
                                resultActions(CompactResultRow(hit: hit, query: model.query, location: model.resultLocation(hit).short, selected: model.selectedID == hit.id), hit: hit)
                            }
                        }.padding(.horizontal, 10).padding(.bottom, 5)
                    }
                }.opacity(currentResults ? 1 : 0.5)
                    .onChange(of: model.selectedID) { if let id = model.selectedID { proxy.scrollTo(id) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.searchStatus.phase == .failed ? "exclamationmark.circle" : "magnifyingglass")
                .font(.system(size: 29, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(emptyTitle).font(.system(size: 14, weight: .medium))
            Text(emptyDetail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
            if model.searchStatus.phase == .complete && !model.activeFilters.isEmpty {
                Button("重置界面筛选") { model.resetInterfaceFilters() }.controlSize(.small)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
    }
    private var emptyTitle: String {
        switch model.searchStatus.phase {
        case .searching, .supplementing: return "正在搜索…"
        case .failed: return "未能完成搜索"
        case .complete: return "当前条件下没有匹配项"
        case .idle: return "搜索文件与内容"
        }
    }
    private var emptyDetail: String {
        switch model.searchStatus.phase {
        case .searching, .supplementing: return "正在查找文件名与已索引内容"
        case .failed: return model.searchStatus.error ?? "请稍后重试。"
        default:
            if model.paused { return "索引已暂停，仍可搜索已保存的内容" }
            if model.progress.busy { return "索引仍在\(model.progress.phase)，可搜索已完成的内容" }
            return model.activeFilters.isEmpty ? "试试其他关键词，也可以搜索文档文字与图片内容" : "试试减少筛选条件，或更换关键词"
        }
    }

    private func resultActions<V: View>(_ view: V, hit: SearchHit) -> some View {
        let snapshot = model.displayedSnapshot
        return view.contentShape(Rectangle())
            .onTapGesture(count: 2) { model.selectedID = hit.id; model.performFileAction(.open, hit: hit, snapshot: snapshot) }
            .onTapGesture { model.selectedID = hit.id; searchFocused = false }
            .contextMenu {
                Button("打开") { model.selectedID = hit.id; model.performFileAction(.open, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("在 Finder 中显示") { model.selectedID = hit.id; model.performFileAction(.reveal, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("快速查看") { model.selectedID = hit.id; model.performFileAction(.quickLook, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Divider()
                Button("复制文件") { model.selectedID = hit.id; model.performFileAction(.copyFile, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("复制路径") { model.selectedID = hit.id; model.performFileAction(.copyPath, hit: hit, snapshot: snapshot) }
            }.id(hit.id)
    }

    private var statusText: String {
        let status = model.searchStatus
        switch status.phase {
        case .searching: return "正在搜索…"
        case .supplementing: return "已找到 \(status.count) 项 · 正文检索中"
        case .failed: return "搜索未完成 · \(status.count) 项"
        case .complete: return status.count == 500 ? "显示前 500 项" : "共 \(status.count) 项"
        case .idle: return "准备搜索"
        }
    }
    private var indexText: String {
        if model.paused { return "索引已暂停" }
        if model.progress.busy { return "\(model.progress.phase) · \(max(model.statistics.files, model.progress.processed).formatted()) 项" }
        return "觅迹 · \(model.statistics.files.formatted()) 个文件"
    }
    private var footer: some View {
        VStack(spacing: 0) {
            if expanded { Divider() }
            HStack(spacing: 10) {
                Text(expanded ? statusText : indexText).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .help(expanded ? model.searchStatus.error ?? statusText : indexText).accessibilityLabel(expanded ? statusText : indexText)
                if expanded {
                    if let time = model.searchStatus.milliseconds, let timing = model.searchStatus.timing {
                        Text("\(timing == .firstBatch ? "首批" : "完成") \(time, specifier: "%.0f") ms").monospacedDigit()
                    }
                    if model.paused || model.progress.busy {
                        Image(systemName: model.paused ? "pause.circle" : "externaldrive.badge.timemachine")
                            .help(indexText).accessibilityLabel(indexText)
                    }
                    Divider().frame(height: 12)
                    Text("↩ 打开  ⌘R 定位").accessibilityHidden(true)
                    Button { model.gridEnabled.toggle(); searchFocused = false } label: { Image(systemName: model.gridEnabled ? "list.bullet" : "square.grid.2x2") }
                        .buttonStyle(SearchIconButtonStyle()).help("切换列表／网格").accessibilityLabel("切换列表／网格")
                    Menu {
                        Picker("预览栏", selection: $model.previewMode) {
                            ForEach(SearchPreviewMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                    } label: { Image(systemName: "sidebar.right").foregroundStyle(model.previewVisible ? Color.accentColor : Color.secondary) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("预览栏：\(model.previewMode.title)").accessibilityLabel("预览栏：\(model.previewMode.title)")
                    Button { model.performFileAction(.quickLook) } label: { Image(systemName: "eye") }
                        .buttonStyle(SearchIconButtonStyle()).help("快速查看 · ⌘Y").accessibilityLabel("快速查看")
                } else { Text("⌃⌥Space 唤起") }
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(SearchIconButtonStyle()).help("搜索语法与快捷键").accessibilityLabel("搜索帮助")
                    .popover(isPresented: $showHelp) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("搜索语法").font(.headline)
                            Text("多个词：全部匹配\n\"完整短语\"：连续匹配\next:pdf：限定格式\npath:课程：限定路径\n-草稿：排除词\n支持中文、拼音与首字母")
                            Divider()
                            Text("↑ ↓ 选择 · Return 打开\n⌘Return / ⌘R 定位 · ⌘Y / 空格预览\n⌘C 复制文件 · ⌘⇧C 复制路径 · Esc 收起").font(.caption)
                        }.padding(20)
                    }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).frame(height: 28)
        }
    }
}

private struct CompactResultRow: View {
    let hit: SearchHit
    let query: String
    let location: String
    let selected: Bool
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    private var hasSnippet: Bool { (hit.matchedIn.contains("正文") || hit.matchedIn.contains("标签")) && !hit.snippet.isEmpty }
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(highlightedFilename(hit.file.name, query: query, selected: selected)).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if hasSnippet {
                        Text(highlightedPreview(hit.snippet, query: query)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(location).lineLimit(1).truncationMode(.middle).frame(maxWidth: 155, alignment: .trailing).layoutPriority(1)
                    } else { Text(location).lineLimit(1).truncationMode(.middle) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                if !hit.root.isOnline { Label("未连接", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange) }
                else { Text(Date(timeIntervalSince1970: hit.file.modified).formatted(.dateTime.month().day())) }
                Text(hit.file.kind == .folder ? "文件夹" : ByteCountFormatter.string(fromByteCount: hit.file.size, countStyle: .file))
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).frame(height: 57)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor.opacity(contrast == .increased ? 0.8 : 0.28) : .clear, lineWidth: 1))
            .onHover { hovering = $0 }.help(hit.path)
            .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ResultGridCell: View {
    let hit: SearchHit
    let query: String
    let location: String
    let selected: Bool
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if hit.root.isOnline && SearchPreviewPolicy.hasContent(hit) { FileThumbnail(hit: hit) }
                else { Image(nsImage: FileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 42, height: 42).accessibilityHidden(true) }
            }.frame(maxWidth: .infinity).frame(height: 108)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            Text(highlightedFilename(hit.file.name, query: query, selected: selected, size: 12)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                if !hit.root.isOnline { Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange) }
                Text(location).lineLimit(1).truncationMode(.middle)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor.opacity(contrast == .increased ? 0.8 : 0.35) : Color.primary.opacity(0.07), lineWidth: 1))
            .onHover { hovering = $0 }.help(hit.path)
            .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(hit.root.isOnline ? "" : "磁盘未连接")
    }
}

enum FileIconCache {
    static let cache = NSCache<NSString, NSImage>()
    static func icon(_ hit: SearchHit) -> NSImage {
        let key = (hit.file.kind == .application ? hit.path : hit.file.kind.rawValue + ":" + hit.file.fileExtension) as NSString
        if let icon = cache.object(forKey: key) { return icon }
        let icon: NSImage
        if hit.file.kind == .folder { icon = NSWorkspace.shared.icon(for: .folder) }
        else if hit.file.kind == .application && hit.root.isOnline { icon = NSWorkspace.shared.icon(forFile: hit.path) }
        else { icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: hit.file.fileExtension) ?? .data) }
        icon.size = NSSize(width: 32, height: 32); cache.setObject(icon, forKey: key); return icon
    }
}
private struct SearchWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isOpaque = false; window.backgroundColor = .clear; window.isMovableByWindowBackground = true
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        }
    }
}
extension FileKind {
    var symbol: String {
        switch self {
        case .document: return "doc.text"; case .image: return "photo"; case .folder: return "folder"
        case .application: return "app"; case .code: return "curlybraces"; case .audio: return "waveform"
        case .video: return "film"; case .archive: return "archivebox"; case .other: return "doc"
        }
    }
}
