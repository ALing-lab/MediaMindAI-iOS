import SwiftUI

public enum MainTab: String, CaseIterable, Identifiable {
    case cloud, preview, tasks, settings

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cloud: return "云盘"
        case .preview: return "预览"
        case .tasks: return "任务"
        case .settings: return "设置"
        }
    }

    public var icon: String {
        switch self {
        case .cloud: return "cloud.fill"
        case .preview: return "eye.fill"
        case .tasks: return "bolt.fill"
        case .settings: return "gearshape.fill"
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
            TabView(selection: $selectedTab) {
                ForEach(MainTab.allCases) { tab in
                    tabContent(tab)
                        .tabItem { Label(tab.label, systemImage: tab.icon) }
                        .tag(tab)
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
