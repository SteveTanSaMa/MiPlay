# MiPlay 信息模型

> **文档状态**：活跃（Active）
> **UX 阶段**：Information Model
> **更新日期**：2026-08-27
> **修订（I-2/I-3/I-4/I-5）**：2026-08-27 保留背景 hover 与“此 Mac”语义，覆盖旧 Wine 作用域模型，冻结单一 runtime 与共享 prefix 信息模型
> **继承自**：Product Domain、Product Features、Architecture Task Queue

## 信息模型规则

1. 所有耗时操作同时有一个任务生命周期和一个业务结果；读取者不得只凭一个“完成”词推断成功。
2. 请求事实、执行事实、验证事实和恢复事实必须可区分。
3. 错误记录至少包含目标、阶段、原因类别、是否发生副作用、恢复动作、恢复是否已验证。
4. 不支持、已损坏、执行失败和用户取消是不同事实，不能归并为一个“失败”。
5. 技术原因可以存在于详细信息和日志，面向普通用户的主要原因使用“运行环境”“游戏文件”“访问权限”等可理解概念。

## 1. UserIntent

用户希望完成的动作，不表示动作已经执行。

| 属性 | 含义 |
|------|------|
| `intentId` | 一次用户意图的标识 |
| `target` | 游戏、兼容方案、路径、版本检测或数据恢复目标 |
| `createdAt` | 用户提交时间 |
| `cancelRequested` | 用户是否请求取消 |

## 2. Task

TaskScheduler 对一次可排队操作的生命周期记录。

| 属性 | 含义 |
|------|------|
| `taskId` | 任务标识，与 UserIntent 关联但不等同 |
| `kind` | Architecture 已定义的 `GameLaunch`、`SolutionApply`、`SolutionRevert`、`IntegrityVerification`、`VersionCheck`、`WineVersionDownload` 等任务类型；路径定位作为用户操作和权限/完整性结果记录，不强制新增调度器任务类型 |
| `status` | 仅使用 `pending`、`running`、`completed`、`failed`、`cancelled` |
| `phase` | 当前阶段，例如校验、环境准备、进程确认、后置验证、恢复验证 |
| `progress` | 可估算时的阶段进度；不可估算时不提供确定数值 |
| `startedAt/endedAt` | 实际开始和结束时间；`pending` 没有 `startedAt` |
| `outcome` | 该任务产生的业务结果，必须单独读取 |
| `error` | 失败类别和面向用户的解释 |
| `recovery` | 当前唯一推荐动作、可重试条件和是否已验证 |

### Task 状态含义

- **`pending`**：请求已接受但尚未开始执行。不得使用“正在应用”“已启动”或“已完成”。
- **`running`**：已开始执行，必须能说明正在处理的阶段。
- **`completed`**：任务达到定义的成功门槛，或对“校验/比较”任务已经获得可信结果；业务结果仍需单独读取。
- **`failed`**：请求目标未达成，或无法获得可信结果。不得把目标对象提升为成功状态。
- **`cancelled`**：取消请求已处理，且需要的清理或回滚已验证；未验证时使用 `failed`。

## 3. LaunchOutcome

游戏启动任务的结果，不把进程创建当作成功。

| 结果 | 进入条件 | 用户可知事实 | 下一步 |
|------|---------|-------------|-------|
| `runningConfirmed` | 进程存在且达到可运行判定 | 游戏已启动 | 继续游玩；正常退出后回到 `Installed` |
| `preflightRejected` | 文件、权限、完整性或环境前置不满足 | 启动尚未执行 | 修复前置条件后重试 |
| `runtimePreparationFailed` | 运行环境获取或准备失败 | 游戏未启动 | 恢复网络/资源后重试 |
| `processStartFailed` | 未创建可运行进程 | 启动失败 | 查看失败详情后重试或修复 |
| `processTimeout` | 在确认期限内未确认进程 | 启动超时，清理状态待确认 | 等待清理完成后重试 |
| `processExitedAbnormally` | 进程异常退出 | 游戏因异常退出结束 | 查看退出事实和方案 |
| `cancelledCleanly` | 取消后无残留且清理验证通过 | 启动已取消 | 稍后重新提交 |

## 4. PermissionAccess

描述 MiPlay 对用户选择路径或系统资源的访问事实。

| 结果 | 含义 | 不得推断 |
|------|------|----------|
| `granted` | 当前任务可以读取/修改声明的资源 | 不等于业务动作成功 |
| `expired` | 曾经允许，但当前授权不能继续使用 | 不等于文件损坏 |
| `denied` | 用户或系统拒绝访问 | 不等于用户取消了整个任务 |
| `unavailable` | 目标资源或授权能力不存在 | 不得提供应用/校验通过动作 |
| `verifiedAfterReauthorization` | 重新授权后实际读写验证通过 | 仅表示权限恢复，不表示方案已应用 |

## 5. IntegrityCheckResult

| 结果 | 进入条件 | 用户文案事实 | 恢复动作 | 终态定义 |
|------|---------|-------------|---------|---------|
| `IntegrityPassed` | 非空、版本对应 manifest，全部条目通过 | “完整性校验通过” | 可继续启动 | 可作为启动前提 |
| `IntegrityFailed` | 有效 manifest 中出现缺失或内容不匹配 | “游戏文件不完整，无法确认可启动” | 重新选择路径，使用官方工具修复/更新，再校验 | 不得标记 `Installed` 为可启动 |
| `IntegrityUnsupported` | manifest 缺失、为空、版本不对应或无法验证 | “当前版本暂无可用校验清单，无法确认完整性” | 稍后重试或使用受支持版本 | 不得报告通过 |
| `executionFailed` | 路径权限、I/O 或读取错误阻止校验 | “无法读取游戏文件，校验未完成” | 重新授权或重新选择路径 | 任务 `failed`，无可信校验结果 |
| `cancelled` | 用户在完成前取消 | “完整性校验已取消，尚未得到新结论” | 手动重新校验 | 保留上一次可信结果 |

## 6. VersionCheckResult

| 结果 | 进入条件 | 文案事实 | 终态 |
|------|---------|---------|------|
| `current` | 本地和官方版本均获得且相等 | “已确认当前为最新版本” | 任务 `completed` |
| `updateAvailable` | 本地和官方版本均获得且不同 | “已确认有新版本可用” | 任务 `completed`，游戏保留 `UpdateAvailable` |
| `unknown` | 没有足够数据判断 | “版本检测未完成，暂时无法判断” | 若本次任务无法产生可信比较，任务 `failed` |
| `failed` | 网络、官方服务、本地文件或解析失败 | “版本检测失败，未改变现有游戏状态” | 恢复条件后重试 |

已有可信结果与本次检测失败同时存在时，保存上一次结果并标记为过期；不得用失败覆盖成“当前最新”。

## 7. SolutionApplication

| 状态 | 进入条件 | 准确文案 | 恢复/后续 | 终态 |
|------|---------|-----------|---------|------|
| `Unavailable` | 资源、适用范围或权限能力不满足 | “此方案当前不可应用：{具体条件}” | 重新授权或等待发布资源；不能开始应用 | 前置终态 |
| `Applying` | 已确认，正在快照、修改或验证 | “正在应用，尚未验证完成” | 等待；取消若已修改必须回滚 | 过程态 |
| `Applied` | 修改、后置验证、记录保存和恢复快照均满足 | “兼容方案已应用并验证通过” | 单独重新启动游戏 | 成功终态 |
| `Failed` | 执行/验证失败，或回滚未确认 | “兼容方案未应用成功；{恢复事实}” | 先完成恢复或重新授权 | 失败终态；不得视为已应用 |
| `RolledBack` | 恢复到应用前状态且读回一致 | “应用未成功，已恢复应用前状态” | 稍后重试或尝试其他可用方案 | 恢复终态 |

`Applied` 不表示游戏已启动；`RolledBack` 不表示应用成功；备份成功不改变上述状态。

## 8. RuntimeReadiness（固定 runtime + 共享 prefix，按 Game ID）

面向用户使用“运行环境”，技术细节可进入日志。当前唯一 runtime 是 `wine-crossover-11.0-1-signed`，三款游戏共用同一个 MiPlay 管理的 prefix。Wine 安装、共享 prefix 和目标游戏 readiness 必须分别表达。

### 8.1 BackgroundGroupSelectionState（I-2 冻结）

背景组 hover 预览是临时媒体事实，不改变持久化选择，也不删除背景缓存。

| 状态 | 进入条件 | 用户事实 | 持久化影响 |
|---|---|---|---|
| `idle` | 未 hover 任何候选组 | 圆点隐藏或可见但未 hover；画面为当前选中组 | 无 |
| `dotsHidden` | 顶部区域无指针 | 圆点隐藏，画面为当前选中组 | 无 |
| `dotsVisible` | 指针进入顶部区域 | 候选圆点可见 | 无 |
| `hoverPreview(groupID)` | hover 候选组 | 正在预览该组 | 无 |
| `previewLoading(groupID)` | 未缓存且允许加载 | 正在加载预览，可取消 | 无 |
| `previewFailed(groupID)` | 预览加载失败 | 预览失败，当前背景保持 | 无 |
| `selected(groupID)` | 用户明确提交且资源验证、选择写回、重读通过 | 当前持久化选中组 | 写入 `selectedBackgroundGroupID` |

`hoverPreview`、`previewLoading` 和 `previewFailed` 不得改变 `selectedBackgroundGroupID`，不得写持久化，不得删除任何背景缓存。只有 `selected(groupID)` 是持久化选中终态。

### 8.2 ManagedWineState（R-1/R-2/R-4 冻结）

固定 runtime 的安装事实与共享 prefix 的运行事实是两个独立状态对象。下载、安装、prefix 初始化和恢复都只绑定这一个固定目标，不产生用户可选择的版本、来源、prefix 或游戏级 Wine 状态。

#### 固定 runtime 安装事实

| 状态 | 进入条件 | 用户事实 | 不能推断 |
|---|---|---|---|
| `NoManagedRuntime` | 固定 runtime 未形成可复核安装事实 | “统一 Wine 尚未安装” | 不得从目录、文件或外部 Wine 推断已安装 |
| `Downloading` | 固定 Release 正在获取 | “正在下载统一 Wine” | 不表示已安装或 prefix 已准备 |
| `ArtifactReady` | 固定 Release 已完整获取并通过校验 | “统一 Wine 安装资源已验证” | 不表示安装提交完成 |
| `Installing` | 托管安装、executable 验证或提交正在进行 | “正在安装统一 Wine” | 不表示安装成功 |
| `Installed` | 安装提交、身份复核和持久化重读均通过 | “统一 Wine 已安装” | 不表示共享 prefix 或任何游戏已就绪 |
| `InstallFailed` | 安装身份、提交、重读或清理失败 | “统一 Wine 安装失败” | 不得把部分安装当作可用 runtime |
| `RuntimeUnavailable` | 固定资源、批准来源、架构或托管事实无法确认 | “统一 Wine 当前不可用” | 不提供来源选择或外部 fallback |
| `RecoveryRequired` | 产生副作用但清理/恢复尚未确认 | “统一 Wine 状态未确认，当前不能继续” | 不得继续安装、初始化或启动 |

#### 共享 prefix 事实

| 状态 | 进入条件 | 用户事实 | 三款游戏影响 |
|---|---|---|---|
| `PrefixUnset` | 固定 runtime 已安装但唯一 prefix 尚未初始化 | “共享运行环境尚未准备” | 三款游戏均不能报告 `WineReady` |
| `PrefixPreparing` | 初始化、更新或验证正在进行 | “正在准备共享运行环境” | 三款游戏均等待，不重复发起 |
| `PrefixReady` | 唯一 prefix 的身份、内容和准备结果均通过 | “共享运行环境已准备” | 可分别检查三款游戏 readiness |
| `PrefixNotReady` | 初始化、更新或验证失败 | “共享运行环境准备失败” | 三款游戏均不能报告 `WineReady` |
| `RecoveryRequired` | prefix 副作用或状态无法确认 | “共享运行环境状态未确认，当前不能继续” | 三款游戏均受保护，先恢复 |

`prefixOccupancy` 是共享 prefix 的独立保护事实：`free`、`busy` 或 `unknown`。`busy` 表示等待当前 Wine 使用结束；它不创建新 prefix、不切换 runtime、不清理正在使用的内容，也不等于初始化失败。

#### 目标游戏 readiness

| 结果 | 进入条件 | 用户事实 | 影响范围 |
|---|---|---|---|
| `WineReady` | 固定 runtime 已安装、共享 prefix 已就绪、目标游戏路径/manifest/启动前置通过 | “{游戏名}可使用统一 Wine 启动” | 只允许目标 Game ID 启动 |
| `RuntimeNotReady` | 固定 runtime 或共享 prefix 未通过门槛 | “统一 Wine 或共享运行环境尚未就绪” | 阻止三款游戏或受影响游戏，按公共事实处理 |
| `GamePreflightFailed` | runtime/prefix 已就绪，但目标游戏自身路径、manifest、兼容方案或启动前置失败 | “统一运行环境已准备，但{游戏名}启动前置未通过” | 只影响目标 Game ID |
| `RecoveryRequired` | 共享 runtime/prefix 的恢复未确认 | “统一运行环境状态未确认，当前不能继续” | 三款游戏均不能开始新的相关任务 |

`WineReady` 不是“Wine 已安装”的别名。共享 prefix 已就绪后，三款游戏仍须分别取得自己的游戏 readiness；一款游戏的 `GamePreflightFailed` 不改变另外两款游戏的结果，也不创建新的 runtime 或 prefix。

`GamePreflightFailed` 是 UX 对“游戏自身前置失败”的归因投影，不是新的 Wine runtime、prefix 或 Task 状态。若下游必须使用 Product 已有的 `RuntimeNotReady` 枚举，应同时携带 `failureScope=game`；公共 Wine/prefix 失败则使用 `failureScope=runtime`，两者的用户恢复路径仍必须区分。

#### 旧 per-game 数据迁移后的用户事实

- `selectedWineVersion` 不再是用户选择。只有它与固定身份一致且安装事实重新验证通过时，才可作为固定 runtime 的历史证据；其他值或空值不能成为当前 runtime。
- `wineVersionOverride` 的所有值都忽略并清除其产品选择含义，不迁移为共享状态，也不产生新的 per-game 状态。
- 旧的多版本安装记录只保留经固定身份和托管安装事实复核的唯一 Release；旧 per-game prefix 不继续使用，必须重新验证唯一共享 prefix。
- 迁移后设置页只表达一个固定 runtime、一个共享 prefix 和三款游戏各自 readiness。无法确认时显示 `NoManagedRuntime`、`RuntimeNotReady` 或 `RecoveryRequired`，不能显示“已就绪”。

### 8.3 DeviceInfo（I-5 冻结）

“此 Mac”主层级字段为机型、芯片、内存、macOS 版本，按“关于本机”表达；未知字段不推断。model identifier 与 build number 是详情字段；Wine 目标卷空间独立读取。

| 字段 | 来源 | 用户语义 | 未知/失败语义 |
|---|---|---|---|
| 机型 | 系统报告的 machine name | 例如 MacBook Pro | 显示“未知”或“无法读取”，不推断 |
| 芯片 | 系统报告的 chip name | 例如 Apple M1 Pro | 显示“未知”或“无法读取”，不从 model identifier 推断 |
| 内存 | 系统报告的物理内存 | 真实内存值 | 不用默认值补齐 |
| macOS 版本 | 系统报告的产品版本 | 面向用户的版本 | 不用 build number 替代 |
| model identifier | 系统型号标识 | 详情字段 | 不作为主层级事实 |
| build number | 系统构建事实 | 详情字段 | 不作为产品版本 |
| Wine 目标卷空间 | Wine 管理目标所在卷 | 当前/总量 | 不可用时保留失败事实，不改变 Wine readiness |

| 状态 | 用户事实 | 恢复动作 | 终态 |
|---|---|---|---|
| `fieldConfirmed` | 字段为系统报告值 | 查看 | 字段可读 |
| `fieldUnknown` | 系统报告未提供 | 手动刷新或等待系统提供 | 不推断 |
| `fieldFailed` | 无法读取字段 | 手动刷新；必要时导出日志 | 不用旧值、0 或空值伪装当前值 |
| `fieldStale` | 显示上一次已确认值 | 刷新 | 旧值标记为等待更新 |
| `diskSpaceUnavailable` | 无法读取 Wine 目标卷空间 | 等待卷可用或重试 | 不改变 Wine readiness |

## 9. AppDataRecovery

这是应用数据恢复过程的 UX 结果，不取代 Game、SolutionApplication 或 Runtime 的业务状态。

| 结果 | 用户事实 | 用户动作 | 终态 |
|------|---------|---------|------|
| `readable` | 应用数据可读取 | 继续使用 | 可用 |
| `backupCreated` | 原始数据已保护 | 等待恢复/迁移结果 | 保护动作完成，不是恢复成功 |
| `restoreAvailable` | 找到可读备份 | 选择恢复或重试 | 等待确认 |
| `restoredAndVerified` | 备份恢复后重新读取通过 | 继续使用 | 可用，提示可能丢失最新变更 |
| `migrationRequired` | 旧格式可读但需迁移 | 确认迁移或稍后处理 | 未迁移前不声明完成 |
| `migratedAndVerified` | 迁移后重新读取和结构校验通过 | 继续使用 | 可用 |
| `recoveryFailed` | 恢复/迁移后仍无法验证 | 选择其他备份、重试或明确重新开始 | 不可用 |
| `freshStartConfirmed` | 用户明确放弃不可恢复数据并确认重新开始 | 重新配置游戏路径和设置 | 可用但历史/配置为空 |

## 10. ErrorRecord

每条 P0/P1 错误至少应表达以下信息：

| 字段 | 内容 |
|------|------|
| 目标 | 哪款游戏、哪项方案、哪个路径或哪份数据 |
| 阶段 | 排队、校验、授权、执行、进程确认、后置验证或恢复 |
| 原因类别 | 网络、权限、文件、manifest、运行环境、进程、数据或用户取消 |
| 副作用事实 | 是否已写入、是否创建进程、是否有残留或是否未改变目标 |
| 当前结果 | 业务结果和任务状态 |
| 恢复动作 | 唯一推荐的下一步及前置条件 |
| 验证事实 | 恢复/清理是否已读回确认 |

## 11. ManagedWineAcquisitionResult

固定 runtime 的资源检查是对一个产品固定目标的获取结果，不是可选版本目录，也不产生用户可选择的来源事实。来源由产品固定和管理；用户只能检查、下载、安装、重试或恢复。

| 结果 | 进入条件 | 用户文案 | 恢复动作 | 是否可用于启动 |
|---|---|---|---|---|
| `checking` | 正在检查固定 Release 资源 | “正在检查统一 Wine” | 等待或取消检查 | 否 |
| `artifactAvailable` | 固定身份、批准来源、架构和资源映射可验证 | “已找到统一 Wine 安装资源” | 开始下载 | 否 |
| `artifactUnavailable` | 固定资源暂时不可达、服务失败或资源不存在 | “无法获取统一 Wine 安装资源” | 恢复网络或稍后重试 | 否 |
| `artifactInvalid` | 资源身份、重定向、格式或校验不匹配 | “统一 Wine 安装资源无法验证” | 等待产品修复或重试 | 否 |
| `artifactDownloaded` | 固定资源完整获取并通过内容校验 | “统一 Wine 安装资源已验证” | 提交安装 | 否 |
| `installationVerified` | 托管安装、executable 身份、持久化提交和重读均通过 | “统一 Wine 已安装” | 初始化共享 prefix | 否 |
| `prefixVerified` | 唯一共享 prefix 初始化和验证通过 | “共享运行环境已准备” | 分别检查游戏 readiness | 仅作为公共门槛 |
| `recoveryRequired` | 清理、安装或 prefix 状态无法确认 | “统一运行环境状态未确认，当前不能继续” | 先完成恢复 | 否 |

下载、解压、文件存在、`wine --version` 有输出或 prefix 目录存在，都不能单独产生 `installationVerified`、`prefixVerified` 或 `WineReady`。三款游戏的 readiness 仍需按目标 Game ID 单独读取。

## 12. LocalGameEvidence

本地文件证据保留来源和用途，避免 `pkg_version`/`config.ini` 被误当作统一真相。

| 证据来源 | 可表达事实 | 不能单独表达 |
|---------|-----------|-------------|
| `pkg_version` | 经格式、目标游戏、安装位置和版本语义验证后的本地版本候选 | 完整性通过、官方最新、渠道可信 |
| `config.ini` | 经格式验证的渠道/来源/配置元数据候选 | 文件完整性、官方最新版本、可启动 |
| `IntegrityManifest` | 游戏身份、客户端版本、必需条目和内容校验依据 | 官方服务器最新版本 |
| 官方远程版本 | 官方最新版本候选 | 本地文件版本或文件完整性 |

| 组合结果 | 用户文案 | 终态 |
|---------|---------|---------|
| 本地版本可验证 + 远程版本可验证 | “已确认当前版本与官方版本的差异” | VersionCheck `completed` |
| manifest 可验证且全条目通过 | “完整性校验通过，已确认文件与当前版本匹配” | `IntegrityPassed` |
| 任一来源缺失或无法解析 | “无法确认当前版本/完整性，缺少可验证来源” | VersionCheck `failed` 或 `IntegrityUnsupported` |
| 来源之间冲突 | “版本信息互相冲突，暂时无法确认” | 不得发布 `current`、`IntegrityPassed` 或 `Running` |

## 13. LocationRecoveryFact

| 事实 | 用户文案 | 允许的下游结果 |
|------|---------|---------------|
| `locationFresh` | “游戏路径授权有效” | 继续消费者操作 |
| `locationStaleRefreshing` | “正在刷新游戏路径授权” | 暂停发布消费者结果 |
| `locationRefreshCommitted` | “游戏路径授权已刷新并保存” | 继续并发布可信消费者结果 |
| `locationRefreshPersistenceFailed` | “路径授权已刷新但尚未保存，本次操作未完成” | 仅重试保存或重新选择路径；不得发布成功 |
| `locationAccessDenied` | “无法访问所选游戏路径” | 重新授权或重新选择路径 |
| `recoveryRequired` | “路径授权恢复未完成，暂时不能继续” | 先恢复记录；禁止同目标新副作用任务 |

`GameRegistry`、`FileIntegrityVerifier`、`VersionChecker`、`PreLaunchValidator` 和 `LaunchOrchestrator` 必须消费同一类事实。`lastKnownPath` 是诊断信息，不是授权或成功证据。

## 14. RestartRecoveryFact

| 事实 | 进入条件 | 用户文案 | 终态/动作 |
|------|---------|---------|-----------|
| `persistedRunningNoProcess` | 重启发现 Game 持久 `Running`，但无可信活动进程 | “上次游戏状态未完成同步，正在恢复” | `recoveryRequired`，不能启动 |
| `recoveryCommitPending` | 退出事实已知但目标终态尚未提交 | “正在保存游戏退出状态” | 保持保护，不显示已退出 |
| `recoveryCommitted` | 进程退出确认、目标终态和记录均重读通过 | “游戏状态已恢复” | 允许新 UserIntent/Task |
| `recoveryPersistenceFailed` | AppData 和恢复记录都无法提交 | “游戏状态恢复未完成，暂时不能启动” | `failed + recoveryRequired`，不自动重试游戏 |

`recoveryRequired` 不是新的 Task.status 或 Game 业务状态；它是保护事实，必须在 Accessibility value 和错误恢复信息中可读。

## 15. AccessibilityProjection

这是从 Domain/ViewModel 状态生成的语义对象，不是视觉层推断结果，也不规定界面布局。

| 字段 | 语义 |
|------|------|
| `role` | button、progressIndicator、status、group 或其他标准角色 |
| `label` | 稳定的对象和动作，例如“切换到原神” |
| `value` | 选中态、业务状态、任务状态、阶段、真实进度或“进度未知” |
| `hint` | 激活后的结果或当前可执行动作 |
| `enabled` | 当前动作是否可执行；不可用必须有原因事实 |
| `busy` | 是否仍在查询、执行、验证或恢复 |
| `recoveryAction` | 当前唯一适合的恢复动作及前置条件 |
| `announcement` | 状态从 pending/running 到可信终态时的完整事实 |

### 必须可读的模板

- **Game card**：`label=切换到{游戏名}`；`value={选中状态}，{业务状态}，{当前可用动作}`；`hint=选择后显示该游戏背景和可用操作`。
- **Background group preview**：`label={组名}背景组预览`；`value=预览中/加载中/失败，当前选中组{组名}`；`hint=离开恢复当前选中组，Return/Space 提交`。
- **Unified Wine runtime**：`label=统一 Wine`；`value=固定 runtime {固定身份}，安装状态{状态}，共享 prefix {状态}，占用{状态}`；`hint=检查、下载、安装、初始化或恢复，不提供版本/来源/prefix 选择`。
- **Game readiness**：`label={游戏名}运行环境`；`value=统一 Wine、共享 prefix、游戏启动前置的结构化结果`；`hint=明确区分运行环境失败与游戏自身前置失败`。
- **This Mac**：`label=此 Mac`；`value={机型}，{芯片}，{内存}，{macOS 版本}，{各字段读取状态}`；未知字段读作“未知”，失败字段读作“无法读取”。
- **Launch progress**：`label={游戏名}启动`；`value={pending/running}，{阶段}，{真实百分比或进度未知}`；不读出由视觉条或时间猜测的百分比。
- **Failure/recovery**：`label={目标}操作结果`；`value={阶段}失败，{副作用事实}，{终态}`；`hint={恢复动作}`。`recoveryRequired` 必须读出“当前不能重试”。
- **Solution**：`Applied` 必须读出“方案已应用并验证，游戏尚未启动”；`RolledBack` 必须读出“应用未成功，应用前状态已恢复并确认”。
- **Managed Wine acquisition**：固定目标只读出“正在检查/下载/验证/安装统一 Wine”及对应终态；不能用空列表、颜色或 spinner 推断安装或 prefix 就绪。

## 2026-10-08 设置与任务反馈修订

设置导航分为应用（通用、Wine）、游戏（三款游戏）、关于；各页面标题和一行范围说明帮助用户确认当前配置对象。主窗口仍以背景和启动操作为主，仅有任务或恢复事实时显示局部反馈。选中游戏使用独立白色标记，彩色描边继续传达运行状态，避免两个语义混用。

实现和验证见 [UI 优化修订](../03-ui/ui-revision-2026-10-08.md)。

## 2026-10-09 简化修订

设置保留分组导航和页面标题，删除重复的一行范围说明；“下次启动生效”改用系统 Section footer。Wine 的共享 prefix 对外称为“共享游戏环境”，完整来源 URL 继续可点击。恢复事实仅展示当前游戏对应的未解决记录。准备遮罩将底层按钮从键盘与辅助技术操作区域隔离。

见 [原生 UI 审查](../03-ui/ui-native-review-2026-10-09.md)。
