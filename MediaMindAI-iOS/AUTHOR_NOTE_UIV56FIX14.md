# fix14 测试 actor 隔离修复（2026-11-27）

fix13 CI run 46060269475：App 编译通过，IPA 已产出；测试目标未编译通过，225 项仍未运行。

根因：fix12 新增测试插在原 @MainActor 与 testRetentionZoneMoveRestoreProtectAndCleanup 之间，使旧测试失去隔离声明。将标注还给旧测试，新测试不需要该标注。修改仅涉及 ExecReversibleRetentionArtworkTests.swift 两行标注位置，不改生产代码、测试逻辑或测试数量。

## fix12 六个修改测试文件的专项自查

- 与 fix11 比较所有旧测试及辅助方法的 @MainActor 声明；修复后未发现其他隔离标注丢失。
- 检查新增 46 个测试的方法隔离、共享 MainActor 引用与 await；未发现其他确定遗漏。已核对原 cleanupProtectedTaskIds 隔离声明。
- 对六个文件的 477 处能够匹配显式初始化器声明的构造调用检查参数顺序，未发现倒序。无法匹配／合成初始化器不包含在该数值中，不是 Swift 类型检查。
- 检查 XCTest 参数中异步调用，未发现 await 被放入同步断言 autoclosure；全部修改测试文件静态解析无诊断。
- 方法总数仍为 225。生产代码与 fix13 完全一致。

本机没有 Swift／Xcode，以上是静态检查，不代表测试目标已经编译通过。请 CI 编译 App 和测试目标，运行全部 XCTest；WebDAV 夹具修复至今没有实跑，需一并确认。不能排除编译器进一步发现其他问题。
