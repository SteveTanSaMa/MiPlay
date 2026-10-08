# MiPlay Implementation Notes

> Implementation Agent report for the frozen architecture contracts.
> Source: Architecture Design -> implementation traceability

## 2026-10-07 退出原因误判修正（Codex）

- 用户反馈：闪退与手动强制退出均显示反作弊不兼容。新增 GameExitDiagnostic 统一诊断，先判断真实信号或未知状态；驱动名必须和明确加载失败证据同条出现才显示可能的兼容问题。
- LaunchServices 每次启动前清空本次日志/旧状态，缺失状态改为 -1/false，不再虚构 signal:0；直接子进程启动阶段保留终止信号。正常退出清除旧诊断。
- 6 个针对性测试通过，含真实 SIGKILL 子进程与随包 GameLauncher 测试。全量 124 tests / 2 failures；复测 Wine 用例通过，退出恢复用例仍失败。未宣称全量通过，未改恢复链路或真实游戏。
- 详细原因、能力边界、验证和交接：[退出诊断审查](../06-review/review-exit-diagnosis-2026-10-07.md)。本轮未提交 Git，保留此前 UI 与所有遗留改动。

## 2026-10-07 UI 通透度调整（Codex，第二轮）

- 用户反馈黑色玻璃“不够透”。移除 DarkGlassSurface 的 0.55 黑色固定底色，改用 `.clear.tint(.black.opacity(0.18))`；面板投影减轻，文字和图标添加局部 1pt 阴影。保留选中描边、交互语义和减少透明度 fallback。
- 本轮仍只修改 DarkGlassSurface.swift、PrimaryActionButton.swift、GameSelectionRailView.swift。第一版截图保留，新增 `QAArtifacts/UI-BlackGlass-20261007/*-translucent.png`。
- 验证：同一原生预览检查主题与浅/深背景，Debug arm64 build。纯视觉参数调整未重复上一轮 120 项全量测试。未使用 computer use、未启动游戏、未改应用数据、未提交 Git。
- 当前方案与交接见 [UI 修订第二轮](../03-ui/ui-revision-2026-10-07.md)。

## 2026-10-07 UI 黑色液态玻璃试用（Codex）

- 用户目标：优化白色玻璃的可识别度，尝试黑色；尽量不用 computer use，允许截图。
- 本轮仅新增 `UI/Components/DarkGlassSurface.swift`，修改 `PrimaryActionButton.swift` 和 `GameSelectionRailView.swift`；未修改业务、启动链路或设置窗口。
- 局部黑色底色 + 原生黑 tint 玻璃、白色文字/图标、独立选中描边；禁用按钮移除全局 0.35 opacity，保留系统禁用反馈。减少透明度/提高对比度有对应渲染路径。
- 验证：Debug arm64 120 tests / 0 failures。最后的设置描边对齐修正已重新完成截图和 Debug build。
- 通过独立原生静态预览检查浅/深背景与原神、星穹铁道、绝区零缓存主题；未使用 computer use、未启动游戏、未改应用数据。截图不代表真实应用交互或辅助功能实测。
- 完整计划、参数、证据与轮流协作交接：[UI 修订 2026-10-07](../03-ui/ui-revision-2026-10-07.md)。产物：`QAArtifacts/UI-BlackGlass-20261007/`。本轮尚未提交 Git，保留全部遗留未提交改动；下一步结合用户观感反馈微调。

## 2026-10-07 启动链路修复（对照最新 YAAGL）+ MetalFX 搁置

用户指令：MetalFX 缩放先搁置（去掉 UI 按钮、保留代码并注释清楚）；对照 YAAGL 研究并修复四个启动问题（启动耗时、强制退出菜单命名、启动后随机退出、启动器 app 图标）。测试按用户要求**单线**进行（一次只启动一款游戏）。

### 0. 参考实现更新

`References/YAAGL` 旧快照（2025-06，178 个受版本控制文件）替换为上游 `yaagl/yet-another-anime-game-launcher` 最新浅克隆（`dae126a3`，2026-10-06）。旧快照可随时从 git 恢复。

### 1. MetalFX 空间缩放：搁置（代码保留）

- `PerformanceOption` 新增 `isSuspended`：搁置选项不进入 `getOptionsForLaunch`（启动环境不再注入 `DXMT_METALFX_SPATIAL_SWAPCHAIN` / `DXMT_CONFIG`），设置界面按 `isSuspended` 过滤不展示；选项定义、`{value}` 模板、1.0–2.0 区间校验、环境装配代码全部保留。恢复方式：把该选项的 `isSuspended` 改回 `false`。
- 现场 AppData 中原神/绝区零的 `metalfx_spatial_upscale` 仍保留 `isEnabled=true, value=1.5` 历史状态：即使如此也不会再下发任何 DXMT 变量（有回归测试锁定）。
- 搁置原因见 `Docs/01-research/research-dxmt-metalfx-2026-10-05.md`（系数只放大 Present 画布；RetinaMode=y 下任何 >1 的系数都是超采样）。

### 2. 启动耗时：定位两处固定开销并消除

改造前实测（`Logs/miplay.log`，秒级时间戳 + 本机 `time` 实测组件耗时）：

| 项目 | 改造前成本 | 说明 |
|---|---|---|
| `wine reg add`（每次启动重写 RetinaMode） | **3.70s**（冷启动，warm 0.66s） | 每次拉起 wineserver |
| `wine --version` 探针 | 每次启动 4–6 次 × 约 0.1s | readiness / lease / 编排器 / prefix 准备各调一次 |
| DXMT/存根资产 staging | 每次启动全量覆盖拷贝（约 50–100MB 写入） | 内容未变化也重写 |
| 游戏 .app bundle 组装 | 每次重拷入口程序 + 重写 Info.plist | — |

改造（`LaunchOrchestrator` 阶段事件新增 `durationMs` 字段用于前后对比）：

1. `WineRuntimeProvider.applyManagedDisplaySettings`：先读 `<prefix>/user.reg`，`Mac Driver\RetinaMode=y` 已落盘就跳过 `wine reg add`（注册表在 wineserver 退出时写盘；prefix 重建后文件缺失会自动回到写入路径）。实测日志出现 `wine.display.settings_already_applied`。
2. `WineRuntimeProvider.load(runtime:)`：按 binary 指纹（路径 + 大小 + 修改时间）在进程内缓存验证结果，同一 runtime 只探针一次，runtime 被替换后自动重验。
3. `LaunchCompatibilityEnvironment.copyOutcome`：源与目标（大小 + 修改时间）一致即跳过拷贝，并区分「源缺失 / 已最新 / 已拷贝」，缺失资产统计语义不变；bundle 组装的入口程序与 Info.plist 也按内容跳过。

### 3. 强制退出菜单：根因已定位，按实测保留 Steam 路径

`lsappinfo` 实测两个条目的真实身份（这正是强制退出菜单的判断依据：只有 `type="Foreground"` 的条目会出现在菜单里）：

- **绝区零（直启）**：唯一可见条目是 `ZenlessZoneZero`（pid = 实际游戏进程，`type="Foreground"`，`bundleID=dev.miplay.game.ZenlessZoneZero`，可执行文件路径显示为 `<runtime>/lib/wine/x86_64-unix/wine`）—— LaunchServices 启动的进程 fork 出的那个直接子进程继承了 app 身份。其余 7 个 `wine` 进程全部是 `type="BackgroundOnly"`，不进菜单。
- **原神（Steam 存根）**：可见条目有两个 —— `GenshinImpact`（bundleID `dev.miplay.game.GenshinImpact`，`type="Foreground"`）= LS 启动的 app 进程；`wine`（bundleID 空，可执行文件 = `<runtime>/lib/wine/x86_64-unix/wine`，`type="Foreground"`）= **实际游戏进程**（窗口所有者）。因为它是 `steam.exe` 经 CreateProcess 产生的**孙进程**，不再继承 app 身份，只能以可执行文件名 "wine" 记录。

对照 YAAGL 的两条路径实测（国服 7.1.0 + 托管 CrossOver 11 runtime）：

- **直启 + 云平台参数**（`-platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1`，即 YAAGL `config.bat` 同款）**失败**：`err:module:import_dll Library WDFLDR.SYS ... not found` → `ZwLoadDriver failed c0000142` → `initDriver Failed: Error [4,1114,0]`，退出码 5。与 YAAGL issue #763 一致，属 Wine 无法提供 WDFLDR（WineHQ bug 49193）。
- **Steam 兼容存根**（`C:\windows\system32\steam.exe <exe>`）**成功**：671 行日志、无驱动报错、游戏持续运行。

因此保留存根路径（`usesSteamCompatibilityStub = true`），直启代码与云参数保留（注释记录失败证据）。要让原神与绝区零一样只剩一个「原神」条目，前提是直启能跑通（即上游能提供 WDFLDR 或游戏改行为）；届时把 `usesSteamCompatibilityStub` 置回 `false` 即可。另实测 `WINELOADER` 环境变量不会改变 CreateProcess 子进程的可执行路径，无法用它给游戏进程改名。

### 4. 启动后随机退出：开发环境变量透传（已修复）

证据（`LaunchApps/ZenlessZoneZero.app/Contents/Resources/launch.log`）：两次异常退出（exit 72）前均为 Metal 校验层断言

```
-[MTLDebugBlitCommandEncoder ...]: failed assertion `Copy From Texture Validation
[sourceTexture pixelFormat](MTLPixelFormatBC7_RGBAUnorm) must equal [destinationTexture pixelFormat](MTLPixelFormatBC7_RGBAUnorm_sRGB)`
```

Xcode 运行 MiPlay 时会注入 `MTL_DEBUG_LAYER=1`（Metal API Validation），而编排器把 `ProcessInfo.processInfo.environment` 整体传给游戏 → DXMT 命中校验断言后 abort。修复：`ProcessManager.childEnvironment(overrides:)` 成为唯一的子进程环境边界（直接子进程与 LaunchServices 两条路径共用），剔除继承来的 `MTL_*` / `METAL_*`；调用方显式覆盖在过滤之后合并，因此性能选项自己的 `MTL_HUD_*` 不受影响。启动时记录 `launch.environment`（`reasonCode=metalDebugVariablesRemoved`）便于确认。

### 5. 启动器 .app 官方图标

- 新增 `GameIconProvider`（Infrastructure）：从 HoYoPlay（hyp-connect）官方接口 `getGames` 取图标 PNG（国服 `launcher_id=jGHBHlcOq1`、国际服 `VYTpXlbWo8`；按安装目录 `config.ini` 的 `uapc` 字段判定区服，原神额外回退到 `YuanShen.exe`），用 `sips` + `iconutil` 转 `.icns` 缓存到 `RuntimeAssets/GameIcons/<GameType>.icns`。
- `LaunchCompatibilityEnvironment.prepareAppBundle` 把缓存图标挂进 bundle（`CFBundleIconFile=AppIcon` + `Contents/Resources/AppIcon.icns`）；没有缓存时不写该键，保持无图标形态并在下次启动重试。
- 应用启动时并行获取（不阻塞运行时准备）。实测：原神/绝区零各生成 1024×1024 `.icns`（日志 `icon.provisioned`，来源 PNG 17.5KB / 17.0KB）。
- `LogWriter` 模块 allowlist 新增 `GameIconProvider`。

### 6. 测试与验证

- `xcodebuild test`：**120 tests / 0 failures**。新增 `MiPlayTests/LaunchOptimizationTests.swift`（8 个回归测试：搁置选项不下发、RetinaMode 探测、环境过滤、原神启动调用、staging 跳过未变化拷贝、图标区服判定、bundle 图标挂载、runtime 探针只跑一次）。该文件按项目现有方式注册进 `project.pbxproj`（测试 target 不使用文件系统同步目录，新增测试文件必须显式登记）。
- 实机单线测试（一次一款）：原神经 Steam 存根启动成功并保持运行；原神直启按预期失败（证据同上）。测试结束后已清理进程与 `wineserver`。
- `testPendingProcessExitRecoveryCommitsAutomaticallyThroughViewModel` 仍有偶发失败（既有时序问题，单独重跑通过），本次未修改该路径。

### 7. 交接后修复：恢复记录提交顺序不确定（Codex 退出诊断交接项）

Codex 的退出诊断修正（`Docs/06-review/review-exit-diagnosis-2026-10-07.md`）收尾时留下一个失败用例：`testPendingProcessExitRecoveryCommitsAutomaticallyThroughViewModel` 期望 `installed`、实际 `launchFailed`，且偶发通过。

根因（真实缺陷，不只是测试问题）：`GameRegistry.pendingRecoveryRecords()` 只按 `createdAt` 排序，而 AppData 用 `.iso8601` 编码日期（**秒级精度**，小数秒在持久化往返中丢失）。同一秒内创建的 `restartReconciliation`（保守结论 → `launchFailed`）与 `processExit`（具体退出事实 → `installed`）时间戳相等，排序结果由 Swift 排序实现决定；自动恢复按该顺序逐条提交，**最后提交的记录决定最终业务状态**，于是状态在两种结论之间随机摇摆。

修复：`pendingRecoveryRecords()` 改用 `GameRegistry.precedesInRecoveryCommitOrder(_:_:)` 排序 —— 时间相同再按"结论强弱"（`restartReconciliation` 先、`processExit` 后，具体事实最终生效），最后按 kind、id 兜底，保证完全确定。回归测试 `testRecoveryCommitOrderIsDeterministicForEqualTimestamps` 锁定同秒/同 kind 的排序。

验证：该用例连续 3 次通过；全量 **126 tests / 0 failures**（Codex 交接时报告的另一个 `testWineSchedulerReturnsOneReceiptAndRejectsResourceConflict` 失败未复现，属并发下的偶发）。

### 8. 兼容资源随包分发（删除 App Support 后仍能从零启动）

用户指令：把 dxmt 等资源放进项目文件夹（准备清空 App Support 做全流程测试）。

- 项目根新增 `RuntimeAssets/`：`dxmt/`（d3d10core.dll、d3d11.dll、dxgi.dll、winemetal.dll、winemetal.so）+ `protonextras/`（steam64/32.exe、lsteamclient64/32.dll），共 48MB。以**文件夹引用（folder reference）**加入 app target 的 Resources 阶段。
  - 实测教训：Xcode 16 的文件系统同步组会把嵌套资源**拍平**到 `Contents/Resources` 根目录（且会静默漏掉 `winemetal.so`），必须用文件夹引用才能保留 `Contents/Resources/RuntimeAssets/dxmt|protonextras` 结构（已核对构建产物）。
- staging 的资产来源改为解析式：`Bundle.main` 随包 `RuntimeAssets`（优先）→ `<AppSupport>/MiPlay/RuntimeAssets`（历史位置/手工替换回退），判定依据是候选目录中存在 `dxmt/d3d11.dll`。启动日志 `launch.compatibility` 新增 `sourceID` 字段（`bundledRuntimeAssets` / `appSupportRuntimeAssets`）用于确认本次走的是哪条。
- 图标缓存等**生成物**仍写在 App Support（`GameIconProvider`、`prepareAppBundle`），不会写进应用包（应用包可能已签名）。
- 清空 App Support 后首次启动的完整流程（各来源均已核对实时可用）：
  1. 启动时自动下载固定 runtime（`wine-crossover-11.0-1-signed`；上游 release 资产 `wine-crossover-11.0-1-osx64-signed.tar.xz` 已确认存在）；
  2. 首次启动游戏时 `wineboot` 建立共享 prefix；
  3. DXMT / Steam 存根资产直接取自随包资源；
  4. 官方图标重新从 HoYoPlay 接口获取；背景素材重新下载；
  5. **游戏位置（security-scoped bookmark）随 `AppData.json` 一起被删除，需要在界面里重新「定位游戏」**（游戏本体在 CrossOver bottle 里，不受影响）。
- 回归测试：`testAssetSourceResolutionPrefersBundledAssetsAndFallsBackToAppSupport`。全量 **127 tests / 0 failures**。Debug 应用包体积因随包资源增至约 133MB。

### 9. Swift 6 语言模式下的并发隔离修复（用户构建报错）

用户反馈的编译错误（Swift 6 语言模式；项目当前 `SWIFT_VERSION = 5.0`，同样的代码在此模式下只是警告）：

- `LaunchCompatibilityEnvironment.CopyOutcome`（嵌套枚举，默认 MainActor 隔离）的 `Equatable` 一致性在 `nonisolated` 的 static 辅助函数里被使用（10 处：`"main actor-isolated conformance ... cannot be used in nonisolated context"`）。修复：把该枚举声明为 `nonisolated`（一致性随之脱离 MainActor）。已用最小探针确认 `nonisolated enum/struct` 在 Xcode 27 工具链上可用。
- `PerformanceOption.launchEnvironment(for:)` 被 MainActor 隔离，而 `LaunchOrchestrator`（actor）在非主线程装配启动环境，无法调用。修复：`launchEnvironment(for:)`、`launchEnvironment()`、`displayValue` 标为 `nonisolated`（纯计算，不依赖主线程）。
- 测试 target：`MockURLProtocol.configure` 的响应闭包在 `@MainActor` 测试扩展里创建，却由 CFNetwork 后台队列（`com.apple.CFNetwork.CustomProtocols`）调用 → Swift 6 运行时隔离检查直接 trap（崩溃报告：`_swift_task_checkIsolatedSwift` → `_dispatch_assert_queue_fail` → SIGTRAP），表现为 test session 崩溃重启、`testWineDownloaderRejectsUnapprovedRedirectHost` 失败。修复：`MockURLProtocol.Response: Sendable`，handler 类型改为 `@Sendable`（关键：接到 `@Sendable` 参数上的闭包字面量不再被推断为主 actor 隔离，探针已验证三种写法均安全），并把 `wineReleaseJSON`/`wineReleasesJSON` 标为 `nonisolated`。
- 另外把 `withObservationTracking` 中被 `@Sendable` `onChange` 闭包捕获改写的 `var` 换成加锁的 `ObservationFlag`（`TestSupport.swift`），消除 `mutation of captured var in concurrently-executing code`。

验证：Swift 6 语言模式 `build-for-testing` 干净通过；两种模式下各 **127 tests / 0 failures**（Swift 5 为项目当前设置，Swift 6 为用户报告错误的模式）。项目 `SWIFT_VERSION` 未改动。

### 10. Retina / 左 Command 开关 + Wine 前置准备流程 + 遮罩修复（用户指令 2026-10-07 第二轮）

#### 1) Wine "Mac Driver" 开关（对照 YAAGL `config/retina.tsx`、`config/left-cmd.tsx`）

- 新增 `WineMacDriverSettings`（`AppData.wineMacDriverSettings` 持久化）：`retinaMode`（`RetinaMode`）、`leftCommandIsCtrl`（`LeftCommandIsCtrl`）。默认 **Retina 开、左 Command 不映射**（保持 MiPlay 既有行为；YAAGL 的默认是两者都关）。
- `WineRuntimeProvider.applyManagedDisplaySettings` 改为按设置写入两个键：先读 `<prefix>/user.reg`（`macDriverValue(forKey:atPrefixPath:)`），值相同就跳过，只有真正变化时才各拉起一次 `wine reg add`；设置值本身来自 `WineRuntimeProvider(persistenceStore:)` 读取的 AppData。
- 设置页（Wine）新增「显示与按键」两个开关（文案对齐 YAAGL），保存后**下次启动游戏时生效**（与 YAAGL 每次启动前 `setProps` 的时机一致）；同时精简该页：移除下载/任务进度面板（改由启动流程的全屏进度承担），保留状态与失败重试。
- **实测（单线，绝区零 + RetinaMode=n）**：游戏正常启动并渲染 —— 进程存活、453 行日志、0 崩溃断言、MoltenVK 1.4.1 初始化、`lsappinfo` 中单条 `Foreground`。「关闭 Retina 后游戏起不来」在当前代码路径下**未复现**（当时 MetalFX 选项还处于启用状态，可能与旧组合有关）。左 Command 映射按 YAAGL 同款注册表实现，需用户实机按键确认。
- 实测同时确认了两个键都由本应用写入：`user.reg` 中出现 `LeftCommandIsCtrl=n`（本应用写入）与随后的 `RetinaMode=y/n` 切换。

#### 2) 启动流程：Wine 前置 + 全屏进度

- `LibraryViewModel` 新增 `startupPhase`（`preparingWine` → `preparingMedia` → `ready`）与 `startupDetail` / `startupProgress` / `startupFailure`。
- `initialize()`：依赖初始化后先跑 **Wine 阶段**（`setupExistingManagedRuntimeIfPresent()` → 已就绪直接通过 → 否则复用/提交 `wineRuntimeSetup` 任务并轮询到终态，把任务阶段与进度投影到遮罩）→ 成功后进入**背景素材阶段**（三款游戏全部提交并等待终态，按「已完成/总数」显示进度）→ `ready`。
- **Wine 阶段失败时停在准备界面**（展示原因 + 「重试」按钮，`retryStartupPreparation()` 重跑两个阶段），不再放行到主页——旧行为会让启动按钮必然失败。
- 新增 `StartupPreparationOverlay`（白色全屏 + 进度条/百分比 + 说明 + 失败重试），删除 `MediaLoadingOverlay`；`MiPlayApp` 不再自行提交 Wine 任务（改由视图模型第一阶段驱动）。

#### 3) 修复：冷启动时全屏遮罩未覆盖主页

- 根因：旧条件 `isLoading || backgroundMediaState == .loading` 是"某一刻的状态快照"，而 `backgroundMediaState` 只在选中游戏或任务事件时才刷新；冷启动时两者都可能不成立，于是出现"黑底 + 按钮"，切换游戏后才刷新出遮罩。
- 修复：条件改为 `startupPhase != .ready`，而 `startupPhase` 的初值就是 `.preparingWine`，因此遮罩**从首帧起**覆盖主页。
- 回归测试：`testStartupPreparationOverlayCoversMainWindowFromFirstFrame`（含首帧可见性与两阶段结束后的关闭）。
- 实测：启动后逐帧截图采样（`QAArtifacts/StartupOverlay-20261007/`），启动瞬间整窗为白色遮罩，随后进入主页 ✓。

#### 4) 验证

- `xcodebuild test`：**130 tests / 0 failures**（新增 3 个：Mac Driver 注册表探测/设置往返、启动遮罩首帧覆盖、开关同步持久化）。
- Swift 6 语言模式 `build-for-testing` 干净通过（新增代码均显式处理隔离：`nonisolated` 目标、`[weak self, wineVersionManager]` 显式捕获）。
- 单线实机：绝区零在 `RetinaMode=n` 下启动并渲染 ✓；测试后已退出游戏、恢复被移开的 `vulkan-1.dll`、把 `RetinaMode` 写回与持久化设置一致的 `y` 并确认落盘。

### 11. 进度条卡 5% 修复 + 游戏设置集中到「通用」+ 实机测试（2026-10-08）

#### 1) 修复：Wine 下载/解压进度不更新（一直停在 5%）

用户实测：完全删除数据后重测，下载进度停在 5%，解压阶段进度条也不动。复现与根因（逐层定位）：

1. **进度源本身不产出持续值**：`NetworkDownloadProvider` 用 `NSProgress.fractionCompleted` 的 KVO 取进度。实测（自定义 URLProtocol 与真实网络下载都一样）只会在开始与结束时给出极少数值 —— 原始字节对被读成 `5/100` → `100/100` → 真实字节，所以界面长期停在 5%。
   - 先试 `URLSessionDownloadDelegate.didWriteData`（官方字节级回调）：**带完成回调的下载任务不会回调 delegate**，实测 30MB 真实下载仍然只有 1 个值 ✗。
   - 最终改用 **轮询 `URLSessionTask.countOfBytesReceived/ ExpectedToReceive`**：与完成回调兼容、字节精确。真实网络 30MB 下载实测产出 **19 个不同的中间进度值**（0.07% → 58% → 100%）✓。
2. **进度事件被落盘堵住**：`TaskScheduler.phase()` 每个进度 tick 都 `commit()`（= 全量写一次 AppData），下载/解压每秒大量 tick 时事件排队，界面看到的进度滞后甚至卡住。
   修复：内存状态与事件流每 tick 更新（界面即时），落盘按 **300ms 节流**（阶段说明变化、无进度的阶段切换、进度到 0/1 时立即落盘）；节流期间事件用已有的 `memoryOnly` 标记。
3. **界面消费方式**：`LibraryViewModel` 现在直接消费 `TaskProgress` 事件流更新遮罩（原先只靠 400ms 轮询快照）。

回归测试：`testNetworkDownloadProviderEmitsContinuousProgress`（下载器持续产出中间值）、`testStartupWinePhasePublishesContinuousProgress`（启动准备阶段必须出现多个中间进度与「正在下载/解压」说明）。测试基础设施同步修正：`MockURLProtocol` 改为**异步持续交付**分片（此前在 `startLoading` 里同步发完，字节级进度会滞后到传输结束之后）并带上 `Content-Length`。

**解压阶段此前完全没有增量进度**（提取器只发 `.extracting(progress: 0)` 然后直接完成）——这就是"解压时进度条也不动"的直接原因。修复：

- 未压缩总大小直接复用解压前已有的 `tar -tvJf` 明细列表累加（无额外解压开销）；
- 解压进程改为 `launch` + 400ms 轮询目标目录已展开字节数 → `progress = 已展开 / 总大小`（上限 0.99，结束时 1.0），经回调 yield 到下载器阶段流 → 调度器 `phase("正在解压 Wine", progress:)` → 遮罩进度条。
- 踩坑记录：bsdtar 旧式参数解析会把 `-tvJf` 之后的 `--numeric-owner` 当成要列出的文件名（`tar: --numeric-owner: No such file or directory`，退出码 1），长选项必须放在最前面；该错误被新增测试直接抓到。

#### 2) 游戏相关设置集中到「通用设置」

用户指令：把影响游戏的设置（Metal HUD、超帧率、Retina、按键映射）全部放到通用设置。

- `WineMacDriverSettings` 扩展为 **`GameEnvironmentSettings`**（AppData 持久化，应用级、三款游戏共享）：
  `metalHUD`（注入 `MTL_HUD_*`）、`fpsUnlock`（待解锁工具接入）、`retinaMode`、`leftCommandIsCtrl`
  （后两者写 `HKCU\Software\Wine\Mac Driver`）。默认：HUD/超帧率关、Retina 开、左 Command 不映射。
- 通用设置页新增「游戏运行」区（四个开关 + 「下次启动游戏时生效」说明）；Wine 页移除开关（只留运行时状态与失败重试）；每游戏设置页的选项区随之不再显示任何条目。
- 启动侧：`LaunchOrchestrator` 在装配启动环境时合并 `GameEnvironmentSettings.environmentVariables`（HUD）；Retina/左 Command 仍由 `WineRuntimeProvider` 在准备 prefix 时写注册表。
- 每游戏性能选项 `metal_hud` / `fps_unlock` 与先前的 `metalfx_spatial_upscale` 一样标记 `isSuspended`：不再进入每游戏启动清单（历史 AppData 里的开关不会与应用级设置打架），定义与装配代码保留并注释。

#### 3) 实机测试（单线，一次一款）

- **绝区零**：`RetinaMode=n` + 左 Command 映射 + HUD 开 → 启动成功（463 行日志、0 崩溃断言、进程存活）；**游戏进程环境里实测到 `MTL_HUD_ENABLED=1` / `MTL_HUD_ELEMENTS=fps` / `MTL_HUD_SCALE=0.2`**，确认应用级设置链路生效 ✓。
- **原神（Steam 兼容存根）**：**概率性成功**（连跑 3 次：2 次正常进入游戏并初始化图形，1 次被反作弊硬错误挡住 `NtRaiseHardError` + `initDriver Failed: Error [4,1114,0]`）。与 YAAGL issue #763（国服 7.1.0「Steam Patch 仍被强加载 HoYoKProtect」）一致，属上游 Wine 无法提供 WDFLDR 的问题，非启动参数差异；实测排除了「工作目录」「是否把 HoYoKProtect.sys 拷进 prefix」两个变量（两种情况下都会概率失败）。
- 测试副作用已清理：退出游戏、恢复被移开的 `vulkan-1.dll`、把 `RetinaMode` / `LeftCommandIsCtrl` 写回与持久化设置一致并确认落盘、无残留 wine 进程。
- 观察记录：`wineserver -k` 后**立刻**启动游戏，偶发 `err:sync:msync_init Failed bootstrap_look_up` 导致当次启动失败（重试即成功）。这是测试脚本"杀掉服务器后 2s 内启动"的时序产物；应用自身在清理与下次启动之间有更长时间间隔。

#### 4) 设置文案与 HUD 面板调整（用户指令，2026-10-08 追加）

- **Metal HUD 恢复系统默认面板**：不再覆盖 `MTL_HUD_ELEMENTS` / `MTL_HUD_SCALE`（此前是 `fps` + `0.2` 的最小纯帧率面板），只注入 `MTL_HUD_ENABLED=1`，使用 Metal HUD 默认的 **Lite** 布局（设备名、图层分辨率与 present 模式、内存占用、FPS / GPU 时间 / 帧间隔图表）。开关说明同步改为「显示 Metal 性能面板（帧率、GPU 时间、图层分辨率等）」；搁置中的 `metal_hud` 选项定义也保持一致。
- **「超帧率」文案**：标题改为「解锁帧率上限」，说明改为「解锁「原神」与「崩坏：星穹铁道」的帧率上限」——游戏名直接取 `GameType.displayName`（不再手写，避免冒号/点号不一致），并按用户要求用直角括号包裹。
- **Retina 模式说明随开关切换**：开 → 「以 Retina 模式渲染」；关 → 「以 macOS 逻辑分辨率渲染」。
- **通用设置区顺序**：「游戏运行」置顶，「语言」「更新」下移到其后（顺序：游戏运行 → 语言 → 更新 → 目录）。
- **Wine 设置页「来源」显示仓库地址**：原来写死为「官方 GitHub」，现在显示 `https://github.com/yaagl/anime-game-wine`（可点击用浏览器打开）。地址来源为 `BuiltInWineVersions.officialSource.repositoryWebURL`（新增字段，唯一来源），并用 `testSourceRepositoryWebURLMatchesAPIEndpoint` 锁定它与下载用的 `apiEndpoint` 指向同一仓库（同一 host + 路径包含关系）。
- **主界面侧栏改用官方游戏图标**：`GameSelectionRailView` 新增 `iconURLs: [GameType: URL]`，有缓存图标时用 56×56 圆角（R=16）图标渲染（选中描边加亮、hover/选中缩放），缺失时回退到原 SF Symbol + 黑玻璃面板；状态圆点与设置入口不变。
- **图标补齐由 `LibraryViewModel` 驱动**（原先在 `MiPlayApp` 的启动 Task 里、依赖直接读 AppData）：`refreshGameIcons()` 为三款游戏都补齐缓存（未定位时按国服取图，与 `GameIconProvider` 兜底一致），`refreshGameIconURLs()` 只读本地缓存并更新 `gameIconURLs`。调用时机：启动准备（与 Wine/素材并行、不阻塞）、`locateGame`/`addGame` 之后（定位后立即生效，不必等下次启动）。图标仍缓存到应用数据目录 `RuntimeAssets/GameIcons/<GameType>.icns`，与打包游戏 `.app` 共用。
- **验证**：`testCachedGameIconURLsListsOnlyExistingIcons`（临时目录 + 只认已存在文件）；离屏渲染截图 `QAArtifacts/GameIcons-20261008/rail-with-icons.png`（官方图标与回退两条路径并排）。`xcodebuild test` 135 tests / 0 failures。
- **窗口焦点导致玻璃降级：已调查、未采用替代实现（回退）**（用户指令 2026-10-08）：打开设置窗口后主窗口失去 key，`.glassEffect` 会降级为暗淡毛玻璃，侧栏图标/主按钮外观跳变。逐像素实测（`QAArtifacts/WindowFocusGlass-20261008`）：SwiftUI `.glassEffect(.clear…)` 与 AppKit `NSGlassEffectView(.clear)` 在 key/非 key 间平均差 12.3、最大 146；`.regular` 平均差 17.1；只有 `NSVisualEffectView(.hudWindow, state: .active)` 为 0/0。曾按后者改造 `DarkGlassSurface` 并验证 key/非 key 逐像素差 0，但**用户判定液态玻璃的视觉效果不可替代，已回退**（`DarkGlassSurface` 恢复 `.glassEffect` + `interactive` 参数，`PrimaryActionButton`、`GameSelectionRailView` 的 `GlassEffectContainer` 同步恢复）。测量与备选方案留在 QA 目录备查。
- **设置窗口改为"点击主窗口即关闭"**：设置窗口通过 `SettingsWindowRegistrar`（`viewDidMoveToWindow`）把自身窗口注册给 `AppDelegate`；主窗口成为 key（点击任意位置、菜单切换等）时 `windowDidBecomeKey` 关闭设置窗口，其它窗口获得焦点时保持打开。回归测试 `testSettingsWindowClosesWhenMainWindowTakesFocus`（用记录型 NSWindow 断言只关闭设置窗口；测试窗口需 `isReleasedWhenClosed = false`，否则 `close()` 会与 ARC 冲突导致测试进程崩溃）。
- 回归测试同步更新（HUD 只注入 `MTL_HUD_ENABLED`，不再出现 ELEMENTS/SCALE）。

### 待上游/待用户确认

- 国服原神 7.1.0 的 WDFLDR 问题需上游 Wine 支持（WineHQ bug 49193）；届时把 `usesSteamCompatibilityStub` 置回 `false` 即可统一强制退出菜单条目。
- 启动耗时改善的端到端数字需要在用户实际点击「启动」后查看一次日志（应用内阶段无法用脚本触发；组件级耗时已实测记录在本节）。

## 2026-10-05 启动兼容链路（确保游戏可成功打开）

用户指令：检查代码并推进修改，至少确保真实游戏可以成功打开（反作弊退出可后续处理）。本次工作按用户指令优先原则直接实施，超出既有实现边界的事实记录在本节末尾的“待上游确认”中。

### 根因（真实启动探测结论）

在开发机（M1 Pro / macOS 27.2，托管 runtime `wine-crossover-11.0-1-signed`，共享 prefix）上对两款已安装游戏做了分步真实启动探测：

| 观察 | 结论 |
|---|---|
| Genshin（`YuanShen.exe`）直接经 `wine <exe>` 启动 | 加载 HoYoKProtect 内核驱动失败（`WDFLDR.SYS` 缺失，`ZwLoadDriver c0000142`）后立即退出（`initDriver Failed: Error [4,1114,0]`）。 |
| Genshin 经 Steam 兼容存根启动（`wine C:\windows\system32\steam.exe <exe>`） | 游戏不再尝试内核驱动路径，正常进入游戏画面（已截图，DXMT D3D11，58 FPS）。 |
| Genshin 在未打 DXMT 的 runtime 上用 wined3d 渲染 | Unity 图形初始化失败（`Failed to initialize graphics / InitializeEngineGraphics failed`）；DXMT 渲染层是必需组件。 |
| ZZZ（`ZenlessZoneZero.exe`）在 DXMT 且自带 `ZenlessZoneZero_Data/Plugins/x86_64/vulkan-1.dll` 存在时 | DXMT/Metal 初始化期间崩溃（`newComputePipelineStateWithDescriptor` 未识别 selector）。 |
| ZZZ 在 DXMT 且该 `vulkan-1.dll` 被移走后 | 正常打开（已截图，无崩溃；与 YAAGL 参照实现行为一致）。 |
| 启动文件移除清单（vulkan-1.dll、crashreport、upload_crash）中的 crashreport/upload_crash | 对“打开游戏”非必需（已 A/B 验证）；仅 bundled `vulkan-1.dll` 与 DXMT 冲突。 |

### 实现

- 新增 `MiPlay/Domain/Launch/LaunchCompatibilityEnvironment.swift`：启动前幂等暂存（staging），全部 best-effort，缺资产只上报不阻塞：
  1. 将游戏目录 `HoYoKProtect.sys` 复制到共享 prefix `system32`；
  2. 将 DXMT 渲染层（`d3d10core.dll` / `d3d11.dll` / `dxgi.dll` / `winemetal.dll` / `winemetal.so`）覆盖到托管 runtime（原始构建文件首次以 `.bak` 保留），并在 prefix `system32` 放置原始构建副本与 `nvapi64.dll` / `nvngx.dll`；
  3. 将游戏自带 `vulkan-1.dll` 移为 `.bak`（Genshin：`YuanShen_Data/Plugins/`；ZZZ：`ZenlessZoneZero_Data/Plugins/x86_64/`；HSR 路径按同模式，未验证）；
  4. Genshin 额外暂存 Steam 兼容存根（`steam64/32.exe`、`lsteamclient64/32.dll`）。
- `LaunchOrchestrator.launch` 在 spawn 前调用 staging，并输出 `launch.compatibility` 结构化事件（`stagedFileCount` / `missingAssetCount`）。
- 启动目标按游戏解析：Genshin → `C:\windows\system32\steam.exe <Z:\...\YuanShen.exe>`（无附加参数）；其余游戏 → 直接启动 exe（无附加参数）。所有游戏 exe 参数使用 `Z:` 形式。
- 启动环境新增：Genshin `WINEESYNC=1`，HSR/ZZZ `WINEMSYNC=1`，均附加 `GST_PLUGIN_FEATURE_RANK=atdec:MAX,avdec_h264:MAX`。
- 退出还原：`cleanup`、`monitorProcess`（进程退出后立即、不依赖状态提交）、`failLaunch`、`cancelAfterFailure` 均调用 `restoreStagedGameFiles()`，把暂存的游戏文件移回。DXMT 运行时补丁按设计保持（幂等复打），不做逐次还原。

### 运行时资产边界（待上游确认）

- staging 读取 `Application Support/MiPlay/RuntimeAssets/`：
  - `dxmt/`：`d3d10core.dll`、`d3d11.dll`、`dxgi.dll`、`winemetal.dll`、`winemetal.so`（DXMT v0.80，开发机来自用户既有 YAAGL 安装）。
  - `protonextras/`：`steam64.exe`、`steam32.exe`、`lsteamclient64.dll`、`lsteamclient32.dll`。
- 当前实现不下载、不校验这些资产；缺失时仅记录 `missingAssetCount` 并继续启动。托管获取（批准来源、校验、版本管理）属于 Research / Architecture 范围，未由本次实现自行决定。
- 应用（未沙盒的开发构建）对这些路径的读写已验证；签名/沙盒分发形态仍需后续验证。

### 验证

```text
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
** BUILD SUCCEEDED **

xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
Executed 98 tests, with 0 failures
** TEST SUCCEEDED **
```

新增 `WineSchedulerTests` 用例覆盖：DXMT 暂存与 `.bak` 原始文件保留、prefix 原始副本与 Steam 存根暂存、bundled `vulkan-1.dll` 移出与还原、Genshin Steam 启动形式、缺失资产清单去重上报、ZZZ 直接启动形式与 `WINEMSYNC` 环境。

- 真实启动探测证据（本次会话）：Genshin 窗口 `原神` 1728×1117，Metal HUD 显示 `DXMT D3D11 FL_11_1 654f547`、58.30 FPS；ZZZ 窗口 `绝区零`，DXMT 渲染无崩溃。
- 应用内 UI 触发启动的用户验证仍待执行（用户验证门禁）。

### 已知限制

- HSR 未安装，其 vulkan 相对路径与启动环境沿用同模式推断，未验证。
- 反作弊相关内核驱动加载在 Wine 下仍不可用（预期内）；Genshin 经 Steam 存根路径规避，ZZZ 路径下该失败被游戏容忍。
- `vulkan-1.dll` 暂存依赖游戏目录可写（security-scoped 授权范围内）。

### 2026-10-05 后续：数据目录丢失与重建（用户验证事件）

用户从 Xcode 直接运行应用（签名构建 = App Sandbox 生效）进行验证，观察到的是**沙盒容器世界**（`~/Library/Containers/SteveTan.MiPlay/Data/...`），与开发期非沙盒数据目录（`~/Library/Application Support/MiPlay`）互相独立；容器内没有托管 runtime、游戏和 RuntimeAssets。用户在容器世界触发的 Wine 安装以「任务参数无效: 解压失败: 固定 Wine binary …」结束（`TaskSchedulerScheduling.swift:172` 将 wine 流 `.failed(detail)` 包装为 `invalidRequest`；该失败事实会持久化在容器 taskHistory 中，是用户看到的消息来源）。

同一时段，非沙盒数据目录 `~/Library/Application Support/MiPlay` 被整体删除（不在废纸篓、沙盒应用无权限删除它、日志无删除证据；原因未定位）。本实现随后完成重建：

- 从官方 release 重新下载 `wine-crossover-11.0-1-osx64-signed.tar.xz`（456,021,524 B），按应用相同算法验证：12,637 条目、无越界条目、wrapper=`wine`、306 个符号链接 0 违规；以 `--strip-components 1` 解压到 `WineVersions/wine-crossover-11.0-1-signed/`；`bin/wine --version` 输出 `wine-11.0`。
- 以应用相同方式（`wine wineboot -u`、`WINEPREFIX=WinePrefixes/shared`）重建共享 prefix；`drive_c`、`dosdevices` 就绪（满足 `isSharedPrefixReady(at:)`）。
- 重新安置 RuntimeAssets（dxmt 5 项、protonextras 4 项）。
- 用户点击「安装并准备」时，`setupExistingManagedRuntimeIfPresent()` 会从本地已暂存文件完成 runtime/prefix 记录提交，无需重新下载；游戏目录授权需在应用内重新添加（书签不可重建）。

遗留项（本轮未解决）：
1. 沙盒运行的独立数据世界：容器内缺少 RuntimeAssets 的自供给机制，且游戏目录书签需在容器世界重新授予；当前产品形态下沙盒运行无法直接复用非沙盒环境。
2. 沙盒内 Wine 安装的历史失败未能取得确切失败点（容器受 TCC 保护不可读）；后续需在可复现环境内单独调查（候选：下载/解压/校验在沙盒下的行为）。
3. 非沙盒数据目录被删除的根因未定位；验证期间建议使用非沙盒构建（`CODE_SIGNING_ALLOWED=NO`），避免在 `~/Library/Application Support/MiPlay` 上做手工清理。

### 2026-10-05 决定：取消 App Sandbox（用户决策）

用户确认数据目录为其手动删除（为进行整流程测试），并提出“项目是否需要取消沙盒”。经分析后执行：`ENABLE_APP_SANDBOX` 由 YES 改为 **NO**（MiPlay target 的 Debug + Release 两个配置；项目无 `.entitlements` 文件，entitlements 由构建设置生成）。`ENABLE_HARDENED_RUNTIME = YES` 保持（Developer ID 公证需要）；其余 `ENABLE_*` 资源访问设置为惰性保留。

依据：
- 本产品形态（下载/执行第三方 Wine、启动 Windows 游戏、反作弊场景）不可能进入 Mac App Store；Developer ID 直接分发只要求 Hardened Runtime，不要求沙盒；同类产品（Whisky / CrossOver / YAAGL）均不使用沙盒。
- 沙盒造成容器/应用支持目录两套数据世界，开发、验证与诊断成本高（本次会话已受此影响：容器受 TCC 保护不可读、容器内安装失败无法复现）；非沙盒下 security-scoped bookmark 机制照常工作，无需架构改动。
- 上述遗留项 1、2 随该决策不再阻塞当前验证；保留为历史发现。若未来需要沙盒运行，需先解决 RuntimeAssets 自供给与沙盒内安装流程复现。

影响标注：该变更属于产品/架构层面的姿态调整（超出 Implementation 边界），当前为快速恢复验证而先行落地；正式流程上应由 Architecture 以修订/ADR 形式确认，并同步 Review/QA 中与“沙盒验证”相关的门禁项。验证环境已按非沙盒形态重建（runtime/prefix/RuntimeAssets）。

### 2026-10-05 修复：ZZZ 在 DXMT 下 1–3 分钟崩溃（Mac Driver 显示设置缺失）

用户经应用启动 ZZZ 后，进程以退出码 1 退出，应用按输出中的 `WDFLDR.SYS` 字样给出“HoYoKProtect/WDFLDR 内核驱动不兼容”诊断（该摘要只描述输出内容，掩盖了真实退出原因）。

定位（真实复现 + 对照）：
- 用与 LaunchOrchestrator 完全相同的命令复现：ZZZ + DXMT（winemetal 渲染层）+ bundled `vulkan-1.dll` 移出，进程在 1–3 分钟内崩溃，日志出现 `libc++abi: terminating due to uncaught exception of type NSException`（Metal 管线创建路径）。同配置 4/4 次复现均在 1–3 分钟内退出。
- 与本机参考实现（YAAGL）逐项对照：其 ZZZ 同日以相同 DXMT 配置稳定运行约 1 小时；唯一未对齐的环境事实是 **prefix 注册表 `HKCU\Software\Wine\Mac Driver\RetinaMode = y`**（参考实现每次启动都通过 `winedrv_config.bat` 设置；MiPlay 从未设置）。
- 对照实验：在共享 prefix 写入 `RetinaMode=y` 后重复同一复现命令（同 DXMT、同参数、同环境），游戏稳定运行 5 分 11 秒无崩溃、窗口正常渲染（超过此前全部崩溃窗口）。结论：`RetinaMode=y` 是该崩溃路径的必要环境事实（因果机制未完全解释，证据为对照实验）。

实现：
- `WineRuntimeProvider.prepareSharedPrefix` 在“已就绪”与“wineboot 完成”两条路径上均调用新增的 `applyManagedDisplaySettings`：幂等执行 `wine reg add "HKCU\Software\Wine\Mac Driver" /v RetinaMode /t REG_SZ /d y /f`（best-effort，失败仅记录 `wine.display.settings_failed` 警告）。该设置由 prefix 注册表持久化。

### 2026-10-05 修复：游戏退出后误报 recoveryRequired（`wineserver -k` 退出码 1）

- 事实：`wineserver -k` 在没有任何 server 运行时**确定返回退出码 1**（空 prefix 实测复现）。游戏退出后 wineserver 常已自行终止，此时 `shutdownSharedPrefix` 用 `launchAndWait` 将退出码 1 当作错误抛出 → `releaseSharedPrefixLease` 失败 → 退出状态提交被判为 `recoveryRequired`，并写入未解决的 processExit 恢复记录（还会阻塞后续 WineRuntimeSetup 入队）。
- 修复：`shutdownSharedPrefix` 改为接受退出码 0 或 1（且非信号终止），其余情况仍抛 `recoveryRequired`；错误文案改为 "managed wineserver -k 未确认"。

### 2026-10-05 清理：过时 UI 页面/组件与空目录

按用户指令检查 UI 层全部视图的引用矩阵（含私有视图逐文件扫描与 MiPlayTests 引用检查），移除已无任何引用的旧版设计遗留：

- `MiPlay/UI/MainWindow/BottomActionView.swift` —— 旧版主窗口底部操作区（仅剩自身 `#Preview` 引用；UI 设计文档中不存在该组件）。
- `MiPlay/UI/Components/StatusBadge.swift` —— 旧版游戏状态徽章（同上，未见于设计文档）。
- 空目录：`MiPlay/UI/GameInstallerWindow/`（GameInstaller 属延期概念）、`MiPlay/Resources/Logs/`、`MiPlay/Resources/GameLibrary/`（无代码或工程引用）。

未移除（经文档核对为现行设计）：`GameInfoHeaderView`、`CompatibilitySolutionView`、`PerformanceOptionView`、`LogAndActionView`、`SettingsDetailView`、`BackgroundScene` 子视图等（均在 `ui-component-tree.md` 现行组件树内且被实际使用）；`PrimaryButtonState` 等成员在其他使用方仍被引用，无孤儿成员。

### 2026-10-05 修复：切换游戏后恢复记录未刷新，启动被旧恢复事实拦截

用户经应用启动 ZZZ 时收到「任务需要恢复: 游戏存在未完成恢复事实: …（旧 processExit 记录详情）」：

- 链路：恢复事实是游戏范围的；`LibraryViewModel.selectGame(id:)` 未刷新 `recoveryRecords`，而启动时只为“上次选中的游戏”拉取记录。用户随后点击切换到 ZZZ 时，记录集合仍是旧值（不含 ZZZ 记录），`primaryButtonState` 据此返回可用的「重试启动」；点击后 `TaskScheduler.enqueue(.gameLaunch)` 按未完成恢复事实拒绝（`TaskScheduler.swift:230-237`），并把旧记录详情原样弹出。
- 修复：`selectGame(id:)` 在选中变更后刷新该游戏的恢复记录（展示与门禁一致：存在未完成记录时按钮为「需要恢复」，主窗口横幅提供「重试恢复」，其内部 `commitProcessExitRecovery` 重读校验后标记 resolved）。
- 说明：旧记录是修复前那次 `wineserver -k` 误判遗留下来的，需要在应用内走一次「重试恢复」才会清除（设计如此：恢复事实需用户确认）。
- 附带观察（未处理）：每次启动时，已定位游戏的版本检查后台任务都会失败（`VersionChecker metadata.version_check_started` 后 `task.terminal failed`），与本次问题无关，待后续单独排查。

### 2026-10-05 修复：背景视频经常不显示（播放器池不感知路径 + 缺静态垫底）

按用户指令检查背景素材全链路（HoyoPlay API → 下载 → ffmpeg 转码 → 内容寻址缓存 → 服务状态 → ViewModel 投影 → BackgroundScene/AVPlayer 播放），结论：

- 磁盘与转码链路健康：三款游戏缓存均含可解码的 `video.mp4`（以内置 ffmpeg 全量解码验证 exit=0），当日转码事件全部完成；当日无缓存清理（指纹 diff）、无背景组切换记录。ffmpeg 应用侧使用 bundle 内副本（无隔离属性，运行正常）。
- 播放层存在两个缺陷：
  1. `PlayerPool` 仅按 gameId 缓存播放器：视频路径变化（切换背景组、悬停预览、重新转码）时继续返回旧播放器；`PoolVideoView.updateNSView` 也从不更新 layer 的 player。后果：悬停预览永远显示旧视频；切换背景组后仍播旧视频；旧文件被清理后该层变黑且本会话无法恢复。
  2. 视频分支缺少静态垫底：视频未出帧或播放失败时直接露黑；且视频条目的 `BackgroundMedia.imagePath` 原先错误地指向 mp4 本身而非该组背景图。
- 修复：
  - `PlayerPool` 记录并比较 `videoPath`，路径变化时停止旧播放器并重建；`PoolVideoView.updateNSView` 在 player 实例变化时同步到 `AVPlayerLayer`。
  - `BackgroundMediaService` 新增 `backgroundStillImagePaths`/`getBackgroundStillImagePath(for:)`（`presentLoadedMedia` 时缓存当前组 `background.png` 路径）；`LibraryViewModel.refreshMediaPaths` 为视频条目填入静图路径；`BackgroundScene` 始终绘制静图、视频层叠加其上 → 首帧加载与失败播放不再黑屏。
  - 清理：移除 `MiPlay/Resources/ffmpeg` 的 `com.apple.quarantine`（此前直接执行该副本会挂起；bundle 副本无此属性，应用不受影响）。
- 回归测试：`testPlayerPoolRebuildsWhenVideoPathChanges`（同路径复用 / 路径变化重建 / 旧播放器停止）。
- 遗留观察（未处理）：三款游戏的 `BackgroundScene` 全部同时存活（ZStack + opacity 转场），非选中游戏也在解码视频；`loadMedia` 的缓存命中路径也会先进入 `.loading` 触发全屏遮罩。两者均为后续可选优化。

### 2026-10-05 修复：已安装游戏背景不显示（版本检查长期占用游戏生命周期资源键）

症状：重启应用后已安装的原神/绝区零无背景，未安装的星铁背景正常。

定位（任务调度层）：
- 启动时序：`LibraryViewModel.initialize` 先经 `scheduleAutomaticVersionChecks` 为已定位游戏入队 `versionCheck`，再为三款游戏入队 `backgroundMediaLoad`。
- `TaskScheduler.resourceKeys` 将 `versionCheck` 与 `backgroundMediaLoad` 都归入 `game:<id>:lifecycle`：版本检查先运行并独占该游戏键；本机实测其对原神 `pkg_version` 的 2743 个条目逐个计算 MD5，单次耗时约 4 分 36 秒（日志 08:12:57 开始 → 08:17:33 完成）。期间同游戏媒体加载排队等待 → 无背景；星铁无版本检查、媒体立即完成 → 背景正常。
- 次级缺陷：`LibraryViewModel.consume(event)` 仅在 `gameID == selectedGameId` 时调用 `refreshMediaPaths()`，非选中游戏的加载完成不会进入投影。

修复：
- `resourceKeys`：`versionCheck`/`integrityVerification` 改用独立域 `game:<id>:evidence`（只读证据扫描；其对游戏状态的提交由 GameRegistry actor 与状态机串行化）；`backgroundMediaLoad` 不再占用 per-game lifecycle 键（仅保留跨游戏串行的 `backgroundMedia` 键）。启动顺序在本次未调整：检查与媒体现在可并行，且不再阻塞启动任务。
- `LibraryViewModel.consume(event)`：媒体任务到达终态时无条件刷新整个媒体投影。
- 回归测试：`testReadOnlyEvidenceTasksDoNotBlockMediaOrLaunchResources`。
- 遗留（性能，未处理）：版本检查对全部 `pkg_version` 条目做 MD5 全量校验（原神约 4.5 分钟/次，每次启动触发，产生大量磁盘 I/O）。现已不阻塞媒体与启动；后续可考虑仅在存在对应 IntegrityManifest 映射时执行逐文件校验（当前无发布清单，逐文件校验结果不会改变版本证据冲突结论）。

### 2026-10-05 修复：切换背景组逻辑复查（动态模式忽略纯图组 + 快速切换竞态）

按用户指令复查"切换背景组"链路（圆点 UI → ViewModel → BackgroundMediaService 加载/解析 → 选中提交 → 投影 → 播放），发现并修复两个缺陷：

1. 动态模式下选中"无视频的组"会被静默替换：`loadDynamicMedia` 只认 `BACKGROUND_TYPE_VIDEO` 且 video.url 非空的组，与 `resolveCurrentBackgroundId`（尊重任意选中组）及缓存门槛不一致 —— 选中纯图组时会跳到"第一个视频组"播放，随后仍提交该纯图组的选择，显示与选中分叉。修复：`loadDynamicMedia` 先尊重显式选择 —— 选中组无可播放视频时走该组自己的图片路径（`loadBackgroundFromAPI` 本就优先选中组），仅在没有显式选择时才回退第一个视频组。
2. 快速连续切换的竞态：`selectBackgroundGroup` 在 `await loadMedia` 期间可能被新的切换取代；旧调用随后仍会提交或回滚（回滚会把内存选择写回旧值，与已持久化的新选择分叉）。修复：加载返回后校验选择仍属于本次调用，被取代则静默退出（由新调用负责提交与回滚）；两处回滚分支同样仅在选择仍属于本次调用时执行。
3. 回归测试：`testDynamicModeHonorsImageOnlySelectedGroup`（混合"视频组 + 纯图组"响应；选中纯图组后呈现该组图片、isVideo=false、静图路径一致）。

保留行为（经现有测试核对）：custom 模式下 `selectBackgroundGroup` 的"就绪即提交"契约不变（`testBackgroundGroupSelectionPersistsAndFailedSwitchKeepsPreviousGroup` 依赖该行为）。

### 2026-10-05 核查：背景资源解析 API 与下载/转码链路（用户观察：切换后才下载）

用线上真实数据（`getAllGameBasicInfo`）与真实素材对"解析 → 下载 → 转码 → 缓存"逐段验证：

1. 解析：线上响应与模型/分组逻辑一致 —— 原神 4 组、星铁 2 组、绝区零 1 组；`video.url` 为 webm、`background/theme.url` 为 webp、`type` 含 `BACKGROUND_TYPE_VIDEO` 与 `BACKGROUND_TYPE_UNSPECIFIED`（后者无视频无主题）。缓存目录只保留已加载组，符合"按需获取"设计。
2. 下载：资源直链（launcher-webstatic.mihoyo.com）返回 200，无需鉴权。`NetworkDownloadProvider` 非 2xx 走类型化失败且不落盘，成功才 move 到目标路径，含磁盘空间检查；失败不会污染缓存。
3. 转码：按应用参数用真实素材实测 —— webm(20MB)→h264 mp4 约 11s、webp→png 约 2s、下载约 10s；输出解码校验通过。单组完整成本约 23s，即"切换新组"时的等待来源。
4. 设计确认：悬停圆点的预览会写入同一份组缓存（`video.mp4`/`background.png`/`theme.png`），即"悬停即预热、点击秒切"；未悬停直接点击才会触发完整下载+转码。
5. 修复缺陷：转码原为 ffmpeg 直接写成品路径，且缓存门槛只查文件存在 —— 转码被中断（退出应用 / 120s 超时强杀）会留下半截成品被误判为有效缓存，之后该组永久黑背景且不自愈。现改为"写 `*.part` 临时文件 → 成功后删除旧成品并原子替换 → 任何失败路径清理临时文件"（视频与图片转码一致）；`hasSubCache` 同时拒收 0 字节文件。
6. 回归测试：`testTranscodeFailureLeavesNoPartialOutput`（假 ffmpeg 写半截后退出 1：成品与 `.part` 均不残留）、`testTranscodeSuccessReplacesOutputAtomically`（成功路径替换旧成品、无 `.part` 残留）、`testCacheGateRejectsZeroByteArtifacts`（0 字节缓存不被承认，写入有效内容后恢复）。`MediaTranscoder` 新增可注入 `ffmpegPath`（默认 nil ＝ 沿用 Bundle/系统路径），沿用 NetworkDownloadProvider 的可注入测试惯例。

### 2026-10-05 功能删减：移除背景组切换，固定使用解析到的第一个背景资源（用户指令；暂时性简化）

按用户指令「暂时简化逻辑，不再提供切换功能，改为每款游戏固定只下载解析到的第一个资源」实施：

1. 行为：每款游戏的背景固定为 API 解析列表中的**第一个可用条目**——`resolveCurrentBackgroundId` 不再依赖模式（原动态取首个视频组、静态取首个有图条目）与任何持久化选择；动态模式下首条目有可播放视频则走视频管线，否则展示其静态图（`loadDynamicMedia`、`loadBackgroundFromAPI` 同步简化）。首次加载仍只下载该条目素材；集合指纹变化时仍按 diff 清理缓存（该机制保留）。
2. 代码级删除：`getBackgroundGroups`、`selectBackgroundGroup`、`getSelectedBackgroundGroupID`、`previewBackgroundGroup`、`cancelBackgroundPreview`、`getBackgroundPreviewState`、`getBackgroundPreviewThemePath`、`loadPreviewMedia`、`previewThemePath`，及对应服务状态（`backgroundGroups`/`selectedBackgroundGroupIDs`/`backgroundGroupErrors`/`backgroundPreviewStates`/`backgroundPreviewThemePaths`）、类型（`BackgroundGroup`、`BackgroundPreviewState`）与 `loadSettings` 中的选择恢复逻辑。
3. ViewModel 删除：`backgroundGroups`、`selectedBackgroundGroupID`、`backgroundGroupError`、`backgroundPreviewStatus/Media`、`hoveredBackgroundGroupID`、`loadBackgroundGroups`、`start/endBackgroundPreview`、`projectBackgroundPreview`、`selectBackgroundGroup`、`effectiveBackgroundMedia`（改为直接使用 `backgroundMedia`）；UI（MainWindowScene）删除背景圆点控件、顶部悬停区、键盘焦点与 `BackgroundGroupButton`。
4. 持久化：`AppData.backgroundGroupSelections` 与 `PerGameSettings.selectedBackgroundGroupID` 字段移除；旧 AppData.json 中的多余键在解码时被忽略，重新编码后不再写出。
5. 测试：删除 5 个切换/预览用例；原「动态模式尊重纯图组选择」用例改为 `testBackgroundLoadsFirstParsedResource`（混合响应中纯图组位于首位、视频组缓存齐备也不得被选中；断言呈现首位条目、`isVideo=false`、静图路径一致）。结果：99 tests / 0 failures，应用重建。
6. 文档影响（**未同步，待该简化确定是否长期保留后走 UX/UI/架构阶段**）：`Docs/02-ux/ux-information-model.md`、`ux-state-flow.md`、`Docs/03-ui/ui-component-tree.md`、`ui-screen-inventory.md`、`ui-interaction-implementation.md`、`Docs/04-architecture/architecture-domain-model.md`、`architecture-service-contracts.md`、`architecture-adr.md`（I-1/I-2 与 ADR 019 中关于选中/预览的描述）仍描述已移除的能力。

### 2026-10-05 检查时机对齐 YAAGL：版本检查不再每次启动全量扫盘（用户指令）

现状核实：每次应用启动，`LibraryViewModel.scheduleAutomaticVersionChecks` 为每款已定位游戏排一次 `.versionCheck` 后台任务；`VersionChecker.readLocalEvidence` 无条件执行 `validatePkgVersionEntries`，对 `pkg_version` 全部条目逐文件做大小 + MD5 校验（原神 2743 条，实测 ≈4.5 分钟 I/O）；而该结果只有在配置了 `IntegrityManifest` 时才参与结论（conflicts 与 mapping 均被清单门控，生产未随包发布清单）——即当时是全量扫盘且不影响任何判定。启动路径中的 `PreLaunchValidator → FileIntegrityVerifier.verify` 同为清单门控，无清单时立即返回 unsupported，成本可忽略。

改动：`readLocalEvidence` 让逐文件校验只在 `integrityManifests[gameType] != nil` 时执行（`fileVerification: full / declaredOnly` 记入 `metadata.local_evidence` 日志字段）。与 YAAGL 时机对齐：常规版本检查只比较声明版本（毫秒级），全量文件校验属于更新/修复流程。对齐后本机原神路径的检查结论不变（本地 7.1.0 == 官方 7.1.0，渠道一致）。

回归测试：`testVersionCheckSkipsFullPkgValidationWithoutManifest`（无清单：条目指向缺失文件也不产生校验错误，证明未扫盘）、`testVersionCheckKeepsFullPkgValidationWhenManifestExists`（有清单：同一夹具必然产生校验错误并进入证据冲突，证明深度路径保留）。

遗留：更新/修复流程与"手动校验游戏文件"入口尚未实现；随包发布 `IntegrityManifest` 后应把"自动轻量 + 更新/手动深度"固化（当前清单存在时自动检查会恢复深度校验）。

### 2026-10-05 功能删减：移除游戏详情窗口（用户指令；精简第一步）

按用户指令删除 `GameDetailWindow`（兼容方案 / 性能选项 / 游戏信息 三标签页）：

1. 删除文件：`UI/GameDetailWindow/GameDetailWindowScene.swift`、`CompatibilitySolutionView.swift`、`PerformanceOptionView.swift`、`LogAndActionView.swift`、`UI/ViewModels/GameDetailViewModel.swift`，目录一并移除。
2. 场景：`MiPlayApp` 移除 `WindowGroup(id: "game-detail")`；仅服务该窗口的 17 个存储属性一并删除，构造图保留为 `init` 内局部值（仍供 `TaskScheduler` 与两个 ViewModel 初始化）。
3. 入口：主窗口移除「查看详情」按钮（`MainTaskFeedbackView.openDetails`）与 `.viewFix` 分支；`.viewFix` 为既有死分支（`primaryButtonState` 从不产生该状态，LaunchFailed 已映射为「重试启动」），故连同 `PrimaryAction.viewFix` 与 `performPrimaryAction` 分支一并删除。启动失败诊断文本保留在主窗口反馈区。
4. 保留：`SolutionEngine`（TaskScheduler 的 solutionApply/solutionRevert 仍用）与 `PerformanceOptionManager`（LaunchOrchestrator 启动参数仍用），相关测试不变。
5. 结果：101 tests / 0 failures，应用重建。
6. 现状说明：删除后「从 MiPlay 移除」无 UI 入口（详情窗口内按钮此前即为死按钮；选择栏 `onRemoveGame` 参数仍未被调用，`LibraryViewModel.removeGame` 仅测试可达）——该能力是否重新安置待定。
7. 文档影响（并入既有清单）：`Docs/03-ui/ui-component-tree.md`、`ui-visual-prompts.md`、`ui-view-responsibility.md`、`Docs/04-architecture/architecture-overview.md`（目录树/GameDetailViewModel）、`architecture-communication.md`、`Docs/08-qa/qa-rtm.md`（LaunchFailed → game-detail 行）仍描述该窗口。

### 2026-10-05 状态恢复全自动化 + 强制退出界面进程命名调查（用户反馈）

**自动恢复**（"状态的恢复应该是全自动完成的，而不是需要手动点击恢复"）：
1. `LibraryViewModel.refreshRecoveryRecords` 在加载未完成恢复事实后自动调用 `autoRecoverPendingRecords()`：仅处理 `processExit` / `restartReconciliation` 两类（bookmarkRefresh/metadata/wineRuntimeSetup 等其他类型仍由各自子系统负责）；每条记录每会话自动尝试一次（`autoRecoveryAttemptedRecordIDs`），成功后刷新游戏状态；失败只记 warning 并保留记录，主窗口「重试恢复」按钮降级为失败兜底。
2. 安全边界：`LaunchOrchestrator.retryProcessExitRecovery` 新增守卫——启动进行中（`currentLaunchProcessID != nil`）拒绝恢复，避免误释放当前启动持有的共享 prefix lease（手动按钮此前同样存在该风险）；VM 侧在 `launchProgress != nil` 时跳过，待启动任务终态后的下一次刷新再提交。
3. 回归测试：`testPendingProcessExitRecoveryCommitsAutomaticallyThroughViewModel`（`running` 状态游戏 + 未提交退出事实 → 只调用 `refreshGames()` 即自动提交为 `installed`、记录清空）；`TestSupport.SchedulerFixture` 增加 `launchOrchestrator`。结果：102 tests / 0 failures。

**强制退出界面命名调查**（"启动器与运行的游戏都显示为 miplay"）：
4. 实测结论：游戏的窗口进程在系统中注册名为 **"wine"**，其 executable path 固定为 runtime 的 `lib/wine/x86_64-unix/wine`。已证伪的包装方式（系统按 realpath 解析、wine loader 最终仍以规范路径运行）：bundle 内符号链接、hardlink + `WINEDLLPATH`、`WINELOADER` 指向 bundle、同目录改名副本、由 bundled 父进程启动。即：无法通过改名/包装让游戏进程自带名称。
5. 推断：用户观察到的 "miplay" 大概率来自**责任进程归属**（由 MiPlay 启动的进程被系统归入 MiPlay 名下）；本机探测环境无法完全复现，待用户截图确认。
6. 候选方案：正式 = 为每款游戏生成具名 `.app` bundle 并经 LaunchServices 启动（Whisky/CrossOver 做法，游戏以自己的名字与图标出现），代价是改造启动路径与进程监控（现依赖直接子进程捕获输出）；快速缓解 = 把启动器显示名改为「MiPlay 启动器」。

### 2026-10-05 实施（用户选定方案 B）：具名 app bundle + LaunchServices 启动

用户确认强制退出界面两行同名（完全相同的名字），选定方案 B。实现：

1. **GameLauncher 入口**（`Tools/GameLauncher/GameLauncher.c`，编译为 `MiPlay/Resources/GameLauncher`，通用二进制 50KB）：fork 后 exec 托管 runtime 的 wine；子进程继承重定向（`MIPLAY_LAUNCH_LOG`）与工作目录（`MIPLAY_LAUNCH_CWD`）；父进程 `waitpid` 后把退出事实写入 `MIPLAY_LAUNCH_STATUS`（`exit:<code>` / `signal:<sig>`）并以同码退出；启动时 `setpgid(0,0)` 自成进程组，供按组终止。独立验证：正常退出→`exit:7`、信号→`signal:9`、输出重定向 ✓。
2. **bundle 生成**（`LaunchCompatibilityEnvironment.prepareAppBundle`）：在 `<support>/MiPlay/LaunchApps/<EnglishName>.app` 幂等生成 `Contents/{Info.plist,MacOS/<EnglishName>,Resources/launch.log,launch.status}`；Info.plist 的 `CFBundleName/CFBundleDisplayName` = 游戏中文名（原神 / 崩坏：星穹铁道 / 绝区零），`CFBundleIdentifier` = `dev.miplay.game.<EnglishName>`。
3. **LaunchServices 启动**（新增 `Infrastructure/Process/ApplicationLauncher`）：`NSWorkspace.openApplication`（arguments + environment）→ 返回 pid；观测 = `kill(pid,0)` 轮询 + 读取状态/日志文件；终止 = `kill(-pid)` 进程组信号（实测：helper 为组长、游戏进程同组、按组终止后无残留）。
4. **编排器接线**（`LaunchOrchestrator`）：仅当托管 runtime 位于标准 `WineVersions/<fixedTag>` 且 bundle/入口可用时走 LS 路径（`activeApplication` 以会话 UUID 记账，复用既有 scopes/lease/recovery 语义）；LS 启动失败（无 pid）**自动回退**直接子进程路径，保证"游戏能开"优先；启动确认后不再对"立刻退出"重复判定，退出事实统一走 `monitorProcess`（`ApplicationLauncher.exitResult` 把缺失状态文件视为异常退出，避免误报正常退出）。
5. **实测**（本机真实 runtime + notepad + 真实 helper）：系统注册名为 **「原神」（bundleID dev.miplay.game.GenshinImpact）**；游戏进程与 helper 同进程组；`kill -TERM -<pid>` 后 helper 与 notepad 全部退出。
6. 结果：103 tests / 0 failures（新增 bundle 生成用例；启动用例走回退路径保持原契约），应用重建。
7. 已知限制：bundle 暂无自定义图标（Dock 显示通用应用图标，待做 Windows 图标提取）；若游戏退出时 helper 未及写入状态文件（如整组被强杀），退出事实按"异常退出"提交（安全侧）。

### 2026-10-05 实机验证：原神 / 绝区零 ≥2 分钟稳定运行 + 画面（含新 LS 启动路径）

按用户要求，用与编排器一致的参数（staging 后的 runtime/prefix、相同环境变量与启动调用）经**新的 bundle + LaunchServices 路径**实机启动两款游戏并截图：

1. 原神（Steam 桩 `C:\windows\system32\steam.exe` + `Z:\...\YuanShen.exe`、WINEESYNC=1、无需移文件）：40s / 140s 两次检查 helper 存活、进程数 1→7、**0 崩溃**；140s 截图为开放世界实机画面（角色/队伍/小地图/UID 正常渲染）。
2. 绝区零（直接 exe、WINEMSYNC=1、移开自带 `vulkan-1.dll` 并在结束后恢复）：40s / 140s helper 存活、9 个进程、**0 崩溃**；140s 截图为实机画面（角色/NPC/任务 HUD/60 FPS）。
3. 关键教训（已内建保证）：LS 启动必须携带**完整环境**——验证脚本起初只给最小环境，绝区零在 DXMT 下于 40s 内崩溃（`newComputePipelineStateWithDescriptor` 收到非 Metal 对象）；补全环境后同一路径 140s 稳定。编排器本身传入 `ProcessInfo.processInfo.environment` 全量环境 ✓；直接启动 + 完整环境的对照实验同样稳定。
4. 顺手清理：删除弃用的 `WineVersionScope` 及其 scope 版 `getInstalledVersions`（无生产调用），移除 `TaskScheduler` 中对弃用 `.wineVersionDownload` 的新增引用（该 case 保留仅用于旧任务解码）；修复 `ApplicationLauncher` 的 `init` 主线程隔离告警。构建告警清零。

### 2026-10-05 复测与渲染层策略调整：绝区零改用 wined3d（DXMT 概率性崩溃）

用户清掉旧 CrossOver 快捷方式后按要求复测，多次运行暴露出的真实分布：

1. **DXMT 对绝区零不可靠**：同参数连跑 3 次——2 次在 35s 崩于同一处（`-[__NSCFNumber/__NSTaggedDate newComputePipelineStateWithDescriptor:options:reflection:error:]`，DXMT 的 Metal 计算管线创建），1 次稳定 110s。
2. **wined3d 稳定**：把 runtime 渲染前端恢复为原版（`.bak`）后连跑 3 次，全部存活 110s、0 崩溃、画面正常（含复杂街景截图）。
3. **原神 DXMT 稳定**：连跑 3 次全部存活 110s、0 崩溃、日志 33–52KB（保持 DXMT 不变）。

**最终处置（用户硬性要求：所有游戏必须使用 DXMT，帧率比替代方案高约 20%，不可更改）**：

4. 撤回"绝区零改用 wined3d"的方案（代码与测试全部回退为全 DXMT；`WINEDEBUG=-d3d`、按游戏渲染策略均删除）。
5. **根因定位 = DXMT 构建回归**：原先手放的 DXMT 是 YAAGL 目录中的 9 月 15 日提交构建（`654f547`），比官方最新正式版 v0.80 更新；用官方 **v0.80**（GitHub Releases `dxmt-v0.80-builtin.tar.gz`）替换 `RuntimeAssets/dxmt` 后实测：**绝区零 3/3 稳定 110s（0 崩溃）+ 终验 140s 画面正常**，**原神 2/2 稳定 110s（0 崩溃）+ 画面正常**——崩溃是较新构建的回归，v0.80 修复，DXMT 渲染器保持不变。
6. 保留的有效改进：`GameLauncher` 输出日志 64MB 封顶（防任何调试通道洪泛）；崩溃诊断结论（`newComputePipelineStateWithDescriptor` 收到字符串对象 = DXMT 内部对象错乱，与游戏侧无关）。
7. 测试环境教训：连续测试时 `open`（不带 `-n`）可能只激活旧实例；上一轮遗留的游戏进程不会命中 `pkill -f WineVersions`，会污染下一轮观测（曾误报"helper 消失/空日志"）。产品路径用 `createsNewApplicationInstance=true`，不受影响。
8. 资产说明：`RuntimeAssets/dxmt` 现为官方 v0.80（x86_64-windows 三件套 + winemetal.dll/.so）；更早的 9 月构建仍保留在 YAAGL 目录（`~/Library/Application Support/Yaagl/dxmt`）可作对照。

### 2026-10-05 修复：背景素材无法显示（转码临时文件名破坏 ffmpeg 格式选择）

用户反馈"重新编译测试发现背景素材没有正常显示"。日志诊断：每次加载都以 `background.transcode.failed / processExitedAbnormally` 结束（MediaCache 因此全空，只剩指纹文件）。根因是此前的"转码原子提交"改动把临时输出写成 `<output>.part`（如 `video.mp4.part`）——**ffmpeg 依赖输出扩展名选择封装器/编码器**，该名字直接报 `Unable to choose an output format for 'v.mp4.part'; use a standard extension for the filename or specify the format manually`，导致所有视频/图片转码失败（当时验证用的是桩脚本，未能暴露该问题）。已用真实素材 + 应用内置 ffmpeg 复现（退出码 234）并确认修正写法可用。

修复与加固：

1. 临时输出改为 `<stem>.part.<ext>`（`video.part.mp4` / `background.part.png`），扩展名保持在末尾；由 `MediaTranscoder.temporaryOutputPath(for:)` 统一生成，原子替换与失败清理逻辑不变。
2. 测试加固：桩 ffmpeg 现在与真实 ffmpeg 一致——对无标准扩展名（`*.mp4`/`*.png`）的输出直接以 234 退出，该类回归今后会被用例抓住；两个转码用例补充临时文件（`video.part.mp4` / `background.part.png`）清理断言。结果：103 tests / 0 failures。
3. 端到端验证：重启应用后三款游戏转码全部 `completed`；MediaCache 三组目录各含 `video.mp4`（5–7MB）+ `background.png`（4.7–7.3MB）+ `theme.png`；应用窗口背景正常显示，且窗口背景区域两帧比对不同——确认**视频背景在播放**。

### 2026-10-05 优化：三款游戏的背景下载与转码改为并行（用户询问"依次还是并行"）

现状：`TaskSchedulerPersistence.resourceKeys` 给 `backgroundMediaLoad` 添加了跨游戏共享资源键 `backgroundMedia`，注释理由是"BackgroundMediaService 持有共享内存状态，串行以防并发修改"。实测冷缓存加载三款游戏总时长约 40 秒，且后两款游戏的加载被明显推迟。

改动：媒体加载改为 **per-game 资源键 `game:<id>:media`**，删除共享键。安全性依据：服务与缓存管理器都是 MainActor/actor 隔离，组目录、`mediaStates`、主题路径等状态均按游戏隔离；唯一共享的 API 元数据缓存是幂等写入（同值覆盖）。同一游戏的重复加载仍按 per-game 键去重，不同游戏互不阻塞。

实测（清空 MediaCache 后冷加载）：

| 版本 | 三款游戏加载起始 | 全部完成窗口 |
|---|---|---|
| 改前 | 18:36:07 仅原神 → 18:36:34 其余两款 | 约 40 秒 |
| 改后 | **18:42:45 三款同时开始** | **约 15 秒** |

回归测试：`testReadOnlyEvidenceTasksDoNotBlockMediaOrLaunchResources` 更新为断言 per-game 键（同一游戏去重、不同游戏互不阻塞）。结果：103 tests / 0 failures。冷加载后缓存完整（36MB，三组目录齐备），应用界面背景正常。

### 2026-10-05 调整：视频转码 preset `medium` → `slow`（用户要求提高参数）及耗时实测

`MediaTranscoder.transcodeWebMToMP4` 的 x264 preset 由 `medium` 提升为 `slow`（与既有文档注释"slow 使用更高压缩效率"一致；CRF 18 不变，同画质下输出更小）。

实测（真实素材 + 应用内置 ffmpeg）：

| 场景 | medium | slow | 变化 |
|---|---|---|---|
| 单个 14MB webm 转码（墙钟） | 4.32s | 5.79s | +34%（user 时间 28.7s → 39.3s） |
| 转码输出体积 | 5.98MB | 5.85MB | -2.3% |
| 应用冷缓存三游戏并行加载（含下载） | ~15s | ~20s | +5s（仅首次；之后为缓存命中，0 开销） |

结果：103 tests / 0 failures；缓存三组目录完备、背景正常。如需再高可用 `slower`/`veryslow`（每档预计再增加约 30–50% 转码时间）。

### 2026-10-06 实施（用户选定方案 B）：MetalFX 空间缩放（自定义系数）+ 移除高级设置

用户指令：采用调研方案 B（一个开关 + 自定义系数），并把设置里的「高级」区直接去掉。

1. **选项定义**（`PerformanceOptionManager.defaultOptions`，`metalfx_spatial_upscale`，三款游戏均适用、默认关闭）：`DXMT_METALFX_SPATIAL_SWAPCHAIN=1` 固定开关 + `valueEnvironmentVariables["DXMT_CONFIG"] = "d3d11.metalSpatialUpscaleFactor={value};"` 模板，系数默认 2。
2. **缺陷修复（方案 B 的阻塞点）**：`LaunchOrchestrator` 此前只应用 `option.environmentVariables`，**从未应用 `valueEnvironmentVariables`**——系数根本不会下发。现改为统一经 `PerformanceOption.launchEnvironment(for:)` 合并（固定变量 + 模板展开），并保留"后位选项覆盖同名变量"的语义。
3. **显示值 = 下发值**：环境模板改用 `displayValue`（归一化后）展开。此前界面读归一化值、启动读原始值，两者可能不一致；现在同一出口。区间 1.0–2.0（DXMT 定义），越界夹取、逗号小数可接受、两位小数归一化、缺失回落默认 2。
4. **界面**（`SettingsGameView`）：删除「高级」区（含"显示高级设置"确认弹窗与 metadata 证据视图：检查结果/时间/来源、`config.ini` 原始字段、`pkg_version` 条目、冲突明细）——该区纯读取展示，删除不影响版本检查与完整校验的既有投影（`integrityResultView`、`localVersion` 仍在）。参数输入只在含 `{value}` 模板的选项开启后出现：单行"系数"输入框 + 说明"系数 = 屏幕分辨率 ÷ 游戏内渲染分辨率（如游戏内 720p 输出到 1440p 用 2.0）"。
5. **新增领域/视图模型接口**：`PerformanceOptionManager.setValue(gameId:optionId:value:)`（带持久化与失败回滚）、`OptionError.invalidValue`、`PerformanceOption.parsedValue/normalizedValue/formattedValue/displayValue/requiresValue`；`SettingsViewModel.setPerformanceOptionValue/performanceOption/reportInvalidPerformanceParameter/reportParameterClamped`（复用设置窗口既有的错误弹窗）。
6. **输入语义**：不可解析（空/`abc`）→ 拒绝并提示，保留已保存值；越界（如 5）→ 夹取为 2 并提示实际生效值。两者都不会把非法系数写进启动环境。
7. **验证**：`xcodebuild test` = **111 tests / 0 failures**。新增用例：`testMetalFXOptionExpandsValueIntoLaunchEnvironment`（模板展开/越界与缺失值的下发结果）、`testLaunchEnvironmentMergesOptionsWithLaterOptionsWinning`、`testPerformanceOptionNormalizesFactorIntoSupportedRange`、`testMetalFXOptionValuePersistsPerGameAndAppliesToNextLaunch`（每游戏独立 + 重启后保留）、`testPerformanceOptionRejectsUnparsableValueAndKeepsPrevious`、`testSettingsViewModelPersistsMetalFXFactorAndReportsInvalidInput`。
8. **上游源码复核**（`References/dxmt`）：`Config::getUserConfig()` 按"配置文件 → `DXMT_CONFIG`（分号分隔）"顺序解析，环境变量同名项**优先生效**；`str::split` 忽略空段，故结尾分号可有可无。走 `DXMT_CONFIG` 而非 `DXMT_CONFIG_FILE` 可避免在共享 prefix 里铺配置文件。
9. **待实机验证**（需用户在游戏内配合）：游戏内设为 720p 左右 + 开关 + 系数 2.0，用 Metal HUD 对比开/关帧率，并肉眼检查 UI 文本锐度（空间放大无时域信息，细字会略软）。注意该接口不改变游戏渲染分辨率，盲开（游戏已按原生渲染仍设 2.0）只会放大到 2× 原生、无收益。
10. **文档影响**：调研笔记 `Docs/01-research/research-dxmt-metalfx-2026-10-05.md` 的集成方案已由本节落地；`Docs/08-qa/qa-rtm.md` 的 F-S-03 仍为 Pending（实机帧率结论未取得）。

#### 2026-10-06 复现并修复：三个开关点击后回弹（用户实测反馈）

用户反馈"在原神设置里点三个开关都没反应"。现场证据：`AppData.json` 在点击时刻被写入且原神三项均为 `true`，日志同一时刻没有任何游戏启动——即**写入成功、开关视觉回弹**，用户看到的是"点了没反应"。

根因（两层，都必须修）：

1. **异步持久化与 Toggle 读取时序冲突（主因）**：`Toggle` 的 setter 里用 `Task { await setPerformanceOption(...) }`，开关状态要等持久化完成才写进 `performanceOptions`。SwiftUI 在 setter 返回后会立刻重新读取绑定值，此时读到的仍是旧值 → 开关弹回原位。`@Observable` 随后的失效通知能否把它翻回来并不保证。
2. **绑定读的是构造期快照**：`PerformanceOptionRow` 的 `get` 用捕获的 `option.isEnabled`（行构造时的值），而非 ViewModel 当前值，进一步固化了回弹。

修复：`SettingsViewModel.applyPerformanceOptionChange(gameID:optionID:enabled:)` **同步**更新内存状态并返回是否被接受，持久化转入后台 `Task`；失败时回滚内存状态并报错（不再留下"界面显示已保存但磁盘没有"的状态）。行的绑定 `get` 改为读取 `settingsViewModel.performanceOption(gameID:optionID:)`。`setPerformanceOption` 保留为 await 版本供其他调用方使用。

回归测试：`testPerformanceOptionToggleAppliesSynchronouslyAndInvalidatesObservers` 精确复现 Toggle 时序——setter 返回后**立刻**读取必须是新值（否则回弹）、必须触发 `withObservationTracking` 失效（否则界面不重绘）、随后后台持久化必须落到磁盘。

验证：**112 tests / 0 failures**（独立 derivedData 路径）。注：`testPendingProcessExitRecoveryCommitsAutomaticallyThroughViewModel` 在整套运行时偶发失败（约 5 次全套中 2 次），单独运行必过，属既有测试隔离问题（与本次改动路径无关），未处理。

**仍未验证（需用户配合）**：三个开关的实际游戏内效果。注意它们都是**下次启动游戏时生效**，点击后应用内除 MetalFX 的「系数」输入框外没有任何即时反馈——这是设计如此，不是故障。

## 2026-08-28 I-1 / I-2 / I-3 / I-4 / I-5

### I-1 背景缓存指纹

- `BackgroundMediaService` 现在计算并持久化“API 背景集合指纹”到媒体缓存目录
  `.background-fingerprint.json`，内容包含 source identity、组顺序、每组图片/视频/
  theme 资源身份与版本，不包含 `selectedBackgroundGroupID` 或 hover 预览态。
- 只有已持久化指纹与当前 API 集合不一致时才执行 diff 清理：删除不再属于当前集合的组，
  或资源身份已变化的组缓存；未变化组保留。指纹缺失/读取失败时不执行破坏性清理。
- 用户切换背景组、hover 预览、预览失败/取消都不删除任何分组缓存；AppData 中旧的
  `lastCachedBackgroundIds` 继续作为兼容诊断字段，不再作为选择或缓存失效依据。

### I-2/I-3 背景 hover 预览与圆点

- `BackgroundMediaService` 增加独立 `BackgroundPreviewState`：`idle`、
  `loading(groupID)`、`ready(...)`、`failed(...)`；预览加载走独立路径，不写 AppData，
  不改变 `selectedBackgroundGroupID`，也不触发缓存清理。
- 下载链路支持 Task 取消并传播到 URLSession；同一候选组重复 hover 复用已缓存或进行中加载。
- `LibraryViewModel` 暴露 hover 预览投影 `backgroundPreviewStatus`、
  `backgroundPreviewMedia` 和 `effectiveBackgroundMedia`，提交选择前会结束预览。
- 主界面圆点默认 `opacity 0` 且不参与点击，顶部 `40pt` 悬停区或键盘焦点显示；
  `top: 12pt`、命中框 `24 × 24pt`、间距 `10pt`，hover 圆点 `1.2x` 放大并高亮，
  选中/预览/加载/失败语义由结构化状态驱动；离开恢复当前选中组。

### I-4 统一 Wine runtime 与共享 prefix

- 产品固定使用 `wine-crossover-11.0-1-signed`；三款游戏共用同一个托管 Wine binary
  和 `WinePrefixes/shared` prefix。新的运行时解析不读取或写入 per-game Wine override。
- `AppData` 升级到 schema 4，新增 `managedWineRuntime` 与 `sharedWinePrefix`；旧的
  `selectedWineVersion`、`installedWineVersions`、`selectedWineSource` 和
  `wineVersionOverride` 字段仅作为迁移输入，迁移完成后清空，不覆盖统一 runtime。
- `WineVersionManager`、`WineRuntimeProvider`、`PreLaunchValidator` 与
  `LaunchOrchestrator` 均通过固定 runtime/shared prefix 的 readiness 和 lease 运行；
  Wine setup 只需下载、安装和初始化一次。共享 prefix 的并发占用由现有任务资源和
  prefix lease 共同保护。
- Settings 仅展示固定 runtime 的安装状态、进度、恢复状态和“此 Mac”信息；不再提供
  按游戏选择 Wine、版本删除或作用范围切换路径。

### I-5 此 Mac

- `SystemEnvironmentDetector` 从 IORegistry 读取系统提供的 machine name（如
  `MacBook Pro`），芯片使用 `machdep.cpu.brand_string`（如 `Apple M1 Pro`），
  内存格式化为可读文本（如 `16 GB`）；未知字段返回空字符串由 UI 显示“未知”。
- 通用设置页按“关于本机”层级展示机型、芯片、内存、macOS 版本四行，
  Wine 目标磁盘为独立只读行。

### 验证

```text
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -destination 'platform=macOS' test
Executed 93 tests, with 0 failures
```

新增测试覆盖：背景组切换不删缓存、API 集合指纹变化才清理、指纹缺失不清理、
hover 预览不改持久化且不删缓存、旧 schema → schema 4 迁移、统一 runtime/shared prefix
解析、旧 per-game 设置不覆盖统一 runtime、删除保护和系统信息字段。

## Phase 6 Closure Status

| Issue | Current implementation and evidence | Boundary |
|---|---|---|
| P1-REV-003 | `GameRegistry` writes an independent `RecoveryGuard.<id>.json` when the AppData commit cannot be made, detects it after restart, blocks a new launch, and retries idempotently. A guard-only retry now appends a resolved recovery record to AppData, verifies the state and record after reread, and clears the guard last. | If both AppData and the independent guard location are genuinely unavailable, the process cannot create a durable fact; the app retains an in-memory recovery result and reports `recoveryRequired`. It never claims convergence. |
| P1-REV-004 | `GameLocation` is the only Domain resolution result. Stale refresh, scope start/stop pairing, writeback success, writeback failure, and no-`lastKnownPath` fallback are covered across Registry, integrity, version, preflight, and launch paths with injected resolver fixtures. Consumers do not publish a result until refreshed authorization is committed. | Resolver fixtures verify the contract without manufacturing platform bookmark bytes. A real stale bookmark requires a user-selected security-scoped URL. |
| P1-UV-003 | `pkg_version` is parsed as JSON Lines and all approved `remoteName`, `fileSize`, and `md5` fields are retained in `LocalEvidence`; `[General]` reads only the approved `config.ini` fields. Manifest, channel, local-version, remote-version, and unmapped-pkg evidence conflicts return `versionEvidenceConflict` without publishing a current/update result. | `pkg_version` and `config.ini` remain evidence, not an integrity or official-version substitute. No approved pkg-to-manifest mapping is present, so an unmapped pkg source is deliberately non-successful. |
| P1-02 | Production Domain callers use `GameLocation` and keep its security-scoped lease active. Path-only infrastructure seams are `internal` and are limited to tests/migration; no bare path is an authorization credential. | A real user-selected bookmark and signed Sandbox runtime still require user validation. |
| P1-04 | Wine readiness requires the fixed managed runtime record, approved source, executable binary, readable runtime, and the one shared prefix with `drive_c`; all supported games resolve to that same pair. | Prefix creation and real Wine execution require the external Wine artifact and a user-selected game. |
| P1-07 | `ManagedStaging` permits only canonical children of `WineVersions/.staging`; archive traversal, symlink escape, and cleanup escape are rejected. Cancellation and failure cleanup are idempotent across concurrent owners and preserve `recoveryRequired` for real failures. | Filesystem fixtures cover boundaries; a signed Sandbox build is still required for distribution validation. |
| P2-02 | Debug and Release arm64 cancellation matrix passes. URLSession cancellation, extraction cancellation, managed staging cleanup, and `cleanupVerified` are now deterministic; an actual cleanup failure remains `recoveryRequired`. | Tests use mock URLSession and temporary managed staging, not a real Release-signed network run. |
| P2-03 | Settings preserves `.notSelected`, `.notDownloaded`, `.prefixNotReady`, and `.error` instead of flattening readiness to `.notInstalled`; task events retain failed/cancelled/recovery states. | Real runtime and prefix states remain unavailable until a managed Wine artifact and game are supplied. |
| P2-05 | This document reports the current 93-test Debug result and separates unsigned build evidence from distribution signing evidence. | Review, QA, and Release agents must retain their own frozen status and external validation gates. |
| P1-REV-005 | Release asset HTTP failures retain typed 403/404/429/5xx semantics from URLSession through Wine download phases and Scheduler terminal errors. API metadata errors remain API-specific; asset failures cannot publish an installed result. | Mock HTTP fixtures cover asset 403, 404, 429, 503, API/asset separation, secure status logging, and Scheduler failed persistence. Real GitHub responses remain external validation. |
| P2-06 | The project still sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for the application configurations. This implementation pass does not change the frozen architecture concurrency semantics. | Architecture review is required before changing the default isolation setting; no implementation-only reinterpretation is claimed. |

The current implementation closes the code-level P1 findings above. This is not a release approval: the user-validation and external-resource gates remain separate.

## Full Source File Split

This maintenance pass changes file organization only. Public symbols, actor isolation,
dependency injection, task state transitions, error/log semantics, persistence behavior,
and UI behavior remain unchanged. Cross-file implementation helpers are module-internal
where Swift requires a same-file `private` member to be shared by an extension; no new
external API was introduced.

| Original file | Before | Resulting responsibility files |
|---|---:|---|
| `Infrastructure/Wine/WineVersionDownloader.swift` | 1388 | `WineVersionDownloader.swift` (contract/catalog), `WineVersionDownloaderDownload.swift` (transfer/progress), `WineVersionDownloaderExtraction.swift` (cancel/extract), `WineVersionDownloaderFlow.swift` (lifecycle), `WineVersionDownloaderValidation.swift` (allowlist/staging cleanup); max 480 lines. |
| `Domain/Runtime/WineVersionManager.swift` | 1133 | `WineVersionManager.swift` (state/init), `WineVersionManagerCatalog.swift` (catalog/source), `WineVersionManagerReadiness.swift` (runtime/prefix gate), `WineVersionManagerInstalled.swift` (installed records), `WineVersionManagerDownload.swift` (download/recovery), `WineVersionModels.swift` (public models); max 328 lines. |
| `Domain/Game/GameRegistry.swift` | 1051 | `GameRegistry.swift` (actor/init), `GameRegistryLocation.swift` (authorized locations), `GameRegistryState.swift` (business facts), `GameRegistryModels.swift` (domain values); max 404 lines. |
| `Domain/Media/BackgroundMediaService.swift` | 817 | `BackgroundMediaService.swift` (state/init), `BackgroundMediaServiceModes.swift` (mode/loading), `BackgroundMediaServiceCache.swift` (cache), `BackgroundMediaModels.swift` (HoyoPlay contracts); max 449 lines. |
| `Domain/TaskScheduler/TaskScheduler.swift` | 803 | `TaskScheduler.swift` (actor/init), `TaskSchedulerScheduling.swift` (queue/execution), `TaskSchedulerPersistence.swift` (resources/commit/recovery), with existing `TaskSchedulerModels.swift`; max 377 lines for the actor file. |
| `Infrastructure/Process/ProcessManager.swift` | 653 | `ProcessManager.swift` (launch/contracts), `ProcessManagerWaiting.swift` (wait/termination requests), `ProcessManagerCompletion.swift` (completion/output); max 296 lines. |
| `Domain/Update/VersionChecker.swift` | 617 | `VersionChecker.swift` (authorized evidence comparison), `VersionCheckerModels.swift` (evidence/result contracts); max 455 lines. |
| `Infrastructure/Log/LogWriter.swift` | 566 | `LogWriter.swift` (actor storage/flush/export), `LogWriterModels.swift` (event/receipt/error contracts); max 479 lines. |
| `UI/ViewModels/LibraryViewModel.swift` | 543 | `LibraryViewModel.swift` (state/actions), `LibraryViewModelModels.swift` (action/progress contracts), `LibraryViewModelPresentation.swift` (derived overlay state); max 498 lines. |
| `UI/ViewModels/SettingsViewModel.swift` | 520 | `SettingsViewModel.swift` (settings/task projection), `SettingsViewModelModels.swift` (Wine/about contracts); max 478 lines. |
| `Infrastructure/Persistence/PersistenceStore.swift` | 504 | `PersistenceStore.swift` (JSON/atomic recovery), `PersistenceStoreModels.swift` (load/recovery/error contracts); max 459 lines. |
| `MiPlayTests/MiPlayCoreTests.swift` | 2651 | `ProcessAndLoggingTests.swift`, `PersistenceMetadataTests.swift`, `WineNetworkTests.swift`, `GameDomainTests.swift`, `SchedulerRecoveryTests.swift`, `BookmarkLaunchTests.swift`, `WineSchedulerTests.swift`, `UIReadinessTests.swift`, and `TestSupport.swift`; max 431 lines. `MiPlayCoreTests.swift` remains the 4-line XCTest discovery anchor. |

All files under `MiPlay/**/*.swift` and `MiPlayTests/**/*.swift` were recounted with
`wc -l`; the maximum is 498 and no file exceeds 500 lines. The MiPlay target uses
`PBXFileSystemSynchronizedRootGroup`, so production split files are automatic members.
The explicit MiPlayTests target now has PBXFileReference, PBXBuildFile, group-child, and
Sources-phase entries for all nine added test files. `xcodebuild -list` reports both
`MiPlay` and `MiPlayTests` targets.

## Implemented P0/P1 Paths

| Area | Implemented behavior |
|---|---|
| ProcessManager | Actor-owned process table, one completion path, concurrent stdout/stderr collection, timeout termination, SIGKILL fallback, cancellation, and termination confirmation. |
| Wine launch | `Process.executableURL` is the selected Wine binary; the game executable is an argument. `WINEPREFIX` and DLL override environment values are injected. `wineboot -u` is verified by checking `drive_c`. |
| Scoped authorization | User-selected directories are represented by security-scoped bookmarks. Stale bookmarks are refreshed. Launch keeps the scope alive until process exit or confirmed cleanup. Legacy path-only records remain `migrationRequired` and are never used as authorization. |
| Launch state | `Launching` is committed before side effects, `Running` and launch time are committed only after `waitUntilRunning`, and persistence or cleanup failures return explicit failure/recovery results. |
| Integrity | Versioned JSON manifests are loaded from `IntegrityManifests` or injected test fixtures. The manifest game and version must match the known game fact, and every manifest entry is hashed. Missing or unverifiable manifest returns `IntegrityUnsupported`; file existence alone never passes. |
| Version check | Local version is read from the authorized install directory and compared with the configured official HoyoPlay `getGameBranches` response (or injected test evidence). Missing remote configuration is an explicit error. No update is performed. |
| Task scheduling | Launch, integrity, version, solution apply, and solution revert call their Domain services. Resource conflicts remain `pending`; only invalid requests are rejected. Task phase, outcome, errors, recovery, start/end times and progress are persisted and emitted through streams. |
| Wine task lifecycle | Wine downloads use one `TaskReceipt` and the `wineRuntime` resource key. A download, install, and persistence commit are separate facts. URLSession, extraction, cancellation, staging cleanup, interrupted-task recovery, and retry/recovery-required states are propagated through Scheduler events. Settings consumes the same event and progress streams. |
| Task recovery | Pending/running records from a previous process are converted to interrupted failures and the repaired result is written back. If that write fails, a `recoveryRequired` event is emitted. No side-effect task is replayed automatically. |
| Exit and bookmark recovery | Process termination is recorded separately from the final game state. Registry/persistence failures retain a retryable recovery fact and never leave an unexplained `Running` projection. Every domain location consumer resolves the bookmark through `GameLocation`; stale bookmark refreshes are written back immediately, while write failure or revoked authorization returns an explicit migration/recovery state. |
| UI contract | Game and Settings entries are standard `Button` controls with stable `64pt` hit frames, fixed `56pt` glass, `12pt` rail spacing, glyph-only hover/selection transforms, a fixed `220 x 64pt` primary action, task/recovery accessibility semantics, and Settings-window centering clamped to `visibleFrame`. |
| AppData | Schema checking, legacy migration, `.bak` creation, corruption diagnostics, backup restore, atomic replacement and post-write decode verification are implemented. Corrupt input is copied to a unique diagnostic file and is never replaced with defaults. |
| ViewModels | Library and detail view models consume ordered scheduler events. Progress is optional and reflects real phases; no fixed percentage is used. |
| Structured diagnostics | `LogWriter` is the single structured event boundary. App initialization, bookmark/scope/writeback, Wine catalog/API/HTTP/download/cancel/verify/extract/cleanup/readiness, scheduler receipt/resource/recovery, process lifecycle, metadata evidence, persistence and background-media transitions carry operation/task/game context. Events are sanitized before OSLog, memory, file flush and export. Flush retains uncommitted batches on failure; export flushes first and returns only redacted JSONL. |
| XCTest | `MiPlayTests` covers process output/exit/timeout/cancellation, duplicate waiter rejection, AppData corruption/backup/migration, manifest verification/version matching, version comparison, metadata evidence conflicts, Wine receipt/resource conflict, API 403/429, asset 403/404/429/5xx, non-HTTP and missing download responses, asset allowlist and unapproved redirect rejection, cancellation and staging cleanup, interrupted-task recovery, process-exit recovery after persistence failure, Wine persistence-failure retry, legacy per-game Wine settings being ignored by unified runtime resolution, and background-group selection rollback. |

## Intentional Runtime Refusals

These are explicit capability failures, not success stubs:

1. The repository has no production `IntegrityManifests/*.json`; real game launch and integrity verification therefore return `IntegrityUnsupported`.
2. The repository has no signed system-modification helper/XPC service and no trusted replacement DLL resources. Published compatibility solutions remain visible for diagnostics, but `SolutionEngine` refuses before side effects and never returns `Applied`.
3. Production version checks use the official mainland HoyoPlay branches endpoint for the supported game IDs. This supplies version-notification evidence only; it is not a game-file integrity manifest and does not perform updates. Region-specific launcher IDs and full game update manifests remain outside the current implementation.
4. A MiPlay-managed Wine distribution and user-authorized game installations are present on the development machine, but the real launch probe is not a product success claim: Genshin exits with `WDFLDR.SYS`/`HoYoProtect` failures under Wine, while Zenless Zone Zero remains in D3D12 initialization during the probe. The app reports process-confirmed failure or timeout rather than manufacturing a successful game state.
5. No system Wine, Whisky, CrossOver installation, or user-supplied runtime path is detected, imported, selected, or used. Only a MiPlay-managed Wine artifact that passes the source and installation gates can be used; no unapproved GitHub mirror is an implicit fallback.

## Task 4 Logging Evidence

- Wine download and install events now retain the approved `wineTag` through download, response, verification, extraction, cancellation and installation commit.
- Cancellation publishes `cancelled` only after cleanup is confirmed. A cleanup failure publishes `recoveryRequired` with `cancellationUnconfirmed` and `cleanupVerified=false`; the manager applies the same rule to staging and final-install cleanup.
- Disk preflight, missing HTTP response, rejected redirect, integrity cleanup, archive cleanup and extraction cleanup failures each have a structured terminal event. Sensitive paths and URLs remain outside event fields and are redacted by the LogWriter boundary.
- Legacy logging calls are retained only as compatibility shims: their localized message/details are discarded before the event reaches OSLog, memory, file flush or export. Critical download, extraction, background API and media-transcode paths use stable structured message codes instead of interpolated paths or URLs.
- Log rotation strictly retains `miplay.log` plus three backups. Flush failures keep the uncommitted actor batch for retry; the failure fixture verifies that a directory write failure cannot silently discard the batch.
- [`log-export-sample.jsonl`](./log-export-sample.jsonl) is a safe export example. It contains no token, bookmark data, user path, command, stdout/stderr or query-bearing URL.

## Known Platform Limits

- The application uses App Sandbox with a user-selected read/write game-directory bookmark. A game directory must be selected by the user and represented by a valid bookmark. Stale refresh and persistence write-back are covered by injected resolver fixtures; consumers are gated on the committed location.
- Path-based infrastructure entry points used by tests and legacy migration are module-internal. Production Domain callers resolve `GameLocation` and keep its scope active before passing a derived path to infrastructure; a bare path is not a user authorization credential.
- System paths such as `/etc/hosts` and `/etc/hostname` are outside the game bookmark. They are not modified from the app process.
- Applying system-level compatibility changes requires a signed, reviewed helper with a narrow protocol and user approval. Adding one is an Architecture/Infrastructure change, not an implementation fallback.
- Manifest and trusted patch assets must come from the release resource pipeline. They must not be fabricated from the current executable or downloaded without an integrity contract.

## Verification

Executed on the local arm64 Mac with Xcode 27 beta and macOS deployment target 26:

```text
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -sdk macosx -configuration Debug -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
** BUILD SUCCEEDED **

xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -sdk macosx -configuration Release -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
** BUILD SUCCEEDED **

xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
Executed 93 tests, with 0 failures
** TEST SUCCEEDED **

xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Release -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
Executed 93 tests, with 0 failures
** TEST SUCCEEDED **

The focused Phase 6 tests include restart recovery after AppData failure, guard-only retry, stale bookmark refresh/writeback failure, revoked-access and reauthorization state transitions, scope pairing, manifest/config/pkg evidence conflicts, Wine API and asset HTTP error separation (403/404/429/5xx), Wine cancellation/cleanup, managed staging traversal and symlink rejection, non-HTTP and missing download responses, unapproved redirect rejection, prefix readiness, Settings readiness projection, structured log sanitization/legacy-text isolation/flush retry/export/rotation and the Wine-binary launch fixture. No Swift 6 correctness warnings were emitted; the Release build still reports the platform `CC_MD5` deprecation described below.
```

The Swift implementation has no Swift 6 correctness warnings. The remaining compiler warnings are intentional compatibility/deprecation notices: legacy Wine scope/task names, the platform SDK deprecation for CommonCrypto `CC_MD5` (required only to interpret `pkg_version` evidence), and Xcode's optional AppIntents metadata notice. The development machine has a MiPlay-managed Wine runtime/shared prefix and user-owned Genshin Impact and Zenless Zone Zero executables, but a real launch is not claimed as successful: the Genshin probe exits with `WDFLDR.SYS`/`HoYoProtect` failures, while the Zenless Zone Zero probe remains in D3D12 initialization until terminated. MiPlay preserves those outcomes as process failure/timeout facts rather than downgrading them to a false success.

The Release verification above is an unsigned arm64 build/test run. A separate Debug app bundle passed `codesign --verify --deep --strict`; its entitlements contain App Sandbox, user-selected read/write access, outgoing network access, and the debug task-allow entitlement. No distribution signature or notarization is claimed. The project contains no incoming-network or Bluetooth entitlement; the network capability used by the product remains limited to outgoing URLSession requests. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` remains an Architecture follow-up, not a hidden implementation change.

## Traceability

- `ProcessManager.swift`: Architecture Service Contract / ADR 003.
- `GameFileSystemRepository.swift`, `GameLocation.swift`: bookmark communication / ADR 004.
- `LaunchOrchestrator.swift`: launch confirmation / ADR 007.
- `TaskScheduler.swift`: task queue / ADR 008.
- `PersistenceStore.swift`, `AppData.swift`: recovery and atomic persistence / ADR 009.
- `SolutionEngine.swift`: backup/apply/rollback boundary / ADR 010.
- `FileIntegrityVerifier.swift`: manifest-based integrity result contract.
- `VersionChecker.swift`: VersionCheck task contract.
- `MiPlayTests/ProcessAndLoggingTests.swift`, `PersistenceMetadataTests.swift`, `WineNetworkTests.swift`, `GameDomainTests.swift`, `SchedulerRecoveryTests.swift`, `BookmarkLaunchTests.swift`, `WineSchedulerTests.swift`, `UIReadinessTests.swift`, and `TestSupport.swift`: split XCTest coverage and shared fixtures; `MiPlayCoreTests.swift` remains the XCTest discovery anchor.

## UI 优化（2026-10-08）

本轮修改四个既有 UI 文件，并新增 `UI/MainWindow/MainTaskFeedbackView.swift`。任务反馈从主场景抽出，增加局部内容材质、百分比与恢复详情；主按钮增加按既有 action 映射的符号；游戏栏增加独立选中标记、辅助技术选择 trait 和减少动态效果支持；图标 URL 失效时清除旧图标，恢复 fallback。设置侧栏分组，详情增加标题与页面 identity。

不增加领域事件、持久化字段或业务状态。保留工作区先前未提交修改；本轮没有提交 Git。完整范围、决策和截图见 [UI 修订](../03-ui/ui-revision-2026-10-08.md)，验证记录见 `QAArtifacts/UI-Optimization-20261008/`。

## 原生 UI 审查与实施（2026-10-09）

移除图标自定义 spring/缩放/brightness 和多余 hover 状态；标准 Button 增加系统 focusable 与 Space/Return key-down 路由。目录定位使用 NSOpenPanel 原生 Sheet；准备遮罩隔离底层输入并修复白底在 Dark Mode 的语义前景。

背景与官方图标通过 task(id:) 后台读取 Data；背景/主题统一图片视图，播放器创建/播放移出 body，非选中/非 active/Reduce Motion 时暂停。删除无引用 GameInformationView 空存根和未使用的 onRemoveGame UI 参数；领域删除能力未改。设置删除副标题及重复 frame，精简说明，完善 Toggle label/hint。未修改领域、ViewModel、Infrastructure 或持久化格式。

最终 Debug arm64 137 tests / 0 failures；详细文件、风险及证据见 [原生 UI 审查](../03-ui/ui-native-review-2026-10-09.md)。

## 2026-10-09 背景几何局部回退

恢复 BackgroundView 的固定 1280 × 688pt frame，移除新增 clipped。背景/视频/theme 的 -16pt 偏移是用户基于 720 总高度、隐藏 titlebar 和 688 内容区居中关系测得的补偿，保持不变。不得将该值作为无依据的装饰偏移清理。此回退仅涉及背景布局，详见 [原生 UI 审查修订](../03-ui/ui-native-review-2026-10-09.md)。
