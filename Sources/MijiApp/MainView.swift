import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MijiCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var showHelp = false
    @AppStorage(SearchAppearance.storageKey) private var appearance = SearchAppearance.system
    private var expanded: Bool { !model.query.isEmpty }
    private var currentResults: Bool { model.displayedSnapshot != nil && model.displayedSnapshot == model.currentSnapshot }
    private let tabs: [FileKind?] = [nil, .folder, .application, .document, .image, .video, .audio, .code, .archive]

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if expanded {
                scopeBar
                Divider()
                HStack(spacing: 0) {
                    if model.searchPresented { results.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if model.previewVisible {
                        Divider()
                        ResultPreviewPane(model: model).frame(width: AppModel.previewWidth)
                    }
                }
                Divider()
            }
            footer
        }
        .frame(width: model.panelWidth, height: model.panelHeight)
        .modifier(PanelSurface())
        .background(SearchWindowConfiguration(appearance: appearance))
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearch) { searchFocused = true }
        .alert("觅迹", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
            TextField("搜索这台 Mac", text: $model.query)
                .font(.system(size: 26)).textFieldStyle(.plain)
                .focused($searchFocused).accessibilityLabel("搜索文件")
            HStack(spacing: 2) {
                if expanded {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary)
                    }.buttonStyle(SearchIconButtonStyle()).help("清空搜索").accessibilityLabel("清空搜索")
                }
                settingsMenu
            }
        }
        .padding(.leading, PanelMetrics.content).padding(.trailing, 13)
        .frame(height: PanelMetrics.searchHeight)
    }

    private var settingsMenu: some View {
        Menu {
            Button("索引与设置…") { AppDelegate.shared?.openSettings() }
            Divider()
            Picker("浮窗外观", selection: $appearance) {
                ForEach(SearchAppearance.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .menuStyle(.button).buttonStyle(SearchIconButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("索引、设置与浮窗外观").accessibilityLabel("索引、设置与浮窗外观")
    }

    // MARK: Scope bar: kind tabs, removable conditions, filter menu

    private var scopeBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(tabs, id: \.self) { kind in
                        ScopeTab(title: kind?.title ?? "全部", selected: model.kind == kind) { model.kind = kind }
                    }
                }.padding(.horizontal, PanelMetrics.edge)
            }.scrollIndicators(.hidden).frame(minWidth: 140)
            if !model.activeFilters.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.activeFilters.filter { $0.id != .kind }) { filter in
                        FilterToken(label: filter.label, symbol: symbol(for: filter)) { model.removeFilter(filter.id) }
                            .frame(maxWidth: filter.id == .root ? 132 : nil)
                    }
                    Button { model.resetInterfaceFilters() } label: { Text("重置").padding(.horizontal, 4).frame(height: PanelMetrics.pillHeight) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                        .help("重置界面筛选，保留搜索词与视图偏好").accessibilityLabel("重置界面筛选")
                }.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            }
            filterMenu
        }
        .padding(.trailing, 13)
        .frame(height: PanelMetrics.scopeHeight)
    }

    private func symbol(for filter: SearchFilter) -> String {
        switch filter.id {
        case .root: return model.roots.first { $0.id == model.rootID }?.isExternal == true ? "externaldrive" : "internaldrive"
        case .scope: return model.scope == .content ? "doc.text.magnifyingglass" : "doc"
        case .sort: return "arrow.up.arrow.down"
        case .onlineOnly: return "externaldrive.badge.checkmark"
        case .kind: return model.kind?.symbol ?? "doc"
        }
    }

    private var filterMenu: some View {
        let active = !model.activeFilters.isEmpty
        return Menu {
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
            Button("重置界面筛选") { model.resetInterfaceFilters() }.disabled(!active)
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 15)).foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.button).buttonStyle(SearchIconButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("搜索范围、位置与排序")
        .accessibilityLabel(active ? "筛选：\(model.activeFilters.map(\.label).joined(separator: "、"))" : "筛选")
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if model.hits.isEmpty { emptyState }
        else {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.gridEnabled {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: model.gridColumns), spacing: 12) {
                            ForEach(model.hits) { hit in
                                resultActions(ResultGridCell(hit: hit, query: model.query, location: model.resultLocation(hit).short, selected: model.selectedID == hit.id), hit: hit)
                            }
                        }.padding(12)
                    } else {
                        LazyVStack(spacing: PanelMetrics.rowSpacing) {
                            ForEach(model.hits) { hit in
                                resultActions(CompactResultRow(hit: hit, query: model.query, location: model.resultLocation(hit).short, selected: model.selectedID == hit.id), hit: hit)
                            }
                        }.padding(.horizontal, PanelMetrics.edge).padding(.vertical, PanelMetrics.listInset)
                    }
                }.opacity(currentResults ? 1 : 0.5)
                    .onChange(of: model.selectedID) { if let id = model.selectedID { proxy.scrollTo(id) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.searchStatus.phase == .searching || model.searchStatus.phase == .supplementing {
                ProgressView().controlSize(.regular).padding(.bottom, 4).accessibilityHidden(true)
            } else {
                Image(systemName: model.searchStatus.phase == .failed ? "exclamationmark.triangle" : "magnifyingglass")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 2).accessibilityHidden(true)
            }
            Text(emptyTitle).font(.system(size: 14, weight: .semibold))
            Text(emptyDetail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
            if model.searchStatus.phase == .complete && !model.activeFilters.isEmpty {
                Button("重置界面筛选") { model.resetInterfaceFilters() }.controlSize(.small).padding(.top, 4)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
    }
    private var emptyTitle: String {
        switch model.searchStatus.phase {
        case .searching, .supplementing: return "正在搜索…"
        case .failed: return "未能完成搜索"
        case .complete: return model.searchStatus.isLimited ? "暂未找到匹配项" : "当前条件下没有匹配项"
        case .idle: return "搜索文件与内容"
        }
    }
    private var emptyDetail: String {
        switch model.searchStatus.phase {
        case .searching, .supplementing: return "正在查找文件名与已索引内容"
        case .failed: return model.searchStatus.error ?? "请稍后重试。"
        default:
            if model.searchStatus.isLimited { return "仅检索了部分内容，可缩小范围" }
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
            .accessibilityAction { model.selectedID = hit.id; searchFocused = false }
            .accessibilityAction(named: Text("打开文件")) { model.performFileAction(.open, hit: hit, snapshot: snapshot) }
            .contextMenu {
                Button("打开") { model.selectedID = hit.id; model.performFileAction(.open, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("在 Finder 中显示") { model.selectedID = hit.id; model.performFileAction(.reveal, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("快速查看") { model.selectedID = hit.id; model.performFileAction(.quickLook, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Divider()
                Button("复制文件") { model.selectedID = hit.id; model.performFileAction(.copyFile, hit: hit, snapshot: snapshot) }.disabled(!hit.root.isOnline)
                Button("复制路径") { model.selectedID = hit.id; model.performFileAction(.copyPath, hit: hit, snapshot: snapshot) }
            }.id(hit.id)
    }

    // MARK: Status bar

    private var statusText: String {
        let status = model.searchStatus
        switch status.phase {
        case .searching: return "正在搜索…"
        case .supplementing: return "已找到 \(status.count) 项 · 正文检索中"
        case .failed: return "搜索未完成 · \(status.count) 项"
        case .complete:
            if status.isLimited { return "\(status.count) 项 · 仅检索了部分内容，可缩小范围" }
            return status.count == 500 ? "显示前 500 项" : "共 \(status.count) 项"
        case .idle: return "准备搜索"
        }
    }
    private var timingText: String? {
        guard let time = model.searchStatus.milliseconds, let timing = model.searchStatus.timing else { return nil }
        return "\(timing == .firstBatch ? "首批" : "完成") \(Int(time.rounded())) ms"
    }
    private var indexText: String {
        if model.paused { return "索引已暂停" }
        if model.progress.busy { return "\(model.progress.phase) · \(max(model.statistics.files, model.progress.processed).formatted()) 项" }
        return "觅迹 · \(model.statistics.files.formatted()) 个文件"
    }
    private var indexSymbol: String? {
        model.paused ? "pause.circle" : model.progress.busy ? "arrow.triangle.2.circlepath" : nil
    }

    private var footer: some View {
        HStack(spacing: 8) {
            statusLabel
            Spacer(minLength: 8)
            if expanded {
                if let symbol = indexSymbol {
                    Image(systemName: symbol).foregroundStyle(.tertiary).help(indexText).accessibilityLabel(indexText)
                }
                Text("↩ 打开   ⌘R 定位").foregroundStyle(.tertiary).accessibilityHidden(true)
                Divider().frame(height: 14).padding(.horizontal, 2)
                HStack(spacing: 2) {
                    Button { model.gridEnabled.toggle(); searchFocused = false } label: { Image(systemName: model.gridEnabled ? "list.bullet" : "square.grid.2x2") }
                        .buttonStyle(SearchIconButtonStyle()).help("切换列表／网格").accessibilityLabel("切换列表／网格")
                    previewMenu
                    Button { model.performFileAction(.quickLook) } label: { Image(systemName: "eye") }
                        .buttonStyle(SearchIconButtonStyle()).help("快速查看 · ⌘Y").accessibilityLabel("快速查看")
                    helpButton
                }
            } else {
                Text("⌃⌥Space 唤起").foregroundStyle(.tertiary)
                helpButton
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.leading, PanelMetrics.content).padding(.trailing, 13)
        .frame(height: PanelMetrics.footerHeight)
    }

    private var statusLabel: some View {
        let status = model.searchStatus
        let text = expanded ? statusText : indexText
        let spoken = [text, expanded ? timingText : nil].compactMap { $0 }.joined(separator: "，")
        return HStack(spacing: 6) {
            if expanded {
                if status.phase == .searching || status.phase == .supplementing {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else if status.phase == .failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if status.phase == .complete && status.isLimited {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
            } else if let symbol = indexSymbol {
                Image(systemName: symbol).foregroundStyle(.tertiary)
            }
            Text(text).lineLimit(1)
            if expanded, let timing = timingText {
                Text(timing).monospacedDigit().foregroundStyle(.tertiary).padding(.leading, 4)
            }
        }
        .help(expanded ? status.error ?? statusText : indexText)
        .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
    }

    private var previewMenu: some View {
        Menu {
            Picker("预览栏", selection: $model.previewMode) {
                ForEach(SearchPreviewMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
        } label: {
            Image(systemName: "sidebar.right").font(.system(size: 13))
                .foregroundStyle(model.previewVisible ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.button).buttonStyle(SearchIconButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("预览栏：\(model.previewMode.title)").accessibilityLabel("预览栏：\(model.previewMode.title)")
    }

    private var helpButton: some View {
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
    }
}

// MARK: - Scope bar pieces

/// A capsule scope item. The semibold label reserves its width, so selecting a tab never
/// shifts its neighbours.
private struct ScopeTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).hidden()
                .overlay(Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? HierarchicalShapeStyle.primary : .secondary))
                .padding(.horizontal, 11).frame(height: PanelMetrics.pillHeight)
                .background(Capsule().fill(Color.primary.opacity(selected ? (contrast == .increased ? 0.18 : 0.1) : hovering ? 0.05 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityLabel("类型：\(title)").accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A removable search condition, drawn like a macOS token: tinted capsule, leading symbol,
/// trailing remove mark. The whole token removes the condition.
private struct FilterToken: View {
    let label: String
    let symbol: String
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 9).padding(.trailing, 8).frame(height: PanelMetrics.pillHeight)
            .background(Capsule().fill(Color.accentColor.opacity(hovering ? 0.24 : 0.15)))
            .overlay { if contrast == .increased { Capsule().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(.primary).onHover { hovering = $0 }
        .help("移除条件：\(label)").accessibilityLabel("移除筛选：\(label)")
    }
}

// MARK: - Result row

/// 57 pt row: name and date share the first baseline, subtitle and size the second. The
/// subtitle is the location, or a body snippet with the location kept on its trailing side.
private struct CompactResultRow: View {
    let hit: SearchHit
    let query: String
    let location: String
    let selected: Bool
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    private var hasSnippet: Bool { (hit.matchedIn.contains("正文") || hit.matchedIn.contains("标签")) && !hit.snippet.isEmpty }
    private var offline: Bool { !hit.root.isOnline }
    private var secondary: AnyShapeStyle { selected ? AnyShapeStyle(Color.white.opacity(0.86)) : AnyShapeStyle(.secondary) }
    private var tertiary: AnyShapeStyle { selected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary) }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 32, height: 32)
                .opacity(offline ? 0.55 : 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(highlightedFilename(hit.file.name, query: query, selected: selected))
                        .font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ResultFormat.date(hit.file.modified)).monospacedDigit().lineLimit(1).foregroundStyle(secondary)
                        .frame(width: PanelMetrics.metaWidth, alignment: .trailing)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    subtitle.frame(maxWidth: .infinity, alignment: .leading)
                    Text(ResultFormat.size(hit)).monospacedDigit().lineLimit(1).foregroundStyle(tertiary)
                        .frame(width: PanelMetrics.metaWidth, alignment: .trailing)
                }
            }.font(.system(size: 11))
        }
        .padding(.horizontal, 10).frame(height: PanelMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous).fill(fill))
        .onHover { hovering = $0 }.help(hit.path)
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(offline ? "磁盘未连接" : "")
    }

    @ViewBuilder private var subtitle: some View {
        if hasSnippet {
            HStack(spacing: 10) {
                Text(highlightedSnippet(hit.snippet, query: query, selected: selected)).lineLimit(1)
                    .foregroundStyle(secondary).frame(maxWidth: .infinity, alignment: .leading)
                locationLabel.frame(maxWidth: 210, alignment: .trailing).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            }
        } else {
            locationLabel
        }
    }

    private var locationLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: offline ? "externaldrive.badge.xmark" : "folder").font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(offline && !selected ? AnyShapeStyle(Color.orange) : tertiary)
            Text(location).lineLimit(1).truncationMode(.middle).foregroundStyle(secondary)
            if offline {
                Text("未连接").fontWeight(.medium).fixedSize()
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.orange))
            }
        }
    }

    private var fill: AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(Color.primary.opacity(hovering ? (contrast == .increased ? 0.1 : 0.06) : 0))
    }
}

/// Finder icon-view cell: the thumbnail floats on the panel, selection tints the thumbnail
/// well and puts the name in an accent capsule; the short location stays under the name.
private struct ResultGridCell: View {
    let hit: SearchHit
    let query: String
    let location: String
    let selected: Bool
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    private var offline: Bool { !hit.root.isOnline }
    var body: some View {
        VStack(spacing: 7) {
            Group {
                if !offline && SearchPreviewPolicy.hasContent(hit) { FileThumbnail(hit: hit, decorated: true).padding(10) }
                else {
                    Image(nsImage: FileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 64, height: 64)
                        .opacity(offline ? 0.55 : 1).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 112)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(selected ? (contrast == .increased ? 0.2 : 0.12) : hovering ? 0.06 : 0)))
            VStack(spacing: 3) {
                Text(highlightedFilename(hit.file.name, query: query, selected: selected, size: 12))
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(selected ? Color.accentColor : Color.clear))
                HStack(spacing: 3) {
                    Image(systemName: offline ? "externaldrive.badge.xmark" : "folder").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(offline ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    Text(location).lineLimit(1).truncationMode(.middle)
                    if offline { Text("未连接").fontWeight(.medium).foregroundStyle(.orange).fixedSize() }
                }.font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 6).frame(maxWidth: .infinity)
        .onHover { hovering = $0 }.help(hit.path)
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(offline ? "磁盘未连接" : "")
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

/// Keeps the borderless panel transparent and applies the chosen panel appearance to the
/// whole window, so glass, materials and SwiftUI content resolve the same colour scheme.
private struct SearchWindowConfiguration: NSViewRepresentable {
    let appearance: SearchAppearance
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let target = appearance.windowAppearance
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isOpaque = false; window.backgroundColor = .clear; window.isMovableByWindowBackground = true
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
            if window.appearance?.name != target?.name { window.appearance = target }
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
