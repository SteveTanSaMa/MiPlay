# MiPlay 状态转换流

> **文档状态**：活跃（Active）
> **UX 阶段**：State Transition Flow
> **更新日期**：2026-08-03
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

## 6. 运行环境流（P0，2026-08-05 回溯口径）

运行环境结果按当前 Game ID 计算；当前运行时不是全局机器状态。可用目录、已安装版本、当前选中版本和 readiness 不得互相替代。

```text
当前 Game ID
  ├─ 没有选中的已安装版本 → NoSelectedRuntime
  ├─ 有选中版本但准备/前置校验未通过 → SelectedNotReady
  ├─ 选中版本、安装事实和当前游戏 readiness 均通过 → WineReady
  ├─ 来源、资源、权限或适用性不满足 → RuntimeUnavailable
  └─ 下载/安装/删除/取消副作用未收敛 → RecoveryRequired
```

- 下载目标和安装中目标只显示过程态；不能覆盖此前有效的当前运行时。
- `WineReady` 文案必须带版本和当前游戏事实，例如“当前运行时：{版本}；{游戏名}已就绪”。
- 可用版本目录不代表本机已安装；已安装版本不代表当前游戏已选中；选中版本不代表 readiness 通过。
- 运行环境失败阻止依赖它的启动任务，但不改变其他已就绪游戏的状态。
- 下载、安装、当前运行时和刷新/恢复的完整状态、文案与触发规则见 [ux-runtime-revision-2026-08-05.md](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/02-ux/ux-runtime-revision-2026-08-05.md)。

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

## 11. 运行环境版本源流（P0 / P1-UV-001 / P1-UV-002）

```text
设置/启动前查询批准版本源
  ↓
catalogLoading
  ├─ 有 allowlist/架构/需求匹配版本 → availableManagedVersions
  ├─ 来源有效但没有匹配版本 → noAvailableManagedVersion
  ├─ 当前选定来源不可达、超时或限流 → networkFailure
  ├─ 当前选定来源返回 403 → sourceConfigurationError（来源拒绝访问）
  ├─ allowlist/URL/镜像/版本策略无效 → sourceConfigurationError
  └─ 响应格式或资源身份无法验证 → catalogInvalid
```

### 版本源结果文案、恢复与终态

| 结果 | 文案 | 恢复动作 | 终态 |
|------|------|---------|------|
| 查询中 | “正在检查游戏运行环境版本” | 等待或取消查询 | 过程态，不是空列表 |
| 有可用目录 | “找到可用的托管运行环境版本” | 选择版本并提交下载任务 | 目录结果，不是 `WineReady` |
| 没有可用版本 | “没有可用的托管运行环境版本” | 稍后重试或等待 MiPlay 支持版本 | `noAvailableManagedVersion` |
| 网络失败 | “无法连接运行环境版本源” | 恢复网络后重试 | `networkFailure` |
| API 403 | “所选运行环境版本源拒绝访问（403）” | 稍后重试或改选预置来源；不提供 token | `sourceConfigurationError`，不是空目录 |
| 来源配置错误 | “运行环境版本源配置错误” | 更新 MiPlay 或等待修复 | `sourceConfigurationError` |
| 来源信息不可验证 | “版本源返回的信息无法验证” | 稍后重试并保留诊断 | `catalogInvalid` |
| 下载中 | “正在下载{版本}，尚未安装完成” | 等待或按任务规则取消 | WineVersionDownload `running` |
| 托管运行环境完成 | “游戏运行环境已准备好” | 继续启动 | 仅安装、持久化、环境验证全通过后为 `WineReady` |

镜像是用户可以明确选择的批准来源，不是官方 GitHub 失败后的静默回退。选定镜像失败时显示镜像错误并保留来源身份；用户改选另一个预置来源后才开始新的查询。MiPlay 不检测系统 Wine、Whisky 或 CrossOver，它们不能进入此流的可用目录，也不能将当前 Game ID 的 `NoSelectedRuntime`、`SelectedNotReady` 或 `RuntimeUnavailable` 改成 `WineReady`。

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
  ├─ Task：目标 + task status + phase + 真实 progress/未知
  └─ Error：目标 + 阶段 + 事实 + 副作用 + 终态 + recoveryAction
```

- Accessibility Tree 的状态来自结构化状态，不来自颜色、状态点、hover、透明度、Liquid Glass 或视觉进度条。
- 游戏卡片应读出“切换到{游戏名}，{选中状态}，{业务状态}，{当前动作}”；状态点不作为独立事实节点。
- 任务进行中应读出“{游戏名}{任务}，正在{阶段}，进度{真实值/未知}”；`pending` 不读成“已开始”，`completed` 必须同时读业务 outcome。
- 错误恢复应读出“{目标}在{阶段}失败，{副作用事实}，当前为{终态}，可执行{恢复动作}”。`recoveryRequired` 明确读出“当前不能重试”。
