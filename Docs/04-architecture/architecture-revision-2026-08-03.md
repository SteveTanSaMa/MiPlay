# MiPlay Architecture Revision 2026-08-03

> **文档状态**：已冻结（Architecture Phase 3）
> **适用范围**：本文件是本目录对 Product、Research、UX、UI 修订结果的当前解释。
> **职责边界**：冻结系统组织、数据事实、状态传播、权限和服务契约；不定义 Swift 实现。
> **下游规则**：Implementation、Review、QA 和 Release 不得用旧 Architecture 文档解释本文件未覆盖的行为。契约问题必须回溯 Architecture；本 Task 不修改业务源码。

## 1. 冻结结论

1. Wine 运行时只有 MiPlay 托管的 `ManagedWineRuntime`。本机 Wine、Whisky、CrossOver 和任意用户路径不检测、不展示、不导入、不复用，也不能作为失败时 fallback。
2. 官方 GitHub 是默认来源；用户可以主动选择 Product allowlist 中的预置可信镜像。用户不能输入 URL、host、token 或任意 header。来源失败不自动切换另一个来源，必须由用户主动改选预置来源。
3. Wine API 目录发现、Release metadata 解析和 Release asset 下载是三个不同的 Domain 阶段。API 200、asset URL、302 或下载进度都不能单独产生 `WineReady`。
4. `config.ini` 是原始本地证据展示；`pkg_version` 是 JSON Lines 文件级证据。未知字段、单独版本值和空/不对应 manifest 不得被提升为可信版本或完整性事实。
5. Game metadata、背景组选择和设置展示状态按 `Game ID` 隔离持久化。全局 Wine source selection 不进入 `PerGameSettings`。
6. 六项高级配置（A-01 至 A-06）仍属于当前版本目标，但本轮全部 `Deferred`。Deferred 没有 toggle、apply task 或 `Applied` 记录。
7. `Task.status` 仍只有 `pending/running/completed/failed/cancelled`。`recoveryRequired`、`RuntimeSourceResult`、metadata evidence 和 AccessibilityProjection 不是新的 Task 或 Game 状态。
8. Domain 事件只在业务事实及其持久化提交、重读验证完成后发布。`@MainActor` 只属于 ViewModel/UI；Domain 和 Infrastructure 的共享可变状态由各自 Actor 隔离。

## 2. 上游逐项追溯和影响分析

| 冻结输入 | Architecture 承接 | 主要影响边界 |
|---|---|---|
| Product：仅 Managed Wine；删除系统 Wine detection | RuntimeCatalog 只接受 ManagedWineRuntime；移除 Wine 观察、状态和选择依赖 | `MiPlayApp` 初始化、`SystemEnvironmentDetector` 的 Wine API、`WineVersionManager`、`SettingsViewModel`、`PreLaunchValidator`、`SolutionEngine` |
| Product/Research：GitHub 默认、allowlist 镜像可主动选择 | `WineSourceSelection` + 固定 SourceDescriptor；无自动 fallback、无任意 URL | `WineCatalogQuery`、`WineAssetDownload`、`NetworkDownloadProvider`、Settings 来源投影 |
| Research：API、Release asset 和镜像证据必须分离 | 目录 query 只读取 metadata；asset download 只接受已验证 CatalogEntry | `WineVersionManager`、`WineVersionDownloader`、catalog/cache 记录和错误映射 |
| Product/Research：`pkg_version`、`config.ini` 只是分离证据 | `GameMetadata` / `LocalGameEvidence` 不产生未知字段含义；manifest 是完整性门槛 | `GameRegistry`、`FileIntegrityVerifier`、`VersionChecker`、metadata ViewModel |
| Product/UX/UI：按 Game ID 保存设置和多背景组 | `PerGameSettings`、`BackgroundGroup` 以 Game ID 为聚合边界 | `SettingsViewModel`、`LibraryViewModel`、BackgroundMediaLoad、PersistenceStore |
| Product：日志导出属于 Should/In Scope，不能证明业务成功 | `LogExport` Domain task；导出只产生已脱敏 bundle | `SettingsViewModel`、TaskScheduler、LogWriter |
| Research：使用 OSLog/统一 logger，且 Sandbox/取消/网络错误需可诊断 | 继续使用 LogWriter actor，补充结构化上下文、flush/export 和测试 seam | Domain services、LogWriter、Network/Process/Persistence consumers |
| Product：六项高级配置本轮 Deferred | Capability read 结果为 Deferred；不得入队、写 Applied 或显示可应用入口 | `SolutionEngine`、`PerformanceOptionManager`、Game detail/settings projections |
| Review P1-REV-003 | restart reconciliation 先建立 recovery guard，再幂等提交退出终态；不自动重启 | `LaunchOrchestrator`、`ProcessManager`、`GameRegistry`、PersistenceStore、TaskScheduler |
| Review P1-REV-004 | 五个 bookmark 消费者共享 resolve/refresh/writeback/readback lease | `GameFileSystemRepository`、`GameRegistry`、完整性、版本、PreLaunch、Launch |
| UI：Accessibility Tree 必须表达状态事实 | 对应 ViewModel 生成 AccessibilityProjection；UI 不推断状态 | `LibraryViewModel`、`SettingsViewModel`、`GameDetailViewModel` 和路径流程 ViewModel |

### 2.1 删除系统 Wine detection 的完整范围

本版本 Architecture 不定义任何外部 Wine runtime detection 状态或相似事实。以下边界必须同时删除或断开：

- App 启动初始化不扫描 PATH、常见安装目录、Whisky bottle、CrossOver bottle 或系统 Wine binary。
- `SystemEnvironmentDetector` 不再由 Domain 注入 WineVersionManager，也不再提供 Wine 版本、路径或“检测到外部 runtime”的结果；若该基础设施文件因其他 macOS 能力暂时保留，其输出不能进入 RuntimeCatalog、Settings 或启动判定。
- `RuntimeSourceResult`、`RuntimeSelection`、`WineReady` 和 `PreLaunchValidator` 不接受外部 Wine 值。
- Settings 不显示外部 Wine、导入、使用或 fallback 行；没有 Managed Wine 时只显示 `WineNotReady` 和来源/下载恢复动作。
- Wine 失败不能改变为“外部可用”或触发另一个未选择的来源。实现发现旧调用时应删除调用链，不以兼容字段保留旧行为。

这不是“检测后不使用”的诊断能力，而是删除检测、展示、状态和依赖后的唯一边界。

## 3. 分层与 Actor 隔离

```text
SwiftUI View
  → @MainActor ViewModel（用户意图、投影、AccessibilityProjection）
    → Domain command/query（Sendable 值）
      → Domain owner Actor（Game、Task、Wine、Solution、session）
        → Infrastructure Actor/value service（JSON、bookmark、HTTP、Process、helper）
```

### 3.1 层职责

| 层 | 允许职责 | 明确禁止 |
|---|---|---|
| UI | 渲染 ViewModel 投影、提交用户动作、附加 AX modifiers | 访问 Infrastructure、读取 bookmark/Process、判断业务成功、创建任务状态 |
| ViewModel | `@MainActor` 保存 UI 投影、选择、窗口状态；把 Domain 快照/事件转换为 label/value/hint/action | 写 JSON、组装 Wine 命令、持有 Process、保存 token 或自行修复业务状态 |
| Domain | 业务聚合、规则、任务、状态转换、事务编排和提交后事件 | 依赖 SwiftUI、默认 MainActor、把 UI 文案作为事实、越权访问系统路径 |
| Infrastructure | 外部 I/O、系统 API、进程、网络、JSON、bookmark scope、受限 helper | 决定 Game/Task 业务状态、访问 ViewModel、静默 fallback 或吞错 |

### 3.2 所有权

| 状态/资源 | 唯一所有者 | 观察者 |
|---|---|---|
| Game、GameMetadata、GameLocation、restart guard | `GameRegistry` | Library/Path/GameDetail ViewModel |
| Task、TaskReceipt、资源锁、取消事实 | `TaskScheduler` | 对应 ViewModel |
| Managed Wine 目录、source selection、安装事实 | `WineVersionManager` | Settings/Library ViewModel |
| 方案应用与恢复记录 | `SolutionEngine` | GameDetail ViewModel |
| JSON 字节、备份、schema 迁移 | `PersistenceStore` | 只通过 Domain 快照/结果间接观察 |
| Process、PID、termination fact | `ProcessManager` | LaunchOrchestrator |
| 当前选中 Game、窗口/tab、AX projection | 对应 `@MainActor` ViewModel | SwiftUI View |

所有者只发布不可变快照和事件。ViewModel 不保存第二份可写 Domain 对象；订阅取消不改变最后一个可信 Domain 事实。

## 4. Managed Wine 服务契约

### 4.1 运行时领域记录

`ManagedWineRuntime` 必须能从持久记录独立验证来源、内容和安装身份，至少包含：`runtimeID`、产品批准 `sourceID`、source policy revision、release/tag identity、asset identity、目标架构 `arm64`、相对安装根、Wine binary 相对路径、已验证的 size/digest/签名事实、安装 revision 和 last verified time。绝不把裸 binary path 当作 runtime identity。

`RuntimeSelection` 只保存一个已经提交、重读验证的 `runtimeID`。`WineReady` 要求 artifact 内容、安装目录、安装记录、prefix 准备和重读都成功。

### 4.2 来源选择与 allowlist

`WineSourceSelection` 是全局状态：默认 `officialGitHub`，或用户从预置 `approvedMirror:<id>` 中主动选择一个。SourceDescriptor 固定 source ID、HTTPS API endpoint、Release metadata endpoint 规则、asset URL host/path allowlist、支持架构、认证模式（当前无用户凭据）和 policy revision。

| 输入 | 输出 | 规则 |
|---|---|---|
| 默认/用户选择 source ID | 已提交 source selection | 只接受当前 Product allowlist；写入并重读后才更新 Settings；不接受 URL、host、token |
| source failure | source-specific failure | 保留上一有效选择；不自动换源；用户可主动重新选择另一个预置 source |
| redirect | validated resolved URL | 只允许仍在该 SourceDescriptor allowlist；跨 host 或未知 redirect 是 invalid |
| source policy 更新 | 新 policy revision | 旧目录和下载结果变为需重新验证，不自动继续执行旧任务 |

成功、失败、取消、恢复、权限和持久化行为：选择成功是 source ID 写回并重读；无效来源或写入失败不改变上一选择；查询可取消但取消不清除上一目录；恢复是重试或主动改选，不自动 fallback；网络只用应用能力，runtime 元数据只写 App Support；用户反馈必须说明来源身份和当前可用动作。

### 4.3 WineCatalogQuery：API / Release metadata 发现

输入是已选 source descriptor、policy revision、目标架构和取消信号。它可以访问 API 和 Release metadata，但不下载 asset body、不创建安装目录、不改变 RuntimeSelection。

输出是 `CatalogSnapshot`：source identity、release identity、allowlist match、asset identity、架构、期望 size/digest/签名声明、抓取时间和结果 revision。有效空列表是 `noAvailableManagedVersion`，不是网络失败。

错误必须区分：

| 错误 | 语义 | 用户恢复 |
|---|---|---|
| API 403 | 当前 source 的 API 被拒绝；记录 status、source、响应摘要和可用 rate-limit 事实；不猜测仓库不存在 | 重试或主动选择另一个预置 source；不要求 token |
| API 429 | 限流；保存 `retryAfter`，不无限自动重试 | 按时间重试或主动改选 source |
| 网络/超时 | source 不可达或请求超时 | 恢复网络后重试/主动改选 |
| schema/identity 不可信 | release、asset、架构或 allowlist 映射不能验证 | 等待策略/应用修复；不能使用条目 |
| 有效空列表 | source 可读但没有匹配托管版本 | 等待新 release 或主动改选 |
| persistence failure | catalog cache 无法提交/重读 | 保留旧缓存为过期诊断，不发布新的可选择目录 |

查询成功只产生可选择的 CatalogEntry，不产生 `WineReady`。查询取消需确认 HTTP stream 已停；取消时不覆盖旧目录。查询失败保留上一有效目录但标记 stale/error，不把旧目录当本次成功。结果写入并重读后才发布 Domain event 和 ViewModel feedback。

### 4.4 WineAssetDownload：Release asset 下载

输入必须是同一 policy revision 下已验证的 `CatalogEntry`、用户选择的 source、目标临时目录和取消信号；不接受裸 URL。下载阶段重新验证 source host/path、release/tag、asset name、架构、expected size/digest/签名和最终 redirect。

输出是 staged artifact 或已提交 `ManagedWineRuntime`。只有归档传输完成、内容验证、解压结构、binary、prefix 规则和 `installedWineVersions` 写回重读全部成功，才是 `completed + installed`。

| 情况 | Task/Domain 结果 | 用户反馈 |
|---|---|---|
| asset 403/404/redirect invalid | `failed + assetForbidden/resourceNotFound/sourceInvalid` | 具体说明 asset 不可用；保留旧 runtime，允许重试或主动改选 source |
| 网络断开/超时/429 | `failed + networkFailure/rateLimited`，记录 retryAfter | 允许重试/改选 source，不伪造完成 |
| bytes/size/digest/signature/结构不符 | `failed + integrityFailed` | 清理 staged 内容，保留旧 runtime |
| 安装或 AppData 提交失败 | `failed` 或 `failed + recoveryRequired` | 清理已验证的 staged 内容；不把 artifact 说成 installed |
| 用户取消 | 仅在 URLSession、解压、清理和 installed 列表读回均确认后 `cancelled` | 显示取消与清理事实；无法确认则 `failed + recoveryRequired` |

下载全局互斥：同版本重复请求复用已有 Receipt；不同版本不排队等待，返回 `conflict(existingTaskID)`。取消由 TaskScheduler 传播到 downloader、URLSession 和解压过程；消费者离开 stream 也必须取消底层任务。下载不自动切换 source。

## 5. Game metadata 和完整性证据

### 5.1 领域模型

`GameMetadata` 归属 `Game ID`，是一次 scoped 读取的不可变快照：`gameID`、location revision、读取时间、原始 `config.ini` section/key/value、`PkgVersionEvidence`、关联 `IntegrityManifestEvidence`、`RemoteVersionEvidence`、证据状态和冲突原因。

| 证据 | 保留内容 | 可信边界 |
|---|---|---|
| `ConfigIniEvidence` | 原始 section/key/value；明确缺失、空值、解析错误 | 仅展示原始字段；不猜 `channel`、`cps`、`sub_channel` 含义，不单独证明版本/完整性 |
| `PkgVersionEvidence` | JSON Lines 每行的 `remoteName`、`fileSize`、`md5`、解析状态和条目数 | 文件清单/候选关联；不单独证明客户端版本、渠道或完整性 |
| `IntegrityManifestEvidence` | Game ID、客户端版本、非空必需条目及每项验证结果 | 只有版本对应且所有必需项通过才可 `IntegrityPassed` |
| `RemoteVersionEvidence` | Product 批准来源、响应身份、版本和抓取时间 | 远程版本候选；不替代本地完整性 |

`wpf_version` 没有当前批准语义，不产生可信 Domain 字段。`game_version`、`remoteName`、manifest 和远程版本冲突时为 `versionEvidenceConflict`；保留上一可信结果，不发布 `current`、`updateAvailable`、`IntegrityPassed` 或 `Running`。

### 5.2 Metadata 服务生命周期

- **输入**：Game ID、统一 bookmark access、只读文件相对路径、取消信号。
- **成功**：原始证据解析、manifest 关联、结果提交并重读成功；UI 可展示证据来源和“候选/已验证”状态。
- **失败**：bookmark stale/权限、文件缺失/空、JSON/INI 解析错误、manifest 缺失/空/不对应、冲突和持久化失败分别保留原因；未知字段不默认成功。
- **取消**：取消读取/哈希/远程查询，保留上一可信 metadata；不写入半成品 evidence。
- **恢复**：重新授权、重新选择目录、获取对应 manifest 或手动重试；不自动修复文件、不写回 config/pkg 文件。
- **持久化**：按 Game ID 保存 evidence 摘要、source、location revision、结果和失败事实；写入失败不发布新的 metadata event。
- **权限/用户反馈**：只读 bookmark scope；ViewModel 展示“原始配置/候选证据/无法确认”，不展示推测语义。

## 6. Per-game settings 和背景组

### 6.1 持久化边界

`GlobalSettings` 保存应用级数据，例如语言、日志偏好、当前 Wine source selection 和 schema/recovery 状态。`PerGameSettings` 以 `Game ID` 为 key，保存 metadata 展示状态、性能/兼容入口状态、当前 `backgroundGroupID` 和该 Game 的失败/恢复事实引用。

Global Wine source selection、Managed runtime catalog、bookmark Data 和活动 scope 不复制进 `PerGameSettings`。同一字段不能同时由 global 和 per-game 记录写入；读取不到或写入失败时不使用静默默认值覆盖已知事实。

每项设置的契约都是：读取成功必须匹配 Game ID 并重读；保存失败保留上一有效值和失败事实；用户取消不改变旧值；恢复只能重试保存/恢复 AppData；权限限于 App Support；ViewModel 反馈“未保存/无法确认”，不把内存值显示成已保存。

### 6.2 BackgroundGroup

`BackgroundGroup` 是一个完整资源单元，至少包含 `groupID`、`gameID`、资源版本、source identity、image/video/theme/decoration 资源身份、类型、size/digest/缓存状态和可用性。不同 Game 不共享可写的当前选择。

| 动作 | Domain 规则 |
|---|---|
| 查询/加载 | 只读 source metadata 和缓存；验证资源身份、类型、完整传输和可渲染性 |
| 选择 | 仅从该 Game 的有效组选择；多组才产生选择投影，单组不产生无意义选择状态 |
| 成功提交 | 目标素材可用，`backgroundGroupID` 写入并重读验证后发布 `BackgroundChanged` |
| 失败 | 保留上一有效组，记录目标组失败原因；不静默切到第三组，不改变安装、完整性、运行或启动状态 |
| 取消 | 丢弃未提交目标选择和未完成临时资源；上一有效组不变 |

背景任务输入/输出/失败/取消/恢复/持久化/反馈：输入是 Game ID、目标 group ID 和取消信号；输出是资源快照或提交后的选择；网络、缓存、decode、写回失败是可区分错误；恢复是重试同组或用户另选有效组；选择写回失败不发布切换成功；反馈说明“当前组仍为上一有效组”。

### 6.3 六项高级配置 Capability

| ID | 本轮 capability 状态 | 任务/持久化规则 |
|---|---|---|
| A-01 Retina | `Deferred` | 只读展示 Deferred；不得 toggle/apply/Applied |
| A-02 Steam patch / 白名单 | `Deferred` | 同上 |
| A-03 旧版反作弊替换 | `Deferred` | 同上 |
| A-04 Metal HUD | `Deferred` | 同上 |
| A-05 左 Command → Control | `Deferred` | 同上 |
| A-06 hosts 屏蔽 | `Deferred` | 同上；不得调用 hosts 修改 gateway |

Capability 查询成功只返回 Deferred；查询数据损坏或缺失返回 unavailable，仍不开放入口；取消只是停止查询，没有 apply 任务；恢复等待后续冻结/实现回溯，不自动重试副作用；不保存 `Applied`、用户 toggle 或伪造完成记录。用户反馈必须明确“当前版本目标，本轮暂不可用”。

## 7. 权限边界

### 7.1 游戏目录 bookmark

`GameLocation` 的 security-scoped bookmark 是唯一可持久授权事实，`lastKnownPath` 只用于显示/迁移提示。五个消费者 `GameRegistry`、`FileIntegrityVerifier`、`VersionChecker`、`PreLaunchValidator`、`LaunchOrchestrator` 必须使用相同 resolve → start scope → stale refresh → writeback → readback → consumer → stop scope 生命周期。

stale 刷新写回失败时保留旧 bookmark/stale 事实并建立 `recoveryRequired`；不能 fallback 到裸 path。取消在 writeback 前发生时丢弃候选 bookmark；scope 必须停止确认后任务才可 cancelled。读写权限按当前 entitlement 检查，不能通过 Process/sudo 绕过。

旧 schema 中的裸 `installPath` 只作为 `migrationRequired` 输入：先备份旧 AppData，保留原始 path 供提示，要求用户重新选择目录并在新 scope 内创建 bookmark；新 bookmark 写入、重读和重启后解析均验证成功后，才解除迁移门禁。迁移或备份失败不覆盖旧文件，也不把裸 path 当作可用授权。

### 7.2 游戏目录、App Support 与系统修改

| 资源 | 允许者 | 失败/取消/恢复 |
|---|---|---|
| 游戏目录读取 | 有效 read bookmark scope 的 Domain 服务 | scope/权限失败不读旧 path；取消不改业务事实 |
| 游戏目录写入 | 只有当前发布能力且有 read-write scope | 未授权为 Unavailable；部分写入必须回滚并读回 |
| App Support/Wine prefix | 对应 Domain service 经 Infrastructure | 原子写入失败保留旧记录；恢复提交前阻止同目标副作用 |
| `/etc/hosts`、hostname | 仅 `SystemModificationGateway` + 受签名 helper；当前 A-06 Deferred | 不接受任意 path/shell；修改后必须读回，取消转不可取消回滚 |

CS-01 hostname 是当前唯一条件发布方案，仍必须满足能力、快照、修改、读回、记录提交和回滚门槛。hosts 屏蔽对应 A-06 Deferred，不因旧入口或 helper 存在而可用。

## 8. 任务、状态事件和跨重启

### 8.1 TaskScheduler / TaskReceipt

入队输入包含 intent ID、kind、target、priority、resource keys、cancellation policy、已验证 context 和 createdAt。成功输出只在 `pending` 记录写入并重读验证后返回 `TaskReceipt`；Receipt 包含 task/intent/target、initialStatus=`pending`、event cursor、resource keys、cancellation policy 和 `persistence=committed`。

后续 `TaskSnapshot` 输出必须包含 status、phase、可选的 0...1 progress、outcome、error、recovery、cancellation policy、时间和 persistence revision。未知进度保持 nil，不能为 UI 伪造百分比；进度事件不改变 Game/Wine/方案业务状态。

WineAssetDownload 持有全局 `wineRuntime` mutex。同版本复用 Receipt，不同版本返回 conflict，不排队多个下载。`pending` 可取消；`running` 取消必须传播并确认 URLSession/解压/清理；清理不确定为 `failed + recoveryRequired`。调度器不直接改变 Game、Wine 或方案业务状态。

### 8.2 终态提交

| 结果 | 提交门槛 | 提交失败 |
|---|---|---|
| `completed` | outcome、相关 AppData 写回和重读均成功 | 不发布 completed；进入 failed 或 recoveryRequired |
| `failed` | 目标未达成、外部副作用已清理/无副作用、失败记录可重读 | 保留恢复保护，不伪造 failed 完成 |
| `cancelled` | 取消处理、清理/回滚和终态提交均确认 | `failed + recoveryRequired` |
| `recoveryRequired` | 持久保护事实，包含目标、阶段、副作用和唯一恢复动作 | 同目标副作用保持禁止；重试持久化 |

`recoveryRequired` 不是第五种 Task status。下载 artifact 在 `installedWineVersions` 提交前是 staged；任何 `markVersionInstalled`/AppData 写入错误不得被吞掉。

### 8.3 Domain event → ViewModel projection

Domain 采用“提交后事件”：持久化变更和重读验证完成后发布带 sequence、aggregate revision 的不可变事件。ViewModel 通过同一 Actor 提供的 snapshot + cursor handshake 订阅：重复丢弃，序列空洞重取快照，payload 冲突以 Domain snapshot 为准。

`LibraryViewModel` 只投影 Game 快照、任务阶段/真实进度、outcome/error/recovery、主操作和背景状态；`SettingsViewModel` 只投影 source/catalog/download、GlobalSettings/PerGameSettings 保存结果、metadata 和 Deferred capability；`GameDetailViewModel` 只投影方案事实。ViewModel 不持有 bookmark Data、WINEPREFIX、Process、token 或可写 Domain 对象。

AccessibilityProjection 属于对应 ViewModel，包含 label/value/hint/action/enabled/busy/announcement。失败或恢复未提交时投影“无法确认/当前不能重试”；UI 不从颜色、hover、状态点、spinner、Process 创建或任务 `completed` 猜状态。

### 8.4 进程退出与重启恢复

启动前先提交 launch session 摘要，再允许创建 Process；健康确认后才提交 Game `Running`。退出处理顺序是 verify termination → 计算目标终态 → 持久化 Game + termination/recovery record → 重读 → 发布事件 → 释放 guard/lock/scope/Process reference。

重启扫描在初始快照前进行：只有 executable、prefix、启动时间和 session identity 全部匹配才接管 `Running`；否则建立持久 restart recovery guard。没有可信退出事实时只能幂等提交 `LaunchFailed(interruptedAfterRestart)`，不能推断正常退出、直接转 Installed 或自动重启。退出终态提交失败时保持同 Game lock；恢复只重试幂等提交，不产生新的启动副作用。

## 9. PersistenceStore 契约

PersistenceStore 只管理 App Support `AppData.json`、可读 `.bak`、诊断副本和 schema 迁移；不读游戏目录或系统路径。输入是带 schema 的 snapshot 和读/写/迁移/恢复命令；输出是重读验证的 snapshot/recovery fact。

- **成功**：临时文件编码、解码验证、原子替换、正式文件重读和 checksum/schema 验证均完成。
- **损坏**：保留原件和诊断副本；可验证 `.bak` 才可 restore；用户明确 fresh start 才能放弃旧业务数据。
- **迁移**：旧裸 path 只能产生 migrationRequired；逐版本迁移，先备份，失败不覆盖旧文件。
- **写入失败**：旧正式文件不变，不发布 committed event；若外部副作用已发生，回滚或建立 recoveryRequired。
- **取消**：原子替换开始后必须完成或确认旧文件保留，不报告半取消；未提交候选丢弃。
- **权限**：仅容器 App Support；不得用游戏 bookmark 代替 AppData 权限。
- **用户反馈**：显示读取/迁移/备份/恢复/写入失败事实，不用默认数据伪装成功。

## 10. 实现影响清单（仅定义任务，不改源码）

| 模块 | 必须收敛的架构变化 | 禁止保留 |
|---|---|---|
| App 初始化 | 装配 Managed Wine services、Persistence recovery 和 startup reconciliation | 启动时 system Wine scan 或外部 Wine state |
| `GameRegistry` | 拥有 GameMetadata、PerGameSettings 索引、BackgroundGroup selection、restart guard | 把 metadata 当单一 version truth；裸 path 授权 |
| `WineVersionManager` | source selection、CatalogQuery/AssetDownload 分离、ManagedWineRuntime 安装提交 | 外部检测、自动 fallback、下载 stream 绕过 scheduler |
| `SettingsViewModel` | 投影 source/catalog/download 和 per-game settings save result | 直接读 JSON、请求 token/任意 URL、展示外部 Wine、Deferred toggle |
| `PreLaunchValidator` | 只接受 ManagedWineRuntime + valid bookmark + evidence/manifest 门禁 + recovery guard | 系统 Wine fallback、PID/ProcessCreated 作为 Running |
| `LaunchOrchestrator` | 固定启动命令和 session/exit commit/reconciliation | 进程退出后先释放 guard；恢复时自动重启 |
| `SolutionEngine` | CS-01 条件发布；A-01..A-06 capability 只读 Deferred | 把源码入口、backup 或 helper 存在当 Applied |
| `PersistenceStore` | schema/backup/migration/atomic readback；终态 commit gate | 吞掉写入错误、默认值覆盖旧事实 |
| `LogWriter` | 结构化事件、统一上下文、脱敏、actor 串行 flush/轮转和 LogExport | UI 直连、敏感值、日志失败改变业务结果、无上下文自由文本错误 |
| `SystemEnvironmentDetector` | 若保留，仅服务非 Wine 的 macOS 能力；从 Wine 依赖图移除 | Wine path/version/availability output |

## 11. P1 修复映射和下游任务

| Issue | Architecture 契约 | Implementation 任务边界 | 验收证据 |
|---|---|---|---|
| P1-REV-003 | §8.4；ADR 014/020 | 退出提交失败保留 guard；启动扫描 exact identity；恢复只提交终态 | 跨重启测试：持久 Running、无进程、退出写入失败、恢复重试、不可自动启动 |
| P1-REV-004 | §7.1；ADR 015/019 | 五个消费者统一 lease；真实 stale refresh/writeback/readback；取消和 denied | fresh/stale success/writeback failure/access denied/cancel + 重启后 fresh |
| P1-UV-001 | §2.1、§4 | 删除 system Wine detection/Settings projection/PreLaunch fallback | 无 scan、无 external state、无 fallback 的依赖扫描 |
| P1-UV-002 | §4.2-4.4 | source selection、API/asset 分离、403/429/empty/mirror failure | 官方与 allowlist source 的 error matrix；不自动切源 |
| P1-UV-003 | §5 | raw config + JSON Lines evidence + manifest gate + conflict | unknown metadata 不可信；冲突/空 manifest 不通过 |
| P1-UV-006 | §8.3 | ViewModel 生成 AX 状态投影 | 游戏卡片、进度、错误恢复的真实 AX tree |
| DOC-REV-001 | §1、§10、§11 | 下游文档移除旧完成口径并引用本文件 | 无 system fallback、PID Running、download Ready、config integrity 旧表述 |

## 12. ADR 索引

本修订新增/更新以下决策，详细记录见 `architecture-adr.md`：

| ADR | 决策 |
|---|---|
| 023 | 删除 system Wine detection 和依赖 |
| 024 | User-selected allowlist source；无自动 fallback |
| 025 | API discovery、Release metadata、asset download 分离 |
| 026 | GameMetadata evidence 与未知字段边界 |
| 027 | PerGameSettings 与 BackgroundGroup 持久化边界 |
| 028 | 六项高级配置 capability 为 Deferred |
| 029 | Managed Wine 启动命令和权限边界 |
| 030 | LogWriter 结构化事件、隐私、flush/export 和依赖边界 |

## 13. 日志契约索引

日志的当前唯一架构口径见 `architecture-logging-contract.md`：

- `LogWriter` 是 Infrastructure actor；事件至少带 operation ID、phase、result、error category，任务相关事件补齐 task/game/Wine context。
- 所有出口在 OSLog、内存、文件和 export 前统一脱敏；bookmark、路径、URL/token、命令、环境、原始 metadata 和错误原文不得记录。
- flush 是日志持久化屏障，export 先 flush 再生成 bundle；二者失败只影响日志维护，不反向改变 Domain outcome。
- 取消、超时、异常退出、restart reconciliation、stale bookmark、metadata conflict、Wine 403/429/空列表和 P1 recovery 均有明确事件覆盖。
- UI/ViewModel 不直连 LogWriter；用户日志导出只能经 `LogExport` Domain task。

本文件与 `architecture-overview.md`、`architecture-domain-model.md`、`architecture-service-contracts.md`、`architecture-state-ownership.md`、`architecture-communication.md`、`architecture-task-queue.md`、`architecture-logging-contract.md` 和 `architecture-adr.md` 冲突时，以本修订后的同名契约和 ADR 作为实现依据；旧段落必须同步删除或标为历史，不得保留第二套有效解释。
