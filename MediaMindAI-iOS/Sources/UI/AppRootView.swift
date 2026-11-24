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

    public init() {}

    public var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(MainTab.allCases, selection: $selectedTab) { tab in
                    Label(tab.label, systemImage: tab.icon)
                        .tag(tab)
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
            TasksTabView()
        case .settings:
            SettingsTabView()
        }
    }
}
