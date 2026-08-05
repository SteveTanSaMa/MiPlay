# Performance Budget

> Baseline 日期：2026-08-02
> 判定原则：只有有 trace、xcresult 或可重复 benchmark 的指标才计为已测；未完成用户验证的项目保持 Blocked/Unverified。

## 1. Budget

| 指标 | Budget | 当前测量 | 判定 |
|---|---:|---:|---|
| Cold Launch 到初始帧完成 | < 3.0 s | 0.866 s / 0.997 s / 1.089 s | Pass（3 次） |
| Idle Physical Footprint | < 200 MiB | 84.6–85.7 MiB（live vmmap）；旧 trace 98.5–99.5 MiB | Pass（两组均低于预算） |
| Idle Real Memory | < 200 MiB | 128.7–129.6 MiB（Activity Monitor trace） | Pass |
| Idle CPU | < 5% 观察窗口峰值 | 1.2–4.4%（10 次采样） | Pass，仍需正式 trace 复测 |
| 当前选中背景播放器 | 1 个视频播放器 | 未做 UI 切换控制实验；当前缓存打开 2 个视频文件 | Blocked / 风险 |
| 不可见背景视频解码 | 0 个持续运行 | `BackgroundView` 用 opacity 保留场景；当前 2 个 video fd | Blocked / P2 风险 |
| steady-state `writeAppData` P99 | < 100 ms | 3.07 ms（100 次、近似真实 payload） | Pass |
| migration P99 | 单独记录，目标不阻塞首次启动 | 183.93 ms（50 次） | Observe |
| corrupt/recovery P99 | 单独记录，目标不阻塞恢复交互 | 224.88 ms（50 次） | Observe |
| Process 正常短命令 P99 | < 50 ms | 48.94 ms（50 次 `/bin/sh`） | Pass，非 Wine |
| Process timeout P99 | 记录确认延迟，不得无界等待 | 166.70 ms（50 次，含 100 ms 测试等待） | Observe |
| Process cancellation P99 | 记录确认延迟，不得无界等待 | 212.12 ms（50 次，含 100 ms 测试等待） | Observe |
| Log flush P99 | < 50 ms | 11.79 ms（49 条/批） | Pass |
| Log export P99 | < 500 ms | 0.315 ms（361,110 bytes） | Pass |

## 2. Acceptance mapping

### A. 不可见背景视频

目标是：不可见背景不创建或不持续推进视频解码，且切换后旧资源可观察地释放。当前证据不满足该结论：`BackgroundView.swift:22-27` 对三个场景使用 `opacity`，`BackgroundScene.swift:33-39` 的 `PlayerPool` 首次取 player 时立即 `play()`。live 进程在 idle 时仍持有两个 `MediaCache/*/video.mp4` 文件描述符。

这只证明当前实现存在持续资源占用风险，不证明每一帧均已由 MiPlay 产生；GPU trace 没有 MiPlay 的可用 Metal allocated-size 数据，真实切换实验必须在用户验证后补做。

### B. 取消旧媒体任务

目标是旧任务取消完成后不能提交新选择之前的状态。当前不能判定 Pass：`BackgroundMediaService.swift:322-324` 使用无引用 `Task`，未接入 `TaskScheduler`；`TaskScheduler.swift:305-307` 不接受 `backgroundMediaLoad`，`TaskScheduler.swift:456-457` 仍把它标为 unsupported。需要先关闭 Review 中的 `P2-REV-004`/相关实现问题并完成可重复切换验证。

### C. 启动、内存和持久化

Cold Launch、idle memory 和 steady-state persistence 达到当前预算。恢复路径的 P99 由备份复制、原子替换和重新读取验证主导，应作为独立恢复预算跟踪，不能用正常写入 Pass 覆盖其尾延迟。

