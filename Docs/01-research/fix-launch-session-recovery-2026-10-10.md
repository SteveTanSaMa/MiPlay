# MiPlay 启动会话恢复修复（wineserver 清理失败后可在本会话内重试）

日期：2026-10-10（Asia/Shanghai）
范围：仅修复第二阶段审计确认的"启动会话恢复状态机"问题；未做任何其它改动。
限制遵守：**未启动游戏、未调用真实 Prefix 的 wineserver、未修改真实 Wine/DXMT 资产/Prefix/缓存、未执行 E1–E5 人工实验**。测试全部在临时目录 + 假 runtime/假 wineserver 上运行。
状态：改动已完成并通过测试，**未提交**，等待审核。

---

## 1. 根因：原有状态判断为什么会阻止恢复

`currentLaunchProcessID` 在改造前同时承担三件事（未拆分）：

| 职责 | 读取点 | 说明 |
| --- | --- | --- |
| ① 会话在途 → 拒绝重复启动 | `launch(game:)`：`guard currentLaunchProcessID == nil, currentGameID == nil`（`LaunchOrchestrator.swift:116`） | 也用于返回 `.gameAlreadyRunning` |
| ② 取消目标 | `cancelLaunch()`：`guard let processID = currentLaunchProcessID`（`:514`） | 取消时用它定位要清理的会话 |
| ③ "退出提交/清理尚未完成"的标记 | `cleanup`：`guard currentLaunchProcessID != processID else { throw recoveryRequired(...) }`（`:581`） | 判断 monitor 是否已完成退出提交 |

失败链条（改造前）：

1. `monitorProcess` 的退出等待返回 → 进程已确认退出；
2. 提交退出事实成功 → 停止安全作用域 → 进入 `releaseSharedPrefixLease()` → `wineserver -k` 失败；
3. 抛错进入 catch → 写入 `processExit` 恢复记录 → **`currentLaunchProcessID` 仍非空**（它只在成功路径末尾被清空）；
4. 此时唯一的恢复入口 `retryProcessExitRecovery` 的第一条判断是 `guard currentLaunchProcessID == nil` → 直接抛 `启动进行中，暂缓执行状态恢复`；
5. 而 `launch()` 也会因同一守卫返回 `.gameAlreadyRunning` ⇒ 用户在本会话内既不能恢复、也不能启动，只能重启应用（重启后 `currentLaunchProcessID == nil`，既有自动恢复成功）。

次要缺陷（同一入口内）：改造前顺序是"**先**提交退出事实、**再**释放 prefix"。若提交成功而清理失败，待恢复记录已被消费（`resolvedAt` 置位），即使解除守卫，第二次重试也会因"恢复事实不存在或已处理"而失败。

结论：`currentLaunchProcessID` 把"会话在途"和"进程是否仍在运行"两件事混在一起，导致**进程已经确认退出**的情况下恢复入口仍被自己的守卫拒绝。

---

## 2. 修复方案

### 2.1 状态拆分（最小）

新增一个布尔事实，只表达"本次会话的进程退出已被确认"：

- `private var sessionProcessExited = false`（`LaunchOrchestrator.swift:86`）
  - 置位点：**唯一的** `monitorProcess` 退出等待返回之后（`:733`）——`ApplicationLauncher.waitForExit`（`.app` 路径）与 `processManager.waitForTermination`（直接子进程路径）共用的汇合点；
  - 清零点：会话开始时（`launch`，`:124`）与会话收尾时（`endLaunchSession()`，`:554-558`）。

新增收尾辅助 `endLaunchSession()`，把原先散落的 `currentLaunchProcessID = nil; currentGameID = nil` 两行统一为"三者一起重置"，用于四处收尾路径（`:614` `cleanup`、`:672` 启动失败路径、`:751` monitor 成功路径、`:826` 恢复成功路径）。**正常退出流程的语句顺序与结果不变**（仅两行赋值收进函数）。

### 2.2 恢复入口前置条件（纯函数）

```swift
/// 只有"存在在途会话且该会话的进程还没有确认退出"才是禁止条件。
nonisolated static func canRetryProcessExitRecovery(
    hasActiveSession: Bool,
    sessionProcessExited: Bool
) -> Bool {
    !hasActiveSession || sessionProcessExited
}
```

`retryProcessExitRecovery` 改为调用该函数（`:812-818`）：会话在途且进程未确认退出时仍抛 `启动进行中，暂缓执行状态恢复`；进程已确认退出时放行。

### 2.3 恢复入口内部顺序

```swift
try await releaseSharedPrefixLease()          // 幂等：已释放时内部直接返回
try await gameRegistry.retryProcessExitRecovery(recordID: recordID)
...
endLaunchSession()
```

先释放共享 prefix、再提交退出事实（`:821-827`）。这样：

- 清理失败 → 待恢复记录**保持未消费** → 可继续重试；
- 提交失败（清理已成功）→ 记录同样保持 → 重试时 prefix 释放走幂等早返回，不再二次 kill。

### 2.4 状态转换（改造前 → 改造后）

| 场景 | 改造前 | 改造后 |
| --- | --- | --- |
| 进程退出、清理成功 | 守卫清空，无记录 | 同（不变） |
| 进程退出、清理失败 | 守卫保留 + 记录保留；**恢复入口被拒** | 守卫保留 + 记录保留；**恢复入口放行（先重试清理）** |
| 进程退出、清理失败、提交也失败 | 同上（且记录可能被消费） | 同上（记录不会被消费） |
| 游戏仍在运行 | 恢复入口被拒 | **仍被拒**（`sessionProcessExited == false`） |
| 应用重启后 | 守卫为空 → 自动恢复 | 同（不变，未改动该路径） |

---

## 3. 安全性

| 要求 | 保障方式 | 证据 |
| --- | --- | --- |
| 不误判仍在运行的游戏已退出 | `sessionProcessExited` 只在退出等待返回后置位；游戏运行时它保持 false ⇒ 恢复入口被拒 | `:733`；判定矩阵测试第 3 组 |
| 清理未完成时不允许不安全的新启动 | ①`launch()` 的会话守卫未改动；②共享 prefix 租约未释放时 `acquireSharedPrefixLease()` 抛 `prefixBusy`；③恢复成功后才 `endLaunchSession()` | `:116`；`WineRuntimeProvider.swift:161`；集成测试断言会话未收尾时新启动被 `.gameAlreadyRunning` 拒绝 |
| 不重复释放同一 Prefix 租约 | 编排层 `releaseSharedPrefixLease()` 在 `activeSharedPrefixLease == nil` 时直接返回；provider 层要求 lease id 匹配 | `:611-613`；`WineRuntimeProvider.swift:172-177`；集成测试在恢复成功后再次调用，被注册表拒绝且未再触发 `wineserver -k` |
| 不重复恢复/覆盖 DLL | `LaunchCompatibilityEnvironment.restore` 幂等（目标文件已存在即跳过）；monitor 中每次会话只调用一次；恢复入口不再调用它 | `LaunchCompatibilityEnvironment.swift:327-335`；`:728` |
| 旧会话清理不影响新会话 | 守卫在整个恢复完成前保持；恢复成功才清空；恢复顺序中 prefix 释放先于提交，而新启动仍被守卫挡住 | `:821-827` |
| 不破坏重启后的自动恢复 | 未触碰 `autoRecoverPendingRecords` / `GameRegistry.retryProcessExitRecovery` / 恢复记录读写 | 既有测试 `testPendingProcessExitRecoveryCommitsAutomaticallyThroughViewModel` 仍通过 |
| 正常退出保持原行为 | 成功路径语句顺序与结果不变，只把两行赋值收进 `endLaunchSession()` | 既有 `testLaunchOrchestratorRefreshesStaleBookmarkAndCommitsExitState` / `testCancellationWaitsForExitCommitAndAllowsConsecutiveRelaunch` 仍通过 |

---

## 4. 代码差异（文件 / 函数 / 关键改动）

| 文件 | 函数/位置 | 改动 |
| --- | --- | --- |
| `MiPlay/Domain/Launch/LaunchOrchestrator.swift` | 属性区 `:81-87` | 新增 `private var sessionProcessExited = false`（含说明注释） |
| 同上 | `launch(game:)` `:124` | 会话开始时清零 `sessionProcessExited` |
| 同上 | `monitorProcess(processID:game:)` `:723-733` | 退出等待返回后置位 `sessionProcessExited = true`（注释说明语义） |
| 同上 | 新增 `endLaunchSession()` `:552-558` | 统一收尾：清进程守卫 / 游戏守卫 / 退出事实 |
| 同上 | `cleanup` `:614`、启动失败路径 `:672`、monitor 成功路径 `:751`、恢复成功路径 `:826` | 改为调用 `endLaunchSession()`（行为等价） |
| 同上 | `retryProcessExitRecovery(recordID:)` `:807-828` | 前置条件换成 `canRetryProcessExitRecovery(...)`；顺序改为"先释放 prefix、再提交退出事实"；收尾走 `endLaunchSession()` |
| 同上 | 新增 `canRetryProcessExitRecovery(hasActiveSession:sessionProcessExited:)` `:830-837` | 纯函数前置条件（可测试） |
| `MiPlayTests/SchedulerRecoveryTests.swift` | 新增 `testLaunchRecoveryPreconditionMatrix` `:460-478` | 4 组判定矩阵 |
| 同上 | 新增 `testWineserverShutdownFailureKeepsSessionRecoverableInApp` `:480-` | 假 runtime + 受控 wineserver 的端到端会话恢复测试 |

改动规模：生产代码 1 个文件、41 行新增 / 11 行删除；测试 1 个文件、+210 行。**未触碰** DXMT 配置、Wine 环境变量、游戏图形设置、Prefix 结构、启动参数或 SwiftUI 页面。

---

## 5. 测试结果（实际运行）

| 测试 | 覆盖场景 | 结果 |
| --- | --- | --- |
| `testLaunchRecoveryPreconditionMatrix` | 场景 5 判定 + 场景 2/3 的判定前提 | ✅ passed（0.003s） |
| `testWineserverShutdownFailureKeepsSessionRecoverableInApp` | 场景 2/3/4/6 + 场景 1 的收尾可再次启动 | ✅ passed（3.596s） |
| 既有 `testPendingProcessExitRecoveryCommitsAutomaticallyThroughViewModel` | 场景 7（重启后自动恢复） | ✅ passed |
| 既有 `testLaunchOrchestratorRefreshesStaleBookmarkAndCommitsExitState` / `testCancellationWaitsForExitCommitAndAllowsConsecutiveRelaunch` | 场景 1（正常退出/取消） | ✅ passed |
| **全量** | — | ✅ **161 tests, 0 failures, 2 skipped**（2 项为需真实游戏的验收测试，按设计跳过）；总耗时 81.7s |

端到端集成测试的断言链（临时目录内、假 runtime）：

1. 启动成功后退出，`wineserver -k` 返回 42 → 等待"状态 `installed` + 存在 `processExit` 待恢复记录"；
2. 会话未收尾时再次 `launch()` → 返回 `.failure(.gameAlreadyRunning)`（共享 Prefix 不会并发操作）；
3. 调用 `retryProcessExitRecovery` → **不再抛"启动进行中"**（本次修复的目标），而是表现为 prefix 清理失败；
4. 第一次重试失败后，待恢复记录仍在（不丢失）；
5. 令 `wineserver -k` 成功 → 同一会话内重试成功：待恢复记录清空、状态 `installed`；
6. 同一恢复事实再次重试被拒（不会二次释放/二次清理）；
7. 之后可再次启动（守卫已清空），最后 `cancelLaunch()` 收尾。

### 场景覆盖说明（明确未自动化覆盖的部分）

| 场景 | 覆盖情况 |
| --- | --- |
| 1 正常退出 | 自动化 ✅（既有两个用例 + 集成测试第 7 步） |
| 2 清理失败 | 自动化 ✅（集成测试第 1、3 步） |
| 3 失败后重试成功 | 自动化 ✅（集成测试第 5 步） |
| 4 失败后再次失败 | 自动化 ✅（集成测试第 3、4 步：记录保留、不重复释放） |
| 5 游戏仍在运行 | **判定级**：纯函数矩阵第 3 组 + 代码论证（`sessionProcessExited` 仅在退出等待返回后置位）。**未做端到端**：需要一个长时间运行的假游戏进程才能复现，本轮未补该夹具。 |
| 6 并发启动 | 自动化 ✅（集成测试第 2 步，会话在途时拒绝新启动） |
| 7 应用重启恢复 | 自动化 ✅（既有用例，未改动该路径） |

其它观察（**与本任务无关、未修改**）：Swift 6 语言模式下**测试目标**在 `MiPlayTests/LaunchOptimizationTests.swift:628-629` 报既有错误（`backgroundModes`/`customImagePaths` 在 `@Sendable` 闭包中被修改，来自提交 `7e12d77`）。应用目标在 `SWIFT_VERSION=6` 下 `BUILD SUCCEEDED`，本次改动的生产代码在 Swift 6 下干净。按"不顺手修改无关代码"的约束，未处理该测试文件。

---

## 6. 未覆盖风险（仍需真实游戏测试）

1. **真实 wineserver 行为的边界**：本轮用假脚本覆盖了 `-k` 退出码非 0 的路径；真实环境中 `wineserver -k` 可能长时间挂起（10s 上限）或返回其它码，用户可见的等待体验未验证。
2. **`wineserver -k` 重试的副作用**：恢复会再次执行 `wineserver -k`。若 `sessionProcessExited` 被错误置位（理论上不会——它只在退出等待返回后置位，且 `.app` 路径由 `GameLauncher` 的 `wineserver -w` 兜住"包装进程先退出、游戏仍在跑"的情况），可能影响仍在运行的进程。**建议在真实会话里确认一次**（退出游戏后立刻断电式关闭应用、重启再恢复）。
3. **恢复顺序调整引入的新窗口**：现在是"先释放 prefix、再提交退出事实"，两步骤之间若应用被强杀，会留下"prefix 已释放但状态未提交"的组合。既有 `restartReconciliation` 机制覆盖这类重启对账，但**本轮没有为这一组合新增测试**。
4. **正常退出流程的完整回归**：集成测试覆盖了假 game 脚本（0.2s 退出）；真实游戏（长会话、异常退出码、信号终止）下的收尾行为仍需人工确认。

---

## 7. 回退方法

本次改动**未提交**。当前工作区中本次相关改动只有两个文件：

```sh
git checkout -- MiPlay/Domain/Launch/LaunchOrchestrator.swift MiPlayTests/SchedulerRecoveryTests.swift
```

（这两个文件在本次修改前是干净的，`git status` 已确认；`Docs/05-implementation/implementation-notes.md` 与两份审计报告属于前序轮次，不在回退范围。）
回退后行为恢复为：清理失败时会话内不可恢复、需重启应用。回退后建议重跑 `xcodebuild test` 确认 159 项既有测试仍通过。

---

## 8. 执行边界声明

本轮只做了：读源码/文档、改上述两个文件、在临时目录用假 runtime/假 wineserver 跑测试、写本文件。未启动任何游戏、未调用真实 Prefix 的 `wineserver`、未修改真实 Prefix/Wine/DXMT/缓存、未执行任何延后的人工实验。等待审核。

---

# 附：提交前异常路径验证（2026-10-10 第二轮）

本轮目标是检查现有修复在异常路径下的状态一致性，**没有重新设计机制**。

## 9. 检查范围内的三个问题

### A. Prefix 已释放、退出事实提交失败（已覆盖，自动化测试）

实现依据：`commitProcessExitRecovery`（`GameRegistryLocation.swift:419-458`）把"状态写入 + 记录标记 resolved"放在**同一个 `updateAppData` 事务**里，失败时回滚内存状态并抛错 ⇒ 提交失败不会消费记录。

新增测试 `testRecoveryAfterPrefixReleasedButExitCommitFails`（3.12s，✅ passed）断言：

| 验证目标 | 断言 |
| --- | --- |
| 不重复释放 Prefix | 该次重试恰好执行 1 次 `wineserver -k`；清除写失败后再次重试，`-k` 计数**不变**（用假 wineserver 调用日志计数，`RecoverableSessionFixture.killCount()`） |
| 不丢失恢复记录 | 提交失败后该记录仍在 `pendingRecoveryRecords` |
| 可最终完成提交 | 清除注入的写失败 → 重试成功 → 待恢复记录清空、状态 `.installed` |
| 成功后状态一致 | 恢复后重新启动成功（随后正常取消） |
| 不误操作新会话 | 会话未收尾时新启动仍被 `.gameAlreadyRunning` 拒绝（沿用上一轮断言） |

### B. 上述状态下应用重启（已覆盖，复用同一夹具）

新增测试 `testRestartAfterPrefixReleasedButExitCommitFails`（2.00s，✅ passed）：先构造"已释放 + 提交失败"的状态，随后**丢弃第一个会话，用同一 `PersistenceStore` 与同一临时目录新建实例**（模拟应用终止/重启），并显式调用 `registry.reconcileInterruptedLaunches()`。

| 验证目标 | 断言 |
| --- | --- |
| 识别已释放的 Prefix | 新实例恢复过程中 `wineserver -k` 计数**不增加**（`releaseSharedPrefixLease` 对空租约直接返回） |
| 不重复清理 | 同上（不触发 `shutdownSharedPrefix`） |
| 可完成恢复 | 记录清空、状态 `.installed` |
| 不遗留阻止新启动的状态 | 新实例可直接启动并正常取消 |

说明：该场景下游戏状态在崩溃前已是 `.installed`（monitor 的提交已成功），因此 `reconcileInterruptedLaunches()` 不会新建 `restartReconciliation` 记录；应用重启后的恢复由"待恢复记录 + 无会话守卫"路径完成。测试同时断言了两者并存时不会互相干扰。

### C. 监控任务异常与取消（代码审查 + 结论；未改生产代码）

`monitorProcess` 的出口逐一核对：

| 出口 | `sessionProcessExited` | 会话守卫 | 恢复路径 |
| --- | --- | --- | --- |
| 正常退出（提交 + 清理成功） | 置位 → 结束时清零 | 清空 | 不需要 |
| 退出等待抛错（外层 catch，`游戏退出事实无法确认`） | **保持 false** | 保持 | **本会话内关闭**（需重启） |
| 提交失败 / 清理失败 | 置位（在退出等待返回后、两条路径之前） | 保持 | 开启（本次修复目标） |
| 取消（`cancelLaunch` → `cleanup`） | 由 monitor 决定（cleanup 只 await monitor） | monitor 结束时同步 | 若 monitor 失败则开启；`cleanup` 会抛 `进程已结束，但退出状态或共享 prefix 清理尚未提交` 并保留守卫 |

结论：

1. **`sessionProcessExited` 只在进程确实退出后置位**：它是 `waitForExit`/`waitForTermination` 返回之后、`restoreStagedGameFiles()` 之前的顺序语句（`:723-733`）。任何"等待抛错"的路径都不会置位 ⇒ 不会误判"游戏已退出"。
2. **取消不会误判退出**：`cleanup` 不再自行释放租约，而是 `await monitor.value` 后检查守卫，行为与 monitor 的真实结论一致（既有注释与 `testCancellationWaitsForExitCommitAndAllowsConsecutiveRelaunch` 覆盖）。
3. **唯一"本会话内不可恢复"的出口是退出等待抛错**（`ProcessManager.waitForTermination` 的 `processNotRunning`/`unsupportedOperation` 等罕见情况）。此路径**故意不置位** `sessionProcessExited`：此时无法证明进程已退出，允许恢复就会用 `wineserver -k` 误杀可能仍在运行的进程。**本轮不改生产代码**，理由：安全优先；状态可由应用重启确定性恢复（重启后无会话守卫、`reconcileInterruptedLaunches` + 待恢复记录路径生效），且该分支在实践中需"进程记录既不在活动列表也不在完成列表"才可达。
4. 该出口目前只在日志中体现（`游戏退出事实无法确认: …`），未单独写恢复记录。如后续要提升可诊断性，可在此处补一条显式记录（属可选改进，本轮未做）。

## 10. Swift 6 构建情况（澄清）

| 项目 | 结果 |
| --- | --- |
| 应用目标（`SWIFT_VERSION=6 build`） | ✅ `BUILD SUCCEEDED`（含本次改动的生产代码） |
| 测试目标（`SWIFT_VERSION=6 build-for-testing`） | ❌ 失败于 `MiPlayTests/LaunchOptimizationTests.swift:628-629`（`backgroundModes` / `customImagePaths` 在 `@Sendable` 闭包中被修改） |
| 该错误是否为既有问题 | **是。** 这两行存在于提交 `7e12d77`（`git show 7e12d77:MiPlayTests/LaunchOptimizationTests.swift` 可见）；本次改动未触碰该文件（`git diff` 为空） |
| 实际测试使用的语言模式 | **Swift 5 语言模式**（`project.pbxproj` 中 `SWIFT_VERSION = 5.0`）；全量 `xcodebuild test` 在该模式下通过 |
| 是否修改 LaunchOptimizationTests.swift | 未修改（遵守本轮约束） |

## 11. 本轮测试结果汇总

| 测试 | 结果 |
| --- | --- |
| `testRecoveryAfterPrefixReleasedButExitCommitFails`（新增） | ✅ passed (3.12s) |
| `testRestartAfterPrefixReleasedButExitCommitFails`（新增） | ✅ passed (2.00s) |
| `testLaunchRecoveryPreconditionMatrix`（上轮新增） | ✅ passed |
| `testWineserverShutdownFailureKeepsSessionRecoverableInApp`（上轮新增） | ✅ passed (2.6–3.6s) |
| **全量** | ✅ **163 tests, 0 failures, 2 skipped**（跳过项为需真实游戏的验收测试），86.5s |

## 12. 当前未提交文件（截至本轮结束）

```
 M Docs/05-implementation/implementation-notes.md      （前序轮次的文档更新，非本轮代码）
 M MiPlay/Domain/Launch/LaunchOrchestrator.swift        （本轮修复：生产代码）
 M MiPlayTests/SchedulerRecoveryTests.swift             （上轮 + 本轮新增测试）
?? Docs/01-research/fix-launch-session-recovery-2026-10-10.md
?? Docs/01-research/investigation-launch-chain-deep-dive-2026-10-10.md
?? Docs/01-research/investigation-launch-chain-perf-audit-2026-10-10.md
```

## 13. 是否建议提交

**建议提交**，理由：修复已由 5 项自动化测试覆盖（含异常路径与重启路径）、全量 163 项无失败、应用目标在 Swift 5/6 两种语言模式下均能构建、改动范围仅 1 个生产文件 + 1 个测试文件、`git diff --check` 干净。

建议提交信息（不含推送）：

```
修复 wineserver 清理失败后的启动会话恢复

- LaunchOrchestrator：新增 sessionProcessExited 事实，恢复入口改为
  canRetryProcessExitRecovery 判定（仅"会话在途且进程未确认退出"时拒绝），
  恢复顺序改为先释放共享 prefix、再提交退出事实
- 收尾统一走 endLaunchSession()
- 新增 4 项测试：判定矩阵、wineserver 清理失败的会话内恢复、
  恢复时 Prefix 已释放但退出提交失败、该状态下应用重启
- 全量 163 tests / 0 failures（2 项需真实游戏的验收测试按设计跳过）
```

提交时请**不要**包含 `Docs/05-implementation/implementation-notes.md` 与本轮之外的三份文档（由用户决定是否一并提交）。
