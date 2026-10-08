# MiPlay 领域模型

> **文档状态**：活跃（Active）
> **领域阶段**：Domain Model
> **更新日期**：2026-08-27
> **继承自**：UX Information Model、Product Domain

## 1. 领域模型原则

本领域模型描述 MiPlay 的业务实体、它们之间的关系、状态转换规则和生命周期约束。**本模型不定义任何 Swift 代码实现**，而是为 Implementation Agent 提供领域面的契约。

### 1.1 实体与值对象

- **实体（Entity）**：具有唯一标识（ID），且对象意义在其生命周期中持续存在，例如 `Game`、`Task`、`SolutionApplication`。
- **值对象（Value Object）**：没有独立标识，其意义由属性值决定，例如 `GameLocation`、`VersionCode`、`PermissionAccess`。
- **聚合（Aggregate）**：若干领域对象组成的边界，保证所在边界内的状态变更在一个事务里。当前核心聚合有 `GameAggregate`、`RuntimeAggregate`。

### 1.2 不变性约束

- 所有**持久化实体**必须处于 `persisted` 状态后才对外可见。
- 状态为 `recoveryRequired`、`recoveryCommitPending` 等遇到未消除副作用时，不得发布 `running`、`installed`、`WineReady` 等成功事实。
- 任何**不可信数据源**出现冲突，不能覆盖可信数据源。

## 2. 核心领域对象

### 2.1 Game (游戏)

- `gameId`：String，三位固定游戏标识（`genshin`、`hkrpg`、`zzz`）
- `displayName`：String，显示名称（原神、星穹铁道、绝区零）
- `executablePath`：GameLocation，可执行的授权路径（游戏目录）
- `manifest`：IntegrityManifest？可选，游戏完整性清单
- `installationStatus`：GameInstallStatus，安装状态枚举
- `launchStatus`：GameLaunchStatus，启动状态枚举
- `readiness`：RuntimeReadiness，运行环境就绪度

**重要**：一个 Game 实体对应用对应一个可执行的 `Domain service` 与 `GameStateMachine`。

### 2.2 GameLocation (游戏路径授权)

**值对象**，表示用户对游戏目录的选择和授权事实。

- `securityScopedBookmark`：Data，security-scoped resource 的持久化凭据
- `establishedPath`：String，已解析的实际文件系统的绝对路径（仅在当前访问作用域内有效）
- `expirationDate`：Date？可选，用于检查 stale 需要刷新（当前通过 `stopAccessingSecurityScopedResource` 的窗口）
- `lastKnownPath`：String？可选，仅用于错误提示和迁移，不是授权证据。

**安全边界**：任何时候都需要在作用域内 `startAccessingSecurityScopedResource`，工作完成后 `stopAccessing...()`。

### 2.3 Task (任务)

任务表示一次耗时的异步操作的生命周期。它与 `UserIntent` 关联但并不等同。

- `taskId`：UUID
- `userIntentId`：UUID? 可选，用户发起意图的引用
- `kind`：TaskKind，任务类型（`GameLaunch`, `IntegrityVerification`, `VersionCheck`, `SolutionApply`, `SolutionRevert`, `WineRuntimeSetup` 等）
- `projectId`：String? 可选，标识相关的项目或游戏
- `status`：TaskStatus（`pending`, `running`, `completed`, `failed`, `cancelled`）
- `phase`：String, 当前执行阶段（如“检查游戏文件”、“下载 runtime”、“应用方案”、“安装 wine”等）
- `progress`：TaskProgress？可选，如果有确定数值
- `startedAt`：Date?，实际开始时间
- `endedAt`：Date?，实际结束时间（仅当 `completed/failed/cancelled`）
- `outcome`：TaskOutcome? 任务产生的业务结果（需要与 `status` 分开读取）
- `error`：TaskError? 失败原因和面向用户的解释
- `recovery`：TaskRecovery? 当前推荐动作、可重试条件和是否已验证

**Task 状态语义**：
- `pending`：已接受请求但尚未开始执行。不得使用“正在应用”“已启动”或“已完成”。
- `running`：已开始执行，必须能说明正在处理的阶段。
- `completed`：任务达到定义的成功门槛，或对“校验/比较”任务已经获得可信结果；业务结果仍需单独读取。
- `failed`：请求目标未达成，或无法获得可信结果。不得把目标对象提升为成功状态。
- `cancelled`：取消请求已处理，且需要的清理或回滚已验证；未验证时使用 `failed`。

### 2.4 LaunchOutcome (启动结果)

游戏启动任务的结果，不把进程创建当作成功。

**可能的值**：
- `runningConfirmed`：进程存在且达到可运行判定，“游戏已启动”
- `preflightRejected`：文件、权限、完整性或环境前置不满足，“启动尚未执行”
- `runtimePreparationFailed`：运行环境获取或准备失败，“游戏未启动”
- `processStartFailed`：未创建可运行进程，“启动失败”
- `processTimeout`：在确认期限内未确认进程，“启动超时，清理状态待确认”
- `processExitedAbnormally`：进程异常退出，“游戏因异常退出结束”
- `cancelledCleanly`：取消后无残留且清理验证通过，“启动已取消”

**注意**：此结果与 `GameLaunch` task 同时存在，`task.status` 为 `completed`，但 `outcome` 可能是不同的失败事实。

### 2.5 PermissionAccess (权限访问事实)

描述 MiPlay 对用户选择路径或系统资源的访问事实。

- `granted`：当前任务可以读取/修改声明的资源
- `expired`：曾经允许，但当前授权不能继续使用
- `denied`：用户或系统拒绝访问
- `unavailable`：目标资源或授权能力不存在
- `verifiedAfterReauthorization`：重新授权后实际读写验证通过

### 2.6 IntegrityCheckResult (完整性校验结果)

- `IntegrityPassed`：非空、版本对应 manifest，全部条目通过
- `IntegrityFailed`：有效 manifest 中出现缺失或内容不匹配
- `IntegrityUnsupported`：manifest 缺失、为空、版本不对应或无法验证
- `executionFailed`：路径权限、I/O 或读取错误阻止校验
- `cancelled`：用户在完成前取消

### 2.7 VersionCheckResult (版本检测结果)

- `current`：本地和官方版本均获得且相等
- `updateAvailable`：本地和官方版本均获得且不同
- `unknown`：没有足够数据判断
- `failed`：网络、官方服务、本地文件或解析失败

### 2.8 SolutionApplication (方案应用)

描述一次兼容方案应用的生命周期。

状态：
- `Unavailable`：资源、适用范围或权限能力不满足
- `Applying`：已确认，正在快照、修改或验证
- `Applied`：修改、后置验证、记录保存和恢复快照均满足
- `Failed`：执行/验证失败，或回滚未确认
- `RolledBack`：恢复到应用前状态且读回一致

**核心规则**：`Applied` 不表示游戏已启动；`RolledBack` 不表示应用成功；备份成功不改变上述状态。

### 2.9 RuntimeReadiness (运行环境就绪度)

面向用户使用“运行环境”，技术细节可进入日志。当前唯一 runtime 是 `wine-crossover-11.0-1-signed`，三款游戏共用同一个 MiPlay 管理的 prefix。

#### 2.9.1 BackgroundGroupSelectionState（背景组选择状态）

记录用户背景预览的临时事实，不影响持久化选择。

状态：
- `idle`：无 hover 任何候选组
- `dotsHidden`：顶部区域无指针，圆点隐藏
- `dotsVisible`：指针进入顶部区域，候选圆点可见
- `hoverPreview(groupID)`：hover 候选组
- `previewLoading(groupID)`：未缓存且允许加载
- `previewFailed(groupID)`：预览加载失败
- `selected(groupID)`：用户明确提交且资源验证、选择写回、重读通过

**重要**：`hoverPreview`、`previewLoading` 和 `previewFailed` 不得改变 `selectedBackgroundGroupID`，不得写持久化，不得删除任何背景缓存。只有 `selected(groupID)` 是持久化选中终态。

#### 2.9.2 ManagedWineState（托管 Wine 状态）

固定 runtime 的安装事实与共享 prefix 的运行事实是两个独立状态对象。

**固定 runtime 安装事实**：
- `NoManagedRuntime`：固定 runtime 未形成可复核安装事实
- `Downloading`：固定 Release 正在获取
- `ArtifactReady`：固定 Release 已完整获取并通过校验
- `Installing`：托管安装、executable 验证或提交正在进行
- `Installed`：安装提交、身份复核和持久化重读均通过
- `InstallFailed`：安装身份、提交、重读或清理失败
- `RuntimeUnavailable`：固定资源、批准来源、架构或托管事实无法确认
- `RecoveryRequired`：产生副作用但清理/恢复尚未确认

**共享 prefix 事实**：
- `PrefixUnset`：固定 runtime 已安装但唯一 prefix 尚未初始化
- `PrefixPreparing`：初始化、更新或验证正在进行
- `PrefixReady`：唯一 prefix 的身份、内容和准备结果均通过
- `PrefixNotReady`：初始化、更新或验证失败
- `RecoveryRequired`：prefix 副作用或状态无法确认

**prefixOccupancy**：独立保护事实：`free`、`busy` 或 `unknown`。`busy` 表示等待当前 Wine 使用结束。

**目标游戏 readiness**：
- `WineReady`：固定 runtime 已安装、共享 prefix 已就绪、目标游戏路径/manifest/启动前置通过
- `RuntimeNotReady`：固定 runtime 或共享 prefix 未通过门槛
- `GamePreflightFailed`：runtime/prefix 已就绪，但目标游戏自身路径、manifest、兼容方案或启动前置失败
- `RecoveryRequired`：共享 runtime/prefix 的恢复未确认

**注意**：`WineReady` 不是"Wine 已安装"的别名。共享 prefix 已就绪后，三款游戏仍须分别取得自己的游戏 readiness。

#### 2.9.3 DeviceInfo（设备信息）

- 机型、芯片、内存、macOS 版本（主层级字段）
- model identifier、build number（详情字段）
- Wine 目标卷空间（独立只读行）

字段状态：
- `fieldConfirmed`：字段为系统报告值
- `fieldUnknown`：系统报告未提供
- `fieldFailed`：无法读取字段
- `fieldStale`：显示上一次已确认值
- `diskSpaceUnavailable`：无法读取 Wine 目标卷空间

### 2.10 AppDataRecovery（应用数据恢复）

描述应用数据恢复过程的结果。

状态：
- `readable`：应用数据可读取
- `backupCreated`：原始数据已保护
- `restoreAvailable`：找到可读备份
- `restoredAndVerified`：备份恢复后重新读取通过
- `migrationRequired`：旧格式可读但需迁移
- `migratedAndVerified`：迁移后重新读取和结构校验通过
- `recoveryFailed`：恢复/迁移后仍无法验证
- `freshStartConfirmed`：用户明确放弃不可恢复数据并确认重新开始

### 2.11 ErrorRecord（错误记录）

每条 P0/P1 错误至少应表达以下信息：

- 目标：哪款游戏、哪项方案、哪个路径或哪份数据
- 阶段：排队、校验、授权、执行、进程确认、后置验证或恢复
- 原因类别：网络、权限、文件、manifest、运行环境、进程、数据或用户取消
- 副作用事实：是否已写入、是否创建进程、是否有残留或是否未改变目标
- 当前结果：业务结果和任务状态
- 恢复动作：唯一推荐的下一步及前置条件
- 验证事实：恢复/清理是否已读回确认

### 2.12 ManagedWineAcquisitionResult（托管 Wine 获取结果）

固定 runtime 的资源检查是对一个产品固定目标的获取结果。

状态：
- `checking`：正在检查固定 Release 资源
- `artifactAvailable`：固定身份、批准来源、架构和资源映射可验证
- `artifactUnavailable`：固定资源暂时不可达、服务失败或资源不存在
- `artifactInvalid`：资源身份、重定向、格式或校验不匹配
- `artifactDownloaded`：固定资源完整获取并通过内容校验
- `installationVerified`：托管安装、executable 身份、持久化提交和重读均通过
- `prefixVerified`：唯一共享 prefix 初始化和验证通过
- `recoveryRequired`：清理、安装或 prefix 状态无法确认

### 2.13 LocalGameEvidence（本地游戏证据）

- `pkg_version`：经格式、目标游戏、安装位置和版本语义验证后的本地版本候选
- `config.ini`：经格式验证的渠道/来源/配置元数据候选
- `IntegrityManifest`：游戏身份、客户端版本、必需条目和内容校验依据
- 官方远程版本：官方最新版本候选

**组合结果**：
- 本地版本可验证 + 远程版本可验证 → `VersionCheck completed + current/updateAvailable`
- manifest 可验证且全条目通过 → `IntegrityPassed`
- 任一来源缺失或无法解析 → `VersionCheck failed` 或 `IntegrityUnsupported`
- 来源之间冲突 → 不得发布 `current`、`IntegrityPassed` 或 `Running`

### 2.14 LocationRecoveryFact（路径恢复事实）

- `locationFresh`：游戏路径授权有效
- `locationStaleRefreshing`：正在刷新游戏路径授权
- `locationRefreshCommitted`：游戏路径授权已刷新并保存
- `locationRefreshPersistenceFailed`：路径授权已刷新但尚未保存，本次操作未完成
- `locationAccessDenied`：无法访问所选游戏路径
- `recoveryRequired`：路径授权恢复未完成，暂时不能继续

### 2.15 RestartRecoveryFact（重启恢复事实）

- `persistedRunningNoProcess`：重启发现 Game 持久 `Running`，但无可信活动进程
- `recoveryCommitPending`：退出事实已知但目标终态尚未提交
- `recoveryCommitted`：进程退出确认、目标终态和记录均重读通过
- `recoveryPersistenceFailed`：AppData 和恢复记录都无法提交

### 2.16 AccessibilityProjection（辅助功能投影）

从 Domain/ViewModel 状态生成的语义对象，不是视觉层推断结果。

- `role`：button、progressIndicator、status、group 或其他标准角色
- `label`：稳定的对象和动作
- `value`：选中态、业务状态、任务状态、阶段、真实进度或“进度未知”
- `hint`：激活后的结果或当前可执行动作
- `enabled`：当前动作是否可执行
- `busy`：是否仍在查询、执行、验证或恢复
- `recoveryAction`：当前唯一适合的恢复动作及前置条件
- `announcement`：状态从 pending/running 到可信终态时的完整事实

## 3. 领域关系图

```
┌─────────────────────────────────────────────────────────────┐
│                        GameAggregate                         │
│  gameId, displayName, installStatus, launchStatus, readiness│
│  + GameLocation (value object)                               │
│  + IntegrityManifest (value object)?                        │
└─────────────────────────────────────────────────────────────┘
                           ↕ composed
┌─────────────────────────────────────────────────────────────┐
│                       RuntimeAggregate                       │
│  ManagedWineState + PrefixState + ReadinessGen                │
└─────────────────────────────────────────────────────────────┘
                           ↕ associated
┌─────────────────────────────────────────────────────────────┐
│                          Task                                 │
│  taskId, kind, status, phase, progress, outcome, error        │
└─────────────────────────────────────────────────────────────┘

关联：
- Game 可以有多个 Task 生命周期的记录
- Game 有一个当前的 RuntimeReadiness
- Task 有一个 consider ability 的结果事实 LaunchOutcome / IntegrityCheckResult 等
- 某些专用事实如 LocationRecoveryFact、RestartRecoveryFact、SolutionApplication 与特定 Task 或 Game 紧密相关
```

## 4. 聚合边界与不变性

### 4.1 GameAggregate (游戏聚合)

**根实体**：`Game`

**边界内对象**：
- `GameLocation`
- `CurrentReadiness` (RuntimeReadiness)
- `LaunchOutcome` (最近启动的结果)
- `SolutionApplication` (最近一次方案应用)
- `IntegrityCheckResult` (最近一次完整性校验)

**不变性约束**：
- 一个 `Game` 在同一时间只能有一个“未清除副作用”的任务状态（例如 `recoveryRequired`）
- `launchStatus` 不能直接跳转到 `Running`，必须经过 `launchOutcome.runningConfirmed`
- 游戏路径（`GameLocation`）失效应阻止 `installed` 和 `launchable` 状态

### 4.2 RuntimeAggregate (运行环境聚合)

**根实体**：`ManagedWineState`（包含安装事实与共享 prefix）

**边界内对象**：
- `RunningEnvironmentState`（安装事实）
- `SharedPrefixState`（共享 prefix 状态）
- `GameReadiness`（每个 Game 的 readiness）
- `BackgroundGroupSelection`（当前选中的背景组）

**不变性约束**：
- `WineReady` 必须同时满足：`Runtime.installed == true` 且 `PrefixState.ready == true` 且 `GamePreflightPassed`
- 任何 `RecoveryRequired` 状态会阻止发布任何成功事实

## 5. 领域服务职责

### 5.1 GameRegistry（游戏注册中心）

- 维护三款固定 Game 实体
- 管理 GameLocation 的持久化和 scoped 访问
- 提供只读的 read-only snapshot 给其他服务

### 5.2 GameStateMachine（游戏状态机）

- 定义 `GameInstallStatus` 和 `GameLaunchStatus` 及合法转换
- 校验从 Infrastructure 返回的结果是否符合转换规则
- 发送领域事件通知状态变更

### 5.3 LaunchOrchestrator（启动编排器）

- 协调 PreLaunchValidator、ProcessManager、WineRuntimeProvider
- 记录 `LaunchOutcome`
- 处理启动失败后的恢复（clean up，recovery）

### 5.4 SolutionEngine（方案引擎）

- 检查方案能力（Resource、权限、适用范围）
- 执行方案应用流程（snapshot → modify → verify → commit）
- 处理失败回滚（不可取消）

### 5.5 TaskScheduler（任务调度器）

- 接收任务请求
- 管理任务排队、互斥执行
- 跟踪任务状态、进度、取消
- 发布任务事件

## 6. 领域事件流

### 6.1 启动事件流

```
UserIntent → Task created (pending)
TaskScheduler: assigned → running → phase update
LaunchOrchestrator: prepares runtime, calls ProcessManager
ProcessManager: start process → running process
LaunchOrchestrator: confirm process within TTL
GameStateMachine: transition to Running
TaskScheduler: completed + outcome.runningConfirmed
AccessibilityProjection: announce success
```

### 6.2 启动失败事件流

```
Task created (pending) → running
LaunchOrchestrator: preflight fails
GameStateMachine: keeps original status (no change)
TaskScheduler: failed + error details
AccessibilityProjection: error + recovery action
```

### 6.3 方案应用事件流

```
UserIntent → Task created (Applying)
SolutionEngine: check capability
SolutionEngine: apply (snapshot then modify)
SolutionEngine: verify
Server: commit
GameStateMachine: update SolutionApplication.AnApplied
TaskScheduler: completed + outcome.Applied
```

## 7. 错误传播模型

**Infrastructure Level**：返回 error enum，例如 `IOError.FileNotFound`。

**Domain Level**：将 Infrastructure error 封装为领域 error，例如 `LaunchFailed(reason: .runtimeNotReady)`。

**ViewModel Level**：保持错误模型不变，只改变用户文案。

**UI Level**：展示错误事实 + 恢复动作，不猜测错误原因。

**恢复流**：状态 `recoveryRequired` → 执行恢复 → 恢复验证 → 重回正常状态或 `failed`。

## 8. 数据持久化契约

### 8.1 持久化的字段

- Game 的基本信息（displayName、gameId）
- GameLocation（bookmark）
- RuntimeReadiness 的持久化事实
- 方案应用记录（Applied time, state）
- 版本检测结果（缓存）
- 设备信息（只读）
- 通用的 AppData 配置

### 8.2 不持久化的临时状态

- `SymbolContext.Session`（调试）
- `BackgroundGroupSelectionState` 的 `hoverPreview` / `previewLoading` 等临时状态
- 任务的 `phase`、`progress`（可重新计算或从事件重放）
- `recoveryRequired` 等保护性状态仅在内存+持久化表中短暂存在

## 9. 约束与边界

- 当前版本只管理三款固定游戏，不新增游戏类型的动态扩展
- Wine 只有固定版本和共享 prefix，不允许用户选择
- 不包含游戏安装、完整更新、任意参数修改、帧率解锁
- `GameInstall`、`GameUpdate` 不是当前版本的调度任务

## 10. 与 UI 的关系

- ViewModel 通过 `Game`、`Task`、`RuntimeReadiness`、`SolutionApplication` 等对象构建投影
- UI 不创造状态，只从这些领域对象中读取事实
- Accessibility Projection 从领域对象生成，不直接访问 UI 元素

---

> **注意**：领域模型是静态的结构描述，具体状态转换规则和事务语义见 `architecture-state-ownership.md` 与 `architecture-communication.md`。

