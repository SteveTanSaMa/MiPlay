# MiPlay 任务队列模型

> **文档状态**：已冻结（Phase 3；当前修订基线见 `architecture-revision-2026-08-03.md`）
> **更新日期**：2026-08-03
> **目标**：冻结任务输入、输出、进度、取消、错误、权限和恢复契约。

## 1. 任务与用户意图

`UserIntent` 是用户希望达成的目标；`Task` 是调度器接受后对一次执行过程的记录。两者 ID 不相同。一次重试创建新的 intent/task，不覆盖旧失败事实。

### 1.1 Task 输入

入队输入必须包含：

| 字段 | 规则 |
|---|---|
| `intentID` | 用户动作唯一标识 |
| `kind` | 当前版本允许的任务类型 |
| `target` | Game ID、方案 ID、runtime tag 或媒体 Game ID |
| `priority` | `userInitiated`、`userBlocking` 或 `background` |
| `resourceKeys` | 需要锁定的资源，如 `game:<id>`、`systemModification`、`wineRuntime` |
| `cancellationPolicy` | 可取消、产生副作用后清理、不可取消回滚 |
| `context` | 已验证的值，如版本或方案参数；不得放任意 shell 命令 |
| `createdAt` | 提交时间 |

参数无效、目标不存在或同一 intent 重复提交时拒绝入队。仅因资源正在使用而冲突的合法请求保持 `pending`，并显示等待事实。

### 1.1 TaskReceipt

`enqueue` 的成功输出不是裸 `TaskID`，而是 `TaskReceipt`。Receipt 只有在任务的 `pending` 记录已经由 `PersistenceStore` 提交并重读验证后才能返回。

| 字段 | 语义 |
|---|---|
| `taskID` | 本次任务的稳定标识 |
| `intentID` | 对应的用户意图标识 |
| `kind/target` | 被接受的任务类型和目标 |
| `acceptedAt` | 调度器接受时间 |
| `initialStatus` | 固定为 `pending`；不得返回“已开始” |
| `eventCursor` | ViewModel 订阅后续 Task event 的起始序列 |
| `resourceKeys` | 调度器实际登记的资源锁 |
| `cancellationPolicy` | 未开始、产生副作用前、产生副作用后和不可取消阶段的规则 |
| `persistence` | `committed`；不能以 memory-only receipt 作为已接受事实 |
| `deduplicatedTaskID` | 仅重复请求时返回已有任务 ID；不创建第二个任务 |

提交失败时不返回成功 Receipt，也不启动执行。重复意图可以返回指向原任务的 deduplicated Receipt；资源冲突的合法请求按任务类型规则处理，并返回明确的冲突任务 ID。

### 1.2 当前任务类型

| Kind | 作用 | 默认优先级 | 可取消 |
|---|---|---|---|
| `GameLaunch` | 校验、Wine 准备、进程启动和确认 | userBlocking | 前段可取消；有副作用后需清理 |
| `SolutionApply` | 能力检查、快照、修改、验证 | userInitiated | 修改前可取消；修改后转回滚 |
| `SolutionRevert` | 恢复快照并验证 | userBlocking | 不可取消 |
| `IntegrityVerification` | 读取 manifest 并校验 | background 或用户发起 | 可取消 |
| `VersionCheck` | 比较本地和官方版本 | background | 可取消 |
| `WineCatalogQuery` | 查询 Product 批准的托管 Wine 版本目录 | background 或用户发起 | 可取消；不产生安装副作用 |
| `WineAssetDownload` | 已发现 Release asset 的下载、校验、解压和安装记录提交 | userInitiated | 清理确认前可取消 |
| `BackgroundMediaLoad` | 获取和缓存版本背景素材 | background | 可取消 |
| `LogExport` | flush 日志、读取轮转文件、脱敏并生成导出 bundle | userInitiated | 读取/生成阶段可取消；不改变业务状态 |

当前版本不调度 `GameInstall` 或 `GameUpdate`。路径定位是 Domain 命令；MiPlay 不执行完整游戏更新。

## 2. Task 输出

### 2.1 TaskSnapshot

任务快照必须包含：task ID、intent ID、kind、target、status、phase、可选 progress、created/started/ended 时间、outcome、error、recovery、cancellation policy、持久化状态和 revision。

### 2.2 状态集合

只允许五种状态：

| 状态 | 语义 |
|---|---|
| `pending` | 已接受，尚未开始；不能称为正在执行 |
| `running` | 执行器已开始；必须有当前 phase |
| `completed` | 任务达到自身完成门槛或获得可信比较结果；不等于业务成功 |
| `failed` | 目标未达成，或无法获得可信结果；可含 recovery required |
| `cancelled` | 取消已处理，且必要的清理/回滚已验证 |

不提供 `paused`。应用退出、系统休眠或调度器重启不是暂停；活动任务按恢复规则标记中断。

### 2.3 进度

- `phase` 是必填的阶段事实，例如 `validating`、`preparingRuntime`、`startingProcess`、`confirmingProcess`、`restoring`。
- `progress` 为可选值；不可估算时为 nil，UI 使用不定进度。
- 进度必须位于 0 到 1，且不能因为 UI 需要而伪造百分比。
- 进度事件只表达执行事实，不修改业务状态。
- 一个阶段完成不代表整体 outcome 完成；例如下载完成仍需校验和解压。

## 3. 调度策略

### 3.1 两条执行通道

- **Foreground lane**：启动、方案应用/回滚、Wine 下载串行执行，一次一个带外部副作用的任务。
- **Background lane**：完整性、版本和背景素材可并行，但必须先获取资源锁；前台任务获得更高调度优先级。
- 前台任务不会粗暴取消后台任务；若共享资源冲突，后台保持 `pending`，或在其 cancellation policy 允许时由 Domain 主动取消。

### 3.2 资源锁

| 资源锁 | 规则 |
|---|---|
| `game:<id>:lifecycle` | 同一 Game 的启动与定位/完整性互斥 |
| `game:<id>:files` | 同一 Game 的方案文件修改与其他写操作互斥 |
| `systemModification` | 所有 hosts/hostname 修改和恢复全局互斥 |
| `wineRuntime` | 全局互斥；最多一个 `WineAssetDownload` 处于 accepted 的 pending/running；下载、解压、删除和安装记录提交互斥；启动只读已验证 runtime |
| `wineCatalog:<sourceID>:<policyRevision>` | 同一用户选择来源的目录查询去重；API/Release metadata 只读，不占用 `wineRuntime`，不得改变 RuntimeSelection |
| `persistence` | 实际由 PersistenceStore Actor 串行化，不由调度器重复加锁 |

规则：

- `SolutionApply` 获取 `game:<id>:files` 和需要时的 `systemModification`，并阻止同一时刻的相关启动。
- `SolutionRevert` 与 `SolutionApply` 互斥；回滚优先于新的同目标应用。
- `IntegrityVerification` 与同 Game 启动互斥，避免在启动确认期间读到不稳定文件。
- `VersionCheck` 只读，不锁系统修改，但仍需有效路径 scope。
- 第二个 Wine asset 下载请求不得排队等待：同版本返回现有 Receipt，不同版本返回 `conflict(existingTaskID)`；任务完成、失败或取消清理确认前，不能删除/替换其目标版本。
- `WineCatalogQuery` 不与下载争抢 `wineRuntime`；同一 source/policy revision 的重复查询复用已有 Receipt，目录结果必须经过来源身份和持久化验证后才可被 Settings 选择。来源失败不自动创建另一来源任务。

### 3.3 顺序和公平性

同优先级按入队时间先入先出；高优先级任务只能插到尚未开始的低优先级任务前面。正在运行的任务不被抢占。精确重复请求返回现有 Task ID 或拒绝原因，不创建隐形重复任务。

## 4. 任务生命周期

```text
UserIntent
  → rejected
  或 accepted → pending
      → running
          → completed + outcome
          → failed + error/recovery
          → cancelled + cleanupVerified
```

每次状态转换必须发送 Task event。业务状态转换由对应 Domain 服务完成，TaskScheduler 不直接把 Game 改成 `Running`、把方案改成 `Applied` 或把 runtime 改成 `Ready`。

## 5. 取消契约

### 5.1 pending

尚未开始执行的可取消任务可直接标记 `cancelled`，记录取消原因和原业务状态。若用户取消 `SolutionRevert`，返回 `notCancellable`，任务继续。

### 5.2 running 且无副作用

向执行器传播结构化取消信号；执行器确认底层工作停止、临时文件已清理后，Task 才是 `cancelled`。

### 5.3 running 且已有副作用

- `GameLaunch`：终止进程，等待实际退出，确认 prefix/临时资源状态；失败则 recovery required。
- `SolutionApply`：取消转换为 `SolutionRevert` 语义；回滚开始后不可取消。
- `WineAssetDownload`：删除未完成归档和目录，验证没有半成品被列为已安装。
- `BackgroundMediaLoad`：已完成素材可以保留；未完成临时文件必须清理。
- `LogExport`：丢弃未完成导出临时结果；已有日志、任务和业务状态不变。

“已发送取消请求”不是 `cancelled`；只能说明 `cancellationRequested`。

### 5.4 Wine 下载的取消桥接

Wine 下载是一个 Task，不允许由 Settings 或 ViewModel 直接消费独立的下载流。取消传播必须覆盖整条子任务链：

```text
TaskScheduler.cancel(taskID)
  → WineVersionManager cancellation
    → WineAssetDownload child task
      → URLSession download task
  → 等待外层/内层 stream 完成
  → 删除临时归档和未完成版本目录
  → 验证目标版本未进入 installed 列表
  → cancelled + cleanupVerified
```

外层 AsyncSequence 结束、订阅者离开或用户点击取消都必须触发同一取消路径；不能只结束外层 stream。若 URLSession、解压进程或文件清理的停止事实无法确认，Task 为 `failed`，附 `recoveryRequired`，不得报告 `cancelled`。

## 6. 错误契约

每个失败事件都包括目标、阶段、原因类别、副作用、推荐恢复动作和恢复验证状态。至少区分：

- `permissionDenied`、`bookmarkStale`、`recoveryRequired`；
- `networkUnavailable`、`httpRateLimited`、`apiForbidden`、`assetForbidden`、`resourceNotFound`；
- `fileMissing`、`integrityFailed`、`integrityUnsupported`；
- `runtimeUnavailable`、`prefixPreparationFailed`；
- `processStartFailed`、`processTimeout`、`processExitedAbnormally`；
- `persistenceCorrupted`、`migrationFailed`、`writeFailed`；
- `logSanitizationRejected`、`logFlushFailed`、`logExportFailed`；
- `userCancelled`、`notCancellable`、`conflict`。

业务结果和任务失败可同时存在：例如完整性任务 `completed + IntegrityFailed` 是可信负结果，不是执行错误；启动确认超时是 `failed + processTimeout`；取消清理未确认是 `failed + recoveryRequired`，不是 cancelled。

## 7. 权限和任务

- 入队不代表权限已授予。执行阶段必须重新验证 bookmark、scope、helper 批准和 runtime binary。
- GameLocation 使用 security-scoped bookmark；scope 失效时停止当前执行阶段并返回重新授权，不回退到裸路径，也不产生 `paused` Task 状态。
- 当前应用沙盒的用户选择能力为只读；涉及游戏目录写入的任务必须在能力检查阶段返回 `Unavailable`，不尝试通过 Process 或 sudo 绕过。
- hosts/hostname 任务只能通过受限 SystemModificationGateway；helper 未安装或用户拒绝则任务失败，不产生 `Applied`。

## 8. 持久化和崩溃恢复

### 8.1 持久化时机

- 入队后必须保存 `pending` 快照；保存并重读验证成功后才能返回 TaskReceipt。
- 开始执行前必须保存 `running` 和 phase；该提交失败时不得开始任何外部副作用。
- 进度是否落盘由节流策略决定，但最终 phase/outcome/error 必须落盘。
- 业务成功事件在对应 Domain 状态提交后产生；Task `completed` 也必须在业务 outcome 和持久化提交均验证后产生。

### 8.2 终态提交语义

| 终态 | 必须满足 | 不满足时 |
|---|---|---|
| `completed` | 执行门槛、业务 outcome、相关 AppData 写入和重读验证均通过 | 不得发布 completed；进入 failed 或 recoveryRequired |
| `failed` | 目标未达成，且没有未处理的外部副作用；失败记录已提交并可重读 | 若失败记录也无法提交，保留 recoveryRequired 保护 |
| `cancelled` | 取消请求已处理，临时资源/进程/修改已清理并验证；终态已提交 | 清理或提交不确定时为 failed + recoveryRequired |
| `recoveryRequired` | 不是 Task.status，而是持久化/副作用保护事实；必须记录目标、阶段、已知副作用和恢复动作 | 在恢复提交前禁止同目标副作用任务 |

P1-REV-002 的 Wine 特殊规则：下载/解压可以得到 artifact，但只有 `installedWineVersions` 已写入且重读验证后才能为 `completed`。记录提交失败时优先清理 staged artifact；清理确认则为 `failed`，清理不确认则为 `failed + recoveryRequired`。artifact 不得被隐式视为已安装。

### 8.3 WineCatalogQuery 的终态和用户反馈

`WineCatalogQuery` 仍使用五种 Task.status；`catalogLoading`、`availableManagedVersions`、`noAvailableManagedVersion`、`networkFailure`、`sourceConfigurationError` 和 `catalogInvalid` 是 outcome/error 事实，不是新的 Task.status。

- `completed + availableManagedVersions`：来源响应、allowlist/架构匹配、asset identity 和目录缓存写回均已验证；用户可选择托管版本，但不能把目录条目当作 `WineReady`。
- `completed + noAvailableManagedVersion`：来源有效但没有匹配版本；用户看到“没有可用的托管运行环境版本”，不显示空白列表或系统 Wine 替代。
- `failed + networkFailure`：用户当前选择的来源不可达、超时或限流；429 记录 `retryAfter`，用户恢复网络后手动重试或主动改选 allowlist source。
- `failed + apiForbidden/assetForbidden`：当前 source 的 API 或 asset 被拒绝；记录 status 和 source，不请求 token，不自动换源。
- `failed + sourceConfigurationError/catalogInvalid`：来源策略、认证模式、响应 schema 或 asset 身份无法验证；用户只能等待应用更新/修复或主动选择其他预置 source，不可输入任意 token、URL 或镜像。
- `cancelled`：请求已停止且无安装副作用；保留上一条已验证目录和 RuntimeSelection。

### 8.4 LogExport 的终态和用户反馈

`LogExport` 先等待 LogWriter flush barrier，再读取当前日志和轮转文件并生成已脱敏 bundle。无记录是 `completed + empty`；flush、读取、脱敏或目标写入失败为 `failed + logExportFailed`；取消只丢弃导出结果。LogExport 的 completed 不代表任何 Game、Wine 或方案成功，日志失败也不能反向改变其他 Task outcome。

目录查询失败不清除既有可用托管版本，但过期缓存不得直接用于启动或绕过新的内容验证。没有已验证托管版本时保持 `WineNotReady`，不产生任何外部 Wine 替代状态。

### 8.3 非正常退出

启动时扫描 `pending/running`：

- 没有副作用证据：标记 `failed + interrupted`，原业务状态不变。
- 有进程/文件/系统修改可能性：标记 `failed + recoveryRequired`，先做状态探测或恢复，不允许新同目标任务。
- 不自动重新执行启动、方案、系统修改或下载；用户必须触发恢复或重试。

## 9. 重试语义

- 重试永远创建新的 UserIntent/Task，不覆盖原 Task 的 outcome、error 或 recovery 事实。
- `failed` 且 `recoveryVerified`：允许新任务重试；前置条件和权限必须重新验证。
- `failed + recoveryRequired`：先执行对应恢复命令并读回验证；恢复未完成前拒绝新的同目标副作用任务。
- `cancelled + cleanupVerified`：允许新的用户意图；原 Task 保留为 cancelled。
- `completed` 不自动重试；若业务 outcome 是可信负结果（如 `IntegrityFailed`），重试必须由用户明确发起。

## 10. ViewModel 消费规则

- ViewModel 订阅 TaskScheduler 的有序 Task event，不读取队列数组的内部可变引用。
- 当前选中 Game 只过滤展示，不过滤 Domain 执行；后台 Game 的任务仍完整记录。
- 事件序列出现空洞时重新获取 Task snapshot。
- `completed` 到达后必须读取 outcome；没有 outcome 的 completed 视为契约错误，投影为“结果无法确认”。
- 取消按钮由 `cancellationPolicy` 决定；UI 不根据任务类型猜测可取消性。
