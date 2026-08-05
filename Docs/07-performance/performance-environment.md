# 性能环境与方法

> 文档状态：Baseline / User Validation Blocked
> 测量日期：2026-08-02
> Agent：Performance Agent

## 1. 测量环境

| 项目 | 值 |
|---|---|
| OS | macOS 27.0 (26A5388g) |
| Xcode | Xcode 27.0 (27A5218g) |
| 设备 | MacBook Pro 18,1，Apple Silicon，10 核，16 GB |
| 架构 | arm64 |
| Deployment Target | macOS 26.0 |
| 构建 | MiPlay Release 构建通过；测试使用同一工作树的 Debug 测试产物 |
| 工具 | `xctrace` 可用；`instruments` 命令不可用；`vmmap`、`ps`、`lsof` 可用 |
| 工作树 | 无历史提交，只有当前工作树 baseline，无法执行版本间回归比较 |

当前测试环境没有可用的 `wine`/`wine64` 命令。工程内置 `MiPlay/Resources/ffmpeg` 是 x86_64；宿主 `/opt/homebrew/bin/ffmpeg` 是 arm64。Wine、真实游戏启动和真实生产媒体切换因此不作为已验证数据。

## 2. 方法与场景

### 2.1 Cold Launch

使用 Xcode Instruments 的 `App Launch` 模板，从独立 Bundle ID 的 `/private/tmp/MiPlayPerf.app` 启动，记录 3 次冷启动 trace：

- `/tmp/MiPlayColdLaunchPerf.trace`
- `/tmp/MiPlayColdLaunchPerf-2.trace`
- `/tmp/MiPlayColdLaunchPerf-3.trace`

读取 `life-cycle-period` 的 `Launching - Initial Frame Rendering` 和 `Foreground` 行。测试进程由 trace 的 time limit 结束，启动时间只取首帧完成前的 launch 区间，不把 trace 保存时间计入。

### 2.2 Idle 内存、CPU 和媒体资源

使用独立 `MiPlayPerf` 进程 PID 28776，先通过 Activity Monitor trace 观察 10.93 秒，再使用 `vmmap -summary`、`ps` 和 `lsof` 做重复采样。媒体文件数量使用完整路径字段匹配 `MediaCache/*/video.mp4`，避免 `Application Support` 路径空格造成误计数。

证据：

- `/tmp/MiPlayIdle.trace`
- `/tmp/MiPlayGamePerformance.trace`
- PID 28776 的 10 次 idle 采样记录（2026-08-02 20:06）

`Game Performance` trace 的 Metal allocated-size 表没有可归因于 MiPlay 的有效数据；trace 同时包含 WindowServer 和 Codex 活动，所以不据此推断 MiPlay GPU 占用。

### 2.3 Process 等待和取消

使用 `xcodebuild test` 对已有 XCTest 做 50 次重复，`-test-repetition-relaunch-enabled NO`，每次测试在同一个测试进程中独立创建 `/bin/sh` 子进程。场景为：

- 输出收集与正常退出：`testProcessManagerCollectsOutputAndExitStatus`
- 超时：`testProcessManagerTimeoutTerminatesAndResumesOnce`
- 等待取消：`testProcessManagerCancellationDoesNotDoubleResume`
- 第二个取消等待者：`testProcessManagerRejectsSecondCancelledWaiter`

这是 Process 生命周期和调度开销基准，不是 Wine 运行时基准。每次超时/取消用例包含测试自身的 100 ms 等待，因此不能将完整用例时长解释为 `Process` API 纯开销。

### 2.4 PersistenceStore

分开测量两类路径：

1. steady-state：直接编译当前 `PersistenceStore.swift`、`AppData.swift` 与临时 benchmark harness，执行 100 次 `writeAppData`。payload 包含 50 条任务历史、设置、缓存映射和 Wine 版本字段，覆盖正常任务提交的近似结构。
2. 修复路径：对已有 XCTest 做 50 次重复，分别覆盖 legacy schema migration 和损坏文件保留/备份恢复。该路径包含临时目录创建、备份复制和 XCTest runner 开销，不等同于 steady-state write。

steady-state harness 在测量后已删除，没有进入项目交付物。

### 2.5 LogWriter

直接编译当前 `LogWriter.swift` 与临时文件系统 stub，执行 100 个 batch：每批写入 49 条日志后显式 `flush()`，避免触发 50 条阈值的未等待 flush 与显式测量相互竞争。之后对累计 361,110 bytes 的日志执行 100 次 `exportLogs()`。

## 3. 前置条件与未验证项

`Docs/06-review/review-user-validation.md` 全部条目仍未勾选。特别是以下项未完成：生产 Wine binary、fresh prefix、真实游戏 executable、进程终止确认、下载取消、权限和真实 UI 场景。因此：

- 快速切换三个真实背景的播放器数、CPU/GPU/解码资源：未验证。
- 取消旧媒体任务后旧结果不覆盖新状态：未验证；静态代码存在风险证据。
- Wine 命令等待、wineboot 和游戏进程资源：未验证。
- “不可见视频零持续消耗”：当前实现有反证风险，但缺少切换前后受控对照，不能宣称完成验收。

