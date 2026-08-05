# MiPlay 服务契约

> **文档状态**：已冻结（Phase 3；当前修订基线见 `architecture-revision-2026-08-03.md`）
> **更新日期**：2026-08-03
> **说明**：以下是职责和行为契约，不是 Swift protocol/class/actor 定义。具体类型名可以按实现文件调整，但不能改变输入、输出、失败、取消、权限和持久化语义。

## 1. 共同返回规则

所有耗时命令都返回任务接收事实，再通过 Task/Domain event 提供过程和最终结果。最终结果必须分成：

- `taskStatus`：`pending`、`running`、`completed`、`failed`、`cancelled`。
- `outcome`：本任务实际获得的业务结果。
- `error`：失败类别、阶段、副作用和恢复动作。
- `persistence`：结果是否已提交、仅内存存在或需要恢复。

“命令返回”“备份成功”“进程已创建”“下载流结束”和“任务 completed”都不是通用业务成功。

## 2. GameRegistry

**职责**：维护三款固定 Game 的业务快照、location 授权事实、状态转换和事件。

- **输入**：Game ID；定位后的 bookmark record；完整性/版本/启动/退出结果；用户请求的状态刷新。
- **输出**：三款 Game 快照、单 Game 快照、状态转换拒绝原因、带序列号的 `gameChanged/permissionChanged` 事件。
- **失败**：未知 Game、非法状态转换、location 无授权、持久化失败、恢复未确认。失败时不提升 Game 状态。
- **取消**：查询可取消；已提交的状态变更不由 UI 中断，若有外部副作用由调用方完成清理后再提交结果。
- **权限**：不自行授权；所有游戏目录操作必须通过有效 bookmark scope。裸 path 只能产生 `migrationRequired`。
- **持久化**：Game、location、完整性结果、方案记录在提交后写入 `AppData.json`；提交失败保留旧快照并发布 recovery required。
- **Metadata/settings**：GameRegistry 归档按 Game ID 关联的 `GameMetadata` 与 `PerGameSettings`，并归档当前 `BackgroundGroup` selection；全局 Wine source selection 不写入 per-game record。
- **背景失败**：目标背景组不可用、取消或选择写回失败时保留上一有效组，记录失败事实，不改变 Game 业务状态。

## 3. GameStateMachine

**职责**：对 Game 状态转换进行纯规则判断，不执行 I/O。

- **输入**：当前 Game 状态、触发事件、相关任务状态和可信结果。
- **输出**：允许的新状态或带原因的转换拒绝。
- **失败**：状态上下文不完整、任务尚未开始却请求 `Launching`、无进程确认却请求 `Running`。
- **取消**：无 I/O，不需要取消；调用方取消事件必须通过合法转换规则处理。
- **权限**：不访问资源，不产生授权判断；权限事实由输入提供。
- **持久化**：不直接写入；允许的转换由 `GameRegistry` 提交。

## 4. PreLaunchValidator

**职责**：在启动执行前汇总系统、路径、可执行文件、完整性、Wine 和磁盘条件。

- **输入**：Game 快照、有效 location scope、当前 runtime selection、产品版本/manifest 条件。
- **输出**：`passed` 或按阶段分类的验证错误；不得返回“启动成功”。
- **失败**：路径未授权、exe 缺失、manifest 不支持/不完整、Wine 未就绪、系统不兼容、磁盘空间不足、读取失败。
- **取消**：校验期间可取消；取消只保留上一条可信结果，Task 为 `cancelled`，不修改 Game 状态。
- **权限**：读取游戏文件使用 bookmark scope；只读校验不要求系统提权；当前只读 entitlement 下不得尝试写入修复。
- **持久化**：可信完整性结果可由 `GameRegistry` 归档；验证失败不覆盖上一条可信结果，错误和过期事实可记录。

## 5. FileIntegrityVerifier

**职责**：使用非空且与当前游戏版本对应的 manifest，并结合可选本地证据读取和校验全部条目。

- **输入**：Game ID、有效只读 location scope、Product 批准的 IntegrityManifest，以及可选的 `LocalGameEvidence`。
- **输出**：`IntegrityPassed`、`IntegrityFailed`、`IntegrityUnsupported`、`versionEvidenceConflict`、执行失败或取消；附缺失/不匹配条目和证据来源。
- **失败**：manifest 缺失/为空/不对应、`pkg_version` 解析或映射失败、证据冲突、权限或 I/O 阻止读取、哈希/尺寸验证失败。完整性失败是可信负结果，不是 Task 失败。
- **取消**：在全部条目完成前取消，输出 `cancelled`，保留上一条可信结果。
- **权限**：只读 bookmark 足够；不修改游戏文件、不请求提权。
- **持久化**：只有结果和时间归档；校验过程临时数据不归档；失败不把 Game 提升为 `Installed`。

### 5.1 LocalGameEvidenceReader

**职责**：在一次有效 scoped access 内读取和解析 `pkg_version`、`config.ini`，输出可追溯的本地证据；不把任一文件直接升级为完整性或版本事实。

- **输入**：Game ID、有效 `ScopedGameLocationAccess`、目标相对文件位置、取消信号和当前 location revision。
- **输出**：`LocalGameEvidence`，包含 JSON Lines `pkg_version` 条目、`config.ini` 的 `game_version/channel/sub_channel/cps/sdk_version` 候选、解析状态、来源摘要和关联 revision。
- **失败**：文件不存在、空文件、JSON Lines/INI 格式错误、目标 Game/路径关联失败、字段类型非法、MD5/尺寸字段不完整、版本证据冲突；不把失败映射为已安装或完整。
- **取消**：读取/解析前段可取消；取消保留上一次可信 evidence，不写入新的版本或完整性结果。
- **权限**：只读 bookmark scope；当前 read-only entitlement 足够读取，不能借此修改 `pkg_version`/`config.ini` 或修复游戏文件。
- **持久化**：只归档经过验证的 evidence 摘要、来源和时间；不归档 token 或任意原始路径。写回失败时保留旧 evidence，不发布新的 `current`/`IntegrityPassed`。

`pkg_version` 的文件校验使用条目声明的文件大小和 MD5；`config.ini.wpf_version` 不进入输出事实。`config.ini.game_version` 只能作为候选版本，必须与 manifest/远程版本按 Domain 规则关联。

### 5.2 VersionChecker

**职责**：组合本地 evidence 与官方远程版本候选，输出可解释的版本比较结果；不执行完整游戏更新。

- **输入**：Game ID、有效 location lease、`LocalGameEvidence`、Product 批准的官方版本查询参数、取消信号。
- **输出**：`current`、`updateAvailable`、`versionEvidenceConflict` 或无法确认的 outcome；带本地来源、远程来源和版本关联依据。
- **失败**：远程网络/HTTP/限流、无本地版本候选、`config.ini` 与 manifest 冲突、`pkg_version` 无法映射、远程响应身份无法验证；失败不改变既有 Game 状态。
- **取消**：网络请求或本地读取未完成前可取消；保留上一条可信版本结果，不清除已有 `UpdateAvailable`。
- **权限**：本地读取必须使用 bookmark scope；远程查询只使用应用网络能力，不请求游戏目录写权限或系统提权。
- **持久化**：提交版本结果前必须保存并重读 evidence 摘要和结果 revision；写入失败为 persistence error，不发布 `current/updateAvailable`。

## 6. LaunchOrchestrator

**职责**：编排校验、Wine prefix、命令构造、进程确认、退出和 Game 状态转换。

- **输入**：Game ID、UserIntent、任务取消信号、性能选项快照；来自 `WineVersionManager` 的 Managed RuntimeSelection。
- **输出**：阶段事件和 `LaunchOutcome`：`runningConfirmed`、`preflightRejected`、`runtimePreparationFailed`、`processStartFailed`、`processTimeout`、`processExitedAbnormally`、`cancelledCleanly`。
- **失败**：任何前置失败、binary/exe 不可用、prefix 未完成、Process 启动失败、确认超时、异常退出、清理未确认。创建进程不算成功。
- **取消**：排队时可取消；prefix/进程请求发出后，终止进程并确认退出、清理临时资源；确认失败为 `failed + recoveryRequired`。确认完成后才允许 `cancelledCleanly`。
- **权限**：游戏 exe、工作目录和 prefix 分别受用户目录 bookmark、App Sandbox 容器权限约束；不使用提权访问游戏目录；scope 覆盖启动和确认阶段。
- **持久化**：`Launching`/`runningConfirmed`/退出结果由 GameRegistry 提交；活动 Process 不持久化；启动命令只记安全摘要，不记 bookmark/token。进程退出后，只有退出结果和目标 Game 状态提交并重读验证，才允许清除 session guard；提交失败保留 `recoveryRequired` 和同目标锁。

Launch session 的 Game/session ID、目标 binary/prefix 安全摘要和 guard 必须在调用 ProcessManager 创建进程前提交并重读验证；提交失败不得创建进程。Process 健康确认后才能提交 `Running`，不能用 ProcessCreated 事件替代。

### 6.1 启动命令固定值

`LaunchOrchestrator` 生成的不可变命令必须满足：

```text
Process executable: <selected Wine binary>/wine
Process arguments: [<absolute game .exe>] + [fixed/performance arguments]
Working directory: <resolved game directory>
WINEPREFIX: <AppSupport>/MiPlay/WinePrefixes/<stableGameID>
WINEDLLOVERRIDES: winemenubuilder.exe=d
```

prefix 准备命令是同一个 Wine binary 的 `wineboot -u`，成功门槛为 prefix 结构和可运行性验证。命令参数使用数组传递，不通过 shell；当前版本不接受用户任意参数或任意环境变量。

### 6.2 进程退出后的状态恢复

进程退出输入必须携带 launch task/session ID、Game ID、Process identity、退出码/信号、退出事实时间和 `terminationConfirmed`。处理规则为：

```text
Running + normal exit
  → 计算 Installed/UpdateAvailable
  → 持久化 Game + termination record
  → 重读验证
  → 清除 session guard / scope / Process reference

Running + abnormal exit
  → 计算 LaunchFailed
  → 持久化 Game + exit record
  → 重读验证
  → 清除 session guard / scope / Process reference
```

- 退出事实重复到达时按 Process ID/session ID 幂等处理，不重复转换或产生第二条恢复任务。
- Game 状态提交失败时，不得只记录日志后释放所有保护；创建并持久化 `recoveryRequired` 记录，保留同 Game lifecycle lock，阻止新的启动。
- 若 recovery record 也无法写入，保留内存中的 termination guard，重试持久化；下次启动把仍为 `Running` 且没有可信活动进程的记录视为 recovery required，不自动启动。
- 恢复命令只重新确认进程已退出并提交目标终态，不重新启动游戏。恢复提交成功后才允许用户创建新的 `GameLaunch` Task。

应用重启边界：

1. `Running` 和 launch session 必须在启动快照发布前扫描；PID 存在本身不算活动进程。
2. 只有 executable、prefix、启动时间和 session identity 全部匹配时，ProcessManager 才可重新接管并发布 `Running`。
3. 没有可验证活动进程时，先持久化 `restart reconciliation` recovery record 并保留 lifecycle lock；若没有已确认退出事实，目标终态只能是保守的 `LaunchFailed(interruptedAfterRestart)`，不能推断正常退出。
4. recovery record 或终态提交失败时，旧 `Running` 记录可以因原子写入保护而暂存，但必须伴随持久 recovery record；若两者都无法写入，进入 AppData recovery guard，禁止启动并在下一次启动重试，不能只更新内存状态。

## 7. WineVersionManager

**职责**：管理 MiPlay 托管 Wine 的 source selection、API/Release metadata 目录、独立 asset 下载、安装提交、生效路径和就绪状态；不检测外部 Wine。

- **输入**：`WineCatalogQuery`、Product 来源策略/allowlist、Release metadata、`WineAssetDownload` 结果、用户主动选择/删除请求；不接收系统路径扫描结果。
- **输出**：RuntimeCatalog、`RuntimeSourceResult`、仅指向 ManagedWineRuntime 的 RuntimeSelection、`WineNotReady/WineAcquiring/WineReady/WineAcquisitionFailed` 事件、已持久化 `TaskReceipt` 和有序下载 Task events。
- **失败**：来源/HTTP/429/认证策略、资源缺失、下载/校验/解压失败、空间不足、binary 无法执行、删除正在使用版本；系统 Wine 或外部 bottle 不能作为失败时的替代成功。
- **取消**：下载、解压和安装记录提交前可请求取消；取消必须传播到 WineVersionDownloader、URLSession 和解压进程，等待停止后删除临时归档/不完整目录，并验证目标版本未列为 installed；清理失败为 `failed + recoveryRequired`。
- **权限**：托管运行时写入 App Support 容器；不使用游戏目录 bookmark 写入 runtime；无系统 Wine 权限或观察能力。
- **持久化**：入队必须先提交 pending Task；开始下载前提交 running；只有 artifact 完整、`installedWineVersions` 写入并重读验证后才发布 completed。写入失败时清理 staged artifact；清理不确定进入 recoveryRequired。

### 7.1 WineCatalogQuery 与来源解析

- **输入**：用户当前选择的 source ID、来源策略 revision、目标架构、网络取消信号；不接受用户自定义 URL、镜像、token 或任意 headers。查询只读取 API/Release metadata，不读取 asset body。
- **输出**：`catalogLoading`、`availableManagedVersions`、`noAvailableManagedVersion`、`networkFailure`、`apiForbidden`、`rateLimited`、`sourceConfigurationError`、`catalogInvalid`；结果只包含可验证 CatalogEntry，不改变 RuntimeSelection。
- **失败**：API 403 映射 `apiForbidden` 并记录 source/status/响应摘要；429 记录 `retryAfter`；网络/超时为 `networkFailure`；有效空结果为 `noAvailableManagedVersion`；schema、release/asset identity、架构或 allowlist 映射不一致为 `catalogInvalid`。来源失败不自动切换 source。
- **取消**：查询未完成前可取消；必须等待 URLSession stream 停止，保留上一已验证目录，不清除 source selection 或 RuntimeSelection。
- **权限**：只使用应用网络能力和 App Support 缓存；不请求用户 token，不读游戏 bookmark 或系统 Wine。
- **持久化**：保存 source identity、policy revision、release/asset identity、架构、目录项、抓取时间和 result revision，写入并重读验证后才发布目录；失败时旧缓存只作过期诊断。

用户可主动改选另一个预置 allowlist source；Architecture 不自动重试另一个 source，也不以镜像 API 的成功替代 asset 内容验证。

### 7.2 WineAssetDownload

**职责**：从已验证 CatalogEntry 获取对应 Release asset，校验并提交 MiPlay 托管安装；不负责 API 发现或来源选择。

- **输入**：同一 source/policy revision 的 CatalogEntry、目标架构、App Support staged directory 和取消信号；不接受裸 URL。
- **输出**：已验证 staged artifact、安装/解压事实、已提交并重读的 `ManagedWineRuntime` 或错误结果。
- **失败**：asset 403/404、跨 allowlist redirect、网络/429、尺寸/digest/签名/结构不符、磁盘/解压失败或安装记录写入失败分别保留 `assetForbidden/resourceNotFound/networkFailure/integrityFailed/writeFailed`；artifact 不能变成 installed。
- **取消**：传播至 URLSession、解压和清理；只有停止、临时资源清理和 installed 列表读回都确认才是 `cancelled`，否则 `failed + recoveryRequired`。
- **权限**：只写 App Support；不使用游戏目录或系统 helper。
- **持久化**：`installedWineVersions` 写入并重读验证是 `completed` 门槛；提交失败保留旧 runtime，清理 staged artifact 或建立 recoveryRequired。
- **用户反馈**：单独显示 API 发现、asset 下载、校验、安装和提交阶段，不把目录或进度显示为 WineReady。

## 8. WineRuntimeProvider

**职责**：执行指定 Wine binary 的加载和 prefix 准备，不决定版本。

- **输入**：已由 WineVersionManager 验证的 runtime path、stable Game ID、App Support prefix 根目录、取消信号。
- **输出**：可执行 Wine binary、已确认的 prefix 路径和准备阶段事实。
- **失败**：binary 不存在/不可执行、`wine --version` 超时或无输出、prefix 创建/配置/验证失败。
- **取消**：`wineboot` 运行期间请求终止并等待退出；prefix 清理确认后返回 cancelled，否则 recovery required。
- **权限**：只写应用容器内的 prefix；不访问用户游戏目录以外资源，不请求系统提权。
- **持久化**：prefix 文件由基础设施管理；业务只持久化 runtime 选择和就绪结果，不把运行中的进程或临时环境写入 AppData。

## 9. GameFileSystemRepository

**职责**：提供受授权的文件读写、备份、验证、临时目录和路径安全检查。

- **输入**：容器内 URL 或已经解析的 security-scoped URL、操作类型、预期目标和取消信号。
- **输出**：文件存在/尺寸/哈希/读写结果、备份句柄，以及 `ScopedGameLocationAccess`（resolved URL、resolved `GameLocation`、是否 stale、scope lease 和 refresh commit 状态）。
- **失败**：bookmark 无法解析/stale 更新失败、scope 启动失败、权限拒绝、路径不存在、符号链接越界、I/O/磁盘错误。
- **取消**：大文件读取、哈希、复制和解压前段可取消；取消后清理临时文件，目标原文件不被标记为已修改。
- **权限**：容器内资源直接使用；用户游戏目录必须在 scope 内；当前 read-only entitlement 下拒绝写操作；拒绝任何 system path 访问。
- **持久化**：bookmark data 和业务备份 metadata 由 Domain 通过 PersistenceStore 保存；临时文件不作为业务成功证据。

### 9.1 统一 scoped access 规则

所有 Domain 消费者，包括定位、`FileIntegrityVerifier`、`VersionChecker`、`PreLaunchValidator` 和 `LaunchOrchestrator`，都只能使用同一访问流程：

```text
stored GameLocation
  → resolve withSecurityScope
  → startAccessing
  → if stale: recreate bookmark in active scope
  → commit resolved/refreshed GameLocation
  → perform consumer operation
  → commit consumer business result
  → stopAccessing
```

- stale 时，`resolvedLocation.bookmarkData` 是当前作用域内的新授权事实；在 bookmark 刷新提交成功前，消费者不得发布 `completed`、`IntegrityPassed`、版本 `current/updateAvailable`、`Installed` 或 `Running`。
- 刷新提交失败返回 `bookmarkRefreshPersistenceFailed`，保留旧记录和 `recoveryRequired`，不回退 `lastKnownPath`，也不把本次读取结果当作新的可信业务结果。
- 非 stale 解析也必须通过同一 lease；若只更新 `lastKnownPath/lastResolvedAt`，可按 PersistenceStore 的节流策略提交，但不能绕过 lease 的关闭流程。
- lease 释放前必须完成刷新提交和该消费者的终态提交；启动场景还要保持到进程退出或清理确认。

## 10. ProcessManager

**职责**：创建、监控、等待、终止进程并收集退出事实；不决定 Game 状态。

- **输入**：不可变 ProcessLaunchSpec（binary、数组参数、环境、工作目录）、超时、取消、是否捕获输出；binary/prefix identity 由上层提供。
- **输出**：ProcessCreated（PID、启动时间、executable/prefix identity）、持续 stdout/stderr、ProcessHealthConfirmed、正常退出/非零退出/信号终止/超时/终止确认事实。
- **失败**：binary 缺失、权限拒绝、启动失败、管道读取失败、超时、`SIGTERM` 后仍运行、退出结果无法确认。
- **取消**：先发送终止请求，再等待 termination handler 和管道 EOF；不能仅返回“已发送终止”作为取消完成。
- **权限**：子进程继承应用沙盒；不通过 Process 逃逸沙盒、不调用任意 sudo；工作目录权限由 bookmark scope 提供。
- **持久化**：不持久化 Process 或 PID；只允许上层记录安全的退出摘要、阶段和错误。

## 11. SystemModificationGateway

**职责**：受限代理当前可发布的 CS-01 hostname 系统修改和回滚；A-06/hosts 屏蔽本轮 Deferred，不接受执行请求。

- **输入**：结构化操作 ID、目标资源类型（当前仅 hostname）、预期变更、应用前快照、用户授权上下文；hosts 操作直接返回 Deferred/Unavailable。
- **输出**：能力检查、备份事实、修改事实、读回验证、回滚事实；hosts 只允许 MiPlay managed block，hostname 只允许 `HostName`、`LocalHostName`、`ComputerName`；不返回“命令成功即应用”。
- **失败**：helper 未注册/未批准/签名或 XPC 不可信、权限拒绝、备份失败、部分写入、读回不一致、DNS/系统配置刷新失败。
- **取消**：能力检查和备份前可取消；修改开始后不可取消，必须完成恢复；恢复未确认返回 recovery required。
- **权限**：使用受签名和 allowlist 限制的 helper/XPC；不接受任意 shell、任意路径、任意 sudo 参数；游戏目录 bookmark 不提供此权限。
- **持久化**：应用前快照、方案记录、helper 版本和验证事实持久化；只有修改和验证均成功才允许 SolutionApplication `Applied`。

## 12. SolutionEngine

**职责**：执行发布清单中的方案事务，协调游戏目录和系统修改能力。

- **输入**：发布清单方案 ID、Game 快照、能力检查结果、风险确认、任务取消信号。
- **输出**：`Unavailable`、`Applying`、`Applied`、`RolledBack`、`Failed + RecoveryUnknown` 的 SolutionApplication 结果。
- **失败**：不适用、资源缺失、权限缺失、备份失败、修改/验证失败、持久化失败、回滚失败。
- **取消**：备份/能力检查前可取消；修改开始后转不可取消回滚；回滚读回一致才可取消或 `RolledBack`。
- **权限**：CS-01 走 SystemModificationGateway；A-06/CS-02 本轮 Deferred 不进入 gateway；若未来方案写游戏目录必须走有效 read-write bookmark，当前只读能力直接 Unavailable。
- **持久化**：快照先保存，应用后验证和记录再提交；保存失败触发回滚或 recovery required；不能只保存“已备份”。

六项高级配置 A-01 至 A-06 的 capability 查询结果均为 `Deferred`。查询成功只提供不可应用的状态；缺失/损坏时为 `Unavailable`；不创建 toggle、apply task、Applied 记录或 per-game 用户选择。A-06/hosts 不调用 SystemModificationGateway。

## 12.1 BackgroundMediaLoad

**职责**：读取指定 Game 的 BackgroundGroup metadata 和资源，验证并提交该 Game 的当前组；不改变 Game 安装、完整性、运行或启动状态。

- **输入**：Game ID、目标 BackgroundGroup ID、source/cache identity 和取消信号；只能选择该 Game 的组。
- **输出**：资源验证事实、可渲染 BackgroundGroup snapshot 或选择提交结果。
- **失败**：来源不可达、资源身份/版本不符、传输/解码/缓存写入失败或目标组不可用；保留上一有效组并记录失败原因。
- **取消**：取消读取和临时缓存，确认清理后返回 `cancelled`；选择尚未提交时上一组不变。
- **权限**：远程/缓存使用应用网络能力和 App Support；不请求游戏目录写权限或系统 helper。
- **持久化**：目标组必须资源验证、selection 写回和重读均成功才发布 `BackgroundChanged`；写入失败不把内存选择显示为已保存。
- **用户反馈**：只在组成功提交后显示已切换；失败明确显示当前仍为上一有效组。

## 13. PersistenceStore

**职责**：以 Actor 串行管理 `AppData.json`、备份、schema 迁移、原子写入和恢复。

- **输入**：schema 版本数据、读/写/迁移/恢复命令、目标文件名（仅 allowlist 内的 `AppData`）、取消信号。
- **输出**：已解码并验证的 AppData snapshot、`readable`、`migrationRequired`、`restoreAvailable`、`restoredAndVerified`、`migratedAndVerified`、`recoveryFailed` 等恢复事实。
- **失败**：文件缺失（首次启动除外）、JSON 损坏、schema 不支持、编码失败、目录/磁盘/原子替换失败、备份读回失败。
- **取消**：编码前可取消；原子替换开始后不报告“半取消”，必须完成替换或确认旧文件仍完整；恢复/迁移写入失败保留原文件和备份。
- **权限**：只写应用容器内 Application Support；不得读写游戏目录或系统路径；文件权限失败映射为 persistence error。
- **持久化**：正式文件 `AppData.json`；写入使用临时文件 → 解码验证 → 原子替换；前一份可读数据维护 `.bak`；损坏原件另存诊断副本，不静默覆盖。

### 13.1 损坏、备份、迁移和写入失败

目标持久化格式为 **schema 2**；当前没有 `schemaVersion` 的旧 `AppData.json` 按 schema 1 处理。所有未来格式必须通过递增版本迁移，不能在读取处散落兼容分支。

- 首次没有 `AppData.json`：产生 `initialData`，这是首次初始化，不是恢复成功。
- 旧 schema：先备份，逐版本迁移，写临时文件并重新读取验证；验证失败不覆盖旧文件。
- 当前文件损坏：保留原文件，生成带时间标识的诊断副本；验证 `.bak` 后进入 `restoreAvailable`，不自动把默认值当用户数据。
- 用户选择恢复：恢复后必须重新读取和结构验证，成功才允许 Domain 初始化。
- 用户明确重新开始：清除旧业务投影，但保留诊断文件，并记录 `freshStartConfirmed`。
- 正常写入失败：旧正式文件保持不变，临时文件可保留用于诊断；调用方得到 `writeFailed`，不能发布 `committed` 事件。
- Domain 外部副作用已发生而保存失败：调用方必须尝试回滚；回滚也失败则进入 `recoveryRequired` 并阻止同目标重复操作。

### 13.2 P1 终态提交门槛

- `completed`：业务结果已经达到自身门槛，相关 AppData 已写入，重新读取确认记录存在，才可发布。
- `failed`：目标未达成且副作用已清理或没有副作用；失败记录已经提交并可读取。
- `recoveryRequired`：不是 `Task.status`，而是“副作用或业务事实无法安全收敛”的持久化恢复记录。恢复记录提交后，调度器锁住同目标；记录提交失败时由 Domain 保留内存保护并继续重试。
- Wine 下载的 `markVersionInstalled` 失败不能被 `try?` 吞掉；artifact 只能处于 staged/待清理事实，不能成为 installed。

## 14. TaskScheduler

**职责**：见 `architecture-task-queue.md`。它是任务状态和任务事件的唯一所有者，不直接执行 UI 更新。

- **输入**：UserIntent、任务类型、目标 ID、优先级、互斥资源、取消策略和任务执行器引用。
- **输出**：已提交 pending 后的 `TaskReceipt`、TaskSnapshot、阶段/进度事件、独立 outcome、取消和恢复结果。Receipt 不能在 memory-only 状态返回。
- **失败**：参数无效、未知目标、重复意图、调度冲突被拒绝、执行器错误、持久化错误、恢复未确认；pending 提交失败时不启动执行。
- **取消**：pending 可直接取消；running 按任务策略传播；SolutionRevert 和已开始回滚不可取消；取消最终态需清理验证。
- **权限**：调度器只判断任务能力和资源锁；实际权限由执行器验证，不能由 UI 或调度器假定拥有。
- **持久化**：活跃任务和最近结果记录在 AppData；pending/running/terminal 状态提交并重读验证后才发布对应事件。崩溃时 pending/running 变成 interrupted failed/recovery required，不自动重放。

## 15. NetworkDownloadProvider

**职责**：执行网络请求和下载，准确区分 HTTP、传输、取消和文件结果。

- **输入**：已允许的 URL、请求头、临时目标、预期大小、取消信号。
- **输出**：HTTP metadata、下载进度、速度（可计算时）、临时文件和响应 body。
- **失败**：非 2xx、429、网络断开、校验/尺寸不符、临时文件写入失败、取消未确认。
- **取消**：取消 URLSession 工作并等待 stream 结束；未确认临时文件删除时不能报告 clean cancellation。
- **权限**：仅使用应用网络 entitlement 和容器临时目录；token 只在内存请求头中使用，不写日志或 AppData。
- **持久化**：下载只写临时文件；上层完成完整性校验和原子移动后才持久化 runtime/media metadata。

## 16. LogWriter

**职责**：沿用现有 `LogWriter` actor，记录脱敏结构化事实、写入 OSLog/App Support、flush、轮转和导出；不参与状态决策。完整契约见 `architecture-logging-contract.md`。

- **输入**：已安全化的 `LogEvent`，至少含 operation ID、阶段、结果和错误类别；任务相关事件补齐 task/game/Wine context。`LogExport` 输入是导出意图和取消信号，不是日志目录。
- **输出**：OSLog 事件、按 actor 序列化的内存批次、flush barrier、轮转日志和已脱敏导出 bundle。
- **失败**：脱敏拒绝、目录/文件写入、轮转、flush、读取、解码或导出目标失败；分类为 LogWriter error，不改变 Domain outcome。
- **取消**：flush 在不可中断文件操作开始后等待确认；LogExport 可在读取/生成阶段取消并丢弃临时导出，不删除已有日志。
- **恢复**：保留旧文件和未提交批次，重试 flush/export；不重试原业务 Task，不创建 recoveryRequired 业务事实。
- **权限**：只写容器内 Application Support `Logs`；用户选定导出目标必须通过明确授权；不使用游戏 bookmark、系统路径、shell 或 helper。
- **持久化**：日志与 AppData 分离；成功 flush 才移除内存批次，失败保留；导出前必须 flush barrier；日志失败不能阻塞已验证业务提交。
