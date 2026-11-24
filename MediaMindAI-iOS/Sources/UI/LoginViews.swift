import SwiftUI
import UIKit

/// 添加网盘账号入口页（123云盘 / 光鸭云盘原生验证码 / WebDAV）。
public struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    public init() {}
    @State private var selectedProvider: ProviderKind?

    public var body: some View {
        NavigationStack {
            List {
                Section("选择网盘提供方") {
                    ForEach(ProviderKind.allCases) { kind in
                        Button {
                            selectedProvider = kind
                        } label: {
                            HStack(spacing: 12) {
                                ProviderBadgeIcon(kind: kind)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.label).font(.headline).foregroundStyle(.primary)
                                    Text(kind.loginHint).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("添加云盘账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(item: $selectedProvider) { kind in
                switch kind {
                case .p123:
                    Pan123LoginView(onSuccess: { dismiss() })
                case .guangya:
                    GuangyaLoginView(onSuccess: { dismiss() })
                case .webdav:
                    WebDavLoginView(onSuccess: { dismiss() })
                }
            }
        }
    }
}

// MARK: - 光鸭云盘原生手机号 + 短信验证码登录（完整移植自 Android v0.5.77）

public struct GuangyaLoginView: View {
    public var targetAccountId: String? = nil
    public let onSuccess: () -> Void
    public init(targetAccountId: String? = nil, onSuccess: @escaping () -> Void) {
        self.targetAccountId = targetAccountId
        self.onSuccess = onSuccess
    }

    @State private var phone = ""
    @State private var smsCode = ""
    @State private var captchaToken = ""
    @State private var showCaptcha = false
    @State private var challenge: GySmsChallenge?
    @State private var challengePhone = ""
    @State private var sending = false
    @State private var submitting = false
    @State private var countdown = 0
    @State private var status = "使用手机号和短信验证码登录光鸭云盘"
    @State private var errorMsg: String?

    public var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ProviderBadgeIcon(kind: .guangya, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("登录光鸭云盘").font(.headline)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(footer: Text("直接填 11 位中国大陆手机号（自动补 +86），也支持 +1 / +44 / +852 等国际号码。")) {
                TextField("手机号（默认 +86）", text: $phone)
                    .keyboardType(.phonePad)
                    .onChange(of: phone) { _, newVal in
                        if challenge != nil, GuangyaDrive.normalizePhone(newVal) != challengePhone {
                            challenge = nil
                            countdown = 0
                            status = "手机号已变更，请重新获取验证码"
                        }
                        errorMsg = nil
                    }

                HStack {
                    TextField("短信验证码", text: $smsCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button {
                        Task { await requestSms() }
                    } label: {
                        Text(countdown > 0 ? "\(countdown)s" : (sending ? "发送中…" : "获取验证码"))
                            .monospacedDigit()
                            .frame(minWidth: 76)
                            .contentTransition(.identity)
                    }
                    .transaction { $0.animation = nil }
                    .disabled(sending || countdown > 0 || phone.trimmingCharacters(in: .whitespaces).count < 7)
                    .buttonStyle(.bordered)
                }

                if showCaptcha {
                    TextField("人机验证凭证（captcha_token，可选）", text: $captchaToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }

            if let errorMsg {
                Section {
                    Text(errorMsg).foregroundStyle(MMTheme.redErr).font(.footnote)
                }
            }

            Section {
                Button {
                    Task { await submitLogin() }
                } label: {
                    HStack {
                        Spacer()
                        if submitting { ProgressView().padding(.trailing, 6) }
                        Text(submitting ? "登录中…" : "登录").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(submitting || smsCode.trimmingCharacters(in: .whitespaces).count < 4)
            }
        }
        .navigationTitle("光鸭云盘登录")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: countdown) {
            guard countdown > 0 else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if countdown > 0 { countdown -= 1 }
        }
    }

    private func requestSms() async {
        sending = true
        errorMsg = nil
        status = "正在发送短信验证码…"
        defer { sending = false }
        do {
            let res = try await GuangyaDrive.sendSmsCode(rawPhone: phone, captchaToken: captchaToken)
            challenge = res
            challengePhone = GuangyaDrive.normalizePhone(phone)
            countdown = 60
            status = "验证码已发送，请查收短信"
        } catch let cap as GyCaptchaRequiredError {
            showCaptcha = true
            errorMsg = cap.message
            status = "需要人机验证"
        } catch {
            errorMsg = error.localizedDescription
            status = "发送失败"
        }
    }

    private func submitLogin() async {
        guard let ch = challenge else {
            errorMsg = "请先点击「获取验证码」后再登录"
            return
        }
        submitting = true
        errorMsg = nil
        status = "正在校验验证码并验证账号…"
        defer { submitting = false }
        do {
            let creds = try await GuangyaDrive.verifySmsLogin(challenge: ch, code: smsCode)
            let probe = GuangyaDrive(accountId: "validate", initialCreds: creds)
            guard await probe.ping() else {
                errorMsg = "凭据验证失败（根目录探测未通过），请重试"
                return
            }
            let suffix = creds.sub.isEmpty ? "账号" : String(creds.sub.suffix(4))
            AccountStore.shared.upsert(
                provider: .guangya,
                label: "光鸭 · \(suffix)",
                extra: creds.sub.isEmpty ? [:] : ["sub": creds.sub],
                secret: GuangyaDrive.encodeCreds(creds),
                targetId: targetAccountId,
                dedupeSub: creds.sub
            )
            status = "登录成功"
            onSuccess()
        } catch {
            errorMsg = error.localizedDescription
            status = "登录失败"
        }
    }
}

// MARK: - 123 云盘登录（原生账号密码直连）

public struct Pan123LoginView: View {
    public var targetAccountId: String? = nil
    public let onSuccess: () -> Void
    public init(targetAccountId: String? = nil, onSuccess: @escaping () -> Void) {
        self.targetAccountId = targetAccountId
        self.onSuccess = onSuccess
    }

    @State private var passport = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMsg: String?

    public var body: some View {
        Form {
            Section(footer: Text("手机号不带 +86；密码不会保存在本机。")) {
                TextField("手机号或邮箱", text: $passport)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            }
            if let errorMsg {
                Section { Text(errorMsg).foregroundStyle(MMTheme.redErr).font(.footnote) }
            }
            Section {
                Button {
                    Task { await loginPassword() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 6) }
                        Text(busy ? "登录中…" : "登录").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(busy || passport.isEmpty || password.isEmpty)
            }
        }
        .navigationTitle("123 云盘登录")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loginPassword() async {
        busy = true
        errorMsg = nil
        defer { busy = false }
        do {
            let token = try await Pan123Drive.loginPassport(passport, password: password)
            password = ""
            await verifyAndSave(token: token, labelSuffix: String(passport.suffix(4)))
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    private func verifyAndSave(token: String, labelSuffix: String) async {
        let probe = Pan123Drive(accountId: "validate", token: token)
        if await probe.ping() {
            AccountStore.shared.upsert(
                provider: .p123,
                label: "123 · \(labelSuffix.isEmpty ? "账号" : labelSuffix)",
                secret: token,
                targetId: targetAccountId
            )
            onSuccess()
        } else {
            errorMsg = "Token 探测失败，请重新登录"
        }
    }
}

// MARK: - WebDAV 登录（1:1 对齐 Android WebDavFormScreen：WebDavAddress 实时解析 + 示例速填 + check() + TOFU 证书指纹弹窗）

public struct WebDavLoginView: View {
    public var targetAccountId: String? = nil
    public let onSuccess: () -> Void
    public init(targetAccountId: String? = nil, onSuccess: @escaping () -> Void) {
        self.targetAccountId = targetAccountId
        self.onSuccess = onSuccess
    }

    @State private var label = ""
    @State private var baseUrl = "https://"
    @State private var username = ""
    @State private var password = ""
    @State private var trustSelfSigned = false
    @State private var certPin = ""
    @State private var showHelp = false
    @State private var busy = false
    @State private var errorMsg: String?
    @State private var testStatus: String?
    @State private var pendingUntrusted: CertPinning.UntrustedCertError?

    private var addrInfo: WebDavAddress.Info {
        WebDavAddress.describe(baseUrl)
    }

    private var isLan: Bool {
        guard let host = URL(string: baseUrl)?.host else { return false }
        return DriveRateProfile.isLanHost(host)
    }

    private var canSubmit: Bool {
        !busy && !addrInfo.error && baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).count > 10
    }

    public var body: some View {
        Form {
            Section {
                TextField("服务器地址（http:// 或 https://）", text: $baseUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(addrInfo.text)
                    .font(.caption)
                    .foregroundStyle(addrInfo.error ? MMTheme.redErr : .secondary)

                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                TextField("显示名称（可选，如 家里 NAS）", text: $label)
            } header: {
                Text("WebDAV 服务器")
            } footer: {
                Text(isLan
                     ? "已识别为局域网 NAS，将自动启用 8 路极速扫描与高并发写入。密码仅保存于本机 Keychain。"
                     : "远程 WebDAV（如 OpenList/AList）将自动启用 AIMD 防风控保护。密码仅保存于本机 Keychain。")
            }

            Section {
                DisclosureGroup("怎么填？查看常见 NAS / Alist 示例", isExpanded: $showHelp) {
                    Text(WebDavAddress.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)

                    ForEach(Array(WebDavAddress.examples.enumerated()), id: \.offset) { _, ex in
                        Button {
                            baseUrl = ex.url
                        } label: {
                            HStack {
                                Text(ex.label).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                Spacer()
                                Text(ex.url).font(.caption.monospaced()).foregroundStyle(MMTheme.accent)
                            }
                        }
                    }
                }
            }

            if baseUrl.lowercased().hasPrefix("https://") {
                Section {
                    Toggle("信任自签名 HTTPS 证书（TOFU 固定指纹）", isOn: $trustSelfSigned)
                    if trustSelfSigned {
                        TextField("SHA-256 指纹（留空则首次连接时弹窗确认）", text: $certPin)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("自签名证书安全选项")
                } footer: {
                    Text("仅信任你明确确认过的那一张服务器证书，绝不盲目放行未知证书。")
                }
            }

            if let testStatus {
                Section { Text(testStatus).foregroundStyle(MMTheme.greenOk).font(.footnote) }
            }
            if let errorMsg {
                Section { Text(errorMsg).foregroundStyle(MMTheme.redErr).font(.footnote) }
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 6) }
                        Text(busy ? "正在验证连接…" : "验证并保存").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle("WebDAV 配置")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "确认信任此自签名证书？",
            isPresented: Binding(
                get: { pendingUntrusted != nil },
                set: { if !$0 { pendingUntrusted = nil } }
            ),
            presenting: pendingUntrusted
        ) { cert in
            Button("信任并固定此指纹") {
                trustSelfSigned = true
                certPin = cert.fingerprint
                pendingUntrusted = nil
                Task { await connect() }
            }
            Button("取消", role: .cancel) {
                pendingUntrusted = nil
            }
        } message: { cert in
            Text("服务器 \(cert.host) 的证书未被系统信任。\n\nSHA-256 指纹：\n\(cert.fingerprint)\n\n确认是你的 NAS 后再信任。")
        }
    }

    private func connect() async {
        busy = true
        errorMsg = nil
        testStatus = nil
        defer { busy = false }
        let trimmedUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let pin = trustSelfSigned ? CertPinning.normalize(certPin) : nil
            let probe = try WebDavDrive(
                accountId: "validate",
                baseUrl: trimmedUrl,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                pinnedFingerprint: pin
            )
            let count = try await probe.check()
            testStatus = "连接成功（根目录共 \(count) 项）"
            let host = URL(string: trimmedUrl)?.host ?? "WebDAV"
            let title = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "WebDAV · \(host)" : label.trimmingCharacters(in: .whitespacesAndNewlines)
            AccountStore.shared.upsert(
                provider: .webdav,
                label: title,
                extra: [
                    "baseUrl": trimmedUrl,
                    "user": username.trimmingCharacters(in: .whitespacesAndNewlines),
                    "certPin": pin ?? "",
                ],
                secret: password,
                targetId: targetAccountId
            )
            onSuccess()
        } catch let untrusted as CertPinning.UntrustedCertError {
            if trustSelfSigned {
                pendingUntrusted = untrusted
                errorMsg = "需要确认并固定服务器证书指纹"
            } else {
                errorMsg = "服务器使用自签名证书（\(untrusted.host)）。如需信任请打开上方「信任自签名 HTTPS 证书」开关后重试。"
            }
        } catch {
            errorMsg = "连接失败：\(error.localizedDescription)"
        }
    }
}
