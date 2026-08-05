# MiPlay 领域模型

> **文档状态**：已冻结（Phase 3；当前修订基线见 `architecture-revision-2026-08-03.md`）
> **更新日期**：2026-08-03
> **原则**：领域对象表达业务事实；任务、权限、执行过程和持久化恢复不能互相冒充。

## 1. 聚合边界

```text
GameLibrary
├── Game × 3
│   ├── GameLocation
│   ├── GameMetadata
│   ├── PerGameSettings
│   ├── BackgroundGroup selection
│   ├── IntegrityCheckResult
│   └── SolutionApplication × N
└── Game business state

RuntimeCatalog
├── ManagedWineRuntime × N
├── RuntimeSourcePolicy / RuntimeSourceResult
└── selected managed runtime / source selection

TaskCatalog
└── Task × N

AppDataRecovery
└── schema, settings, bookmark records, task recovery metadata
```

- `GameRegistry` 是 GameLibrary 的唯一业务状态所有者。
- `WineVersionManager` 是 RuntimeCatalog 的唯一决策者。
- `TaskScheduler` 是 TaskCatalog 的唯一状态所有者。
- `PersistenceStore` 只拥有持久化字节，不拥有上述业务状态；Domain 在读取后验证并恢复聚合。
- 聚合之间通过稳定 ID 和不可变值关联，不持有对方的可变对象引用。

## 2. Game

### 2.1 身份和属性

三款固定 Game 的稳定 ID 为 `GenshinImpact`、`HonkaiStarRail`、`ZenlessZoneZero`。Game 的业务字段如下：

| 字段 | 语义 | 持久化 |
|---|---|---|
| `id/type` | 唯一游戏身份和固定游戏类型 | 是 |
| `location` | bookmark 授权、最后已知路径和授权状态 | 是；bookmark 为权威 |
| `businessState` | `PathUnset`、`NotInstalled`、`Installed`、`UpdateAvailable`、`Launching`、`Running`、`LaunchFailed` | 是；`Launching/Running` 重启时不直接恢复 |
| `version` | 已验证的本地客户端版本 | 是 |
| `lastIntegrity` | 最近一次完整性事实及时间 | 是 |
| `lastLaunchDate` | 最近一次被确认启动的时间 | 是 |
| `solutionApplications` | 方案应用记录 ID 和状态 | 是 |

`Game` 不保存任务的 `pending/running` 作为自身状态。启动任务正在排队只表示 Task 状态，不能把 Game 提前改为 `Launching`；进入启动执行阶段后才允许转换为 `Launching`。

### 2.2 业务状态不变量

- 没有可用 `GameLocation` 时只能是 `PathUnset` 或 `NotInstalled`，不能是 `Installed`、`Launching` 或 `Running`。
- `Installed` 至少需要路径可访问和启动前已知前提满足；完整性 `Unsupported` 不可伪装成 `IntegrityPassed`。
- `Launching` 只由已开始执行的 `GameLaunch` 任务进入。
- `Running` 只由进程确认事件进入；创建 `Process` 或 `wine` 返回不够。
- 正常退出回到重新评估后的 `Installed`/`UpdateAvailable`；异常退出进入 `LaunchFailed`，除非后置检查得出其他可信结果。
- 启动前失败不提升 Game；它只保存失败事实和恢复动作。

### 2.3 GameMetadata

`GameMetadata` 归属单一 Game ID，是 scoped 读取后的不可变 evidence snapshot，而不是一个可自由填写的版本对象。它保存 location revision、读取时间、原始 `config.ini` section/key/value、`pkg_version` JSON Lines 条目、关联 manifest/远程版本证据、解析状态和冲突原因。

- `config.ini` 只保留原始字段和值；不得推断 `channel`、`cps` 或 `sub_channel` 的友好含义。
- `pkg_version` 只保留 `remoteName/fileSize/md5` 和解析状态；不单独产生完整性或官方版本结论。
- 非空且与 Game/client version 对应的 manifest 是 `IntegrityPassed` 的必要门槛。
- 未知字段、`wpf_version`、单独的 `game_version` 或空 manifest 不产生可信事实；冲突时保留上一可信结果并记录 `versionEvidenceConflict`。

### 2.4 PerGameSettings 与 BackgroundGroup

`PerGameSettings` 按 Game ID 保存 metadata 展示状态、性能/兼容入口状态、当前背景组 ID 和失败/恢复事实引用。全局 Wine source selection 不得写入此记录。读取、保存、取消和失败均保留上一已提交值，不能用默认值覆盖旧事实。

`BackgroundGroup` 绑定 Game ID、组 ID、版本、source identity、图片/视频/theme/装饰资源身份、资源验证和缓存状态。目标组加载或选择提交失败时保留上一有效组，不静默切到其他组；背景结果不改变 Game 的安装、完整性、运行或启动状态。单组不形成无意义的选择状态。

## 3. GameLocation 与 security-scoped bookmark

### 3.1 持久化记录

每款游戏最多一个当前定位记录。记录包含：

| 字段 | 规则 |
|---|---|
| `gameID` | 关联固定 Game |
| `bookmarkData` | 使用读写 scope 创建时的 bookmark `Data`；JSON 编码为标准 Codable 数据表示 |
| `lastKnownPath` | 最近一次解析出的路径，仅用于显示、诊断和迁移，不可单独授权 |
| `scope` | `readOnly` 或 `readWrite`，反映实际创建的授权范围 |
| `resolutionState` | `missing`、`resolvable`、`stale`、`accessDenied`、`resourceUnavailable`、`migrationRequired` |
| `lastResolvedAt` | 最近一次解析时间 |
| `bookmarkVersion` | 记录格式版本，不等同于 AppData schema 版本 |

裸 `installPath` 只存在于旧 schema 迁移输入中。新 schema 不把它作为可用 GameLocation。

### 3.2 生命周期

```text
用户选择目录
  → 创建 bookmark
  → 原子保存 bookmark + lastKnownPath
  → 解析并 startAccessing
  → 在 scope 内验证目录和可执行文件
  → 产生路径/完整性业务结果
  → stopAccessing
```

- 解析返回 stale 时，可以在有效 scope 内完成内部读取以判断是否需要恢复，但必须在本次作用域结束前重新创建并持久化 bookmark；刷新提交未验证前，不得发布新的完整性、版本或启动成功结果。
- 解析失败、用户撤销权限、卷不可用或目录被删除均保留最近路径用于提示，但不允许文件操作。
- scope 只覆盖当前异步操作。不得在 App 启动时无限期保持访问，也不得把 path 字符串传给下游替代 scope。
- 方案涉及游戏目录读写时，快照、修改、验证和回滚必须在同一个有效读写 scope 内完成。

### 3.3 旧 path 迁移

旧数据被视为 schema 1：`Game.installPath` 是裸路径，没有可验证的持久授权。

1. 读取旧数据后创建 `.bak`，不覆盖原文件。
2. 将每个裸路径转换为 `migrationRequired` 记录，并保留 `lastKnownPath`；不自动生成 bookmark，不把文件存在当成授权。
3. UI 要求用户重新选择对应目录。用户选择成功后创建 bookmark，在 scope 内确认游戏可识别，再原子写入 schema 2。
4. 新数据重新读取并验证通过后，才移除旧 `installPath` 的业务作用；原始备份保留到下一次成功写入策略定义的轮换点。
5. 任一迁移失败都保留旧文件和备份，Game 不变为已接入；用户可以重试、选择其他备份或明确重新开始。

### 3.4 消费者统一提交

解析结果不是只读 URL，而是一次 `ScopedGameLocationAccess`：包含解析 URL、更新后的 `GameLocation`、是否检测到 stale、scope lease 和刷新提交状态。定位、完整性、版本检查、启动前校验和启动编排都必须消费这一结果。

- stale bookmark 在有效 scope 内重新创建 bookmark，并把新 Data 作为候选 location。
- `GameRegistry` 在消费者发布自己的业务结果前提交候选 location；写入和重读成功后，候选 location 才成为新的持久授权事实。
- 刷新提交失败时，旧 location 保留为 `stale`，附加 `recoveryRequired` 记录；本次消费者结果不得升级为 completed、IntegrityPassed、current/updateAvailable、Installed 或 Running。
- 重试是新的 UserIntent/Task。若反复无法刷新，恢复动作是重新选择目录，不允许回退到 `lastKnownPath`。

## 4. WineRuntime 与启动命令

### 4.1 RuntimeCatalog

`ManagedWineRuntime` 记录版本 ID、来源身份、归档校验事实、安装目录、`bin/wine` 可用性和就绪状态。当前版本只有 MiPlay 托管副本可以进入 RuntimeCatalog 的可用集合。

`RuntimeSourcePolicy` 记录 Product allowlist、目标架构、来源身份、API/Release metadata/asset URL 规则、版本/asset 身份和认证模式。官方 GitHub 是默认 source；用户可以主动选择 allowlist 中的预置镜像。来源失败不自动切换，用户 URL、token 和未知 redirect 不进入策略。

`RuntimeSourceResult` 是版本目录查询结果，不是 Task.status 或 `WineReady`：

- `availableManagedVersions`：目录、allowlist、架构和 asset 身份均验证通过；
- `noAvailableManagedVersion`：来源响应有效但没有匹配版本；
- `networkFailure`：当前用户选择的来源不可达、超时或限流；
- `sourceConfigurationError`：allowlist、URL、认证策略或镜像配置无效；
- `catalogInvalid`：响应格式、来源身份或资源映射无法验证；
- `sourceForbidden`：API 或 asset 被当前来源拒绝，记录 source/status，不产生可用 runtime。

生效路径决策固定为：

1. 用户选中的、由 MiPlay 托管且校验通过的版本存在，并且 `bin/wine` 可执行；
2. 否则为 `WineNotReady`；不得使用系统 Wine、Whisky、CrossOver 或任意用户路径回退。

`WineVersionManager` 负责 source selection、API/Release metadata 目录、独立 asset 下载、托管版本选择和就绪判定；`WineRuntimeProvider` 只执行给定的托管路径，不能自行扫描或覆盖选择。

### 4.2 LaunchCommand

`LaunchCommand` 是一次启动前的不可变值，必须包含：

| 字段 | 冻结规则 |
|---|---|
| `wineBinary` | 已验证的绝对 Wine binary 路径 |
| `gameExecutable` | 已解析的绝对 Windows exe 路径，作为 Wine 参数第一项 |
| `arguments` | 固定游戏参数和已启用性能选项产生的数组；不经过 shell 拼接 |
| `workingDirectory` | 游戏目录的解析 URL/path，scope 由调用方持有 |
| `environment` | 受控基础环境 + `WINEPREFIX` + 固定 DLL override + 允许的性能环境变量 |
| `prefix` | `Application Support/MiPlay/WinePrefixes/<stableGameID>` |
| `confirmationDeadline` | 由启动服务设定的确认期限，超时必须进入清理/失败流程 |

冻结环境键：

```text
WINEPREFIX=<MiPlay Application Support>/WinePrefixes/<stableGameID>
WINEDLLOVERRIDES=winemenubuilder.exe=d
```

游戏进程的可执行文件不是 `Process.executableURL`；`Process` 执行的是 `wineBinary`，参数为 `[gameExecutable] + arguments`。prefix 准备使用同一 Wine binary 和 `WINEPREFIX`，以 `wineboot -u` 完成并验证 `drive_c` 存在。

## 5. CompatibilitySolution 与 SolutionApplication

### 5.1 发布清单

当前版本只有 `modify_hostname`（CS-01）进入条件能力检查。hosts 屏蔽（A-06/CS-02）、旧版反作弊替换（A-03/CS-03）和 Steam 白名单（A-02/CS-04）本轮 Deferred；`use_legacy_patch`（CS-05）为 Out of Scope。Deferred/Out of Scope 不得显示可应用、入队或进入 `Applied`。

### 5.2 应用记录

每次应用记录至少包含方案 ID、Game ID、应用前快照、目标资源、执行阶段、后置验证、回滚状态和时间。

状态规则：

```text
Unavailable
  → Applying
      → Applied                 （修改、验证、记录保存、可恢复快照均确认）
      → Failed + RolledBack     （失败且恢复读回一致）
      → Failed + RecoveryUnknown（失败且恢复未确认）
```

`Applied` 不表示游戏启动；备份成功、命令返回或任务 `completed` 都不能单独产生 `Applied`。修改开始后用户取消必须转入不可取消的恢复流程。

## 6. IntegrityCheckResult

完整性结果由有效 manifest、游戏版本和 scoped 文件读取共同决定：

| 结果 | 进入条件 | 是否允许提升 Game |
|---|---|---|
| `IntegrityPassed` | manifest 非空、版本对应、全部条目通过 | 允许作为启动前提 |
| `IntegrityFailed` | 有效 manifest 中有缺失/不匹配 | 不允许 |
| `IntegrityUnsupported` | manifest 缺失、为空、版本不对应或无法确认 | 不允许 |
| `ExecutionFailed` | 授权/I/O/读取阻止结论 | 不改变既有可信结果 |
| `Cancelled` | 用户取消且没有新结论 | 保留上一次可信结果 |

完整性校验本身不修改游戏文件，不需要兼容方案式回滚。

## 7. Task 与 UserIntent

`UserIntent` 表示用户提出的目标；`Task` 表示调度器接受并执行的过程。一个意图可以因冲突或权限失败没有产生成功结果，但不能把意图当作业务事实。

Task 必须记录 task ID、intent ID、kind、Game/方案目标、优先级、创建/开始/结束时间、状态、阶段、可选进度、独立 outcome、错误、恢复动作、取消策略和持久化 revision。

`TaskReceipt` 是任务被持久接受的证明，包含 task ID、intent ID、target、`pending`、事件 cursor、资源锁、取消策略和 `persistence=committed`。pending 持久化失败时不返回 Receipt，也不开始执行。

当前任务类型为 `GameLaunch`、`SolutionApply`、`SolutionRevert`、`IntegrityVerification`、`VersionCheck`、`WineCatalogQuery`、`WineAssetDownload`、`BackgroundMediaLoad`、`LogExport`。API/Release metadata discovery 属于 `WineCatalogQuery`，asset bytes 属于 `WineAssetDownload`。`LogExport` 只生成已脱敏诊断 bundle，不产生任何 Game/Wine/solution 业务状态。路径定位不是独立业务成功状态；它由域命令记录授权和完整性事实，并可触发 `IntegrityVerification`。

## 7.2 LocalGameEvidence

`LocalGameEvidence` 是一次有效 scoped access 内对本地元数据的不可变读取结果，不是 Game 业务状态。它必须带 Game ID、location revision、读取时间、解析状态和来源摘要。

| 证据 | 领域字段 | 允许表达 | 禁止表达 |
|---|---|---|---|
| `pkg_version` | JSON Lines 条目：`remoteName`、`fileSize`、`md5`；非空/格式/映射结果 | 在目标 Game、安装位置和版本映射均验证后，作为文件条目和可选本地版本候选 | 单独证明完整性、官方最新版本或渠道 |
| `config.ini` | `[General]` 的 `game_version`、`channel`、`sub_channel`、`cps`、可选 `sdk_version` | 本地版本候选、渠道/来源证据 | 单独证明文件完整性、官方最新版本或可启动 |
| `IntegrityManifest` | Game、客户端版本、必需文件及字段声明的摘要 | 完整性校验的权威依据 | 官方服务器当前最新版本 |

`pkg_version` 的文件摘要算法按条目声明和既有事实使用文件大小 + MD5；不能把其他任务的 SHA-256/xxhash 代入。`config.ini` 的 `wpf_version` 没有当前批准语义，不读取为业务事实，也不生成该字段。

版本关联规则：先分别解析和记录来源，再用 Game ID、location revision、支持的渠道/版本映射和 manifest 进行关联。`config.ini.game_version`、可映射的 `pkg_version.remoteName`、manifest 版本和官方远程版本必须一致或满足明确的兼容规则；冲突时输出 `versionEvidenceConflict`，不得发布 `current`、`IntegrityPassed` 或 `Running`。`pkg_version` 为空/损坏或无法映射时保留诊断事实，但不能制造版本候选。

## 7.1 ProcessExitRecoveryRecord

这是持久化的恢复事实，不是新的 Game 业务状态，也不是额外的 Task.status。它至少包含 Game ID、launch session ID、Process identity（PID、启动时间和可验证的 executable/prefix 摘要）、退出码/信号（若有）、termination-confirmed、恢复来源（ProcessExit 或 restart reconciliation）、期望终态、已知副作用、恢复阶段、重试次数和最近错误。

生命周期：

```text
ProcessExitEvent
  → termination record pending
  → Game target state + termination record committed and re-read
  → recovery cleared

commit failure
  → recoveryRequired + same-game lifecycle guard
  → retry idempotent termination commit
  → verified → new GameLaunch allowed
```

应用重启时，持久 `Running` 不能直接恢复为可用 Running：必须先以 Process identity 验证活动进程并重新接管，或确认进程不存在后建立 `restart reconciliation` recovery record。没有可用退出事实时，恢复提交采用保守的 `LaunchFailed`/`interruptedAfterRestart` 结果，不推断正常退出，也不自动启动。恢复记录或终态提交失败时，磁盘上的旧 Running 只能与持久 recovery record 一起保留，并继续阻止启动；不能只把内存投影改成其他状态。

恢复命令只确认进程已退出并提交目标终态，不重新创建 Wine 进程。重复退出事件以 session ID 幂等。

## 8. DomainEvent

DomainEvent 是只追加、可排序、Sendable 的事实信封：

| 字段 | 含义 |
|---|---|
| `sequence` | Domain 服务内单调递增序列 |
| `occurredAt` | 领域事实产生时间 |
| `kind` | `gameChanged`、`taskChanged`、`integrityChanged`、`solutionChanged`、`runtimeChanged`、`permissionChanged`、`recoveryChanged` |
| `targetID` | Game、Task、方案或恢复会话 ID |
| `revision` | 相关聚合版本 |
| `payload` | 不可变结果值，不含 UI 文案或 ViewModel |
| `persistence` | `committed`、`memoryOnly`、`recoveryRequired` |

对需要持久化的业务改变，只有 `committed` 事件才能驱动“已应用/已接入”等持久状态投影。`memoryOnly` 只允许表达短暂运行事实，并在退出时重新评估。

## 9. 领域不变量

1. 任务状态和业务结果永不合并为一个布尔值。
2. 授权事实、文件事实、进程事实、修改事实和恢复事实分别记录。
3. 所有外部副作用都有可验证的完成门槛；无法读回即失败或恢复未确认。
4. 领域对象只包含业务值，不包含 UI 文案、SwiftUI 类型、`Process` 或裸的非 Sendable 系统对象。
5. 任何状态恢复失败都会阻止需要该状态的后续任务，而不是静默使用默认值。
