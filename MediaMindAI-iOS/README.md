# MediaMind AI for iOS / iPadOS (v0.5.79)

MediaMind AI 的原生 SwiftUI / Swift Concurrency iOS & iPadOS 完整移植版（对齐 Android v0.5.79 全部核心能力）。

## 核心功能对齐
- **三大网盘驱动**：123 云盘（账号密码 + 官方登录中心 `WKWebView` 短信/扫码）、光鸭云盘（原生手机号 + 短信验证码 + E.164 国际区号标准化 + 自动续期 + OSS V1 签名上传）、WebDAV（RFC 4918 + 局域网 NAS 自动识别）。
- **分网盘乐观高速 + AIMD 防风控限流**：局域网 NAS 8 路并发（10–20ms）、123 云盘 5 路（60–120ms）、光鸭/远程 WebDAV 4 路（70–150ms），命中真实 429/405/142/143/154 才降档并学习安全下限。
- **影视识别与刮削管线**：繁转简/全角/水印去混淆、外链 ID（IMDb/TMDB/TVDB）、番剧集数与多集范围（`S01E01-E03`）、TMDB 80ms 节流 + 1024 条内存 LRU + 整季批量接口（NFO 与单集剧照共享请求）+ 合集官方海报与首部电影海报兜底。
- **AI 智能识别**：内置 DeepSeek、硅基流动、通义千问、智谱 GLM、Kimi 等 5 个中国大陆直连预设，以及 OpenAI、Google Gemini、本地 Ollama 与自定义 OpenAI 兼容接口。
- **安全与自适应 UI**：全部 API Key 与网盘凭据通过 iOS Keychain（`AfterFirstUnlockThisDeviceOnly`）加密存储；iPhone 底部 TabView + iPad 侧边栏 NavigationSplitView 原生自适应布局。

## 在 Mac 上构建运行
1. **方式一（推荐，直接双击打开）**：用 Xcode 16+ 打开 `MediaMindAI.xcodeproj`，在 `Signing & Capabilities` 选择你的 Apple Developer Team，连接真机或 iOS 17+ 模拟器按 `Cmd + R` 运行。
2. **方式二（XcodeGen 重建工程）**：在项目根目录执行 `xcodegen generate`，再打开生成的 `MediaMindAI.xcodeproj`。
3. **运行核心单元测试**：在终端执行 `swift test`（或在 Xcode 中按 `Cmd + U`）。
