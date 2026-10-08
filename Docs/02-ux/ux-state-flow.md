# MiPlay 状态转换流

> **文档状态**：活跃（Active）
> **UX 阶段**：State Transition Flow
> **更新日期**：2026-08-27
> **修订（I-2/I-3/I-4/I-5）**：2026-08-27 保留背景 hover 与“此 Mac”语义，覆盖旧 Wine 作用域流，冻结单一 runtime 与共享 prefix 状态流
> **继承自**：Product Domain、Product Features、Architecture Task Queue

## 1. 状态层级

MiPlay 同时维护三层事实，任何一层都不能替代另一层：

1. **任务状态**：TaskScheduler 的 `pending`、`running`、`completed`、`failed`、`cancelled`。
2. **业务状态**：Game 的 `PathUnset`、`NotInstalled`、`Installed`、`UpdateAvailable`、`GameUpdating`、`Launching`、`Running`、`LaunchFailed`；运行环境和兼容方案使用 Product 已冻结的状态。
3. **结果事实**：启动确认、完整性结果、版本比较结果、权限状态、回滚验证和 AppData 恢复结果。

“已提交”“已入队”“备份成功”“进程创建”“命令返回”“日志写入”均不是成功终态。

## 2. 统一任务流

```text
用户意图
  ↓ 接受请求
pending：已接受，尚未执行
  ↓ 调度器开始执行
running：正在执行，报告当前阶段
  ├─ 达到任务定义的成功门槛/取得可信结果 → completed
  ├─ 用户取消且清理或回滚已验证 → cancelled
  └─ 目标未达成、无法取得可信结果或清理未确认 → failed
```

### 任务状态准确文案与终态

| 状态 | 准确文案 | 恢复动作 | 终态定义 |
|------|---------|---------|---------|
| `pending` | “已提交，等待执行” | 取消或等待 | 不是成功，不表示动作已发生 |
| `running` | “正在{阶段}” | 对可取消任务请求取消 | 仍不是成功 |
| `completed` | 按结果显示“已确认{结果}” | 继续下一步 | 启动须已确认运行；校验/比较须有可信结果 |
| `failed` | “{目标}未完成：{原因}” | 按原因修复、重试或查看恢复状态 | 目标不得提升为成功 |
| `cancelled` | “已取消，清理已确认” | 重新提交新任务 | 只在清理/回滚验证完成后使用 |

`SolutionRevert` 开始后不可取消。收到取消请求时应反馈“恢复已开始，必须完成恢复验证”，继续到 `completed` 或 `failed`；不能把未完成的恢复标记为 `cancelled`。

## 3. 通用错误流

```text
前置检查
  ├─ 失败且未改变目标 → failed + 说明前置条件 + 修复/重试
  └─ 通过
       ↓
执行动作
  ├─ 未产生副作用 → failed 或 cancelled
  ├─ 产生副作用 → 后置验证
  │    ├─ 验证通过 → completed + 正向业务结果
  │    └─ 验证失败 → 自动恢复/回滚
  │         ├─ 恢复读回一致 → failed + RolledBack
  │         └─ 恢复未确认 → failed + 恢复未完成，阻止同类重试
  └─ 进程/外部对象达到成功条件 → completed + 成功结果
```

错误反馈顺序固定为：目标 → 失败阶段 → 事实 → 是否改变目标 → 当前终态 → 唯一恢复动作。原因不明时说“无法确认”，不猜测为某个兼容问题。

## 4. 路径定位与访问授权流（P0）

```text
PathUnset
  ↓ 用户提交路径
路径访问任务 pending → running
  ├─ 用户取消 → cancelled，保持 PathUnset
  ├─ 授权拒绝/授权失效 → failed，保持原业务状态
  │    └─ 重新选择路径并重新授权 → 新任务
  ├─ 路径可读但 manifest 校验失败 → IntegrityFailed/Unsupported
  └─ 路径可读且 IntegrityPassed → Installed
```

- 文案：授权拒绝为“无法访问所选游戏路径，请重新选择并允许访问”；授权失效为“所选路径的访问权限已失效，请重新选择路径”。
- 不能使用“路径已添加”表示游戏已就绪；它最多表示用户提交了路径。
- 重新选择路径会创建新的定位任务；它不自动抹除上一条可信路径，直到新路径校验结果确定。
- 路径可读但文件损坏时，不回退为权限错误；必须保留 `IntegrityFailed` 的文件事实。

## 5. 游戏启动流（P0）

```text
Installed 或 UpdateAvailable（允许启动的现有状态）
  ↓ 用户点击启动
GameLaunch task: pending
  ↓ 开始执行并发出进程请求
Game: Launching / task: running
  ├─ 前置校验失败 → task failed + 原状态不变
  ├─ 运行环境准备失败 → task failed + LaunchFailed
  ├─ 进程启动失败 → task failed + LaunchFailed
  ├─ 等待超时 → 清理残留
  │    ├─ 无残留且清理确认 → task failed + LaunchFailed
  │    └─ 残留未确认 → task failed + LaunchFailed + 禁止立即重试
  ├─ 进程确认可运行 → task completed + Running
  └─ 用户取消
       ├─ 请求尚未发出 → cancelled + 原状态不变
       └─ 请求已发出 → 停止并确认清理；未确认则 failed
```

### 启动失败语义

| 场景 | 文案 | 恢复动作 | 终态 |
|------|------|---------|------|
| 前置校验失败 | “启动前检查未通过：{文件/完整性/访问权限/运行环境}” | 修复列出的条件后重试 | task `failed`，Game 不被提升 |
| 运行环境未就绪 | “游戏运行环境未准备好，游戏尚未启动” | 准备环境；网络恢复后重试 | task `failed`，依赖环境失败 |
| 运行环境获取失败 | “游戏运行环境准备失败，未完成启动” | 恢复网络或来源后重试 | task `failed`，Game `LaunchFailed` |
| 进程启动失败 | “游戏进程未能启动” | 查看失败详情，修复后重试 | task `failed`，Game `LaunchFailed` |
| 进程超时 | “等待游戏启动超时，正在确认并清理残留” | 等待清理确认；确认后可重试 | task `failed`，不显示 `Running` |
| 进程异常退出 | “游戏进程异常退出，游戏未保持运行” | 查看退出事实或兼容方案 | task/session `failed`，Game `LaunchFailed` |
| 正常退出 | “游戏已退出” | 无需修复 | Game 回到 `Installed` |

“进程已创建”“正在启动”“任务完成”只有在对应确认事实满足时才能升级为“游戏已启动”。

## 6. 统一 Wine 与共享 prefix 状态流（P0，R-1/R-2/R-4 回溯）

当前只存在一个固定 Wine runtime：`wine-crossover-11.0-1-signed`。原神、星穹铁道、绝区零共用这一个 runtime 和一个 MiPlay 管理的共享 prefix。Game ID 只用于表达目标游戏的启动前置结果，不再绑定不同 Wine 或 prefix。

```text
进入 Wine 设置
  ↓ 读取固定 runtime、共享 prefix 和三款游戏 readiness
  ├─ NoManagedRuntime
  │    → 检查固定资源 → Downloading → ArtifactReady
  │    → Installing → Installed
  ├─ Installed + PrefixUnset
  │    → PrefixPreparing → PrefixReady
  ├─ PrefixReady
  │    → 分别读取三款游戏的游戏路径、manifest 和启动前置
  │    ├─ 通过 → 目标 Game ID = WineReady
  │    └─ 失败 → 目标 Game ID = GamePreflightFailed
  └─ 任一阶段失败、取消后清理未确认或状态不一致
       → RecoveryRequired → 恢复并重新验证
```

### 6.1 固定 runtime 安装状态

| 状态 | 用户事实 | 下一步 | 三款游戏影响 |
|---|---|---|---|
| `NoManagedRuntime` | 固定 Wine 尚未形成有效托管安装 | 获取固定 Release | 三款游戏均不能启动 |
| `Downloading` | 正在下载固定 Release | 等待或取消 | 不产生安装、prefix 或 Ready |
| `ArtifactReady` | 资源完整且校验通过，等待安装 | 提交安装 | 仍不产生安装或 Ready |
| `Installing` | 正在安装、验证 executable 或提交记录 | 等待；发生副作用后按恢复规则处理 | 三款游戏均不能报告 `WineReady` |
| `Installed` | 安装提交、身份复核和重读均通过 | 初始化共享 prefix | 不等于 prefix 或游戏就绪 |
| `InstallFailed` | 安装或验证未通过 | 清理后重试固定 Release；未收敛则恢复 | 不得使用部分安装或外部 Wine |
| `RuntimeUnavailable` | 固定资源或托管身份无法确认 | 稍后重试或等待产品修复 | 不提供来源选择或启动语义 |

### 6.2 共享 prefix 状态

| 状态 | 用户事实 | 用户动作 | 影响 |
|---|---|---|---|
| `PrefixUnset` | 固定 Wine 已安装，唯一 prefix 尚未准备 | 初始化共享 prefix | 三款游戏均未就绪 |
| `PrefixPreparing` | prefix 正在初始化、更新或验证 | 等待；不重复提交 | 三款游戏均等待 |
| `PrefixReady` | 唯一 prefix 身份、内容和准备结果通过 | 读取各游戏 readiness | 形成公共门槛，不等于三款游戏均 Ready |
| `PrefixNotReady` | 初始化、更新或验证失败 | 重试或进入恢复 | 三款游戏均不能报告 `WineReady` |
| `RecoveryRequired` | prefix 副作用或状态无法确认 | 先恢复并重读验证 | 三款游戏均不能开始新的相关任务 |

`prefixOccupancy` 是独立保护事实：`free`、`busy` 或 `unknown`。当 prefix 为 `busy` 时，状态保持在 `PrefixPreparing` 或当前已确认状态，显示“共享运行环境正在使用中”，等待当前 Wine 使用结束；不得并发初始化、重复排队、清理正在使用的内容、创建替代 prefix 或切换系统 Wine。

### 6.3 游戏 readiness 与启动失败归因

| 结果 | 进入条件 | 文案 | 影响范围 |
|---|---|---|---|
| `WineReady` | 固定 runtime 已安装、prefix 已就绪，目标游戏前置通过 | “{游戏名}可使用统一 Wine 启动” | 只允许目标 Game ID 启动 |
| `RuntimeNotReady` | 固定 runtime 或共享 prefix 未通过门槛 | “统一 Wine 或共享运行环境尚未就绪，{游戏名}暂不能启动” | 公共 runtime/prefix 失败时影响三款游戏 |
| `GamePreflightFailed` | runtime/prefix 已就绪，但目标游戏路径、manifest、兼容方案或启动前置失败 | “统一运行环境已准备，但{游戏名}启动前置未通过” | 只影响目标 Game ID |
| `RecoveryRequired` | 共享 runtime/prefix 恢复未确认 | “统一运行环境状态未确认，当前不能继续” | 三款游戏均受保护 |

启动失败时，先按失败阶段归因：Wine 下载/安装/共享 prefix 失败属于 runtime 失败；游戏路径、manifest、兼容方案或目标进程失败属于游戏自身失败。后一类不得通过新建 prefix 或切换 Wine 来恢复。

`GamePreflightFailed` 只是上述游戏自身失败的 UX 归因投影，不新增 Wine runtime 或 prefix 状态；如使用 Product 既有 `RuntimeNotReady` 枚举，应以 `failureScope=game` 与 runtime/prefix 的 `failureScope=runtime` 区分。

### 6.4 背景组 hover 预览与选择流（I-2 冻结）

```text
顶部区域无指针 → dotsHidden：圆点默认隐藏，画面为 selectedBackgroundGroupID
  ↓ 指针进入顶部区域
dotsVisible：候选圆点显示
  ↓ hover 候选组
hoverPreview(groupID)
  ├─ 资源已缓存 → 直接显示预览；不改变选择、不删除缓存
  ├─ 资源未缓存 → previewLoading(groupID)
  │    ├─ 预览资源可用 → 继续 hoverPreview(groupID)
  │    ├─ 用户取消 → 离开预览，恢复当前选中组；缓存不变
  │    └─ 加载失败 → previewFailed(groupID)；当前选中组保持
  ├─ 指针离开该圆点或顶部区域 → idle/dotsHidden；恢复当前选中组
  └─ 用户提交（点选/Return/Space） → 只有此时才可能成为持久化选择
       ├─ 目标组资源验证 + 选择写回 + 重读通过 → selected(groupID)
       └─ 验证/写回失败 → 保留上一有效选中组 + 失败事实
```

| 状态 | 用户事实 | 恢复/动作 | 终态 |
|---|---|---|---|
| `idle` | 未 hover 任何候选组；画面为持久化选中组 | 指针进入顶部区域或 hover 候选组 | 不改变选择 |
| `dotsHidden` | 圆点隐藏；当前画面为持久化选中组 | 指针进入顶部区域 | 不改变选择 |
| `dotsVisible` | 候选圆点显示 | hover 候选组或离开 | 不改变选择 |
| `hoverPreview(groupID)` | 正在预览该组 | 继续预览、离开或提交 | 离开恢复当前选中组 |
| `previewLoading(groupID)` | 未缓存，正在加载预览 | 等待或取消 | 取消不改变当前背景/缓存 |
| `previewFailed(groupID)` | 预览加载失败 | 离开 hover 或重试 | 当前选中组保持 |
| `selected(groupID)` | 用户明确提交且验证、写回、重读通过 | 后续可重新切换 | 唯一持久化选中终态 |

- `hoverPreview`、`previewLoading` 和 `previewFailed` 都不得改变 `selectedBackgroundGroupID`，不得写持久化，不得删除任何背景缓存。
- hover 预览是临时媒体事实，不改变 Game 的安装、完整性、运行或启动状态；只有用户明确提交后的 `selected(groupID)` 才写入持久化选择。
- 未缓存目标组允许发起可取消的预览加载；加载取消或失败后，画面恢复当前选中组，不进入任何持久化业务状态。
- `dotsVisible` 必须让候选组、当前选中组和 hover 中的候选组在语义上可区分；区分事实来自结构化状态，不由视觉颜色单独承载。
- 已处于 `selected(groupID)` 时 hover 另一候选组回到 `hoverPreview(otherGroupID)`；只有再次明确提交才覆盖当前选中。
- 同一候选组的预览加载未完成时，重复 hover 复用同一加载；加载成功后再次 hover 直接使用已缓存预览，不重复发起下载。

### 6.5 统一 Wine 设置任务流（替代旧 I-4 作用域）

```text
进入 Wine 设置
  ↓ 查看固定 runtime 与共享 prefix 的当前事实
  ├─ 未安装/不可确认 → 下载固定 Release → 校验 → 安装
  ├─ 已安装但 PrefixUnset/PrefixNotReady → 初始化或恢复唯一共享 prefix
  ├─ prefix busy → 等待当前使用结束，不重复发起
  ├─ runtime/prefix 已就绪 → 查看三款游戏各自 readiness
  └─ 失败、取消或副作用未收敛 → 恢复 → 重读 → 回到可确认状态
```

设置页不出现版本作用域切换、版本列表、来源选择、游戏级 Wine 覆盖、prefix 选择或当前固定 runtime 删除入口。用户只有一个明确 runtime 目标和一个明确共享 prefix 目标。

旧 `selectedWineVersion` 与 `wineVersionOverride` 只在迁移阶段读取：固定身份一致的旧记录可作为待验证证据；所有 override 都清除其产品选择含义。迁移后若无法确认固定 runtime 或共享 prefix，显示未就绪/需要恢复，不显示旧的 per-game 选择结果。

### 6.6 “此 Mac”设备信息状态流（I-5 冻结）

```text
进入通用设置“此 Mac”
  ↓ 读取系统报告
  ├─ 主层级字段（机型/芯片/内存/macOS 版本）
  │    ├─ 系统报告可确认 → fieldConfirmed：显示报告值
  │    ├─ 系统报告未提供 → fieldUnknown：显示“{字段}未知”，不推断
  │    └─ 读取失败 → fieldFailed：显示不可用，保留失败事实
  ├─ Wine 目标卷空间单独读取
  │    ├─ 可确认 → 显示当前/总量
  │    └─ 失败/目标不可用 → 不可用；不改变 Wine readiness
  └─ 手动刷新
       ├─ 新结果成功 → 替换旧值并记录读取时间
       └─ 新结果失败 → 保留上一次已确认值并标记过期
```

| 状态 | 用户事实 | 恢复动作 | 终态 |
|---|---|---|---|
| `fieldConfirmed` | 字段为系统报告值 | 查看 | 字段可读 |
| `fieldUnknown` | 系统报告未提供该字段 | 手动刷新或等待系统提供 | 不推断、不用其他字段替代 |
| `fieldFailed` | 无法读取字段 | 手动刷新；必要时导出日志 | 不用旧值、0 或空值伪装当前值 |
| `fieldStale` | 显示上一次已确认值 | 刷新 | 旧值标记为等待更新 |
| `diskSpaceUnavailable` | 无法读取 Wine 目标卷空间 | 等待卷可用或重试 | 不改变 Wine readiness |

- “此 Mac”主层级按“关于本机”表达：机型、芯片、内存、macOS 版本；model identifier 与 build number 只作为详情，不进入主层级。
- 任一主层级字段未知或失败时，只影响该字段，不从架构、model identifier、卷名或旧缓存推断；设备信息读取失败不改变 Wine 版本状态，也不允许或阻止启动。

## 7. 完整性校验流（P0）

```text
IntegrityVerification task: pending → running
  ↓ 读取 manifest
  ├─ manifest 非空且版本对应
  │    ├─ 全部条目通过 → completed + IntegrityPassed
  │    └─ 任一缺失/不匹配 → completed + IntegrityFailed
  ├─ manifest 缺失/为空/不对应/无法确认 → completed + IntegrityUnsupported
  ├─ 路径授权/I/O 阻止读取 → failed，无可信结果
  └─ 用户取消 → cancelled，保留上次可信结果
```

| 结果 | 文案 | 恢复动作 | 终态定义 |
|------|------|---------|---------|
| `IntegrityPassed` | “完整性校验通过，已确认文件与当前版本匹配” | 可继续启动 | 允许作为启动前提 |
| `IntegrityFailed` | “完整性校验未通过：发现缺失或损坏文件” | 重新选择路径，使用官方工具修复/更新，再校验 | 不得视为已就绪 |
| `IntegrityUnsupported` | “无法确认完整性：当前版本没有可用校验清单” | 稍后重试或使用受支持版本 | 永不等同通过 |
| 执行失败 | “无法读取游戏文件，完整性校验未完成” | 重新授权或重新选择路径 | task `failed` |
| 取消 | “完整性校验已取消，尚未得到新结论” | 手动重新校验 | task `cancelled` |

## 8. 兼容方案流（P0）

```text
无关联应用记录
  ↓ 用户确认 CS-01/CS-02
能力检查
  ├─ 资源/适用范围/权限不满足 → Unavailable
  └─ 满足 → Applying
       ↓ 保存应用前快照
       ↓ 执行修改
       ↓ 后置读取验证
       ├─ 通过 + 记录保存 + 快照可恢复 → Applied
       └─ 失败 → 自动回滚（不可取消）
            ├─ 读回与快照一致 → Failed + RolledBack
            └─ 未一致/无法读取 → Failed + 恢复未确认
```

### 兼容方案状态与用户动作

| 状态 | 准确文案 | 用户动作 | 终态定义 |
|------|---------|---------|---------|
| `Unavailable` | “此兼容方案当前不可应用：{资源/权限/适用范围原因}” | 重新授权或查看原因 | 不创建 `Applied` |
| `Applying` | “正在应用兼容方案，尚未验证完成” | 等待；发生修改后取消转为恢复流程 | 过程态 |
| `Applied` | “兼容方案已应用并验证通过” | 单独重新启动游戏 | 成功终态 |
| `RolledBack` | “兼容方案应用未成功，已恢复应用前状态” | 稍后重试或选择其他可用方案 | 恢复终态 |
| `Failed` | “兼容方案未应用成功：{执行/验证/恢复事实}” | 先完成恢复、重新授权或导出日志 | 失败终态，禁止伪装成功 |

特殊规则：

- CS-03、CS-04、CS-05 不在当前发布清单中，不得进入此流，也不得出现“可应用”。
- 备份成功只允许显示“原始状态已保存，正在应用”，不得显示 `Applied`。
- 用户取消若已发生修改，必须等待自动回滚；回滚完成后任务为 `cancelled`，业务结果为 `RolledBack`。
- 回滚任务开始后不能被取消；回滚失败时保留 `Failed + 恢复未确认`，不允许再次应用同一方案。

## 9. 版本检测流（P1）

```text
VersionCheck task: pending → running
  ↓ 读取本地版本 + 获取官方最新版本
  ├─ 两者均成功并完成比较 → completed + current/updateAvailable
  ├─ 网络/官方服务失败 → failed + 保留既有游戏状态
  ├─ 本地版本缺失/解析失败 → failed + 不改变游戏状态
  └─ 用户取消 → cancelled + 保留既有可信结果
```

| 场景 | 文案 | 恢复动作 | 终态 |
|------|------|---------|------|
| 已是最新 | “已确认当前为最新版本” | 继续启动 | task `completed` |
| 有新版本 | “已确认有新版本可用，MiPlay 不执行完整更新” | 使用官方更新流程或稍后处理 | task `completed`，保留 `UpdateAvailable` |
| 网络/服务失败 | “版本检测失败，未改变现有游戏状态” | 网络恢复后重试 | task `failed` |
| 本地版本不可读 | “无法读取本地版本，暂时无法判断是否需要更新” | 重新授权/重新选择路径后重试 | task `failed` |
| 重试耗尽 | “仍未获得可信版本结果，自动重试已结束” | 手动重试或稍后处理 | task `failed`，上次结果标记过期 |

检测失败不能把 `Installed` 改成“最新”，也不能清除已有可信的 `UpdateAvailable`。

## 10. AppData 恢复流（P0）

```text
读取 JSON
  ├─ 可读且结构有效 → readable → 继续初始化
  ├─ 旧格式可读 → backupCreated → migrationRequired
  │    ├─ 迁移后重新读取通过 → migratedAndVerified
  │    └─ 迁移失败 → recoveryFailed，不覆盖原文件
  └─ 损坏/不可读 → backupCreated
       ├─ 存在可读备份 → restoreAvailable
       │    ├─ 恢复后重新读取通过 → restoredAndVerified
       │    └─ 恢复失败 → recoveryFailed
       └─ 无可读备份 → recoveryFailed
            ├─ 用户重试/选择其他备份
            └─ 用户明确确认重新开始 → freshStartConfirmed
```

- 备份成功只表示原数据已保护，不能关闭恢复提示或报告应用数据已恢复。
- 恢复/迁移完成必须重新读取和验证；失败时原文件与备份均保留。
- 数据未恢复前，不确认游戏路径、方案历史、语言或运行环境选择；这些信息不得被默认值伪装成用户原设置。
- “重新开始”是明确的高损失终态：文案必须说明本地配置和历史可能丢失，不能静默触发。

## 11. 固定 runtime 获取与共享 prefix 验证流（P0 / R-1/R-2/R-4）

```text
检查固定 Release wine-crossover-11.0-1-signed
  ├─ 资源不可达/身份无法确认 → RuntimeUnavailable
  ├─ 用户取消且清理确认 → cancelled；此前有效事实保持
  └─ 资源身份和内容通过 → Downloading → ArtifactReady
       ├─ 内容校验失败 → DownloadFailed；不能安装
       └─ 安装、executable 验证、提交和重读
            ├─ 失败且无副作用 → InstallFailed
            ├─ 失败且副作用未收敛 → RecoveryRequired
            └─ 成功 → Installed
                 → PrefixUnset/PrefixPreparing
                      ├─ prefix busy → 等待释放，不重复初始化
                      ├─ 初始化/验证失败 → PrefixNotReady
                      ├─ 副作用未确认 → RecoveryRequired
                      └─ 验证通过 → PrefixReady
                           → 分别读取三款游戏 readiness
```

| 阶段/结果 | 用户文案 | 下一步 | 不得推断 |
|---|---|---|---|
| 检查中 | “正在检查统一 Wine” | 等待或取消 | 不是未安装或已安装结论 |
| 下载中 | “正在下载统一 Wine” | 查看真实进度或取消 | 不产生安装、prefix 或 Ready |
| 资源已验证 | “统一 Wine 安装资源已验证” | 提交安装 | 不表示托管安装完成 |
| 安装中 | “正在安装统一 Wine” | 等待或按恢复规则处理 | 不表示安装成功 |
| 安装完成 | “统一 Wine 已安装，共享运行环境尚未准备” | 初始化共享 prefix | 不表示任何游戏 Ready |
| prefix 占用 | “共享运行环境正在使用中” | 等待当前使用结束 | 不表示失败，不创建替代 prefix |
| prefix 初始化失败 | “共享运行环境准备失败，三款游戏暂不能启动” | 重试或恢复 | 不切换 runtime，不按游戏创建 prefix |
| prefix 已验证 | “共享运行环境已准备” | 分别检查目标游戏 | 不表示三款游戏均 Ready |
| 游戏前置失败 | “统一运行环境已准备，但{游戏名}启动前置未通过” | 修复目标游戏前置 | 不改变其他游戏 readiness |
| 状态未确认 | “统一运行环境状态未确认，当前不能继续” | 先完成恢复 | 不提供启动语义 |

下载完成不是安装完成；安装完成不是 prefix 就绪；prefix 就绪不是三款游戏全部 Ready。任何失败都不得 fallback 到系统 Wine、Whisky、CrossOver 或外部 prefix。

## 12. 本地版本与完整性证据流（P0/P1 / P1-UV-003）

```text
读取 pkg_version / config.ini / IntegrityManifest
  ↓ 记录各自来源和解析结果
  ├─ manifest 有效且全条目通过 → IntegrityPassed
  ├─ manifest 缺失/为空/不对应 → IntegrityUnsupported
  ├─ manifest 条目缺失/不匹配 → IntegrityFailed
  ├─ pkg_version、config.ini、manifest 或远程版本冲突 → 无法确认
  └─ 本地/远程版本证据均可信 → VersionCheck completed + current/updateAvailable
```

- `pkg_version` 只有在目标游戏和安装位置关联通过后才是本地版本候选；不能单独证明完整性。
- `config.ini` 只提供渠道/来源/配置元数据候选；不能替代 manifest 或官方最新版本。
- 任何来源缺失、格式未知或相互冲突时，文案为“无法确认当前版本/完整性”；不得发布 `current`、`IntegrityPassed` 或 `Running`。
- 完整性通过仍要求非空、版本对应 manifest 的所有条目通过；文件存在、版本字段或关键 exe 存在都不构成通过。

## 13. 重启状态恢复流（P1-REV-003）

```text
应用启动
  ↓ 扫描持久 Game 状态和可信活动进程
  ├─ Running + 活动进程存在 → Running
  ├─ Running + 无活动进程 → recoveryRequired
  │    ├─ 提交目标终态/清除恢复记录并重读通过 → recoveryCommitted
  │    └─ 提交失败 → failed + recoveryRequired，保留保护
  └─ 非 Running → 按已有可信状态继续
```

- `Running` 且无进程时文案为“上次游戏状态未完成同步，正在恢复”；不得直接显示“游戏已退出”或提供新的启动重试。
- 恢复只确认进程已退出、提交预期终态并重读验证，不自动重启游戏。
- AppData 与恢复记录同时不可写时，用户看到“游戏状态恢复未完成，暂时不能启动”；应用重启不能把持久 `Running` 静默改成 `Installed`。
- 恢复提交成功后，用户重新启动才创建新的 UserIntent/Task；旧任务的失败/恢复事实保留。

## 14. stale bookmark 访问流（P1-REV-004）

```text
保存的 GameLocation
  ↓ resolve + startAccessing
  ├─ fresh → 消费者操作
  ├─ stale → 在有效 scope 内刷新候选
  │    ├─ 写回 + 重读验证成功 → 消费者操作 → 发布消费者结果
  │    └─ 写回失败 → failed + recoveryRequired
  └─ access denied → failed + 要求重新授权/选择路径
```

- stale 刷新期间文案为“正在刷新游戏路径授权”；不是“路径有效”或“校验中已完成”。
- 刷新候选只在 PersistenceStore 写回并重读成功后成为授权事实；写回失败时旧记录保留 stale，不回退裸 path 或 `lastKnownPath`。
- `GameRegistry`、`FileIntegrityVerifier`、`VersionChecker`、`PreLaunchValidator`、`LaunchOrchestrator` 均须遵守此门槛。
- 写回失败文案为“路径授权已刷新但尚未保存，本次操作未完成”；不得发布 `IntegrityPassed`、版本 `current/updateAvailable`、`Installed` 或 `Running`。

## 15. Accessibility 状态投影流（P1-UV-006）

```text
Domain/ViewModel 状态快照
  ↓ 生成 AccessibilityProjection
  ├─ Game card：对象 + 动作 + 选中态 + 业务态 + 当前动作
  ├─ Unified Wine：固定 runtime + 共享 prefix + 占用 + 任务阶段
  ├─ Game readiness：目标游戏 + runtime/prefix 前置 + 游戏自身前置
  ├─ Task：目标 + task status + phase + 真实 progress/未知
  └─ Error：目标 + 阶段 + 事实 + 副作用 + 终态 + recoveryAction
```

- Accessibility Tree 的状态来自结构化状态，不来自颜色、状态点、hover、透明度、Liquid Glass 或视觉进度条。
- 游戏卡片应读出“切换到{游戏名}，{选中状态}，{业务状态}，{当前动作}”；状态点不作为独立事实节点。
- Wine 任务进行中应读出“统一 Wine，正在{阶段}，目标为共享 prefix，进度{真实值/未知}”；`pending` 不读成“已开始”，`completed` 必须同时读业务 outcome。
- 游戏 readiness 必须分别读出“统一 Wine/共享 prefix {状态}”和“{游戏名}自身前置 {状态}”；不能把 Wine 已安装读成三款游戏均已就绪。
- 错误恢复应读出“{目标}在{阶段}失败，{副作用事实}，当前为{终态}，可执行{恢复动作}”。`recoveryRequired` 明确读出“当前不能重试”。
- 固定 runtime 获取只读出“正在检查/下载/验证/安装统一 Wine”；共享 prefix 只读出“未准备/准备中/已准备/被占用/失败/需要恢复”，不出现版本或来源选择。
