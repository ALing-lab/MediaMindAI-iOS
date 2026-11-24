import SwiftUI
import UIKit

/// 传给手动修正匹配页的一个待修正目标（单个文件或一个文件夹分组，1:1 复刻 Android `MatchTargetGroup`）。
public struct MatchTargetGroup: Identifiable, Hashable, Sendable {
    public struct FileItem: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public let key: String
    public let folderPath: String
    public let actionIds: [String]
    public let files: [FileItem]
    public let sampleFileName: String
    public let suggestedSeason: Int?
    public let suggestedYear: String
    public let suggestedEpisode: Int?
    public let suggestedSeriesIndex: String

    public var id: String { key }

    public init(
        key: String,
        folderPath: String,
        actionIds: [String],
        files: [FileItem] = [],
        sampleFileName: String = "",
        suggestedSeason: Int? = nil,
        suggestedYear: String = "",
        suggestedEpisode: Int? = nil,
        suggestedSeriesIndex: String = ""
    ) {
        self.key = key
        self.folderPath = folderPath
        self.actionIds = actionIds
        self.files = files
        self.sampleFileName = sampleFileName
        self.suggestedSeason = suggestedSeason
        self.suggestedYear = suggestedYear
        self.suggestedEpisode = suggestedEpisode
        self.suggestedSeriesIndex = suggestedSeriesIndex
    }
}

private struct GroupInputState: Equatable {
    var season: String = ""
    var year: String = ""
    var episode: String = ""
    var seriesIndex: String = ""
}

/// 1:1 复刻自 Android `ManualMatchSheet.kt`（原生 SwiftUI 实现）：
/// - 支持电影 / 剧集与综艺切换、片名 + 4 位年份或直接输入 TMDB ID 搜索
/// - 单个剧集文件纠错：支持季号（0–99）与集号（留空按文件名 SxxExx）
/// - 批量多文件 / 多文件夹联合纠错：按分组独立设置季号（剧集）或整组序号 + 年份 + 可展开逐文件「第几部」（电影）
/// - 实时校验输入合法性，确认后回传 `(MatchInfo, [GroupMatchOverride])` 交由 `Scanner.replanTargetGroups` 重规划
public struct ManualMatchSheet: View {
    public let initialQuery: String
    public let initialKind: String
    public let initialYear: String
    public let applying: Bool
    public let applyError: String?
    public let needsEpisode: Bool
    public let initialSeason: Int?
    public let initialEpisode: Int?
    public let targetGroups: [MatchTargetGroup]
    public let onEpisode: (Int?, Int?) -> Void
    public let onApply: (MatchInfo) -> Void
    public let onApplyGroups: ((MatchInfo, [GroupMatchOverride]) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var kind: String = "movie"
    @State private var year: String = ""
    @State private var busy: Bool = false
    @State private var searched: Bool = false
    @State private var results: [MatchInfo] = []
    @State private var selected: MatchInfo?
    @State private var errorText: String?

    @State private var legacySeason: String = ""
    @State private var legacyEpisode: String = ""
    @State private var groupInputs: [String: GroupInputState] = [:]
    @State private var fileSeriesInputs: [String: String] = [:]
    @State private var expandedMovieGroups: Set<String> = []
    @State private var initialized: Bool = false

    public init(
        initialQuery: String,
        initialKind: String,
        initialYear: String = "",
        applying: Bool = false,
        applyError: String? = nil,
        needsEpisode: Bool = false,
        initialSeason: Int? = nil,
        initialEpisode: Int? = nil,
        targetGroups: [MatchTargetGroup] = [],
        onEpisode: @escaping (Int?, Int?) -> Void = { _, _ in },
        onApply: @escaping (MatchInfo) -> Void = { _ in },
        onApplyGroups: ((MatchInfo, [GroupMatchOverride]) -> Void)? = nil
    ) {
        self.initialQuery = initialQuery
        self.initialKind = initialKind
        self.initialYear = initialYear
        self.applying = applying
        self.applyError = applyError
        self.needsEpisode = needsEpisode
        self.initialSeason = initialSeason
        self.initialEpisode = initialEpisode
        self.targetGroups = targetGroups
        self.onEpisode = onEpisode
        self.onApply = onApply
        self.onApplyGroups = onApplyGroups
    }

    private var useGroupMode: Bool {
        !targetGroups.isEmpty && onApplyGroups != nil
    }

    private var totalFiles: Int {
        targetGroups.reduce(0) { $0 + $1.actionIds.count }
    }

    private var isSingleFileMode: Bool {
        useGroupMode && targetGroups.count == 1 && totalFiles == 1
    }

    private var validInputs: Bool {
        if useGroupMode {
            return targetGroups.allSatisfy { g in
                let st = groupInputs[g.key] ?? GroupInputState()
                let seasonOk = st.season.isEmpty || (Int(st.season).map { (0...99).contains($0) } ?? false)
                let episodeOk = !isSingleFileMode || kind != "tv" || st.episode.isEmpty || ((Int(st.episode) ?? 0) > 0)
                let indexOk = kind != "movie" || st.seriesIndex.isEmpty || ((Int(st.seriesIndex) ?? 0) > 0)
                let yearOk = st.year.isEmpty || st.year.count == 4
                return seasonOk && episodeOk && indexOk && yearOk
            }
        } else {
            guard needsEpisode && kind == "tv" else { return true }
            let sOk = legacySeason.isEmpty || (Int(legacySeason).map { (0...99).contains($0) } ?? false)
            let eOk = legacyEpisode.isEmpty || ((Int(legacyEpisode) ?? 0) > 0)
            return sOk && eOk
        }
    }

    private var groupHeaderHint: String {
        if isSingleFileMode && kind == "tv" {
            return "单集参数设置（季号与集号均选填；集号留空则以文件名 S0XE0X 为准）"
        }
        if isSingleFileMode {
            return "单文件参数设置（年份与系列序号均选填）"
        }
        if targetGroups.count > 1 && kind == "tv" {
            return "各分组独立设置（共 \(targetGroups.count) 组，可为每组单独填季号，同剧将自动整理到一起）"
        }
        if targetGroups.count > 1 {
            return "各分组独立设置（共 \(targetGroups.count) 组，可为每组单独填系列序号与年份）"
        }
        if kind == "tv" {
            return "分组参数设置（批量多集不支持填集号，可填季号，留空按文件名）"
        }
        return "系列电影整夹匹配：留空则自动按合集/年份一次性匹配夹内全部电影"
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部类型切换 + 搜索栏
                VStack(spacing: 10) {
                    Picker("类型", selection: $kind) {
                        Text("剧集 / 综艺").tag("tv")
                        Text("电影").tag("movie")
                    }
                    .pickerStyle(.segmented)
                    .disabled(busy || applying)
                    .onChange(of: kind) { _, _ in
                        selected = nil
                        results = []
                        searched = false
                    }

                    HStack(spacing: 8) {
                        TextField(kind == "tv" ? "剧名 / 综艺名或 TMDB ID" : "电影名 / 系列名或 TMDB ID", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .disabled(busy || applying)
                            .onSubmit { Task { await runSearch() } }

                        TextField("年份", text: Binding(
                            get: { year },
                            set: { year = String($0.filter(\.isNumber).prefix(4)) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 74)
                        .disabled(busy || applying)

                        Button {
                            Task { await runSearch() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                Text(busy ? "搜索中" : "搜索")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || applying || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if !useGroupMode && needsEpisode && kind == "tv" {
                        HStack(spacing: 8) {
                            TextField("季号（留空自动）", text: Binding(
                                get: { legacySeason },
                                set: { legacySeason = String($0.filter(\.isNumber).prefix(2)) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .disabled(applying)

                            TextField("集号（留空按 SxxExx）", text: Binding(
                                get: { legacyEpisode },
                                set: { legacyEpisode = String($0.filter(\.isNumber).prefix(5)) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .disabled(applying)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // 可滚动主体：分组独立参数 + TMDB 搜索结果
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if useGroupMode {
                            Text(groupHeaderHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)

                            ForEach(targetGroups) { grp in
                                groupOverrideCard(grp)
                            }
                        }

                        Text("搜索结果（TMDB 信息），请选择：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        if busy {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在搜索 TMDB…").font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        } else if results.isEmpty {
                            Text(searched ? "没有找到匹配结果，请调整片名、类型或年份，也可直接输入 TMDB 数字 ID。" : "搜索后选择正确的影视条目。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(results, id: \.id) { info in
                                resultRow(info)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                // 底部错误提示与确认按钮
                VStack(spacing: 8) {
                    if let err = applyError ?? errorText, !err.isEmpty {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        confirmSelection()
                    } label: {
                        Text(applying ? "重新规划中…" : "确认修正匹配结果")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || applying || busy || !validInputs)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .navigationTitle(useGroupMode && targetGroups.count > 1 ? "联合修正匹配（\(targetGroups.count) 个分组）" : "修正匹配信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(applying)
                }
            }
            .onAppear { setupInitialState() }
        }
    }

    @ViewBuilder
    private func groupOverrideCard(_ grp: MatchTargetGroup) -> some View {
        let stateBinding = Binding<GroupInputState>(
            get: { groupInputs[grp.key] ?? GroupInputState() },
            set: { groupInputs[grp.key] = $0 }
        )

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(MMTheme.accent)
                Text(grp.folderPath.isEmpty ? "未记录目录" : grp.folderPath)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(grp.actionIds.count) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isSingleFileMode && !grp.sampleFileName.isEmpty {
                Text(grp.sampleFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                if kind == "tv" {
                    TextField("季号（自动）", text: Binding(
                        get: { stateBinding.wrappedValue.season },
                        set: { var s = stateBinding.wrappedValue; s.season = String($0.filter(\.isNumber).prefix(2)); stateBinding.wrappedValue = s }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .disabled(applying)

                    if isSingleFileMode {
                        TextField("集号（SxxExx）", text: Binding(
                            get: { stateBinding.wrappedValue.episode },
                            set: { var s = stateBinding.wrappedValue; s.episode = String($0.filter(\.isNumber).prefix(5)); stateBinding.wrappedValue = s }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .disabled(applying)
                    }
                } else {
                    TextField("整组序号（自动）", text: Binding(
                        get: { stateBinding.wrappedValue.seriesIndex },
                        set: { var s = stateBinding.wrappedValue; s.seriesIndex = String($0.filter(\.isNumber).prefix(2)); stateBinding.wrappedValue = s }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .disabled(applying)

                    TextField("年份（选填）", text: Binding(
                        get: { stateBinding.wrappedValue.year },
                        set: { var s = stateBinding.wrappedValue; s.year = String($0.filter(\.isNumber).prefix(4)); stateBinding.wrappedValue = s }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .disabled(applying)
                }
            }

            if kind == "movie" && !grp.files.isEmpty {
                let isExpanded = expandedMovieGroups.contains(grp.key)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedMovieGroups.remove(grp.key)
                        } else {
                            expandedMovieGroups.insert(grp.key)
                        }
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "收起文件分配列表（可按文件输入第几部，留空自动）" : "展开文件分配列表（\(grp.files.count) 个文件 · 可手动填第几部）")
                            .font(.caption)
                            .foregroundStyle(MMTheme.accent)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(MMTheme.accent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 6) {
                        ForEach(grp.files) { file in
                            HStack(spacing: 8) {
                                Text(file.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("第几部", text: Binding(
                                    get: { fileSeriesInputs[file.id] ?? "" },
                                    set: { fileSeriesInputs[file.id] = String($0.filter(\.isNumber).prefix(2)) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numberPad)
                                .frame(width: 78)
                                .disabled(applying)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func resultRow(_ info: MatchInfo) -> some View {
        let isSelected = selected?.id == info.id && selected?.kind == info.kind
        Button {
            selected = info
        } label: {
            HStack(alignment: .top, spacing: 12) {
                TmdbImageView(
                    url: info.posterPath.flatMap { AppSettings.shared.imageUrl(path: $0, size: "w185") },
                    placeholderSystemName: info.kind == "tv" ? "tv" : "film",
                    allowRetry: false
                )
                .frame(width: 54, height: 80)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text("\(info.year.isEmpty ? "年份未知" : info.year) · TMDB \(info.id)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !info.overview.isEmpty {
                        Text(info.overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? MMTheme.accent : .secondary)
                    .padding(.top, 4)
            }
            .padding(10)
            .background(isSelected ? MMTheme.accent.opacity(0.08) : Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? MMTheme.accent : Color(uiColor: .separator).opacity(0.35), lineWidth: isSelected ? 1.2 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(applying)
    }

    private func setupInitialState() {
        guard !initialized else { return }
        initialized = true
        query = initialQuery
        kind = (initialKind == "tv") ? "tv" : "movie"
        year = String(initialYear.filter(\.isNumber).prefix(4))
        legacySeason = initialSeason.map { "\($0)" } ?? ""
        legacyEpisode = initialEpisode.map { "\($0)" } ?? ""

        var initGroups: [String: GroupInputState] = [:]
        for g in targetGroups {
            initGroups[g.key] = GroupInputState(
                season: g.suggestedSeason.map { "\($0)" } ?? "",
                year: g.suggestedYear,
                episode: isSingleFileMode ? (g.suggestedEpisode.map { "\($0)" } ?? "") : "",
                seriesIndex: g.suggestedSeriesIndex
            )
        }
        groupInputs = initGroups
        if targetGroups.count == 1, let first = targetGroups.first, first.files.count > 1 {
            expandedMovieGroups = [first.key]
        }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        selected = nil
        errorText = nil
        defer { busy = false; searched = true }

        // 支持直接输入纯数字或 tmdb-12345 精确反查
        let lower = trimmed.lowercased()
        let directIdStr: String?
        if lower.hasPrefix("tmdb-") || lower.hasPrefix("tmdb:") || lower.hasPrefix("tmdb=") {
            directIdStr = String(lower.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.allSatisfy(\.isNumber) && trimmed.count >= 2 {
            directIdStr = trimmed
        } else {
            directIdStr = nil
        }

        if let idStr = directIdStr, let tmdbId = Int(idStr), tmdbId > 0 {
            let hit = (kind == "tv") ? await TmdbClient.shared.tvDetails(id: tmdbId) : await TmdbClient.shared.movieDetails(id: tmdbId)
            if let hit {
                results = [hit]
                selected = hit
                return
            }
        }

        let yearInt = year.count == 4 ? Int(year) : nil
        results = (kind == "tv")
            ? await TmdbClient.shared.searchTv(query: trimmed, year: yearInt)
            : await TmdbClient.shared.searchMovie(query: trimmed, year: yearInt)
    }

    private func confirmSelection() {
        guard let chosen = selected else { return }
        if useGroupMode, let onApplyGroups {
            let overrides = targetGroups.map { g -> GroupMatchOverride in
                let st = groupInputs[g.key] ?? GroupInputState()
                var fileMap: [String: Int] = [:]
                if kind == "movie" {
                    for f in g.files {
                        if let idx = Int(fileSeriesInputs[f.id] ?? ""), idx > 0 {
                            fileMap[f.id] = idx
                        }
                    }
                }
                return GroupMatchOverride(
                    key: g.key,
                    actionIds: g.actionIds,
                    season: kind == "tv" ? Int(st.season) : nil,
                    episode: (isSingleFileMode && kind == "tv") ? Int(st.episode) : nil,
                    year: st.year.trimmingCharacters(in: .whitespacesAndNewlines),
                    seriesIndex: kind == "movie" ? Int(st.seriesIndex) : nil,
                    fileSeriesIndices: fileMap
                )
            }
            onApplyGroups(chosen, overrides)
        } else {
            onEpisode(kind == "tv" ? Int(legacySeason) : nil, kind == "tv" ? Int(legacyEpisode) : nil)
            onApply(chosen)
        }
    }
}

/// 1:1 复刻自 Android `EpisodeStrategySheet.kt`：剧集集序策略与 TMDB 剧集组即点即用选择器。
public struct EpisodeStrategySheet: View {
    public let current: EpisodeStrategy
    public let applying: Bool
    public let error: String?
    public let episodeGroups: [TmdbEpisodeGroupSummary]
    public let selectedEpisodeGroupId: String?
    public let onConfirm: (EpisodeStrategy) -> Void
    public let onSelectEpisodeGroup: ((String?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var picked: EpisodeStrategy

    public init(
        current: EpisodeStrategy,
        applying: Bool = false,
        error: String? = nil,
        episodeGroups: [TmdbEpisodeGroupSummary] = [],
        selectedEpisodeGroupId: String? = nil,
        onConfirm: @escaping (EpisodeStrategy) -> Void,
        onSelectEpisodeGroup: ((String?) -> Void)? = nil
    ) {
        self.current = current
        self.applying = applying
        self.error = error
        self.episodeGroups = episodeGroups
        self.selectedEpisodeGroupId = selectedEpisodeGroupId
        self.onConfirm = onConfirm
        self.onSelectEpisodeGroup = onSelectEpisodeGroup
        self._picked = State(initialValue: current)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(EpisodeStrategy.allCases, id: \.self) { option in
                        Button {
                            if option != picked {
                                picked = option
                                onConfirm(option)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.label)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(option.detailDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: picked == option ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked == option ? MMTheme.accent : .secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(applying)
                    }
                } header: {
                    Text("剧集编号策略")
                }

                if !episodeGroups.isEmpty, let onSelectEpisodeGroup {
                    Section("剧集组（TMDB Episode Groups）") {
                        Button {
                            onSelectEpisodeGroup(nil)
                        } label: {
                            HStack {
                                Text("默认播出顺序").foregroundStyle(.primary)
                                Spacer()
                                if selectedEpisodeGroupId == nil {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(MMTheme.accent)
                                }
                            }
                        }
                        .disabled(applying)

                        ForEach(episodeGroups, id: \.id) { grp in
                            Button {
                                onSelectEpisodeGroup(grp.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(grp.name).foregroundStyle(.primary)
                                        if grp.groupCount > 0 || grp.episodeCount > 0 {
                                            Text("\(grp.groupCount) 组 · \(grp.episodeCount) 集")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedEpisodeGroupId == grp.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(MMTheme.accent)
                                    }
                                }
                            }
                            .disabled(applying)
                        }
                    }
                }

                Section {
                    Text(error ?? (applying ? "正在重新生成当前剧集的预览…" : "点选后立即重新生成当前剧集的预览，不会立即修改云盘。拆分与合并需要完整的 TMDB 季集信息。"))
                        .font(.caption)
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
            }
            .onChange(of: current) { _, newVal in
                picked = newVal
            }
            .onChange(of: error) { _, newErr in
                if newErr != nil {
                    picked = current
                }
            }
            .navigationTitle("切换剧集策略")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(applying)
                }
            }
        }
    }
}
