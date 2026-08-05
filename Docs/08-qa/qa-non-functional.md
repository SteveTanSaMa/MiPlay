# 非功能测试与回归策略

> 状态：2026-08-02 执行版

## 已执行的非功能边界

| 类别 | 场景 | 结果 | 证据 |
|---|---|---|---|
| 稳定性 | Process 大量 stdout/stderr | Pass | TC-PROC-002 |
| 稳定性 | Process timeout/取消/重复 waiter | Pass | TC-PROC-004~006 |
| 数据可靠性 | JSON 损坏、备份恢复、schema 迁移 | Pass | TC-DATA-001~004 |
| 数据安全 | manifest 路径逃逸 | Pass | TC-INT-004 |
| 并发状态 | Task progress、失败、重启恢复 | Pass | TC-TASK-001~005 |
| 网络隔离 | 自动化不访问外网，版本使用注入 fixture | Pass（测试隔离） | TC-VER-001 |
| 架构兼容 | Apple Silicon arm64 Debug/Release | Pass | 两个 `.xcresult` |

## 尚未执行的发布级非功能测试

| 类别 | 测试 | 通过门槛 | 状态 |
|---|---|---|---|
| 性能 | Cold launch | < 2.0s，硬上限 < 3.0s | Pending：无性能 trace |
| 性能 | Idle/运行中 memory | 目标 <150/<300 MB，硬上限 <200/<400 MB | Pending |
| 性能 | 持久化 P99 | <50ms，硬上限 <100ms | Pending |
| 兼容 | macOS 26+ 子版本、M1-M4 | 主路径无回归 | Pending：当前仅本机 arm64 |
| Wine | 实际 binary、`WINEPREFIX`、DLL override | 命令、环境、权限正确 | Pending |
| 沙箱 | security-scoped bookmark stale/access denied | 可重新授权且不误报路径可用 | Pending |
| UI | Button、VoiceOver、键盘、窗口、hover、布局 | Smoke 全 Pass，P0 UI 全 Pass | Pending：ScreenCaptureKit `-3811` |
| 本地化 | 中文/英文系统、按钮和错误文本 | 无 raw key、截断、重叠 | Pending |
| 可靠性 | 强制退出后恢复、7×24 内存增长 | 无数据丢失；增长 <20% | Pending |

## Smoke/Regression 触发策略

| 变更 | 必跑套件 |
|---|---|
| Process/Launch/Wine 改动 | TC-PROC 全组 + SMOKE-010 |
| Persistence/GameLocation/GameRegistry 改动 | TC-DATA、TC-PATH、TC-STATE + SMOKE-009 |
| Integrity/Solution 改动 | TC-INT、TC-SOL + SMOKE-011 |
| TaskScheduler/状态投影改动 | TC-TASK、TC-STATE |
| UI/window/localization 改动 | TC-UI + SMOKE-001~008、SMOKE-012 |
| 发布候选 | Debug + Release 自动化、全手工 Smoke、性能和真实 Wine |

## 当前手工执行记录

当前桌面存在两个 DerivedData MiPlay 进程，但 Computer Use 无法取得窗口截图，返回 `NSCocoaErrorDomain/ScreenCaptureKit -3811`。因此 UI/VoiceOver/键盘/本地化/窗口项目保持 Pending；这不是生产功能失败，也不能作为 Gate Pass 证据。
