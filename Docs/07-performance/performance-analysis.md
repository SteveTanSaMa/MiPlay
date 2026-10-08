# Performance Analysis

> 结论格式：Observation → Evidence → Root Cause → Optimization Direction
> 优化方向均为 P2 识别，不是实施方案。

## 1. 背景媒体资源生命周期

- 观察 (Observation)：idle 主窗口下仍有多个背景视频资源保持打开；不可见场景是否停止由 UI opacity 控制，而不是资源生命周期控制。
- 证据 (Evidence)：PID 28776 的 10 次采样均发现 2 个 `MediaCache/*/video.mp4` 文件描述符；CPU 为 1.2–4.4%，Physical Footprint 为 84.6–85.7 MiB。`BackgroundView.swift:22-27` 对所有 `BackgroundScene` 使用 `.opacity(...)`；`BackgroundScene.swift:33-39` 的 `PlayerPool.player` 创建 `AVQueuePlayer`、创建 looper 并立即 `queue.play()`。
- 根因 (Root Cause)：透明度改变渲染可见性，但当前实现没有与 `AVQueuePlayer.pause/remove/释放` 对应的生命周期边界；每个 `BackgroundScene` 还拥有独立 `@State PlayerPool`。`LibraryViewModel.swift:167-170` 启动时顺序加载三款背景素材，使多个缓存素材在窗口进入 idle 前就可用。
- 优化方向 (Optimization Direction)：将“可见背景”和“媒体资源活动”建立同一状态边界，优先验证不可见播放器数量、解码线程和视频文件 fd 在切换后归零；再针对媒体 cache 与预加载策略做 P2 资源预算控制。回溯：`P2-REV-004` → `BackgroundMediaService`/`TaskScheduler` → `BackgroundView.swift:22-27`、`BackgroundScene.swift:33-39`、`LibraryViewModel.swift:167-170`。

当前判定：风险有测量证据，但真实快速切换和 GPU/decoder 对照尚未完成，不能宣称验收通过。

## 2. 媒体任务取消与旧状态覆盖

- 观察 (Observation)：媒体加载任务的调度类型已声明，但执行和取消链路没有完成；快速选择可能让旧加载结果晚于新选择提交。
- 证据 (Evidence)：`TaskScheduler.swift:305-307` 的 `enqueue` 不接受 `.backgroundMediaLoad`；`TaskScheduler.swift:456-457` 对该类型进入 unsupported；`BackgroundMediaService.swift:322-324` 以无引用 `Task` 启动 theme 加载；服务的加载状态写入没有可见的任务 revision/取消 token 对照。评审回溯为 `P2-REV-004`。
- 根因 (Root Cause)：媒体读取任务没有进入拥有取消语义和有序事件的 `TaskScheduler`，旧 Task 的完成回调缺少新意图身份或 revision 门槛；因此资源结束时间和 UI 状态提交时间没有同一事实源。
- 优化方向 (Optimization Direction)：先定义并测量媒体意图的取消确认、结果提交顺序和旧任务丢弃率；将性能预算与“最多一个活动媒体任务/当前意图可提交”绑定。不得在 Performance 阶段直接重构任务架构，问题修改应回溯 Implementation，若改变任务契约再回溯 Architecture。

当前判定：未验证。没有真实 UI 切换场景和旧结果覆盖断言，不能将测试通过的 Process cancellation 结果外推为媒体任务取消通过。

## 3. Process 等待、超时和取消

- 观察 (Observation)：正常短命令很快；超时和取消尾延迟约 167–212 ms P99，但没有无界等待证据，且实现包含强制终止确认轮询。
- 证据 (Evidence)：正常输出/退出 50 次 P99 48.94 ms，timeout P99 166.70 ms，cancellation P99 212.12 ms，duplicate waiter P99 183.72 ms；所有 200 次通过。`ProcessManager.swift:263-303` 使用 continuation、timeout Task 和 cancellation handler；`ProcessManager.swift:440-495` 先 SIGTERM，再按 50 ms 轮询并在 deadline 后 SIGKILL。
- 根因 (Root Cause)：取消和超时的完成事实被定义为 termination handler + pipe EOF，而不是发出 SIGTERM 的时刻；测试固定等待 100 ms，系统调度和进程终止回调占据尾延迟。真实 Wine 可能产生不同的子进程树和终止行为。
- 优化方向 (Optimization Direction)：把“命令执行时间”和“终止确认时间”分开建模，按 Wine/游戏真实进程树建立 P95/P99 baseline；在实现层只针对测得的尾延迟和未确认率做 P2 优化。回溯：`P2-REV-002`/Process 生命周期 → `ProcessManager.swift:263-303,440-527`。

当前判定：本地 synthetic Process 通过；Wine 运行时未验证。

## 4. PersistenceStore 尾延迟

- 观察 (Observation)：正常 steady-state 写入很快，但 migration 和损坏恢复路径出现 184–225 ms P99 尾延迟。
- 证据 (Evidence)：近似真实 AppData 的 100 次 `writeAppData` P99 3.07 ms；migration P99 183.93 ms；corrupt/recovery P99 224.88 ms。`PersistenceStore.swift:155-176` 每次写入编码、原子替换、备份并重新读取验证；`PersistenceStore.swift:106-123` 迁移先备份再替换并读回；`PersistenceStore.swift:128-139` 损坏路径复制 diagnostic 并检查 backup。
- 根因 (Root Cause)：异常路径包含额外复制、临时目录和恢复读回；尾延迟由文件系统/测试 runner 调度与恢复操作叠加，不能仅归因于 JSON 编码。
- 优化方向 (Optimization Direction)：正常写入维持 <100 ms P99；对恢复交互单独记录备份复制、原子替换、读回验证的子阶段，只有在真实 AppData 和真实磁盘上确认后再做 P2 尾延迟优化。回溯：Persistence 修复 → `PersistenceStore.swift:106-139,155-176,277-315`。

当前判定：steady-state Pass；恢复路径 Observe，不覆盖正常写入的 Pass。

## 5. 日志 flush/export

- 观察 (Observation)：49 条日志的显式 flush P99 11.79 ms；约 361 KB 文件的 export P99 0.315 ms。
- 证据 (Evidence)：临时 harness 100 个 batch 测量当前 `LogWriter.swift`；`flushToFile()` 位于 `LogWriter.swift:94-146`，包括目录检查、轮转检查、ISO8601 格式化和 append；`exportLogs()` 位于 `LogWriter.swift:167-181`，顺序读取所有主/备份日志。
- 根因 (Root Cause)：flush 的主要工作是每条 entry 的文本格式化和 FileHandle append；当前 benchmark 没触发 5 MB rotation，未覆盖 rotation 尾延迟。
- 优化方向 (Optimization Direction)：保持日志写入不阻塞用户动作；若后续日志量接近 rotation 阈值，单独测量轮转和大文件导出后再决定 P2 优先级。关注 `LogWriter.swift:79-91` 的未等待 Task flush 与 flush 竞争，不在本 Agent 直接改动。

当前判定：当前 payload Pass；5 MB rotation 未验证。

## 6. 启动和 idle memory

- 观察 (Observation)：冷启动和 idle memory 当前均在预算内。
- 证据 (Evidence)：三次 App Launch 初始帧完成 0.866–1.089 s；Activity Monitor trace Physical Footprint 98.5–99.5 MiB、Real Memory 128.7–129.6 MiB；live vmmap 为 84.6–85.7 MiB，均低于 200 MiB。
- 根因 (Root Cause)：当前测量环境和缓存规模未触发超过预算的内存压力；媒体资源生命周期仍可能在多场景切换时改变峰值，当前没有完整切换峰值数据。
- 优化方向 (Optimization Direction)：在用户验证后固定三款真实媒体、窗口尺寸和切换脚本，重复采集 peak Physical Footprint、IOSurface/VideoToolbox 和 GPU allocated size；若峰值回归，再回溯媒体资源生命周期问题，不提前做架构重构。

## UI 生命周期优化（2026-10-09）

图片与官方图标磁盘读取移入路径驱动 task，后台读取 Data 后在主 actor 创建 NSImage；body 不再重复读取图片。视频播放器创建/启动移出 body，非选中或 scene 非 active 时暂停，Reduce Motion 下退化为静态图片。主题与背景使用同一图片实现。

新增播放器暂停/复用回归通过；未做 Instruments、GPU、能耗或帧率基准，不声明量化性能收益。证据与限制见 [原生 UI 审查](../03-ui/ui-native-review-2026-10-09.md)。
