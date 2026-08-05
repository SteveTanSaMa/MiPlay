# Performance Regression Report

> 当前工作树 baseline：2026-08-02
> 版本比较：不可用（仓库无历史提交）
> 总体状态：Performance Gate Blocked by User Validation

## 1. 回归检测结论

| 区域 | 当前结果 | 回归判定 |
|---|---|---|
| Cold Launch | 3 次 0.866–1.089 s | 当前 baseline 通过；无历史版本对照 |
| Idle memory | Physical Footprint 84.6–85.7 MiB live；旧 trace 98.5–99.5 MiB | 当前 baseline 通过；媒体切换峰值未验证 |
| Idle CPU / I/O | CPU 1.2–4.4%；旧 trace 19.47 MiB / 10.93 s | 无历史对照；不可见视频资源风险存在 |
| Media player lifetime | idle 仍有 2 个 video fd；GPU allocated-size 无有效 MiPlay 数据 | 不能通过不可见资源验收 |
| Process wait/cancel | 50 次场景均通过；P99 48.94–212.12 ms | synthetic baseline 通过；Wine 未验证 |
| steady-state persistence | 100 次 P99 3.07 ms | 通过 |
| migration/recovery persistence | P99 183.93/224.88 ms | 尾延迟 Observe，不等于 steady-state 回归 |
| Log flush/export | P99 11.79/0.315 ms | 当前 payload 通过；rotation 未验证 |

没有历史提交、历史 trace 或历史 benchmark，不能写“比上一版本改善/回归”。本报告只记录当前 baseline 和当前实现可回溯的问题。

## 2. P2 瓶颈汇总与 Traceability

| Issue | Observation / Evidence | Module | Code location | Owner / 回溯 |
|---|---|---|---|---|
| `P2-REV-004` | `opacity` 隐藏场景仍构造/播放播放器；idle 2 个 video fd | UI + Media | `BackgroundView.swift:22-27`; `BackgroundScene.swift:33-39` | Implementation；若改调度契约再 Architecture |
| `P2-REV-004` | `BackgroundMediaLoad` 被 enqueue 拒绝，run unsupported；媒体 theme 使用无引用 Task | TaskScheduler + Media | `TaskScheduler.swift:305-307,456-457`; `BackgroundMediaService.swift:322-324` | Implementation；必要时 Architecture |
| `P2-REV-002` | 无生产 Wine binary，无法测 Wine wait、prefix、游戏进程树 | Process + Wine | `ProcessManager.swift:263-303,440-527`; `WineRuntimeProvider.swift:55-115` | QA/User validation；问题确认后回溯 Implementation |
| `P2-PERSIST-001` | recovery P99 183.93/224.88 ms，明显高于 normal write P99 3.07 ms | Persistence | `PersistenceStore.swift:106-139,155-176,277-315` | Implementation；只在真实磁盘证据后优化 |
| `P2-LOG-001` | 当前 flush/export 通过；rotation 及未等待 flush 竞争没有数据 | Log | `LogWriter.swift:79-91,94-146,167-181` | Implementation；先补测再决定 |

## 3. Gate status

### 已通过

- Cold Launch < 3 s：3/3 trace 通过。
- Idle memory < 200 MB：Activity Monitor/vmmap 两组 baseline 均通过。
- steady-state Persistence P99 < 100 ms：通过。
- Process synthetic tests：200 次超时/取消相关重复全部通过。
- 当前日志 payload 的 flush/export budget：通过。

### 未通过或未验证

- 不可见背景视频持续资源消耗：当前实现和 fd 证据显示风险，真实切换/解码/GPU 对照未完成。
- 取消旧媒体任务不覆盖新状态：未完成用户验证，且 scheduler executor 有静态缺口。
- Wine command、wineboot、真实游戏进程等待和终止：环境无 Wine，未验证。
- 用户验证清单：`Docs/06-review/review-user-validation.md` 所有复选项仍未勾选。

## 4. 下一轮回归入口

用户验证通过后，必须固定以下场景再更新本报告：

1. 冷启动 5 次，使用同一 Release 签名产物，报告 initial frame P50/P95/max。
2. 进入主窗口后只保留当前背景，再快速循环三款游戏至少 30 次；每次记录活动播放器数、video fd、CPU、GPU allocated size、VideoToolbox/IOSurface 峰值和切换后释放时间。
3. 以 A → B → C → A 的媒体加载意图交错完成/取消，断言旧任务不能提交新 revision 的状态。
4. 使用生产 Wine binary 和 fresh prefix，分别测 `wine --version`、`wineboot -u`、真实游戏启动确认、超时、取消和 SIGTERM ignored 场景。
5. 以真实 AppData 大小和 5 MB 日志 rotation 重复 persistence/log benchmark，并保留 `.xcresult` 和 `.trace`。

在上述证据存在之前，不提高 Performance Gate 为 Pass，也不进行未经测量的架构重构。

