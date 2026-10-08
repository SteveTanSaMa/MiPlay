# MiPlay 服务契约

> **文档状态**：已冻结（Architecture 回溯；2026-08-28 重置 I-4 运行时模型，并保留 I-1/I-5 契约）
> **更新日期**：2026-08-28
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
- **Metadata/settings**：GameRegistry 归档按 Game ID 关联的 `GameMetadata` 与 `PerGameSettings`，并归档当前 `BackgroundGroup` selection；固定 Wine、共享 prefix、来源策略和 runtime readiness 由 `WineVersionManager` 管理，不写入 Game 的可选绑定字段。
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

- **输入**：Game 快照、有效 location scope、由 `WineVersionManager` 提供的公共 runtime/prefix readiness、产品版本/manifest 条件。
- **输出**：`passed` 或按阶段分类的验证错误；不得返回“启动成功”。
- **运行时规则**：先消费无 Game 上下文的公共 readiness，再以 `checkReadiness(for gameID:)` 验证目标 Game；不选择 runtime/prefix，不调用外部 Wine，也不自行创建 Game 级 prefix。通过后由 `LaunchOrchestrator` 取得同一 `validatedRuntime()` 和 shared prefix lease。
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

**职责**：编排公共 runtime/prefix 校验、命令构造、进程确认、退出和 Game 状态转换。

- **输入**：Game ID、UserIntent、任务取消信号、性能选项快照；来自 `WineVersionManager` 的固定 `validatedRuntime()`、共享 prefix lease 和目标 Game 的启动前置结果。Game ID 只用于游戏 executable、路径、manifest 和结果归属，不用于选择 Wine/prefix。
- **输出**：阶段事件和 `LaunchOutcome`：`runningConfirmed`、`preflightRejected`、`runtimePreparationFailed`、`processStartFailed`、`processTimeout`、`processExitedAbnormally`、`cancelledCleanly`。
- **失败**：任何前置失败、binary/exe 不可用、prefix 未完成、Process 启动失败、确认超时、异常退出、清理未确认。创建进程不算成功。
- **取消**：排队时可取消；prefix/进程请求发出后，终止进程并确认退出、清理临时资源；确认失败为 `failed + recoveryRequired`。确认完成后才允许 `cancelledCleanly`。
- **权限**：游戏 exe/工作目录由用户目录 bookmark scope 保护，共享 prefix 由 App Support 容器保护；两者权限事实不互相替代，scope 覆盖启动和确认阶段。
- **持久化**：`Launching`/`runningConfirmed`/退出结果由 GameRegistry 提交；活动 Process 不持久化；启动命令只记安全摘要，不记 bookmark/token。进程退出后，只有退出结果和目标 Game 状态提交并重读验证，才允许清除 session guard；提交失败保留 `recoveryRequired` 和同目标锁。

Launch session 的 Game/session ID、目标 binary/prefix 安全摘要和 guard 必须在调用 ProcessManager 创建进程前提交并重读验证；提交失败不得创建进程。Process 健康确认后才能提交 `Running`，不能用 ProcessCreated 事件替代。

### 6.1 启动命令固定值

`LaunchOrchestrator` 生成的不可变命令必须满足：

```text
Process executable: <fixed managed Wine binary>/wine
Process arguments: [<absolute game .exe>] + [fixed/performance arguments]
Working directory: <resolved game directory>
WINEPREFIX: <AppSupport>/MiPlay/WinePrefixes/shared
WINEDLLOVERRIDES: winemenubuilder.exe=d
```

prefix 准备命令是固定托管 Wine binary 的 `wineboot -u`，成功门槛为共享 prefix identity、结构、内容和 runtime/prefix 绑定验证。命令参数使用数组传递，不通过 shell；当前版本不接受用户任意参数或任意环境变量。

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

**职责**：作为唯一 runtime 决策者，管理固定 `wine-crossover-11.0-1-signed`、唯一共享 prefix、安装/准备/恢复状态和公共/目标 Game readiness；不检测外部 Wine，不暴露版本或来源选择。

- **输入**：固定 `ManagedWineReleasePolicy`、唯一 catalog entry 的读取结果、`WineRuntimeSetup` 执行结果、共享 prefix 状态、目标 Game ID 的前置验证请求；不接收系统 Wine、用户 URL、外部路径或 per-game override。
- **输出**：固定 runtime snapshot、共享 prefix snapshot、公共 `RuntimeReadiness`、`checkReadiness(for:)` 的目标 Game 结果、`validatedRuntime()`、`validatedSharedPrefix()`、持久化 `TaskReceipt` 和有序 runtime/prefix task events。
- **失败**：固定资源/来源/架构/校验/下载/安装失败、binary 身份无法验证、prefix 初始化/验证/恢复失败、共享资源 busy、迁移未确认、持久化失败；不以其他 Wine/prefix fallback。
- **取消**：下载或安装前段可取消；prefix 初始化、修复或已产生外部副作用后必须停止并确认清理/恢复。无法确认为 `failed + recoveryRequired`；不得报告 clean cancellation。
- **权限**：runtime 和 shared prefix 只写 App Support 容器；不使用游戏目录 bookmark 写 runtime/prefix，不访问系统 Wine。
- **持久化**：`WineRuntimeSetup` 入队、running、阶段和终态按任务契约提交；只有固定 runtime 安装身份、共享 prefix 状态和最终 pair 验证全部重读确认后才发布成功。不存在全局选择、per-game override、installed version list 或删除请求。

### 7.1 固定 catalog entry 读取

- **输入**：固定 release identity、产品批准 source identity、policy revision、目标架构和取消信号。source identity 由产品策略提供，不接受用户选择、用户 URL、token 或任意镜像。
- **输出**：一个可验证的 fixed catalog entry，至少包含 release/tag、asset identity、架构、预期 size/digest/签名事实和来源摘要；结果只能是 fixed entry、暂不可用、来源错误或 `catalogInvalid`。
- **失败**：release/asset identity、架构、响应 schema、来源身份或校验要求不一致时为 `catalogInvalid`；HTTP/网络/限流/权限错误保留技术状态，不产生替代 entry，不自动换源。
- **取消**：停止 metadata 请求并确认 stream 结束；不清除现有已验证 runtime/prefix，也不改变固定策略。
- **权限**：只使用应用网络能力和 App Support 临时/诊断目录。
- **持久化**：只保存固定 entry 的安全摘要、policy revision、抓取时间和验证结果；不形成可选择的版本列表。

### 7.2 WineRuntimeSetup

**职责**：以固定 catalog entry 为唯一目标，串行完成固定资源获取、asset 内容验证、托管安装提交、共享 prefix 初始化/复用/验证和最终 pair 验证。

- **输入**：固定 catalog entry、`arm64` 目标、App Support staged directory、共享 prefix identity/path、取消信号和恢复上下文；不接受 version/source selection。
- **输出**：阶段事件以及已提交并重读验证的 `ManagedWineRuntime` + `SharedWinePrefix` pair，或明确的失败/取消/恢复结果。
- **阶段**：`readingFixedEntry` → `downloading` → `verifyingArtifact` → `installingRuntime` → `preparingSharedPrefix` → `verifyingRuntimePair` → `committed`。
- **失败**：资源拒绝/缺失、网络错误、尺寸/digest/签名/结构不符、磁盘/解压/安装提交失败、prefix 结构或 runtime 绑定不符、迁移状态不明确；artifact 或半初始化 prefix 不得成为 ready。
- **取消**：下载/校验前段可取消；安装或 prefix 操作开始后，必须等待子进程停止、清理或保留恢复保护。此前有效 pair 必须继续保留；清理不确定为 `RecoveryRequired`。
- **权限**：只写 App Support；三款游戏的 bookmark scope 不参与 runtime/prefix 安装。
- **持久化**：`ManagedWineRuntime`、`SharedWinePrefix` 和 recovery record 采用临时写入、解码/规则验证、原子替换、重读确认；任一提交未确认不得发布 runtime/prefix ready。

### 7.3 公共 readiness、目标 Game readiness 与锁

- **公共查询**：`checkReadiness()` 只验证固定 runtime、唯一 shared prefix、pair identity、持久化记录和恢复状态；没有 Game ID，不得返回 `WineReady`。
- **目标查询**：`checkReadiness(for gameID:)` 先取得公共 readiness，再叠加目标 Game 的 executable、路径 scope、manifest 和启动前置；它不改变 runtime/prefix identity。
- **验证 API**：`validatedRuntime()` 无参数，返回固定 Wine binary + shared prefix pair；`validatedSharedPrefix()` 无参数，返回共享 prefix 的受保护使用事实。不存在 `validatedRuntime(for:)`。
- **共享 prefix lease**：初始化、修复、升级和每次游戏启动都必须取得 `sharedWinePrefix` 独占 lease。启动 lease 从 prefix 准备完成前一直持有到进程退出、termination confirmed 和清理完成；同一时间不得有第二个游戏 launch 使用该 prefix，冲突返回 `busy/conflict`，不能隐式排队或创建第二个 prefix。
- **恢复**：任何 prefix recovery record、未确认进程或 pair mismatch 都阻止三款游戏的新启动；恢复必须在同一 shared prefix lease 下完成，并在释放 lease 前重读验证。

### 7.4 删除、升级与回滚

- 当前固定 runtime 和 shared prefix 不提供用户删除 API。允许删除未提交 artifact、失败 staged 结果或已确认无效的临时数据，但不删除当前有效 pair。
- 未来 Product 批准的升级是一个 pair transaction：新 runtime staged/验证 → runtime + shared prefix locks → 保留旧 pair 回滚事实 → 准备并验证新 prefix → 原子提交。失败/取消保留旧 pair；旧 pair 无法确认时进入 `RecoveryRequired`。
- 回滚和清理前检查三款游戏的活动 launch session、shared prefix lease、进程退出确认和 recovery records；任何一项未收敛都禁止清理旧 pair。

## 8. WineRuntimeProvider

**职责**：执行 `WineVersionManager` 已验证的固定 Wine binary 与唯一 shared prefix 的加载、准备、验证和受保护使用，不决定 runtime/prefix identity。

- **输入**：已由 WineVersionManager 验证的固定 runtime identity、`sharedWinePrefix` identity/path、固定 Wine binary、取消信号和 lease 上下文；不接收 Game ID 作为 prefix 选择输入。
- **输出**：可执行固定 Wine binary、已确认的 shared prefix 使用事实、prefix 准备/验证结果和 lease 生命周期事实。
- **失败**：binary 不存在/不可执行、固定 runtime 身份不一致、`wine --version` 超时或无输出、prefix 创建/配置/验证失败、lease 冲突或释放未确认。
- **取消**：`wineboot`、修复或受保护使用期间请求终止并等待退出；prefix 清理、进程终止和 lease 释放确认后返回 cancelled，否则 recovery required。
- **权限**：只写应用容器内的 prefix；不访问用户游戏目录以外资源，不请求系统提权。
- **持久化**：prefix 文件由基础设施管理；业务只持久化固定 runtime/shared prefix identity、准备/验证结果和恢复事实，不把运行中的进程或临时环境写入 AppData。

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

- **输入**：Game ID、目标 BackgroundGroup ID、source/cache identity、API 背景集合指纹和取消信号；只能选择该 Game 的组。
- **输出**：资源验证事实、可渲染 BackgroundGroup snapshot、集合指纹验证结果或选择提交结果。
- **失败**：来源不可达、资源身份/版本不符、传输/解码/缓存写入失败或目标组不可用；保留上一有效组并记录失败原因。
- **取消**：取消读取和临时缓存，确认清理后返回 `cancelled`；选择尚未提交时上一组不变。
- **权限**：远程/缓存使用应用网络能力和 App Support；不请求游戏目录写权限或系统 helper。
- **持久化**：目标组必须资源验证、selection 写回和重读均成功才发布 `BackgroundChanged`；选择写入 AppData，缓存指纹与 manifest 写入媒体缓存目录；写入失败不把内存选择显示为已保存。
- **用户反馈**：只在组成功提交后显示已切换；失败明确显示当前仍为上一有效组。

### 12.2 API 背景集合指纹与缓存失效（I-1）

- **指纹定义**：指纹由一次 API 响应的该 Game 背景集合内容计算，至少包含 source identity、组 ID 顺序、每组图片/视频/theme 资源身份与版本。指纹不得包含 `selectedBackgroundGroupID`、hover 预览态或加载时序。
- **缓存单元**：缓存按 `(Game ID, 组 ID, 资源身份)` 组织；每个组在指纹变化前保持完整缓存，不因用户切换被删除。
- **失效规则**：只有当前 API 集合指纹与已持久化指纹不一致时才允许清理。清理按 diff 进行：只删除不再属于当前集合的组，或资源身份已变化的旧资源；未变化的组保留缓存。
- **用户切换**：`selectedBackgroundGroupID` 改变、hover 预览、预览失败和选择提交失败均不改变指纹，不删除任何分组缓存。
- **指纹缺失/读取失败**：不得进行破坏性清理；缓存按未知集合处理，逐资源验证或重新获取，不删除无法判断归属的资源。
- **API 请求失败**：保留现有缓存和指纹；不因网络失败触发清理。
- **持久化**：指纹与缓存 manifest 位于 App Support 媒体缓存目录，属于派生缓存事实；AppData 只保存 `selectedBackgroundGroupID` 等用户选择。旧 `lastCachedBackgroundIds` 不再作为选中或缓存失效依据。

## 13. PersistenceStore

**职责**：以 Actor 串行管理 `AppData.json`、备份、schema 迁移、原子写入和恢复。

- **输入**：schema 版本数据、读/写/迁移/恢复命令、目标文件名（仅 allowlist 内的 `AppData`）、取消信号。
- **输出**：已解码并验证的 AppData snapshot、`readable`、`migrationRequired`、`restoreAvailable`、`restoredAndVerified`、`migratedAndVerified`、`recoveryFailed` 等恢复事实。
- **失败**：文件缺失（首次启动除外）、JSON 损坏、schema 不支持、编码失败、目录/磁盘/原子替换失败、备份读回失败。
- **取消**：编码前可取消；原子替换开始后不报告“半取消”，必须完成替换或确认旧文件仍完整；恢复/迁移写入失败保留原文件和备份。
- **权限**：只写应用容器内 Application Support；不得读写游戏目录或系统路径；文件权限失败映射为 persistence error。
- **持久化**：正式文件 `AppData.json`；写入使用临时文件 → 解码验证 → 原子替换；前一份可读数据维护 `.bak`；损坏原件另存诊断副本，不静默覆盖。

### 13.1 损坏、备份、迁移和写入失败

目标持久化格式为 **schema 4**；当前没有 `schemaVersion` 的旧 `AppData.json` 按 schema 1 处理。所有未来格式必须通过递增版本迁移，不能在读取处散落兼容分支。

- 首次没有 `AppData.json`：产生 `initialData`，这是首次初始化，不是恢复成功。
- 旧 schema：先备份，逐版本迁移，写临时文件并重新读取验证；验证失败不覆盖旧文件。
- schema 1/2/3 → 4：保留 Game、bookmark、背景选择和其他仍有效业务事实；`selectedWineVersion`、`selectedWineSource`、`installedWineVersions` 与 `PerGameSettings.wineVersionOverride` 只作为迁移输入，不能写入新模型。与固定 tag 相同的旧版本仅作为重新验证候选；其他/空值不能授权旧 Wine。旧 per-game override 全部清除产品含义，旧 `WinePrefixes/<gameID>` 不合并、不改名后静默采用；可安全隔离则保留为 legacy recovery data，否则迁移进入 `migrationRequired`/`RecoveryRequired`。共享 prefix 缺少 authoritative record 时必须显式验证，不能默认 ready。迁移写入临时文件、重读验证后发布；失败保留旧文件与备份。
- 当前文件损坏：保留原文件，生成带时间标识的诊断副本；验证 `.bak` 后进入 `restoreAvailable`，不自动把默认值当用户数据。
- 用户选择恢复：恢复后必须重新读取和结构验证，成功才允许 Domain 初始化。
- 用户明确重新开始：清除旧业务投影，但保留诊断文件，并记录 `freshStartConfirmed`。
- 正常写入失败：旧正式文件保持不变，临时文件可保留用于诊断；调用方得到 `writeFailed`，不能发布 `committed` 事件。
- Domain 外部副作用已发生而保存失败：调用方必须尝试回滚；回滚也失败则进入 `recoveryRequired` 并阻止同目标重复操作。

### 13.2 P1 终态提交门槛

- `completed`：业务结果已经达到自身门槛，相关 AppData 已写入，重新读取确认记录存在，才可发布。
- `failed`：目标未达成且副作用已清理或没有副作用；失败记录已经提交并可读取。
- `recoveryRequired`：不是 `Task.status`，而是“副作用或业务事实无法安全收敛”的持久化恢复记录。恢复记录提交后，调度器锁住同目标；记录提交失败时由 Domain 保留内存保护并继续重试。
- WineRuntimeSetup 的 runtime/prefix pair 提交失败不能被吞掉；artifact 或半初始化 prefix 只能处于 staged/待清理/recovery 事实，不能成为 installed、PrefixReady 或 WineReady。

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

## 17. SystemEnvironmentDetector

**职责**：只读取产品范围内的 macOS、Apple Silicon、设备信息和目标卷磁盘能力；不提供 Wine 路径、版本或可用性，不记录序列号等敏感设备标识。

- **输入**：无用户路径输入；磁盘查询使用调用方已解析的合法目标 URL；允许注入只读系统数据源作为测试 seam。
- **输出**：`SystemInfo` 至少包含 `machineName`、`chipName`、`physicalMemory`、`osVersion`、`buildNumber`、`modelIdentifier` 和 `isAppleSilicon`；任一字段可为 `unknown` 或带失败事实，不推断。
- **字段规则**：
  - `machineName` 只取系统报告的机器名称（例如 `MacBook Pro`），不从 `hw.model` 推断尺寸或营销后缀；
  - `chipName` 只取系统报告的芯片名称（例如 `Apple M1 Pro`），绝不把 `hw.model` 当作芯片名；
  - `physicalMemory` 使用系统报告的物理内存值，不用 0、默认值或旧值补齐；
  - `osVersion` 使用产品版本，`buildNumber` 是详情字段，不能替代 `osVersion`；
  - `modelIdentifier`（例如 `MacBookPro18,1`）是详情字段，不作为主层级，不推断芯片或尺寸。
- **失败**：单字段读取失败或系统未提供时保留 `unknown/failed` 事实，不影响其他字段；不得把失败映射成 Wine 状态或启动结论。
- **取消**：系统查询为只读同步能力；若使用可取消注入源，按调用方取消停止。
- **权限**：只读系统信息和 App Support/已授权目标卷；不读取、不展示、不持久化序列号、平台 UUID、UDID、Wine 路径或系统 Wine 事实；磁盘空间只针对 Wine 管理目标卷，不固定假设根卷。
- **持久化**：不把原始检测值写入 AppData；如 UI 需要保留上一次已确认值，由对应 ViewModel 保存过期标记，不成为第二业务事实源。
- **用户反馈**：主层级只展示机型、芯片、内存、macOS 版本；model identifier 与 build number 为详情；Wine 目标磁盘空间独立展示。
