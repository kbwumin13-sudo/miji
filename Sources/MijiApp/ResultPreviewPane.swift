import SwiftUI
import MijiCore

struct ResultPreviewPane: View {
    @ObservedObject var model: AppModel
    @State private var indexedExpanded = false

    var body: some View {
        Group {
            if let hit = model.selected {
                let availability = model.resultAvailability(hit)
                let snapshot = model.displayedSnapshot
                VStack(alignment: .leading, spacing: 12) {
                    header(hit, availability: availability)
                    Divider()
                    HStack {
                        Label("匹配：\(hit.matchedIn)", systemImage: "magnifyingglass")
                        Spacer()
                        if let page = model.previewPage {
                            Button("第 \(page) 页 ↗") { AppDelegate.shared?.showPDFMatch() }
                                .disabled(model.previewPDF == nil).buttonStyle(.plain).help("打开匹配页")
                        } else if let line = model.previewLine { Text("第 \(line) 行") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    notices(availability)
                    content(hit).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(hit.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(hit.path)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.performFileAction(.copyPath, hit: hit, snapshot: snapshot) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(SearchIconButtonStyle()).help("复制完整路径").accessibilityLabel("复制完整路径")
                    }
                }.padding(16)
            } else {
                Text("选择文件查看预览").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.selectedID) { indexedExpanded = false }
    }

    private func header(_ hit: SearchHit, availability: ResultAvailability) -> some View {
        let snapshot = model.displayedSnapshot
        let originalUnavailable = availability.state == .diskOffline || availability.state == .fileUnavailable
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: FileIconCache.icon(hit)).resizable().scaledToFit().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.file.name).font(.system(size: 15, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text("\(hit.file.kind.title) · \(hit.file.kind == .folder ? "文件夹" : ByteCountFormatter.string(fromByteCount: hit.file.size, countStyle: .file)) · \(Date(timeIntervalSince1970: hit.file.modified).formatted(.dateTime.year().month().day()))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { model.performFileAction(.open, hit: hit, snapshot: snapshot) } label: { Label("打开", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent)
                Button { model.performFileAction(.reveal, hit: hit, snapshot: snapshot) } label: { Label("定位", systemImage: "folder") }
                    .help("在 Finder 中显示")
                Button { model.performFileAction(.copyFile, hit: hit, snapshot: snapshot) } label: { Label("复制", systemImage: "doc.on.doc") }
                    .help("复制文件").accessibilityLabel("复制文件")
                Spacer(minLength: 0)
                Button { model.performFileAction(.quickLook, hit: hit, snapshot: snapshot) } label: { Image(systemName: "eye") }
                    .help("快速查看 · ⌘Y").accessibilityLabel("快速查看")
            }.controlSize(.small).disabled(originalUnavailable || !model.isCurrentResult(hit))
                .help(availability.message ?? "打开或定位原文件，也可复制文件")
        }
    }

    @ViewBuilder private func notices(_ availability: ResultAvailability) -> some View {
        if availability.message != nil || availability.contentMessage != nil {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: availability.state == .diskOffline ? "externaldrive.badge.exclamationmark" : "exclamationmark.circle")
                    .foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if let message = availability.message { Text(message).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true) }
                    if availability.state == .fileUnavailable && !model.previewText.isEmpty {
                        Text("仍可阅读已索引内容，或复制原路径。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let warning = availability.contentMessage {
                        ScrollView { Text(warning).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(maxHeight: 40)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func content(_ hit: SearchHit) -> some View {
        if model.previewLoading {
            ProgressView("正在载入预览…").controlSize(.small).font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !SearchPreviewPolicy.hasContent(hit) {
            VStack(alignment: .leading, spacing: 8) {
                Text(metadataHint(hit)).font(.callout).foregroundStyle(.secondary)
                if !hit.snippet.isEmpty { Text(highlightedPreview(hit.snippet, query: model.query)).font(.callout).textSelection(.enabled) }
            }
        } else if SearchPreviewPolicy.usesTextReader(hit) && !model.previewText.isEmpty {
            textContent(hit)
        } else if let document = model.previewPDF {
            VStack(spacing: 8) {
                PDFDocumentPreview(document: document, page: model.previewPage, terms: PreviewResolver.terms(in: model.query))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                indexedDisclosure(hit)
            }
        } else if let url = model.previewLocalURL, hit.file.kind == .image || hit.file.kind == .audio || hit.file.kind == .video || SearchPreviewPolicy.usesSystemPreview(hit, hasIndexedText: !model.previewText.isEmpty) {
            VStack(spacing: 8) {
                Group {
                    if hit.file.kind == .image { FileThumbnail(hit: hit, pixels: 800, showsStatus: true) }
                    else if hit.file.kind == .audio || hit.file.kind == .video { MediaFilePreview(hit: hit, authorize: { model.fileOperationURL(for:hit,action:.preview) }).id(hit.path) }
                    else { SystemFilePreview(url: url) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                indexedDisclosure(hit)
            }
        } else if !model.previewText.isEmpty {
            textContent(hit)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("暂无可显示的预览").font(.callout)
                Text(hit.root.isOnline ? "可使用快速查看，或打开原文件。" : "重新连接磁盘后可查看原文件。").font(.caption).foregroundStyle(.secondary)
                if !hit.labels.isEmpty { Text(hit.labels).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
    }

    private func textContent(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已索引内容").font(.system(size: 10)).foregroundStyle(.secondary)
            ScrollView(hit.file.kind == .code ? [.horizontal, .vertical] : .vertical) {
                Text(highlightedPreview(model.previewText, query: model.query))
                    .font(hit.file.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    @ViewBuilder private func indexedDisclosure(_ hit: SearchHit) -> some View {
        if !model.previewText.isEmpty || !hit.labels.isEmpty {
            DisclosureGroup("已索引文字与标签", isExpanded: $indexedExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(highlightedPreview(model.previewText, query: model.query)).textSelection(.enabled)
                        if !hit.labels.isEmpty { Text(hit.labels).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.frame(maxHeight: 110)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func metadataHint(_ hit: SearchHit) -> String {
        switch hit.file.kind {
        case .application: return "应用可直接打开，或在 Finder 中查看。"
        case .folder: return "在 Finder 中浏览此文件夹。"
        case .archive: return "打开原文件查看压缩包或磁盘映像内容。"
        default: return "可打开原文件，或使用快速查看。"
        }
    }
}
