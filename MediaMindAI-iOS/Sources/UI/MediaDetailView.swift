import SwiftUI
import UIKit

/// 作品完整详情页：
/// - 顶部作品头卡 + 快捷调整（含第 3 层影片策略覆盖实时开关）
/// - 基础素材真实预览卡（海报 / 背景图 / Logo / 主 NFO，关闭项自动隐藏，无勾选项）
/// - 下方可左滑切换的季卡（剧集）或单部电影卡（系列合集）：完整展示对应季/电影海报、文件夹、季 NFO、每集 TMDB 标题、拟整理文件名/原文件名，以及按开关显隐的集 NFO 与集缩略图。
public struct MediaDetailView: View {
    public let planId: String
    public let groupId: String
    public let onRematch: () -> Void
    public let onEditPolicy: () -> Void
    public let onEditAssets: () -> Void
    public let onEditEpisodeStrategy: (() -> Void)?

    @State private var planStore = PlanAndTaskStore.shared
    @State private var settings = AppSettings.shared
    @State private var currentPageIndex: Int = 0
    @State private var pageSlideForward: Bool = true
    @State private var seasonMetas: [Int: SeasonMeta] = [:]
    @State private var episodeMetas: [String: EpisodeMeta] = [:]
    @State private var movieMetas: [Int: MatchInfo] = [:]
    @State private var fetchedClearlogoPath: String? = nil
    @State private var fetchedBackdropPath: String? = nil

    public init(
        planId: String,
        groupId: String,
        onRematch: @escaping () -> Void,
        onEditPolicy: @escaping () -> Void,
        onEditAssets: @escaping () -> Void,
        onEditEpisodeStrategy: (() -> Void)? = nil
    ) {
        self.planId = planId
        self.groupId = groupId
        self.onRematch = onRematch
        self.onEditPolicy = onEditPolicy
        self.onEditAssets = onEditAssets
        self.onEditEpisodeStrategy = onEditEpisodeStrategy
    }

    private var plan: ScrapePlan? { planStore.plans.first(where: { $0.id == planId }) }
    private var group: PlanGroup? { plan?.groups.first(where: { $0.id == groupId }) }
    private var allGroupActions: [PlanAction] { plan?.actions.filter { $0.groupId == groupId } ?? [] }

    private func effectivePolicy(for g: PlanGroup) -> EffectivePolicy {
        PolicyResolver.resolve(
            isTv: g.kind == "tv",
            global: settings.policies,
            task: plan?.taskPolicy,
            film: g.policyOverride
        )
    }

    private var pages: [DetailPage] {
        guard let g = group else { return [] }
        return buildPages(for: g, actions: allGroupActions)
    }

    public var body: some View {
        Group {
            if let g = group {
                let eff = effectivePolicy(for: g)
                let pageList = pages
                let safeIndex = min(max(0, currentPageIndex), max(0, pageList.count - 1))

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        headerCard(for: g, actions: allGroupActions)
                        quickActionsCard(for: g)
                        baseAssetsCard(for: g, eff: eff, actions: allGroupActions)

                        if !pageList.isEmpty {
                            pagedContentSection(
                                group: g,
                                eff: eff,
                                pageList: pageList,
                                safeIndex: safeIndex
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(g.title.isEmpty ? "作品详情" : g.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onRematch) {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                Text("手动识别")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MMTheme.accent)
                        }
                    }
                }
                .onChange(of: g.tmdbId) { _, _ in
                    seasonMetas.removeAll()
                    episodeMetas.removeAll()
                    movieMetas.removeAll()
                    fetchedClearlogoPath = nil
                    fetchedBackdropPath = nil
                    currentPageIndex = 0
                }
                .task(id: "\(g.id)-\(g.tmdbId ?? 0)-\(pageList.count)-\(eff.scrapeEnabled)-\(eff.downloadFanart)-\(eff.downloadClearlogo)-\(eff.downloadEpisodeThumb)-\(eff.episodeNfo)") {
                    await loadMetadata(for: g, pageList: pageList, eff: eff)
                }
            } else {
                ContentUnavailableView("未找到作品记录", systemImage: "film")
            }
        }
    }

    // MARK: - 1. 顶部作品头卡

    private func headerCard(for g: PlanGroup, actions: [PlanAction]) -> some View {
        let fileCount = Set(actions.filter { $0.kind == "file" }.map { $0.fileId ?? $0.id }).count
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                TmdbImageView(
                    url: g.posterPath.flatMap { settings.imageUrl(path: $0, size: "w342") },
                    placeholderSystemName: g.kind == "tv" ? "tv" : "film"
                )
            }
            .frame(width: 82, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(g.title.isEmpty ? g.folderName : g.title)
                    .font(.title3.bold())
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if !g.year.isEmpty { Text(g.year) }
                    if let r = g.rating, r > 0 { Text(String(format: "★ %.1f", r)) }
                    if let tid = g.tmdbId { Text("TMDB \(tid)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if fileCount > 0 {
                    Text("\(fileCount) 个视频文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let conf = g.confidence {
                    Text("识别置信度：\(conf)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if g.policyOverride != nil {
                    Label("已启用第 3 层影片策略覆盖", systemImage: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(MMTheme.accent)
                }

                if let warn = g.warn, !warn.isEmpty {
                    Label(warn, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 2. 快捷调整卡片（保留第 3 层影片策略覆盖开关与精确命名）

    private func quickActionsCard(for g: PlanGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("快捷调整")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "switch.2")
                        .foregroundStyle(MMTheme.accent)
                        .frame(width: 22)
                    Toggle("启用第 3 层影片策略覆盖", isOn: Binding(
                        get: { g.policyOverride != nil },
                        set: { enabled in toggleFilmPolicyOverride(enabled: enabled) }
                    ))
                    .font(.subheadline)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if g.policyOverride != nil {
                    Divider().padding(.leading, 44)
                    quickActionRow(icon: "slider.horizontal.3", title: "调整作品命名与整理策略", action: onEditPolicy)

                    Divider().padding(.leading, 44)
                    quickActionRow(icon: "photo.on.rectangle.angled", title: "自定义 NFO 与海报素材", action: onEditAssets)

                    if g.kind == "tv", let onEditEpisodeStrategy {
                        Divider().padding(.leading, 44)
                        quickActionRow(icon: "list.number", title: "切换剧集策略 / TMDB 剧集组", action: onEditEpisodeStrategy)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(g.policyOverride == nil
                 ? "已关闭第 3 层影片策略覆盖，当前直接复用任务策略或全局默认策略。"
                 : "已开启第 3 层影片策略覆盖，可单独调整此作品的命名与刮削素材。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)
        }
    }

    private func quickActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(MMTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(MMTheme.accent)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. 基础信息与主素材真实预览卡（无勾选项，关闭项自动隐藏）

    private func baseAssetsCard(for g: PlanGroup, eff: EffectivePolicy, actions: [PlanAction]) -> some View {
        let showImages = buildBaseArtworkItems(for: g, eff: eff, actions: actions)
        let mainNfo = actions.first {
            $0.op == "artwork" && ($0.kind == "tvshow_nfo" || $0.kind == "movie_nfo") && $0.enabled
        }
        let showMainNfo = eff.scrapeEnabled && eff.writeNfo && (mainNfo != nil || g.tmdbId != nil)
        let folderRename = g.folderNewName ?? g.folderName

        return VStack(alignment: .leading, spacing: 10) {
            Text("基础信息与素材")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 12) {
                // 文件夹信息
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(MMTheme.accent)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folderRename)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        if let newName = g.folderNewName, newName != g.folderName {
                            Text("原目录：\(g.folderName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }

                // 真实海报 / 背景图 / Logo 横向展示
                if !showImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(showImages) { item in
                                VStack(spacing: 5) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.black.opacity(0.25))
                                        TmdbImageView(
                                            url: item.url,
                                            placeholderSystemName: item.placeholder
                                        )
                                    }
                                    .frame(width: item.isWide ? 128 : 78, height: 108)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    Text(item.fileName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                // 主 NFO 行
                if showMainNfo {
                    let nfoName = mainNfo?.newName ?? (g.kind == "tv" ? "tvshow.nfo" : "movie.nfo")
                    let statusText = mainNfo?.done == true ? "已生成" : "执行任务时生成"
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(MMTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(nfoName)
                                .font(.subheadline.weight(.medium))
                            Text(statusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - 4. 下方可左滑切换的季卡 / 系列电影卡（完整海报 + 季目录/季NFO + 每集详情）

    private func pagedContentSection(
        group g: PlanGroup,
        eff: EffectivePolicy,
        pageList: [DetailPage],
        safeIndex: Int
    ) -> some View {
        let page = pageList[safeIndex]
        return VStack(alignment: .leading, spacing: 10) {
            // 顶部页码选择条 + 左滑提示
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pageList.enumerated()), id: \.element.id) { idx, item in
                            Button {
                                guard idx != safeIndex else { return }
                                pageSlideForward = idx > safeIndex
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    currentPageIndex = idx
                                }
                            } label: {
                                Text(item.tabTitle)
                                    .font(.caption.weight(idx == safeIndex ? .semibold : .regular))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        idx == safeIndex ? MMTheme.accent : Color(.secondarySystemGroupedBackground),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(idx == safeIndex ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if pageList.count > 1 {
                    Text("\(safeIndex + 1)/\(pageList.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // 当前季 / 当前部电影完整卡片（支持左右滑动切换，带定向滑动过渡动画）
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    pageHeaderBlock(group: g, page: page, eff: eff)

                    if !page.episodes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(g.kind == "tv" ? "分集明细" : "文件明细")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                let uniqEpCount = Set(page.episodes.compactMap(\.episode)).count
                                Text(
                                    g.kind == "tv" && uniqEpCount > 0 && uniqEpCount < page.episodes.count
                                        ? "\(uniqEpCount) 集 · \(page.episodes.count) 文件（多版本）"
                                        : (g.kind == "tv" ? "\(page.episodes.count) 集" : "\(page.episodes.count) 项")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            if g.kind == "tv", eff.scrapeEnabled, eff.downloadEpisodeThumb {
                                let loadedMetas = page.episodes.compactMap { $0.metaLookupKey.flatMap { episodeMetas[$0] } }
                                let anyThumb = page.episodes.contains { ep in
                                    if let raw = ep.thumbUrl, !raw.isEmpty { return true }
                                    if let sp = ep.metaLookupKey.flatMap({ episodeMetas[$0]?.stillPath }), !sp.isEmpty { return true }
                                    return false
                                }
                                if !loadedMetas.isEmpty && !anyThumb {
                                    Label("当前剧集在 TMDB 暂无单集缩略图", systemImage: "info.circle")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }

                            ForEach(Array(page.episodes.enumerated()), id: \.element.id) { idx, ep in
                                episodeDetailRow(group: g, page: page, ep: ep, eff: eff)
                                if idx + 1 < page.episodes.count {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .id(page.id)
                .transition(.asymmetric(
                    insertion: .move(edge: pageSlideForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: pageSlideForward ? .leading : .trailing).combined(with: .opacity)
                ))
            }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 28, coordinateSpace: .global)
                    .onEnded { value in
                        guard pageList.count > 1, value.startLocation.x > 32 else { return }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.4, abs(dx) > 44 else { return }
                        if dx < 0, safeIndex + 1 < pageList.count {
                            pageSlideForward = true
                            withAnimation(.easeInOut(duration: 0.28)) {
                                currentPageIndex = safeIndex + 1
                            }
                        } else if dx > 0, safeIndex > 0 {
                            pageSlideForward = false
                            withAnimation(.easeInOut(duration: 0.28)) {
                                currentPageIndex = safeIndex - 1
                            }
                        }
                    }
            )

            if pageList.count > 1 {
                Text(g.kind == "tv"
                     ? "左滑卡片可切换下一季，对应季海报、季文件夹与分集信息会同步更新。"
                     : "左滑卡片可切换系列电影的下一部，对应海报与文件信息会同步更新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func pageHeaderBlock(group g: PlanGroup, page: DetailPage, eff: EffectivePolicy) -> some View {
        let posterURL = resolvedPagePosterURL(group: g, page: page)
        let showSeasonPoster = g.kind == "tv"
            ? (eff.scrapeEnabled && eff.seasonPoster)
            : (eff.scrapeEnabled && eff.downloadPoster)
        let showSeasonNfo = g.kind != "tv" && eff.scrapeEnabled && eff.writeNfo

        HStack(alignment: .top, spacing: 12) {
            if showSeasonPoster {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.16))
                    TmdbImageView(
                        url: posterURL,
                        placeholderSystemName: g.kind == "tv" ? "tv" : "film"
                    )
                }
                .frame(width: 72, height: 106)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(page.headerTitle)
                    .font(.headline)

                if let folderName = page.folderName, !folderName.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(MMTheme.accent)
                        Text(folderName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                }

                if showSeasonPoster, let posterFile = page.posterFileName {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(posterFile)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if showSeasonNfo, let nfoFile = page.nfoFileName {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(MMTheme.accent)
                        Text(nfoFile)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func episodeDetailRow(
        group g: PlanGroup,
        page: DetailPage,
        ep: DetailEpisodeItem,
        eff: EffectivePolicy
    ) -> some View {
        let metaKey = ep.metaLookupKey
        let meta = metaKey.flatMap { episodeMetas[$0] }
        let showEpNfo = g.kind == "tv" && eff.scrapeEnabled && eff.episodeNfo
        let showEpThumb = g.kind == "tv" && eff.scrapeEnabled && eff.downloadEpisodeThumb
        let thumbURL: URL? = {
            if let raw = ep.thumbUrl, let u = URL(string: raw) { return u }
            if let sp = meta?.stillPath { return settings.imageUrl(path: sp, size: "w300") }
            return nil
        }()

        VStack(alignment: .leading, spacing: 6) {
            if g.kind == "tv", let epNum = ep.episode {
                let sNum = ep.season ?? page.seasonNumber ?? 1
                let code = String(format: "S%02dE%02d", sNum, epNum)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let title = meta?.name, !title.isEmpty {
                        Text("第\(epNum)集：\(title)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    } else {
                        Text("第\(epNum)集")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(code)
                        .font(.caption2.monospaced())
                        .foregroundStyle(MMTheme.accent)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                if showEpThumb {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.16))
                        if thumbURL != nil {
                            TmdbImageView(
                                url: thumbURL,
                                placeholderSystemName: "photo.tv"
                            )
                        } else {
                            VStack(spacing: 3) {
                                Image(systemName: "photo.slash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("暂无缩略图")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(ep.newFileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if !ep.oldFileName.isEmpty && ep.oldFileName != ep.newFileName {
                        Text("原：\(ep.oldFileName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if g.kind == "tv" {
                        Label(showEpNfo ? "集NFO已启用" : "集NFO已关闭", systemImage: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(showEpNfo ? MMTheme.greenOk : .secondary)
                            .lineLimit(1)

                        let thumbStatusText: String = {
                            guard showEpThumb else { return "集缩略图已关闭" }
                            return thumbURL == nil ? "集缩略图已开启（TMDB 暂无）" : "集缩略图已开启"
                        }()
                        let thumbStatusColor: Color = {
                            guard showEpThumb else { return .secondary }
                            return thumbURL == nil ? .orange : MMTheme.greenOk
                        }()
                        Label(thumbStatusText, systemImage: "photo")
                            .font(.caption2)
                            .foregroundStyle(thumbStatusColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 5. 数据组装与 TMDB 元数据按需加载

    private func buildBaseArtworkItems(for g: PlanGroup, eff: EffectivePolicy, actions: [PlanAction]) -> [BaseArtworkItem] {
        guard eff.scrapeEnabled else { return [] }
        var items: [BaseArtworkItem] = []

        if eff.downloadPoster {
            let act = actions.first {
                $0.op == "artwork" && $0.kind == "image" && $0.season == nil && $0.episode == nil
                && $0.newName.lowercased().contains("poster") && $0.enabled
            }
            let url = act?.artworkUrl.flatMap(URL.init(string:))
                ?? g.posterPath.flatMap { settings.imageUrl(path: $0, size: "w342") }
            items.append(BaseArtworkItem(
                id: "poster",
                fileName: act?.newName ?? "poster.jpg",
                url: url,
                placeholder: g.kind == "tv" ? "tv" : "film",
                isWide: false
            ))
        }

        if eff.downloadFanart {
            let fanartActs = actions.filter {
                $0.op == "artwork" && $0.kind == "image" && $0.season == nil && $0.episode == nil
                && ($0.newName.lowercased().hasPrefix("fanart") || $0.newName.lowercased().hasPrefix("backdrop"))
                && $0.enabled
            }
            if !fanartActs.isEmpty {
                for a in fanartActs {
                    let url = a.artworkUrl.flatMap(URL.init(string:))
                        ?? fetchedBackdropPath.flatMap { settings.imageUrl(path: $0, size: "w780") }
                    items.append(BaseArtworkItem(
                        id: "fanart-\(a.id)",
                        fileName: a.newName,
                        url: url,
                        placeholder: "photo",
                        isWide: true
                    ))
                }
            } else if let bp = fetchedBackdropPath {
                items.append(BaseArtworkItem(
                    id: "fanart-default",
                    fileName: "fanart.jpg",
                    url: settings.imageUrl(path: bp, size: "w780"),
                    placeholder: "photo",
                    isWide: true
                ))
            }
        }

        if eff.downloadClearlogo {
            let act = actions.first { $0.op == "artwork" && $0.kind == "clearlogo" && $0.enabled }
            let url = act?.artworkUrl.flatMap(URL.init(string:))
                ?? fetchedClearlogoPath.flatMap { settings.imageUrl(path: $0, size: "w500") }
            if act != nil || url != nil {
                items.append(BaseArtworkItem(
                    id: "clearlogo",
                    fileName: act?.newName ?? "clearlogo.png",
                    url: url,
                    placeholder: "sparkles.rectangle.stack",
                    isWide: true
                ))
            }
        }

        return items
    }

    private func buildPages(for g: PlanGroup, actions: [PlanAction]) -> [DetailPage] {
        let fileActions = actions.filter { $0.kind == "file" && ($0.op == "rename" || $0.op == "move" || $0.op == "skip") }
        // 按 fileId 去重合并 rename + move，优先保留 rename 的新旧文件名
        var mergedFiles: [String: PlanAction] = [:]
        var fileOrder: [String] = []
        for a in fileActions {
            let key = a.fileId ?? a.id
            if let existing = mergedFiles[key] {
                if existing.op != "rename" && a.op == "rename" {
                    mergedFiles[key] = a
                }
            } else {
                mergedFiles[key] = a
                fileOrder.append(key)
            }
        }
        let uniqueFiles = fileOrder.compactMap { mergedFiles[$0] }

        if g.kind == "tv" {
            var seasonSet = Set<Int>()
            for a in actions {
                if let s = a.season { seasonSet.insert(s) }
            }
            let sortedSeasons = seasonSet.sorted()
            if sortedSeasons.isEmpty {
                let eps = uniqueFiles.map { makeEpisodeItem(from: $0, actions: actions) }
                return [DetailPage(
                    id: "tv-all",
                    tabTitle: "全部文件",
                    headerTitle: g.title.isEmpty ? g.folderName : g.title,
                    seasonNumber: nil,
                    movieTmdbId: nil,
                    folderName: g.folderNewName ?? g.folderName,
                    posterFileName: "poster.jpg",
                    posterUrl: g.posterPath.flatMap { settings.imageUrl(path: $0, size: "w342")?.absoluteString },
                    nfoFileName: "tvshow.nfo",
                    episodes: eps
                )]
            }

            return sortedSeasons.map { s in
                let tabTitle = s == 0 ? "特别篇" : "第 \(s) 季"
                let folderName = StandardNaming.seasonDirName(s)
                let seasonPosterAct = actions.first {
                    $0.op == "artwork" && $0.kind == "image" && $0.season == s && $0.episode == nil
                    && $0.newName.lowercased().contains("poster")
                }
                let seasonFiles = uniqueFiles
                    .filter { ($0.season ?? 1) == s }
                    .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
                let eps = seasonFiles.map { makeEpisodeItem(from: $0, actions: actions) }
                let posterFile = seasonPosterAct?.newName ?? (s == 0 ? "season-specials-poster.jpg" : String(format: "season%02d-poster.jpg", s))
                return DetailPage(
                    id: "season-\(s)",
                    tabTitle: tabTitle,
                    headerTitle: s == 0 ? "特别篇（\(folderName)）" : "第 \(s) 季（\(folderName)）",
                    seasonNumber: s,
                    movieTmdbId: nil,
                    folderName: folderName,
                    posterFileName: posterFile,
                    posterUrl: seasonPosterAct?.artworkUrl,
                    nfoFileName: nil,
                    episodes: eps
                )
            }
        }

        // 系列电影 / 合集：按每部电影（tmdbId 或 destLabel）分页，支持左滑切换第 2 部、第 3 部
        if g.kind == "collection" {
            var bucketKeys: [String] = []
            var bucketMap: [String: [PlanAction]] = [:]
            for f in uniqueFiles {
                let key = f.tmdbId.map { "tmdb-\($0)" } ?? (f.destLabel ?? f.id)
                if bucketMap[key] == nil { bucketKeys.append(key) }
                bucketMap[key, default: []].append(f)
            }
            if bucketKeys.count >= 1 {
                return bucketKeys.enumerated().map { idx, key in
                    let files = bucketMap[key] ?? []
                    let first = files.first
                    let mid = first?.tmdbId
                    let posterAct = actions.first {
                        $0.op == "artwork" && $0.kind == "image" && $0.tmdbId == mid
                        && $0.newName.lowercased().contains("poster")
                    }
                    let nfoAct = actions.first {
                        $0.op == "artwork" && $0.kind == "movie_nfo" && $0.tmdbId == mid
                    }
                    let title = movieMetas[mid ?? -1]?.title ?? first?.destLabel ?? "第 \(idx + 1) 部"
                    return DetailPage(
                        id: "movie-\(key)",
                        tabTitle: "第 \(idx + 1) 部",
                        headerTitle: title,
                        seasonNumber: nil,
                        movieTmdbId: mid,
                        folderName: first?.destLabel ?? g.folderNewName ?? g.folderName,
                        posterFileName: posterAct?.newName ?? "poster.jpg",
                        posterUrl: posterAct?.artworkUrl,
                        nfoFileName: nfoAct?.newName ?? "movie.nfo",
                        episodes: files.map { makeEpisodeItem(from: $0, actions: actions) }
                    )
                }
            }
        }

        // 单部电影
        let eps = uniqueFiles.map { makeEpisodeItem(from: $0, actions: actions) }
        return [DetailPage(
            id: "movie-single",
            tabTitle: "电影详情",
            headerTitle: g.title.isEmpty ? g.folderName : g.title,
            seasonNumber: nil,
            movieTmdbId: g.tmdbId,
            folderName: g.folderNewName ?? g.folderName,
            posterFileName: "poster.jpg",
            posterUrl: g.posterPath.flatMap { settings.imageUrl(path: $0, size: "w342")?.absoluteString },
            nfoFileName: "movie.nfo",
            episodes: eps
        )]
    }

    private func makeEpisodeItem(from fileAct: PlanAction, actions: [PlanAction]) -> DetailEpisodeItem {
        let newName = fileAct.newName.isEmpty ? fileAct.oldName : fileAct.newName
        let stem = MediaParser.splitNameExt(newName).0
        let epNfoAct = actions.first {
            $0.op == "artwork" && $0.kind == "episode_nfo"
            && $0.season == fileAct.season && $0.episode == fileAct.episode
        }
        let epThumbAct = actions.first {
            $0.op == "artwork" && $0.kind == "image"
            && $0.season == fileAct.season && $0.episode == fileAct.episode
        }
        return DetailEpisodeItem(
            id: fileAct.id,
            season: fileAct.season,
            episode: fileAct.episode,
            metadataSeason: fileAct.metadataSeason ?? fileAct.season,
            metadataEpisode: fileAct.metadataEpisode ?? fileAct.episode,
            newFileName: newName,
            oldFileName: fileAct.oldName,
            episodeNfoFileName: epNfoAct?.newName ?? "\(stem).nfo",
            episodeThumbFileName: epThumbAct?.newName ?? "\(stem)-thumb.jpg",
            thumbUrl: epThumbAct?.artworkUrl
        )
    }

    private func resolvedPagePosterURL(group g: PlanGroup, page: DetailPage) -> URL? {
        if let s = page.seasonNumber, let sp = seasonMetas[s]?.posterPath, !sp.isEmpty {
            return settings.imageUrl(path: sp, size: "w342")
        }
        if let raw = page.posterUrl, !raw.isEmpty, let u = URL(string: raw) { return u }
        if let mid = page.movieTmdbId, let mp = movieMetas[mid]?.posterPath, !mp.isEmpty {
            return settings.imageUrl(path: mp, size: "w342")
        }
        return g.posterPath.flatMap { settings.imageUrl(path: $0, size: "w342") }
    }

    private func loadMetadata(for g: PlanGroup, pageList: [DetailPage], eff: EffectivePolicy) async {
        guard let tid = g.tmdbId, tid > 0 else { return }

        if eff.scrapeEnabled && eff.downloadClearlogo && fetchedClearlogoPath == nil {
            let kind = g.kind == "tv" ? "tv" : "movie"
            fetchedClearlogoPath = await TmdbClient.shared.clearlogoPath(kind: kind, id: tid)
        }

        if eff.scrapeEnabled && eff.downloadFanart && fetchedBackdropPath == nil {
            if g.kind == "tv" {
                fetchedBackdropPath = await TmdbClient.shared.tvDetails(id: tid)?.backdropPath
            } else {
                fetchedBackdropPath = await TmdbClient.shared.movieDetails(id: tid)?.backdropPath
            }
        }

        if g.kind == "tv" {
            // 先批量拉取所有季的专属元数据与季海报，避免第 2/3 季海报被第 1 季分集请求阻塞
            for page in pageList {
                guard let s = page.seasonNumber else { continue }
                if seasonMetas[s] == nil {
                    if let sm = await TmdbClient.shared.seasonMeta(tvId: tid, season: s) {
                        seasonMetas[s] = sm
                    }
                }
            }
            for page in pageList {
                for ep in page.episodes {
                    guard let ms = ep.metadataSeason, let me = ep.metadataEpisode, let key = ep.metaLookupKey else { continue }
                    if episodeMetas[key] == nil {
                        if let em = await TmdbClient.shared.episodeFromSeasonBatch(tvId: tid, season: ms, episode: me) {
                            episodeMetas[key] = em
                        }
                    }
                }
            }
        } else if g.kind == "collection" {
            for page in pageList {
                guard let mid = page.movieTmdbId, mid > 0, movieMetas[mid] == nil else { continue }
                if let info = await TmdbClient.shared.movieDetails(id: mid) {
                    movieMetas[mid] = info
                }
            }
        }
    }

    private func toggleFilmPolicyOverride(enabled: Bool) {
        guard var p = plan, let idx = p.groups.firstIndex(where: { $0.id == groupId }) else { return }
        p.groups[idx].policyOverride = enabled ? (p.groups[idx].policyOverride ?? PolicyOverride()) : nil
        p = PolicyResolver.applyOverrides(to: p, global: settings.policies)
        PlanAndTaskStore.shared.savePlan(p)
    }
}

// MARK: - 内部视图模型

private struct BaseArtworkItem: Identifiable {
    let id: String
    let fileName: String
    let url: URL?
    let placeholder: String
    let isWide: Bool
}

private struct DetailPage: Identifiable {
    let id: String
    let tabTitle: String
    let headerTitle: String
    let seasonNumber: Int?
    let movieTmdbId: Int?
    let folderName: String?
    let posterFileName: String?
    let posterUrl: String?
    let nfoFileName: String?
    let episodes: [DetailEpisodeItem]
}

private struct DetailEpisodeItem: Identifiable {
    let id: String
    let season: Int?
    let episode: Int?
    let metadataSeason: Int?
    let metadataEpisode: Int?
    let newFileName: String
    let oldFileName: String
    let episodeNfoFileName: String?
    let episodeThumbFileName: String?
    let thumbUrl: String?

    var metaLookupKey: String? {
        guard let s = metadataSeason, let e = metadataEpisode else { return nil }
        return "\(s)-\(e)"
    }
}
