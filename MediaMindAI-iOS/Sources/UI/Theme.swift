import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// MediaMind AI 视觉配色（与 Android v0.5.78 IosTheme 完全对齐：标志性橙色 #FF8B37）。
public enum MMTheme {
    public static let accent = Color(red: 1.0, green: 0x8B / 255.0, blue: 0x37 / 255.0)
    public static let accentTint = Color(red: 1.0, green: 0x8B / 255.0, blue: 0x37 / 255.0).opacity(0.14)
    public static let purpleBadge = Color(red: 0xAF / 255.0, green: 0x52 / 255.0, blue: 0xDE / 255.0)
    public static let greenOk = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)
    public static let redErr = Color(red: 0xFF / 255.0, green: 0x3B / 255.0, blue: 0x30 / 255.0)

    public static func providerColor(_ kind: ProviderKind) -> Color {
        switch kind {
        case .p123: return Color(red: 0x3B / 255.0, green: 0x6C / 255.0, blue: 0xF5 / 255.0)
        case .guangya: return Color(red: 0xFF / 255.0, green: 0x8B / 255.0, blue: 0x37 / 255.0)
        case .webdav: return Color(red: 0x30 / 255.0, green: 0xB0 / 255.0, blue: 0xC7 / 255.0)
        }
    }

    public static func providerSymbol(_ kind: ProviderKind) -> String {
        switch kind {
        case .p123: return "cloud.fill"
        case .guangya: return "sun.max.fill"
        case .webdav: return "externaldrive.connected.to.line.below.fill"
        }
    }
}

public struct ProviderBadgeIcon: View {
    public let kind: ProviderKind
    public var size: CGFloat = 36
    public init(kind: ProviderKind, size: CGFloat = 36) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(MMTheme.providerColor(kind))
            Image(systemName: MMTheme.providerSymbol(kind))
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// TMDB 代理海报缩略图组件（1:1 对标 Android `TmdbImage.kt`）：
/// 走 `TmdbImageLoader`（代理 + 镜像回退 + 防劫持）；无图显示占位图标；失败显示点击重试图标。
public struct TmdbImageView: View {
    public let url: URL?
    public var placeholderSystemName: String
    public var allowRetry: Bool
    public var hidePlaceholderOnFailure: Bool

    #if canImport(UIKit)
    @State private var decodedImage: UIImage? = nil
    #endif
    @State private var failed = false
    @State private var attempt = 0
    @State private var loadedUrl: String? = nil

    public init(
        url: URL?,
        placeholderSystemName: String = "film",
        allowRetry: Bool = true,
        hidePlaceholderOnFailure: Bool = false
    ) {
        self.url = url
        self.placeholderSystemName = placeholderSystemName
        self.allowRetry = allowRetry
        self.hidePlaceholderOnFailure = hidePlaceholderOnFailure
    }

    public var body: some View {
        ZStack {
            if url != nil {
                #if canImport(UIKit)
                if let uiImg = decodedImage {
                    Color.clear
                        .overlay(
                            Image(uiImage: uiImg)
                                .resizable()
                                .scaledToFill()
                        )
                        .clipped()
                } else if failed {
                    if allowRetry {
                        Button {
                            failed = false
                            attempt += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("重试加载海报")
                    } else if hidePlaceholderOnFailure {
                        Color.clear
                    } else {
                        Image(systemName: placeholderSystemName)
                            .foregroundStyle(.secondary)
                    }
                } else if !hidePlaceholderOnFailure {
                    ProgressView()
                        .controlSize(.small)
                }
                #else
                Image(systemName: placeholderSystemName)
                    .foregroundStyle(.secondary)
                #endif
            } else if !hidePlaceholderOnFailure {
                Image(systemName: placeholderSystemName)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: url?.absoluteString) { _, newVal in
            if newVal != loadedUrl {
                #if canImport(UIKit)
                decodedImage = nil
                #endif
                loadedUrl = nil
                failed = false
                attempt = 0
            }
        }
        .task(id: "\(url?.absoluteString ?? "")#\(attempt)") {
            guard let url else {
                #if canImport(UIKit)
                decodedImage = nil
                #endif
                loadedUrl = nil
                failed = false
                return
            }
            let targetUrl = url.absoluteString
            if loadedUrl != targetUrl {
                #if canImport(UIKit)
                decodedImage = nil
                #endif
            }
            failed = false
            let data = await TmdbImageLoader.shared.load(urlString: targetUrl, bypassCache: attempt > 0)
            guard !Task.isCancelled else { return }
            #if canImport(UIKit)
            if let data, let img = UIImage(data: data) {
                decodedImage = img
                loadedUrl = targetUrl
                failed = false
            } else {
                decodedImage = nil
                failed = true
            }
            #else
            failed = (data == nil)
            #endif
        }
    }
}

extension MMTheme {
    public static func opLabel(_ op: String) -> String {
        switch op {
        case "rename": return "重命名"
        case "mkdir": return "新建目录"
        case "move": return "移动"
        case "artwork": return "刮削"
        case "delete", "trash": return "清理"
        case "skip": return "跳过"
        case "unmatched": return "待匹配"
        case "upload": return "上传"
        case "backup": return "备份"
        case "quarantine": return "暂存"
        case "retention_move": return "保留区"
        case "undo_stash": return "撤销暂存"
        default: return op
        }
    }
}

/// 统一顶部柔和品牌光晕（用于云盘 / 预览 / 任务 / 设置四大主页面）。
public struct TopAmbientGlow: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [
                MMTheme.accent.opacity(0.22),
                MMTheme.accent.opacity(0.06),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 180)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

/// 按需展开搜索条：默认收起不占版面、推入过渡零重影；点右上角放大镜后平滑展开并自动聚焦。
public struct CollapsibleSearchBar: View {
    @Binding public var text: String
    @Binding public var isPresented: Bool
    public let prompt: String
    @FocusState private var focused: Bool

    public init(text: Binding<String>, isPresented: Binding<Bool>, prompt: String) {
        self._text = text
        self._isPresented = isPresented
        self.prompt = prompt
    }

    public var body: some View {
        if isPresented {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(prompt, text: $text)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button("取消") {
                    focused = false
                    text = ""
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }
                .font(.subheadline)
                .foregroundStyle(MMTheme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .clipped()
            .transition(.move(edge: .top).combined(with: .opacity))
            .task {
                // 等待搜索栏 0.2s 展开动画完成后再拉起键盘，避免主线程冷启动输入法与列表重排动画冲突导致卡顿
                try? await Task.sleep(for: .milliseconds(230))
                guard !Task.isCancelled, isPresented else { return }
                focused = true
            }
            .onDisappear {
                focused = false
            }
        }
    }
}

/// 底部悬浮圆形放大镜搜索组件（贴合 iOS 26/27 Liquid Glass 视觉，默认收起为右下角独立圆标，点击后在底部平滑展开搜索胶囊）。
public struct BottomFloatingSearchModifier: ViewModifier {
    @Binding var text: String
    let prompt: String
    let bottomOffset: CGFloat
    let visible: Bool

    @State private var isExpanded = false
    @FocusState private var focused: Bool

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if visible {
                    if isExpanded {
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                TextField(prompt, text: $text)
                                    .focused($focused)
                                    .font(.subheadline)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.search)
                                if !text.isEmpty {
                                    Button {
                                        text = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8))
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                            Button {
                                focused = false
                                text = ""
                                withAnimation(.snappy(duration: 0.22)) {
                                    isExpanded = false
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(.label))
                                    .frame(width: 42, height: 42)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8))
                                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottomOffset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .milliseconds(220))
                            guard !Task.isCancelled, isExpanded else { return }
                            focused = true
                        }
                        .onDisappear {
                            focused = false
                        }
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                isExpanded = true
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(text.isEmpty ? Color(.label) : MMTheme.accent)
                                    .frame(width: 48, height: 48)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(
                                        Circle().strokeBorder(
                                            text.isEmpty ? Color.primary.opacity(0.12) : MMTheme.accent.opacity(0.45),
                                            lineWidth: 0.8
                                        )
                                    )
                                    .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
                                if !text.isEmpty {
                                    Circle()
                                        .fill(MMTheme.accent)
                                        .frame(width: 9, height: 9)
                                        .offset(x: -4, y: 4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("搜索")
                        .padding(.trailing, 18)
                        .padding(.bottom, bottomOffset)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
            .onChange(of: visible) { _, nowVisible in
                if !nowVisible {
                    focused = false
                    isExpanded = false
                }
            }
    }
}

public extension View {
    func bottomFloatingSearch(
        text: Binding<String>,
        prompt: String,
        bottomOffset: CGFloat = 16,
        visible: Bool = true
    ) -> some View {
        modifier(BottomFloatingSearchModifier(text: text, prompt: prompt, bottomOffset: bottomOffset, visible: visible))
    }
}
