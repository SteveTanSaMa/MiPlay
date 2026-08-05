# MiPlay 状态所有权与投影

> **文档状态**：已冻结（Phase 3；当前修订基线见 `architecture-revision-2026-08-03.md`）
> **更新日期**：2026-08-03
> **核心规则**：业务状态只有一个写入者；ViewModel 只保存 UI 投影，不反向修改 Domain。

## 1. 状态分层

| 状态类别 | 唯一所有者 | 修改者 | 观察者 | 是否持久化 |
|---|---|---|---|---|
| Game 业务状态 | `GameRegistry` Actor | Domain 命令/启动与校验结果 | `LibraryViewModel`、详情和设置 ViewModel | 是；运行中状态按恢复规则处理 |
| GameLocation 授权 | `GameRegistry` + `GameFileSystemRepository` | 用户定位流程的 Domain 命令 | Library/设置/路径反馈 ViewModel | bookmark 是；活动 scope 否 |
| 完整性结果 | `FileIntegrityVerifier` 计算，`GameRegistry` 归档 | 完整性任务 | Library/路径反馈/详情 ViewModel | 最近可信结果是 |
| Task 生命周期 | `TaskScheduler` Actor | 调度器和执行器回调 | 所有相关 ViewModel | 活跃任务和最近历史是 |
| Wine 目录与生效选择 | `WineVersionManager` Actor | Wine 管理命令 | Settings、Wine 进度、Library ViewModel | 是 |
| Wine 来源目录结果 | `WineVersionManager` Actor | `WineCatalogQuery` 执行和来源解析 | `SettingsViewModel` | 已验证目录缓存是；认证 token 否 |
| Wine source selection | `WineVersionManager` Actor | 默认/用户选择 allowlist source | `SettingsViewModel` | source ID 是；URL/token 否 |
| Game metadata | `GameRegistry` 归档的 `LocalGameEvidence` | scoped metadata read | Library/Settings/GameDetail ViewModel | evidence 摘要是；原始游戏文件否 |
| Per-game settings/background selection | `GameRegistry` + `PersistenceStore` | Game ID 命令 | `SettingsViewModel`、`LibraryViewModel` | 是；活动加载 scope 否 |
| 本地版本/渠道证据 | `LocalGameEvidenceReader` 计算，`GameRegistry` 归档 | scoped 读取任务 | `LibraryViewModel`、详情/设置 ViewModel | 证据摘要是；原始游戏文件否 |
| 进程表 | `ProcessManager` Actor | 启动、终止、termination handler | `LaunchOrchestrator`，不直接给 UI | 否；退出后重建 |
| 进程退出恢复记录 | `LaunchOrchestrator`/`GameRegistry` | ProcessExitEvent 后的终态提交和恢复命令 | LibraryViewModel、任务恢复 ViewModel | 是；提交失败时保留同目标保护 |
| Launch session / restart reconciliation | `LaunchOrchestrator` + `GameRegistry` | 启动前、进程确认、重启扫描 | LibraryViewModel | 是；Process 引用本身否 |
| 方案应用记录 | `SolutionEngine`/GameRegistry | 应用、验证、回滚流程 | GameDetailViewModel | 是 |
| AppData 恢复状态 | `PersistenceStore` Actor + Domain 恢复协调 | 启动、迁移、用户恢复命令 | Settings 和恢复 UI | 是 |
| LogEvent sequence、内存批次、flush/export 状态 | `LogWriter` Actor | Domain 安全事件、flush barrier、`LogExport` | `SettingsViewModel`（仅导出投影） | 日志文件是；内存批次和活动 flush 否 |
| 选中游戏/当前 Tab/窗口状态 | 对应 `@MainActor` ViewModel | UI 事件 | 对应 View | 否，除明确设置项 |
| 任务确认后的主按钮语义 | `LibraryViewModel` 计算投影 | Domain 事件到达后重算 | 主窗口 UI | 否 |
| AccessibilityProjection | 对应 `@MainActor` ViewModel | 根据结构化快照/事件生成本地化 projection | SwiftUI View | 否；不成为第二业务事实源 |

## 2. Actor 隔离规则

### 2.1 Domain 与 Infrastructure

- `GameRegistry`、`TaskScheduler`、`SolutionEngine`、`WineVersionManager`、`PersistenceStore`、`ProcessManager`、`GameFileSystemRepository` 和下载/日志服务的共享可变状态均在各自 Actor 内。
- `LocalGameEvidenceReader` 和 Wine catalog/network/file services 不因被 ViewModel 调用而变为 `MainActor`；共享可变缓存和持久化由对应 Actor 所有。
- `LogWriter` 也不因导出按钮或 ViewModel 观察而变为 `MainActor`；它独占事件序列、缓冲、flush 和日志文件状态。
- Actor 不使用 `@MainActor` 作为默认隔离。`@MainActor` 只属于 ViewModel 和 UI。
- Actor 间只传 Sendable 值：稳定 ID、路径值（仅在有效访问操作中短暂传递）、`Data`、时间、枚举、快照和错误记录。
- 不跨 Actor 传 `Process`、`URLSessionTask`、`FileHandle`、SwiftUI 状态或可变领域引用。
- 一个 Actor 不观察另一个 Actor 的 `@Observable` 属性。Actor 通过查询结果和 `AsyncSequence` 传递事实。

### 2.2 ViewModel

- 每个 ViewModel 是 `@MainActor @Observable`，唯一职责是把 Domain 快照/事件转换为 UI 需要的稳定投影。
- ViewModel 可以持有取消用的观察 `Task`，但不持有 Domain 的可变状态副本作为事实源。
- ViewModel 的异步调用由结构化 Task 承担；视图消失时取消观察和尚未提交的查询。
- ViewModel 只能发送用户意图：启动、取消、重新授权、应用方案、回滚、重试。它不能直接设置 `Game.businessState` 或 `Task.status`。

## 3. Domain Event Stream

### 3.1 事件信封

每个 Domain 聚合通过统一的只读事件流暴露 `DomainEvent`。事件具有服务内递增 `sequence`、聚合 `revision`、目标 ID、不可变 payload 和 `persistence` 标记。事件在 Actor 内按产生顺序发布，订阅者不得依赖到达时间排序。

事件发布门槛：

1. 纯查询不发布事件。
2. 内存态运行变化可以发布 `memoryOnly` 事件。
3. 需要持久化的 Game、方案、bookmark、Wine 选择或任务记录，先完成 JSON 提交和重新验证，再发布 `committed` 事件。
4. 外部副作用已发生但持久化失败时，发布 `recoveryRequired`；不得发布成功业务事件。
5. 事件流关闭时，订阅者得到结束事实并保留最近快照；不能把流结束当成成功。

### 3.2 初始快照与竞态消除

LibraryViewModel 采用一次性订阅握手：Domain 返回“当前快照 + 当前序列号 + 从该序列号之后的事件流”。初始快照和订阅边界由同一 Actor 操作确定，避免先查快照、后订阅造成事件丢失。

事件处理规则：

- `sequence <= lastSequence`：丢弃重复事件。
- `sequence == lastSequence + 1`：应用事件，更新投影。
- 出现序列空洞：暂停局部投影，重新获取全量快照并重建序列边界。
- 事件 payload 与快照冲突：以 Domain 全量快照为准，并记录诊断日志。
- 事件作用于未选中的游戏：更新该游戏的 rail 投影，但不改变当前选中游戏的 UI 状态。

### 3.3 TaskReceipt 与提交边界

- `TaskReceipt` 由 TaskScheduler 产生，但只有 `pending` 任务记录提交并重读验证后才可返回给 ViewModel。
- `running` 是执行副作用的提交门；`running` 写入失败时不得开始 Wine 下载、进程启动、方案修改或其他外部副作用。
- `completed` 只有在业务 outcome 和相关 AppData 提交均验证后才可发布。
- `failed` 表示目标未达成且副作用已清理；若清理/状态收敛不确定，则附 `recoveryRequired`。
- `recoveryRequired` 是恢复保护事实，不是第五种/第六种 Task 状态；它使同目标任务保持不可用，直到恢复提交和读回验证完成。

## 4. LibraryViewModel 投影流程

```text
用户点击主按钮
  → LibraryViewModel 创建 UserIntent
  → TaskScheduler 接受/拒绝并返回 TaskReceipt
  → Domain 执行并改变 GameRegistry/TaskScheduler
  → Domain 持久化并发布 DomainEvent
  → LibraryViewModel 处理快照/事件
  → 重新计算 rail、主按钮、阶段、进度和恢复动作
  → SwiftUI 重绘
```

### 4.1 投影字段

`LibraryViewModel` 只保留以下面向 UI 的值：

- 三款游戏的不可变展示快照：名称、状态、路径是否已确认、最近完整性结果、最近失败事实。
- 当前选中 Game ID。
- 当前关联任务 ID、阶段、可选确定进度、是否可取消、错误和唯一恢复动作。
- 主操作语义：定位、启动、查看方案、重试或禁用。
- 背景媒体的展示状态和加载阻断状态。

它不保留：bookmark secret 的第二份副本、Wine binary 组装逻辑、`WINEPREFIX`、系统权限 token、Process 引用或可写的 Game 业务对象。

### 4.2 状态计算优先级

1. 恢复未确认/数据不可用：显示恢复或重新授权入口，不能使用默认值。
2. 当前 Game 的互斥任务 `pending/running`：显示任务阶段和取消策略。
3. Game 业务状态：按 UI 冻结映射显示定位、启动、方案或重试。
4. 任务 `completed`：读取独立 `outcome` 后再决定下一步，不能显示通用成功。
5. `failed/cancelled`：显示失败或清理已确认事实，保留原 Game 状态。

若存在 `recoveryRequired`，它优先于普通 Game 状态和重试按钮：ViewModel 必须展示恢复/重新授权事实，并阻止新的同目标副作用任务。恢复成功后才重新计算主操作。

`WineReady` 只解除运行环境依赖，不产生 `Running`；`processCreated` 只表示启动中间事实，不产生 `Running`；`Applied` 只表示方案完成，不产生游戏启动。

### 4.3 AccessibilityProjection 所有权

- `LibraryViewModel` 生成游戏卡片、主操作、启动进度、取消和错误恢复的 AccessibilityProjection。
- `SettingsViewModel` 生成 Wine source/catalog、403/429/认证/空列表、托管下载、metadata 和 Deferred capability 的 AccessibilityProjection；不存在外部 Wine projection。
- `SettingsViewModel` 只生成 `LogExport` 的 pending/running/completed(empty)/failed/cancelled 投影；不读取 LogWriter 内部缓冲或日志目录。
- Path/Library 对应 ViewModel 生成 bookmark stale、刷新写回和 `pkg_version/config.ini` 证据的 AccessibilityProjection；`GameDetailViewModel` 生成方案应用与回滚投影。
- Projection 只允许使用 Domain 提供的结构化事实：label 对象/动作，value 选中态/业务态/任务阶段/真实进度，hint 当前动作或恢复条件。UI 不从颜色、hover、状态点、spinner 或进程创建推断事实。
- Domain 事件或持久化提交失败时，Projection 明确读出“无法确认/当前不能重试”；取消订阅只停止观察，不改变最近可信 Domain 事实。

## 5. 取消与状态所有权

- 取消动作由 ViewModel 发给 `TaskScheduler`，由调度器决定是否可取消。
- `pending` 任务可在未开始时直接进入 `cancelled`，业务状态不变。
- 已有副作用的任务必须由 Domain 执行清理/回滚；清理确认后才发布 `cancelled`。
- `SolutionRevert` 和已开始修改的方案恢复不可取消；取消按钮从投影中消失，而不是由 UI 强行终止。
- 取消失败或清理未确认进入 `failed + recoveryRequired`，不允许 ViewModel 本地复位为初始状态。
- 进程退出后的 Game 状态提交失败时，保留 session guard 和同 Game lifecycle lock；恢复命令只提交 `Installed/UpdateAvailable/LaunchFailed` 目标终态，不重新启动。

## 6. 持久化与内存状态

- Domain 业务状态的持久化提交是状态变更的提交点；写入失败时，原文件和旧业务快照保留。
- 进程运行状态、活动 security scope、异步订阅和 UI 选择不持久化。
- 应用崩溃恢复时，`pending/running` 任务改为 `failed(interrupted)` 或 `recoveryRequired`，不能自动重新执行可能有副作用的工作。
- 启动时若持久 Game 仍为 `Running` 但没有可信活动进程，先建立 `recoveryRequired`，完成退出探测/终态提交后才允许新的 GameLaunch。
- 只读查询失败不会覆盖上一次可信业务结果；失败原因以过期/不可确认事实附着。

## 7. 与 UI 状态映射的逐项追溯

| UI 冻结项 | 状态所有权实现 |
|---|---|
| Game Rail 的八种 Game 状态 | GameRegistry 快照；选中态由 LibraryViewModel 单独持有 |
| 主按钮只表达下一步动作 | ViewModel 根据 Domain 快照 + Task 投影计算 |
| pending/running/completed/failed/cancelled 与业务结果分离 | TaskScheduler 与 Game/Integrity/Solution 分开发布 |
| 启动必须进程确认 | LaunchOrchestrator 发布 `runningConfirmed` 后 GameRegistry 才转 `Running` |
| 方案应用后需验证和可恢复 | SolutionEngine 发布 `Applied` 或 `RolledBack/RecoveryUnknown` |
| 设置数据恢复失败不可默认 | PersistenceStore recovery state 直接投影到 SettingsViewModel |
| stale bookmark 刷新失败不可继续成功 | bookmarkRefreshPersistenceFailed + recoveryRequired 优先投影 |
| Wine 进度不等于游戏运行 | WineVersionManager 事件只更新运行环境投影 |
