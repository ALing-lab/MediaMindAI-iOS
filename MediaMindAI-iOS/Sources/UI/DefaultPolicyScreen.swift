import SwiftUI
import UIKit

/// 全局默认策略分类（1:1 复刻 Android `DefaultPolicyScreen` 三大类：整理策略 / 刮削策略 / 剧集策略）。
public enum PolicyCategory: String, CaseIterable, Identifiable, Sendable {
    case organize = "organize"
    case scrape = "scrape"
    case episode = "episode"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .organize: return "整理策略"
        case .scrape: return "刮削策略"
        case .episode: return "剧集策略"
        }
    }
}

/// 1:1 复刻自 Android `DefaultPolicyScreen.kt`（原生 SwiftUI 实现）：
/// - 三大策略域（整理策略 / 刮削策略 / 剧集策略）全部实时写回 `AppSettings.shared.policies`
/// - 深色实时命名预览展示卡（海报位 + 灰色「优化前」与橙色「优化后」文件夹/文件对照）
/// - 完整文件/文件夹命名偏好、附加画质音轨开关、自定义归档目标库选择器（`LibraryDestinationSheet`）
/// - 完整刮削方式、图片清晰度、电影/剧集/季/集素材开关与 `NfoFieldsSheet` 实时字段配置
/// - 「恢复本页默认值」仅重置当前策略分类，不动其他分类
public struct DefaultPolicyScreen: View {
    @State private var settings = AppSettings.shared
    @State private var category: PolicyCategory
    @State private var organizeIsTv: Bool = false
    @State private var scrapeIsTv: Bool = true
    @State private var showDestinationPicker: Bool = false
    @State private var nfoSheetTitle: String? = nil
    @State private var nfoSheetIsEpisode: Bool = false
    private enum PolicyLayerMode {
        case global
        case task
        case film(title: String, isTv: Bool, taskOverride: PolicyOverride?)
    }

    @State private var draftPolicies: DefaultPolicies
    @State private var hasOverride: Bool
    private let layerMode: PolicyLayerMode
    private let onOverrideChange: ((PolicyOverride?) -> Void)?

    private let tmdbStyles: [(value: String, label: String)] = [
        ("{tmdb-id}", "{tmdb-842675}"),
        ("[tmdb-id]", "[tmdb-842675]"),
        ("[tmdbid=id]", "[tmdbid=842675]"),
        ("tmdb-id", "tmdb-842675"),
    ]
    private let separators: [(value: String, label: String)] = [
        (" ", "空格"),
        (".", "点 (.)"),
        ("_", "下划线 (_)"),
        ("-", "短横线 (-)"),
    ]
    private let yearStyles: [(value: String, label: String)] = [
        ("(year)", "(2023)"),
        ("[year]", "[2023]"),
        ("year", "2023"),
    ]
    private let langOptions: [(value: String, label: String)] = [
        ("chinese", "优先中文"),
        ("english", "优先英语"),
        ("bilingual", "双语（中英）"),
        ("none", "无（保持原语言）"),
    ]

    public init(
        initialCategory: PolicyCategory = .organize,
        taskOverride: PolicyOverride? = nil,
        onTaskOverrideChange: ((PolicyOverride?) -> Void)? = nil
    ) {
        self._category = State(initialValue: initialCategory)
        let base = AppSettings.shared.policies
        self._draftPolicies = State(initialValue: base.applying(taskOverride))
        self._hasOverride = State(initialValue: taskOverride != nil)
        self.layerMode = onTaskOverrideChange != nil ? .task : .global
        self.onOverrideChange = onTaskOverrideChange
    }

    /// 第 3 层（影片级 · 最高优先）完整策略页：继承「任务策略 > 全局策略」，所有修改实时生成差量覆盖。
    public init(
        initialCategory: PolicyCategory = .organize,
        filmTitle: String,
        filmIsTv: Bool,
        taskOverride: PolicyOverride?,
        filmOverride: PolicyOverride?,
        onFilmOverrideChange: @escaping (PolicyOverride?) -> Void
    ) {
        let safeCategory: PolicyCategory = (!filmIsTv && initialCategory == .episode) ? .organize : initialCategory
        self._category = State(initialValue: safeCategory)
        self._organizeIsTv = State(initialValue: filmIsTv)
        self._scrapeIsTv = State(initialValue: filmIsTv)
        let base = AppSettings.shared.policies.applying(taskOverride)
        self._draftPolicies = State(initialValue: base.applying(filmOverride))
        self._hasOverride = State(initialValue: filmOverride != nil)
        self.layerMode = .film(title: filmTitle, isTv: filmIsTv, taskOverride: taskOverride)
        self.onOverrideChange = onFilmOverrideChange
    }

    private var basePoliciesForLayer: DefaultPolicies {
        switch layerMode {
        case .global:
            return settings.policies
        case .task:
            return settings.policies
        case .film(_, _, let taskOverride):
            return settings.policies.applying(taskOverride)
        }
    }

    private var isScopedOverride: Bool {
        if case .global = layerMode { return false }
        return true
    }

    private var availableCategories: [PolicyCategory] {
        if case .film(_, let isTv, _) = layerMode, !isTv {
            return [.organize, .scrape]
        }
        return PolicyCategory.allCases
    }

    private var layerFooterText: String {
        switch layerMode {
        case .global:
            return "全局策略（第 1 层）会在任务生成时同步为该任务的任务策略；任务策略、影片策略优先于全局策略。所有修改实时生效。"
        case .task:
            return "当前为任务策略（第 2 层）：仅覆盖本次识别任务，不影响全局默认设置，所有修改实时生效。"
        case .film(let title, _, let taskOverride):
            let display = title.isEmpty ? "当前作品" : "「\(title)」"
            let parentName = taskOverride != nil ? "任务策略（第 2 层）与全局策略（第 1 层）" : "全局默认策略（第 1 层）"
            return "当前为影片策略（第 3 层 · 最高优先）：仅覆盖\(display)，优先于\(parentName)，所有修改实时生效。"
        }
    }

    private var layerNavigationTitle: String {
        switch layerMode {
        case .global:
            return category.title
        case .task:
            return "任务策略"
        case .film(let title, _, _):
            return title.isEmpty ? "影片策略" : "影片策略 · \(title)"
        }
    }

    private var restoreButtonTitle: String {
        switch layerMode {
        case .global: return "恢复本页默认值"
        case .task: return "恢复继承全局策略"
        case .film(_, _, let taskOverride):
            return taskOverride != nil ? "恢复继承任务策略" : "恢复继承上层策略"
        }
    }

    private var currentPolicies: DefaultPolicies {
        isScopedOverride ? draftPolicies : settings.policies
    }

    private var policiesBinding: Binding<DefaultPolicies> {
        if isScopedOverride {
            return Binding(
                get: { draftPolicies },
                set: { updated in
                    draftPolicies = updated
                    let diff = updated.diffOverride(from: basePoliciesForLayer)
                    if diff == PolicyOverride() {
                        hasOverride = false
                        onOverrideChange?(nil)
                    } else {
                        hasOverride = true
                        onOverrideChange?(diff)
                    }
                }
            )
        }
        return $settings.policies
    }

    private var activeNamingBinding: Binding<MediaNamingPrefs> {
        organizeIsTv ? policiesBinding.tvNaming : policiesBinding.movieNaming
    }

    private var activeMediaDefaultsBinding: Binding<MediaDefaults> {
        scrapeIsTv ? policiesBinding.tv : policiesBinding.movie
    }

    public var body: some View {
        Form {
            Section {
                Picker("策略分类", selection: $category) {
                    ForEach(availableCategories) { cat in
                        Text(cat.title).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(layerFooterText)
            }

            switch category {
            case .organize:
                organizeSections
            case .scrape:
                scrapeSections
            case .episode:
                episodeSections
            }

            if isScopedOverride {
                if hasOverride {
                    Section {
                        Button(restoreButtonTitle, role: .destructive) {
                            draftPolicies = basePoliciesForLayer
                            hasOverride = false
                            onOverrideChange?(nil)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            } else {
                Section {
                    Button("恢复本页默认值", role: .destructive) {
                        resetCurrentCategory()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(layerNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDestinationPicker) {
            if let acct = AccountStore.shared.activeAccount {
                LibraryDestinationSheet(
                    accountId: acct.id,
                    sourceId: nil
                ) { folderId, displayPath in
                    policiesBinding.wrappedValue.adaptiveTargetDirId = folderId
                    policiesBinding.wrappedValue.adaptiveTargetDirPath = displayPath
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { nfoSheetTitle != nil },
            set: { if !$0 { nfoSheetTitle = nil } }
        )) {
            NfoFieldsSheet(
                title: nfoSheetTitle ?? "NFO 基础信息设置",
                isEpisode: nfoSheetIsEpisode
            )
        }
    }

    // MARK: - 1. 整理策略（命名规范 + 实时展示卡 + 自定义归档目标库）

    @ViewBuilder
    private var organizeSections: some View {
        Section {
            if !isScopedOverride {
                Toggle("启用文件与目录整理", isOn: policiesBinding.organizeEnabled)
            } else if !settings.policies.organizeEnabled {
                Label("全局「启用文件与目录整理」总开关已关闭，请在设置 → 整理与命名策略中开启。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("文件重命名", isOn: policiesBinding.renameFiles)
            Toggle("文件夹重命名", isOn: policiesBinding.renameFolders)
            Toggle("整理季目录", isOn: policiesBinding.seasonFolders)
        } header: {
            Text("整理开关")
        } footer: {
            Text("关闭季目录时，依赖该目录的移动和素材操作也会关闭。")
        }

        Section("实时命名预览") {
            if case .film = layerMode {
                EmptyView()
            } else {
                Picker("预览类型", selection: $organizeIsTv) {
                    Text("电影").tag(false)
                    Text("剧集").tag(true)
                }
                .pickerStyle(.segmented)
            }

            let prefs = organizeIsTv ? currentPolicies.tvNaming : currentPolicies.movieNaming
            VStack(spacing: 12) {
                NamingPreviewShowcaseCard(
                    categoryLabel: (organizeIsTv ? "剧集" : "电影") + "文件夹命名示例",
                    posterLetter: organizeIsTv ? "爱" : "流",
                    posterPath: organizeIsTv ? "/65VjxRnfqguutyL7LdOEQ3UcCUF.jpg" : "/tXuQCgx69DxVgeTsU0TkruR3i9O.jpg",
                    before: prefs.previewFolder(isTv: organizeIsTv, renameFolders: false),
                    after: prefs.previewFolder(isTv: organizeIsTv, renameFolders: currentPolicies.renameFolders),
                    isFolder: true
                )
                NamingPreviewShowcaseCard(
                    categoryLabel: (organizeIsTv ? "剧集" : "电影") + "文件命名示例",
                    posterLetter: organizeIsTv ? "爱" : "流",
                    posterPath: organizeIsTv ? "/65VjxRnfqguutyL7LdOEQ3UcCUF.jpg" : "/tXuQCgx69DxVgeTsU0TkruR3i9O.jpg",
                    before: prefs.previewFile(isTv: organizeIsTv, renameFiles: false),
                    after: prefs.previewFile(isTv: organizeIsTv, renameFiles: currentPolicies.renameFiles),
                    isFolder: false
                )
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        }

        if currentPolicies.renameFiles {
            Section(organizeIsTv ? "剧集文件名偏好" : "电影文件名偏好") {
                Toggle("TMDB 标签", isOn: activeNamingBinding.fileTmdbEnabled)
                if activeNamingBinding.wrappedValue.fileTmdbEnabled {
                    Picker("TMDB 标签样式", selection: activeNamingBinding.fileTmdbStyle) {
                        ForEach(tmdbStyles, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                }
                Picker("文件名分隔符", selection: activeNamingBinding.fileSeparator) {
                    ForEach(separators, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                Toggle("文件名年份", isOn: activeNamingBinding.fileYearEnabled)
                if activeNamingBinding.wrappedValue.fileYearEnabled {
                    Picker("年份样式", selection: activeNamingBinding.fileYearStyle) {
                        ForEach(yearStyles, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                }
                Picker("文件名语言偏好", selection: activeNamingBinding.fileLanguage) {
                    ForEach(langOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                Toggle("保留附加信息", isOn: activeNamingBinding.keepExtraInfo)
                if activeNamingBinding.wrappedValue.keepExtraInfo {
                    Toggle("分辨率（如 2160p、1080p）", isOn: activeNamingBinding.keepResolution)
                    Toggle("帧率（如 60fps、120fps）", isOn: activeNamingBinding.keepFps)
                    Toggle("动态范围（HDR / DV / SDR）", isOn: activeNamingBinding.keepQuality)
                    if activeNamingBinding.wrappedValue.keepQuality {
                        Toggle("缺失动态范围时默认补 SDR", isOn: activeNamingBinding.defaultSdrWhenMissing)
                    }
                    Toggle("音轨（如 TrueHD 7.1、Atmos）", isOn: activeNamingBinding.keepAudio)
                }
            }
        }

        if currentPolicies.renameFolders {
            Section(organizeIsTv ? "剧集文件夹命名偏好" : "电影文件夹命名偏好") {
                Toggle("与文件名保持一致", isOn: activeNamingBinding.folderMatchFileName)
                Toggle("TMDB 标签", isOn: activeNamingBinding.folderTmdbEnabled)
                if activeNamingBinding.wrappedValue.folderTmdbEnabled {
                    Picker("TMDB 标签样式", selection: activeNamingBinding.folderTmdbStyle) {
                        ForEach(tmdbStyles, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                }
                Picker("文件夹分隔符", selection: activeNamingBinding.folderSeparator) {
                    ForEach(separators, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                Toggle("文件夹年份", isOn: activeNamingBinding.folderYearEnabled)
                if activeNamingBinding.wrappedValue.folderYearEnabled {
                    Picker("年份样式", selection: activeNamingBinding.folderYearStyle) {
                        ForEach(yearStyles, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                }
                if !activeNamingBinding.wrappedValue.folderMatchFileName {
                    Picker("文件夹语言偏好", selection: activeNamingBinding.folderLanguage) {
                        ForEach(langOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                }
            }
        }

        Section {
            Toggle("启用自定义归档目标库", isOn: policiesBinding.adaptiveDirectory)
            if currentPolicies.adaptiveDirectory {
                Button {
                    showDestinationPicker = true
                } label: {
                    HStack {
                        Text("目标媒体库目录").foregroundStyle(.primary)
                        Spacer()
                        Text(currentPolicies.adaptiveTargetDirPath.isEmpty ? "点击选择" : currentPolicies.adaptiveTargetDirPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(AccountStore.shared.activeAccount == nil)

                if !currentPolicies.adaptiveTargetDirId.isEmpty {
                    Button("清除已选目标目录", role: .destructive) {
                        policiesBinding.wrappedValue.adaptiveTargetDirId = ""
                        policiesBinding.wrappedValue.adaptiveTargetDirPath = ""
                    }
                }
            }
            Toggle("确定重复项自动移入保留区", isOn: policiesBinding.autoMoveConfirmedDuplicates)
        } header: {
            Text("目标库归档与重复处理")
        } footer: {
            Text(AccountStore.shared.activeAccount == nil
                 ? "请先在「网盘账号」中登录一个账号，再选择自定义归档目标目录。"
                 : "开启目标库归档后，整理完成的作品将按标准分类目录归档至指定根目录；疑似重复仍默认原位保留。")
        }
    }

    // MARK: - 2. 刮削策略（模式 + 清晰度 + 电影/剧集/季/集素材 + NFO 字段）

    @ViewBuilder
    private var scrapeSections: some View {
        Section {
            if !isScopedOverride {
                Toggle("启用海报与 NFO 刮削", isOn: policiesBinding.scrapeEnabled)
            } else if !currentPolicies.scrapeEnabled {
                Label("全局「启用海报与 NFO 刮削」总开关已关闭，请在设置 → 刮削与素材策略中开启。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if currentPolicies.scrapeEnabled {
                Picker("刮削模式", selection: policiesBinding.fullScrape) {
                    Text("只刮削缺失文件").tag(false)
                    Text("完整刮削").tag(true)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("刮削文件策略")
        } footer: {
            Text(!currentPolicies.scrapeEnabled
                 ? "全局已关闭海报与 NFO 刮削，扫描与执行时仅做文件整理。"
                 : (currentPolicies.fullScrape
                    ? "重新生成所选素材，同名旧文件先备份。"
                    : "默认只补缺失项：复用历史影视匹配，仍实时检查文件是否存在。"))
        }

        if currentPolicies.scrapeEnabled {
            Section {
                Picker("图片清晰度", selection: policiesBinding.imageQuality) {
                    ForEach(ImageQualityOption.allCases, id: \.self) { q in
                        Text(q.label).tag(q)
                    }
                }
            } header: {
                Text("海报下载设置")
            } footer: {
                Text(qualityDescription(currentPolicies.imageQuality))
            }

            Section {
                if case .film = layerMode {
                    EmptyView()
                } else {
                    Picker("素材类型", selection: $scrapeIsTv) {
                        Text("剧集").tag(true)
                        Text("电影").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Toggle(scrapeIsTv ? "剧 NFO" : "电影 NFO", isOn: activeMediaDefaultsBinding.nfo)
                if activeMediaDefaultsBinding.wrappedValue.nfo {
                    Button {
                        nfoSheetTitle = scrapeIsTv ? "剧 NFO 基础信息设置" : "电影 NFO 基础信息设置"
                        nfoSheetIsEpisode = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("基础信息字段").foregroundStyle(.primary)
                                Text(selectedBasicFieldSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Toggle("海报 · poster.jpg", isOn: activeMediaDefaultsBinding.poster)
                Toggle("背景图 · fanart.jpg", isOn: activeMediaDefaultsBinding.fanart)
                Toggle("Logo 图片 · clearlogo.png", isOn: activeMediaDefaultsBinding.logo)
            } header: {
                Text(scrapeIsTv ? "剧素材设置" : "电影素材设置")
            } footer: {
                Text("已有同名文件会保留，不覆盖；只补充缺失素材。")
            }

            if scrapeIsTv {
                Section("季素材设置") {
                    Toggle("季海报", isOn: policiesBinding.seasonPoster)
                }
                Section("集素材设置") {
                    Toggle("集 NFO", isOn: policiesBinding.episodeNfo)
                    if currentPolicies.episodeNfo {
                        Button {
                            nfoSheetTitle = "集 NFO 基础信息设置"
                            nfoSheetIsEpisode = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("集基础信息字段").foregroundStyle(.primary)
                                    Text(selectedEpisodeFieldSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Toggle("集缩略图", isOn: policiesBinding.episodeThumb)
                }
            }
        }
    }

    // MARK: - 3. 剧集策略（编号策略 + 同系列归并）

    @ViewBuilder
    private var episodeSections: some View {
        Section("季集处理（默认策略）") {
            ForEach(EpisodeStrategy.allCases, id: \.self) { option in
                let isSelected = currentPolicies.episodeStrategy == option.rawValue
                Button {
                    policiesBinding.wrappedValue.episodeStrategy = option.rawValue
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(option.detailDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? MMTheme.accent : .secondary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }

        Section {
            Toggle("合并同系列（电影合集 / 同剧多季）", isOn: policiesBinding.mergeSeries)
        } header: {
            Text("同系列归并")
        } footer: {
            Text("开启后：同系列电影归并至带 {tmdb-collection-ID} 的系列目录，不同位置的同剧多季归并至主剧目录并保留实际季号。")
        }
    }

    // MARK: - 辅助方法

    private func qualityDescription(_ q: ImageQualityOption) -> String {
        switch q {
        case .original: return "最高清晰度，占用较多空间与流量"
        case .standard: return "兼顾画质与速度（推荐默认）"
        case .compact: return "较小体积，加载更快"
        }
    }

    private var selectedBasicFieldSummary: String {
        let f = settings.nfoFields
        var names: [String] = []
        if f.title { names.append("标题") }
        if f.originalTitle { names.append("原名") }
        if f.year { names.append("年份") }
        if f.rating { names.append("评分") }
        if f.plot { names.append("简介") }
        if f.aired { names.append("首映日期") }
        if f.tmdbId { names.append("TMDB ID") }
        return names.isEmpty ? "未勾选字段" : names.joined(separator: " / ")
    }

    private var selectedEpisodeFieldSummary: String {
        let f = settings.nfoFields
        var names: [String] = []
        if f.title { names.append("单集标题") }
        if f.season { names.append("季号") }
        if f.episode { names.append("集号") }
        if f.aired { names.append("播出日期") }
        if f.plot { names.append("单集简介") }
        if f.rating { names.append("评分") }
        return names.isEmpty ? "未勾选字段" : names.joined(separator: " / ")
    }

    private func resetCurrentCategory() {
        let initial = DefaultPolicies()
        switch category {
        case .episode:
            settings.policies.episodeStrategy = initial.episodeStrategy
            settings.policies.mergeSeries = initial.mergeSeries
        case .organize:
            settings.policies.organizeEnabled = initial.organizeEnabled
            settings.policies.renameFiles = initial.renameFiles
            settings.policies.renameFolders = initial.renameFolders
            settings.policies.seasonFolders = initial.seasonFolders
            settings.policies.movieNaming = .movieDefault()
            settings.policies.tvNaming = .tvDefault()
            settings.policies.adaptiveDirectory = false
            settings.policies.adaptiveTargetDirId = ""
            settings.policies.adaptiveTargetDirPath = ""
            settings.policies.autoMoveConfirmedDuplicates = false
        case .scrape:
            settings.policies.scrapeEnabled = initial.scrapeEnabled
            settings.policies.fullScrape = initial.fullScrape
            settings.policies.imageQuality = initial.imageQuality
            settings.policies.movie = initial.movie
            settings.policies.tv = initial.tv
            settings.policies.seasonPoster = initial.seasonPoster
            settings.policies.episodeNfo = initial.episodeNfo
            settings.policies.episodeThumb = initial.episodeThumb
            settings.nfoFields = NfoFieldSelection()
        }
    }
}

/// 1:1 复刻 Android `NamingPreviewShowcaseCard`：深蓝灰卡片 + 右上角示例标签 + 左侧海报占位 + 灰色「优化前」/橙色「优化后」。
private struct NamingPreviewShowcaseCard: View {
    let categoryLabel: String
    let posterLetter: String
    let posterPath: String
    let before: String
    let after: String
    let isFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Text(categoryLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(red: 0.08, green: 0.09, blue: 0.11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.60, green: 0.63, blue: 0.69))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.18, green: 0.23, blue: 0.32), Color(red: 0.08, green: 0.09, blue: 0.11)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Text(posterLetter)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    if let url = AppSettings.shared.imageUrl(path: posterPath, size: "w342") {
                        TmdbImageView(url: url, allowRetry: false, hidePlaceholderOnFailure: true)
                    }
                }
                .frame(width: 52, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("优化前：")
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.60, green: 0.63, blue: 0.69))
                        Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.79, green: 0.80, blue: 0.83))
                        Text(before)
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.79, green: 0.80, blue: 0.83))
                            .lineLimit(2)
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text("优化后：")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.22))
                        Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                            .font(.caption)
                            .foregroundStyle(Color(red: 1.0, green: 0.69, blue: 0.13))
                        Text(after)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.22))
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(red: 0.12, green: 0.14, blue: 0.18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// 1:1 复刻自 Android `LibraryDestinationSheet.kt`：云盘归档目标目录选择器（面包屑返回上一级 + 过滤源目录 + 即选即用）。
public struct LibraryDestinationSheet: View {
    public let accountId: String
    public let sourceId: String?
    public let onChoose: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var crumbs: [(id: String, name: String)] = []
    @State private var folders: [CloudEntry] = []
    @State private var loading: Bool = true
    @State private var errorMsg: String?
    @State private var drive: (any CloudDrive)?
    @State private var loadEpoch = 0

    public init(accountId: String, sourceId: String? = nil, onChoose: @escaping (String, String) -> Void) {
        self.accountId = accountId
        self.sourceId = sourceId
        self.onChoose = onChoose
    }

    private var currentFolderId: String {
        crumbs.last?.id ?? (drive?.rootId ?? "")
    }

    private var currentDisplayPath: String {
        if crumbs.count <= 1 { return "/" }
        return "/" + crumbs.dropFirst().map(\.name).joined(separator: "/")
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if crumbs.count > 1 {
                        Button {
                            crumbs.removeLast()
                            Task { await loadCurrent() }
                        } label: {
                            Label("上一级", systemImage: "chevron.left")
                                .font(.footnote.weight(.medium))
                        }
                    }
                    Text(currentDisplayPath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                if let err = errorMsg {
                    VStack(spacing: 10) {
                        Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button("重试") {
                            Task {
                                if drive == nil {
                                    await initializeDriveAndLoad()
                                } else {
                                    await loadCurrent()
                                }
                            }
                        }
                            .buttonStyle(.bordered)
                    }
                    .padding(24)
                    Spacer()
                } else if loading {
                    ProgressView("正在读取云盘目录…")
                        .padding(32)
                    Spacer()
                } else if folders.isEmpty {
                    ContentUnavailableView("当前目录下没有子文件夹", systemImage: "folder")
                } else {
                    List(folders, id: \.fileId) { folder in
                        Button {
                            crumbs.append((folder.fileId, folder.fileName))
                            Task { await loadCurrent() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(MMTheme.accent)
                                Text(folder.fileName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择目标目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择") {
                        onChoose(currentFolderId, currentDisplayPath)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(loading || errorMsg != nil || drive == nil)
                }
            }
            .task { await initializeDriveAndLoad() }
        }
    }

    private func initializeDriveAndLoad() async {
        guard let acct = AccountStore.shared.get(id: accountId) else {
            errorMsg = "找不到对应的云盘账号"
            loading = false
            return
        }
        do {
            let built = try AccountStore.shared.buildDrive(for: acct)
            drive = built
            crumbs = [(built.rootId, "根目录")]
            await loadCurrent()
        } catch {
            errorMsg = error.localizedDescription
            loading = false
        }
    }

    private func loadCurrent() async {
        guard let drive else { return }
        loadEpoch += 1
        let epoch = loadEpoch
        loading = true
        errorMsg = nil
        do {
            let list = try await drive.list(folderId: currentFolderId)
            guard epoch == loadEpoch else { return }
            folders = list.filter { $0.isDir && $0.fileId != sourceId }
            loading = false
        } catch is CancellationError {
            return
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return
        } catch {
            guard epoch == loadEpoch else { return }
            errorMsg = error.localizedDescription
            folders = []
            loading = false
        }
    }
}

/// 1:1 复刻自 Android `NfoFieldsSheet.kt`：NFO 基础信息字段两列实时勾选弹窗（即时写回 `AppSettings.shared.nfoFields`）。
public struct NfoFieldsSheet: View {
    public let title: String
    public let isEpisode: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared

    public init(title: String, isEpisode: Bool = false) {
        self.title = title
        self.isEpisode = isEpisode
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    if isEpisode {
                        fieldCard("单集标题", isOn: $settings.nfoFields.title)
                        fieldCard("季号", isOn: $settings.nfoFields.season)
                        fieldCard("集号", isOn: $settings.nfoFields.episode)
                        fieldCard("播出日期", isOn: $settings.nfoFields.aired)
                        fieldCard("单集简介", isOn: $settings.nfoFields.plot)
                        fieldCard("评分", isOn: $settings.nfoFields.rating)
                    } else {
                        fieldCard("标题", isOn: $settings.nfoFields.title)
                        fieldCard("原名", isOn: $settings.nfoFields.originalTitle)
                        fieldCard("年份", isOn: $settings.nfoFields.year)
                        fieldCard("评分", isOn: $settings.nfoFields.rating)
                        fieldCard("简介", isOn: $settings.nfoFields.plot)
                        fieldCard("首映日期", isOn: $settings.nfoFields.aired)
                        fieldCard("TMDB ID", isOn: $settings.nfoFields.tmdbId)
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func fieldCard(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn.wrappedValue ? MMTheme.accent : .secondary)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
