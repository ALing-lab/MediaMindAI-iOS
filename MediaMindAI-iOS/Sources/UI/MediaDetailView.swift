import SwiftUI

/// 1:1 复刻自 Android `MediaDetailScreen.kt`：
/// 作品完整详情页（海报/评分/TMDB 编号、分季动作明细、逐条勾选、单作策略覆盖与重新匹配入口）。
public struct MediaDetailView: View {
    public let planId: String
    public let groupId: String
    public let onRematch: () -> Void
    public let onEditPolicy: () -> Void
    public let onEditAssets: () -> Void
    public let onEditEpisodeStrategy: (() -> Void)?

    @State private var planStore = PlanAndTaskStore.shared

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
    private var actions: [PlanAction] { plan?.actions.filter { $0.groupId == groupId } ?? [] }

    public var body: some View {
        Group {
            if let g = group {
                List {
                    Section {
                        HStack(alignment: .top, spacing: 14) {
                            posterView(for: g)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(g.title.isEmpty ? g.folderName : g.title)
                                    .font(.title3.bold())
                                HStack(spacing: 8) {
                                    if !g.year.isEmpty { Text(g.year) }
                                    if let r = g.rating, r > 0 { Text(String(format: "★ %.1f", r)) }
                                    if let tid = g.tmdbId { Text("TMDB \(tid)") }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let conf = g.confidence {
                                    Text("识别置信度：\(conf)").font(.caption2).foregroundStyle(.secondary)
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
                        }
                        .padding(.vertical, 4)

                        if let newDir = g.folderNewName {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("目录重命名").font(.caption.bold()).foregroundStyle(.secondary)
                                Text("\(g.folderName) → \(newDir)")
                                    .font(.caption.monospaced())
                            }
                        }
                    }

                    Section("快捷调整") {
                        Button { onRematch() } label: { Label("重新搜索匹配 TMDB", systemImage: "magnifyingglass") }
                        Button { onEditPolicy() } label: { Label("调整此作品命名与刮削策略", systemImage: "slider.horizontal.3") }
                        Button { onEditAssets() } label: { Label("自定义此作品 NFO 与图片素材", systemImage: "photo.on.rectangle.angled") }
                        if g.kind == "tv", let onEditEpisodeStrategy {
                            Button { onEditEpisodeStrategy() } label: {
                                Label("切换剧集策略 / TMDB 剧集组", systemImage: "list.number")
                            }
                        }
                    }

                    if g.kind == "tv" {
                        let bySeason = Dictionary(grouping: actions) { $0.season ?? -1 }
                        let keys = bySeason.keys.sorted()
                        ForEach(keys, id: \.self) { seasonNum in
                            let title = seasonNum < 0 ? "剧集级操作（目录 / 主 NFO / 海报）" : (seasonNum == 0 ? "特别篇（Season 00）" : String(format: "第 %02d 季（Season %02d）", seasonNum, seasonNum))
                            Section(title) {
                                ForEach(bySeason[seasonNum] ?? []) { act in
                                    actionRow(act)
                                }
                            }
                        }
                    } else {
                        Section("整理操作明细（\(actions.count) 项）") {
                            ForEach(actions) { act in
                                actionRow(act)
                            }
                        }
                    }
                }
                .navigationTitle(g.title.isEmpty ? "作品详情" : g.title)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("未找到作品记录", systemImage: "film")
            }
        }
    }

    private func posterView(for g: PlanGroup) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
            TmdbImageView(
                url: g.posterPath.flatMap { AppSettings.shared.imageUrl(path: $0, size: "w342") },
                placeholderSystemName: g.kind == "tv" ? "tv" : "film"
            )
        }
        .frame(width: 84, height: 124)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func actionRow(_ act: PlanAction) -> some View {
        HStack(spacing: 10) {
            if act.op != "unmatched" && !act.done {
                Button {
                    toggleAction(actionId: act.id)
                } label: {
                    Image(systemName: act.selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(act.selected ? MMTheme.accent : .secondary)
                }
                .buttonStyle(.plain)
            } else if act.done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(MMTheme.greenOk)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(act.op)] \(act.newName.isEmpty ? act.oldName : act.newName)")
                    .font(.caption.monospaced())
                if !act.oldName.isEmpty && act.oldName != act.newName {
                    Text("原：\(act.oldName)").font(.caption2).foregroundStyle(.secondary)
                }
                if let err = act.error {
                    Text(err).font(.caption2).foregroundStyle(MMTheme.redErr)
                }
            }
        }
    }

    private func toggleAction(actionId: String) {
        guard let p = plan, let act = p.actions.first(where: { $0.id == actionId }) else { return }
        PlanAndTaskStore.shared.savePlan(PlanSelection.set(plan: p, ids: [actionId], on: !act.selected))
    }
}
