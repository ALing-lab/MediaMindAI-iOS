import SwiftUI
import AVFoundation

/// 1:1 复刻自 Android `MainActivity.kt` 双 M 深浅色全屏视频开屏动画（AVPlayerLayer center-crop + 12 秒看门狗 + 播放完成/后台/点击自动淡出）。
public struct SplashView: View {
    public let onDone: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var finished = false

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    private var isDark: Bool { colorScheme == .dark }
    private var bgColor: Color {
        isDark ? Color(red: 0x20 / 255.0, green: 0x20 / 255.0, blue: 0x20 / 255.0) : .white
    }

    private var videoUrl: URL? {
        let name = isDark ? "splash_dark" : "splash_light"
        return Bundle.main.url(forResource: name, withExtension: "mp4")
    }

    public var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()
            if let url = videoUrl {
                SplashVideoPlayerView(url: url, onEnded: finish)
                    .ignoresSafeArea()
            } else {
                // 资源缺失时的平滑品牌字标兜底
                VStack(spacing: 16) {
                    Image(isDark ? "wordmark_dark" : "wordmark_light")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220)
                }
                .task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    finish()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            finish()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { finish() }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }
}

#if canImport(UIKit)
import UIKit

private final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct SplashVideoPlayerView: UIViewRepresentable {
    let url: URL
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEnded: onEnded) }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .clear
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.observe(item: item, player: player)
        player.play()
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.cleanup()
        uiView.playerLayer.player = nil
    }

    final class Coordinator {
        private let onEnded: () -> Void
        private var player: AVPlayer?
        private var observer: NSObjectProtocol?

        init(onEnded: @escaping () -> Void) { self.onEnded = onEnded }

        func observe(item: AVPlayerItem, player: AVPlayer) {
            self.player = player
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onEnded()
            }
        }

        func cleanup() {
            player?.pause()
            player = nil
            if let obs = observer {
                NotificationCenter.default.removeObserver(obs)
                observer = nil
            }
        }

        deinit { cleanup() }
    }
}
#else
private struct SplashVideoPlayerView: View {
    let url: URL
    let onEnded: () -> Void
    var body: some View {
        Color.clear.task { onEnded() }
    }
}
#endif
