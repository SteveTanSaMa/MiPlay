# MiPlay 核心领域概念与业务状态

> **文档状态**：已冻结（Freezed）
> **产品阶段**：Product Definition（问题空间定义）

---

## 1. 核心领域概念（Core Domain Concepts）

### Game
- **概念定义**：一款具体的米哈游游戏作品，是 MiPlay 的管理单元。MiPlay 固定管理三款游戏（原神、星穹铁道、绝区零），围绕每个游戏提供启动、兼容方案和状态管理等能力。
- **关键属性概念**：游戏标识（唯一指代某款游戏）、安装路径（游戏可执行文件所在位置）、游戏版本（当前安装的游戏客户端版本）、运行状态（当前游戏进程的状态判定）、已知方案列表（针对该游戏适用的内置兼容方案集合）。

### CompatibilitySolution
- **概念定义**：一种内置在 MiPlay 中的兼容性处理手段，用于解决特定游戏在特定环境下的启动障碍。方案来源于社区经验，随程序版本内置发布，不依赖外部信息源。每个方案可能关联所需的 Wine 版本。
- **关键属性概念**：适用范围（所针对的游戏和已知环境条件）、方案类型（所解决的问题类别，如 hostname 修改、网络屏蔽等）、当前版本目标归属、发布资格（当前轮次是否允许作为可应用方案）、实现状态（已验证 / Deferred / Out of Scope）、资源与权限前置条件、风险等级（应用该方案的潜在副作用程度）。静态存在的方案定义不等于当前版本可应用方案。

### IntegrityManifest
- **概念定义**：与特定游戏和客户端版本对应的必需文件清单及其内容校验依据，用于判定已定位的游戏文件是否完整。
- **关键属性概念**：游戏标识、客户端版本、必需文件条目、每个条目的内容校验值。空清单、缺失清单、版本不对应或无法验证对应关系的清单均不是可用 manifest。

### IntegrityCheckResult
- **概念定义**：一次基于有效 manifest 的游戏文件完整性判定结果。
- **关键属性概念**：目标游戏、manifest 版本、结果（完整 / 不完整 / 无法判定）、缺失或不匹配文件列表。只有有效 manifest 的全部条目通过时，结果才可为“完整”。

### SolutionApplication
- **概念定义**：将一个内置兼容方案实际应用到系统中的一次记录。代表一次"用户选择了某项方案并执行"的操作实例。
- **关键属性概念**：关联方案（应用了哪个兼容方案）、关联游戏（为哪个游戏应用）、应用时间（何时应用）、应用前状态快照、后置验证结果、当前状态（应用中 / 已生效 / 失败 / 已回滚）。`Applied`（代码语义为 `.applied`）只表示真实操作和后置验证均完成，不表示用户发起过操作或代码路径被调用。

### AdvancedGameOption
- **概念定义**：可由 MiPlay 控制的、与游戏运行或视觉表现相关的高级选项。不涉及游戏内画质设置；当前版本目标包括 Retina、Steam patch / Steam 白名单、旧版反作弊文件替换、Metal HUD、左 Command 映射 Control 和 hosts 屏蔽。
- **关键属性概念**：选项类型、可应用的游戏范围、当前版本目标归属、本轮实现状态和当前启用状态。Deferred 选项不得被记录为已实现或可应用。

### WineRuntime
- **概念定义**：游戏启动所依赖的特定、由 MiPlay 托管的 Wine 构建版本。不同兼容方案可能指定不同的 Wine 版本。用户无需理解 Wine 的技术构成，但可以查看其安全的名称、版本、批准来源和状态事实。
- **关键属性概念**：版本标识（唯一指代特定 Wine 构建版本）、批准来源（默认官方 GitHub 或当前版本 allowlist 中的镜像）、目标架构、MiPlay 托管状态、下载/安装状态、安装身份验证、适用范围（所支持的游戏或兼容方案）。`WineRuntime` 的安装事实不自动代表某个游戏已选中或已 `WineReady`。

### CurrentRuntime
- **概念定义**：当前选中游戏实际尝试使用的 MiPlay 托管 Wine 版本身份，加上该游戏对应的 readiness 结果。它是 Game ID 级产品事实，不是全局本机 Wine 检测结果，也不是路径或远程目录条目。
- **关键属性概念**：关联 Game ID、托管版本身份、批准来源、安装状态、当前选中状态、当前游戏 readiness、未就绪/失败/取消/恢复原因。路径不是默认用户语义；系统 Wine、Whisky 和 CrossOver 不得形成 `CurrentRuntime`。

### DeviceInfo
- **概念定义**：设置页展示的、与 MiPlay 当前运行环境有关的只读设备信息。它用于帮助用户了解环境，不是 Wine readiness 或启动门禁。
- **关键属性概念**：系统报告的 Mac 型号、macOS 版本、MiPlay 托管 Wine 目标卷的磁盘空间、各字段读取状态和失败事实。读取失败时结果为不可用，不得用推断值、旧值或无关卷信息替代。

### WineSourcePolicy
- **概念定义**：当前版本允许 MiPlay 获取托管 Wine 的来源规则。默认来源是官方 GitHub，用户只能在预置可信镜像 allowlist 中选择其他来源；任意 URL 输入和本机 Wine 检测均不属于产品能力。
- **关键属性概念**：默认来源、批准镜像集合、来源选择、来源可用性、下载失败事实。来源失败不能产生可用运行时，也不能触发外部 Wine 替代。

### ConfigIniEvidence
- **概念定义**：从目标游戏 `config.ini` 读取的原始字段证据，用于向用户展示游戏配置事实。该证据不自动成为游戏版本、渠道或完整性结论。
- **关键属性概念**：所属游戏、文件位置、原始 section、原始 key、原始 value、读取状态和读取时间。`channel`、`cps` 等字段保留原始值，不推断友好含义。

### GameSettings
- **概念定义**：与单个 Game ID 绑定的设置事实。游戏级设置和全局来源选择分开保存，切换游戏不能串用或覆盖另一款游戏的设置。
- **关键属性概念**：所属 Game ID、设置值、读取/保存状态和本轮实现状态。设置事实只属于其目标游戏。

### DiagnosticLog
- **概念定义**：MiPlay 对核心业务流程产生的本地诊断事实集合，用于解释流程阶段、结果、失败原因、取消和恢复状态。诊断日志不是业务成功状态，也不是远程遥测。
- **关键属性概念**：事件时间、流程/任务关联、作用域（如 Game ID 或批准来源 ID）、操作、阶段、结果、非敏感原因码、清理/恢复事实和必要的耗时信息。日志只能记录安全摘要，不记录密码、Token、完整用户路径、bookmark 内容、游戏文件内容或个人数据。
- **可见性边界**：用户可见错误提供原因类别和下一步动作；诊断日志提供排障上下文；开发调试信息不属于当前版本用户可见或导出承诺。

### VersionBackground
- **概念定义**：来源于米哈游官方渠道、与游戏当前版本主题对应的背景视觉素材。包含图片类素材和装饰性视觉元素，用于在启动体验中传达当前版本的主题信息。
- **关键属性概念**：所属游戏（素材对应哪款游戏）、对应版本（关联的游戏版本标识）、素材类别（背景图 / 装饰元素）、来源出处（素材的官方来源标识）。

### BackgroundGroup
- **概念定义**：属于一款游戏的一组版本背景素材及其装饰元素。用户切换背景组时，只改变目标游戏当前使用的组，不改变其他游戏的选择。
- **关键属性概念**：所属 Game ID、组标识、版本对应关系、组内素材集合、可用状态、当前选择和失败恢复事实。目标组不可用时保留上一有效组。

## 1.1 延期领域概念（Deferred / 不纳入当前版本）

### GameInstaller
- **概念定义**：未来用于引导用户完成游戏客户端获取和安装的产品能力。当前版本不负责从官方资源获取或安装游戏客户端。
- **关键属性概念**：未来可包含目标游戏、安装进度和完整性状态；这些属性不构成当前版本业务状态要求。

---

## 2. 业务状态类别（Business State Categories）

### Per‑Game 状态

| 状态名称 | 描述 | 作用域 | 触发来源 |
|---------|------|--------|---------|
| `PathUnset` | 游戏可执行文件路径尚未指定 | Per Game | User |
| `NotInstalled` | 游戏路径已指定但在该路径未找到可识别的安装文件 | Per Game | User / System |
| `Installed` | 已定位到可识别的游戏安装文件；该状态不承诺 Wine 或启动 readiness | Per Game | System |
| `GameUpdating` | 游戏客户端正在被官方更新程序更新 | Per Game | System |
| `UpdateAvailable` | 检测到游戏客户端有新版本可用 | Per Game | System |
| `Launching` | 启动请求已发出，游戏进程启动中 | Per Game | User |
| `Running` | 游戏进程正在运行中 | Per Game | System |
| `LaunchFailed` | 启动请求已发出但游戏进程未能正常启动 | Per Game | System |

### Wine 版本自身状态

| 状态名称 | 描述 | 作用域 | 触发来源 |
|---------|------|--------|---------|
| `Available` | 批准来源目录中身份和资源可验证、允许作为获取目标的版本；不代表本地已安装 | Catalog / Version | System / Network |
| `Downloading` | 指定批准来源和版本资源正在传输 | Version | System / Network |
| `DownloadFailed` | 下载、内容校验或来源验证失败；不产生新安装事实 | Version | System / Network |
| `ArtifactReady` | 资源已完成并通过内容校验，但尚未完成安装提交 | Version | System |
| `Installing` | 正在安装、验证托管 executable 和提交安装事实 | Version | System |
| `Installed` | MiPlay 托管安装完成，版本身份和持久化记录可复核 | Version | System |
| `InstalledNotSelected` | 已安装但尚未绑定到当前游戏 | Version | System / User |
| `InstallFailed` | 安装、executable 身份、提交或重读验证失败 | Version | System |
| `Cancelled` | 取消已处理，必要的清理或恢复已确认完成 | Version | User / System |
| `RecoveryRequired` | 失败或取消产生的副作用尚未清理或恢复确认 | Version | System |
| `Unavailable` | 来源、资源、权限或适用性不满足，不能作为可应用目标 | Version | System |

### CurrentRuntime / 当前游戏 readiness 状态

| 状态名称 | 描述 | 作用域 | 触发来源 |
|---------|------|--------|---------|
| `NoSelectedRuntime` | 当前游戏没有选中的已安装 MiPlay 托管版本 | Per Game | System / User |
| `SelectedNotReady` | 当前游戏已选中版本，但运行环境、身份或启动前置校验未通过 | Per Game | System |
| `WineReady` | 当前游戏选中的 MiPlay 托管版本已安装、身份一致、运行环境准备完成并通过启动前置验证 | Per Game | System |
| `RuntimeUnavailable` | 当前选中或候选版本不可用，不能产生启动语义 | Per Game | System |
| `RecoveryRequired` | 当前游戏相关的下载、安装、取消或删除副作用尚未收敛 | Per Game | System |

### 兼容方案相关状态

| 状态名称 | 描述 | 作用域 | 触发来源 |
|---------|------|--------|---------|
| `Applying` | 兼容方案正在被应用到系统中 | Per Game | User |
| `Applied` | 真实操作完成，后置状态验证通过，且应用前状态可用于恢复 | Per Game | System |
| `Failed` | 操作或后置验证失败；不得解释为已应用 | Per Game | System |
| `RolledBack` | 已恢复到应用前状态，并通过恢复结果验证 | Per Game | System / User |
| `Unavailable` | 资源、适用范围或权限能力不满足，不进入应用流程 | Per Game | System |

### 完整性校验结果状态

| 状态名称 | 描述 | 作用域 | 触发来源 |
|---------|------|--------|---------|
| `IntegrityPassed` | 使用非空、版本对应的 manifest，全部必需文件通过内容校验 | Per Game | System |
| `IntegrityFailed` | 有文件缺失或内容不匹配 | Per Game | System |
| `IntegrityUnsupported` | manifest 缺失、为空、不对应当前版本或无法验证；不得报告为通过 | Per Game | System |
