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
