# MiPlay P1 修复影响分析

> **文档状态**：已冻结（历史 P1 修复基线；Wine 部分已由 2026-08-28 Architecture 回溯取代）
> **更新日期**：2026-08-28
> **当前规范**：Wine runtime/prefix 以 `architecture-domain-model.md` §4、`architecture-service-contracts.md` §7-8、`architecture-task-queue.md` §3/§5/§8 和 ADR 037-042 为准；本文中旧的 `WineAssetDownload`、多版本、来源选择和独立 prefix 描述不得直接交付 Implementation。
> **范围**：Review `P1-REV-001` 至 `P1-REV-004`
> **实现约束**：本文只冻结契约和影响范围，不修改业务代码，不新增 Deferred 功能。

## 1. P1 总览

| P1 | 根因 | 修复契约 | 主要影响模块 | 不改变的边界 |
|---|---|---|---|---|
| `P1-REV-001` | 固定 Wine setup 绕过 TaskScheduler，取消没有贯穿内部 Task/URLSession/解压/Wine 子进程 | `TaskReceipt`、全局 `wineRuntime` 与 `sharedWinePrefix` 互斥、统一 Task events、清理确认后才 cancelled | TaskScheduler、WineVersionManager、WineRuntimeProvider、NetworkDownloadProvider、Settings VM 入口 | 不增加新的下载产品能力；当前任务名为 `WineRuntimeSetup`，目标固定为 `wine-crossover-11.0-1-signed` 和唯一 shared prefix |
| `P1-REV-002` | `markVersionInstalled` 写入失败被吞掉，下载流仍发布 completed | completed/failed/recoveryRequired 的提交门槛 | WineVersionManager、PersistenceStore、TaskScheduler、DomainEvent | 不改变 JSON 存储方案，不自动把 artifact 视为 installed |
| `P1-REV-003` | 进程退出后的 Game 状态提交失败仍释放保护，留下 Running/实际退出矛盾 | `ProcessExitRecoveryRecord`、先提交终态再释放 guard、恢复后新任务重试 | LaunchOrchestrator、GameRegistry、ProcessManager、TaskScheduler、AppData | 不新增用户可见 Game 业务状态，不自动重启游戏 |
| `P1-REV-004` | stale bookmark 只有部分消费路径回写 | 统一 scoped access lease，刷新 bookmark 后先提交，再发布消费者结果 | GameFileSystemRepository、GameRegistry、FileIntegrityVerifier、VersionChecker、PreLaunchValidator、LaunchOrchestrator | 不回退裸 path，不扩大 Sandbox 权限，不新增路径定位功能 |

## 2. 共同契约

1. 所有修复沿用 UI → ViewModel → Domain → Infrastructure；Settings 不得直连 Wine 下载流。
2. `Task.status` 仍只有 `pending`、`running`、`completed`、`failed`、`cancelled`。
3. `recoveryRequired` 是持久化恢复保护事实，不是新的 Task.status 或 Game 业务状态。
4. 重试创建新的 UserIntent/Task，旧 Task 的失败、取消和恢复事实不被覆盖。
5. `completed` 必须同时有业务 outcome 和相关持久化记录的重读验证；“流结束”“进程退出”“bookmark 已刷新到内存”都不满足该门槛。
6. 未修改 Product 范围：不新增游戏安装、完整更新、自定义任意启动参数、帧率解锁或未发布兼容方案。

## 3. P1-REV-001：Wine 下载 TaskReceipt、互斥和取消

### 3.1 输入

TaskScheduler 接收：

- `intentID`：用户点击下载的一次意图。
- `kind=WineRuntimeSetup`。
- `target.runtimeIdentity`：固定为 `wine-crossover-11.0-1-signed`；不接受用户版本选择。
- `priority=userInitiated`。
- `resourceKeys=[wineRuntime, sharedWinePrefix]`。
- `cancellationPolicy=cleanupBeforeCancelled`。
- 已验证的下载 metadata/asset 参数；不包含任意 shell 命令。

WineVersionManager 只能从 Task executor 接收上述类型化输入，不能由 SettingsViewModel 直接消费 `downloadAndInstall` stream。

### 3.2 TaskReceipt 输出

只有以下顺序完成后才返回 Receipt：

```text
validate input
  → register wineRuntime exclusivity
  → persist pending Task
  → re-read pending Task
  → return TaskReceipt
```

Receipt 至少包含 task ID、intent ID、runtime tag、`pending`、event cursor、`wineRuntime` lock、取消策略和 `persistence=committed`。

- 同一 runtime tag 已有 accepted task：返回已有 task ID 的 deduplicated Receipt，不创建新任务。
- 不同 runtime tag 已有 Wine 下载：返回带 existing task ID 的冲突错误，不创建第二个 pending task。
- pending 写入失败：不返回 Receipt、不占用执行资源、不开始下载。

### 3.3 状态转换

```text
accepted + pending commit
  → pending
  → running [running commit]
  → readingFixedEntry
  → downloading
  → verifyingArtifact
  → installingRuntime
  → preparingSharedPrefix
  → verifyingRuntimePair
  → completed + runtimePairReady/outcome
```

任何阶段都可以转：

```text
running
  → failed + error
  → cancelled + cleanupVerified
  → failed + recoveryRequired
```

固定 runtime 安装记录、shared prefix 记录和 pair 重读验证属于 `verifyingRuntimePair`/提交阶段，不是下载阶段的附属日志；旧多版本列表不属于当前模型。

### 3.4 失败

| 失败阶段 | Task 终态 | 业务结果 | 恢复动作 |
|---|---|---|---|
| fixed entry/source/asset 403/404/429 | `failed` | 未产生 fixed installed runtime | 恢复网络或等待限流后重试；不改选来源，不产生替代 entry |
| 下载中断或尺寸不符 | `failed` | staged archive 无效 | 删除归档并验证清理 |
| 解压失败 | `failed` | 目标版本未安装 | 删除不完整目录并验证清理 |
| runtime/prefix pair 记录写入失败，artifact 可清理 | `failed` | pair 未提交；artifact discarded | 修复持久化后对固定目标新任务重试 |
| installed record 写入失败，artifact/记录清理不确定 | `failed` + `recoveryRequired` | 版本状态未知，禁止删除/重复下载 | 先扫描、清理或恢复记录并验证 |

没有任何路径把“解压目录存在”直接解释为 `installed`。

### 3.5 取消

- `pending`：若取消提交成功，直接 `cancelled`；无下载副作用。
- metadata/下载：取消传播到内部 Swift Task、URLSession download task 和外层 AsyncSequence；等待它们结束。
- 解压：向解压进程请求终止并等待退出；不能只报告终止请求已发送。
- 取消后删除临时 archive、staged 目录和不完整版本；重读 installed 列表确认目标 tag 未加入。
- 清理确认后才是 `cancelled + cleanupVerified`；任何未确认都为 `failed + recoveryRequired`。

### 3.6 恢复

`recoveryRequired` 记录固定 runtime identity、shared prefix identity、staged 路径、已知清理动作和最近错误。恢复任务先扫描 runtime/prefix 目录和 pair 记录，再删除未提交结果或恢复为一致状态；读回验证完成后清除 recovery record。恢复过程不能偷偷开始新的下载或采用旧 prefix。

### 3.7 重试

`failed + recoveryVerified` 或 `cancelled + cleanupVerified` 才能创建新的固定 setup 意图。`recoveryRequired` 存在时，新的 setup、升级、清理和 pair 记录修改均被拒绝。重试不复用旧 Task ID；同一旧 intent 的重复点击只能得到 deduplicated 结果或明确拒绝。

### 3.8 权限和持久化

- 权限：下载、解压和 staged artifact 只能位于 App Support 管理的 Wine 目录；metadata/asset 必须来自已验证来源。Wine 下载不获得游戏目录 bookmark、系统文件或 helper 权限。
- 持久化：`pending`、`running`、终态 Task、固定 runtime 记录和 shared prefix pair 记录都必须由 PersistenceStore 写入并重读验证；pending 提交失败不启动 setup，任一 pair 记录提交失败不发布 completed。

## 4. P1-REV-002：completed、failed、recoveryRequired 提交语义

### 4.1 输入

Domain 执行器提交终态时必须提供：task ID、目标 ID、业务 outcome、外部副作用摘要、待写入 AppData snapshot、错误/恢复事实和当前 revision。

### 4.2 状态转换

```text
running
  → prepare terminal outcome
  → encode temp
  → decode/validate temp
  → atomic replace AppData
  → re-read and verify
      ├─ verified → completed + committed event
      ├─ target not achieved + cleanup verified → failed + committed event
      └─ side effect/state cannot converge → failed + recoveryRequired
```

### 4.3 三种提交语义

| 事实 | 必要条件 | 允许的事件 |
|---|---|---|
| `completed` | 业务完成门槛、outcome、AppData 写入和重读验证全部通过 | `taskChanged(completed)` + 业务 committed event |
| `failed` | 目标未达成；外部副作用没有残留或已验证清理；失败记录可重读 | `taskChanged(failed)`，附可重试 recovery |
| `recoveryRequired` | 副作用、业务状态或其持久记录无法安全收敛 | `taskChanged(failed)` + `recoveryChanged(recoveryRequired)`；锁定同目标 |

`recoveryRequired` 不得单独作为 completed/failed 的替代状态，也不得被 UI 当成“可立即重试”。

### 4.4 失败和恢复

- 正式文件写入失败时，旧 AppData 保持不变，临时文件不能被读取为正式状态。
- 若外部副作用尚未开始，Task 可失败，业务状态不变。
- 若外部副作用已开始，先清理/回滚；确认后发布 failed，无法确认则 recoveryRequired。
- recovery record 写入也失败时，Domain 保持内存保护和同目标锁，重试 recovery commit；下次启动将已有 pending/running 或未知副作用视为 recovery required，不自动重放。

### 4.5 取消

- 终态提交开始前收到取消：若没有外部副作用，停止提交前的工作并把 Task 记为 `cancelled`；取消记录本身也必须提交并重读验证。
- 原子替换或终态重读已经开始后，不强行打断文件操作；等待提交结果。提交成功则事实已经是 `completed`，不能伪造为 cancelled；提交失败按 failed/recoveryRequired 处理。
- Wine staged artifact 在取消后必须按 P1-REV-001 清理；清理未确认时保持 recoveryRequired。

### 4.6 重试

- `failed` 且恢复已验证：用户可以发起新任务。
- `failed + recoveryRequired`：先执行恢复命令；恢复读回成功后才能创建新任务。
- `completed`：不自动重试；可信负 outcome（如完整性不通过）由用户明确重新发起。

### 4.7 权限和持久化

- 权限：终态提交只通过 PersistenceStore 写入 App Support 允许的 AppData 文件；本契约不授予游戏目录或系统修改权限，staged artifact 的清理仍遵守对应 Domain 的目录权限。
- 持久化：临时编码文件必须先解码校验，正式文件原子替换后重读验证；旧 AppData/备份在写入失败时保留，recovery record 与同目标锁必须作为可恢复事实提交。

## 5. P1-REV-003：进程退出后的状态恢复和重试

### 5.1 输入

`ProcessExitEvent` 必须包含 Process ID、可验证的 Process identity（PID、启动时间、executable/prefix 摘要）、Game ID、launch session/task ID、退出码或信号、`terminationConfirmed`、退出时间、scope lease 状态和当前 Game 状态 revision。

### 5.2 状态转换：正常退出

```text
Running + ProcessExitEvent(normal)
  → target Game state = Installed/UpdateAvailable
  → persist Game + ProcessExitRecoveryRecord(clear)
  → re-read verify
  → committed event
  → release session guard, lifecycle lock, scope and Process reference
```

### 5.3 状态转换：异常退出

```text
Running + ProcessExitEvent(abnormal)
  → target Game state = LaunchFailed
  → persist Game + exit record
  → re-read verify
  → committed event
  → release protection
```

正常/异常的目标状态由退出事实和现有业务规则决定；不得因为“进程已退出”而无条件显示 Installed。

### 5.4 提交失败

- Game 状态提交失败时，不得只写日志、清除当前 Process ID 和释放同目标保护。
- 创建 `ProcessExitRecoveryRecord`，记录期望终态、已确认退出事实、revision 和失败原因；持久化成功后发布 recoveryRequired。
- 保留 `game:<id>:lifecycle` guard，阻止新 GameLaunch；scope 可在 Process 已确认退出且不再需要子进程访问后释放，但 session guard 不能释放。
- 若恢复记录也无法保存，保留内存 termination guard，继续重试持久化；应用重启后，持久 `Running` 且无活动 Process 必须进入 recoveryRequired，而不是自动转 Installed 或重新启动。

重启边界进一步固定为：启动快照发布前必须扫描 `Running`、launch session 和 recovery record；PID 存在不算活动进程，只有 executable、prefix、启动时间和 session identity 全部匹配才可重新接管。无可验证进程时先建立 `restart reconciliation` recovery record 并保留同 Game lock；无已确认退出事实时采用保守 `LaunchFailed(interruptedAfterRestart)`，不推断正常退出。若旧 `Running` 因原子写入失败暂存，必须同时有持久 recovery record；两者都不能写入时进入 AppData recovery guard，下一次启动继续恢复，不能只修改内存投影。

### 5.5 恢复和重试

恢复命令输入为 recovery record ID、Game/session ID 和当前 revision。它只做：

1. 重新确认 Process 不存在或已退出；
2. 幂等提交目标 Game 终态和清除 recovery record；
3. 重读验证；
4. 发布 committed recovery event；
5. 释放 guard。

恢复命令不得创建 Wine prefix、启动 Process 或隐式重试游戏。恢复提交成功后，用户的下一次启动才创建新的 UserIntent/Task。重复退出事件和重复恢复命令按 session/recovery ID 幂等。

### 5.6 取消

- 进程已经退出并进入终态提交/恢复阶段后，恢复命令不可取消；取消请求只记录为待处理，不解除 lifecycle guard。
- 若原始 GameLaunch 在进程仍运行时被取消，先按 GameLaunch 的终止和清理契约处理；收到确认退出后仍必须完成本节的终态提交。
- 恢复提交未完成时，UI 不显示 cancelled，也不能提供新的启动重试；只有恢复事实提交并验证后，用户才能创建新任务。

### 5.7 权限和持久化

- 权限：Process 引用、游戏工作目录和确认阶段的访问 scope 由 LaunchOrchestrator/ProcessManager 持有；游戏目录权限来自 bookmark，不能由退出恢复扩大为系统权限或 helper 权限。
- 持久化：ProcessExitEvent、目标 Game 终态和 termination/recovery record 按同一 session/revision 提交并重读验证；验证成功前不得释放 session guard 和同目标 lifecycle lock。

## 6. P1-REV-004：stale bookmark 统一解析、刷新和持久化

### 6.1 输入

所有需要游戏目录的 Domain 消费者输入 `GameLocation`、操作目的（read/launch/write）、所需 scope（readOnly/readWrite）和 consumer task ID。不得输入裸 path 作为授权凭据。

### 6.2 状态转换与解析流

```text
stored GameLocation
  → resolve withSecurityScope
  ├─ resolution/access failure → accessDenied/resourceUnavailable
  └─ resolved + scope active
       ├─ fresh → optional metadata commit → consumer operation
       └─ stale → recreate bookmark in active scope
                    → candidate refreshed GameLocation
                    → GameRegistry/PersistenceStore commit + re-read
                    ├─ verified → consumer operation
                    └─ failed → stale + recoveryRequired
```

刷新后的 bookmark 必须在当前 scope 内生成，并保留原 scope 类型。`lastKnownPath` 只能辅助显示和诊断，不能替代刷新或授权。

### 6.3 失败

| 阶段 | 结果 | 业务影响 |
|---|---|---|
| resolve 失败 | `failed + accessDenied/resourceUnavailable` | 不读写，不改变 Game |
| startAccessing 失败 | `failed + permission` | 不回退裸 path |
| stale bookmark 重新创建失败 | `failed + bookmarkStale` | 保留旧 bookmark，要求重新选择 |
| refreshed location 持久化失败 | `failed + bookmarkRefreshPersistenceFailed + recoveryRequired` | 不发布本次完整性/版本/启动成功结果 |
| scope 关闭前消费者失败 | 按消费者错误终态 | 刷新若已提交仍保留；业务结果不伪造 |

### 6.4 取消

- 解析、刷新和只读消费者操作可以取消；取消前结束当前 scope 操作。
- stale 刷新候选已生成但未持久化时，取消不得把候选标记为新授权；旧记录保留 stale。
- 启动操作若进程已请求启动，取消沿用 GameLaunch 的清理/退出确认规则；不能用 bookmark lease 取消替代进程清理。

### 6.5 消费者范围

以下路径必须使用同一规则并提交刷新结果：

- `GameRegistry` 定位和刷新状态；
- `FileIntegrityVerifier` 完整性任务；
- `VersionChecker` 版本检测；
- `PreLaunchValidator` 启动前校验；
- `LaunchOrchestrator` 进程启动和确认。

没有消费者可以只拿 `resolvedURL` 后丢弃 `resolvedLocation`。

### 6.6 恢复

bookmark 刷新恢复只允许两条路径：重试持久化当前 scope 内生成的新 bookmark，或用户重新选择目录创建新 bookmark。恢复成功必须重读 `GameLocation`，确认 bookmark 可解析且 scope 类型未改变；恢复失败继续保留 stale/recoveryRequired。

### 6.7 重试

刷新提交失败时，旧任务终态保留失败和 recoveryRequired。恢复成功后，新的 UserIntent/Task 可以重新解析同一 bookmark；若仍 stale 或资源已移动，则要求用户重新选择，创建新的 bookmark 后再重试。不得静默使用旧 path。

### 6.8 输出、权限和持久化

- 输出：消费者得到带 lease 的 `ScopedGameLocationAccess`（resolved URL、当前或 refreshed `GameLocation`、stale 事实和操作 scope）；消费者结果只有在刷新事实提交后才可发布。
- 权限：只能使用请求类型匹配的 security-scoped bookmark；`lastKnownPath` 不能授权，游戏目录 bookmark 不能授权 `/etc/hosts`、hostname 或其他系统资源。
- 持久化：fresh/stale 的 `GameLocation` 通过 PersistenceStore 原子写入并重读验证；刷新提交失败保留旧记录和 recoveryRequired，不把内存候选作为可信授权。

### 6.9 真实刷新/写回验证矩阵

Implementation 必须以可注入的 bookmark resolver、PersistenceStore 写入结果和五个消费者观察点验证以下契约；本矩阵是 Architecture 验收边界，不是 UI 测试替代：

| 场景 | 必须观察到 | 禁止观察到 |
|---|---|---|
| fresh bookmark | 五个消费者均在有效 lease 内完成；`startAccessing/stopAccessing` 成对；不生成刷新写回 | 裸 path 访问或 scope 泄漏 |
| stale + 写回成功 | 读取到新的 bookmark Data；AppData 原子写入并重读成功；重启后解析为 fresh；消费者结果随后发布 | 只更新内存、先发布 `IntegrityPassed/current/Running` |
| stale + 写回失败 | 旧记录仍为 stale；返回 `bookmarkRefreshPersistenceFailed + recoveryRequired`；消费者无可信成功结果；scope 释放 | 回退 `lastKnownPath`、发布业务成功、允许同目标副作用重试 |
| access denied | 不进入消费者操作；保留重新授权/重新选择事实；scope 不泄漏 | 当作文件损坏或使用旧 path |
| 刷新候选产生后取消 | 候选不成为授权事实；旧记录保持 stale；底层访问停止已确认 | 把候选标成 fresh 或报告 clean success |

五个消费者固定为 `GameRegistry`、`FileIntegrityVerifier`、`VersionChecker`、`PreLaunchValidator`、`LaunchOrchestrator`；任一消费者绕过 `ScopedGameLocationAccess` 都视为契约违例。

## 7. Implementation 影响边界

### 必须修改的实现职责

- TaskScheduler：生成和持久化 TaskReceipt、Wine runtime 冲突处理、任务事件和取消传播入口。
- WineVersionManager/Downloader：把下载纳入 executor，桥接外层/内层取消，清理 staged artifact，并将安装记录写入视为终态提交阶段。
- PersistenceStore 调用方：检查终态提交错误，不使用吞错路径发布完成。
- LaunchOrchestrator/GameRegistry：实现 ProcessExitRecoveryRecord、提交失败保护和幂等恢复。
- GameFileSystemRepository 与所有列出的 Domain 消费者：传递并提交 refreshed GameLocation。
- 对应 ViewModel：只消费 TaskReceipt/DomainEvent；不直接消费 Wine 下载 stream，不自行解释 recoveryRequired。

### 不得修改的范围

- Product 功能边界和 Deferred 清单。
- App Sandbox 为只读用户选择文件的权限事实；不通过代码绕过。
- Task 五态集合；`recoveryRequired` 不升级为第六种 Task 状态。
- Wine 启动命令、`WINEPREFIX`、`WINEDLLOVERRIDES` 和 shared prefix lease 规则（当前 prefix 为 `<Application Support>/MiPlay/WinePrefixes/shared`）。
- 不新增通用调度框架、通用 UI 状态系统或未被四个 P1 要求的服务。

## 8. 验证映射

| P1 | 最小验证集合 |
|---|---|
| `P1-REV-001` | Receipt 只有 pending commit 后返回；固定目标 setup 互斥；取消传播到 URLSession/解压/Wine 子进程；shared prefix lease 受保护；清理后 cancelled；清理失败 recoveryRequired；无自动重放 |
| `P1-REV-002` | installed record 写入成功才 completed；写入失败不发 completed；staged artifact 可清理为 failed；清理不确定锁定 recoveryRequired；terminal event 可重读 |
| `P1-REV-003` | 正常/异常退出终态；提交失败保留 guard；恢复命令幂等且不启动；重启时 Running 无进程进入 recoveryRequired；恢复成功后新任务可入队 |
| `P1-REV-004` | fresh/stale/access denied；所有五个消费者提交 refreshed location；刷新持久化失败不发布业务成功；scope 成对释放；重试不回退裸 path |

这些验证项是本阶段 Architecture 契约的闭合条件，不表示真实 Wine、真实用户授权、signed helper 或生产 manifest 已经验证通过。
