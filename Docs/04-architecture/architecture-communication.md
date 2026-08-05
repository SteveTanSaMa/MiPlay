# MiPlay 模块通信与异常传播

> **文档状态**：已冻结（Phase 3；当前修订基线见 `architecture-revision-2026-08-03.md`）
> **更新日期**：2026-08-03
> **通信原则**：命令向下，结果向上，事件横向广播；异常在产生层分类，在 ViewModel 层投影为用户可理解事实。

## 1. 通信方向

```text
UI action
  → ViewModel UserIntent
    → TaskScheduler / Domain command
      → Domain actor
        → Infrastructure actor
          → OS / network / file / process

OS result
  → Infrastructure typed result/error
    → Domain outcome + business transition
      → Persistence commit (when required)
        → DomainEvent
          → ViewModel projection
            → UI
```

禁止以下路径：

- UI → `ProcessManager`、`PersistenceStore`、`FileManager`、系统命令。
- ViewModel → Infrastructure。
- Infrastructure → ViewModel 或 SwiftUI。
- Domain → ViewModel；Domain 不能知道某个结果要显示在哪个窗口。
- 一个 Domain Actor 直接修改另一个 Actor 的内部状态；必须调用其命令或提交事件。

## 2. 查询、命令和事件

### 2.1 查询

查询不产生副作用，返回不可变 snapshot/result。查询失败不会自动修改业务状态；如果查询只是暂时不可用，结果标记 `unknown` 或 `stale`，不伪装为成功。

### 2.2 命令

命令必须包含稳定目标 ID、UserIntent ID、必要的能力上下文和取消句柄。命令返回：

- 立即拒绝：参数无效、目标不存在、当前状态不允许。
- 接受：`TaskReceipt`，包括 task ID、intent ID、target、`pending` 当前状态、event cursor、资源锁、取消策略和 `persistence=committed`；只有 pending 记录重读验证后才能返回。
- 执行结果：独立 outcome、业务转换、错误/恢复事实和是否已持久化。

### 2.3 事件

事件在 Domain Actor 内按序生成。任务阶段事件可以频繁发送；业务状态事件只在状态转换门槛满足后发送。UI 只消费事件，不把事件反向写回 Domain。

## 3. 领域模块通信矩阵

| 发起方 | 接收方 | 通信内容 | 结果返回 |
|---|---|---|---|
| `LibraryViewModel` | `TaskScheduler` | 启动、完整性、版本检查、取消、重试意图 | TaskReceipt/拒绝 |
| `GameDetailViewModel` | `TaskScheduler` | 应用方案、回滚、取消（按策略） | TaskReceipt/拒绝 |
| `SettingsViewModel` | `TaskScheduler` | Wine 目录查询、选择、下载、删除、日志导出意图 | Runtime snapshot/TaskReceipt |
| `TaskScheduler` | Domain executor | 类型化任务输入、取消信号、互斥资源 | 阶段、outcome、错误 |
| `TaskScheduler` | `WineVersionManager` | `WineCatalogQuery`、source selection、托管版本选择和 `WineAssetDownload` 输入 | RuntimeSourceResult/RuntimeSelection/Task events |
| `WineVersionManager` | `LocalGameEvidenceReader` | 不直接调用；通过 Game/路径任务请求本地证据 | LocalGameEvidence |
| `FileIntegrityVerifier` / `VersionChecker` | `LocalGameEvidenceReader` | Game ID、有效 location lease、取消信号 | LocalGameEvidence 或 typed error |
| `LaunchOrchestrator` | `GameRegistry` | Launching、Running、退出和失败转换 | DomainEvent |
| `LaunchOrchestrator` | `PreLaunchValidator` | Game 快照和校验意图 | ValidationResult |
| `LaunchOrchestrator` | `WineVersionManager` | 请求生效 runtime | RuntimeSelection |
| `LaunchOrchestrator` | `WineRuntimeProvider` | Wine binary、Game exe、prefix、环境 | Prefix/进程准备结果 |
| `LaunchOrchestrator` | `ProcessManager` | LaunchCommand、等待确认、终止 | ProcessResult/ExitEvent |
| `SolutionEngine` | `GameFileSystemRepository` | 游戏目录快照/验证/回滚 | 文件事实 |
| `SolutionEngine` | `SystemModificationGateway` | 结构化 hosts/hostname 变更 | 修改/验证/回滚事实 |
| `GameRegistry` | `PersistenceStore` | 已验证聚合快照 | committed 或 StoreError |
| 所有 Domain service | `LogWriter` | 已安全化 LogEvent 和统一 operation/task/game context | accepted sequence 或 LogWriter error；不反向改变业务结果 |
| 所有 Domain Actor | 自己的 event stream | 不可变 DomainEvent | ViewModel 投影 |

## 4. 错误分层

### 4.1 Infrastructure 错误

Infrastructure 只报告技术事实，不直接给出业务状态：

- `permissionDenied`：系统或沙盒阻止访问。
- `resourceNotFound`：文件、binary、helper 或网络资源不存在。
- `invalidResponse`：HTTP 非成功、响应格式或版本不符合预期。
- `processStartFailed`、`processExited`、`processTimedOut`、`terminationUnconfirmed`。
- `readFailed`、`writeFailed`、`encodeFailed`、`decodeFailed`、`atomicReplaceFailed`。
- `logSanitizationRejected`、`logFlushFailed`、`logExportFailed`。
- `cancelled`：调用方取消且底层确认已停止，或 `cancellationUnconfirmed`：尚未确认。
- `unsupported`：当前平台或能力不支持。

每个错误保留技术 detail 和可安全记录的目标标识；不把完整路径、bookmark 数据或 token 写入普通日志。

### 4.2 Domain 错误

Domain 把底层错误映射到业务原因类别：`validation`、`permission`、`gameFiles`、`integrity`、`runtime`、`process`、`solution`、`persistence`、`conflict`、`userCancelled`、`recoveryRequired`。

Domain 错误必须带：

| 字段 | 说明 |
|---|---|
| 目标 | Game、方案、Task 或恢复会话 |
| 阶段 | 排队、授权、校验、准备、修改、进程确认、验证、恢复 |
| 原因类别 | 上述业务类别 |
| 副作用 | `none`、`filesChanged`、`systemChanged`、`processCreated`、`unknown` |
| 结果 | 对应业务 outcome；不能只给 error string |
| 恢复动作 | 唯一推荐下一步和前置条件 |
| 恢复验证 | `notRequired`、`pending`、`verified`、`unconfirmed` |

### 4.3 ViewModel 投影

ViewModel 只把 Domain error 投影成 UI 已冻结的事实：

- 权限错误 → 重新选择/授权，不显示文件损坏。
- manifest 不支持 → `IntegrityUnsupported`，不显示校验失败或通过。
- 进程创建成功但确认超时 → 游戏未启动，先等待清理确认。
- 持久化失败 → 数据未确认/恢复待处理，不显示已保存。
- 用户取消 → 只有清理/回滚确认后显示 `cancelled`。

### 4.4 Wine 来源错误映射

- HTTP 429：Infrastructure 保留 status、`Retry-After` 和来源 ID；Domain 映射为 `networkFailure/rateLimited`，不无限自动重试，不请求用户 token。
- API 403 映射为 `apiForbidden`，asset 403 映射为 `assetForbidden`；二者都保留 source/status，不自动换源、不请求用户 token。
- 有效空目录：映射为 `noAvailableManagedVersion`，不是网络失败，也不是“检测失败”。
- 响应 schema、release tag、asset、架构或 allowlist 身份不一致：映射为 `catalogInvalid`，不能切换到未经批准的镜像。
- 当前用户选择的来源失败不自动切换到另一个 source；用户必须主动选择 allowlist source。镜像 API 成功也不能替代 Release asset bytes 的独立验证。

### 4.5 本地版本证据错误映射

- `pkg_version`：按 JSON Lines 解析，条目字段使用 `remoteName/fileSize/md5`；非空、格式和目标位置关联必须先验证。
- `config.ini`：只读 `[General]` 的 `game_version/channel/sub_channel/cps/sdk_version`；`wpf_version` 不产生 Domain 事实。
- `pkg_version`、`config.ini`、manifest 或官方版本冲突：映射为 `versionEvidenceConflict`，保留旧可信状态，不发布 `current`、`IntegrityPassed` 或 `Running`。
- 证据缺失/无法解析：版本检测为 failed，完整性为 `IntegrityUnsupported` 或执行失败，不能用文件存在或版本字段冒充完整。

## 5. security-scoped bookmark 通信

### 5.1 定位流程

1. UI 通过 ViewModel 请求系统目录选择。
2. ViewModel 把用户选中的 URL 交给 Domain 定位命令，不把 URL 作为长期状态保存。
3. `GameFileSystemRepository` 创建读写能力匹配的 bookmark，并返回 bookmark record。
4. Domain 在 scoped access 内验证目录、识别 exe，必要时启动完整性任务。
5. `GameRegistry` 仅在授权和业务验证结果可信后提交 location/state。
6. `PersistenceStore` 原子保存；提交成功后发布 `permissionChanged/gameChanged`。
7. 任何一步失败都保留旧记录，释放 scope，发布失败/重新授权事实。

### 5.3 stale bookmark 统一状态流

```text
stored resolvable
  → resolving with security scope
  ├─ resolve/access failed → accessDenied/resourceUnavailable
  └─ resolved
       ├─ fresh → commit resolution if metadata changed → consumer operation
       └─ stale → recreate bookmark in active scope
                    → persist refreshed GameLocation
                    ├─ commit verified → consumer operation → consumer result commit
                    └─ commit failed → bookmarkRefreshPersistenceFailed + recoveryRequired
```

所有消费者必须使用同一 `ScopedGameLocationAccess`，不能只取 resolved URL。`FileIntegrityVerifier`、`VersionChecker`、`PreLaunchValidator` 和 `LaunchOrchestrator` 在 stale 刷新未提交前不得发布自己的完成或业务成功结果。重试创建新的 UserIntent/Task；若恢复记录未收敛，先执行 bookmark 恢复或要求用户重新选择。

### 5.2 访问作用域

- bookmark 解析失败不能 fallback 到 `lastKnownPath`。
- stale bookmark 可以用于本次读取验证，但必须立即替换；替换失败进入 `migrationRequired`。
- 游戏目录写入必须使用真实读写 scope。当前 read-only entitlement 下，方案若涉及游戏目录写入直接为 `Unavailable`。
- 进程启动所需的工作目录和 exe 访问必须覆盖在同一有效 scope 生命周期内；进程退出确认前不能提前释放会导致子进程失去访问的资源。

## 6. 系统权限边界

### 6.1 游戏目录

普通 App Sandbox + 用户选择 bookmark 负责游戏目录。它只授权声明的目录，不提供 root，不授权系统文件。`GameFileSystemRepository` 必须拒绝目录外的路径逃逸、符号链接越界和未声明资源。

### 6.2 `/etc/hosts` 与 hostname

系统修改是独立的 Infrastructure 边界：

- Domain 传入结构化操作 ID、目标类型、预期变更和快照摘要，不传任意命令字符串。
- `SystemModificationGateway` 当前只允许条件发布的 hostname 操作；A-06/hosts 屏蔽本轮 Deferred，不进入 gateway。若平台存在 `/etc/hostname`，它只作为读取/备份证据，不作为任意直接写入目标。
- 普通应用不能因拥有游戏目录 bookmark 而直接写系统路径；沙盒子进程也不获得额外权限。
- 更高权限需要经过签名、受限、可验证的 helper/XPC 机制和用户批准。当前 helper 未完成或用户拒绝时，结果是 `Unavailable`/`Failed`，不是 `Applied`。
- hostname 修改前必须备份，修改后读回验证；任何部分修改转入恢复流程。恢复开始后不可取消。

## 7. Wine 启动通信

```text
WineVersionManager
  → RuntimeSelection（已验证 binary 来源和版本）
LaunchOrchestrator
  → WineRuntimeProvider.preparePrefix
  → LaunchCommand
ProcessManager
  → ProcessCreated
  → ProcessHealthConfirmed / Exit / Timeout
LaunchOrchestrator
  → GameRegistry transition + Task outcome
```

`WineCatalogQuery` 只产生 API/Release metadata 的 CatalogEntry；`WineAssetDownload` 从已验证 CatalogEntry 取得 asset bytes。两个阶段通过 source ID、policy revision 和 release/asset identity 关联，但不合并为一个“下载成功”事实。

启动命令固定为：执行 `wineBinary`，参数 `[gameExecutable] + fixed/performance arguments`，工作目录为游戏目录，环境包含：

```text
WINEPREFIX=<AppSupport>/MiPlay/WinePrefixes/<stableGameID>
WINEDLLOVERRIDES=winemenubuilder.exe=d
```

命令构造不调用 shell，不接受任意环境键。进程创建事件只能推动 `Launching` 的中间阶段；只有运行确认事件推动 `Running`。

进程退出后的通信必须带 session ID 和 termination-confirmed 事实：

```text
ProcessExitEvent
  → LaunchOrchestrator 计算 normal/abnormal target state
  → GameRegistry 提交 Game + exit record
  → PersistenceStore 重读验证
  → committed event
  → 清除 session guard、scope 和 Process reference
```

如果 Game 状态提交失败，Domain 发布 `recoveryRequired` 并保留同 Game lifecycle lock；恢复命令只探测“进程已退出”并重试终态提交，不重新启动游戏。恢复提交成功后，用户才能创建新的 `GameLaunch` Task。重复 ProcessExitEvent 按 session ID 幂等。

应用重启时，Domain 必须先读取 launch session 和 recovery record 再发布 Game 快照。PID 只有与 executable、prefix、启动时间和 session identity 同时匹配才可作为活动进程；否则先建立持久 `restart reconciliation` recovery record，保留同 Game lock。没有已确认退出事实时不得推断正常退出，恢复目标为 `LaunchFailed(interruptedAfterRestart)`；持久化失败时不能只修改内存投影。

## 8. 持久化错误传播

```text
PersistenceStore read/decode
  ├─ missing first run → initialData
  ├─ old schema → backup + migrationRequired
  ├─ corrupt → preserve original + recoveryRequired
  └─ valid → verified snapshot

Domain mutation
  → encode temp
  → decode/validate temp
  → atomic replace
  → re-read verification
  → committed event
```

写入或验证失败时：

- 原始可读文件不被覆盖；临时文件不得被当作正式数据。
- 尚未产生外部副作用的命令直接失败，业务状态不变。
- 已有外部副作用的命令尝试清理/回滚；恢复也失败则 `recoveryRequired`，阻止重复执行。
- ViewModel 展示恢复操作，而不是把内存中的新值继续显示为已保存。

Task 终态提交遵循：`completed` = 业务 outcome + AppData 写入 + 重读验证全部通过；`failed` = 目标未达成且副作用已清理并记录；`recoveryRequired` = Task 仍可为 `failed`，但有未收敛的副作用/状态保护，必须先恢复，不能作为 completed 或可重试成功使用。

### 8.1 LogWriter 错误传播

Domain 将已确定的业务事实转换为安全 LogEvent 后提交给 `LogWriter`。LogWriter 的 `logFlushFailed`、`logExportFailed` 或脱敏拒绝只返回日志维护错误；它们不回滚、阻止或改写前一条 Game/Task/solution/Persistence 结果。用户导出必须通过 `LogExport` task，不能由 ViewModel 直接调用 Infrastructure。

## 9. Actor 到 ViewModel 的隔离

- Actor 返回 `AsyncSequence<DomainEvent>` 或快照，ViewModel 在自己的 `@MainActor` 任务中消费。
- 事件消费任务只调用 ViewModel 的主 Actor 方法，不从 Domain 回调直接触碰 SwiftUI。
- 订阅取消、Domain stream 结束和 ViewModel 销毁都必须结束消费任务；流结束显示为状态来源不可用，不是成功。
- 错误通过值返回/抛出到调用者，再由 ViewModel 投影；不存在“Domain Actor 直接设置 ViewModel 属性”的反向引用。

### 9.1 AccessibilityProjection 所有权

`AccessibilityProjection` 不是 Domain 状态，也不由 View 计算。每个 `@MainActor` ViewModel 根据结构化 Domain snapshot/event 生成自己的本地化 label/value/hint/action/busy projection；SwiftUI View 只把 projection 附加到已有 Button、Progress 和 status 节点。

| 投影 | 所有者 | 必须包含 | 禁止来源 |
|---|---|---|---|
| 游戏卡片/主操作/启动进度/错误恢复 | `LibraryViewModel` | Game ID、选中态、业务态、Task status/phase、真实 progress、side effect、唯一 recovery action | 颜色、hover、状态点、Process 创建 |
| Wine 目录/source/download | `SettingsViewModel` | `RuntimeSourceResult`、source identity、403/429/认证/空列表反馈和 Task 事实 | 系统 Wine 路径、外部 runtime 或任意 URL 推断为可用 |
| 路径授权/本地证据 | Path/Library 对应 ViewModel | fresh/stale、刷新提交、证据来源、重新授权动作 | `lastKnownPath`、文件存在推断授权 |
| 兼容方案 | `GameDetailViewModel` | Applying/Applied/RolledBack/Failed、恢复和不可取消事实 | 备份成功、颜色或命令返回 |

Projection 只存在内存中；业务事实和恢复事实由 Domain 持久化。事件提交失败或字段不完整时，ViewModel 投影为“无法确认/当前不能重试”，不得自行补成成功。
