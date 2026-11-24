import SwiftUI

/// 1:1 复刻自 Android `AccountsScreens.kt`：多云盘账号管理中心（原生 SwiftUI）。
public struct AccountsManageView: View {
    @State private var store = AccountStore.shared
    @State private var showAdd = false

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(store.accounts) { acct in
                    NavigationLink {
                        AccountDetailView(accountId: acct.id)
                    } label: {
                        HStack(spacing: 12) {
                            ProviderBadgeIcon(kind: acct.provider, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(acct.label).font(.headline)
                                    if acct.id == store.activeAccountId {
                                        Text("当前浏览")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(MMTheme.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(MMTheme.accentTint, in: Capsule())
                                    }
                                }
                                Text(subtitle(for: acct))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            let hasSecret = !(store.secretOf(id: acct.id) ?? "").isEmpty
                            Text(hasSecret ? "已登录" : "未登录")
                                .font(.caption)
                                .foregroundStyle(hasSecret ? MMTheme.greenOk : .secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { idxs in
                    let ids = idxs.compactMap { store.accounts.indices.contains($0) ? store.accounts[$0].id : nil }
                    for id in ids { store.remove(id: id) }
                }

                Button {
                    showAdd = true
                } label: {
                    Label("添加网盘账号", systemImage: "plus.circle.fill")
                        .foregroundStyle(MMTheme.accent)
                }
            } header: {
                Text("网盘账号（\(store.accounts.count)）")
            } footer: {
                Text("「云盘」页顶部可以快速切换正在浏览的网盘。所有登录令牌与密码仅保存在本机 iOS Keychain 加密存储。")
            }
        }
        .navigationTitle("云盘账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddAccountSheet()
        }
    }

    private func subtitle(for acct: DriveAccount) -> String {
        var parts = [acct.provider.label]
        if let url = acct.extra["baseUrl"] ?? acct.extra["url"], !url.isEmpty {
            parts.append(url)
        } else if let phone = acct.extra["phone"], !phone.isEmpty {
            parts.append(phone)
        }
        return parts.joined(separator: " · ")
    }
}

/// 1:1 复刻自 Android `AccountDetailScreen`：账号重命名、连通性测试、切换活动账号、重新登录与二次确认移除。
public struct AccountDetailView: View {
    public let accountId: String

    @Environment(\.dismiss) private var dismiss
    @State private var store = AccountStore.shared
    @State private var editedLabel = ""
    @State private var pinging = false
    @State private var pingResult: String?
    @State private var pingOk = false
    @State private var showReloginSheet = false
    @State private var showRemoveConfirm = false

    public init(accountId: String) {
        self.accountId = accountId
    }

    private var account: DriveAccount? {
        store.get(id: accountId)
    }

    public var body: some View {
        Group {
            if let acct = account {
                Form {
                    Section("账号信息") {
                        HStack(spacing: 12) {
                            ProviderBadgeIcon(kind: acct.provider, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(acct.label).font(.headline)
                                Text(acct.provider.label).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.activeAccountId == acct.id {
                                Text("当前活动")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(MMTheme.accent)
                            }
                        }
                        .padding(.vertical, 4)

                        HStack {
                            TextField("账号显示名称", text: $editedLabel)
                            Button("保存名称") {
                                store.rename(id: acct.id, label: editedLabel)
                            }
                            .buttonStyle(.bordered)
                            .disabled(editedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editedLabel == acct.label)
                        }

                        if let url = acct.extra["baseUrl"] ?? acct.extra["url"], !url.isEmpty {
                            LabeledContent("服务器地址", value: url)
                        }
                        if let user = acct.extra["user"], !user.isEmpty {
                            LabeledContent("用户名", value: user)
                        }
                        if let pin = acct.extra["certPin"] ?? acct.extra["pin"], !pin.isEmpty {
                            LabeledContent("已固定证书指纹", value: String(pin.prefix(23)) + "…")
                        }
                        LabeledContent("账号 ID", value: acct.id)
                    }

                    Section("连接与切换") {
                        if store.activeAccountId != acct.id {
                            Button {
                                store.activeAccountId = acct.id
                            } label: {
                                Label("设为当前活动账号", systemImage: "checkmark.circle")
                            }
                        }

                        Button {
                            Task { await runConnectivityCheck(acct) }
                        } label: {
                            HStack {
                                if pinging { ProgressView().padding(.trailing, 6) }
                                Label(pinging ? "正在检测连通性…" : "测试云盘连通性", systemImage: "network")
                            }
                        }
                        .disabled(pinging)

                        if let pingResult {
                            Text(pingResult)
                                .font(.footnote)
                                .foregroundStyle(pingOk ? MMTheme.greenOk : MMTheme.redErr)
                        }

                        Button {
                            showReloginSheet = true
                        } label: {
                            Label("重新登录 / 更新凭据", systemImage: "key.fill")
                        }
                    }

                    Section {
                        Button("移除此账号", role: .destructive) {
                            showRemoveConfirm = true
                        }
                    } footer: {
                        Text("移除账号会同时清除本机 Keychain 中保存的登录令牌或密码，不会影响云盘上的文件。")
                    }
                }
                .onAppear {
                    if editedLabel.isEmpty { editedLabel = acct.label }
                }
                .sheet(isPresented: $showReloginSheet) {
                    NavigationStack {
                        Group {
                            switch acct.provider {
                            case .p123:
                                Pan123LoginView(targetAccountId: acct.id) { showReloginSheet = false }
                            case .guangya:
                                GuangyaLoginView(targetAccountId: acct.id) { showReloginSheet = false }
                            case .webdav:
                                WebDavLoginView(targetAccountId: acct.id) { showReloginSheet = false }
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showReloginSheet = false }
                            }
                        }
                    }
                }
                .confirmationDialog("确认移除账号「\(acct.label)」？", isPresented: $showRemoveConfirm, titleVisibility: .visible) {
                    Button("确认移除", role: .destructive) {
                        store.remove(id: acct.id)
                        dismiss()
                    }
                    Button("取消", role: .cancel) {}
                }
            } else {
                ContentUnavailableView("该账号已被移除", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        .navigationTitle("账号详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runConnectivityCheck(_ acct: DriveAccount) async {
        pinging = true
        pingResult = nil
        pingOk = false
        defer { pinging = false }
        do {
            let drive = try store.buildDrive(for: acct)
            if acct.provider == .webdav {
                let baseUrl = acct.extra["baseUrl"] ?? acct.extra["url"] ?? ""
                let user = acct.extra["user"] ?? ""
                let pass = store.secretOf(id: acct.id) ?? ""
                let pin = acct.extra["certPin"] ?? acct.extra["pin"]
                let wd = try WebDavDrive(accountId: acct.id, baseUrl: baseUrl, username: user, password: pass, pinnedFingerprint: pin)
                let count = try await wd.check()
                pingOk = true
                pingResult = "连接正常（根目录共 \(count) 项，\(wd.isLanEndpoint ? "局域网高速模式" : "远程限频模式")）"
            } else {
                let ok = await drive.ping()
                pingOk = ok
                pingResult = ok ? "连接正常，鉴权有效" : "连接失败，请检查网络或重新登录"
            }
        } catch {
            pingOk = false
            pingResult = "检测失败：\(error.localizedDescription)"
        }
    }
}
