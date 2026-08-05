# QA Smoke/Regression 报告

> 日期：2026-08-02
> 角色：QA Agent
> 范围：Task 9 自动化质量门禁、手工检查边界、测试结果保留

## 结论

核心自动化回归通过：Debug 与 Release arm64 均 `30 passed / 0 failed / 0 skipped`。P0 自动化 `25/25`，P1 自动化 `5/5`，满足本轮自动化通过率要求。

Release 的第一次命令因未启用 `ENABLE_TESTABILITY` 导致测试 module 编译失败；随后使用固定 arm64 destination 与 `ENABLE_TESTABILITY=YES` 成功完成 30 个测试。两轮结果和失败诊断均保留，未将构建诊断误计为 assertion failure。

## 覆盖摘要

| 范围 | 已验证 |
|---|---|
| ProcessManager | 正常退出、stdout/stderr、退出码、timeout、取消、重复 waiter、缺失 executable、大量输出 |
| Wine 契约 | 缺失 binary 失败、稳定 prefix 路径；真实 Wine/环境变量/权限未执行 |
| Bookmark/GameLocation | bookmark round-trip、scope/version、legacy path migration、未授权时不报 Installed |
| AppData | 损坏恢复、备份、schema 迁移、不支持 schema、非法文件名、写入失败 |
| Manifest | hash、缺失、损坏、版本不匹配、路径逃逸 |
| TaskScheduler | 真实 version-check 任务、进度、取消策略、失败恢复、重启中断修复、持久化结果 |
| 状态/投影 | GameStateMachine 合法/非法转换；registry 与 AppData 结果一致 |
| 兼容方案 | published manifest、能力缺失失败、非法 rollback |
| UI | Button/Settings accessibility 语义契约；真实 Button、VoiceOver、键盘、窗口和本地化仍 Pending |

## Smoke 结果

自动化 Smoke（核心 P0/P1）全部通过。真实 UI Smoke 未完成：Computer Use 无法捕获 DerivedData MiPlay 窗口，系统返回 `ScreenCaptureKit -3811`（音视频捕捉失败）。因此以下项目保持 Pending，不构成已解释失败：

- Settings 齿轮、`⌘,`、六 pane、关闭和居中。
- Button 点击、键盘导航、VoiceOver 朗读与本地化视觉布局。
- bookmark stale/access denied 的重新授权。
- Wine 启动命令、`WINEPREFIX`、`WINEDLLOVERRIDES` 和系统权限。
- 真实兼容方案 apply/fail/rollback、背景 fallback、Loading 遮罩和 crossfade。

## Regression 结果

| 套件 | Debug | Release arm64 |
|---|---:|---:|
| MiPlayTests 总体 | 30/30 Pass | 30/30 Pass |
| P0 | 25/25 Pass | 25/25 Pass |
| P1 | 5/5 Pass | 5/5 Pass |
| UI/Wine/系统权限手工套件 | Pending | Pending |

## 证据

- [Debug result bundle](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Debug-20260802-final.xcresult)
- [Debug log](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Debug-20260802-final.log)
- [Release arm64 result bundle](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Release-20260802-arm64.xcresult)
- [Release arm64 log](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Release-20260802-arm64.log)
- [Release initial build-failure bundle](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Release-20260802-final.xcresult)
- [Test source](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/MiPlayTests/MiPlayCoreTests.swift)

## 门禁判定

Gate 2（自动化实现）通过；Gate 3 仅自动化部分通过；Gate 4 性能未测；Gate 5 Release Ready 未通过。原因是 UI/Wine/系统权限/性能/覆盖率阈值仍无完整证据，而不是本轮自动化存在 P0/P1 assertion failure。
