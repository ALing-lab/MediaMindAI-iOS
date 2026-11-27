# fix13 CI 测试编译修正（2026-11-27）

fix12 CI run 46059296133：App 编译通过，IPA 已产出；测试目标编译失败，225 项测试均未执行。

已修正 Batch1ScrapeTests.swift 两处及 ScrapeAndScannerSuiteTests.swift 一处 PolicyOverride 参数顺序，将 episodeNfo 放在 downloadEpisodeThumb 前。第三处为同类检查补充发现。生产代码未修改。

全部 13 个 PolicyOverride 调用已按当前初始化器声明顺序检查通过；两个修改文件静态解析无诊断。本机无 Swift/Xcode，尚未重新编译或运行测试；请 CI 编译并执行全部 225 项，包含先前修正的 WebDAV 夹具测试。不能将 fix12 App 编译通过视为 fix13 测试通过。
