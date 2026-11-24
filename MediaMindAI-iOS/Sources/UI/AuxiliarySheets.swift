import SwiftUI

/// 1:1 复刻自 Android `LibraryScrapeAssets.kt`：单部作品 NFO 与图片素材自定义细选弹窗。
public struct LibraryScrapeAssetsSheet: View {
    public let title: String
    public let isTv: Bool
    public let initial: PolicyOverride?
    public let fallback: EffectivePolicy
    public let onSave: (PolicyOverride) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var writeNfo = true
    @State private var downloadPoster = true
    @State private var downloadFanart = false
    @State private var downloadClearlogo = false
    @State private var downloadEpisodeThumb = false

    public init(title: String, isTv: Bool, initial: PolicyOverride?, fallback: EffectivePolicy, onSave: @escaping (PolicyOverride) -> Void) {
        self.title = title
        self.isTv = isTv
        self.initial = initial
        self.fallback = fallback
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("《\(title)》素材勾选") {
                    Toggle("写入 NFO 元数据", isOn: $writeNfo)
                    Toggle("下载海报（poster.jpg）", isOn: $downloadPoster)
                    Toggle("下载背景图（fanart.jpg）", isOn: $downloadFanart)
                    Toggle("下载透明 Logo（clearlogo.png）", isOn: $downloadClearlogo)
                    if isTv {
                        Toggle("下载单集剧照（-thumb.jpg）", isOn: $downloadEpisodeThumb)
                    }
                }
            }
            .navigationTitle("自定义刮削素材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var ov = initial ?? PolicyOverride()
                        ov.writeNfo = writeNfo
                        ov.downloadPoster = downloadPoster
                        ov.downloadFanart = downloadFanart
                        ov.downloadClearlogo = downloadClearlogo
                        if isTv { ov.downloadEpisodeThumb = downloadEpisodeThumb }
                        onSave(ov)
                        dismiss()
                    }
                }
            }
            .onAppear {
                writeNfo = initial?.writeNfo ?? fallback.writeNfo
                downloadPoster = initial?.downloadPoster ?? fallback.downloadPoster
                downloadFanart = initial?.downloadFanart ?? fallback.downloadFanart
                downloadClearlogo = initial?.downloadClearlogo ?? fallback.downloadClearlogo
                downloadEpisodeThumb = initial?.downloadEpisodeThumb ?? fallback.downloadEpisodeThumb
            }
        }
    }
}

/// 1:1 复刻自 Android `MissingBackupChoiceSheet.kt`：保留区还原时原父目录不存在时的备选目标选择弹窗。
public struct MissingBackupChoiceSheet: View {
    public let item: RetentionItem
    public let onRestoreToRoot: () -> Void
    public let onRestoreToCustom: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customFolderId = ""

    public init(item: RetentionItem, onRestoreToRoot: @escaping () -> Void, onRestoreToCustom: @escaping (String) -> Void) {
        self.item = item
        self.onRestoreToRoot = onRestoreToRoot
        self.onRestoreToCustom = onRestoreToCustom
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("原目录（\(item.originalParentId.isEmpty ? "未知" : item.originalParentId)）在云端已不存在或无法访问，请选择新的还原位置。")) {
                    Text(item.fileName).font(.headline)
                }
                Section("备选还原位置") {
                    Button("还原到云盘根目录") {
                        onRestoreToRoot()
                        dismiss()
                    }
                    TextField("或输入目标目录 ID / WebDAV 路径", text: $customFolderId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("还原到指定目录") {
                        let clean = customFolderId.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return }
                        onRestoreToCustom(clean)
                        dismiss()
                    }
                    .disabled(customFolderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("原目录缺失")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
}

/// 开源许可证与第三方组件合规展示页（加载随包打包的 `Resources/licenses/` 文本）。
public struct LicensesView: View {
    @State private var files: [(name: String, content: String)] = []

    public init() {}

    public var body: some View {
        List {
            if files.isEmpty {
                Section("GNU GPL v3.0") {
                    Text("MediaMind AI 基于 GNU General Public License v3.0 开源发布。完整许可证文本已随工程打包于 Resources/licenses/。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(files, id: \.name) { f in
                    NavigationLink(f.name) {
                        ScrollView {
                            Text(f.content)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle(f.name)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .navigationTitle("开源许可与组件声明")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadLicenses() }
    }

    private func loadLicenses() {
        guard files.isEmpty, let dir = Bundle.main.resourceURL?.appendingPathComponent("licenses") else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        files = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { u in
            guard let txt = try? String(contentsOf: u, encoding: .utf8) else { return nil }
            return (u.lastPathComponent, txt)
        }
    }
}
