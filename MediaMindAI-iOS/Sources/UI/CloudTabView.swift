import SwiftUI
import UIKit
import Observation

/// 全局后台非阻塞扫描管理器：扫描期间不锁屏、不阻塞切页或浏览其他目录，顶部轻量浮条实时展示进度与取消入口。
@Observable
@MainActor
public final class BackgroundScanManager {
    public static let shared = BackgroundScanManager()

    public var isScanning = false
    public var progressText = ""
    public var finishedSummary: String? = nil
    public var errorMessage: String? = nil
    private var scanTask: Task<Void, Never>? = nil
    private var scanEpoch: Int = 0

    private init() {}

    public func startScan(account: DriveAccount, roots: [PlanRoot]) {
        guard !isScanning else { return }
        scanEpoch += 1
        let epoch = scanEpoch
        isScanning = true
        finishedSummary = nil
        errorMessage = nil
        progressText = "正在连接网盘…"
        scanTask?.cancel()
        scanTask = Task {
            do {
                let drive = try AccountStore.shared.buildDrive(for: account)
                let plan = try await Scanner.scan(
                    roots: roots,
                    drive: drive,
                    fullDrive: false,
                    preflightTmdb: true
                ) { msg, count in
                    Task { @MainActor in
                        guard BackgroundScanManager.shared.scanEpoch == epoch else { return }
                        BackgroundScanManager.shared.progressText = "\(msg)（已发现 \(count) 个视频）"
                    }
                }
                guard !Task.isCancelled, self.scanEpoch == epoch else { return }
                PlanAndTaskStore.shared.savePlan(plan)
                isScanning = false
                scanTask = nil
                let matchedCount = plan.groups.filter { $0.kind != "unmatched" }.count
                let unmatchedCount = plan.groups.filter { $0.kind == "unmatched" }.count
                if unmatchedCount > 0 {
                    finishedSummary = "扫描完成：已识别 \(matchedCount) 组，待确认 \(unmatchedCount) 组"
                } else {
                    finishedSummary = "扫描完成：已识别 \(matchedCount) 组作品"
                }
            } catch is CancellationError {
                guard self.scanEpoch == epoch else { return }
                isScanning = false
                scanTask = nil
                progressText = ""
            } catch {
                guard self.scanEpoch == epoch else { return }
                isScanning = false
                scanTask = nil
                errorMessage = "扫描失败：\(error.localizedDescription)"
            }
        }
    }

    public func cancel() {
        scanEpoch += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        progressText = ""
    }

    public func dismissBanner() {
        finishedSummary = nil
        errorMessage = nil
    }
}

/// 收藏的云盘目录模型（持久化至 UserDefaults）。
private struct FavoriteCloudFolder: Identifiable, Codable, Hashable {
    var id: String { "\(accountId)|\(folderId)" }
    let accountId: String
    let provider: ProviderKind
    let accountLabel: String
    let folderId: String
    let folderName: String
    let pathLabel: String
}

private enum CloudFavoritesStore {
    private static let key = "cloud_favorite_folders_v1"

    static func load() -> [FavoriteCloudFolder] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([FavoriteCloudFolder].self, from: data) else {
            return []
        }
        return list
    }

    static func save(_ list: [FavoriteCloudFolder]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// 全新「文件来源」页（参考文件来源卡片 Hub 风格）：
/// - 顶部「我的设备 / 我的收藏」下划线切换 + 右上角「帮助」
/// - 已登录网盘以独立圆角卡片展示，点击直接浏览目录并扫描，右侧 ⋮ 菜单支持重新登录、检测连接、删除账号
/// - 底部「+ 添加文件来源」直接呼出原生登录页（123 / 光鸭 / WebDAV）
public struct CloudTabView: View {
    public let onScanFinished: () -> Void
    public init(onScanFinished: @escaping () -> Void) {
        self.onScanFinished = onScanFinished
    }

    private enum SourceTab: Int {
        case devices = 0
        case favorites = 1
    }

    @State private var store = AccountStore.shared
    @State private var activeTab: SourceTab = .devices
    @State private var favorites: [FavoriteCloudFolder] = CloudFavoritesStore.load()
    @State private var showAddAccount = false
    @State private var showHelpSheet = false
    @State private var reloginTarget: DriveAccount? = nil
    @State private var deleteTarget: DriveAccount? = nil
    @State private var pingStatusByAccount: [String: String] = [:]
    @State private var pingingAccountId: String? = nil

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()

                // 顶部柔和渐变光晕
                LinearGradient(
                    colors: [
                        MMTheme.accent.opacity(0.22),
                        MMTheme.accent.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 170)
                .ignoresSafeArea(edges: .top)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 「我的设备 / 我的收藏」下划线分段标签
                        HStack(spacing: 24) {
                            tabHeaderButton(title: "我的设备", tab: .devices)
                            tabHeaderButton(title: "我的收藏", tab: .favorites)
                            Spacer()
                        }

                        if activeTab == .devices {
                            devicesSection
                        } else {
                            favoritesSection
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("文件来源")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("帮助") {
                        showHelpSheet = true
                    }
                    .foregroundStyle(MMTheme.accent)
                }
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountSheet()
            }
            .sheet(item: $reloginTarget) { acct in
                NavigationStack {
                    Group {
                        switch acct.provider {
                        case .p123:
                            Pan123LoginView(targetAccountId: acct.id) { reloginTarget = nil }
                        case .guangya:
                            GuangyaLoginView(targetAccountId: acct.id) { reloginTarget = nil }
                        case .webdav:
                            WebDavLoginView(targetAccountId: acct.id) { reloginTarget = nil }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { reloginTarget = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: $showHelpSheet) {
                NavigationStack {
                    List {
                        Section("使用说明") {
                            Label("点击「添加文件来源」可接入 123 云盘、光鸭云盘或 WebDAV / OpenList。", systemImage: "plus.square")
                            Label("点击已连接的网盘卡片即可浏览目录，勾选影视文件夹后开始识别与整理。", systemImage: "folder")
                            Label("在目录浏览页右上角点击星标，可将常用目录加入「我的收藏」一键直达。", systemImage: "star")
                            Label("点击网盘卡片右侧「⋮」可检测连接、重新登录或删除账号。", systemImage: "ellipsis.circle")
                        }
                    }
                    .navigationTitle("帮助")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showHelpSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog(
                "确认删除「\(deleteTarget?.label ?? "")」？",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除账号", role: .destructive) {
                    if let acct = deleteTarget {
                        store.remove(id: acct.id)
                        favorites.removeAll { $0.accountId == acct.id }
                        CloudFavoritesStore.save(favorites)
                        pingStatusByAccount.removeValue(forKey: acct.id)
                    }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("仅移除本机保存的登录凭据，不会删除云盘中的任何文件。")
            }
            .onAppear {
                favorites = CloudFavoritesStore.load()
            }
        }
    }

    private func tabHeaderButton(title: String, tab: SourceTab) -> some View {
        let selected = activeTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                activeTab = tab
            }
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                Capsule()
                    .fill(selected ? MMTheme.accent : Color.clear)
                    .frame(width: 22, height: 3)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 我的设备

    private var devicesSection: some View {
        VStack(spacing: 14) {
            ForEach(store.accounts) { acct in
                HStack(spacing: 14) {
                    NavigationLink {
                        CloudDirectoryBrowserView(
                            account: acct,
                            initialFavorite: nil,
                            onFavoritesChanged: { favorites = CloudFavoritesStore.load() },
                            onScanFinished: onScanFinished
                        )
                        .onAppear {
                            store.activeAccountId = acct.id
                        }
                    } label: {
                        HStack(spacing: 14) {
                            ProviderBadgeIcon(kind: acct.provider, size: 46)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(acct.label)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(accountSubtitle(acct))
                                    .font(.caption)
                                    .foregroundStyle(subtitleColor(for: acct))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button {
                            Task { await testConnection(for: acct) }
                        } label: {
                            Label("检测连接", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        Button {
                            reloginTarget = acct
                        } label: {
                            Label("重新登录", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteTarget = acct
                        } label: {
                            Label("删除账号", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 36)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }

            // 添加文件来源卡片
            Button {
                showAddAccount = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus.square")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(width: 46, height: 32)
                    Text("添加文件来源")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 我的收藏

    private var favoritesSection: some View {
        VStack(spacing: 12) {
            let validFavs = favorites.filter { fav in
                store.accounts.contains(where: { $0.id == fav.accountId })
            }
            if validFavs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无收藏目录")
                        .font(.headline)
                    Text("进入网盘目录后，点击右上角星标即可收藏常用影视目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .padding(.horizontal, 20)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            } else {
                ForEach(validFavs) { fav in
                    if let acct = store.accounts.first(where: { $0.id == fav.accountId }) {
                        HStack(spacing: 12) {
                            NavigationLink {
                                CloudDirectoryBrowserView(
                                    account: acct,
                                    initialFavorite: fav,
                                    onFavoritesChanged: { favorites = CloudFavoritesStore.load() },
                                    onScanFinished: onScanFinished
                                )
                                .onAppear { store.activeAccountId = acct.id }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.title2)
                                        .foregroundStyle(MMTheme.accent)
                                        .frame(width: 38)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(fav.folderName)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(acct.label) · \(fav.pathLabel)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                favorites.removeAll { $0.id == fav.id }
                                CloudFavoritesStore.save(favorites)
                            } label: {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(MMTheme.accent)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    }
                }
            }
        }
    }

    private func accountSubtitle(_ acct: DriveAccount) -> String {
        if pingingAccountId == acct.id { return "正在检测连接…" }
        if let custom = pingStatusByAccount[acct.id] { return custom }
        if acct.provider == .webdav, let url = acct.extra["baseUrl"] ?? acct.extra["url"], !url.isEmpty {
            return "已连接 · \(url)"
        }
        return "已连接"
    }

    private func subtitleColor(for acct: DriveAccount) -> Color {
        if let status = pingStatusByAccount[acct.id], status.contains("失败") || status.contains("失效") {
            return MMTheme.redErr
        }
        return .secondary
    }

    private func testConnection(for acct: DriveAccount) async {
        pingingAccountId = acct.id
        defer { if pingingAccountId == acct.id { pingingAccountId = nil } }
        do {
            let drive = try store.buildDrive(for: acct)
            let ok = await drive.ping()
            pingStatusByAccount[acct.id] = ok ? "已连接 · 探测正常" : "连接失败，请尝试重新登录"
        } catch {
            pingStatusByAccount[acct.id] = "连接失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 网盘目录浏览与扫描页（推入二级页）

private struct CloudDirectoryBrowserView: View {
    let account: DriveAccount
    let initialFavorite: FavoriteCloudFolder?
    let onFavoritesChanged: () -> Void
    let onScanFinished: () -> Void

    @State private var store = AccountStore.shared
    @State private var pathStack: [(id: String, name: String)] = []
    @State private var entries: [CloudEntry] = []
    @State private var selectedIds: Set<String> = []
    @State private var loading = false
    @State private var errorMsg: String?
    @State private var loadEpoch = 0
    @State private var favorites: [FavoriteCloudFolder] = CloudFavoritesStore.load()

    private var defaultRootId: String {
        switch account.provider {
        case .webdav: return "/"
        case .guangya: return ""
        case .p123: return "0"
        }
    }

    private var currentFolder: (id: String, name: String) {
        pathStack.last ?? (defaultRootId, account.label)
    }

    private var currentPathLabel: String {
        let names = pathStack.map(\.name)
        return names.isEmpty ? "根目录" : names.joined(separator: " / ")
    }

    private var isCurrentFavorited: Bool {
        let cur = currentFolder
        return favorites.contains { $0.accountId == account.id && $0.folderId == cur.id }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 面包屑导航条
                if pathStack.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(pathStack.enumerated()), id: \.offset) { idx, seg in
                                Button(seg.name) {
                                    pathStack = Array(pathStack.prefix(idx + 1))
                                    selectedIds.removeAll()
                                    Task { await loadCurrent() }
                                }
                                .font(.caption)
                                .foregroundStyle(idx == pathStack.count - 1 ? .primary : MMTheme.accent)
                                if idx < pathStack.count - 1 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                }

                if let errorMsg {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MMTheme.redErr)
                        Text(errorMsg).font(.footnote).foregroundStyle(MMTheme.redErr)
                        Spacer()
                        Button("重试") { Task { await loadCurrent() } }
                            .font(.caption.weight(.medium))
                    }
                    .padding(12)
                    .background(MMTheme.redErr.opacity(0.1))
                }

                if loading && entries.isEmpty {
                    Spacer()
                    ProgressView("正在读取目录…")
                    Spacer()
                } else if entries.isEmpty {
                    ContentUnavailableView("空目录", systemImage: "folder", description: Text("当前目录下没有文件或子文件夹。"))
                } else {
                    List {
                        ForEach(entries) { entry in
                            HStack(spacing: 12) {
                                if entry.isDir {
                                    Button {
                                        if selectedIds.contains(entry.fileId) {
                                            selectedIds.remove(entry.fileId)
                                        } else {
                                            selectedIds.insert(entry.fileId)
                                        }
                                    } label: {
                                        Image(systemName: selectedIds.contains(entry.fileId) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selectedIds.contains(entry.fileId) ? MMTheme.accent : .secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                Image(systemName: entry.isDir ? "folder.fill" : (MediaParser.isVideo(entry.fileName) ? "film" : "doc"))
                                    .foregroundStyle(entry.isDir ? MMTheme.accent : .secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.fileName)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    if !entry.isDir && entry.size > 0 {
                                        Text(AppDirs.formatSize(entry.size))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if entry.isDir {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard entry.isDir else { return }
                                pathStack.append((entry.fileId, entry.fileName))
                                selectedIds.removeAll()
                                Task { await loadCurrent() }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await loadCurrent()
                    }
                }

                // 底部扫描操作条
                HStack(spacing: 12) {
                    if !selectedIds.isEmpty {
                        Button("清空勾选") {
                            selectedIds.removeAll()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(currentPathLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        startScan()
                    } label: {
                        Text(selectedIds.isEmpty ? "扫描当前目录" : "扫描已选 (\(selectedIds.count))")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(MMTheme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .disabled(BackgroundScanManager.shared.isScanning)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }


        }
        .navigationTitle(currentFolder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    toggleFavoriteCurrent()
                } label: {
                    Image(systemName: isCurrentFavorited ? "star.fill" : "star")
                        .foregroundStyle(isCurrentFavorited ? MMTheme.accent : .primary)
                }
                Button {
                    Task { await loadCurrent() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            if pathStack.isEmpty {
                let rootId = defaultRootId
                if let fav = initialFavorite, fav.folderId != rootId {
                    pathStack = [(rootId, account.label), (fav.folderId, fav.folderName)]
                } else {
                    pathStack = [(rootId, account.label)]
                }
            }
            await loadCurrent()
        }

    }

    private func toggleFavoriteCurrent() {
        let cur = currentFolder
        if let idx = favorites.firstIndex(where: { $0.accountId == account.id && $0.folderId == cur.id }) {
            favorites.remove(at: idx)
        } else {
            favorites.append(FavoriteCloudFolder(
                accountId: account.id,
                provider: account.provider,
                accountLabel: account.label,
                folderId: cur.id,
                folderName: cur.name,
                pathLabel: currentPathLabel
            ))
        }
        CloudFavoritesStore.save(favorites)
        onFavoritesChanged()
    }

    private func loadCurrent() async {
        loadEpoch += 1
        let epoch = loadEpoch
        loading = true
        errorMsg = nil
        do {
            let drive = try store.buildDrive(for: account)
            let list = try await drive.list(folderId: currentFolder.id)
            guard epoch == loadEpoch else { return }
            entries = list.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir && !b.isDir }
                return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            }
            loading = false
        } catch is CancellationError {
            if epoch == loadEpoch { loading = false }
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            if epoch == loadEpoch { loading = false }
        } catch {
            guard epoch == loadEpoch else { return }
            errorMsg = error.localizedDescription
            loading = false
        }
    }

    private func startScan() {
        guard !BackgroundScanManager.shared.isScanning else { return }
        errorMsg = nil
        let cur = currentFolder
        let picked: [PlanRoot]
        if selectedIds.isEmpty {
            picked = [PlanRoot(folderId: cur.id, name: cur.name)]
        } else {
            picked = entries
                .filter { $0.isDir && selectedIds.contains($0.fileId) }
                .map { PlanRoot(folderId: $0.fileId, name: $0.fileName) }
        }
        let targetRoots = picked.isEmpty ? [PlanRoot(folderId: cur.id, name: cur.name)] : picked
        selectedIds.removeAll()
        BackgroundScanManager.shared.startScan(account: account, roots: targetRoots)
    }
}
