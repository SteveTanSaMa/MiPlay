# P1 Closure Report

> 日期：2026-08-04；只使用当前 MiPlay 代码、62/62 Debug/Release XCTest 和当前工程配置。

| Issue | 当前状态 | 代码证据 | 测试/文档证据 | 结论 |
|---|---|---|---|---|
| P1-REV-003 | Closed | `GameRegistry` 的进程退出提交失败、recovery guard、重启 reconcile 和 retry 只提交事实不重启 | `MiPlayTests/MiPlayCoreTests.swift:1136-1383` | 持久 Running 不会在重启边界被当作正常运行；真实游戏仍待用户验证 |
| P1-REV-004 | Closed | 五类消费者都从 `GameLocation` 获得 scope；stale refresh/writeback 未成功不发布结果 | `MiPlayTests/MiPlayCoreTests.swift:1385-1715` 覆盖 refresh、写回失败、revoked、preflight、launch | 代码/fixture 关闭；真实 NSOpenPanel bookmark 仍是外部验证 |
| P1-01 | Closed | `SecurityScopedAccess.stop()` 幂等，`defer` 成对释放，stale refresh 后才提交新 bookmark | bookmark counter、revoked access 和 writeback failure tests passed | 不把 fixture 当真实 Sandbox 通过 |
| P1-02 | Closed | 生产游戏入口是 `verify(game:)`/`checkVersion(for:)`/`GameLocation`；path overload 为 `internal` 测试/迁移 seam。Wine runtime 和 extraction seam 也为 `internal` 且必须构造 managed identity | `testLegacyGamePathDecodesAsMigrationRequiredWithoutAuthorization`、`testStaleBookmarkWriteback...`、`testWineExtractionRejectsArchiveOutsideManagedStagingWithoutDeletingIt` | 关闭；BackgroundMedia 的 raw destination 只指 App-owned cache，不是游戏授权路径 |
| P1-03 | Closed | `config.ini` 原始 section/key/value 保留；`pkg_version` size/MD5 仅在批准 manifest mapping 下发布版本事实；冲突不发布 current/update | `MiPlayTests/MiPlayCoreTests.swift:431-561` | 未推断 `wpf_version` 或未经证据确认的格式 |
| P1-04 | Closed | `checkReadiness(for:)` 要求 verified prefix `drive_c`；Settings 无 game context 返回 `prefixNotReady`；launch preflight 使用同一 managed runtime 调 `preparePrefix` | `testWineReadinessRequiresGameSpecificPrefixBeforeWineReady` 2044-2093 | 关闭代码契约；真实 Wine/wineboot 仍待用户验证 |
| P1-05 | Closed | `TaskReceipt` 仅在 pending commit/read-back 后返回；`wineRuntime` lock、重复 intent、recovery-held lock 均保留 | `testWineSchedulerReturnsOneReceiptAndRejectsResourceConflict` 1827-1863 | 关闭 |
| P1-06（历史关闭） | Reopened as P1-REV-005 | API `request` 有 typed `httpError`，但 asset `download` 的 non-2xx 变成字符串，Domain 全部映射为 `networkUnavailable` | 现有测试只有 catalog 403/429、non-HTTP/missing response、redirect；没有 asset 403/404/429/5xx 专门测试 | 不能继续视为完整关闭 |
| P1-07 | Closed | `ManagedStaging` 只允许 canonical `WineVersions/.staging` child；archive、symlink、extracted tree 和 cleanup 均受 root guard | `testManagedWineStagingRejectsOutsideAndSymlinkDestinations`、`testWineExtractionRejectsArchiveOutsideManagedStagingWithoutDeletingIt` 2095-2146 | 关闭；签名 Sandbox 运行仍待外部验证 |
| P1-08 | External Blocked | SwiftUI 静态 AX modifiers 存在，动态状态由 ViewModel 投影 | 无签名 App、AX Inspector、VoiceOver global navigation/audio transcript 或动态任务记录 | 必须保留阻塞 |

## Closure Gate

P1-REV-003、P1-REV-004、P1-02、P1-04、P1-07 已满足代码、测试和文档证据要求。当前 Review 不能整体 Pass，因为 P1-REV-005 是新的实现缺口，P1-08 仍需真实 Apple 运行证据。

