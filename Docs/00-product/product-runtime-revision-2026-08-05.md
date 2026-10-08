# MiPlay 运行时产品语义修订

> **文档状态**：已冻结（本阶段 Product 回溯）
> **产品阶段**：Product Definition（问题空间定义）
> **当前版本边界冻结**：2026-08-05
> **最新用户硬性修订**：2026-08-27 覆盖此前 I-4 的“全局 / 单独 Wine 版本”设计，冻结单一固定 Wine 与单一共享 prefix
> **适用范围**：固定 Wine Release 获取、校验、安装、共享 prefix、恢复、启动前置验证和设置页设备信息

## 1. 修订结论

当前版本只支持一个固定的 MiPlay 托管 Wine Release：`wine-crossover-11.0-1-signed`。三款受支持游戏（原神、星穹铁道、绝区零）共用这一托管 Wine，且共用一个由 MiPlay 管理的 Wine prefix。产品不提供多版本选择、来源选择、按游戏 Wine 覆盖或用户删除当前固定运行时。

固定 Release 的获取来源仍必须属于产品批准范围，但来源由产品固定和管理，不作为用户可选择的设置。系统 Wine、Whisky、CrossOver 或其他本机 Wine 不属于候选运行时：不检测、不展示、不导入、不复用，也不作为失败后的 fallback。用户不能输入 URL、选择镜像或指定外部路径。

本修订覆盖此前 I-4 的“全局 Wine 版本 / 按 Game ID 单独覆盖”定义。当前产品只有一个生效 Wine 身份和一个共享 prefix；Game ID 只用于表达目标游戏的启动前置验证结果，不再用于绑定不同 Wine 或不同 prefix。

托管、内容校验、安装提交、恢复和启动前置验证仍然是独立门槛。下载完成、文件存在、解压完成、日志存在或代码入口执行，都不能单独形成已安装、共享 prefix 就绪或 `WineReady` 证据。本文件冻结产品语义，不声明当前代码、网络下载或真实 Wine 启动已经通过。

## 2. 唯一的当前运行时定义

### 2.1 产品定义

“当前运行时”唯一表示：

> **固定的 `wine-crossover-11.0-1-signed` 托管 Wine、唯一共享 prefix，以及目标 Game ID 的启动前置验证结果。**

三款游戏的 Wine 版本身份和 prefix 身份必须相同。当前游戏之间可以因为游戏可执行文件、路径、兼容方案或启动前置条件不同而得到不同 readiness 结果，但不得因此形成不同 Wine 版本、不同 prefix 或 per-game Wine 选择状态。

### 2.2 用户和系统应当区分的事实

| 产品事实 | 准确定义 | 是否足以称为当前运行时就绪 |
|---|---|---|
| 固定 Release 获取目标 | 产品批准并固定为 `wine-crossover-11.0-1-signed` 的唯一 Wine 资源身份 | 否；目标身份不代表本地存在 |
| 下载中资源 | 正在获取固定 Release 的资源 | 否；传输中或部分资源不构成运行时 |
| 已校验资源 | 固定 Release 已完成获取并通过内容校验、等待安装提交的资源 | 否；仍未形成已安装运行时 |
| 已安装托管 Wine | 固定 Release 已完成托管安装，身份可复核且安装事实可重读 | 否；共享 prefix 可能尚未就绪 |
| 共享 prefix | 三款游戏共同使用的唯一 MiPlay 托管 prefix；其身份、内容和可用性可复核 | 否；还必须通过目标游戏启动前置验证 |
| 游戏启动前置结果 | 目标 Game ID 使用同一固定 Wine 与共享 prefix 时的启动前置验证结果 | 只有结果为 `WineReady` 时才支持启动 |
| 当前运行时 | 固定托管 Wine、共享 prefix 和目标游戏 readiness 的组合 | 只有目标游戏为 `WineReady` 时才支持启动 |
| 本机可执行文件 | 机器任意位置存在的 Wine、Wine wrapper 或 bottle | 永远不是 MiPlay 当前运行时 |

### 2.3 当前运行时的产品展示边界

当前运行时相关信息应表达以下事实：

1. **固定身份**：显示 `wine-crossover-11.0-1-signed` 及其经过批准的来源身份。用户不能更改版本或来源。
2. **托管状态**：明确未安装、获取中、校验中、安装中、已安装、失败、已取消、升级中或需要恢复。
3. **共享环境状态**：明确唯一共享 prefix 未准备、准备中、已就绪、失败或需要恢复。不得把 prefix 拆成三款游戏各自的产品对象。
4. **目标游戏 readiness**：明确当前 Game ID 使用共享 Wine/prefix 的启动前置结果；某游戏未就绪不代表存在另一个 Wine 或 prefix 可替代。
5. **操作边界**：不显示版本选择器、来源选择器、按游戏覆盖入口、用户下载目录入口或当前固定运行时删除入口。
6. **路径**：运行时路径不是默认用户文案。受控诊断可以记录安全的身份摘要；产品展示不得要求用户理解或复制路径来判断是否可用。

## 3. 固定 Wine 与共享 prefix 语义

### 3.1 固定 Release 策略

| 项目 | 产品状态 | 规则 |
|---|---|---|
| `wine-crossover-11.0-1-signed` | 支持，当前唯一 Release | 由 MiPlay 从产品批准来源获取、校验、安装和恢复；三款游戏共用 |
| 其他 Wine 版本 | 不支持 | 不展示、不选择、不下载、不安装、不作为 fallback |
| 来源选择 | 不提供 | 来源由产品固定；用户不能选择官方 GitHub、镜像或其他来源 |
| 用户 URL / 外部路径 | 禁用 | 不输入、不保存、不请求、不下载、不重试、不导入 |
| 系统 Wine / Whisky / CrossOver Wine | 禁用，不检测 | 不读取、不展示、不导入、不复用，不得进入 `WineReady` |

固定 Release 是产品事实，不是动态版本目录中的候选项。远程目录、API 返回、资源名称或 `wine --version` 输出不能扩大当前支持范围，也不能产生用户可选择的版本集合。固定 Release 的具体批准来源身份仍由产品发布资料维护，但不转化为用户可见的来源选择能力。

### 3.2 固定 Release 的获取与安装

固定 Release 只有在以下门槛全部满足后，才形成已安装托管 Wine：

- 资源身份与固定 Release `wine-crossover-11.0-1-signed` 一致；
- 资源完整获取并通过内容校验；
- 安装结果位于 MiPlay 管理范围内；
- MiPlay 管理的可执行文件身份能够被验证，并与固定 Release 记录一致；
- 安装提交完成；
- 重新读取持久化记录后，固定身份和安装事实仍一致。

下载完成、解压目录存在、任意位置存在 `wine` 可执行文件或 `wine --version` 返回文本，均不足以形成已安装托管 Wine。校验、安装提交或重读失败时，固定运行时不得进入已安装或可启动状态。

### 3.3 单一共享 prefix

MiPlay 当前版本只有一个共享 Wine prefix 产品事实：

- 三款游戏都使用同一个共享 prefix；
- 不按 Game ID 创建、选择、切换或持久化不同 prefix；
- 共享 prefix 必须属于 MiPlay 管理范围，身份和内容可复核；
- 共享 prefix 的准备、验证或恢复未完成时，三款游戏都不能报告完整的 `WineReady`；
- 某个游戏的启动前置失败，只影响该 Game ID 的 readiness，不产生新的 prefix，也不允许切换到外部 Wine。

共享 prefix 就绪是公共门槛；目标游戏 readiness 是在该公共门槛之上对具体游戏启动前置条件的结果。二者都不能被下载完成或静态文件存在替代。

### 3.4 用户选择和删除边界

- 用户不能选择 Wine 版本、选择来源或为某一游戏设置 Wine 覆盖。
- 用户不能删除当前固定 `wine-crossover-11.0-1-signed` 托管运行时。
- 用户不能删除当前共享 prefix，也不能将其替换为外部 prefix。
- 固定运行时损坏、缺失或校验失效时，产品提供的是受控的重新获取、修复或恢复语义，不是删除后选择另一版本。
- 清理下载临时资源、失败安装结果或恢复所需的无效内容，不等于用户删除当前运行时，也不能制造多版本目录。

## 4. Readiness 与启动语义

`WineReady` 是 **目标 Game ID 的启动前置结果**，但它只能建立在同一个固定托管 Wine 和同一个共享 prefix 之上。只有以下事实同时成立，目标游戏才可为 `WineReady`：

1. 固定 Release 身份为 `wine-crossover-11.0-1-signed`，且来源属于产品批准范围；
2. 固定 Wine 已由 MiPlay 完成安装并通过身份复核；
3. 唯一共享 prefix 已准备完成，身份和内容验证通过；
4. 固定 Wine、共享 prefix 和持久化事实保持一致；
5. 目标 Game ID 的游戏路径、运行环境和启动前置校验通过。

真实 Wine 运行和游戏进程启动仍需用户验证；用户验证完成前，不能把日志、文件存在或静态检查当作真实启动证据。

| readiness 结果 | 产品含义 | 启动语义 |
|---|---|---|
| `WineReady` | 固定托管 Wine、共享 prefix 和目标游戏启动前置条件全部通过 | 允许进入启动流程 |
| `RuntimeNotReady` | 固定 Wine 或共享 prefix 存在，但安装身份、环境准备或目标游戏启动前置校验未通过 | 阻止启动并显示可修复原因 |
| `NoManagedRuntime` | 固定 Wine 尚未形成有效托管安装事实 | 阻止启动，引导获取固定 Release |
| `RuntimeUnavailable` | 固定资源、权限、适用性或托管身份不满足 | 不提供可启动语义 |
| `RecoveryRequired` | 获取、安装、prefix 准备、升级或取消的副作用尚未收敛 | 阻止继续操作，先完成恢复 |

## 5. 固定 Wine 的下载、安装、失败、取消、恢复和升级

| 阶段或结果 | 产品定义 | 对固定运行时和共享 prefix 的影响 |
|---|---|---|
| `Available` | 唯一固定 Release 的资源身份、适用架构和获取条件可验证 | 不创建本地安装或 readiness 事实 |
| `Downloading` | 固定 Release 资源正在传输 | 不创建已安装 Wine、共享 prefix 或 `WineReady` |
| `DownloadFailed` | 传输、来源身份、重定向、内容校验或资源完整性失败 | 不产生新安装；保留此前有效的固定 Wine 与共享 prefix |
| `ArtifactReady` | 固定 Release 资源完整并通过内容校验，等待安装提交 | 仍不产生已安装 Wine 或 `WineReady` |
| `Installing` | 正在安装固定 Wine、验证 executable 并提交安装事实 | 不得展示为已安装或 `WineReady` |
| `Installed` | 唯一固定 Wine 的安装提交和重读确认完成 | 可进入共享 prefix 准备；不自动表示 prefix 或游戏就绪 |
| `PrefixPreparing` | 唯一共享 prefix 正在准备或验证 | 三款游戏均不得报告 `WineReady` |
| `PrefixReady` | 唯一共享 prefix 身份、内容和准备结果通过 | 允许分别进行三款游戏的启动前置验证 |
| `RuntimeNotReady` | Wine 或共享 prefix 存在，但目标游戏启动前置未通过 | 阻止对应游戏启动 |
| `WineReady` | 固定 Wine、共享 prefix 和目标游戏启动前置全部通过 | 允许进入启动流程 |
| `InstallFailed` | 固定 Wine 的校验、安装、身份、提交或重读失败 | 不创建新安装或 readiness；清理结果另行表达 |
| `Cancelled` | 用户取消已处理，必要清理或恢复已确认 | 未提交的新资源不进入安装；此前有效的固定 Wine 与共享 prefix 继续保留 |
| `RecoveryRequired` | 失败、取消、prefix 准备或升级产生副作用，清理/恢复尚未确认 | 不得报告完成；阻止继续操作和启动 |
| `UpgradeAvailable` | 产品发布要求将唯一固定 Release 更新为新的产品批准身份 | 不提供版本选择；当前固定 Wine 继续作为唯一有效运行时 |
| `Upgrading` | 受控升级正在校验并替换固定 Wine/prefix 产品事实 | 旧的有效运行时继续作为权威事实，直到新结果通过验证 |
| `UpgradeFailed` | 新固定 Release 或共享 prefix 升级未通过验证 | 保留旧的有效运行时；无法恢复时进入 `RecoveryRequired` |
| `Unavailable` | 固定资源、权限、架构或适用性不满足 | 不展示可应用或可启动语义 |

下载进度、预计大小、速度和阶段必须属于同一个固定 Release 目标。预计大小未知时，不得伪造确定百分比；速度必须代表连续传输样本。产品不提供用户可配置的下载目录、多个版本目录或外部安装路径；临时资源和失败清理只服务于固定目标的生命周期。

### 5.1 失败、取消和恢复规则

- 下载或安装失败、取消，不得清除或覆盖此前有效的固定托管 Wine、共享 prefix 或目标游戏 readiness 事实。
- 固定 Wine 安装失败时，不得把部分资源、解压目录或任意可执行文件作为当前运行时。
- 共享 prefix 准备失败时，三款游戏都保持未就绪或恢复中；不得为某一游戏创建替代 prefix。
- 失败或取消产生副作用且尚未收敛时进入 `RecoveryRequired`；恢复完成前不得继续同一目标操作或启动任一游戏。
- 恢复完成后，只有重新通过固定 Wine、共享 prefix 和目标游戏启动前置验证，才能恢复 `WineReady`。
- 任何失败都不得触发系统 Wine、Whisky、CrossOver Wine、未批准来源或外部路径 fallback。

### 5.2 升级规则

- 当前支持身份固定为 `wine-crossover-11.0-1-signed`；未来改变固定身份必须通过新的 MiPlay 产品版本或明确的 Product 迁移重新冻结，不能依赖动态版本目录让用户选择。
- 升级是固定托管 Wine 与共享 prefix 的受控产品升级，不是新增可选版本，也不产生用户可见的多版本集合。
- 在新固定 Release 和共享 prefix 的校验、安装、提交、重读及启动前置验证完成前，旧的有效运行时仍是唯一权威事实。
- 升级失败或取消时保留旧的有效 Wine/prefix；若旧状态无法确认或恢复未完成，则进入 `RecoveryRequired`，不得伪造新旧任一方为就绪。
- 用户不能通过删除旧运行时、选择另一版本或修改来源来完成升级。

## 6. 设置页设备信息边界

Mac 型号、macOS 版本和磁盘空间是设置页的只读信息能力，不属于固定 Wine 或共享 prefix 状态，也不决定 `WineReady`。

| 信息 | 产品定义 | 读取失败语义 |
|---|---|---|
| Mac 型号 | 只展示系统报告提供的型号文本，不从芯片或架构自行推断 | 显示不可用，保留读取失败事实 |
| macOS 版本 | 只展示系统报告提供的版本字符串 | 显示不可用，不能以旧值替代 |
| 磁盘空间 | 展示与 MiPlay 固定 Wine/prefix 获取和安装目标相关卷的当前空间信息 | 显示不可用，不能用无关卷、0、空值或路径推断结果冒充准确值 |

设备信息读取失败不会自动改变固定 Wine、共享 prefix 或 readiness，也不会允许或阻止启动；它只说明设置页信息不可用。

## 7. 用户问题与 Issue 追溯

| Issue | 产品要求 | 当前版本验收边界 |
|---|---|---|
| `DL-001` | 固定 Release 下载状态在同一目标上保持稳定，用户看到的阶段、身份和结果不能在刷新时跳变 | Product 只冻结状态必须保持同一固定目标和终态事实；具体刷新和动画由 UX/UI/Implementation 负责 |
| `DL-002` | 下载进度、预计字节、速度和结果必须真实对应固定 Release 资源 | 完成必须有可解释的传输结果；未知大小不报确定百分比，固定 0 或虚假速度不算通过 |
| `DL-003` | 下载后必须能确认 MiPlay 托管的固定 Wine executable 身份 | 找不到、身份不一致或无法读回均为 `InstallFailed`，不得进入 `Installed`、共享 prefix 或 `WineReady` |
| `INFO-001` | “当前运行时”固定表示唯一托管 Wine、唯一共享 prefix 及目标游戏 readiness | 三款游戏的 Wine/prefix 身份必须相同；目标游戏 readiness 仍单独表达 |
| `INFO-002` | 固定 Wine、共享 prefix、安装状态和 readiness 不能互相替代 | 下载、安装、prefix 准备、游戏前置验证必须分层表达；失败、取消和恢复保留此前有效事实 |
| `INFO-003` | 设置页设备信息必须来自准确的系统报告事实 | 型号和系统版本不推断；错误不伪造旧值；磁盘空间指向固定托管 Wine/prefix 目标卷 |
| `INFO-004` | 磁盘空间失败必须是明确的不可用事实 | 不以 0、空值或其他卷数据报告成功；不改变固定 Wine、共享 prefix 或 readiness |
| `STRUCT-001` | 下载、安装、共享 prefix、目标游戏 readiness 是可区分的产品阶段 | 任何阶段不得单独提升为 `WineReady`；取消/失败后的副作用必须进入恢复语义 |
| `I-4-OVERRIDE` | 最新用户意见覆盖此前 I-4 的全局/单独 Wine 设计 | 只保留一个固定 `wine-crossover-11.0-1-signed`、一个共享 prefix；不提供版本选择、来源选择或 Game ID Wine 覆盖 |
| `MIGRATION-003` | 旧 schema 3 数据迁移不得制造错误的 per-game 选择状态 | `selectedWineVersion` 和 `wineVersionOverride` 按第 8 节迁移；旧非固定版本不能成为运行时 |

## 8. 旧 schema 3 兼容迁移

从旧 schema 3 迁移到当前固定运行时语义时，产品事实按以下规则解释：

| 旧字段 | 迁移规则 | 迁移后产品事实 |
|---|---|---|
| `selectedWineVersion` 等于 `wine-crossover-11.0-1-signed` | 仅将其视为与当前固定身份一致的旧记录；不保留为用户可选版本字段 | 当前唯一固定 Wine 目标仍为 `wine-crossover-11.0-1-signed` |
| `selectedWineVersion` 为其他值或为空 | 不把旧值转换为新的运行时选择；不自动安装、保留或使用该版本 | 当前固定目标仍是 `wine-crossover-11.0-1-signed`；若未安装则为 `NoManagedRuntime` |
| `wineVersionOverride` 为任意值 | 全部忽略并清除其产品选择含义；不迁移为共享状态或新的 per-game 状态 | 三款游戏不再有 Wine 覆盖；全部使用同一个固定 Wine |
| `installedWineVersions` 含多个版本 | 只承认固定 Release 且经过 MiPlay 安装身份复核的事实；旧非固定版本不进入当前安装集合或用户可见列表 | 产品只保留一个固定托管 Wine 事实；旧非固定资源不得启动或作为 fallback |
| 旧来源选择字段 | 不保留用户来源选择语义；来源归一为产品批准的固定 Release 来源身份 | 用户不可选择来源、镜像、URL 或外部路径 |
| 旧 per-game Wine / prefix 状态 | 不制造游戏级 Wine 或 prefix 事实；共享 prefix 只有在唯一托管 prefix 重新验证通过后才成立 | 三款游戏共用一个共享 prefix；无法确认时为 `RuntimeNotReady` 或 `RecoveryRequired` |

迁移不得自动为任何 Game ID 写入 Wine 选择、Wine 覆盖或独立 prefix。迁移后的三款游戏只引用同一个固定托管 Wine 和同一个共享 prefix；旧数据不能把历史选择状态伪装成当前产品能力。迁移写入或重读失败时必须保留旧数据恢复事实，并不得报告 `WineReady`。

## 9. 与既有 Product 和 Review 结论的冲突登记

| 旧口径 | 冲突原因 | 2026-08-27 后有效口径 |
|---|---|---|
| Wine 可由全局默认和 Game ID 覆盖共同选择 | 用户最新意见要求三款游戏共用一个固定 Wine | 唯一支持身份为 `wine-crossover-11.0-1-signed`；不提供全局/单独版本选择或覆盖 |
| 三款游戏可以分别绑定不同 Wine | 与单一共享 Wine 要求冲突 | 三款游戏使用同一个托管 Wine 身份 |
| 三款游戏可以拥有各自 prefix | 与单一共享 prefix 要求冲突 | 三款游戏使用同一个 MiPlay 托管共享 prefix |
| 用户可见的来源 allowlist 选择 | 用户最新意见要求移除来源选择 | 来源仍受批准范围约束，但由产品固定；用户不可选择来源或输入 URL |
| 已安装但未被选中的 Wine 版本 | 单一 Wine 后不再存在多版本选中集合 | 只有固定 Release 的一个托管安装事实；无“未选中版本”产品状态 |
| 用户可以删除已安装版本 | 当前固定运行时必须始终作为产品唯一目标 | 不提供删除当前固定 Wine 或共享 prefix；损坏时走修复/恢复 |
| 动态 catalog 可提供未来版本 | 固定 Release 不能由动态目录扩大 | 升级只能通过新的 MiPlay 产品版本或明确 Product 迁移 |
| 旧 schema 3 `selectedWineVersion` / `wineVersionOverride` 可延续选择语义 | 会制造错误的 per-game 选择状态 | 迁移只归一固定身份，清除所有覆盖含义，不自动写入任何 Game ID 选择 |
| 下载完成等于 Wine 可用 | 忽略校验、安装、共享 prefix 和启动前置 | 下载、安装、prefix 准备和 `WineReady` 各自独立验收 |
| 机器上存在 Wine 即可作为运行时线索 | 会把系统 Wine、Whisky 或 CrossOver 误认为受支持 | 只有固定 MiPlay 托管 Wine + 共享 prefix + 目标游戏前置验证通过才有启动语义 |

Review 的下载、安装、prefix、权限和真实启动缺口继续有效。当前 Product 只冻结验收定义，不能用代码入口、日志、目录存在、HTTP 成功或部分网络结果关闭这些缺口。用户验证通过前，Release 不得把本文件矩阵标记为已完成。

## 10. Must / Deferred / Out of Scope

| 优先级 | 产品能力 | 当前版本状态 |
|---|---|---|
| Must | 固定 `wine-crossover-11.0-1-signed` 的 MiPlay 托管、来源批准、内容校验、安装提交和身份复核 | 当前版本验收范围 |
| Must | 三款游戏共用一个托管 Wine 身份 | 当前版本验收范围 |
| Must | 三款游戏共用一个 MiPlay 托管共享 prefix | 当前版本验收范围 |
| Must | 固定 Wine 的下载、安装、失败、取消、恢复和启动前置验证状态区分 | 当前版本验收范围 |
| Must | 固定 Wine 与共享 prefix 的升级语义；升级失败保留此前有效事实或进入恢复 | 当前版本验收范围 |
| Must | 旧 schema 3 `selectedWineVersion` / `wineVersionOverride` 兼容迁移，不制造 per-game 选择 | 当前版本验收范围 |
| Should | 设置页 Mac 型号、macOS 版本和固定 Wine/prefix 目标卷磁盘空间的准确只读展示 | 当前版本产品范围，具体优先级沿用 `product-features.md` |
| Deferred | 官方游戏安装、自定义启动参数、帧率解锁、截图/视频目录入口 | 不进入本轮 Implementation 或 Release 验收 |
| Deferred | Retina、Steam patch / Steam 白名单、旧版反作弊文件替换、Metal HUD、左 Command 映射 Control、hosts 屏蔽 | 属于当前版本目标但本轮暂缓实现；不得显示为已实现或可应用 |
| Out of Scope | 多版本选择、按 Game ID Wine 覆盖、用户来源选择、自由 URL、用户下载目录、用户删除当前固定 Wine/prefix | 当前产品不提供 |
| Out of Scope | 系统 Wine、Whisky、CrossOver 或其他外部 Wine/prefix 的检测、导入、复用和 fallback | 永不成为当前版本运行时 |

## 11. Product 验收声明

本修订完成的验收仅表示产品边界和术语已经冻结。下游必须分别证明：固定 Release 资源身份正确、下载结果真实、托管 Wine 安装完成、唯一共享 prefix 准备完成、目标游戏启动前置验证通过，以及失败/取消/恢复/升级状态正确收敛。任何一个门槛缺失，都只能报告对应的未就绪或失败状态，不能用另一个状态替代。

验收还必须确认：三款游戏只有一个生效 Wine 身份和一个共享 prefix；不存在用户可见的版本选择、来源选择、按游戏覆盖、多版本目录或当前固定运行时删除语义；旧 schema 3 数据迁移不会恢复或制造错误的 per-game Wine 选择状态。
