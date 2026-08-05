# 测试用例

> 执行日期：2026-08-02
> 自动化结果：Debug 30/30；Release arm64 30/30；P0 25/25，P1 5/5。
> 代码：`MiPlayTests/MiPlayCoreTests.swift`

## 自动化用例

| ID | 覆盖范围 | XCTest 方法 | 优先级 | 结果 |
|---|---|---|---|---|
| TC-PROC-001 | stdout/stderr 与退出码 | `testProcessManagerCollectsOutputAndExitStatus` | P0 | Pass |
| TC-PROC-002 | 大量并发输出不死锁 | `testProcessManagerDrainsLargeConcurrentOutput` | P0 | Pass |
| TC-PROC-003 | 非零退出码 | `testProcessManagerReportsNonZeroExit` | P0 | Pass |
| TC-PROC-004 | timeout 后终止且单次恢复 | `testProcessManagerTimeoutTerminatesAndResumesOnce` | P0 | Pass |
| TC-PROC-005 | waiter 取消与子进程清理 | `testProcessManagerCancellationDoesNotDoubleResume` | P0 | Pass |
| TC-PROC-006 | 重复 waiter/取消策略 | `testProcessManagerRejectsSecondCancelledWaiter` | P0 | Pass |
| TC-PROC-007 | executable 不存在 | `testProcessManagerRejectsMissingExecutable` | P0 | Pass |
| TC-DATA-001 | AppData 损坏、备份、恢复 | `testPersistencePreservesCorruptDataAndRestoresBackup` | P0 | Pass |
| TC-DATA-002 | legacy schema 迁移并保留记录 | `testPersistenceMigratesLegacySchemaWithoutDroppingPathRecord` | P0 | Pass |
| TC-DATA-003 | 不支持 schema 与非法文件名 | `testPersistenceRejectsUnsupportedSchemaAndInvalidFilename` | P0 | Pass |
| TC-DATA-004 | base path 为文件时写入失败 | `testPersistenceWriteFailsWhenBasePathIsAFile` | P0 | Pass |
| TC-INT-001 | manifest hash 成功/损坏 | `testIntegrityVerifierUsesManifestHash` | P0 | Pass |
| TC-INT-002 | 缺失文件与不支持 manifest | `testIntegrityVerifierDistinguishesMissingAndUnsupportedManifest` | P0 | Pass |
| TC-INT-003 | unknown/version mismatch | `testIntegrityVerifierRejectsManifestForUnknownOrDifferentVersion` | P0 | Pass |
| TC-INT-004 | manifest 路径逃逸 | `testIntegrityVerifierRejectsManifestPathEscape` | P0 | Pass |
| TC-VER-001 | 本地/注入远端版本比较 | `testVersionCheckerComparesLocalAndInjectedRemoteManifest` | P1 | Pass |
| TC-STATE-001 | 合法与非法状态转换矩阵 | `testGameStateMachineLegalTransitionsAndIllegalTransitions` | P0 | Pass |
| TC-STATE-002 | 状态与游戏类型显示事实 | `testGameStateAndGameTypeDisplayFactsAreLocalized` | P0 | Pass |
| TC-PATH-001 | legacy path 迁移所需状态 | `testLegacyGamePathDecodesAsMigrationRequiredWithoutAuthorization` | P0 | Pass |
| TC-PATH-002 | bookmark、scope、version round-trip | `testGameLocationRoundTripPreservesBookmarkAndScope` | P0 | Pass |
| TC-PATH-003 | registry 不在迁移前误报 Installed | `testGameRegistryLegacyPathIsNotInstalledUntilBookmarkMigration` | P0 | Pass |
| TC-WINE-001 | binary 缺失与 prefix 路径契约 | `testWineRuntimeProviderRejectsMissingBinaryAndBuildsStablePrefixPath` | P1 | Pass |
| TC-SOL-001 | published manifest 与能力缺失 | `testSolutionEngineOnlyExposesPublishedManifestAndFailsBeforeSideEffect` | P1 | Pass |
| TC-SOL-002 | rolled-back 状态禁止重复 rollback | `testSolutionEngineRejectsRollbackFromRolledBackState` | P1 | Pass |
| TC-TASK-001 | 真实 version-check、进度、状态投影、持久化 | `testTaskSchedulerRunsVersionCheckProjectsProgressAndPersistsOutcome` | P0 | Pass |
| TC-TASK-002 | 缺失游戏失败与 recovery hint | `testTaskSchedulerRecordsFailureForMissingGameAndRecoveryHint` | P0 | Pass |
| TC-TASK-003 | 启动中断任务恢复 | `testTaskSchedulerRepairsInterruptedPersistedTask` | P0 | Pass |
| TC-TASK-004 | side-effect 前后取消策略 | `testScheduledTaskCancellationPoliciesMatchSideEffectBoundaries` | P0 | Pass |
| TC-TASK-005 | unsupported/malformed request 拒绝 | `testTaskSchedulerRejectsUnsupportedAndMalformedRequests` | P0 | Pass |
| TC-UI-001 | 主按钮与 Settings accessibility 契约 | `testPrimaryButtonAndSettingsAccessibilityContractsAreStable` | P1 | Pass（静态/语义） |

## 手工 Smoke

| ID | 检查 | 通过条件 | 本轮结果 |
|---|---|---|---|
| SMOKE-001 | 应用启动与主窗口 | 主窗口可交互，游戏入口可见 | Pending：截图捕获失败 |
| SMOKE-002 | 游戏状态显示 | 状态名称、颜色、操作建议一致 | Pending |
| SMOKE-003 | Settings 齿轮与 `⌘,` | 同一 Settings Scene 打开 | Pending |
| SMOKE-004 | Settings 关闭 | 关闭后主窗口仍可用 | Pending |
| SMOKE-005 | 六个 Settings pane | 800×448 下全部可见且可选 | Pending |
| SMOKE-006 | VoiceOver | Button label、hint、状态可被朗读 | Pending：需 VoiceOver 实机 |
| SMOKE-007 | 键盘导航 | Tab/方向键/Return/`⌘,` 可完成主要路径 | Pending |
| SMOKE-008 | 本地化 | 中文/英文系统下无 raw key、截断或重叠 | Pending |
| SMOKE-009 | bookmark stale/access denied | 明确提示并可重新授权，不误报 Installed | Pending |
| SMOKE-010 | Wine 启动命令/prefix | 环境变量、参数、prefix 和权限正确 | Pending：真实 Wine |
| SMOKE-011 | 兼容方案应用/失败/回滚 | 失败不留半成品，回滚可追踪 | Pending：helper 权限 |
| SMOKE-012 | 背景与 Loading fallback | 视频/图片/default fallback 与阻断行为正确 | Pending |

## 回归规则

- 任一 TC-PROC、TC-DATA、TC-STATE、TC-TASK、TC-INT 的 P0 用例失败，阻断发布。
- 手工场景不能通过源码存在替代；必须记录操作、结果、截图或录屏路径。
- Wine、系统权限和真实网络失败不能作为 unit failure 计数，必须进入集成/手工 defect log。
