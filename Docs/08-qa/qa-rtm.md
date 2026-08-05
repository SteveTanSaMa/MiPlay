# 需求跟踪矩阵（RTM）

> 状态：2026-08-02 QA 执行版
> 证据：`QAArtifacts/Debug-20260802-final.xcresult`、`QAArtifacts/Release-20260802-arm64.xcresult`
> 自动化：30 tests passed, 0 failed, 0 skipped（Debug/Release arm64 各一轮）

## 判定规则

- **Auto Pass**：已由 XCTest 结果包证明。
- **Static Pass**：源码/语义契约检查通过，但不等同于运行时 UI 通过。
- **Pending**：需要真实 Wine、沙箱权限、网络、窗口或 VoiceOver 环境；本轮不伪造结果。
- **Out of Scope**：当前产品阶段没有实现或不属于本轮验收范围。

## 产品需求映射

| 需求 | 需求摘要 | 实现边界 | 自动化证据 | 当前结论 | 手工/集成补充 |
|---|---|---|---|---|---|
| F-M-01 | 选择游戏并启动 | `LaunchOrchestrator`, `ProcessManager` | 进程退出码、输出、timeout、取消、缺失 executable | Auto Pass（进程契约） | 真实 Wine 启动 Pending |
| F-M-02 | Wine 版本与 prefix | `WineRuntimeProvider`, `WineVersionDownloader` | 缺失 binary、prefix 路径契约 | Auto Pass（失败路径） | Wine binary、`WINEPREFIX`、权限 Pending |
| F-M-03 | 兼容方案应用与回滚 | `SolutionEngine` | 已发布 manifest、能力缺失、非法 rollback | Auto Pass（防护路径） | helper 权限与真实回滚 Pending |
| F-M-04 | 游戏状态总览 | `GameStateMachine`, `GameRegistry`, `TaskScheduler` | 合法/非法转换、任务结果投影、持久化 | Auto Pass |
| F-M-05 | 游戏路径与授权 | `GameLocation`, `GameRegistry` | legacy path、bookmark round-trip、迁移前未授权 | Auto Pass（数据契约） | stale bookmark / access denied Pending |
| F-M-06 | 安装引导与官方下载 | `NetworkDownloadProvider`, scheduler | 本轮不调用外网 | Pending | 网络替身集成、真实下载 Pending |
| F-M-07 | 文件完整性校验 | `FileIntegrityVerifier` | hash、缺失、版本、路径逃逸 | Auto Pass |
| F-S-01 | 更新提示 | `VersionChecker`, `TaskScheduler` | 注入远端版本、`updateAvailable`、进度与历史 | Auto Pass |
| F-S-02 | 背景素材 | `BackgroundMediaService`, `BackgroundScene` | 本轮无 UI/media 自动化 | Pending | 视频、图片与全失败 fallback Pending |
| F-S-03 | 性能辅助选项 | `PerformanceOptionManager` | 本轮未覆盖 | Pending | UI 与真实启动参数 Pending |
| F-S-04 | 中文/英文显示 | `GameStateMachine`, `GameType` | display facts 非空 | Static Pass | 系统语言切换与视觉本地化 Pending |
| F-S-05 | 日志导出 | `LogWriter`, `LogAndActionView` | 本轮未覆盖导出 UI | Pending | 手工导出与文件检查 Pending |

## 架构与状态需求

| 需求 | 验证内容 | 证据 | 当前结论 |
|---|---|---|---|
| A-01/A-02 | UI → ViewModel → Domain → Infrastructure，依赖方向不反转 | 静态结构审查；本轮未引入跨层调用 | Static Pass |
| A-03 | actor/异步边界下状态不丢失 | `GameRegistry`、`TaskScheduler` 异步测试 | Auto Pass（覆盖范围内） |
| A-04 | JSON 持久化、备份、迁移、损坏恢复 | 4 个 `PersistenceStore` 测试 | Auto Pass |
| A-05 | ViewModel/Domain 状态投影 | scheduler 完成后 registry 与 AppData 一致 | Auto Pass（任务路径） |
| A-06 | UI 行为由状态驱动 | 主按钮、Settings pane 语义契约 | Static Pass |
| A-07 | 任务可追踪、可取消、失败可恢复 | 5 个 `TaskScheduler` 测试 | Auto Pass |

## UX/UI 需求映射

| 需求 | 自动化/静态证据 | 真实 UI 状态 |
|---|---|---|
| Settings 打开、`⌘,`、关闭 | Settings 入口契约检查 | Pending：当前 ScreenCaptureKit `-3811`，无截图证据 |
| 六个 Settings pane | `SettingsView` 源码语义检查 | Pending：需 800×448 实机窗口检查 |
| 主按钮 enabled/disabled 与 VoiceOver label | `testPrimaryButtonAndSettingsAccessibilityContractsAreStable` | Static Pass；VoiceOver 实机朗读 Pending |
| 键盘导航 | 无 XCUITest target | Pending |
| hover、状态圆点层级、主按钮位置/圆角 | 无 UI 自动化 | Pending，需截图/录屏 |
| 背景视频/图片/default fallback、crossfade | 无 UI 自动化 | Pending |
| Loading 遮罩与交互阻断 | 无 UI 自动化 | Pending |
| LaunchFailed → game-detail/兼容方案 | 无 UI 自动化 | Pending |

## 测试方法索引

详细方法名与用例 ID见 [`qa-test-cases.md`](qa-test-cases.md)。本轮测试代码集中在 `MiPlayTests/MiPlayCoreTests.swift`，生产代码未修改。
