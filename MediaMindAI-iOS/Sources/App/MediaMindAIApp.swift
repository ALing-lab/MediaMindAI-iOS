import SwiftUI

@main
struct MediaMindAIApp: App {
    @State private var showSplash = true
    @State private var settings = AppSettings.shared

    private var preferredScheme: ColorScheme? {
        switch settings.themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    init() {
        CrashReporter.install()
        let initialTmdbCfg = AppSettings.shared.tmdbNetConfig
        let initialFileLog = AppSettings.shared.netLogFileEnabled
        Task {
            await TmdbNet.shared.apply(initialTmdbCfg)
            await NetLog.shared.setFileEnabled(initialFileLog)
        }
        ExecutionEngine.shared.driveResolver = { accountId in
            guard let acct = AccountStore.shared.accounts.first(where: { $0.id == accountId }) else { return nil }
            return try? AccountStore.shared.buildDrive(for: acct)
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppRootView()
                    .tint(MMTheme.accent)
                if showSplash {
                    SplashView {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showSplash = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .preferredColorScheme(preferredScheme)
        }
    }
}
