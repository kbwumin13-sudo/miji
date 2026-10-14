import SwiftUI
import AppKit
import MijiCore

struct SettingsView:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rootToRemove:IndexedRoot?
    private func preference(_ keyPath:WritableKeyPath<IndexingPreferences,Bool>) -> Binding<Bool> {Binding(get:{model.preferences[keyPath:keyPath]},set:{model.preferences[keyPath:keyPath]=$0;model.savePreferences()})}
    var body:some View {
        VStack(spacing:0) {
            HStack {VStack(alignment:.leading,spacing:4) {Text("索引与设置").font(.title2.weight(.semibold));Text("所有识别和搜索都在这台 Mac 上完成").foregroundStyle(.secondary).font(.callout)};Spacer();Button("完成") {AppDelegate.shared?.closeSettings()}.keyboardShortcut(.defaultAction)}.padding(22)
            Divider()
            Form {
                Section("索引位置") {
                    ForEach(model.roots) {root in
                        HStack(alignment:.top) {
                            Image(systemName:root.isExternal ? "externaldrive" : "folder").padding(.top,4)
                            VStack(alignment:.leading,spacing:5) {
                                Text(root.name).font(.headline)
                                Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if !root.isOnline {Text("未连接，已保留目录与提取内容").font(.caption).foregroundStyle(.orange)}
                                if let error=root.lastError {Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)}
                            }
                            Spacer()
                            Toggle("启用",isOn:Binding(get:{root.enabled},set:{model.setRoot(root,enabled:$0)})).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Button {rootToRemove=root} label:{Image(systemName:"minus.circle")}.buttonStyle(.borderless).help("移除此位置的索引")
                        }.padding(.vertical,5)
                    }
                    HStack {Button("添加文件夹或磁盘…") {model.addFolder()};Spacer();Button("立即更新目录") {model.service?.requestScan()}}
                }
                Section("图片与文档") {
                    Toggle("识别图片文字与内容标签",isOn:preference(\.images))
                    Toggle("提取文档全文（包括扫描 PDF）",isOn:preference(\.documents))
                    Text("扫描目录时同步分批识别图片和文档。关闭提取会保留已有结果。").font(.caption).foregroundStyle(.secondary)
                }
                Section("外置磁盘") {
                    Toggle("自动加入接入的外置磁盘",isOn:preference(\.autoAddExternal))
                    Toggle("处理外置盘上的图片",isOn:preference(\.externalImages))
                    Toggle("处理外置盘上的文档",isOn:preference(\.externalDocuments))
                    Toggle("搜索已断开磁盘的文件与内容",isOn:preference(\.retainOffline))
                    Text("未连接的文件仍能找到；打开原文件时需要重新连接磁盘。").font(.caption).foregroundStyle(.secondary)
                }
                Section("扫描范围") {
                    Toggle("包含隐藏文件",isOn:preference(\.includeHidden))
                    Toggle("跳过用户资源库与开发缓存",isOn:preference(\.excludeDevelopmentCaches))
                    Text("默认搜索整个 Mac，包括系统目录、隐藏文件和资源库。开启上方选项后才会跳过用户 Library、node_modules、.git、.build 等目录；受保护的位置需要完全磁盘访问权限。").font(.caption).foregroundStyle(.secondary)
                    Button("打开“完全磁盘访问权限”…") {NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)}
                }
                Section("索引状态") {
                    LabeledContent("当前任务",value:model.progress.phase)
                    if !model.progress.detail.isEmpty {Text(model.progress.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)}
                    if let date=model.lastProgressAt {LabeledContent("最近进展",value:date.formatted(date:.omitted,time:.standard))}
                    LabeledContent("文件",value:model.statistics.files.formatted())
                    LabeledContent("已提取内容",value:model.statistics.indexedContent.formatted())
                    LabeledContent("待提取",value:model.statistics.pending.formatted())
                    LabeledContent("提取异常",value:model.statistics.errors.formatted())
                    HStack {Button(model.paused ? "继续建立索引" : "暂停建立索引") {model.togglePause()};Spacer();Button("重新提取内容") {model.retryContent()}}
                    Text("觅迹 \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.0.1") · 全局快捷键 ⌃⌥Space\n索引保存在 ~/Library/Application Support/Miji").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.frame(width:720,height:650)
        .confirmationDialog("移除「\(rootToRemove?.name ?? "")」的索引？",isPresented:Binding(get:{rootToRemove != nil},set:{if !$0 {rootToRemove=nil}})) {
            Button("移除索引",role:.destructive) {if let root=rootToRemove {model.removeRoot(root)};rootToRemove=nil}
            Button("取消",role:.cancel) {rootToRemove=nil}
        } message:{Text("只删除觅迹保存的目录与提取内容，原文件保留。")}
    }
}
