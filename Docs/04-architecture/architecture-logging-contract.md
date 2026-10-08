# MiPlay 日志服务契约

> **文档状态**：已冻结（Architecture Task 3）
> **更新日期**：2026-08-04
> **职责边界**：冻结日志事件、隐私、串行写入、flush、导出和依赖边界；不定义 Swift 实现。
> **上游**：Product 日志导出范围、Research 的 `Logger.shared`/OSLog 参考、App Sandbox/网络/取消事实和现有 `LogWriter`。
> **下游**：Implementation 只能在本契约内补充现有 `LogWriter`；日志失败不得改变 Domain 业务结果。

## 1. 决策和范围

1. 继续使用现有 `Infrastructure.LogWriter` actor。它继续负责 OSLog、内存缓冲、文件轮转、flush、导出和清理；不新增通用日志框架、全局 logger 单例或跨产品日志协议层。
2. 必要补充只有一项：在现有 `LogEntry` 写入边界增加结构化、可脱敏的事件上下文，并保留现有分级 API 作为兼容入口。新调用优先记录事件名和结构化上下文，不把 Domain 自由拼接的业务句子当作事实字段。
3. 日志是 Infrastructure 的可观察性副作用，不是 Domain 状态、任务 outcome、持久化提交或权限证明。日志写入、flush 或 export 失败不能把已成功的业务改为失败，也不能把失败改为成功。
4. UI / ViewModel 不直接依赖 `LogWriter`。用户导出日志通过 `UI → ViewModel → Domain LogExport → Infrastructure.LogWriter`；ViewModel 只消费导出结果和状态投影。

## 2. 分层与依赖边界

```text
SwiftUI View
  → @MainActor ViewModel
    → Domain UserIntent / LogExport task
      → LogWriter actor
        → OSLog + App Support log files
```

### 2.1 允许和禁止的依赖

| 调用方 | 允许方式 | 禁止方式 |
|---|---|---|
| UI | 读取 ViewModel 的日志导出状态、触发导出意图 | 直接持有 `LogWriter`、读取日志目录、拼接或过滤 Domain 日志 |
| ViewModel | 向 Domain 提交 `LogExport`、接收 `LogExport` snapshot/outcome | 直接调用 `LogWriter`、`OSLog`、`FileManager` 或把日志成功当业务成功 |
| Domain service | 通过组合根注入同一 `LogWriter`，提交安全事件；把 task/game/operation context 传给日志边界 | 访问日志文件、OSLog、路径、bookmark Data；等待日志成功才提交业务状态 |
| Infrastructure service | 在自己的阶段边界记录安全事件，使用同一 LogWriter actor | 依赖 ViewModel、改变 Domain 状态、写入未经脱敏的错误/命令/URL |
| `LogWriter` | 只依赖日志存储所需的 Infrastructure 文件边界和 OSLog | 回调 Domain、调用 TaskScheduler、修改 Game/Task/Persistence 状态 |

`LogWriter` 可以使用现有文件系统服务取得 App Support `Logs` 目录，但该目录能力必须是日志专用的、容器内的、不可把游戏 bookmark 或系统路径传入的边界。若文件系统服务自身记录日志，不能形成 LogWriter ↔ 文件系统的循环调用。

### 2.2 日志与 Domain 事件的关系

- DomainEvent 是业务事实；LogEvent 是诊断记录。二者可以有相同的 `taskID`、`gameID` 和 `operationID`，但互不替代。
- Domain 先按自身契约提交 Game/Task/Persistence 状态，再记录终态日志；日志失败不能阻止 committed DomainEvent。
- 需要诊断的“提交前”事实可以记录，但不能写成 `completed`、`Applied`、`Running` 或 `Installed`。
- LogWriter 不发布 DomainEvent、不修改 Task.status、不创建 recoveryRequired；它只能报告自己的 `flush/export` 错误给调用方。

## 3. 日志级别

现有四个级别继续使用，级别不是用户可见业务状态：

| 级别 | 记录条件 | 典型内容 | 禁止误用 |
|---|---|---|---|
| `DEBUG` | 调试阶段、输入已规范化、阶段细节 | 阶段进入、计数、耗时、过滤后的状态摘要 | 不记录原始参数、路径、stdout 或凭据 |
| `INFO` | 正常接受、开始、完成或用户可观察的生命周期节点 | task accepted、source selected、process confirmed、export completed | 不把“请求已发出”写成业务成功 |
| `WARNING` | 可恢复异常、过期缓存、取消未完成、结果暂不可确认 | retryAfter、stale、旧记录保留、日志 flush 重试 | 不吞掉错误，不降低真实失败等级 |
| `ERROR` | 目标失败、权限拒绝、持久化失败、异常退出、恢复保护 | error category、phase、result、recovery fact | 不记录敏感错误文本，不自行改变业务结果 |

`ERROR` 表示诊断事件严重，不自动等于 `Task.failed`；具体 Task/Domain outcome 仍由对应服务提交。

## 4. LogEvent 数据契约

### 4.1 必填字段

每条进入 OSLog 或文件缓冲的事件必须先经过同一安全化边界，并至少具有以下字段：

| 字段 | 类型/规则 | 语义 |
|---|---|---|
| `eventID` | 单次事件唯一 ID | 用于去重、测试断言和关联导出记录 |
| `timestamp` | UTC 时间 | 事件产生时间，不是 flush 时间 |
| `level` | 四级之一 | 诊断严重性 |
| `module` | 固定 allowlist 模块名 | 例如 `TaskScheduler`、`LaunchOrchestrator`、`LogWriter` |
| `eventName` | 固定事件名 | 测试和检索使用；不得用自由文本代替 |
| `operationID` | 每次用户/Domain 操作的稳定 ID | 没有 Task 的查询、启动初始化和导出也必须有 operation ID |
| `phase` | 当前阶段枚举 | 例如 `queued`、`validating`、`flushing`、`exporting`、`recovering` |
| `result` | 允许的结果值 | `accepted`、`started`、`inProgress`、`completed`、`failed`、`cancelled`、`rejected`、`unavailable`、`recoveryRequired`、`unknown` |
| `errorCategory` | 正常事件为 `none`；warning/error 必须分类 | 不使用未经分类的 `localizedDescription` 代替 |
| `messageCode` | 稳定、可本地化的安全代码 | 不把带插值的用户句子作为结构化事实 |

### 4.2 统一关联上下文

以下字段按操作类型必须出现；未知时使用明确的 `absent` 事实，不填充虚假值：

| 上下文字段 | 必须出现的操作 | 规则 |
|---|---|---|
| `taskID` | 所有 TaskScheduler 接受、执行、取消、终态和恢复事件 | 与 TaskReceipt/task snapshot 相同；非任务事件不制造 task ID |
| `gameID` | Game、路径、metadata、启动、方案、背景和 per-game settings 操作 | 使用固定 Game ID，不记录安装路径或显示名推断 |
| `wineTag` | Wine catalog/source/download/runtime/prefix 操作 | 只记录已验证或 allowlist 内 tag；未知 tag 记为 `redacted` |
| `operationID` | 所有事件 | 跨阶段保持不变；重试创建新 operation ID，并通过 `parentOperationID`（如需要）关联 |
| `phase` | 所有事件 | 必须描述事件发生阶段；不能用 `module` 代替 |
| `result` | 所有事件 | 表达本条事件的结果，不等于业务成功 |
| `errorCategory` | 所有 warning/error、取消未确认和恢复事件 | 正常事件为 `none`；不得把错误信息藏在 message 中 |

允许的附加诊断字段仅限安全标量和有限枚举，例如 HTTP status、retryAfter 秒数、字节数、条目数、退出码/信号、attempt count、revision 和 `redacted=true`。附加字段必须有固定名称和类型；不接受任意字典或任意用户字符串。

### 4.3 错误分类

日志分类必须能覆盖当前 Domain/Infrastructure 错误，但不创建第二套业务状态：

`permissionDenied`、`bookmarkStale`、`networkUnavailable`、`apiForbidden`、`assetForbidden`、`rateLimited`、`resourceNotFound`、`catalogInvalid`、`integrityFailed`、`integrityUnsupported`、`processStartFailed`、`processTimedOut`、`processExitedAbnormally`、`terminationUnconfirmed`、`userCancelled`、`cancellationUnconfirmed`、`conflict`、`persistenceCorrupted`、`migrationFailed`、`writeFailed`、`logFlushFailed`、`logExportFailed`、`recoveryRequired`、`unknown`。

错误事件必须同时记录 `operationID`、适用的 `taskID/gameID/wineTag`、`phase`、`result`、`errorCategory` 和安全恢复事实。例：asset 403 是 `phase=downloadingAsset`、`result=failed`、`errorCategory=assetForbidden`，不能只记录“下载失败”。

## 5. 隐私和路径脱敏

### 5.1 允许记录

- 固定 Game ID、已批准 Wine tag、source ID、task/operation/event ID、phase/result/errorCategory。
- HTTP status、`Retry-After` 秒数、响应/文件大小、数量、耗时、退出码或信号编号。
- 资源版本、manifest revision、schema revision、AppData revision 和日志文件轮转编号。
- 固定的 `messageCode`、模块名和安全的恢复动作代码。

### 5.2 必须过滤或禁止记录

在 OSLog、内存缓冲、文件日志和导出之前都必须过滤，不能只在 export 阶段脱敏：

- security-scoped bookmark Data、bookmark URL、完整游戏路径、用户 home、prefix 路径、临时文件路径、日志文件绝对路径和任意路径字符串。
- Release/API/asset 完整 URL、query、redirect Location、cookie、Authorization、个人 token、签名、header 内容和任意用户输入 URL。
- `WINEPREFIX`、完整 Process command line、环境变量值、Wine binary/exe 绝对路径、stdout/stderr、shell 命令和 helper 请求原文。
- `config.ini` 原始 value、账号/设备标识、用户选择的文件名、完整错误文本和可能包含路径的 `localizedDescription`。
- 通过字符串插值拼入上述值的 message、details 或日志标签。

路径、URL 或未批准 tag 一旦进入调用参数，安全化边界必须替换为固定标记（如 `<redacted-path>`、`<redacted-url>`、`<redacted-value>`），并记录 `sanitizationApplied=true`；无法安全化时拒绝该事件并产生不含原值的 `logSanitizationRejected` 诊断事实。不得用 hash 让敏感原值可被离线猜测。

日志导出仍是已脱敏副本，不是原始调试转储。导出失败时不得返回包含未过滤缓冲的 fallback 文本。

## 6. LogWriter Actor 生命周期

### 6.1 记录

`record(LogEvent)` 在 LogWriter actor 内完成：校验固定字段 → 脱敏/拒绝敏感值 → 分配事件序列 → 写入 OSLog → 追加内存缓冲。事件序列只由 LogWriter 生成，按 actor 内接受顺序单调递增；OSLog 成功和内存接受不代表文件已持久化。

自动 flush 继续使用现有的缓冲阈值和文件轮转配置（当前阈值 50 条、单文件约 5 MB、保留 3 个备份），但自动 flush 失败不得用 `try?` 静默丢失：未提交批次必须留在 actor 缓冲中，并记录安全的 `logFlushFailed` 状态。业务调用方不因自动 flush 失败而失败。

### 6.2 Flush

| 项目 | 契约 |
|---|---|
| 输入 | LogWriter 当前 actor 缓冲和可选的 flush reason；不接受路径、业务状态或任意文件目标 |
| 成功输出 | `flushedThroughSequence`，表示该序列及之前批次已写入并验证；缓冲移除只发生在成功确认后 |
| 失败输出 | `logFlushFailed`、未提交条目数量、阶段和可重试事实；旧日志文件和内存批次保留 |
| 取消 | 写入开始前可取消并保留批次；文件替换/append 开始后等待文件操作结束，确认写入或旧文件保留后才能返回；不能把取消请求当作 flushed |
| 恢复 | 由调用方稍后显式重试；重复 flush 必须按批次/序列幂等，不重复产生业务事件 |
| 权限 | 只能写 App Support `Logs`；不使用游戏 bookmark、系统路径或 helper |
| 用户反馈 | 普通业务流程不因 flush 失败弹出业务错误；用户请求导出时才投影“日志暂未保存/导出失败” |

显式 flush 是持久化屏障：调用方收到成功前，不能声称日志已落盘。flush 失败不回写 Domain，不改变 Task/solution/Game outcome。应用退出或进入后台时由应用协调边界发起 best-effort flush；进程被强制终止造成的未 flush 日志丢失只产生诊断风险，不改变业务事实。

### 6.3 Export

用户可见导出通过 `LogExport` Domain task：

```text
UserIntent(LogExport)
  → TaskReceipt(pending)
  → flush barrier
  → read current log + rotated backups
  → verify order and apply redaction
  → RedactedLogBundle
  → committed export outcome
```

| 项目 | 契约 |
|---|---|
| 输入 | operation ID、可选 Game/task filter、导出目标能力和取消信号；默认范围是启动相关日志，不接受任意日志目录 |
| 成功输出 | 已 flush 的、按时间/序列排序、重新脱敏的 `RedactedLogBundle` 或用户选定目标中的已验证文件；结果可关联 task/operation |
| 空结果 | `completed + empty`，不是失败；UI 显示没有可导出记录 |
| 失败 | flush、读取、解码、排序、脱敏、目标写入或权限失败为 `failed + logExportFailed`；不返回未过滤或不完整的“成功”文本 |
| 取消 | 读取/生成阶段可取消；丢弃未提交导出临时结果，不删除或改变已有日志和业务状态 |
| 恢复 | 重试同一导出意图或重新选择用户目标；不修复 Game/Task，不重新执行原业务操作 |
| 权限 | App Support 日志只读；用户选定导出目标必须走明确的用户授权；不通过 shell、sudo 或游戏 bookmark 扩权 |
| 用户反馈 | `pending/running/completed(empty)/failed/cancelled` 由 ViewModel 投影；“日志已导出”只表示导出 bundle 成功，不表示原业务成功 |

导出读取当前日志前必须执行 flush barrier。导出不清除日志，不改变轮转文件，不把日志导出成功写成 Domain 的 `completed` outcome。

### 6.4 轮转和失败恢复

- 轮转只在当前文件达到大小门槛时发生；轮转失败保留当前文件和未提交批次，结果为 `logFlushFailed`，不删除旧日志。
- 文件 append/write、目录创建、编码、解码或读取失败必须留下原文件、未提交批次和可重试状态；不以空文件覆盖旧日志。
- 日志目录不可写、磁盘不足、文件损坏和导出目标拒绝都属于 LogWriter 自身错误；不能创建 `recoveryRequired` 来阻塞 Game/Task，除非业务 Domain 自己另有恢复事实。
- 清理日志是显式维护操作，不由自动恢复触发；清理失败只影响日志维护结果，不删除 AppData、任务记录或恢复记录。

## 7. 关键流程日志覆盖

日志记录的是事实边界，不要求每次进度回调都写一条日志。每个关键流程至少记录开始、关键转换和终态；终态事件必须使用对应的 `result/errorCategory`。

| 流程 | 必须记录的事件 | 终态要求 |
|---|---|---|
| TaskScheduler | accepted、pending committed、running committed、phase transition、cancel requested、terminal commit | Receipt/状态持久化失败要记录 `writeFailed`；不能只记录 UI 点击 |
| Wine Catalog | source selected、API response classification、empty/403/429/schema result | source ID、status、retryAfter；不记录 URL/token，不自动换源 |
| Wine asset | catalog entry validated、download start/progress summary、asset verify、extract、installed record commit | 取消必须记录 cleanup verified/unconfirmed；artifact 未安装不能记录 ready |
| Game launch | preflight、prefix preparation、process created、health confirmed、exit observed、exit commit | ProcessCreated 不是 Running；超时/异常退出/退出提交失败分别记录并关联 recovery |
| Restart reconciliation | startup scan、identity matched/unmatched、guard created、terminal commit/retry | 无可信进程不得记录正常退出；`recoveryRequired` 必须在提交失败时出现 |
| Bookmark | resolve fresh/stale、scope start/stop、refresh candidate、writeback/readback、access denied | stale 写回失败不得记录 consumer success；日志不含 bookmark/path |
| Metadata/integrity | config/pkg read classification、manifest association、conflict、integrity outcome | 只记录字段 presence/parse category/hash result，不记录原始 values |
| Solution | capability check、snapshot、modify、readback、rollback | Deferred 只记录 capability `unavailable/Deferred`，不得记录 Applied |
| Background | group load/verify/select commit/failure/cancel | 目标组失败保留上一有效组；不改变 Game 状态 |
| Persistence | read/decode, backup, migration, atomic write, readback | 写入失败记录旧文件保留和恢复动作；不把日志成功当提交证据 |
| Log service | sanitize accepted/rejected、flush start/success/failure、rotation、export start/success/failure | 日志自身失败只能影响日志结果 |

### 7.1 取消、超时、异常退出和 recoveryRequired

- **取消**：记录 `result=cancelled` 只有底层清理/回滚确认后成立；否则记录 `result=failed` 或 `recoveryRequired`、`errorCategory=cancellationUnconfirmed`，并带清理阶段。
- **超时**：记录 `result=failed`、`errorCategory=processTimedOut` 或对应网络/flush timeout、phase、timeout kind 和是否已清理；不得用超时日志替代 Task outcome。
- **异常退出**：记录 termination observed、退出码/信号和 session identity 摘要；未确认退出记录 `terminationUnconfirmed`，不能记录正常退出。
- **recoveryRequired**：记录恢复事实创建、恢复尝试、恢复读回和清除四类事件；包含恢复 ID、目标安全 ID、阶段和下一动作代码，不包含原始副作用路径。
- **日志自身失败**：在 OSLog 中写入最小安全诊断并保留内存/旧文件状态；不能递归记录同一 LogWriter 错误，也不能改变上述任何 Domain 结果。

## 8. 任务日志与用户可见错误

| 维度 | Task/Domain | LogWriter |
|---|---|---|
| 权威性 | 决定 Task.status、outcome、Game/solution/recovery 状态 | 记录这些事实的诊断副本 |
| 文本 | ViewModel 从结构化错误投影本地化用户反馈 | 使用安全 `messageCode` 和技术分类，不承担本地化 |
| 失败 | 失败可能阻止/恢复业务目标 | 日志失败只影响观察和导出 |
| 重试 | 按 recovery 和权限规则决定新 UserIntent | 只重试 flush/export，不重试原业务 |
| 持久化 | AppData 是业务事实提交点 | Logs 是诊断存储，不能作为业务事实来源 |

用户错误必须来自 Domain outcome/error/recovery；UI 不能根据日志行、日志数量、flush 是否成功或 OSLog 状态猜测业务状态。导出日志可作为用户恢复动作，但不能是“已修复”的证明。

## 9. 测试捕获 seam

测试不读取系统 Console，也不依赖真实用户 Home 或真实游戏路径。组合根为 `LogWriter` 提供以下最小测试边界：

1. 使用临时 App Support `Logs` 目录，验证 actor 串行顺序、flush barrier、5 MB 轮转和导出排序。
2. 通过 LogWriter 的事件记录边界捕获脱敏后的 LogEvent，按 `eventName/operationID/taskID/gameID/phase/result/errorCategory` 断言，不按本地化 message 或时间字符串断言。
3. 注入可控的目录创建、写入、读取、轮转和导出目标失败，验证 `logFlushFailed/logExportFailed`，并验证 Domain outcome 不变。
4. 构造包含路径、bookmark Data、URL、token、环境变量、stderr 和 `localizedDescription` 的输入，断言 OSLog/file/export 三个出口都不包含原始值。
5. 运行 Task 取消、Process timeout/abnormal exit、重启 recovery、stale bookmark writeback failure、metadata conflict、Wine 403/429/empty 和 Deferred capability 场景，断言关键事件存在且上下文完整。
6. 测试 LogWriter 自身 flush 失败时不递归、不死锁、不丢弃未提交批次；测试重复 flush/export 是稳定且不产生重复业务事件的。

测试捕获 seam 是 Infrastructure 的测试组合配置，不向 UI 暴露、不成为第二个生产日志框架，也不允许测试绕过 Sandbox 权限边界。

## 10. Review 问题覆盖矩阵

| Issue | 日志覆盖要求 | 不可替代的业务证据 |
|---|---|---|
| `P1-REV-001` | WineRuntimeSetup 固定目标、URLSession/解压/Wine 子进程/共享 prefix lease 的取消传播和最终 cleanup fact | Task cancelled/recoveryRequired 的 Domain 提交 |
| `P1-REV-002` | runtime/prefix pair staged、记录 write/readback、completed 被拒绝或提交 | 固定 runtime 与 shared prefix 记录的持久化和重读 |
| `P1-REV-003` | Process exit、termination identity、退出终态提交失败、guard/recovery/retry | GameRegistry 终态和 restart reconciliation |
| `P1-REV-004` | 五个 bookmark 消费者的 stale resolve、writeback、readback、scope release 和失败 | 新 bookmark 持久化和消费者 outcome |
| `P1-UV-001` | Managed Wine policy rejection/absence 可诊断，但不创建外部 Wine 事实 | 无 system Wine detection/fallback |
| `P1-UV-002` | 固定 source/entry 的 API/asset 403、429、网络和内容失败；无自动换源或用户改选 | fixed catalog entry、asset 内容与来源验证 |
| `P1-UV-003` | metadata parse、manifest association、unknown/conflict 分类；禁止原始 config/pkg 值 | `GameMetadata` evidence 和 IntegrityManifest |
| `P1-UV-006` | 记录 AX 相关 Domain 状态事实是否可投影；不把日志当 AX tree 证据 | ViewModel AccessibilityProjection 和真实 AX 验证 |
| `DOC-REV-001` | 导出内容不得包含旧的成功口径或敏感值；事件字段必须引用当前术语 | Architecture/Domain/QA 完成口径 |

## 11. 实现验收

- 所有关键错误日志可通过 `operationID` 关联，并按任务类型补齐 `taskID/gameID/wineTag`；没有上下文的自由文本错误不视为覆盖。
- `flush` 成功表示批次已落盘并验证，`export` 成功表示已脱敏 bundle 可读；两者均不改变 Domain 状态。
- 日志目录、文件轮转、导出目标均留在 Sandbox 允许范围；不以日志功能要求额外权限。
- 任何日志异常都能被捕获、分类、重试或展示为日志维护失败，而不会反向写入 Game/Task/solution。
- UI 只经 ViewModel 触发 `LogExport` 和消费其投影；源码中已有的 ViewModel → `LogWriter` 直连属于下游实现偏差，必须回溯本 Architecture 修正。
