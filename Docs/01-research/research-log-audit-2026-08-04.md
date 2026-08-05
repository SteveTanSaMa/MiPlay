# MiPlay 日志审查与 Apple macOS 日志边界

**研究日期：** 2026-08-04
**角色：** Research Agent
**范围：** 现有 `LogWriter`、日志调用点、本地 Xcode SDK Apple 资料
**修改范围：** 仅本文件；未修改源码、Product、UX、UI 或 Architecture 文档

## 1. 结论摘要

当前 `LogWriter` 可以同时把事件写入 Apple unified logging 和应用自己的文本日志文件，但还不能作为完整、可靠且隐私安全的用户诊断导出实现。

| 结论 | 证据状态 | 影响 |
|---|---|---|
| `actor` 保护了同一 `LogWriter` 实例的内存状态，未发现直接的数据竞争 | 源码事实 | 不等于 flush 任务、导出和清除之间具有完整事务语义 |
| 达到 50 条后启动未被跟踪的异步 flush；错误被 `try?` 吞掉 | 源码事实 | flush 失败不可观察，存在丢日志或重复写入窗口 |
| `exportLogs()` 不先 flush，且只读取主文件和 `.1` 到 `.3` | 源码事实 | 最新内存日志可能漏出，物理轮转出的 `.4` 不会进入导出 |
| 当前 `os_log` 将动态 message 标为 `public` | 源码事实 + Apple 事实 | 完整路径、URL 或错误详情可能进入公开日志表示 |
| 应用文件日志与 Apple system log 是两个独立数据源 | 源码事实 + Apple 事实 | 当前导出不包含 `.logarchive`，也不等同于系统诊断采集 |
| 关键下载、进程、完整性、bookmark 和持久化基础设施没有直接日志调用 | 源码扫描事实 | 发生故障时缺少阶段、结果和清理状态 |

本报告不把“缺少日志调用”直接等同为必须记录所有内部细节。后续实现应只补充能够解释用户可见失败、恢复和取消结果的最小事件，并遵守本报告的隐私边界。

## 2. 审查方法和证据范围

源码审查以当前工作区版本为准，使用 `rg` 扫描 `MiPlay/**/*.swift` 中的 `LogWriter` 注入和 `debug/info/warning/error` 调用，并逐段阅读 `LogWriter`、网络、Process、持久化、文件系统、完整性校验和 ViewModel 代码。

Apple 平台结论使用本机 Xcode SDK 和系统 man page：

- `$(xcrun --sdk macosx --show-sdk-path)/usr/share/man/man3/os_log.3:24-57,91-119`
- `/usr/share/man/man1/log.1:126-153,399-423`
- `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/OSLog.framework/Versions/A/Headers/Store.h:16-30`
- `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSTask.h`，以及现有平台约束报告中的 A1 证据索引
- `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSURL.h`，以及现有平台约束报告中的 A2 证据索引
- `Docs/01-research/research-apple-platform-constraints.md:147-193,229-243`

本轮未启动应用、未生成系统 `.logarchive`，因此运行时日志保留时长和真实崩溃现场只列为验证要求，不伪造运行结果。

## 3. 现有 `LogWriter` 审查

### 3.1 API、双写和缓冲

`LogWriter` 是 `actor`，公开入口是 `debug`、`info`、`warning`、`error`；`LogEntry` 字段为 `timestamp`、`level`、`module`、`message`、可选 `details`（`MiPlay/Infrastructure/Log/LogWriter.swift:14-45,64-78`）。

每次调用都会：

1. 通过 `OSLog(subsystem: "SteveTan.MiPlay", category: "MiPlay")` 写入 unified logging。
2. 追加到 actor 内的 `[LogEntry]`。
3. 当数量达到 50 时创建 `Task { try? await self.flushToFile() }`（`LogWriter.swift:48-60,80-99`）。

`LogEntry: Codable` 和 `JSONEncoder` 当前没有用于文件序列化。文件实际是 UTF-8 文本行，格式为时间、级别、模块、message 和可选 details（`LogWriter.swift:31-45,51-60,119-139`）。因此文件不是 JSON，也没有字段转义；message 或 details 中的换行会破坏“一条日志一行”的可读结构。

### 3.2 flush、轮转和失败处理

- `flush()` 只调用一次 `flushToFile()`（`LogWriter.swift:166-169`），没有保存或等待由阈值触发的未跟踪 `Task`。由于 `flushToFile()` 在取得 `logDirectory()` 时会挂起，其他 actor 消息可能在同一次写入前后交错；actor 保护内存访问，但没有定义 flush 的批次边界。
- 阈值任务使用 `try?`，所以目录创建、属性读取、轮转或关闭文件产生的错误不会返回给调用方，也不会进入另一条日志路径（`LogWriter.swift:93-97,103-117`）。
- 追加已有文件时，`try? FileHandle(forWritingTo:)` 失败会跳过写入，但函数随后仍执行 `logEntries.removeAll()`。这是明确的缓冲丢失路径（`LogWriter.swift:131-142`）。
- 如果文件句柄已写入但 `close()` 抛错，函数可能在 `removeAll()` 前退出；下一次重试可能重复追加已经写入的批次。当前代码没有批次 ID 或写后确认来区分该状态（`LogWriter.swift:131-142`）。
- 轮转使用 `miplay.log.1` 到 `.4` 的实际移动路径：`maxBackups = 3` 时 `.3` 会移动到 `.4`，当前文件移动到 `.1`；但 `getLogFileURLs()` 只读取主文件和 `.1` 到 `.3`（`LogWriter.swift:144-164,173-190`）。因此 `.4` 可能存在但不会被导出或清除。
- 轮转移动失败使用 `try?`，失败不会成为可观察的日志写入错误（`LogWriter.swift:149-163`）。

**并发结论：** 同一个 actor 内不存在普通意义上的同时修改 `[LogEntry]` 数据竞争；但未跟踪 flush 与 actor 重入造成了逻辑竞态。特别是 `clearLogs()` 可以在异步 flush 挂起期间删除文件并清空缓冲，待 flush 恢复后可能重新写入清除之后到达的批次；实现没有定义清除操作与正在进行的 flush 的顺序（`LogWriter.swift:103-142,209-215`）。

### 3.3 export 和 clear

`exportLogs()` 直接调用 `getLogFileURLs()` 并读取已经落盘的文件，没有先执行 `flush()`；读取文件失败使用 `try?` 并静默跳过，最终总是返回 `String`（`LogWriter.swift:173-207`）。因此：

- 少于 50 条的内存日志不会自动出现在导出结果中。
- 已触发但尚未完成的异步 flush 可能不在导出结果中。
- `.4` 轮转文件不会出现在导出结果中。
- 没有导出文件、归档、失败状态或导出元数据；UI 只是把这个字符串写入 ViewModel 的 `logContent`（`MiPlay/UI/ViewModels/SettingsViewModel.swift:346-351`、`MiPlay/UI/ViewModels/GameDetailViewModel.swift:150-155`）。

`clearLogs()` 先枚举文件并删除，再清空内存缓冲；它没有等待、取消或标记已排队的 flush（`LogWriter.swift:209-215`）。这使清除结果依赖 actor 重入时序，不能作为“清除完成后不会重新出现旧批次”的保证。

### 3.4 应用日志文件位置

`GameFileSystemRepository` 使用 `FileManager` 的 `.applicationSupportDirectory`，再追加 `MiPlay/Logs/miplay.log`（`MiPlay/Infrastructure/FileSystem/GameFileSystemRepository.swift:390-413`）。这是 MiPlay 自己的 Application Support 文件，不是 unified logging 的系统 datastore，也不是 `log collect` 生成的 `.logarchive`。

Apple `log` man page 说明 `log collect` 收集系统日志并生成 `.logarchive`，`log show` 读取系统 datastore 或 `.logarchive`（`/usr/share/man/man1/log.1:126-153,399-423`）。当前 `exportLogs()` 没有调用这些工具或 `OSLogStore`，所以用户导出仅代表应用文本日志，不应在 UI 中宣称为完整系统诊断包。

## 4. 日志调用点清单

### 4.1 已有调用

| 模块 | 当前可观察事件 | 源码证据 |
|---|---|---|
| `GameRegistry` | 加载、保存、移除、恢复保护、bookmark 写回和错误 | `MiPlay/Domain/Game/GameRegistry.swift:116-129,223,253,325-452,523,692-798` |
| `LaunchOrchestrator` | 启动开始、Wine 准备、启动、运行确认、取消清理、退出和恢复错误 | `MiPlay/Domain/Launch/LaunchOrchestrator.swift:104-341` |
| `BackgroundMediaService` | 背景加载、缓存清理、API 请求/响应和持久化错误 | `MiPlay/Domain/Media/BackgroundMediaService.swift:166-560` |
| `PerformanceOptionManager` | 性能选项加载错误 | `MiPlay/Domain/Performance/PerformanceOptionManager.swift:78-114` |
| `WineVersionManager` | 版本初始化、列表错误、选中、删除和恢复持久化错误 | `MiPlay/Domain/Runtime/WineVersionManager.swift:179-219,305-338,520-630,882` |
| `SolutionEngine` | 兼容方案查询/应用相关警告 | `MiPlay/Domain/Solution/SolutionEngine.swift:47-83` |
| `TaskScheduler` | 中断任务写回和历史恢复错误 | `MiPlay/Domain/TaskScheduler/TaskScheduler.swift:224-342` |
| `VersionChecker` | 官方版本获取错误 | `MiPlay/Domain/Update/VersionChecker.swift:183-193,526` |
| `MediaTranscoder` | ffmpeg 缺失、转码开始/完成/失败 | `MiPlay/Infrastructure/Media/MediaTranscoder.swift:33-92` |
| `WineVersionDownloader` | 归档下载开始/完成、解压开始/完成 | `MiPlay/Infrastructure/Wine/WineVersionDownloader.swift:135-164,307-419,507-600` |

`MiPlayApp` 只负责创建和注入 `LogWriter`，没有记录应用初始化、日志目录准备或退出 flush（`MiPlay/MiPlayApp.swift:59-76`）。

### 4.2 注入但未发现业务调用

扫描发现以下类型持有 `LogWriter`，但当前文件没有 `debug/info/warning/error` 调用：

- `LibraryViewModel`：`MiPlay/UI/ViewModels/LibraryViewModel.swift:134-148`。
- `GameDetailViewModel`：除 `exportLogs()` 外没有日志调用，`MiPlay/UI/ViewModels/GameDetailViewModel.swift:42-63,67-148`。
- `SettingsViewModel`：除 `exportLogs()` 外没有日志调用，`MiPlay/UI/ViewModels/SettingsViewModel.swift:220-251,255-351`。

这意味着 ViewModel 的加载、用户触发的启动/定位/安装、兼容方案排队、任务投影和导出失败目前主要通过状态或 `errorMessage` 表达，不会自动形成应用诊断事件。

### 4.3 未注入 `LogWriter` 的关键模块

以下模块在当前源码中没有 `LogWriter` 属性或调用，故其内部失败不会直接产生应用日志：

| 模块 | 当前存在但未记录的关键状态 | 源码证据 |
|---|---|---|
| `NetworkDownloadProvider` | 请求/下载开始、最终 URL、HTTP 状态、临时文件移动、大小校验、取消和清理结果 | `MiPlay/Infrastructure/Network/NetworkDownloadProvider.swift:33-43,126-281,291-377` |
| `ProcessManager` | launch、PID、stdout/stderr、termination handler、超时、SIGTERM/SIGKILL 和 wait 结果 | `MiPlay/Infrastructure/Process/ProcessManager.swift:13-21,87-215,263-380` |
| `WineRuntimeProvider` | Wine 版本探测、prefix 创建/取消清理和失败恢复 | `MiPlay/Infrastructure/Wine/WineRuntimeProvider.swift:13-165` |
| `PersistenceStore` | 读取、原子写入、备份、恢复、schema/migration 和验证失败 | `MiPlay/Infrastructure/Persistence/PersistenceStore.swift:12-435` |
| `GameFileSystemRepository` | bookmark resolve、stale 刷新、scope 开始/结束、文件操作和目录权限失败 | `MiPlay/Infrastructure/FileSystem/GameFileSystemRepository.swift:161-237,390-413` |
| `FileIntegrityVerifier` | 清单读取、校验开始/结果、缺失/损坏数量和取消 | `MiPlay/Domain/Game/FileIntegrityVerifier.swift:102-233` |
| `PreLaunchValidator` | 各前置条件及具体阻断原因 | `MiPlay/Domain/Launch/PreLaunchValidator.swift:13-195` |
| `GameStateMachine` | 合法/非法状态转换 | `MiPlay/Domain/Game/GameStateMachine.swift:14-81` |
| `SystemEnvironmentDetector` | OS/硬件/磁盘空间探测失败 | `MiPlay/Infrastructure/System/SystemEnvironmentDetector.swift:15-167` |

## 5. Apple unified logging 约束

### 5.1 Apple 文档事实

当前源码导入 `OSLog` 并直接使用 `OSLog` 对象和 `os_log` 函数（`MiPlay/Infrastructure/Log/LogWriter.swift:8-9,48-58,80-82`）；全仓扫描没有发现 `Logger` 类型的调用。本报告核对的是当前实际使用的 OSLog/os_log 语义，不把迁移到 `Logger` 设为本 Research 阶段的结论。

本机 `os_log.3` 说明 unified logging 会集中管理内存和磁盘上的系统日志，并可用 Console 和 `log` 查看；自定义 log object 可以用 subsystem/category 做过滤（`os_log.3:24-35,91-97`）。

日志级别和默认保留语义如下（`os_log.3:99-119`）：

| 类型 | Apple man page 语义 | 对 MiPlay 的事实影响 |
|---|---|---|
| default | 通常在内存和磁盘捕获，适合生产故障上下文 | 当前 `warning` 映射到 `.default` |
| info | 生命周期短，通常先在内存，收集时写出；可配置持久化 | 当前 `info` 不能单独证明长期可查 |
| debug | 默认只有工具或配置明确请求时才记录 | 当前 `debug` 不能单独承担用户诊断主链路 |
| error | 与本地进程或框架相关的错误 | 当前 `error` 使用 `.error` |
| fault | 表示代码缺陷/被破坏的假设 | 当前 `LogWriter` 没有 fault 入口 |

Apple man page 还说明：动态字符串和复杂对象默认为 private；`public` 会无论隐私设置都显示；`sensitive` 用于敏感数据（`os_log.3:37-57`）。

### 5.2 当前 OSLog 格式的隐私问题

当前调用是：

```swift
os_log("%{public}@ [%@] %{public}@", log: osLog, type: level.osLogType, level.rawValue, module, message)
```

源码位置：`MiPlay/Infrastructure/Log/LogWriter.swift:80-82`。

根据 `os_log.3`：

- `level.rawValue` 被明确标为 `public`，这是有限枚举值，通常不含用户数据。
- `module` 使用未标记的 `%@`，动态对象按 Apple 语义默认为 private。
- `message` 被明确标为 `public`，因此所有调用方插入 message 的 URL、路径、错误文本和其他动态值都可能以公开形式进入 unified logging。
- `details` 没有写入 OSLog，但会原样进入应用文件。

这不是“Apple 自动把应用文件日志脱敏”的情况。OSLog 的 privacy 标记只约束 unified logging 参数；`miplay.log` 的文本写入必须在调用前或 LogWriter 边界自行做字段限制和脱敏。

### 5.3 Apple 日志、应用诊断日志和导出边界

| 数据源 | 生产者 | 可见范围和用途 | 当前 MiPlay 状态 |
|---|---|---|---|
| Apple unified logging | `os_log` / OSLog subsystem | 系统 datastore、Console、`log show`；info/debug 的保留受系统配置影响 | 已写入 `SteveTan.MiPlay` / `MiPlay`，但 message 标 public |
| 应用持久化诊断日志 | `FileManager` + `Application Support/MiPlay/Logs/miplay.log` | MiPlay 自己控制的文本历史，可在应用中读取 | 已实现，但 flush/export 不完整 |
| 用户导出 | 当前 `exportLogs() -> String` | UI 获得应用文本，不自动生成文件，也不包含 system log | 仅返回内存中的字符串属性 |
| 系统诊断归档 | `log collect` / `OSLogStore` 等 Apple 能力 | 系统范围或指定范围的 `.logarchive`，可能包含比 MiPlay 更广的系统事件 | 当前未接入，不能与应用导出混称 |

`OSLogStore.h` 将 system scope 与 current-process scope 定义为不同范围（`Store.h:16-30`）；`log.1` 将 `.logarchive` 定义为 system logs 的归档（`log.1:138-153`）。因此，用户诊断功能必须明确产品选择的是应用日志、系统日志，还是两个经过区分的导出项；本 Research 不替 Product 决定导出范围。

### 5.4 崩溃和 Process 输出边界

- `LogWriter` 的文件 buffer 只在达到阈值或显式 flush 时写盘；进程在 buffer 落盘前崩溃时，这批应用文件日志可能不存在。Apple unified logging 的保留则按消息类型和系统配置处理，不能用应用文件结果反推系统 log 结果。
- `ProcessManager` 只有在 `captureOutput` 为 true 时连接 stdout/stderr pipe，并在 termination 时合并为 `TerminationResult.output`（`MiPlay/Infrastructure/Process/ProcessManager.swift:87-135,173-203,317-320`）。当前 `ProcessManager` 没有把输出转交 `LogWriter`；`LaunchOrchestrator` 只记录进程正常/异常退出等摘要（`MiPlay/Domain/Launch/LaunchOrchestrator.swift:322-341`）。
- Apple 的 `NSTask.h` 只定义 Process、pipe 和 termination 边界；它不表示子进程 stdout/stderr 会自动进入 unified logging。需要诊断输出时，必须由应用选择性地记录经过限制和脱敏的摘要。
- 本报告不把 unified logging 当作 crash report API，也不把 `log collect` 当作应用文件导出 API。崩溃报告、Process 输出和用户导出属于不同诊断数据边界。

## 6. 关键日志缺失状态

以下是“出现后用户无法解释失败或恢复结果”的最小缺口，不是要求记录所有中间循环：

| 流程 | 建议至少有的状态事件 | 当前证据 |
|---|---|---|
| 应用启动/恢复 | 初始化完成、恢复保护发现、恢复成功/失败、日志目录不可用 | `MiPlayApp.swift:59-76` 仅组装依赖；`GameRegistry` 只覆盖部分恢复错误 |
| Wine 下载 | 来源类别、开始、HTTP status/最终 host、收到字节、临时文件移动、大小/归档校验、取消、清理结果、终态 | `NetworkDownloadProvider.swift:126-281` 无 LogWriter；`WineVersionDownloader.swift:307-419` 只有开始/完成 |
| API 请求 | 开始、非 2xx、403/429/5xx、解码失败、取消或超时 | `NetworkDownloadProvider.swift:291-377` 无 LogWriter |
| Process | launch accepted、运行确认、PID、stdout/stderr 是否启用、超时、终止原因/码、输出是否截断、取消清理结果 | `ProcessManager.swift:150-380` 无 LogWriter |
| bookmark | resolve、stale、刷新保存成功/失败、scope 开始/结束、目录不可访问 | `GameRegistry` 记录部分失败；底层文件系统无直接调用 |
| 完整性校验 | 清单可用性、开始、总数/通过/缺失/损坏、算法标识、取消 | `FileIntegrityVerifier.swift:179-233` 无 LogWriter |
| 持久化 | 读写开始、原子替换、验证、备份恢复、失败和恢复状态 | `PersistenceStore.swift:77-435` 无 LogWriter；上层仅记录部分错误 |
| 兼容方案 | 任务提交、开始、阶段、应用/回滚/恢复结果、取消和清理 | `GameDetailViewModel.swift:80-148` 只提交任务；`SolutionEngine.swift:83` 只有警告 |
| 日志本身 | flush 成功/失败、待写条数、轮转结果、export 读取失败、clear 与 flush 的协调结果 | `LogWriter.swift:93-215` 无内部结果事件 |

## 7. 最小字段和隐私规则

下表是面向后续实现和测试的最小建议。它们是基于 Apple privacy 约束和当前故障诊断需要形成的 Research 建议，不是 Apple 对 MiPlay 的产品决策。

### 7.1 建议字段

| 字段 | 用途 | 允许的内容 |
|---|---|---|
| `timestamp` | 排序和关联时序 | 系统时间；不拼用户信息 |
| `level` | 过滤严重程度 | 固定枚举 |
| `subsystem` / `category` / `module` | Console/文件过滤 | 固定代码标识，不含路径和用户输入 |
| `event` | 稳定查询键 | 如 `download.http_response`、`process.terminated`，不要只写自然语言句子 |
| `operationID` | 关联一次操作 | 随机 opaque ID，不使用账号、路径或 token |
| `gameType` | 识别三款游戏 | 固定枚举或受控 ID；不记录完整安装路径 |
| `phase` / `result` | 描述状态机结果 | 固定值，如 `started`、`failed`、`cancelled`、`cleanup_failed` |
| `durationMs` | 解释超时和慢操作 | 非负数 |
| `bytesReceived` / `expectedBytes` | 解释下载进度和大小失败 | 数字；不记录文件内容 |
| `httpStatus` / `redirectHostClass` | 解释网络失败和来源切换 | 状态码；host 仅限已批准的类别或哈希后的内部标识 |
| `exitCode` / `signal` | 解释 Process 终态 | 数字和受控结果 |
| `integrityAlgorithm` / `integrityResult` | 解释完整性门禁 | 算法名和 pass/fail；不输出完整文件摘要到用户日志 |
| `cancelRequested` / `cleanupResult` | 区分取消和失败清理 | 布尔值和固定结果 |
| `errorCode` | 稳定支持诊断 | 本地错误枚举；detail 必须经过脱敏和长度限制 |

### 7.2 明确禁止或默认不记录

- access token、Authorization 值、cookie、bookmark data、签名材料和任何凭据。
- 完整本地路径、用户目录名、完整 URL query、可推断用户身份的网络地址或任意请求头。
- 游戏文件内容、stdout/stderr 原文、归档内容、配置文件全文和完整 `config.ini` 内容。
- 未经筛选的 `error.localizedDescription`、`NSError.userInfo` 或服务器响应体。当前 `NetworkDownloadProvider` 会把响应体前 512 字节放入错误 detail（`NetworkDownloadProvider.swift:321-334,361-374`），调用方写日志前仍必须把它视为未清洗输入。
- 以 `public` 形式写入动态用户数据。Apple man page 明确要求 `public` 只用于不会损害隐私的数据（`os_log.3:40-53`）。

用户可见文本、错误呈现和日志诊断字段不是同一份数据。错误 UI 可以使用本地化错误码投影；诊断日志应保存稳定错误码和受控数值，而不是把最终 UI 文本、路径或服务器原文直接写入。

## 8. 可验证的实现要求

这些要求供 Architecture、Implementation、Review 和 QA 回溯使用，不在本 Research 阶段修改源码。

### 8.1 LogWriter 生命周期

1. 把阈值触发的 flush 纳入可等待的生命周期；每个 flush 批次必须有明确成功、失败或待恢复结果。
2. 写入失败时保留未确认成功的条目，并让调用方能观察失败；不能用 `try?` 把日志失败变成静默成功。
3. `export` 必须定义是否包含当前内存、正在写入批次和全部轮转文件；在该定义下验证主文件、`.1` 到实际保留上限的集合一致。
4. `clear` 必须和排队 flush 有明确顺序，测试清除、追加、flush 三者交错时不会复活已清除批次。
5. 若继续使用文本行格式，测试 message/details 中的换行、UTF-8、超长内容和截断；若改用结构化格式，导出读取器和向后兼容行为必须被定义。
6. 应用退出、进入后台和崩溃前不可假设都有机会完成 flush；关键故障摘要应优先进入 Apple unified logging 的合适级别。

### 8.2 隐私和诊断测试

1. 用包含 token、完整路径、URL query、服务器错误原文和换行的输入验证 OSLog 与文件日志都不会泄露禁止内容。
2. 验证 `public` 仅出现在固定枚举、受控数字或经过允许清单确认的值；默认动态值使用 private 或不写入。
3. 并发提交至少覆盖多个任务同时写入、阈值触发、显式 `flush()`、`exportLogs()` 和 `clearLogs()`。
4. 注入目录创建失败、文件打开失败、轮转移动失败、写后关闭失败、导出读取失败，检查错误可观察且待写条目不静默消失。
5. 下载、Process 和 bookmark 的取消测试要记录“取消请求”和“外部资源已停止/清理完成”两个不同状态；Swift `Task` 被取消本身不能证明外部资源已清理。既有平台报告 A10/A11 对此已有 Apple SDK 证据（`research-apple-platform-constraints.md:171-193,242-243`）。
6. 分别验证应用文本导出和 Apple `log collect` 产生的系统 `.logarchive`；不要用一个文件的存在替代另一个文件的验证。

## 9. 研究结论边界

### 已确认

- 当前 `LogWriter` 的 actor、双写、50 条阈值、Application Support 路径、5 MiB 轮转、导出和清除行为均由 `LogWriter.swift` 与 `GameFileSystemRepository.swift` 直接确认。
- 当前 10 个业务/基础设施调用方及其调用点如第 4 节所列；网络、Process、持久化、文件系统、完整性和环境探测模块没有直接 `LogWriter` 调用。
- Apple `os_log.3` 对 unified logging、subsystem/category、privacy、default/info/debug/error/fault 的语义如第 5 节所列。
- Apple `log.1` 的 system datastore、`log collect`、`.logarchive` 和 `log show` 是系统日志边界，不等于应用文本日志。

### 待验证

- 在目标 macOS 26+ 签名产物上，info/debug 的实际保留窗口和用户可取得的 OSLog 范围。
- 真实崩溃、强制退出、磁盘满、文件权限变化和并发清除时的丢失/重复日志表现。
- 用户导出是否需要只提供应用日志，或由上游 Product/UX 另行定义 Apple system log 的用户授权流程。
- Process stdout/stderr 的实际体量和内容是否含有第三方游戏的敏感数据；在未审计前不应把原文写入日志。

### 不可直接推断

- “已写入 OSLog”不能推断应用 `miplay.log` 已落盘。
- `flush()` 返回不能推断之前所有未跟踪 flush 都已完成。
- HTTP/Process/完整性操作返回成功不能推断用户能在导出日志中看到完整过程。
- Apple unified logging 的默认保留不能推断长期用户诊断留存，也不能替代应用可导出的、经过脱敏的最小记录。
