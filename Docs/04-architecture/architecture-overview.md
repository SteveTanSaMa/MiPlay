# MiPlay 架构概览

> **文档状态**：已冻结（Phase 3；当前修订基线见 `architecture-revision-2026-08-03.md`）
> **更新日期**：2026-08-03
> **职责边界**：本文件冻结系统如何组织，不规定 Swift 代码写法。
> **上游**：Product、Research、UX、UI 文档均为冻结输入。
> **下游**：Implementation 只能在本目录契约内实现；发现契约问题必须回溯 Architecture。

## 1. 架构目标与范围

MiPlay 当前版本只管理三款固定游戏：原神、崩坏：星穹铁道、绝区零。架构必须支持：定位已安装游戏、完整性校验、Wine 运行时管理、启动确认、内置兼容方案、版本检测、背景素材和日志导出。日志导出通过 `LogExport` Domain task 完成。

当前版本不包含游戏客户端安装、完整游戏更新包下载、自定义任意启动参数、帧率解锁和未进入发布清单的兼容方案。`GameInstall`、`GameUpdate` 不是当前版本的调度任务；版本更新只产生 `VersionCheck` 结果和用户提示。日志 flush 不是业务 Task；用户导出使用 `LogExport`。

## 2. 四层架构

```text
UI
  ↓ 读取投影、提交用户意图
ViewModel
  ↓ 调用领域命令/查询，订阅领域事件
Domain
  ↓ 调用基础设施能力，维护业务状态和规则
Infrastructure
  ↓ Foundation、AppKit、URLSession、Process、文件系统、系统授权
```

### 2.1 UI Layer

UI 只负责 SwiftUI 场景、布局、控件语义和展示 ViewModel 投影。UI 不读取 Actor 内部状态，不访问 `PersistenceStore`、`Process`、文件路径或系统命令，也不决定业务状态转换。

固定入口：

- `MainWindow`：游戏选择栏、背景、主操作和任务反馈。
- `PathLocationFlow`：系统文件选择器结果的展示和授权/完整性反馈。
- `GameDetailWindow`：兼容方案和游戏详情。
- `Settings`：运行环境、配置和只读状态。
- `WineProgressSheet`：Wine 获取任务的阶段与进度。

### 2.2 ViewModel Layer

ViewModel 是唯一的 UI 可观察状态持有层，使用 `@Observable` 和 `@MainActor`。ViewModel 保存 UI 投影和纯 UI 状态，不保存第二份可写的业务事实。

| ViewModel | 负责的投影 | 不负责 |
|---|---|---|
| `LibraryViewModel` | 三款游戏的快照、选中游戏、主操作语义、关联任务反馈 | 判断文件是否完整、组装 Wine 命令、写入持久化 |
| `GameDetailViewModel` | 方案列表、应用记录、风险和恢复事实 | 执行方案、修改系统、决定 `Applied` |
| `SettingsViewModel` | 配置、Wine 版本、恢复状态和 `LogExport` 投影 | 直接读写 JSON、下载运行时、直接调用 LogWriter |
| 其他流程 ViewModel | 对应任务的阶段、进度、结果和取消入口 | 直接调用 Infrastructure |

ViewModel 从 Domain 的只读快照和有序事件流构建投影。选中游戏、当前 Tab、窗口是否显示等 UI 状态由 ViewModel 独占，不进入 Game 业务聚合。

### 2.3 Domain Layer

Domain 负责领域对象、业务规则、事务编排、任务调度和状态事件。带有共享可变状态的 Domain 服务使用 Actor 隔离；无状态规则使用不可变值计算。Domain 不标记为默认 `MainActor`，也不持有 SwiftUI 类型。

| 模块 | 责任 |
|---|---|
| `GameRegistry` | 固定三款 Game、路径授权事实、业务状态和领域事件 |
| `GameStateMachine` | 校验 Game 状态转换，不执行 I/O |
| `PreLaunchValidator` | 汇总启动前文件、授权、完整性、运行环境和磁盘条件 |
| `FileIntegrityVerifier` | 基于有效 manifest 得出完整/不完整/不支持/执行失败 |
| `LaunchOrchestrator` | 按启动契约准备 Wine、构造命令、启动并确认进程 |
| `SolutionEngine` | 方案能力检查、快照、修改、验证、回滚和应用记录 |
| `WineVersionManager` | Product 批准托管 Wine 的来源选择、目录发现、asset 下载、安装提交和就绪判断；不检测外部 Wine |
| `PerformanceOptionManager` | 当前版本允许的少量启动环境选项 |
| `VersionChecker` | 本地版本与官方版本比较，不执行完整更新 |
| `TaskScheduler` | 任务接收、互斥、排队、进度、取消和任务事件 |

### 2.4 Infrastructure Layer

Infrastructure 只提供外部能力，不决定业务状态。

| 模块 | 责任和权限边界 |
|---|---|
| `PersistenceStore` | `AppData.json` 的读取、备份、迁移、原子写入和恢复 |
| `GameFileSystemRepository` | 容器内文件和用户选择目录的 scoped 访问；不绕过授权 |
| `ProcessManager` | `Process` 生命周期、stdout/stderr、超时和退出事实 |
| `WineRuntimeProvider` | 执行指定 Wine 二进制、准备 `WINEPREFIX`，不选择版本 |
| `WineVersionDownloader` | 下载、临时文件、完整性检查和解压 |
| `NetworkDownloadProvider` | HTTP、响应状态、下载取消和网络错误 |
| `SystemEnvironmentDetector` | 仅提供仍在产品范围内的 macOS、Apple Silicon 和磁盘能力；不提供 Wine 路径、版本或可用性 |
| `SystemModificationGateway` | 仅代理明确允许的 `/etc/hosts`、hostname 系统修改；不接受任意 shell |
| `LogWriter` | 结构化、脱敏日志；OSLog、App Support flush/轮转和导出，不承载业务状态 |

## 3. 依赖与通信

```text
SwiftUI View
  → @MainActor @Observable ViewModel
    → Domain command/query
      → Domain actor
        → Infrastructure actor / value service
```

- UI 不跨过 ViewModel 访问 Domain 或 Infrastructure。
- ViewModel 不把 Domain Actor 当作 `@Observable` 属性直接绑定；它订阅 Domain 的快照/事件流并更新自己的投影。
- Domain 只能依赖 Infrastructure 的能力边界；Infrastructure 不依赖 UI 或 ViewModel。
- 领域服务之间只通过 Sendable 值、命令结果和事件通信；不传递 `Process`、`URLSessionTask`、SwiftUI View 或 ViewModel。
- Domain 服务可以向同一 `LogWriter` actor 提交脱敏 LogEvent；UI/ViewModel 不持有 LogWriter，日志导出必须经过 Domain `LogExport` task。
- 共享可变资源必须只有一个 Actor 作为所有者：游戏业务状态归 `GameRegistry`，任务归 `TaskScheduler`，持久化文件归 `PersistenceStore`，进程表归 `ProcessManager`。

## 4. 应用启动顺序

1. App 组装 Infrastructure 和 Domain 服务；不在 UI 初始化中执行文件、网络或进程工作。
2. `PersistenceStore` 读取 `AppData.json`，执行 schema 检查和必要迁移。
3. 若数据损坏且未完成恢复，Domain 进入 `recoveryRequired`；不能用默认值伪装成用户设置或已授权路径。
4. `GameRegistry` 从已验证数据恢复三款 Game；旧裸路径只进入迁移状态，不能直接作为授权。
5. `LaunchOrchestrator/GameRegistry` 在发布初始快照前扫描 launch session、`Running` 和 recovery record；无法验证活动进程时建立持久 restart recovery guard。
6. `TaskScheduler` 将上次退出时的 `pending/running` 标记为中断失败或恢复待确认，绝不自动重放副作用任务。
7. ViewModel 创建订阅，再取得带序列号的初始快照；后续只按事件顺序更新业务和 Accessibility projection。
8. UI 展示快照和恢复状态。只有在 Domain 给出可信业务结果后才改变主操作语义。

## 5. 权限总览

### 5.1 用户选择的游戏目录

- `GameLocation` 的 security-scoped bookmark 是长期授权凭据；`lastKnownPath` 只用于显示和迁移提示。
- 每次读取或写入都必须解析 bookmark、处理 stale、`startAccessingSecurityScopedResource()`，在同一操作作用域内完成工作，最后匹配 `stopAccessing...()`。
- 当前工程沙盒能力为用户选择文件只读。读取和完整性校验可以继续；游戏目录写入、替换 DLL、创建备份等需要读写 entitlement 和读写 bookmark。能力未满足时返回 `PermissionAccess.unavailable`，不尝试提权。

### 5.2 系统资源

- 游戏目录授权不扩大到 `/etc/hosts`、`/etc/hostname` 或其他系统资源。
- `/etc/hosts` 和 hostname 只通过 `SystemModificationGateway` 的固定操作进入；普通 Domain 服务不调用 `bash`、`sudo` 或任意系统命令。
- 系统修改必须先保存原状态，修改后读回验证；应用中途取消转入不可取消的恢复流程。

## 6. 启动命令的架构契约摘要

启动不是“执行一个 exe”这么简单，`LaunchOrchestrator` 必须向 `WineRuntimeProvider` 提供以下完整事实：

| 项目 | 冻结值 |
|---|---|
| Wine binary | `WineVersionManager` 选定的 MiPlay 托管版本 `bin/wine`；没有可验证托管 binary 则失败，不回退系统 Wine |
| Game executable | 从目标 Game 的受支持相对路径中找到的第一个可执行文件；以绝对路径作为 Wine 的第一个游戏参数 |
| 参数 | 当前版本只允许产品定义的游戏固定参数和已启用性能选项；不接受用户任意参数 |
| `WINEPREFIX` | 应用容器内 `Application Support/MiPlay/WinePrefixes/<stableGameID>`，每款游戏独立，不使用游戏目录作为 prefix |
| DLL override | `WINEDLLOVERRIDES=winemenubuilder.exe=d`；由 prefix 准备和游戏启动沿用，不由用户输入覆盖 |
| 其他环境变量 | 继承受控基础环境，再合并产品允许的性能环境变量；同名键的最终值必须可记录 |
| 工作目录 | 游戏安装目录的已解析 scoped URL；scope 在进程启动和必要的确认阶段保持有效 |
| 成功门槛 | 创建进程只是中间事实；在确认窗口内验证进程仍运行并达到可运行判定后，才产生 `runningConfirmed` |

详细输入、失败、取消、恢复、持久化和用户反馈行为见 `architecture-service-contracts.md` 与 `architecture-phase3-contracts.md`。

本轮四个 P1 的契约和影响范围见 `architecture-p1-repair-impact.md`；它是 Implementation 的直接交付边界，不允许 Implementation 自行解释 Receipt、recoveryRequired 或 stale bookmark 行为。

## 6.1 Phase 3 新增冻结边界

- Wine 的可用目录只来自用户当前选择的 Product 批准托管来源；官方 GitHub 为默认，allowlist 镜像必须主动选择，来源失败不自动换源，系统 Wine/Whisky/CrossOver 不得检测、选择、回退或启动。
- `WineCatalogQuery` 只产生 API/Release metadata 目录结果；`WineAssetDownload` 独立取得 asset。两者都不能单独产生 `WineReady`，后者仍要求 artifact、安装记录、环境准备和重读验证。
- `pkg_version`、`config.ini` 和 IntegrityManifest 分别保留来源与用途；冲突时不得发布可信版本、完整性或 Running。
- stale bookmark 的刷新写回必须在五个消费者共享的 scoped lease 内完成，并在真实写回/重读后发布消费者结果。
- AccessibilityProjection 由对应 `@MainActor` ViewModel 从结构化快照/事件生成；UI 不从视觉效果或 Process 中间事实推断状态。

## 7. 上游追溯

| 上游冻结内容 | 本架构承接 |
|---|---|
| Product：三款固定游戏、定位路径、不做完整安装更新 | `GameRegistry` 固定三款；没有 `GameInstall/GameUpdate` 当前任务 |
| Product：CS-01 条件发布；A-02/A-03/A-06 Deferred；CS-05 Out of Scope | `SolutionEngine` 只允许 CS-01；Deferred/Out of Scope 返回 `Unavailable` |
| Research：Actor 服务层、任务状态解耦、Apple Sandbox 约束 | Actor 所有权、Domain 事件流、bookmark 和 helper 边界 |
| UX：任务状态和业务结果分离 | TaskScheduler 任务模型与 Game/Integrity/Solution 独立结果 |
| UX：启动须进程确认、取消须清理确认 | LaunchOrchestrator 和任务取消契约 |
| UI：主窗口、路径流程、详情窗口、Settings、Wine 反馈 | ViewModel 投影边界和事件订阅对象 |
| UI：UI 不创造状态 | Domain 是业务事实唯一写入者，ViewModel 只投影 |

### 7.1 逐项追溯矩阵

| 来源文件 | 冻结要求 | Architecture 落点 | 可验证证据 |
|---|---|---|---|
| `Docs/00-product/product-features.md` | 游戏启动 | `LaunchOrchestrator` + `GameLaunch` + 进程健康确认 | `architecture-service-contracts.md` §6、`architecture-task-queue.md` §1.2 |
| 同上 | Wine 版本管理，用户无需手动配置 | `WineVersionManager` 托管来源选择、`WineCatalogQuery/WineAssetDownload`、`WineRuntimeProvider` 执行 | `architecture-domain-model.md` §4、服务契约 §7、Revision §4 |
| 同上 | CS-01 条件发布；A-02/A-03/A-06 Deferred；CS-05 Out of Scope | 发布清单约束、`SystemModificationGateway`、`Unavailable` | `architecture-domain-model.md` §5、服务契约 §11-12、Revision §6-7 |
| 同上 | 三款游戏状态总览 | 固定三款 GameLibrary 和 GameStateMachine | `architecture-domain-model.md` §2、状态所有权 §1 |
| 同上 | 定位已安装路径 | GameLocation bookmark 生命周期和旧 path 迁移 | `architecture-domain-model.md` §3、通信 §5 |
| 同上 | 完整性校验 | `IntegrityVerification` + 有效 manifest 结果 | 服务契约 §5、任务队列 §1.2 |
| 同上 | 版本检测/背景素材/性能选项/日志 | `VersionCheck`、`BackgroundMediaLoad`、PerformanceOptionManager、LogWriter | 任务队列 §1.2、服务契约 §15-16、概览 §2.3-2.4 |
| Product：日志导出属于 Should/In Scope | `LogExport` task + 脱敏 LogWriter bundle；不作为业务成功证据 | `architecture-logging-contract.md` §6-8、服务契约 §16 |
| `Docs/01-research/research-architecture-patterns.md` | 单向分层、Domain 服务、任务队列 | 四层依赖和 TaskScheduler 所有权 | 概览 §2-3、任务队列 §3 |
| `Docs/01-research/research-pattern-library.md` | Actor 隔离、任务状态解耦、双队列 | 独立 Actor、foreground/background lane、事件流 | ADR 002、ADR 008、状态所有权 §2-3 |
| `Docs/01-research/research-ux-patterns.md` | 统一 logger、异常退出记录、非阻塞诊断 | LogWriter actor、关键阶段事件、日志与用户错误分离 | `architecture-logging-contract.md` §3、§7-8、ADR 030 |
| `Docs/01-research/research-apple-platform-constraints.md` | bookmark scope、read-only entitlement、helper/XPC、Process 终止确认 | GameLocation、权限分离、ProcessManager、SystemModificationGateway | ADR 004-007、通信 §5-7、服务契约 §9-11 |
| `Docs/02-ux/ux-information-model.md` | Task 与业务结果分离 | TaskSnapshot + outcome/error/recovery | 任务队列 §2、服务契约 §1 |
| 同上 | LaunchOutcome、PermissionAccess、Integrity、Runtime、AppDataRecovery | 领域对象和错误传播模型 | 领域模型 §3-8、通信 §4、服务契约 §13 |
| `Docs/02-ux/ux-state-flow.md` | 启动确认、清理、完整性、方案回滚和数据恢复流程 | Launch/Integrity/Solution/Persistence 生命周期 | 领域模型 §2、§5、§6；任务队列 §5、§8 |
| `Docs/03-ui/ui-screen-inventory.md` | MainWindow、PathLocationFlow、GameDetailWindow、Settings、WineProgressSheet | ViewModel 归属和事件投影 | 概览 §2.1-2.2、状态所有权 §4 |
| `Docs/03-ui/ui-view-responsibility.md` | UI 不执行任务、不判断业务结果 | UI → ViewModel，Domain 是事实源 | 概览 §2.1-2.2、通信 §1 |
| `Docs/03-ui/ui-component-tree.md` | 主操作、任务反馈、授权反馈不新增业务状态 | Task/业务/权限三类输入分离 | 状态所有权 §4、任务队列 §9 |
| `Docs/03-ui/ui-state-mapping.md` | pending/running/结果分开；Running/Applied 需真实门槛 | Domain event commit、LaunchOutcome、SolutionApplication | ADR 003、007、010、011 |
| `Docs/01-research/research-yaagl-download-and-metadata.md` | GitHub API/Release asset 分离、镜像限制、`pkg_version` JSON Lines + MD5、`config.ini` 原始证据 | Wine source policy、WineAssetDownload、LocalGameEvidence、VersionChecker | Revision §4-5、ADR 023-029 |
| `Docs/03-ui/ui-validation-and-accessibility.md` | Accessibility Tree 状态、进度、错误恢复由结构化事实表达 | ViewModel AccessibilityProjection ownership | Communication §9.1、State Ownership §4.3、ADR 021 |
| `Docs/02-ux/ux-state-flow.md` | Wine source result、证据冲突、重启恢复和 stale refresh flow | RuntimeSourceResult、LocalGameEvidence、ProcessExitRecoveryRecord、ScopedGameLocationAccess | Phase 3 契约 §2-5 |

追溯规则：实现阶段每个验收项至少能定位到一个 Domain/Infrastructure 结果和一个 ViewModel 投影；若只有 UI 文案而没有事实来源，不视为已覆盖。

## 8. 实现约束

- 本架构不允许以“Domain `@Observable` 属性直接被 ViewModel 引用”实现状态传播。
- 本架构不允许把一个默认 `MainActor` 的服务作为所有 Domain/Infrastructure 服务的并发方案。
- 本架构不允许把裸路径、进程创建、命令返回、备份成功或任务 `completed` 单独升级为业务成功。
- 本架构不新增通用 UI 框架、通用协议层或未来扩展用的抽象；每个边界只为当前产品问题服务。
