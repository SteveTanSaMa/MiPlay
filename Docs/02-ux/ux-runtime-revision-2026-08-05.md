# MiPlay UX 回溯补充：背景 hover 预览、统一 Wine 与共享 prefix

> **文档状态**：UX 回溯补充稿
> **更新日期**：2026-08-27
> **修订（R-1/R-2/R-4）**：2026-08-27 覆盖此前 I-4 的版本作用域设计，冻结单一 Wine runtime、单一共享 prefix 与简化设置流程
> **依据**：[product-runtime-revision-2026-08-05.md](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/00-product/product-runtime-revision-2026-08-05.md)、[research-wine-shared-prefix-2026-08-27.md](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/01-research/research-wine-shared-prefix-2026-08-27.md)、[research-wine-archive-and-mac-info-2026-08-05.md](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/01-research/research-wine-archive-and-mac-info-2026-08-05.md)
> **范围**：用户任务、信息模型、状态文案、刷新和恢复语义；不定义 SwiftUI、下载协议或安装实现。

## 1. 冻结事实与术语

- 当前唯一受支持的 Wine runtime 是 MiPlay 托管的固定 Release：`wine-crossover-11.0-1-signed`。不提供多版本选择、来源选择、自由 URL、外部路径或用户删除入口。
- 原神、星穹铁道、绝区零共用同一个固定 Wine runtime；三款游戏不再各自选择 Wine。
- 三款游戏共用一个由 MiPlay 管理的 Wine prefix。prefix 不是 Wine 归档内的 `wine/` 目录，而是由固定 Wine 初始化形成的共享运行时状态。
- 系统 Wine、Whisky、CrossOver 或其他本机 Wine/prefix 不检测、不展示、不导入、不复用，也不作为失败后的 fallback。
- **固定 runtime**：唯一固定 Release 的身份、托管安装状态和持久化安装事实。
- **共享 prefix**：三款游戏共同使用的唯一 prefix 身份、初始化/验证状态、占用状态和恢复事实。
- **游戏 readiness**：目标 Game ID 使用同一固定 Wine 和同一共享 prefix 时的启动前置结果。它可以因游戏路径、manifest、兼容方案或进程事实不同而不同，但不能产生不同 runtime 或 prefix。
- **`WineReady`**：固定 Wine 已安装、共享 prefix 已就绪、目标游戏启动前置已通过。只有该结果才具有启动语义。

下载完成、文件存在、解压目录存在、`wine --version` 有输出或 prefix 目录存在，都不能单独产生“已安装”“prefix 已就绪”或 `WineReady`。

### 1.1 背景组圆点 hover 预览（I-2 冻结）

主界面背景圆点默认隐藏；鼠标进入顶部区域后显示候选圆点。hover 到某个候选组时进入预览态，并与当前选中和其他候选组区分。hover 预览是临时媒体事实，不是背景组选择：

- `idle`：当前未 hover 任何圆点，画面为持久化选中组。
- `hoverPreview(groupID)`：鼠标悬停在候选组，画面尝试预览该组；离开该圆点或顶部区域后恢复当前选中组。
- `selected`：用户通过点选、Return 或 Space 明确提交目标组；只有目标组资源全部验证、选择写回并重读通过后才成为持久化选中。
- 预览不得改变 `selectedBackgroundGroupID`，不得写持久化，不得删除任何背景缓存；离开 hover 后恢复当前选中组。
- 未缓存的目标组允许加载预览，但加载必须可取消。取消只结束预览，不改变当前背景、不删除缓存，也不把该预览写成选中。
- 同一候选组的预览加载未完成时，重复 hover 复用同一加载，不重复发起；加载成功后再次 hover 直接使用已缓存预览。
- 预览加载失败时保持当前选中组；失败事实可以显示和重试，但不进入持久化业务状态。

## 2. Wine 设置页信息模型

Wine 设置只管理一个固定 runtime 和一个共享 prefix，不与三款游戏的独立非 Wine 设置混合。进入后直接查看统一 runtime 的状态和唯一任务流程，不出现版本作用域切换、版本列表选择、来源选择、per-game Wine 覆盖或删除当前 runtime 的路径。

1. **固定 runtime**：显示固定身份 `wine-crossover-11.0-1-signed`、托管安装状态和当前任务。
2. **共享 prefix**：显示唯一 prefix 的未初始化、准备中、已就绪、占用、失败或恢复状态。
3. **三款游戏 readiness**：分别显示每个 Game ID 在同一 runtime/prefix 上的启动前置结果。
4. **当前任务**：下载、校验、安装、prefix 初始化、验证、升级或恢复中的目标、阶段、进度和恢复动作。

“Wine 已安装”只说明固定 runtime 的安装事实；“共享 prefix 已就绪”只说明公共环境事实；二者都不能直接显示“三款游戏均已就绪”。

### 2.1 单一 runtime 任务流（R-1/R-2/R-4 冻结）

```text
进入 Wine 设置
  ↓ 读取固定 runtime 与共享 prefix 状态
  ├─ 固定 runtime 未安装/不可确认
  │    → 获取固定 Release → 校验资源 → 安装并重读确认
  ├─ 固定 runtime 已安装，prefix 未就绪
  │    → 初始化/更新唯一共享 prefix → 验证 prefix
  ├─ 固定 runtime 与 prefix 均就绪
  │    → 分别读取三款游戏的启动前置结果
  └─ 任一阶段失败、取消或副作用未收敛
       → 保留此前有效事实 → 显示恢复动作 → 恢复完成后重新验证
```

- 所有下载、安装和 prefix 操作只绑定一个明确目标：固定 `wine-crossover-11.0-1-signed` 与唯一共享 prefix。
- 用户不选择版本、来源、prefix 或游戏级 Wine；设置页没有“未选中版本”或“单独覆盖”终态。
- 共享 prefix 被占用时，涉及 prefix 初始化、更新、修复或恢复的操作不得并发执行或重复排队；用户看到“共享运行环境正在使用中”，等待当前使用结束后再继续。
- prefix 占用是运行条件/保护事实，不是新的用户可选择 runtime，也不触发其他 prefix 或系统 Wine fallback。

### 2.2 当前运行时状态

| 状态 | 准确文案 | 用户动作 | 终态定义 |
|---|---|---|---|
| 公共运行环境状态 | “统一 Wine 与共享运行环境状态” | 查看安装、prefix 和三款游戏 readiness | 不因当前查看的游戏改变固定 runtime 或共享 prefix |
| 固定 runtime 未安装 | “统一 Wine 尚未安装” | 获取固定 Release | `NoManagedRuntime`，三款游戏均不能启动 |
| 固定 runtime 安装中 | “正在安装统一 Wine；共享环境尚未准备” | 等待或取消 | 不产生 `WineReady` |
| 共享 prefix 未准备 | “统一 Wine 已安装，共享运行环境尚未准备” | 初始化或恢复共享 prefix | `RuntimeNotReady`，三款游戏均不能报告 Ready |
| 共享 prefix 准备中 | “正在准备共享运行环境” | 等待；占用时等待当前使用结束 | 三款游戏均不能报告 `WineReady` |
| 共享 prefix 已就绪 | “统一 Wine 与共享运行环境已准备” | 查看各游戏启动前置 | 仍不等于三款游戏均就绪 |
| 目标游戏已就绪 | “{游戏名}可使用统一 Wine 启动” | 启动游戏 | `WineReady`，允许启动前置流程 |
| 目标游戏未就绪 | “统一运行环境已准备，但{游戏名}启动前置未通过” | 修复目标游戏路径、完整性或前置条件 | `GamePreflightFailed`，只阻止该游戏 |
| 共享 prefix 被占用 | “共享运行环境正在使用中” | 等待当前使用结束，不重复发起变更 | 保持当前已确认事实 |
| 不可用 | “当前运行时不可用：{原因}” | 按原因重试或等待修复 | `RuntimeUnavailable`，不提供启动语义 |
| 需要恢复 | “统一运行环境状态未确认，当前不能继续操作” | 先完成共享 prefix/Wine 恢复 | `RecoveryRequired`，阻止三款游戏相关新任务 |

`GamePreflightFailed` 仅用于 UX 归因“游戏自身前置失败”，不是新的 Wine runtime 状态。若下游使用 Product 既有 `RuntimeNotReady` 枚举，应将其标记为游戏范围失败；固定 runtime 或共享 prefix 失败则标记为 runtime 范围失败。

### 2.3 固定 runtime、共享 prefix 与游戏 readiness

| 事实层 | 用户必须能区分的内容 | 不能推断 |
|---|---|---|
| 固定 runtime 安装 | 固定 Release 资源身份、内容校验、托管安装、executable 身份和持久化重读 | 不能从下载完成、解压目录或 `wine --version` 推断安装成功 |
| 共享 prefix | 唯一 prefix 身份、初始化/更新结果、内容验证、当前占用和恢复状态 | 不能从 prefix 目录存在推断 prefix 已就绪 |
| 游戏 readiness | 每个 Game ID 的路径、manifest、兼容方案和启动前置结果 | 不能把另一款游戏的 Ready 或 prefix 事实复制给当前游戏 |

固定 runtime 安装失败或共享 prefix 未就绪时，三款游戏都不能显示完整 `WineReady`。共享 prefix 已就绪后，三款游戏仍须分别通过自己的游戏路径和启动前置；一款游戏失败不改变其他游戏的游戏级 readiness，也不创建新的 runtime/prefix。

### 2.4 旧 per-game override 的迁移后表现

- 旧 `selectedWineVersion` 不再是用户可修改的选择。只有与固定身份一致且重新验证通过的记录，才可作为固定 runtime 的历史证据；其他值或空值不能形成当前运行时。
- 旧 `wineVersionOverride` 全部忽略并清除其产品选择含义，不迁移为共享状态，也不保留新的游戏级 Wine 设置。
- 旧按游戏 prefix 不继续使用；迁移后必须重新初始化并验证唯一共享 prefix。无法确认时显示 `NoManagedRuntime`、`RuntimeNotReady` 或 `RecoveryRequired`，不能显示旧选择仍然有效。
- 迁移后设置页只有一个固定 runtime、一个共享 prefix 和三款游戏各自 readiness；用户不需要也不能选择作用范围、版本、来源或 prefix。

## 3. 固定 Wine、安装与共享 prefix 状态流

```text
读取固定 Release
  ├─ 目标身份不匹配/来源信息无法验证 → 固定 runtime 不可用
  ├─ 网络或资源失败 → 保留旧有效事实，等待用户重试
  └─ 身份和资源可验证 → 下载固定 Release
       ├─ 用户取消且清理确认 → cancelled，旧事实保持
       ├─ 下载/内容校验失败 → DownloadFailed，不能安装
       └─ 资源完整 → ArtifactReady
            → 安装固定 Wine、验证 executable、提交并重读
                 ├─ 失败 → InstallFailed 或 RecoveryRequired
                 └─ 成功 → Installed
                      → 初始化/更新唯一共享 prefix
                           ├─ prefix 被占用 → PrefixPreparing + busy，等待释放
                           ├─ 初始化失败 → PrefixNotReady
                           ├─ 取消且清理确认 → cancelled，prefix 事实保持
                           ├─ 清理/恢复未确认 → RecoveryRequired
                           └─ 验证通过 → PrefixReady
                                → 分别验证三款游戏 readiness
```

### 3.1 固定 Release 检查反馈

| 事实 | 用户文案 | 恢复动作 | 终态 |
|---|---|---|---|
| 首次检查 | “正在检查统一 Wine” | 等待或取消 | 检查中，不是未安装结论 |
| 固定 Release 身份可验证 | “已找到统一 Wine 安装资源” | 开始下载 | 只产生固定获取目标 |
| 来源身份无法验证 | “统一 Wine 来源无法确认” | 稍后重试或等待 MiPlay 修复 | `RuntimeUnavailable`，不提供来源选择 |
| 网络/服务失败 | “无法获取统一 Wine 安装资源” | 恢复网络后重试 | 保留此前有效 runtime/prefix |
| 资源身份不匹配 | “统一 Wine 安装资源与受支持版本不匹配” | 等待产品更新或重试 | 不进入安装 |

来源由产品固定和管理。用户不能选择官方 GitHub、镜像或其他来源；任何失败都不能回退到系统 Wine、Whisky、CrossOver 或外部 prefix。

### 3.2 下载、安装与 prefix 反馈

| 阶段/结果 | 用户文案 | 恢复动作 | 对固定 runtime/prefix 的影响 |
|---|---|---|---|
| `pending` | “已提交统一 Wine 任务，等待执行” | 等待或在未开始时取消 | 不改变固定 runtime/prefix |
| `running` 下载中 | “正在下载统一 Wine” | 查看真实进度或取消 | 不产生安装或 Ready |
| 内容校验中 | “正在验证统一 Wine 安装资源” | 等待或按规则取消 | 不产生安装或 Ready |
| 安装中 | “正在安装统一 Wine” | 等待；发生副作用后按恢复规则处理 | 不产生 prefix 或 Ready |
| executable 找不到/身份不一致 | “统一 Wine 安装失败：无法确认托管可执行文件” | 清理临时内容后重试固定 Release | 不进入已安装事实 |
| 安装记录无法重读 | “统一 Wine 安装状态无法确认” | 先完成恢复/重试提交 | `InstallFailed` 或 `RecoveryRequired` |
| 安装成功 | “统一 Wine 已安装，共享运行环境尚未准备” | 初始化共享 prefix | 不等于三款游戏 Ready |
| prefix 初始化中 | “正在准备共享运行环境” | 等待；不重复发起 | 三款游戏均不 Ready |
| prefix 被占用 | “共享运行环境正在使用中” | 等待当前 Wine 使用结束 | 不清理、不替换、不创建新 prefix |
| prefix 初始化失败 | “共享运行环境准备失败，三款游戏暂不能启动” | 重试初始化或进入恢复 | 三款游戏均不 Ready |
| prefix 内容/身份无法确认 | “共享运行环境状态无法确认” | 先恢复或重新验证 | `PrefixNotReady` 或 `RecoveryRequired` |
| prefix 就绪 | “共享运行环境已准备” | 分别检查目标游戏 | 只形成公共门槛 |
| 游戏 readiness 失败 | “统一运行环境已准备，但{游戏名}启动前置未通过” | 修复该游戏路径、完整性或前置条件 | 只影响该游戏，不创建新 prefix |
| 用户取消 | “统一 Wine 操作已取消，当前有效环境保持不变” | 清理确认后重新提交 | Task `cancelled` 仅在清理确认后成立 |

下载完成不是安装完成；安装完成不是 prefix 就绪；prefix 就绪不是三款游戏全部 Ready。失败、取消或恢复中的新资源不得覆盖此前可验证的固定 runtime、共享 prefix 或游戏 readiness。

## 4. 固定 Wine 任务期间稳定的进度与状态语义

任务状态必须固定绑定到唯一目标：固定 Release `wine-crossover-11.0-1-signed` 和唯一共享 prefix。展示区域保留稳定的语义字段，不因阶段切换创建/删除整块内容，也不把动态错误文案替换主标题。

| 字段 | 可确认时 | 不可确认时 | 规则 |
|---|---|---|---|
| 阶段 | “下载中”“验证资源”“安装中”“准备共享环境”“正在恢复” | “阶段未知，状态仍在确认” | 阶段变化不改变固定 runtime/prefix 目标 |
| 进度 | 真实百分比 | “进度未知” | 不用时间或动画估算；未知总大小不伪造百分比 |
| 速度 | 当前目标的近期传输速度 | “速度未知” | 没有连续样本时不显示 0 代替未知 |
| 已传输/总量 | 真实已传输量和已知总量 | “总大小未知” | 不把目录元数据或旧任务数值复用到固定任务 |
| 可取消 | “可取消”或“正在清理，不能取消” | “取消状态未知” | 取消请求不等于取消完成 |

下载、安装和 prefix 准备期间只更新字段值和阶段事实；不反复替换“正在下载统一 Wine”“正在准备共享运行环境”等主文案，不让失败提示、速度变化或进度更新改变内容的语义位置。VoiceOver 不逐次播报速度采样，只在阶段、占用/可取消性和终态改变时播报。

## 5. 刷新与任务状态流

刷新是读取固定 runtime、共享 prefix 和三款游戏 readiness 当前事实的动作；下载、安装、prefix 初始化、修复和升级是有副作用的任务。刷新不能代替任务终态，也不能在任务进行中创建第二个同目标任务。

| 触发 | 刷新内容 | 允许条件 | 结束语义 |
|---|---|---|---|
| 页面首次打开 | 固定 runtime、共享 prefix 和三款游戏 readiness | 每个读取目标只启动一次 | 成功、未安装、失败或恢复均结束 busy |
| 用户手动刷新 | 固定 runtime、共享 prefix 和游戏 readiness | 同一读取进行中复用/忽略重复触发 | 新一次读取有独立结果 |
| 下载完成 | 固定 runtime 安装状态和共享 prefix 状态 | 仅在下载任务终态后触发一次 | 资源、安装和 prefix 必须继续区分 |
| 安装完成 | 固定 runtime 安装记录和共享 prefix 状态 | 安装提交重读后触发一次 | 只有重读成功才显示已安装 |
| prefix 初始化/恢复完成 | 共享 prefix 状态和三款游戏 readiness | 共享操作终态后触发一次 | 只有验证通过才显示 PrefixReady |
| 游戏启动前置刷新 | 目标 Game ID 的路径、完整性和 readiness | 只刷新目标游戏；共享 prefix 事实保持一致 | 不改变其他游戏 readiness |
| 固定 runtime 失败后重试 | 同一固定 Release 和共享 prefix 目标 | 用户主动触发 | 不创建版本选择或隐藏 fallback |

刷新规则：

- 同一目标已有进行中的读取时，不重复启动、不清空已有结果、不重置进度；用户看到“正在更新”。
- 旧请求返回时，如果目标固定 runtime、共享 prefix、Game ID 或操作已变化，旧结果只作为诊断，不覆盖新结果。
- 每次刷新最终必须离开 busy：成功、空、失败、取消或不可用都要有终态；超时/取消也不能永久显示加载。
- 任务失败或取消后，可以保留上一次可信的固定 runtime、共享 prefix 和游戏 readiness，并明确标记它们不是本次新结果。
- 下载/安装/prefix 任务的 `pending/running/completed/failed/cancelled` 不被刷新改写；`RecoveryRequired` 只是保护事实，必须先恢复再允许同目标任务或任一游戏启动。

### 5.1 Task 状态与 Wine 业务结果

Task 状态只回答任务生命周期，业务结果必须同时回答目标是否真正改变：

| Task 状态 | 用户事实 | Wine 业务边界 |
|---|---|---|
| `pending` | “已提交统一 Wine 任务，等待执行” | 不代表下载、安装或 prefix 操作已经开始 |
| `running` | “正在执行{阶段}” | 不代表固定 runtime 或共享 prefix 已改变；进度和速度只能使用同一目标的真实值 |
| `completed` | “{阶段}已完成” | 只表示当前 Task 自己的成功门槛通过；安装完成仍可能尚未初始化共享 prefix |
| `failed` | “{阶段}失败：{原因}” | 目标未达成或结果无法确认；保留此前有效 runtime/prefix 和游戏事实 |
| `cancelled` | “{阶段}已取消，清理已确认” | 只在必要清理/恢复完成后成立；不能覆盖此前有效 runtime/prefix |

## 6. “此 Mac”信息模型

“此 Mac”是通用设置中的只读信息组，与固定 Wine、共享 prefix 和游戏 readiness 分开。它按“关于本机”的表达层级展示：机型、芯片、内存、macOS 版本；未知字段显示未知，不从 model identifier、架构、卷名或历史缓存推断。它不展示序列号、平台 UUID、UDID、完整路径或其他非必要设备标识。

### 6.1 信息层级

| 层级 | 字段 | 用户语义 | 禁止推断 |
|---|---|---|---|
| 主层级 | 机型 | 系统报告提供的 machine name，例如 MacBook Pro | 不从 model identifier 拼出尺寸或营销后缀 |
| 主层级 | 芯片 | 系统报告提供的 chip name，例如 Apple M1 Pro | 不从 model identifier 推断芯片 |
| 主层级 | 内存 | 系统报告的物理内存 | 不用默认值补齐 |
| 主层级 | macOS 版本 | 面向用户的系统产品版本，例如 27.0 | 不用 build number 替代产品版本 |
| 详情 | model identifier | 系统型号标识，例如 MacBookPro18,1；不作为主层级 | 不当作芯片名称或屏幕尺寸 |
| 详情 | build number | 系统构建事实，例如 26A5388g；不作为主层级 | 不把 build number 显示为产品版本 |
| 独立 | 固定 Wine/prefix 目标卷可用/总空间 | 与 MiPlay 固定 Wine 下载、安装和共享 prefix 相关的卷 | 不固定假设为根卷，不使用无关卷数据 |

### 6.2 设备信息状态

| 状态 | 用户文案 | 恢复动作 | 终态 |
|---|---|---|---|
| 加载中 | “正在读取此 Mac 信息” | 等待或取消 | busy 结束后进入明确结果 |
| 成功 | “此 Mac 信息已更新” | 查看字段 | 记录字段来源和读取时间 |
| 字段未知 | “{字段}未知” | 手动刷新或等待系统提供 | 不用其他字段替代 |
| 检测失败 | “无法读取{字段}” | 手动刷新；必要时导出日志 | 不用旧值、0 或空值伪装当前值 |
| 权限/目标不可用 | “无法读取目标磁盘空间” | 等待卷可用或重试检测 | 不要求无关的用户路径授权，不改变 Wine readiness |
| 过期 | “显示的是上一次已确认的{字段}，等待更新” | 刷新 | 旧值不能标记为当前实时值 |

磁盘空间必须描述 Wine 管理目标所在卷。预检查只是信息提示；真实下载/安装仍可能因空间变化失败，失败后按下载或安装恢复流处理。

## 7. 无障碍与键盘语义

Accessibility Tree 使用 Domain/ViewModel 的结构化状态投影，不从视觉状态、空白列表、动画、颜色或布局变化推断。

| 对象 | Label / Role | Value / Hint | 动态播报 |
|---|---|---|---|
| 统一 Wine | 状态对象：“统一 Wine” | 固定身份、安装状态、共享 prefix 状态、占用状态和可用动作 | 安装、prefix、失败或恢复事实改变时播报完整状态 |
| 固定 Wine 资源 | 状态对象：“统一 Wine 安装资源” | 检查、下载、校验、不可用或已验证 | 资源身份和校验终态改变时播报 |
| 共享 prefix | 状态对象：“共享运行环境” | 未准备、准备中、已准备、被占用、失败或需要恢复 | prefix 状态或占用事实改变时播报 |
| 背景组预览 | 选择项：“{组名}背景组预览” | 预览中、加载中、失败或离开恢复当前选中组 | 不把 hover 预览播报为已切换；提交成功才读“已切换到{组名}” |
| 游戏 readiness | 状态对象：“{游戏名}运行环境” | 固定 Wine、共享 prefix 和目标游戏启动前置结果 | 必须区分公共运行环境失败与游戏自身前置失败 |
| 下载任务 | 进度对象：“下载统一 Wine” | 阶段、进度或进度未知、速度或速度未知、取消状态 | 不逐次播报速度；阶段和终态变化时播报 |
| 此 Mac 硬件/系统 | 只读状态组 | 字段名、值、来源状态或未知 | 读取成功/失败时说明具体字段 |
| 磁盘空间 | 只读状态对象：“固定 Wine/prefix 目标磁盘空间” | 当前/总量或未知、读取状态 | 不把 0 或空值读作空间为零 |
| 错误恢复 | 状态对象 + 唯一动作 | 失败阶段、是否保留旧版本、恢复动作 | “当前运行时保持不变”或“当前不能继续”必须可读 |

键盘流程保持稳定：刷新、下载取消、重试、安装恢复、共享 prefix 初始化/恢复和目标游戏启动均可聚焦并使用 Return/Space；同一读取或共享 prefix 任务进行中，刷新动作保持可识别但不重复启动；固定 runtime、来源和 prefix 没有选择控件；不可用动作说明原因。切换 Game ID 后，只更新目标游戏 readiness，不能读出另一款游戏的值或产生新的 runtime/prefix。

## 8. Issue 逐条验收

| Issue | 本稿结论 |
|---|---|
| `DL-001` | §4 固定目标、阶段、进度、速度和取消字段；刷新不清空或重建状态区域，不用动态文案改变语义位置 |
| `DL-002` | §4 区分真实进度、未知进度、真实速度和未知速度；阶段和终态来自同一下载目标 |
| `DL-003` | §3.2 把托管可执行文件找不到定义为安装失败；不进入已安装、选中或 `WineReady` |
| `INFO-001` | §1、§2.2 将当前运行时定义为固定托管 Wine、唯一共享 prefix 与目标 Game ID readiness |
| `INFO-002` | §2.3、§5 区分固定 Wine 安装、共享 prefix、游戏 readiness 和刷新结果 |
| `INFO-003` | §6 分开机型名称、model identifier、芯片、macOS 产品版本和 build number |
| `INFO-004` | §6 规定目标卷空间、未知/失败/权限不可用语义，不以 0 或无关卷替代 |
| `STRUCT-001` | §3、§5 分开下载、安装、prefix、readiness、刷新和恢复 |
| `ARCH-001` | 本稿不规定实现拆分；下游保持相同状态语义并遵守既有单文件约束 |
| `I-2` | §1.1 圆点默认隐藏、hover 预览、离开恢复、预览不改变选中且不删除缓存 |
| `I-4-OVERRIDE` | §1、§2、§3 移除“全局 / 单独”Wine 作用域、版本选择和 Game ID 覆盖；统一固定 runtime 与共享 prefix |
| `I-5` | §6 “此 Mac”主层级为机型、芯片、内存、macOS 版本；未知字段不推断，详情字段不伪装主层级 |
| `R-1/R-2/R-4` | §1-§5 固定 `wine-crossover-11.0-1-signed`、共享 prefix、简化设置流程、prefix 占用/初始化失败/恢复和游戏级 readiness 隔离 |

本补充稿没有新增 Product 功能，没有把 Research 观察到的旧版路径或失败行为当作产品成功，也没有改变托管 Wine-only 边界。背景 hover 预览只定义临时媒体事实，不改变背景组持久化选择。旧 I-4 的 Wine 作用域和覆盖语义已被当前用户要求覆盖；当前 UX 只表达一个固定 runtime、一个共享 prefix 和三款游戏各自的启动前置结果。
