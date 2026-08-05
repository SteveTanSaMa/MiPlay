# 测试策略

> 状态：2026-08-02 执行版
> 目标：为进程、权限边界、状态流、持久化和完整性校验建立回归保护。

## 测试金字塔

目标比例为 Unit 70% / Integration 20% / UI 10%。当前 target 只有 `MiPlayTests`，尚未建立 XCUITest target，因此本轮以可重复的 Domain/Infrastructure contract tests 为主，UI/Wine/系统权限列为手工或集成门禁。

| 层级 | 本轮状态 | 内容 |
|---|---|---|
| Unit/contract | 30 个方法全部执行 | GameStateMachine、PersistenceStore、GameLocation、FileIntegrityVerifier、TaskScheduler、SolutionEngine |
| Process integration | 已执行 | `ProcessManager` 使用稳定的 `/bin/sh` fixture，覆盖 stdout/stderr、退出码、timeout、取消和大量输出 |
| UI automation | 未建立 | 仅有按钮/Settings 语义契约检查；窗口、键盘、VoiceOver、视觉行为 Pending |
| Real integration/manual | 未执行 | Wine binary、prefix、系统权限、网络和真实 bookmark 授权必须单独执行 |

## 替身与隔离策略

- 网络：不访问外网；`VersionChecker` 使用注入的 latest-version fixture。真实下载和 API 错误作为集成测试。
- 文件系统：每个测试使用独立 temporary directory；不会读写用户游戏目录。真实沙箱/bookmark 授权单独手工验证。
- Process：使用 `/bin/sh` 的确定性命令作为 ProcessManager contract fixture；不启动 Wine 或游戏。真实 Wine 启动独立验证。
- 时间/取消：使用短 timeout 与 Swift concurrency cancellation，验证单次 resume 和子进程清理。
- 结果隔离：每轮通过 `-resultBundlePath` 保存 `.xcresult` 与完整日志。

## 优先级

- P0：进程生命周期、持久化恢复/写入失败、路径迁移、完整性校验、状态机、任务调度，共 25 个自动化检查。
- P1：版本比较、Wine binary/prefix 契约、兼容方案边界、UI accessibility 语义，共 5 个自动化检查。
- P2：视觉布局、真实网络、性能、跨 macOS/芯片矩阵，保留为手工/发布前测试。

## 回归层次

1. **Smoke**：应用启动、主窗口、Settings、状态显示、日志导出、退出；当前 UI 环境受 ScreenCaptureKit 阻断，未判定 Pass。
2. **P0 regression**：运行 `MiPlayTests` 全部 P0 方法；Debug/Release arm64 均 100% Pass。
3. **P1 regression**：运行全部 P1 方法；Debug/Release arm64 均 100% Pass。
4. **Release/manual**：真实 Wine、系统权限、bookmark stale/access denied、VoiceOver、键盘、本地化、背景 fallback 和性能。

## 入口与出口

入口：生产代码完成 Review；测试 fixture 不依赖外网或用户目录；Debug 与 Release 的测试 scheme 可构建。

出口：P0 100%；P1 ≥95%；结果包存在；每个未通过项有日志和归因；UI/Wine/性能若未执行必须保持 Pending，不能折算为自动化通过。
