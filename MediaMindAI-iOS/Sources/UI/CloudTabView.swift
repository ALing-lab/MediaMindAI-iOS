import SwiftUI

/// 云盘目录浏览与扫描启动页（对标 Android CloudScreen）。
public struct CloudTabView: View {
    public let onScanFinished: () -> Void
    public init(onScanFinished: @escaping () -> Void = {}) {
        self.onScanFinished = onScanFinished
    }

    @State private var store = AccountStore.shared
    @State private var showAddAccount = false
    @State private var pathStack: [(id: String, name: String)] = []
    @State private var entries: [CloudEntry] = []
    @State private var selectedIds: Set<String> = []
    @State private var loading = false
    @State private var loadEpoch = 0
    @State private var scanning = false
    @State private var scanProgress = ""
    @State private var errorMsg: String?

    private var currentAccount: DriveAccount? { store.activeAccount }

    public var body: some View {
        NavigationStack {
            Group {
                if let acct = currentAccount {
                    VStack(spacing: 0) {
                        if scanning {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(scanProgress.isEmpty ? "正在扫描识别…" : scanProgress)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .background(MMTheme.accentTint)
                        }

                        if !pathStack.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Button("根目录") {
                                        pathStack.removeAll()
                                        selectedIds.removeAll()
                                        Task { await loadFolder(acct.provider.rootId, account: acct) }
                                    }
                                    .font(.caption)
                                    ForEach(Array(pathStack.enumerated()), id: \.offset) { idx, item in
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                        Button(item.name) {
                                            pathStack = Array(pathStack.prefix(idx + 1))
                                            selectedIds.removeAll()
                                            Task { await loadFolder(item.id, account: acct) }
                                        }
                                        .font(.caption)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                        }

                        if let errorMsg {
                            Text(errorMsg).font(.footnote).foregroundStyle(MMTheme.redErr).padding()
                        }

                        List {
                            if loading {
                                HStack { Spacer(); ProgressView(); Spacer() }
                            } else if entries.isEmpty {
                                ContentUnavailableView("空目录", systemImage: "folder", description: Text("当前目录下没有文件或子文件夹"))
                            } else {
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
                                                    .foregroundStyle(selectedIds.contains(entry.fileId) ? MMTheme.accent : .secondary)
                                                    .font(.title3)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Image(systemName: entry.isDir ? "folder.fill" : (MediaParser.isVideo(entry.fileName) ? "film" : "doc"))
                                            .foregroundStyle(entry.isDir ? MMTheme.accent : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.fileName).lineLimit(1)
                                            if !entry.isDir && entry.size > 0 {
                                                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if entry.isDir {
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard entry.isDir else { return }
                                        pathStack.append((entry.fileId, entry.fileName))
                                        selectedIds.removeAll()
                                        Task { await loadFolder(entry.fileId, account: acct) }
                                    }
                                }
                            }
                        }

                        if !selectedIds.isEmpty {
                            HStack {
                                Text("已选 \(selectedIds.count) 个目录").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    Task { await startScan(account: acct) }
                                } label: {
                                    Text("开始识别刮削").fontWeight(.semibold)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 10)
                                        .background(MMTheme.accent, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                                .disabled(scanning)
                            }
                            .padding()
                            .background(.bar)
                        }
                    }
                    .task(id: acct.id) {
                        pathStack.removeAll()
                        selectedIds.removeAll()
                        await loadFolder(acct.provider.rootId, account: acct)
                    }
                } else {
                    ContentUnavailableView {
                        Label("尚未添加云盘账号", systemImage: "cloud.fill")
                    } description: {
                        Text("支持 123 云盘、光鸭云盘（原生短信验证码）与 WebDAV / 局域网 NAS。")
                    } actions: {
                        Button("添加云盘账号") { showAddAccount = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(currentAccount?.label ?? "云盘")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.accounts.isEmpty {
                        Menu {
                            ForEach(store.accounts) { acct in
                                Button {
                                    store.activeAccountId = acct.id
                                } label: {
                                    Label(acct.label, systemImage: acct.id == store.activeAccountId ? "checkmark" : MMTheme.providerSymbol(acct.provider))
                                }
                            }
                            Divider()
                            Button("添加新账号…") { showAddAccount = true }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddAccount = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountSheet()
            }
        }
    }

    private func loadFolder(_ folderId: String, account: DriveAccount) async {
        loadEpoch += 1
        let epoch = loadEpoch
        loading = true
        errorMsg = nil
        do {
            let drive = try store.buildDrive(for: account)
            let list = try await drive.list(folderId: folderId)
            guard epoch == loadEpoch else { return }
            entries = list.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            }
            loading = false
        } catch is CancellationError {
            return
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return
        } catch {
            guard epoch == loadEpoch else { return }
            errorMsg = error.localizedDescription
            loading = false
        }
    }

    private func startScan(account: DriveAccount) async {
        guard !KeychainStore.tmdbApiKey.isEmpty else {
            errorMsg = "请先在「设置 → TMDB 网络」填写 TMDB API Key"
            return
        }
        scanning = true
        errorMsg = nil
        scanProgress = "正在初始化扫描…"
        defer { scanning = false }
        do {
            let drive = try store.buildDrive(for: account)
            let curParent = pathStack.last?.id ?? account.provider.rootId
            let roots = entries.filter { selectedIds.contains($0.fileId) }.map { PlanRoot(folderId: $0.fileId, name: $0.fileName, parentId: curParent) }
            let plan = try await Scanner.scan(roots: roots, drive: drive, organizedKeys: AppSettings.shared.rememberHistory ? PlanAndTaskStore.shared.organizedFolderKeys : []) { msg, count in
                Task { @MainActor in scanProgress = "\(msg)（已发现 \(count) 个视频）" }
            }
            PlanAndTaskStore.shared.savePlan(plan)
            selectedIds.removeAll()
            onScanFinished()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
