import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 1:1 复刻自 Android `TmdbNetScreen.kt`：完整 TMDB API Key (v3/v4)、双官方地址预设、明文 HTTP 安全提示、图片备用镜像、代理配置与 API/图片双连通测试。
public struct TmdbSettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var apiKey = KeychainStore.tmdbApiKey
    @State private var savedHint = false
    @State private var testingApi = false
    @State private var apiTestMsg: String?
    @State private var apiTestOk = false
    @State private var testingImg = false
    @State private var imgTestMsg: String?
    @State private var imgTestOk = false

    public init() {}

    public var body: some View {
        Form {
            Section {
                SecureField("粘贴 TMDB API Key（v3 密钥或 v4 Bearer 令牌）", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存密钥") {
                    KeychainStore.tmdbApiKey = apiKey
                    savedHint = true
                }
                if savedHint {
                    Text("已安全保存至系统 Keychain（支持自动识别 v3 api_key 与 v4 Bearer JWT）")
                        .font(.caption)
                        .foregroundStyle(MMTheme.greenOk)
                }
            } header: {
                Text("TMDB 密钥")
            } footer: {
                Text("密钥仅存于 iOS Keychain（ThisDeviceOnly），绝不写入日志或 UserDefaults。")
            }

            Section {
                TextField("API Base", text: $settings.tmdbApiBase)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack(spacing: 8) {
                    Button("api.tmdb.org（推荐）") {
                        settings.tmdbApiBase = TmdbNetConfig.altApi
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button("api.themoviedb.org") {
                        settings.tmdbApiBase = TmdbNetConfig.defaultApi
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }

                if let httpProblem = TmdbNetConfig(apiBase: settings.tmdbApiBase).apiHttpProblem() {
                    Text(httpProblem)
                        .font(.caption)
                        .foregroundStyle(MMTheme.redErr)
                }

                TextField("语言（如 zh-CN）", text: $settings.tmdbLanguage)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("API 接口地址")
            } footer: {
                Text("首选官方地址不通时，客户端会自动尝试另一个官方域名并记住本次可用线路。")
            }

            Section {
                TextField("图片主地址（默认 image.tmdb.org）", text: $settings.tmdbImageBase)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("图片备用镜像（可选，如 https://wsrv.nl/?url=）", text: $settings.tmdbImageFallback)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("官方图片不通时自动试公共镜像", isOn: $settings.tmdbPublicMirrors)
            } header: {
                Text("图片地址与镜像回退")
            } footer: {
                Text("支持前缀式镜像与以 `=` / `{url}` 结尾的转发镜像；自动校验图片魔数防劫持。")
            }

            Section("TMDB 专用代理（可选）") {
                Picker("代理类型", selection: $settings.tmdbProxyType) {
                    Text("不使用代理").tag("none")
                    Text("HTTP 代理").tag("http")
                    Text("SOCKS 代理").tag("socks")
                }
                if settings.tmdbProxyType != "none" {
                    TextField("代理主机（如 127.0.0.1）", text: $settings.tmdbProxyHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("代理端口（如 7890）", value: $settings.tmdbProxyPort, format: .number)
                        .keyboardType(.numberPad)
                        .onChange(of: settings.tmdbProxyPort) { _, newVal in
                            if newVal < 0 { settings.tmdbProxyPort = 0 }
                            else if newVal > 65535 { settings.tmdbProxyPort = 65535 }
                        }
                }
            }

            Section("连通性测试") {
                Button {
                    Task { await runApiTest() }
                } label: {
                    HStack {
                        if testingApi { ProgressView().padding(.trailing, 6) }
                        Label(testingApi ? "正在测试 API…" : "测试 TMDB API 连通性", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(testingApi)

                if let apiTestMsg {
                    Text(apiTestMsg)
                        .font(.footnote)
                        .foregroundStyle(apiTestOk ? MMTheme.greenOk : MMTheme.redErr)
                }

                Button {
                    Task { await runImageTest() }
                } label: {
                    HStack {
                        if testingImg { ProgressView().padding(.trailing, 6) }
                        Label(testingImg ? "正在测试图片下载…" : "测试海报图片与镜像回退", systemImage: "photo")
                    }
                }
                .disabled(testingImg)

                if let imgTestMsg {
                    Text(imgTestMsg)
                        .font(.footnote)
                        .foregroundStyle(imgTestOk ? MMTheme.greenOk : MMTheme.redErr)
                }
            }
        }
        .navigationTitle("TMDB 网络")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runApiTest() async {
        testingApi = true
        apiTestMsg = nil
        defer { testingApi = false }
        await TmdbNet.shared.apply(settings.tmdbNetConfig)
        let res = await TmdbClient.shared.test()
        switch res {
        case .success(let msg):
            apiTestOk = true
            apiTestMsg = msg
        case .failure(let err):
            apiTestOk = false
            apiTestMsg = err.localizedDescription
        }
    }

    private func runImageTest() async {
        testingImg = true
        imgTestMsg = nil
        defer { testingImg = false }
        await TmdbNet.shared.apply(settings.tmdbNetConfig)
        let res = await TmdbClient.shared.testImage()
        switch res {
        case .success(let msg):
            imgTestOk = true
            imgTestMsg = msg
        case .failure(let err):
            imgTestOk = false
            imgTestMsg = err.localizedDescription
        }
    }
}

/// 1:1 复刻自 Android `SettingsMoreScreens.kt`：脱敏诊断日志（2 MB 滚动落盘开关 + 错误筛选 + 合并崩溃导出）。
public struct DiagnosticLogView: View {
    @State private var settings = AppSettings.shared
    @State private var entries: [NetLog.Entry] = []
    @State private var activity = NetLog.Activity()
    @State private var onlyErrors = false
    @State private var searchQuery = ""
    @State private var showSearch = false
    @State private var exportHint: String?

    public init() {}

    private var filteredEntries: [NetLog.Entry] {
        let base = onlyErrors ? entries.filter { $0.level == "ERR" } : entries
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base.reversed() }
        return base.filter {
            $0.tag.lowercased().contains(q) || $0.message.lowercased().contains(q)
        }.reversed()
    }

    public var body: some View {
        VStack(spacing: 0) {
            CollapsibleSearchBar(text: $searchQuery, isPresented: $showSearch, prompt: "按标签或关键字搜索日志")
            List {
            Section {
                Toggle("开启 2 MB 滚动落盘日志（net.log）", isOn: $settings.netLogFileEnabled)
                if let last = activity.last, !last.isEmpty {
                    LabeledContent("最近活动", value: last)
                        .font(.caption)
                }
                if let lastErr = activity.lastError, !lastErr.isEmpty {
                    Text("最近错误：\(lastErr)")
                        .font(.caption)
                        .foregroundStyle(MMTheme.redErr)
                }
                if let exportHint {
                    Text(exportHint)
                        .font(.caption)
                        .foregroundStyle(MMTheme.greenOk)
                }
            } header: {
                Text("调试日志设置（共 \(entries.count) 条）")
            }

            Section {
                Picker("筛选", selection: $onlyErrors) {
                    Text("全部").tag(false)
                    Text("仅错误").tag(true)
                }
                .pickerStyle(.segmented)

                if filteredEntries.isEmpty {
                    ContentUnavailableView("暂无匹配日志", systemImage: "doc.text", description: Text("网络请求与错误会自动记录并脱敏。"))
                } else {
                    ForEach(filteredEntries) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(e.level)] [\(e.tag)]")
                                .font(.caption2.bold())
                                .foregroundStyle(e.level == "ERR" ? MMTheme.redErr : .secondary)
                            Text(e.message)
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSearch.toggle() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                Button("导出并复制") {
                    Task { await exportAndCopy() }
                }
                Button("清空", role: .destructive) {
                    Task {
                        await NetLog.shared.clear()
                        entries = []
                        exportHint = "日志已清空"
                    }
                }
            }
        }
        .task {
            entries = await NetLog.shared.snapshot()
            activity = await NetLog.shared.currentActivity()
        }
    }

    private func exportAndCopy() async {
        let header = "MediaMind AI iOS \(UpdateChecker.currentVersion) · Exported \(Date())"
        let outUrl = FileManager.default.temporaryDirectory.appendingPathComponent("mediamind-diagnostic.log")
        do {
            let file = try await NetLog.shared.exportTo(fileUrl: outUrl, header: header)
            let text: String
            if let loaded = try? String(contentsOf: file, encoding: .utf8) {
                text = loaded
            } else {
                text = await NetLog.shared.exportText()
            }
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #endif
            exportHint = "已合并崩溃报告并脱敏复制到剪贴板（\(AppDirs.formatSize(Int64(text.utf8.count)))）"
        } catch {
            exportHint = "导出失败：\(error.localizedDescription)"
        }
    }
}

/// 1:1 复刻自 Android `AppDirs.usage()` 缓存与存储占用管理页。
public struct StorageCacheView: View {
    @State private var usage = AppDirs.usage()
    @State private var statusHint: String?

    public init() {}

    public var body: some View {
        List {
            Section("本机磁盘占用（总计 \(AppDirs.formatSize(usage.total))）") {
                LabeledContent("TMDB 元数据缓存", value: AppDirs.formatSize(usage.tmdbCache))
                LabeledContent("海报与图片缓存", value: AppDirs.formatSize(usage.imgCache))
                LabeledContent("扫描计划文件", value: AppDirs.formatSize(usage.plans))
                LabeledContent("滚动诊断日志", value: AppDirs.formatSize(usage.logs))
                LabeledContent("历史记忆数据", value: AppDirs.formatSize(usage.history))
            }

            if let statusHint {
                Section {
                    Text(statusHint).font(.footnote).foregroundStyle(MMTheme.greenOk)
                }
            }

            Section("分项清理") {
                Button("清除 TMDB 与图片缓存") {
                    Task {
                        await TmdbClient.shared.clearCache()
                        await ArtworkFetcher.shared.clearMemoryCache()
                        await TmdbImageLoader.shared.clearCache()
                        try? FileManager.default.removeItem(at: AppDirs.imgCacheDir)
                        usage = AppDirs.usage()
                        statusHint = "已清理 TMDB 与图片缓存"
                    }
                }
                Button("清除本地扫描计划与排队") {
                    PlanAndTaskStore.shared.clearAllCache()
                    PlanStore.shared.reset()
                    TaskQueue.shared.clear()
                    usage = AppDirs.usage()
                    statusHint = "已清理本地计划与任务队列"
                }
                Button("清空全部诊断日志", role: .destructive) {
                    Task {
                        await NetLog.shared.clear()
                        CrashReporter.clear()
                        usage = AppDirs.usage()
                        statusHint = "已清空诊断日志与崩溃报告"
                    }
                }
            }
        }
        .onAppear { usage = AppDirs.usage() }
        .navigationTitle("存储与缓存")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 1:1 复刻自 Android `HistoryScreen`：已整理历史记忆管理（开关、展开明细、单条删除与清空）。
public struct HistoryManageView: View {
    @State private var store = HistoryStore.shared
    @State private var settings = AppSettings.shared
    @State private var showClearConfirm = false

    public init() {}

    public var body: some View {
        List {
            Section {
                Toggle("记住已整理的项目", isOn: Binding(
                    get: { settings.rememberHistory && store.enabled },
                    set: { on in
                        settings.rememberHistory = on
                        store.setEnabled(on)
                    }
                ))
            } footer: {
                Text("开启后，执行成功的作品目录会记住 TMDB 匹配身份，下次扫描直接复用并跳过已整理视频。")
            }

            Section("整理任务历史（\(store.runs.count)）") {
                if store.runs.isEmpty {
                    ContentUnavailableView("暂无任务历史记忆", systemImage: "clock.arrow.circlepath")
                } else {
                    ForEach(store.runs) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(run.title.isEmpty ? "整理记录" : run.title).font(.headline)
                                Spacer()
                                Text(run.provider).font(.caption2).foregroundStyle(.secondary)
                            }
                            if !run.dir.isEmpty {
                                Text("目录：\(run.dir)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("已记作品 \(run.groups.count) 部 · 动作 \(run.items.count) 项")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { idxs in
                        let ids = idxs.compactMap { store.runs.indices.contains($0) ? store.runs[$0].id : nil }
                        for id in ids { store.deleteRun(id: id) }
                    }
                }
            }

            if !store.records.isEmpty {
                Section("目录索引（\(store.records.count)）") {
                    ForEach(store.records.prefix(50)) { rec in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.matchedTitle).font(.subheadline.weight(.medium))
                            Text("\(rec.folderName) · \(rec.actionCount) 项").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idxs in
                        let ids = idxs.compactMap { store.records.indices.contains($0) ? store.records[$0].id : nil }
                        for id in ids { store.remove(id: id) }
                    }
                }
            }
        }
        .navigationTitle("历史记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.runs.isEmpty || !store.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { showClearConfirm = true }
                }
            }
        }
        .confirmationDialog("清空全部历史记忆？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("确认清空", role: .destructive) {
                store.clear()
                PlanAndTaskStore.shared.clearOrganizedFolders()
            }
            Button("取消", role: .cancel) {}
        }
    }
}

/// 1:1 复刻自 Android `UpdateChecker` 检查更新页（结构化 `UpdateResult` + 手动更新兜底链接）。
public struct UpdateCheckView: View {
    @State private var checking = false
    @State private var status = "当前版本：\(UpdateChecker.currentVersion)"
    @State private var isError = false
    @State private var release: ReleaseInfo?

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(isError ? MMTheme.redErr : .primary)
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        if checking { ProgressView().padding(.trailing, 6) }
                        Text(checking ? "正在检查 GitHub Release…" : "立即检查更新")
                    }
                }
                .disabled(checking)

                if let url = URL(string: UpdateChecker.releasesPageUrl) {
                    Link("手动更新（前往 GitHub 发布页）", destination: url)
                }
            }

            if let rel = release {
                Section("发现新版本：\(rel.tagName)") {
                    if !rel.releaseNotes.isEmpty {
                        Text(rel.releaseNotes).font(.caption)
                    }
                    if let url = URL(string: rel.htmlUrl) {
                        Link("前往此版本发布页", destination: url)
                    }
                }
            }
        }
        .navigationTitle("检查更新")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func check() async {
        checking = true
        isError = false
        release = nil
        defer { checking = false }
        let res = await UpdateChecker.check()
        switch res {
        case .available(let info):
            release = info
            status = "发现新版本：\(info.tagName)（当前 \(UpdateChecker.currentVersion)）"
        case .upToDate(let latest):
            status = "已是最新版本（当前 \(UpdateChecker.currentVersion)，最新 \(latest)）"
        case .error(let msg):
            isError = true
            status = msg
        }
    }
}
