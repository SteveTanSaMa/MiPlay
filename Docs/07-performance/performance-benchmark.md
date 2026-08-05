# Performance Benchmark

> Baseline：2026-08-02，当前工作树；无历史提交可比较。

## 1. Cold Launch

来源：`App Launch` template，独立 `MiPlayPerf` 产物。

| Trace | Initial Frame Rendering 完成 | Foreground 开始 | 结果 |
|---|---:|---:|---|
| `/tmp/MiPlayColdLaunchPerf.trace` | 0.997 s | 1.044 s | < 3 s |
| `/tmp/MiPlayColdLaunchPerf-2.trace` | 1.089 s | 1.148 s | < 3 s |
| `/tmp/MiPlayColdLaunchPerf-3.trace` | 0.866 s | 0.951 s | < 3 s |

样本最大值 1.089 s，约为 3 s budget 的 36.3%。Trace 被 time limit 结束并将临时启动进程 SIGKILL；这不代表产品正常退出路径。

## 2. Idle resource baseline

### 2.1 Activity Monitor / vmmap

来源：`/tmp/MiPlayIdle.trace`，10.93 秒观察窗口；补充 live PID 28776 的 10 次 `vmmap`/`ps`/`lsof` 采样。

| 指标 | Activity Monitor trace | live sample |
|---|---:|---:|
| Physical Footprint | 98.5–99.5 MiB | 84.6–85.7 MiB |
| Real Memory | 128.7–129.6 MiB | 未取同口径样本 |
| CPU | 约 2.7–4.0% | 1.2–4.4% |
| 磁盘读取 | 19.47 MiB / 10.93 s，约 1.78 MiB/s | 未重复计算 |
| video.mp4 文件描述符 | 未记录 | 每次均为 2 |
| `vmmap` footprint peak | 111.3 MiB | 未重复计算 |

当前缓存中打开的视频为：

- `.../MediaCache/HonkaiStarRail/z44PvVL5nc/video.mp4`
- `.../MediaCache/ZenlessZoneZero/RF7Hpwc3MA/video.mp4`

由于进程同时持有两份 video 文件，且代码在不可见场景仍调用 `queue.play()`，不能把 idle CPU/磁盘值解释为“视频已停止”。

### 2.2 Game Performance

来源：`/tmp/MiPlayGamePerformance.trace`。TOC 中有 `metal-current-allocated-size` 表，但没有可归因于 MiPlay 的有效行；进程列表同时包含 MiPlay、WindowServer 和 Codex。结论为 GPU allocated size 未验证，不把系统 GPU 活动归因于 MiPlay。

## 3. Process benchmark

全部为 `MiPlayCoreTests` 的 50 次重复，结果 bundle 为：

| 场景 | Result bundle | min | P50 | P95 | P99/max | mean |
|---|---|---:|---:|---:|---:|---:|
| normal output/exit | `/tmp/MiPlayDerivedData/Logs/Test/Test-MiPlay-2026.08.02_19-52-54-+0800.xcresult` | 6.51 ms | 8.17 ms | 16.90 ms | 48.94 ms | 11.71 ms |
| timeout | `/tmp/MiPlayProcessTimeout-20260802.xcresult` | 103.03 ms | 110.39 ms | 117.33 ms | 166.70 ms | 111.01 ms |
| wait cancellation | `/tmp/MiPlayProcessCancellation-20260802.xcresult` | 102.59 ms | 107.85 ms | 140.36 ms | 212.12 ms | 112.04 ms |
| duplicate cancelled waiter | `/tmp/MiPlayProcessDuplicateCancellation-20260802.xcresult` | 102.63 ms | 107.95 ms | 115.94 ms | 183.72 ms | 109.65 ms |

所有 200 次重复均通过。timeout/cancellation 结果包含测试中 `sleep 100 ms` 的等待和终止确认，不能当作 production Wine 启动时间。

## 4. Persistence benchmark

### 4.1 steady-state write

基于当前 `PersistenceStore` 的临时 harness，100 次写入，payload 包含 50 条 `taskHistory`、性能设置、背景映射和 Wine 版本列表：

| n | min | P50 | P95 | P99 | max | mean |
|---:|---:|---:|---:|---:|---:|---:|
| 100 | 2.18 ms | 2.45 ms | 2.89 ms | 3.07 ms | 8.68 ms | 2.56 ms |

`writeAppData` 的测量覆盖 JSON encode、`atomicWrite`、备份、文件替换和写后 decode 验证，具体实现位置为 `PersistenceStore.swift:155-176`。

### 4.2 recovery paths

| 场景 | Result bundle | n | P50 | P95 | P99/max | mean |
|---|---|---:|---:|---:|---:|---:|
| legacy migration | `/tmp/MiPlayDerivedData/Logs/Test/Test-MiPlay-2026.08.02_19-50-21-+0800.xcresult` | 50 | 4.67 ms | 14.01 ms | 183.93 ms | 9.60 ms |
| corrupt + backup restore available | `/tmp/MiPlayDerivedData/Logs/Test/Test-MiPlay-2026.08.02_19-51-40-+0800.xcresult` | 50 | 7.78 ms | 17.92 ms | 224.88 ms | 13.23 ms |

## 5. Log benchmark

基于当前 `LogWriter`，100 个 batch、每批 49 条日志：

| 场景 | n | payload | P50 | P95 | P99/max | mean |
|---|---:|---:|---:|---:|---:|---:|
| explicit `flush()` | 100 | 49 entries/batch | 6.37 ms | 7.25 ms | 11.79 ms / 11.88 ms | 6.55 ms |
| `exportLogs()` | 100 | 361,110 bytes | 0.120 ms | 0.184 ms | 0.315 ms / 0.522 ms | 0.133 ms |

## 6. Repeatability commands

```sh
xcodebuild test -project MiPlay.xcodeproj -scheme MiPlay \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/MiPlayDerivedData \
  -only-testing:MiPlayTests/MiPlayCoreTests/testProcessManagerTimeoutTerminatesAndResumesOnce \
  -test-iterations 50 -test-repetition-relaunch-enabled NO

xcrun xctrace export --input /tmp/MiPlayColdLaunchPerf.trace \
  --xpath '/trace-toc/run[1]/data/table[@schema="life-cycle-period"]'

vmmap -summary <PID>
lsof -p <PID> -Fn | rg 'MediaCache.*video\\.(mp4|mov)$'
```

