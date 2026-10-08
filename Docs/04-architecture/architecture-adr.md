# MiPlay 架构决策记录

> **文档状态**：已冻结（Architecture 回溯；2026-08-28 重置 I-4 运行时模型，并保留 I-1/I-5 契约）
> **更新日期**：2026-08-28
> **用途**：记录本阶段冻结的架构决策。实现不得绕过已接受决策；若发现决策与平台事实冲突，必须回溯 Architecture。

## ADR 001：采用四层单向依赖

- **状态**：Accepted
- **决策**：固定依赖方向为 UI → ViewModel → Domain → Infrastructure。UI 只读取 ViewModel，ViewModel 只提交用户意图和读取 Domain 结果，Domain 只调用 Infrastructure 能力，Infrastructure 不依赖上层。
- **理由**：产品同时包含进程、文件、权限、持久化和任务生命周期；把这些逻辑放入 UI 会造成状态反向传播和不可测试的权限路径。四层足以表达当前复杂度，不引入额外框架层。
- **备选方案**：A（View 直接调用 Service）— 未采纳，因为会让权限、错误和业务转换进入 UI；B（TCA/Reducer 全量框架）— 未采纳，因为当前产品没有足以抵消额外抽象的状态规模；C（Domain 依赖 ViewModel）— 未采纳，因为违反单向依赖。
- **Trade-off**：增加 ViewModel 和事件映射工作；收益是权限、错误和状态来源可单独验证。
- **影响范围**：所有目录、依赖注入、状态读取和测试边界。

## ADR 002：共享可变状态使用独立 Actor，禁止 Domain 默认 MainActor

- **状态**：Accepted
- **决策**：GameRegistry、TaskScheduler、SolutionEngine、WineVersionManager、PersistenceStore、ProcessManager、文件/网络等共享资源服务各自 Actor 隔离。`@MainActor` 仅用于 SwiftUI View 和 ViewModel；纯规则保持不可变值计算。
- **理由**：进程表、文件状态、任务队列和 JSON 写入存在并发访问，Actor 能提供编译器可检查的隔离。把所有服务放到 MainActor 会阻塞 UI，并不能解决系统资源权限问题。
- **备选方案**：A（所有服务 MainActor）— 未采纳，因为耗时 I/O 和进程等待不应占用 UI executor；B（class + locks）— 未采纳，因为锁粒度和取消传播容易出错；C（所有状态通过全局单例）— 未采纳，因为隐藏共享所有权。
- **Trade-off**：跨 Actor 调用产生 async 边界，需使用 Sendable 快照和事件；这是可接受的并发显式成本。
- **影响范围**：Domain/Infrastructure 服务签名、依赖组装、测试和事件消费。

## ADR 003：ViewModel 使用 @Observable 投影 Domain 事件，不直接观察 Domain Actor

- **状态**：Accepted；取代旧的“ViewModel 直接引用 Domain 可观察属性”描述
- **决策**：ViewModel 是 `@MainActor @Observable` 的唯一 UI 状态源。Domain Actor 暴露带序列号的 snapshot 和 AsyncSequence 事件；ViewModel 在主 Actor 消费并生成自己的 UI 投影，不保存可写业务副本。
- **理由**：Actor 隔离后的内部属性不能安全地作为 SwiftUI 绑定源；直接引用会产生跨隔离观察、竞态和生命周期不明确的问题。快照 + 有序事件能处理初始订阅竞态、重复和序列空洞。
- **备选方案**：A（Domain `@Observable` 直接绑定）— 未采纳，因为它混合业务所有权与 UI 观察；B（每次渲染异步查询）— 未采纳，因为会产生频繁跨 Actor 调用和不稳定的渲染时序；C（ViewModel 复制完整业务状态）— 未采纳，因为产生第二个事实源。
- **Trade-off**：需要维护事件序列、快照重建和投影代码；换来单一业务所有权和可恢复的订阅语义。
- **影响范围**：LibraryViewModel、GameDetailViewModel、SettingsViewModel、所有 Domain event stream 和 UI 状态映射。

## ADR 004：用户选择的游戏目录使用 security-scoped bookmark 作为唯一长期授权

- **状态**：Accepted
- **决策**：每款 Game 持久化 bookmark Data、scope 类型、解析状态和 lastKnownPath。裸路径只用于旧数据迁移和显示，不用于读取、写入或启动。每次操作按解析 → stale 更新 → startAccessing → scoped work → stopAccessing 生命周期执行。
- **理由**：App Sandbox 中路径字符串不携带授权；bookmark 才能跨重启恢复用户选择。scope 的开始和释放必须与一次操作配对，避免资源泄漏和越权。
- **备选方案**：A（只保存绝对 path）— 未采纳，因为重启后不能证明授权；B（应用启动时长期 startAccessing）— 未采纳，因为会泄漏 scope 且难以界定生命周期；C（自动从旧 path 生成 bookmark）— 未采纳，因为没有新的用户授权事实。
- **Trade-off**：需要处理 stale、卷不可用和重新授权流程；这是沙盒正确性所需成本。
- **影响范围**：GameLocation、GameRegistry、GameFileSystemRepository、PathLocationFlow、AppData 迁移。

## ADR 005：游戏目录权限与系统修改权限严格分离

- **状态**：Accepted
- **决策**：用户选择目录只授权该目录的 scoped 访问；不扩大为 root 或系统路径权限。`/etc/hosts` 和 hostname 只能通过受限 `SystemModificationGateway` 和签名/批准的 helper/XPC 执行固定 allowlist 操作，不接受任意 shell、sudo 或路径。
- **理由**：沙盒子进程继承主应用边界，游戏目录 bookmark 不能解决系统资源写入。系统修改必须有最小权限、备份、读回验证和可恢复边界。
- **备选方案**：A（普通 Process 调 bash/sudo）— 未采纳，因为不可审计、不能形成最小权限边界；B（关闭 App Sandbox）— 未采纳，因为扩大所有资源权限且违反平台约束；C（将所有文件操作交给一个万能 helper）— 未采纳，因为权限范围和风险过大。
- **Trade-off**：需要额外 helper/XPC 签名、批准和发布验证；未安装/未批准时 CS-01 只能显示不可用，A-06/hosts 本轮 Deferred。
- **影响范围**：CS-01、SolutionEngine、SystemModificationGateway、发布签名和 QA 权限矩阵。

## ADR 006：冻结 Wine 启动命令和 prefix 归属

- **状态**：Deprecated；由 ADR 037-039 取代
- **决策**：由 WineVersionManager 决定已验证的 MiPlay 托管 Wine；WineRuntimeProvider 只验证并准备该 binary。Process 执行 Wine binary，参数为绝对游戏 exe 加固定/性能参数；工作目录为游戏目录；每款 Game 使用 App Support 下独立 prefix；环境固定包含 `WINEPREFIX` 和 `WINEDLLOVERRIDES=winemenubuilder.exe=d`。不检测或使用系统 Wine。
- **理由**：将“选择哪个 Wine”和“如何执行 Wine”分离，避免多个决策者。独立 prefix 避免游戏之间相互污染，固定 DLL override 确保 prefix 准备与启动一致。参数数组避免 shell 注入和转义歧义。
- **备选方案**：A（Process 直接执行 Windows exe）— 未采纳，因为 macOS 不能直接执行目标 exe；B（每款游戏共用一个 prefix）— 未采纳，因为兼容配置和 DLL 状态会互相污染；C（让 UI/用户自由传环境和参数）— 未采纳，因为当前产品明确延期自定义启动参数且扩大风险。
- **Trade-off**：命令灵活性受限，新增参数必须回溯产品和架构；收益是可审计、可复现的启动行为。
- **影响范围**：LaunchOrchestrator、WineRuntimeProvider、WineVersionManager、ProcessManager、启动日志和启动测试。

## ADR 007：启动成功必须经过进程健康确认

- **状态**：Accepted
- **决策**：Process 创建只是中间事件。只有进程在确认期限内仍运行并达到可运行判定，LaunchOrchestrator 才产生 `runningConfirmed`，GameRegistry 才允许进入 `Running`。超时、异常退出、终止未确认均为失败或恢复待确认。
- **理由**：命令返回和 PID 存在不能证明游戏真正运行；进程可能立即退出、缺少环境或需要清理。UX 已冻结“任务状态与运行结果分离”。
- **备选方案**：A（`Process.run()` 返回即成功）— 未采纳，因为无法覆盖立即退出；B（固定 sleep 后当作成功）— 未采纳，因为没有事实保证且受机器性能影响；C（UI 轮询 PID）— 未采纳，因为绕过 ProcessManager 的唯一进程所有权。
- **Trade-off**：启动反馈增加等待阶段；换来不误报 Running 和明确的超时恢复路径。
- **影响范围**：LaunchOrchestrator、ProcessManager、GameStateMachine、LibraryViewModel、启动任务测试。

## ADR 008：TaskScheduler 使用任务事实与业务 outcome 分离的串行/后台通道

- **状态**：Accepted
- **决策**：任务状态只允许 `pending/running/completed/failed/cancelled`；前台副作用任务串行，完整性、版本和媒体任务可在资源锁允许时后台并行。每个任务独立记录 phase、可选 progress、outcome、error、recovery 和 cancellation policy。
- **理由**：UX 要求用户区分请求、执行、验证和恢复事实；不同 Game 的后台读取不应阻塞用户启动，但同一 Game 的文件写入和启动必须互斥。
- **备选方案**：A（所有操作共用一个无优先级队列）— 未采纳，因为后台媒体/版本检查会阻塞启动；B（每个 Domain 服务自己维护队列）— 未采纳，因为跨服务互斥无法统一；C（将 `completed` 直接映射为业务成功）— 未采纳，因为完整性失败和恢复任务也可以可信完成。
- **Trade-off**：需要资源锁和恢复规则；避免了分散队列造成的竞态和错误成功提示。
- **影响范围**：TaskScheduler、所有耗时 Domain 服务、ViewModel 任务投影和任务持久化。

## ADR 009：持久化采用带 schema、备份和原子验证的单一 JSON

- **状态**：Accepted；取代“无迁移策略”的旧描述
- **决策**：所有当前业务持久化集中在 App Support 的 `AppData.json`。数据带 schema version；旧格式先备份再逐版本迁移。写入使用临时文件、解码验证和原子替换；维护最后一份可读 `.bak`。损坏时保留原文件，恢复必须由备份重读验证或用户明确重新开始。
- **理由**：当前数据量小，单文件便于一致性；原子写入和备份解决 JSON 的全量替换风险。security-scoped bookmark 迁移需要明确 schema，不可继续依赖裸 path。
- **备选方案**：A（Core Data/SQLite）— 未采纳，因为关系和查询规模不足以抵消依赖/迁移复杂度；B（UserDefaults）— 未采纳，因为不适合 bookmark、任务和恢复记录；C（损坏时静默使用默认值）— 未采纳，因为会丢失用户路径和设置且造成错误成功状态。
- **Trade-off**：全量编码和恢复 UI 增加实现成本；数据规模小，成本可控且可诊断性更强。
- **影响范围**：PersistenceStore、AppData、GameLocation 迁移、任务恢复、Settings 状态和启动初始化。

## ADR 010：外部副作用采用备份-修改-验证-恢复事务

- **状态**：Accepted
- **决策**：兼容方案和需要修改系统/游戏文件的操作依次执行能力检查、应用前快照、修改、后置读回验证、记录提交。失败或取消若已产生副作用，自动进入不可取消恢复；恢复读回一致才可得到 `RolledBack/cancelled`。
- **理由**：备份存在、命令返回和日志成功都不能证明修改生效；系统权限可能在执行过程中失效。事务化流程把“是否改过”和“是否恢复”作为显式事实。
- **备选方案**：A（先修改，失败后尽力恢复）— 未采纳，因为缺少应用前基线；B（只保存 `.bak` 文件，不做读回）— 未采纳，因为不能证明恢复内容一致；C（取消立即终止整个任务）— 未采纳，因为会留下部分系统状态。
- **Trade-off**：修改操作不能在某些阶段即时取消，回滚可能耗时；这是系统一致性优先的必要限制。
- **影响范围**：SolutionEngine、SystemModificationGateway、GameFileSystemRepository、TaskScheduler、方案记录和 UI 取消语义。

## ADR 011：Domain 事件在提交后发布，事件流以序列号恢复

- **状态**：Accepted
- **决策**：需要持久化的业务变更先通过 PersistenceStore 写入并重读验证，再发布 `committed` DomainEvent。事件带单调序列和聚合 revision；ViewModel 采用快照+订阅握手，检测空洞后重取快照。
- **理由**：先发事件再写盘会让 UI 显示不可恢复的成功；只靠通知会丢事件或重复应用。序列化事件和快照能处理 Actor 调度、应用启动和 UI 生命周期。
- **备选方案**：A（ViewModel 定时轮询）— 未采纳，因为延迟和竞态不可控；B（先更新 ViewModel 再异步保存）— 未采纳，因为写入失败会产生假状态；C（无序广播通知）— 未采纳，因为无法检测丢失或重复。
- **Trade-off**：持久化延迟会出现在状态反馈前；这是避免错误成功的明确取舍。
- **影响范围**：GameRegistry、TaskScheduler、PersistenceStore、所有 ViewModel 订阅和恢复测试。

## ADR 012：TaskReceipt 以 pending 持久化提交为接受门槛

- **状态**：Accepted
- **决策**：TaskScheduler 只有在 pending Task 写入 AppData 并重读验证后才返回 `TaskReceipt`。Receipt 必须包含 task/intent/target、事件 cursor、资源锁、取消策略和 `persistence=committed`。固定 `WineRuntimeSetup` 使用全局 `wineRuntime` 互斥：同一固定目标重复请求复用已有 Receipt；已有 setup、升级或恢复未收敛时返回带冲突 Task ID 的拒绝，不创建第二个 setup。
- **理由**：只有裸 Task ID 无法证明任务已被持久接受；Wine 版本目录和安装记录是共享资源，多个下载会造成临时目录、选择和取消状态冲突。
- **备选方案**：A（先返回 Receipt 再异步写 pending）— 未采纳，因为崩溃或写入失败会产生不存在的任务；B（允许多个 WineRuntimeSetup pending）— 未采纳，因为固定 runtime/shared prefix 资源和恢复语义会交叉；C（Settings 直接消费 Wine 流）— 未采纳，因为绕过统一取消、历史和事件投影。
- **Trade-off**：持久化短暂不可用时用户不能立即提交任务；这是避免任务丢失和伪接受的必要门槛。
- **影响范围**：TaskScheduler、WineVersionManager、SettingsViewModel 的调用入口、Task history、TaskReceipt 测试。

## ADR 013：任务终态必须经过持久化提交和重读验证

- **状态**：Accepted
- **决策**：`completed` 只有业务 outcome、相关 AppData 写入和重读验证全部通过才可发布；`failed` 只有目标未达成且外部副作用已清理、失败记录可重读才成立；`recoveryRequired` 不是 Task.status，而是持久化的恢复保护事实。固定 Wine artifact 和 shared prefix 在 runtime/prefix pair 提交前始终是 staged 或 recovery 事实，不得列为已安装或 ready。
- **理由**：P1-REV-002 证明吞掉 `markVersionInstalled` 错误会把内存 artifact 误报为已安装。把提交验证设为终态门槛可以阻止 UI 和 Domain 产生不同事实。
- **备选方案**：A（下载/解压完成即 completed）— 未采纳，因为 AppData 可能没有安装记录；B（写入失败静默重试后仍先完成）— 未采纳，因为事件顺序会误导 UI；C（把 recoveryRequired 加入 Task.status）— 未采纳，因为 UX 已冻结五种 Task 生命周期，恢复是跨任务保护事实。
- **Trade-off**：终态反馈可能因磁盘写入或重读延迟；实现必须保留 staged artifact 清理和恢复路径。
- **影响范围**：WineVersionManager、PersistenceStore、TaskScheduler、DomainEvent、Wine 下载验收。

## ADR 014：进程退出先提交终态，再释放 session guard

- **状态**：Accepted
- **决策**：ProcessExitEvent 由 LaunchOrchestrator 转为正常/异常目标状态，并与 termination record 一起提交、重读验证。提交成功后才清除同 Game 的 session guard、lifecycle lock、scope 和 Process reference。提交失败建立 `ProcessExitRecoveryRecord`/`recoveryRequired`，保留同目标锁；恢复命令只重试幂等的退出终态提交，不重新启动游戏。
- **理由**：进程已退出但 Game 状态写入失败时，直接释放保护会留下持久 `Running` 和可重复启动的矛盾事实。恢复记录让下一次启动能阻止副作用并提供明确重试路径。
- **备选方案**：A（退出后先释放资源，再后台保存）— 未采纳，因为保存失败会丢失保护；B（把 Game 新增为 ProcessExited 状态）— 未采纳，因为这是恢复事实而非用户业务状态；C（恢复时自动重新启动）— 未采纳，因为恢复只能收敛旧事实，不能创建新副作用。
- **Trade-off**：状态持久化异常时同 Game 会暂时不可启动；这是避免重复进程和错误 Running 的优先级取舍。
- **影响范围**：LaunchOrchestrator、GameRegistry、ProcessManager、TaskScheduler、AppData 恢复和启动重试。

## ADR 015：所有 stale bookmark 消费者共用解析-刷新-提交生命周期

- **状态**：Accepted
- **决策**：GameFileSystemRepository 返回带 lease 的 `ScopedGameLocationAccess`，其中包含 resolved URL、resolved/refreshed GameLocation 和 stale 事实。定位、完整性、版本检查、PreLaunchValidator 和 LaunchOrchestrator 必须在同一流程中解析、startAccessing、刷新 bookmark、提交 refreshed location、提交消费者结果，再 stopAccessing。刷新提交失败时保留旧 stale 记录并进入 recoveryRequired，不发布本次消费者成功结果。
- **理由**：P1-REV-004 表明只在定位和状态刷新路径回写 bookmark 会让完整性、版本和启动路径继续使用旧 bookmark。统一 lease 和提交门槛避免每个消费者自行解释 stale。
- **备选方案**：A（各消费者自行处理 stale）— 未采纳，因为必然出现遗漏和生命周期差异；B（只更新内存 location）— 未采纳，因为重启后 stale 仍会复现；C（刷新失败回退 lastKnownPath）— 未采纳，因为 path 不携带 security scope。
- **Trade-off**：只读任务也可能因 bookmark 刷新持久化失败而暂时不能报告完成；这保证持久授权事实和业务结果不分叉。
- **影响范围**：GameFileSystemRepository、GameLocation、GameRegistry、FileIntegrityVerifier、VersionChecker、PreLaunchValidator、LaunchOrchestrator 和路径任务重试。

## ADR 016：当前版本只使用 MiPlay 托管 Wine

- **状态**：Accepted
- **决策**：只有由 MiPlay 从产品固定批准来源取得、保存、校验、安装并提交记录的唯一 `ManagedWineRuntime`，以及与其绑定的 `SharedWinePrefix`，才能进入 `RuntimeEnvironment`、`WineReady` 或游戏启动。系统 Wine、Whisky、CrossOver 和用户路径不被检测、展示、导入或使用。
- **理由**：Product 已冻结“托管 Wine 是唯一可用运行时”；外部 binary/prefix 的来源、版本、权限和可复现性无法由检测路径证明。
- **备选方案**：A（无托管版本时回退系统 Wine）— 未采纳，因为会绕过 Product allowlist 和安装验证；B（导入 Whisky/CrossOver bottle）— 未采纳，因为引入未知 prefix 权属和运行时污染；C（允许用户指定 Wine path）— 未采纳，因为超出当前产品边界。
- **Trade-off**：批准来源不可用时用户不能启动，即使系统存在 Wine；换取启动事实可追溯、可验证和一致的权限边界。
- **影响范围**：WineVersionManager、RuntimeEnvironment、SharedWinePrefix、WineRuntimeProvider、LaunchOrchestrator、SettingsViewModel 和启动验收。

## ADR 017：Wine 来源由用户从 allowlist 主动选择

- **状态**：Deprecated；由 ADR 037、040 取代
- **决策**：新增 `WineCatalogQuery`、`WineAssetDownload` 和 `WineSourceSelection` 契约。官方 GitHub 是默认来源；用户可从 Product allowlist 主动选择预置可信镜像。来源失败不自动切换，用户必须主动改选另一个预置来源；不接受任意 URL、host、token 或 header。
- **理由**：Research 证明现有 API proxy 不等于 Release asset 镜像，当前第三方 proxy 没有固定版本、内容等价和完整响应验证证据。将其当作默认镜像会把不可信网络行为变成运行时事实。
- **备选方案**：A（API/asset 任意最快源竞速）— 未采纳，因为最快不等于身份和内容可信；B（自动增加第三方镜像）— 未采纳，因为没有批准和可验证证据；C（网络失败回退系统 Wine）— 未采纳，因为违反 ADR 016。
- **Trade-off**：当前来源不可达时目录查询或下载失败，即使另一个预置来源可能可用；换来用户可见、可审计的来源选择和不会静默改变供应链的行为。
- **影响范围**：WineSourceSelection、WineCatalogQuery、WineAssetDownload、NetworkDownloadProvider、403/429/空列表/asset 错误、SettingsViewModel 和目录缓存。

## ADR 018：`pkg_version` 与 `config.ini` 作为分离的本地证据

- **状态**：Accepted
- **决策**：`pkg_version` 按 JSON Lines 解析并使用条目 `fileSize + md5` 事实；`config.ini` 只读取 `game_version`、`channel`、`sub_channel`、`cps`、可选 `sdk_version`。两者分别进入 `LocalGameEvidence`，必须关联 Game/location/manifest 后才能参与版本判断；`wpf_version` 不产生当前事实。
- **理由**：Research 已核实两种文件的格式和用途不同；`pkg_version` 不是统一版本源，`config.ini` 也不能替代 IntegrityManifest 或官方版本。
- **备选方案**：A（把 `pkg_version` 当完整性真相）— 未采纳，因为存在空文件、渠道差异和非通用存在性证据；B（把 `config.ini.game_version` 当唯一版本）— 未采纳，因为它是最后更新记录且可与实际文件冲突；C（缺失时用关键 exe 存在替代）— 未采纳，因为无法证明版本或完整性。
- **Trade-off**：版本检测会有“无法确认/证据冲突”结果，需要更多读取和关联；换取不误报完整或最新。
- **影响范围**：LocalGameEvidenceReader、FileIntegrityVerifier、VersionChecker、GameRegistry、版本/完整性 UI 投影和日志。

## ADR 019：stale bookmark 必须有真实刷新和写回验证边界

- **状态**：Accepted
- **决策**：五个消费者只能消费 `ScopedGameLocationAccess`。stale bookmark 生成的新 Data 必须在当前 scope 内原子写回、重读验证并在重启后重新解析；写回成功前不发布消费者结果。Implementation 必须验证 fresh、stale 成功、写回失败、access denied 和取消五种场景，并验证 scope 成对释放。
- **理由**：P1-REV-004 的调用覆盖不等于行为覆盖；没有真实写回和重启验证时，内存刷新会在下一次启动失效。
- **备选方案**：A（每个消费者自行处理 stale）— 未采纳，因为会产生遗漏和不同生命周期；B（只更新内存）— 未采纳，因为不持久；C（失败回退 lastKnownPath）— 未采纳，因为 path 不携带授权。
- **Trade-off**：只读任务也可能因 bookmark 写回失败暂时不能报告结果；换取持久授权与业务结果不分叉。
- **影响范围**：GameFileSystemRepository、GameRegistry、FileIntegrityVerifier、VersionChecker、PreLaunchValidator、LaunchOrchestrator、PersistenceStore 和测试矩阵。

## ADR 020：跨重启的 Running 必须经过 Process identity 恢复

- **状态**：Accepted
- **决策**：启动前持久化 launch session，Running 只在进程健康确认后提交。重启时 PID 不足以证明活动进程；必须匹配 executable、prefix、启动时间和 session identity 才可接管。没有可信进程时先持久化 restart recovery record、保留 lifecycle lock；无退出事实时以 `LaunchFailed(interruptedAfterRestart)` 保守收敛，不自动启动。
- **理由**：P1-REV-003 表明退出提交失败或应用重启可能留下持久 Running；只修改内存投影会在下一次重启再次暴露矛盾。
- **备选方案**：A（按 PID 恢复 Running）— 未采纳，因为 PID 可复用且无法证明身份；B（无进程直接 Installed）— 未采纳，因为不能推断正常退出；C（恢复时自动重启）— 未采纳，因为恢复不应创建新的副作用。
- **Trade-off**：崩溃或进程身份不可验证时可能暂时阻止启动；换取不会把未知状态伪装成 Running 或 Installed。
- **影响范围**：LaunchOrchestrator、ProcessManager、GameRegistry、PersistenceStore、AppData 启动扫描、LibraryViewModel 和恢复 UI。

## ADR 021：AccessibilityProjection 归属对应的 @MainActor ViewModel

- **状态**：Accepted
- **决策**：Domain 只输出结构化状态、phase、progress、outcome、error、side effect 和 recovery action；`LibraryViewModel`、`SettingsViewModel`、Path/Library ViewModel、`GameDetailViewModel` 各自生成本地化 AccessibilityProjection。SwiftUI View 只附加 label/value/hint/action，不从颜色、hover、状态点、spinner 或 Process 创建推断业务事实。
- **理由**：UI 文档已冻结完整 Accessibility Tree；将语义放入 View 会导致多个入口使用不同成功/恢复口径，将语义放入 Domain 又会污染分层和本地化边界。
- **备选方案**：A（集中式 AccessibilityTree 服务）— 未采纳，因为引入无使用场景的通用抽象；B（View 根据颜色/布局自行读状态）— 未采纳，因为不可测试且不能表达恢复事实；C（Domain 直接持有 UI 文案）— 未采纳，因为违反 Domain/UI 边界和多语言职责。
- **Trade-off**：每个 ViewModel 需要维护明确的 projection 映射；换取状态事实单一来源和 VoiceOver/键盘语义一致。
- **影响范围**：LibraryViewModel、SettingsViewModel、GameDetailViewModel、路径流程 ViewModel、Accessibility 验证和 UI 组件。

## ADR 022：Phase 3 Architecture 文档是完成口径唯一来源

- **状态**：Accepted
- **决策**：Implementation/QA 文档必须引用当前固定 Managed Wine、WineRuntimeSetup、SharedWinePrefix、LocalGameEvidence、restart recovery、stale writeback 和 AccessibilityProjection 口径；旧的系统 Wine fallback、下载完成即 Ready、配置文件即完整、PID 即 Running 和 UI 视觉推断均视为过时。
- **理由**：DOC-REV-001 表明下游完成口径分叉会让实现即使通过局部测试仍违反 Product/UX/Architecture 冻结事实。
- **备选方案**：A（各 Agent 保留本地解释）— 未采纳，因为无法形成可审计验收；B（只在 QA 末尾修正文档）— 未采纳，因为 Implementation 会在错误契约上继续扩散；C（修改 Product/UX 以适配实现）— 未采纳，因为回溯方向错误。
- **Trade-off**：下游文档同步成为显式交付项；换取跨阶段术语和验收口径一致。
- **影响范围**：Architecture downstream 文档、Implementation 任务、QA RTM、Review 追踪和 Release 验收。

## ADR 023：删除 system Wine detection 及其 Domain 依赖

- **状态**：Accepted
- **决策**：MiPlay 不扫描、展示、导入或记录系统 Wine、Whisky、CrossOver 或任意外部 Wine。`SystemEnvironmentDetector` 不再向 WineVersionManager、SettingsViewModel、PreLaunchValidator 或 RuntimeSelection 提供 Wine 事实；若该基础设施服务因其他 macOS 能力保留，Wine 依赖必须断开。
- **理由**：Product 已将 Managed Wine 冻结为唯一运行时；外部检测本身会形成与产品边界冲突的状态和 fallback 诱因。
- **备选方案**：A（只检测不使用）— 未采纳，因为仍会产生错误产品能力和持久/AX 投影；B（无托管版本时 fallback）— 未采纳，因为绕过来源、安装和可复现性验证。
- **Trade-off**：系统存在 Wine 时仍不能启动；换取唯一、可审计和可复现的 runtime 事实。
- **影响范围**：App 初始化、SystemEnvironmentDetector、WineVersionManager、SettingsViewModel、PreLaunchValidator、LaunchOrchestrator、依赖扫描和测试夹具。

## ADR 024：Wine source 采用用户主动选择的 Product allowlist

- **状态**：Deprecated；由 ADR 037、040 取代
- **决策**：官方 GitHub 是默认 source；用户只能主动选择预置 allowlist mirror。source ID、HTTPS endpoint、host/path、架构、release/asset 规则和 policy revision 由 Product 配置固定。来源失败不自动切换，用户只能重试或主动改选另一个预置 source。
- **理由**：研究无法把 API proxy、302 或速度证明为 Release asset 的内容等价镜像；主动选择使来源身份和失败反馈可审计。
- **备选方案**：A（固定顺序自动 fallback）— 未采纳，因为用户未选择且错误类别可能被掩盖；B（任意 URL/镜像输入）— 未采纳，因为供应链和权限不可验证；C（竞速最快源）— 未采纳，因为最快不等于可信。
- **Trade-off**：当前 source 失败会阻止下载，用户需要主动操作；换取不静默改变下载来源。
- **影响范围**：WineSourceSelection、SettingsViewModel、WineCatalogQuery、NetworkDownloadProvider、catalog persistence 和错误投影。

## ADR 025：API discovery、Release metadata 和 asset download 分离

- **状态**：Deprecated；由 ADR 040 取代
- **决策**：`WineCatalogQuery` 只发现和验证 API/Release metadata，输出 CatalogEntry；`WineAssetDownload` 只接收已验证 CatalogEntry 并取得 asset bytes。API 200、asset URL、302、Content-Length 或下载进度均不能单独产生 WineReady。
- **理由**：Research 已确认 API prefix、Release JSON 和 asset bytes 可能具有不同身份、重定向和失败行为；分离才能分别表达 403、429、空列表、asset forbidden 和内容不完整。
- **备选方案**：A（一个下载服务完成所有步骤）— 未采纳，因为职责混合会吞掉阶段错误；B（只按 URL 下载）— 未采纳，因为无法验证 release/asset identity；C（API 结果直接 Ready）— 未采纳，因为没有安装和内容证据。
- **Trade-off**：任务和持久化记录更多；换取错误、取消和重试边界可验证。
- **影响范围**：WineVersionManager、TaskScheduler、WineCatalogQuery、WineAssetDownload、NetworkDownloadProvider、Settings feedback。

## ADR 026：GameMetadata 只保存有证据的事实

- **状态**：Accepted
- **决策**：`config.ini` 保留原始 section/key/value；`pkg_version` 保留 JSON Lines 的 `remoteName/fileSize/md5`；二者进入按 Game ID 关联的 LocalGameEvidence。完整性必须依赖非空且版本对应的 manifest。未知字段、`wpf_version`、单独 `game_version` 或 `pkg_version` 不产生可信事实。
- **理由**：Research 证明字段含义、渠道和文件清单之间没有足够证据形成单一真相；保留原始值可以展示而不进行猜测。
- **备选方案**：A（把 game_version 当唯一版本）— 未采纳，因为可能与 manifest/远程版本冲突；B（把 pkg_version 当完整性 manifest）— 未采纳，因为空文件、映射和渠道可能不完整；C（丢弃未知字段）— 未采纳，因为 UI 仍需要展示原始证据。
- **Trade-off**：会出现候选、冲突和无法确认状态；换取不误报版本、渠道或完整性。
- **影响范围**：GameRegistry、LocalGameEvidenceReader、FileIntegrityVerifier、VersionChecker、metadata persistence 和 ViewModel projection。

## ADR 027：PerGameSettings 和 BackgroundGroup 以 Game ID 隔离

- **状态**：Accepted
- **决策**：GlobalSettings 只保存应用级设置和固定 runtime/shared prefix 的安全摘要；PerGameSettings 按 Game ID 保存 metadata 展示、性能/兼容入口状态、背景组选择和失败事实引用，不保存 Wine 版本或 prefix 绑定。BackgroundGroup 绑定 Game ID、版本、source identity 以及 image/video/theme 资源身份；目标组失败或取消时保留上一有效组。
- **理由**：UX/UI 明确要求不同游戏设置和背景选择不串用；背景资源失败不应污染游戏安装、完整性或启动状态。
- **备选方案**：A（全局当前背景/设置）— 未采纳，因为会跨游戏泄漏；B（只保存 URL）— 未采纳，因为无法表达资源版本和验证状态；C（失败时静默选择其他组）— 未采纳，因为改变了用户意图。
- **Trade-off**：AppData 需要按 Game 保存更多摘要；换取隔离、可恢复和明确反馈。
- **影响范围**：GameRegistry、PersistenceStore、SettingsViewModel、LibraryViewModel、BackgroundMediaLoad 和 metadata projection。

## ADR 028：六项高级配置本轮只提供 Deferred capability

- **状态**：Accepted
- **决策**：A-01 Retina、A-02 Steam patch/白名单、A-03 旧版反作弊替换、A-04 Metal HUD、A-05 左 Command → Control、A-06 hosts 屏蔽在本轮 capability 查询中均返回 Deferred，不产生 toggle、apply task、Applied 或持久化用户选择。
- **理由**：Product 保留目标但将本轮状态冻结为 Deferred；源码入口、参考项目行为或 helper 存在不足以形成发布能力。
- **备选方案**：A（按已有代码入口开放）— 未采纳，因为缺真实资源/权限/后置验证；B（直接删除目标）— 未采纳，因为超出 Architecture 的产品回溯范围；C（显示 toggle 但禁用）— 未采纳，因为会把目标误解为当前可应用能力。
- **Trade-off**：用户本轮不能操作六项配置；换取不产生伪造 Applied 或不可回滚副作用。
- **影响范围**：SolutionEngine、PerformanceOptionManager、Settings/GameDetail ViewModel、SystemModificationGateway（A-06 不调用）和 AX feedback。

## ADR 029：Managed Wine 启动命令和权限边界固定

- **状态**：Deprecated；由 ADR 037-039 取代
- **决策**：启动只能执行已验证 Managed Wine binary；参数为绝对游戏 exe 加固定/批准性能参数；prefix 为 App Support 下的独立 Game ID 目录；环境固定包含 `WINEPREFIX` 和 `WINEDLLOVERRIDES=winemenubuilder.exe=d`；游戏目录 bookmark scope、App Support prefix 和系统修改 helper 三者权限不互相替代。
- **理由**：固定命令和独立 prefix 能隔离游戏、避免 shell/任意环境输入，并保持 Sandbox 与系统修改最小权限边界。
- **备选方案**：A（用户任意 binary/参数）— 未采纳，因为破坏 Managed Wine 和可审计性；B（游戏目录作为 prefix）— 未采纳，因为权限和游戏文件污染混在一起；C（bookmark 直接写 hosts/hostname）— 未采纳，因为游戏授权不等于系统授权。
- **Trade-off**：需要明确的运行时准备和 helper 能力检查；换取启动、恢复和权限行为可验证。
- **影响范围**：PreLaunchValidator、LaunchOrchestrator、WineRuntimeProvider、ProcessManager、GameFileSystemRepository 和 SystemModificationGateway。

## ADR 030：继续使用 LogWriter actor，日志只作为脱敏诊断副作用

- **状态**：Accepted
- **决策**：保留现有 `Infrastructure.LogWriter` actor 作为唯一日志服务；在现有分级/文件能力上补充结构化 LogEvent、统一 operation/task/game/Wine context、字段脱敏、flush barrier、LogExport 和测试捕获 seam。不新增通用日志框架。UI/ViewModel 不直接依赖 LogWriter，用户导出经 `LogExport` Domain task。
- **理由**：Product 只需要启动相关日志导出，Research 已有 OSLog/统一 logger 参考；现有 actor 已具备缓冲、轮转和导出基础。结构化上下文和隐私过滤是当前错误关联和 Sandbox 安全所必需的最小补充。
- **备选方案**：A（UI 直接读取/拼接日志）— 未采纳，因为违反四层依赖并可能泄露路径；B（新建通用 Logging framework/protocol graph）— 未采纳，因为超出当前问题且造成抽象膨胀；C（只保留自由文本）— 未采纳，因为无法稳定关联 task/operation/phase/result 或测试错误恢复。
- **Trade-off**：现有自由文本调用需要经过安全化/结构化收敛，导出前必须 flush，可能增加诊断延迟；换取日志不会成为第二业务事实源，且敏感值不会进入文件或导出。
- **影响范围**：LogWriter、TaskScheduler/LogExport、GameRegistry、LaunchOrchestrator、WineVersionManager、VersionChecker、SolutionEngine、Persistence/Process/Network consumers、SettingsViewModel 和日志测试。

## ADR 031：API 背景集合指纹是缓存失效的唯一依据（I-1）

- **状态**：Accepted
- **决策**：背景缓存以 `(Game ID, 组 ID, 资源身份)` 为单元；每个 Game 维护一个 API 背景集合指纹，由 API 返回的集合内容（组 ID 顺序、各组资源身份/版本、source identity）计算，不含 `selectedBackgroundGroupID` 或 hover 态。只有指纹变化时才允许按 diff 清理不再属于当前集合或资源身份已变化的缓存；用户切换、hover 预览、失败和取消都不删除缓存。指纹与缓存 manifest 存 App Support 媒体缓存目录，AppData 只保存选择。
- **理由**：当前实现用“缓存 ID 不同”触发删除，无法区分用户切换与 API 变更，切换分组会误删其他分组缓存；指纹把“集合是否变化”和“呈现选择”分离。
- **备选方案**：A（用 `selectedBackgroundGroupID` 做缓存清理依据）— 未采纳，因为用户切换会被当成内容变更；B（每次加载全量清缓存）— 未采纳，因为会浪费并删除其他分组资源；C（用 URL 直接判断）— 未采纳，因为 URL 不能表达集合身份和资源版本变化。
- **Trade-off**：需要维护指纹与 manifest，并在指纹缺失时保守不清缓存；收益是用户切换无损、API 变更可回收。
- **影响范围**：BackgroundMediaService、BackgroundMediaLoad、媒体缓存目录、PersistenceStore（选择持久化）、LibraryViewModel 预览。

## ADR 032：Wine 生效版本按 Game ID 解析为覆盖优先、全局回退（I-4）

- **状态**：Deprecated；由 ADR 037、041 取代
- **决策**：`PerGameSettings.wineVersionOverride` 保存单 Game 覆盖；全局默认仍由 AppData `selectedWineVersion` 表达。生效版本解析固定为 `wineVersionOverride ?? selectedWineVersion`。覆盖存在但无效时不自动回退全局；只有覆盖不存在时才回退。两者都必须已安装托管版本；下载/安装目标不成为有效选中。
- **理由**：Product/UX/UI 已冻结“全局 / 单独”；“覆盖优先、无覆盖回退”是唯一解析规则，避免多来源歧义。
- **备选方案**：A（只有全局版本）— 未采纳，因为无法按游戏分别使用不同版本；B（覆盖失效时静默回退全局）— 未采纳，因为会掩盖用户单独选择并产生非预期启动环境；C（覆盖存在且失效时显示全局）— 未采纳，因为违反冻结的“当前选中版本失效显示未就绪”。
- **Trade-off**：失效覆盖需要用户显式修复或移除；换来版本事实不静默漂移。
- **影响范围**：WineVersionManager、PerGameSettings、GameRegistry、LaunchOrchestrator、SettingsViewModel。

## ADR 033：WineVersionManager 提供游戏级选择、读取与 readiness API（I-4）

- **状态**：Deprecated；由 ADR 037、039 取代
- **决策**：WineVersionManager 提供按 Game ID 的覆盖设置/移除、全局默认读取/设置、`effectiveVersion(for:)`、`checkReadiness(for:)` 和 `validatedRuntime(for:)`。无 Game 上下文的 `checkReadiness()` 只表达全局/默认运行时状态（gameID 为 nil），不得产生任何 Game 的 `WineReady`；`LaunchOrchestrator` 只消费按目标 Game 解析后的 runtime。Wine 下载全局 `wineRuntime` 互斥语义不变。
- **理由**：UX 要求 readiness 是当前 Game 级结论；启动编排必须从目标 Game 的有效版本出发，Settings 无游戏上下文不能误报。
- **备选方案**：A（全局 readiness 继续当启动门槛）— 未采纳，因为掩盖游戏级 prefix 与覆盖差异；B（每个 Game 独立下载互斥）— 未采纳，因为改变已冻结的全局 `wineRuntime` 下载互斥；C（UI 自行解析覆盖）— 未采纳，因为业务解析必须由 Domain 唯一所有者执行。
- **Trade-off**：WineVersionManager 接口增加 Game ID 参数；换来版本解析和 readiness 单一决策者。
- **影响范围**：WineVersionManager、SettingsViewModel、LibraryViewModel、LaunchOrchestrator、PreLaunchValidator。

## ADR 034：Wine 版本删除保护覆盖全局默认与全部游戏覆盖（I-4）

- **状态**：Deprecated；由 ADR 042 取代
- **决策**：删除版本前必须同时检查全局 `selectedWineVersion`、所有 `PerGameSettings.wineVersionOverride`、活动下载和未收敛恢复记录；任一引用存在即拒绝删除并返回 `conflict`/`recoveryRequired`。删除成功后重读验证无任何引用和安装记录。用户必须先改选或移除全部引用后才能删除被引用版本。
- **理由**：只检查全局会留下指向已删版本的覆盖，启动和 readiness 会产生无效运行时引用；Product/UX 已冻结“存在任一引用时不得删除”。
- **备选方案**：A（只检查全局）— 未采纳，因为残留覆盖引用；B（删除时自动清除覆盖）— 未采纳，因为会改变用户单独选择事实且可能覆盖失败；C（允许删除后按需重建）— 未采纳，因为已删版本无法恢复且破坏安装事实。
- **Trade-off**：删除被引用版本需要多一步解除引用；换来没有悬空运行时引用。
- **影响范围**：WineVersionManager 删除流程、GameRegistry/PerGameSettings、PersistenceStore、SettingsViewModel、恢复记录。

## ADR 035：AppData schema 3 增量迁移兼容旧文件（I-4）

- **状态**：Deprecated；由 ADR 041 取代
- **决策**：AppData 目标格式升级为 schema 3：`PerGameSettings` 新增 `wineVersionOverride`；`selectedWineVersion` 继续作为全局默认；旧 `lastCachedBackgroundIds` 保留为兼容诊断字段，不再作为选中或缓存失效依据。schema 1/2 按版本迁移：备份 → 迁移 → 写入 → 重读验证 → 发布；旧 `selectedWineVersion` 迁移为全局默认，不自动写入任何 Game 覆盖；迁移失败保留旧文件与备份。
- **理由**：既有用户文件必须无损升级；全局/覆盖分离要求新增字段；不能把旧全局选择静默复制到三款游戏，也不能用新字段缺失绕过迁移验证。
- **备选方案**：A（不升 schema，直接添加字段）— 未采纳，因为违反既有“未来格式必须递增版本迁移”的契约且无法表达迁移验证；B（迁移时自动为三款游戏写覆盖）— 未采纳，因为改变用户意图且违背冻结；C（丢弃旧字段）— 未采纳，因为会导致数据丢失。
- **Trade-off**：需要一次显式迁移和验证；换来旧文件可回滚、新字段无歧义。
- **影响范围**：PersistenceStore、AppData、GameRegistry、WineVersionManager、BackgroundMediaService、QA 迁移测试。

## ADR 036：SystemInfo 字段契约与最小设备标识（I-5）

- **状态**：Accepted
- **决策**：SystemEnvironmentDetector 的 `SystemInfo` 区分 `machineName`（用户可读机型）、`chipName`（系统报告芯片名）、`physicalMemory`、`osVersion`、`buildNumber`、`modelIdentifier`（详情）和 `isAppleSilicon`。`machineName` 不来自 `hw.model` 推断；`chipName` 绝不使用 `hw.model`；字段缺失或失败分别保持 `unknown/failed`，不伪造旧值、0 或默认值。不读取、不展示、不持久化序列号、平台 UUID、UDID 等敏感标识；磁盘空间只针对 Wine 管理目标卷。
- **理由**：Research 已确认 `hw.model=MacBookPro18,1` 是 model identifier 而非芯片名；UI/UX 冻结主层级四行；敏感设备标识应最小化。
- **备选方案**：A（用 `hw.model` 当 chipName）— 未采纳，因为与 Research 和产品要求冲突；B（从 model identifier 推断营销型号）— 未采纳，因为没有可验证映射；C（失败时用旧值、0 或默认）— 未采纳，因为会伪装当前值。
- **Trade-off**：真实芯片/机型字段依赖系统报告，个别平台可能 unknown；换取准确、可审计且不泄露标识。
- **影响范围**：SystemEnvironmentDetector、SystemInfo、SettingsViewModel、GeneralPane、诊断导出脱敏规则。

## ADR 037：当前版本固定为单一 Wine runtime 与单一 catalog entry

- **状态**：Accepted
- **决策**：当前版本唯一 runtime identity 为 `wine-crossover-11.0-1-signed`。`WineVersionManager` 只读取并验证一个产品批准的 fixed catalog entry，固定来源策略、目标架构和 asset 校验要求；不提供版本列表、来源选择、用户 URL、外部 Wine 检测或 fallback。远程 API 只能验证该固定目标，不能扩大支持范围。
- **理由**：用户于 2026-08-27 明确要求三款游戏统一使用该 Wine，并移除按游戏选择 Wine 的产品路径。单一身份使下载、安装、readiness 和启动的事实来源一致，也消除旧全局/按游戏选择模型的歧义。
- **备选方案**：A（保留多版本 catalog）— 未采纳，因为会重新引入用户选择和迁移歧义；B（允许用户选择批准来源）— 未采纳，因为产品要求简化设置且来源应由产品固定；C（检测系统 Wine 并 fallback）— 未采纳，因为无法证明其托管身份、版本和权限边界。
- **Trade-off**：批准资源不可用时不能切换其他版本或本机 Wine；换取可复现、可审计和最小的运行时配置面。
- **影响范围**：WineVersionManager、SettingsViewModel、WineRuntimeProvider、PreLaunchValidator、LaunchOrchestrator、网络下载和运行时迁移。

## ADR 038：三款游戏共用一个稳定 SharedWinePrefix

- **状态**：Accepted
- **决策**：三款游戏唯一共享 prefix identity 为 `sharedWinePrefix`，稳定路径为 `<Application Support>/MiPlay/WinePrefixes/shared`。prefix 由固定 Wine binary 初始化、验证和恢复；Game ID 不参与 prefix 路径、选择或持久化绑定。缺少 authoritative record、身份不一致或内容不明时进入 `migrationRequired`/`RecoveryRequired`，不得静默采用旧目录或外部 prefix。
- **理由**：Research 已确认相同 `WINEPREFIX` 共享 Wine server 和 prefix 状态；将 prefix 作为单一公共事实，才能正确表达三款游戏共同受到的初始化、损坏和恢复影响。
- **备选方案**：A（继续 `WinePrefixes/<gameID>`）— 未采纳，因为违反共享 prefix 要求；B（运行时按需复制 prefix）— 未采纳，因为会产生未定义的副本身份和额外迁移复杂度；C（复用系统/Whisky/CrossOver prefix）— 未采纳，因为不属于 MiPlay 托管边界。
- **Trade-off**：共享 prefix 损坏会同时阻止三款游戏，且不能用另一 prefix 绕过；换取单一状态、可验证恢复和一致启动环境。
- **影响范围**：WineRuntimeProvider、WineVersionManager、LaunchCommand、PreLaunchValidator、LaunchOrchestrator、AppData schema 4 和旧 prefix 迁移。

## ADR 039：共享 prefix 使用独占 lease，禁止未协调的并发启动和修改

- **状态**：Accepted
- **决策**：增加全局 `sharedWinePrefix` 独占资源 lease。prefix 初始化、修复、恢复、升级、兼容性写入和每次游戏启动都必须取得该 lease。启动 lease 从 prefix 准备完成前持续到进程退出、termination confirmed 和清理完成；同一时间不允许第二款游戏启动或任何流程修改该 prefix。冲突返回明确 `busy/conflict`，不隐式创建重复任务或第二个 prefix。
- **理由**：Research 指出 Swift actor 无法协调外部 Wine 子进程，`wineserver -w` 也不是应用级互斥。共享 prefix 的注册表、用户目录和 server 状态需要跨任务的显式生命周期保护。
- **备选方案**：A（允许多游戏并发启动）— 未采纳，因为当前没有真实兼容性证据且无法隔离共享状态；B（只依赖 `wineserver -w`）— 未采纳，因为它不是完整的任务互斥协议；C（只锁 prefix 初始化）— 未采纳，因为运行中修改或恢复仍可能污染活动进程。
- **Trade-off**：同一时刻最多一个共享 prefix 使用者，可能拒绝或延迟第二个启动；换取可确认的 prefix 生命周期和可恢复失败边界。
- **影响范围**：TaskScheduler、WineVersionManager、WineRuntimeProvider、LaunchOrchestrator、ProcessManager、任务取消和恢复。

## ADR 040：用单一 WineRuntimeSetup 任务简化获取、安装和 prefix 准备

- **状态**：Accepted
- **决策**：当前产品用一个固定目标的 `WineRuntimeSetup` Domain task 串联 fixed catalog entry 读取、资源下载、内容验证、托管安装提交、共享 prefix 准备和最终 pair 验证。允许内部阶段事件区分网络、校验、安装和 prefix 准备，但不暴露可选版本/来源列表，也不把任一中间阶段当作 `WineReady`。原有 `WineCatalogQuery`、`WineAssetDownload` 作为当前产品任务契约废止。
- **理由**：用户要求简化 Wine 下载、安装与设置流程；固定目标下保留阶段事实即可支持错误、取消和恢复，无需让用户理解多版本目录和来源选择。
- **备选方案**：A（保留两个用户可见任务）— 未采纳，因为会暴露已移除的选择流程；B（下载完成即 ready）— 未采纳，因为 prefix 初始化和安装提交仍是独立门槛；C（单一无阶段黑盒任务）— 未采纳，因为无法准确表达取消、失败和恢复位置。
- **Trade-off**：Domain executor 内部需要维护更长的事务状态；换取设置页单一入口和固定目标的一致进度语义。
- **影响范围**：TaskScheduler、WineVersionManager、NetworkDownloadProvider、WineRuntimeProvider、SettingsViewModel、任务持久化和取消/恢复。

## ADR 041：schema 4 迁移不继承旧 Wine 选择或旧 per-game prefix

- **状态**：Accepted
- **决策**：当前 canonical AppData schema 为 schema 4。schema 3 的 `selectedWineVersion`、`selectedWineSource`、`installedWineVersions` 和 `PerGameSettings.wineVersionOverride` 只作为迁移输入：固定 tag 只可作为重新验证候选，其他/空值不能授权旧 Wine；所有 per-game override 清除产品含义。旧 `WinePrefixes/<gameID>` 不合并、不改名后采用；可安全隔离则作为 legacy recovery data 保留，否则迁移阻止在 `migrationRequired`/`RecoveryRequired`。任何共享 prefix adoption 都必须有新的 authoritative record 和完整验证。
- **理由**：旧 schema 记录了已经被用户覆盖的新产品边界；静默继承会让旧 Wine、旧来源或旧 prefix 继续影响启动，并制造不可见的运行时选择。
- **备选方案**：A（把旧 selected version 直接转成当前 runtime）— 未采纳，因为未证明安装身份和 prefix 绑定仍有效；B（把每个 override 合并到共享状态）— 未采纳，因为多个冲突选择无法定义唯一事实；C（自动挑一个旧 prefix）— 未采纳，因为无法证明其来源、内容和三款游戏共享资格。
- **Trade-off**：部分旧用户需要重新下载、重新准备 prefix 或人工恢复；换取迁移后不会静默使用旧运行环境。
- **影响范围**：PersistenceStore、AppData、WineVersionManager、WineRuntimeProvider、启动 readiness、旧目录清理和迁移测试。

## ADR 042：固定 runtime 与 shared prefix 的删除、升级和回滚必须成对保护

- **状态**：Accepted
- **决策**：当前固定 runtime 和 shared prefix 不提供用户删除 API。失败临时 artifact、未提交安装结果和确认无效的 staged/rollback 数据可按恢复规则清理。未来 Product 批准的升级必须作为 runtime/prefix pair transaction 执行：阶段校验、取得 `wineRuntime` 与 `sharedWinePrefix` locks、保留旧 pair 回滚事实、准备并验证新 pair、原子提交。升级失败或取消时保留旧有效 pair；旧 pair 无法确认时进入 `RecoveryRequired`。清理旧数据前必须确认无活动 launch lease、进程、恢复记录或未提交事务。
- **理由**：共享 prefix 与 Wine binary 是绑定的运行环境；只替换其中一个会留下混合状态。用户删除当前 runtime 也会直接使三款游戏失去唯一运行环境。
- **备选方案**：A（允许分别升级 binary 和 prefix）— 未采纳，因为会产生不兼容 pair；B（删除后重新生成 prefix）— 未采纳，因为丢失可回滚事实并可能扩大副作用；C（失败后静默使用新旧混合状态）— 未采纳，因为无法形成可信 readiness。
- **Trade-off**：升级期间操作被串行化，失败恢复可能阻止启动；换取运行时身份、prefix 内容和持久化事实的一致性。
- **影响范围**：WineVersionManager、WineRuntimeProvider、TaskScheduler、PersistenceStore、LaunchOrchestrator、RecoveryRequired 投影和发布升级流程。

## 3. 历史冲突处理

以下旧描述不再代表当前架构：

| 旧描述 | 当前处理 |
|---|---|
| Domain `@Observable` 属性直接由 ViewModel 引用 | 被 ADR 003 取代，改为 Actor snapshot/event projection |
| 所有服务可使用默认 MainActor | 被 ADR 002 取代，只有 UI/ViewModel MainActor |
| 裸 `installPath` 可恢复路径授权 | 被 ADR 004 取代，旧值仅触发 migrationRequired |
| 普通 Process/bash 可直接修改 `/etc/hosts`/hostname | 被 ADR 005 取代，必须走受限系统修改边界 |
| 进程创建或任务完成即表示启动成功 | 被 ADR 007/008 取代，必须读取 outcome 和健康确认 |
| JSON 无需 schema/迁移/恢复契约 | 被 ADR 009 取代 |
| 全局/按 Game ID 的 Wine 选择与 `override ?? global` | 被 ADR 037-042 取代，改为固定单一 runtime 与单一 shared prefix |
| 背景缓存 ID 不同即删除旧缓存 | 被 ADR 031 取代，改为 API 背景集合指纹失效 |
| `lastCachedBackgroundIds` 可作为选中或缓存失效依据 | 被 ADR 031 取代，改为选择与缓存清理分离 |
| `hw.model` 可作为芯片名 | 被 ADR 036 取代，芯片名只取系统报告值 |

历史 UI 窗口拓扑决策不在本 Task 改写范围内；本轮只冻结它们与 Domain/Infrastructure 的通信和状态边界。
