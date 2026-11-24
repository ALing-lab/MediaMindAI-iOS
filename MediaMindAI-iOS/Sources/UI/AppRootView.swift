import SwiftUI

public enum MainTab: String, CaseIterable, Identifiable {
    case cloud, preview, tasks, settings, search

    public static var primaryTabs: [MainTab] { [.cloud, .preview, .tasks, .settings] }

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cloud: return "云盘"
        case .preview: return "预览"
        case .tasks: return "任务"
        case .settings: return "设置"
        case .search: return "搜索"
        }
    }

    public var icon: String {
        switch self {
        case .cloud: return "cloud.fill"
        case .preview: return "eye.fill"
        case .tasks: return "bolt.fill"
        case .settings: return "gearshape.fill"
        case .search: return "magnifyingglass"
        }
    }
}

/// 自适应主框架：iPad 使用左侧栏 NavigationSplitView，iPhone 使用底部 TabView（原生 safeArea 避让，杜绝底部遮挡）。
public struct AppRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedTab: MainTab = .cloud
    @State private var scanManager = BackgroundScanManager.shared

    public init() {}

    public var body: some View {
        mainContent
            .overlay(alignment: .bottom) {
                floatingScanBanner
                    .padding(.bottom, sizeClass == .regular ? 24 : 124)
            }
            .animation(.easeInOut(duration: 0.22), value: scanManager.isScanning)
            .animation(.easeInOut(duration: 0.22), value: scanManager.finishedSummary)
            .animation(.easeInOut(duration: 0.22), value: scanManager.errorMessage)
            .onChange(of: selectedTab) { _, tab in
                if tab == .preview && scanManager.finishedSummary != nil {
                    scanManager.dismissBanner()
                }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(selection: Binding<MainTab?>(
                    get: { selectedTab },
                    set: { if let v = $0 { selectedTab = v } }
                )) {
                    ForEach(MainTab.allCases) { tab in
                        Label(tab.label, systemImage: tab.icon)
                            .tag(tab)
                    }
                }
                .navigationTitle("MediaMind AI")
            } detail: {
                tabContent(selectedTab)
            }
        } else {
            if #available(iOS 18.0, *) {
                TabView(selection: $selectedTab) {
                    Tab(MainTab.cloud.label, systemImage: MainTab.cloud.icon, value: MainTab.cloud) {
                        CloudTabView(onScanFinished: { selectedTab = .preview })
                    }
                    Tab(MainTab.preview.label, systemImage: MainTab.preview.icon, value: MainTab.preview) {
                        PreviewTabView(onStartExecution: { selectedTab = .tasks })
                    }
                    Tab(MainTab.tasks.label, systemImage: MainTab.tasks.icon, value: MainTab.tasks) {
                        TasksTabView(onOpenPreview: { selectedTab = .preview })
                    }
                    Tab(MainTab.settings.label, systemImage: MainTab.settings.icon, value: MainTab.settings) {
                        SettingsTabView()
                    }
                    Tab(value: MainTab.search, role: .search) {
                        GlobalSearchTabView(onOpenPreview: { selectedTab = .preview })
                    }
                }
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(MainTab.allCases) { tab in
                        tabContent(tab)
                            .tabItem { Label(tab.label, systemImage: tab.icon) }
                            .tag(tab)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: MainTab) -> some View {
        switch tab {
        case .cloud:
            CloudTabView(onScanFinished: { selectedTab = .preview })
        case .preview:
            PreviewTabView(onStartExecution: { selectedTab = .tasks })
        case .tasks:
            TasksTabView(onOpenPreview: { selectedTab = .preview })
        case .settings:
            SettingsTabView()
        case .search:
            GlobalSearchTabView(onOpenPreview: { selectedTab = .preview })
        }
    }

    @ViewBuilder
    private var floatingScanBanner: some View {
        if scanManager.isScanning {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(MMTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("后台正在扫描识别…")
                        .font(.caption.weight(.semibold))
                    if !scanManager.progressText.isEmpty {
                        Text(scanManager.progressText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Button("取消") {
                    scanManager.cancel()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(MMTheme.redErr)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(MMTheme.accent.opacity(0.28), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let summary = scanManager.finishedSummary {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MMTheme.greenOk)
                Text(summary)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("查看结果") {
                    scanManager.dismissBanner()
                    selectedTab = .preview
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(MMTheme.accent)
                .buttonStyle(.plain)
                Button {
                    scanManager.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(MMTheme.greenOk.opacity(0.32), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let err = scanManager.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MMTheme.redErr)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(MMTheme.redErr)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Button {
                    scanManager.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}


/// 原生底栏独立搜索页（iOS 26/27 Liquid Glass 与底栏平行的圆形放大镜入口）：支持跨识别结果与任务记录检索。
private struct GlobalSearchTabView: View {
    let onOpenPreview: () -> Void
    @State private var store = PlanAndTaskStore.shared
    @State private var query = ""

    private var activePlan: ScrapePlan? {
        store.plans.first
    }

    private var matchedGroups: [PlanGroup] {
        guard let plan = activePlan else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return plan.groups }
        return plan.groups.filter { g in
            g.title.lowercased().contains(q)
                || g.folderName.lowercased().contains(q)
                || g.year.contains(q)
                || (g.tmdbId.map { String($0).contains(q) } ?? false)
                || (g.originalTitle?.lowercased().contains(q) ?? false)
        }
    }

    private var matchedTasks: [TaskRun] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return store.tasks.filter { t in
            t.sourceLabel.lowercased().contains(q)
                || t.provider.lowercased().contains(q)
                || t.id.lowercased().contains(q)
                || t.message.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !matchedGroups.isEmpty, let plan = activePlan {
                    Section(query.isEmpty ? "当前识别结果（\(matchedGroups.count)）" : "匹配的识别作品（\(matchedGroups.count)）") {
                        ForEach(matchedGroups) { grp in
                            NavigationLink {
                                MediaDetailView(
                                    planId: plan.id,
                                    groupId: grp.id,
                                    onRematch: { onOpenPreview() },
                                    onEditPolicy: { onOpenPreview() },
                                    onEditAssets: { onOpenPreview() },
                                    onEditEpisodeStrategy: nil
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.secondary.opacity(0.14))
                                        TmdbImageView(
                                            url: grp.posterPath.flatMap { AppSettings.shared.imageUrl(path: $0, size: "w185") },
                                            placeholderSystemName: grp.kind == "tv" ? "tv" : "film"
                                        )
                                    }
                                    .frame(width: 40, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(grp.title.isEmpty ? grp.folderName : grp.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            if !grp.year.isEmpty { Text(grp.year) }
                                            if let tid = grp.tmdbId { Text("TMDB \(tid)") }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        Text(grp.folderName)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                if !matchedTasks.isEmpty {
                    Section("匹配的任务记录（\(matchedTasks.count)）") {
                        ForEach(matchedTasks) { run in
                            NavigationLink {
                                CompletedTaskDetailScreen(run: run)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(run.sourceLabel.isEmpty ? "任务 \(run.id)" : run.sourceLabel)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(run.provider) · 成功 \(run.succeeded) / 失败 \(run.failed)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                if matchedGroups.isEmpty && matchedTasks.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "暂无可搜索内容" : "未找到匹配结果",
                        systemImage: "magnifyingglass",
                        description: Text(query.isEmpty ? "扫描网盘目录后，可在此快速搜索片名、年份、目录名或 TMDB ID。" : "试试更换片名、年份或 TMDB ID。")
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "搜索片名、文件夹、年份或 TMDB ID")
        }
    }
}
