import SwiftUI
import UIKit

/// 设置总页及全部子页面（1:1 对标 Android SettingsScreens + DefaultPolicyScreen + NfoFields + RetentionZone + AiDiagnostics + AiSettingsScreen + TmdbNetScreen + AccountDetailScreen）。
public struct SettingsTabView: View {
    public init() {}
    @State private var settings = AppSettings.shared
    @State private var retention = RetentionZoneStore.shared
    @State private var showClearConfirm = false

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()
                TopAmbientGlow()
                List {
                Section("外观") {
                    Picker("外观主题", selection: $settings.themeMode) {
                        ForEach(AppThemeMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Section("识别与网络") {
                    NavigationLink {
                        TmdbSettingsView()
                    } label: {
                        LabeledContent("TMDB 网络与密钥", value: KeychainStore.tmdbApiKey.isEmpty ? "未配置" : "已配置")
                    }
                    NavigationLink {
                        AiSettingsView()
                    } label: {
                        LabeledContent("AI 智能识别", value: settings.aiEnabled ? AiProviderPreset.of(settings.aiProviderId).label : "关闭")
                    }
                    NavigationLink {
                        AiDiagnosticsAndRulesView()
                    } label: {
                        Text("AI 蒸馏规则与识别诊断")
                    }
                }

                Section("扫描与默认整理策略（第 1 层 · 全局）") {
                    Toggle("自动防风控限速（AIMD）", isOn: $settings.scanAutomatic)
                    NavigationLink {
                        DefaultPolicyScreen(initialCategory: .organize)
                    } label: {
                        LabeledContent("整理与命名策略", value: settings.policies.movieNaming.fileTmdbStyle)
                    }
                    NavigationLink {
                        DefaultPolicyScreen(initialCategory: .scrape)
                    } label: {
                        LabeledContent("刮削与素材策略", value: settings.policies.fullScrape ? "完整刮削" : "只补缺失")
                    }
                    NavigationLink {
                        DefaultPolicyScreen(initialCategory: .episode)
                    } label: {
                        LabeledContent("剧集与归并策略", value: settings.policies.mergeSeries ? "自动归并" : "不归并")
                    }
                    Toggle("同系列电影/多季自动归并", isOn: $settings.policies.mergeSeries)
                    Picker("图片清晰度", selection: $settings.imageQuality) {
                        ForEach(ImageQualityOption.allCases, id: \.self) { q in
                            Text(q.label).tag(q)
                        }
                    }
                }

                Section("安全与数据") {
                    NavigationLink {
                        HistoryManageView()
                    } label: {
                        LabeledContent("历史记忆", value: settings.rememberHistory ? "已开启" : "已关闭")
                    }
                    NavigationLink {
                        RetentionZoneView()
                    } label: {
                        LabeledContent("保留区（暂存待处理文件）", value: "\(retention.items.count + RetentionZoneEngine.shared.retainedRecords().count) 项")
                    }
                    NavigationLink {
                        StorageCacheView()
                    } label: {
                        LabeledContent("存储与缓存", value: AppDirs.formatSize(AppDirs.sizeBytes()))
                    }
                    NavigationLink("影视库总览") {
                        FilmLibraryView()
                    }
                    NavigationLink("诊断日志（已脱敏）") {
                        DiagnosticLogView()
                    }
                    NavigationLink("崩溃日志") {
                        CrashReportView()
                    }
                    Button("清除本地计划与缓存", role: .destructive) {
                        showClearConfirm = true
                    }
                }

                Section("关于 MediaMind AI") {
                    LabeledContent("版本", value: "\(UpdateChecker.currentVersion) (iOS)")
                    NavigationLink("开源许可与组件声明") {
                        LicensesView()
                    }
                    NavigationLink("检查版本更新") {
                        UpdateCheckView()
                    }
                }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("设置")
            .confirmationDialog("清除全部本地计划、TMDB 与图片缓存？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("确认清除", role: .destructive) {
                    PlanAndTaskStore.shared.clearAllCache()
                    PlanStore.shared.reset()
                    TaskQueue.shared.clear()
                    Task {
                        await TmdbClient.shared.clearCache()
                        await ArtworkFetcher.shared.clearMemoryCache()
                        await TmdbImageLoader.shared.clearCache()
                        try? FileManager.default.removeItem(at: AppDirs.imgCacheDir)
                        await AiRecognizerClient.shared.clearCache()
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

private struct RetentionZoneView: View {
    @State private var store = RetentionZoneStore.shared
    @State private var statusHint: String?
    @State private var busyId: String?
    @State private var missingBackupItem: RetentionItem?
    @State private var engineRecords: [RetentionZoneEngine.Record] = []
    @State private var cleanupSummary: String?

    var body: some View {
        List {
            if let statusHint {
                Section {
                    Text(statusHint).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let regErr = RetentionZoneEngine.shared.registryError() {
                Section {
                    Label(regErr, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let cleanupSummary {
                Section {
                    Text(cleanupSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !engineRecords.isEmpty {
                Section("云端分级保留区（\(engineRecords.count)）") {
                    ForEach(engineRecords) { rec in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(rec.originalName).font(.subheadline.bold())
                            Text("\(rec.workTitle) · \(rec.retentionPath)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack(spacing: 10) {
                                Button("安全还原") {
                                    Task { await restoreEngineRecord(rec) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(busyId != nil)
                                Button("核验并清理", role: .destructive) {
                                    Task { await cleanupEngineRecords([rec]) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(busyId != nil)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if store.items.isEmpty && engineRecords.isEmpty {
                ContentUnavailableView("保留区为空", systemImage: "tray", description: Text("在预览页将不确定的待确认文件移入保留区后，可在此还原或彻底清理。"))
            } else {
                ForEach(store.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.fileName).font(.subheadline.bold())
                            Spacer()
                            if busyId == item.id {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Text("\(item.provider) · \(item.reason)").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("还原至原目录") {
                                Task { await restore(item: item, fallbackParentId: nil) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busyId != nil)

                            Button("彻底清理云端", role: .destructive) {
                                Task { await deleteCloud(item: item) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busyId != nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { idxs in
                    let ids = idxs.compactMap { store.items.indices.contains($0) ? store.items[$0].id : nil }
                    for id in ids { store.remove(id: id) }
                }
            }
        }
        .onAppear { engineRecords = RetentionZoneEngine.shared.retainedRecords() }
        .navigationTitle("保留区")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空记录", role: .destructive) { store.clear() }
                }
            }
        }
        .sheet(item: $missingBackupItem) { item in
            MissingBackupChoiceSheet(
                item: item,
                onRestoreToRoot: {
                    let acct: DriveAccount? = !item.accountId.isEmpty
                        ? AccountStore.shared.get(id: item.accountId)
                        : AccountStore.shared.activeAccount
                    let rootId = acct.flatMap { try? AccountStore.shared.buildDrive(for: $0).rootId } ?? "0"
                    Task { await restore(item: item, fallbackParentId: rootId) }
                },
                onRestoreToCustom: { customId in
                    Task { await restore(item: item, fallbackParentId: customId) }
                }
            )
        }
    }

    private func resolveAccount(for accountId: String) -> DriveAccount? {
        if !accountId.isEmpty {
            return AccountStore.shared.get(id: accountId)
        }
        return AccountStore.shared.activeAccount
    }

    private func restore(item: RetentionItem, fallbackParentId: String?) async {
        guard let acct = resolveAccount(for: item.accountId),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            statusHint = "该保留项所属云盘账号已删除或不可用"
            return
        }
        busyId = item.id
        defer { busyId = nil }
        do {
            try await CloudRetentionZone.restoreFromCloud(item: item, drive: drive, fallbackParentId: fallbackParentId)
            statusHint = "已还原：\(item.fileName)"
        } catch {
            if fallbackParentId == nil {
                missingBackupItem = item
                statusHint = "原目录不可用，请选择备选还原位置"
            } else {
                statusHint = "还原失败：\(error.localizedDescription)"
            }
        }
    }

    private func restoreEngineRecord(_ rec: RetentionZoneEngine.Record) async {
        guard let acct = resolveAccount(for: rec.accountId),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            statusHint = "该保留记录所属云盘账号已删除或不可用"
            return
        }
        busyId = rec.recordId
        defer { busyId = nil }
        do {
            _ = try await RetentionZoneEngine.shared.restoreRecord(recordId: rec.recordId, drive: drive)
            engineRecords = RetentionZoneEngine.shared.retainedRecords()
            statusHint = "已安全还原：\(rec.originalName)"
        } catch {
            statusHint = "还原失败：\(error.localizedDescription)"
        }
    }

    private func cleanupEngineRecords(_ recs: [RetentionZoneEngine.Record]) async {
        guard let firstRec = recs.first else { return }
        guard let acct = resolveAccount(for: firstRec.accountId),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            statusHint = "该保留记录所属云盘账号已删除或不可用"
            return
        }
        busyId = firstRec.recordId
        defer { busyId = nil }
        let protected = RetentionZoneEngine.shared.cleanupProtectedTaskIds(records: recs)
        let checks = await RetentionZoneEngine.shared.verifyForCleanup(records: recs, drive: drive, activeTaskIds: protected)
        do {
            let outcome = try await RetentionZoneEngine.shared.cleanupVerified(checks: checks, drive: drive)
            engineRecords = RetentionZoneEngine.shared.retainedRecords()
            cleanupSummary = "清理结果（\(outcome.modeLabel)）：已清理 \(outcome.cleaned) / 跳过 \(outcome.skipped) / 失败 \(outcome.failed)"
        } catch {
            cleanupSummary = "清理中止：\(error.localizedDescription)"
        }
    }

    private func deleteCloud(item: RetentionItem) async {
        guard let acct = resolveAccount(for: item.accountId),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            statusHint = "该保留项所属云盘账号已删除或不可用"
            return
        }
        busyId = item.id
        defer { busyId = nil }
        do {
            try await CloudRetentionZone.deleteFromCloud(item: item, drive: drive)
            statusHint = "已从云端清理：\(item.fileName)"
        } catch {
            statusHint = "云端清理失败：\(error.localizedDescription)"
        }
    }
}

private struct AiDiagnosticsAndRulesView: View {
    @State private var snapshot = AiRecognitionDiagnostics.Snapshot()
    @State private var rules: [DistilledRule] = []

    var body: some View {
        List {
            Section("运行期识别诊断（7 维遥测）") {
                LabeledContent("本地蒸馏规则 0ms 命中", value: "\(snapshot.ruleHits)")
                LabeledContent("AI 磁盘/内存缓存命中", value: "\(snapshot.cacheHits)")
                LabeledContent("AI 实际触发次数", value: "\(snapshot.aiTriggers)")
                LabeledContent("AI 验证命中数", value: "\(snapshot.aiHits)")
                LabeledContent("低置信度未采纳", value: "\(snapshot.lowConfidenceMisses)")
                LabeledContent("传输/接口错误", value: "\(snapshot.transportErrors)")
                LabeledContent("单次扫盘预算耗尽", value: "\(snapshot.budgetExhausted)")
                LabeledContent("AI 平均响应耗时", value: "\(snapshot.avgLatencyMs) ms")
                Button("重置统计") {
                    Task {
                        await AiRecognitionDiagnostics.shared.reset()
                        snapshot = await AiRecognitionDiagnostics.shared.snapshot()
                    }
                }
            }
            if !snapshot.recentEvents.isEmpty {
                Section("最近事件日志（\(snapshot.recentEvents.count)）") {
                    ForEach(Array(snapshot.recentEvents.suffix(30).reversed().enumerated()), id: \.offset) { _, ev in
                        Text(ev).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            Section("本地蒸馏规则库（\(rules.count) 条）") {
                if rules.isEmpty {
                    Text("AI 识别或手动修正后会自动沉淀混淆片名规则，下次扫描零消耗直接命中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.pattern) → \(r.targetTitle)").font(.subheadline.bold())
                            Text("\(r.mediaType.uppercased())" + (r.tmdbId.map { " · TMDB \($0)" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idxs in
                        let ids = idxs.compactMap { rules.indices.contains($0) ? rules[$0].id : nil }
                        rules.removeAll { ids.contains($0.id) }
                        Task {
                            for id in ids { await AiRuleDistiller.shared.delete(id: id) }
                            rules = await AiRuleDistiller.shared.allRules()
                        }
                    }
                }
            }
        }
        .navigationTitle("AI 规则与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !rules.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空规则", role: .destructive) {
                        Task {
                            await AiRuleDistiller.shared.clear()
                            rules = []
                        }
                    }
                }
            }
        }
        .task {
            snapshot = await AiRecognitionDiagnostics.shared.snapshot()
            rules = await AiRuleDistiller.shared.allRules()
        }
    }
}

private struct AiSettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var apiKey = KeychainStore.aiApiKey
    @State private var testing = false
    @State private var testMsg: String?
    @State private var circuitErr: String?
    @State private var proxyPortText: String = AppSettings.shared.aiProxyPort > 0 ? "\(AppSettings.shared.aiProxyPort)" : ""

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 辅助识别（常规匹配未命中时兜底）", isOn: $settings.aiEnabled)
                Toggle("多候选歧义语义重排", isOn: $settings.aiEnableCandidateRerank)
                Toggle("自动蒸馏本地规则（0ms 零消耗复用）", isOn: $settings.aiEnableRuleDistillation)
                Stepper("单次扫盘 AI 预算上限：\(settings.aiMaxCallsPerScan) 次", value: $settings.aiMaxCallsPerScan, in: 1...200, step: 5)
            }

            Section("AI 服务商（支持 5 家国内直连预设）") {
                Picker("服务商", selection: $settings.aiProviderId) {
                    ForEach(AiProviderPreset.all) { p in
                        Text(p.label).tag(p.id)
                    }
                }
                .onChange(of: settings.aiProviderId) { _, newId in
                    let p = AiProviderPreset.of(newId)
                    settings.aiBaseUrl = p.defaultBaseUrl
                    settings.aiModel = p.defaultModel
                    Task { await AiRecognitionCache.shared.resetCircuit() }
                }

                TextField("接口地址", text: $settings.aiBaseUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let urlErr = AiRecognizerConfig.validateBaseUrl(settings.aiBaseUrl) {
                    Text(urlErr).font(.caption).foregroundStyle(MMTheme.redErr)
                }
                TextField("模型名称", text: $settings.aiModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key（本地 Ollama 可留空）", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, v in KeychainStore.aiApiKey = v }
            }

            Section("AI 网络代理") {
                Picker("代理模式", selection: $settings.aiProxyType) {
                    Text("直连").tag(AiRecognizerConfig.proxyNone)
                    Text("复用 TMDB 代理").tag(AiRecognizerConfig.proxyFollowTmdb)
                    Text("HTTP 代理").tag(AiRecognizerConfig.proxyHttp)
                    Text("SOCKS5 代理").tag(AiRecognizerConfig.proxySocks)
                }
                if settings.aiProxyType == AiRecognizerConfig.proxyFollowTmdb && settings.tmdbProxyType == "none" {
                    Text("当前 TMDB 未配置代理，复用模式下将直连").font(.caption).foregroundStyle(.orange)
                }
                if settings.aiProxyType == AiRecognizerConfig.proxyHttp || settings.aiProxyType == AiRecognizerConfig.proxySocks {
                    TextField("代理主机（如 127.0.0.1）", text: $settings.aiProxyHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("代理端口（如 7890）", text: $proxyPortText)
                        .keyboardType(.numberPad)
                        .onChange(of: proxyPortText) { _, v in
                            let digits = v.filter(\.isNumber)
                            if digits != v { proxyPortText = digits }
                            let port = Int(digits) ?? 0
                            settings.aiProxyPort = (1...65535).contains(port) ? port : 0
                        }
                    if settings.aiProxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(1...65535).contains(settings.aiProxyPort) {
                        Text("请填写有效的代理主机与端口（1–65535）").font(.caption).foregroundStyle(MMTheme.redErr)
                    }
                }
            }

            Section {
                Button {
                    Task {
                        testing = true
                        testMsg = nil
                        let res = await AiRecognizerClient.shared.testConnection()
                        circuitErr = await AiRecognitionCache.shared.lastError()
                        testing = false
                        switch res {
                        case .success(let ok): testMsg = ok
                        case .failure(let err): testMsg = "连接失败：\(err.localizedDescription)"
                        }
                    }
                } label: {
                    HStack {
                        if testing { ProgressView().padding(.trailing, 6) }
                        Text(testing ? "正在测试连接…" : "测试 AI 连接")
                    }
                }
                .disabled(testing || AiRecognizerConfig.validateBaseUrl(settings.aiBaseUrl) != nil || ((settings.aiProxyType == AiRecognizerConfig.proxyHttp || settings.aiProxyType == AiRecognizerConfig.proxySocks) && (settings.aiProxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(1...65535).contains(settings.aiProxyPort))))

                Button("重置熔断并清空 AI 缓存") {
                    Task {
                        await AiRecognizerClient.shared.clearCache()
                        circuitErr = nil
                        testMsg = "已重置 AI 熔断状态并清空磁盘/内存缓存"
                    }
                }

                if let circuitErr {
                    Text("最近熔断原因：\(circuitErr)").font(.caption).foregroundStyle(.orange)
                }
                if let testMsg {
                    Text(testMsg).font(.footnote).foregroundStyle(testMsg.hasPrefix("连接成功") || testMsg.hasPrefix("已重置") ? MMTheme.greenOk : MMTheme.redErr)
                }
            }
        }
        .navigationTitle("AI 智能识别")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            circuitErr = await AiRecognitionCache.shared.lastError()
        }
    }
}
