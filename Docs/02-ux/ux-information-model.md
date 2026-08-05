# MiPlay 信息模型

> **文档状态**：活跃（Active）
> **UX 阶段**：Information Model
> **更新日期**：2026-08-03
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

## 8. RuntimeReadiness（按 Game ID）

面向用户使用“运行环境”，技术细节可进入日志。`WineReady` 是当前 Game ID 的 readiness，不是全局机器状态；可用目录、已安装版本、当前选中版本和 readiness 必须分别表达。

| 结果 | 用户事实 | 依赖任务 |
|------|---------|---------|
| `NoSelectedRuntime` | “{游戏名}没有选中的托管运行时” | 获取或选择已安装版本 |
| `SelectedNotReady` | “{游戏名}的运行时尚未就绪” | 运行环境准备/前置校验 |
| `WineReady` | “当前运行时：{版本}；{游戏名}已就绪” | 可继续启动前置流程 |
| `RuntimeUnavailable` | “当前运行时不可用：{原因}” | 来源、资源、权限或适用性恢复 |
| `RecoveryRequired` | “运行时状态未确认，当前不能继续操作” | 先完成恢复/清理 |

`WineAcquiring` 仅是旧文档中的过程性总称，不是终态，也不是新的 Task 状态。2026-08-05 起，必须按 [ux-runtime-revision-2026-08-05.md](/Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/02-ux/ux-runtime-revision-2026-08-05.md) 分开表达下载目标、安装任务、当前选中版本和当前 Game ID 的 readiness。下载完成、文件存在、解压完成或前缀准备开始都不能单独产生 `WineReady`。

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

## 11. RuntimeSourceResult

运行环境版本发现是“来源查询结果”，不等同于下载任务或 `WineReady`。它不新增 Task.status；查询进行中由现有任务/阶段事实表示。

| 结果 | 进入条件 | 用户文案 | 恢复动作 | 是否可用于启动 |
|------|---------|---------|---------|-------------|
| `catalogLoading` | 正在读取批准来源或批准镜像 | “正在检查游戏运行环境版本” | 等待或取消查询 | 否 |
| `availableManagedVersions` | 返回有效目录，至少有 allowlist、架构和需求匹配版本 | “找到可用的托管运行环境版本” | 选择后创建下载任务 | 只有安装并验证后才可 |
| `noAvailableManagedVersion` | 来源有效，但没有可用的托管版本 | “没有可用的托管运行环境版本” | 稍后重试或等待 MiPlay 支持版本 | 否 |
| `networkFailure` | 当前选定的官方 GitHub 或预置镜像不可达、超时、限流或服务不可用 | “无法连接所选运行环境版本源” | 检查网络后重试，或主动改选其他预置来源 | 否 |
| `sourceConfigurationError`（403） | 当前选定来源拒绝访问，HTTP 403；没有取得可信目录 | “所选运行环境版本源拒绝访问（403）” | 稍后重试或改选预置来源；不要求用户提供 token | 否 |
| `sourceConfigurationError` | allowlist、URL、镜像配置或版本策略无法通过校验 | “运行环境版本源配置错误” | 更新 MiPlay 或等待修复，不要求用户改源 | 否 |
| `catalogInvalid` | 响应可达但数据格式、身份或资源映射无效 | “版本源返回的信息无法验证” | 稍后重试并保留诊断 | 否 |
| `selectedPresetMirror` | 用户明确选择了 allowlist 内的预置镜像 | “已选择{镜像}作为 Wine 版本源” | 查询该来源或改选其他批准来源 | 否 |

### 来源与镜像规则

- 只有 Product allowlist 内的批准来源和批准镜像参与 `RuntimeSourceResult`；用户可以选择预置镜像，但不能输入任意 URL。
- 官方 GitHub 或预置镜像的查询结果必须保留选定来源身份；一个来源失败不自动改写为另一个来源成功。用户主动改选来源后，才开始新的来源查询。
- 选定来源失败为该来源的 API/下载错误；配置本身无效为 `sourceConfigurationError`；有效目录为空为 `noAvailableManagedVersion`。
- 远程目录条目、下载完成、解压完成和 `wine --version` 输出都不能单独产生 `WineReady`。必须有托管身份、内容验证、安装提交、环境准备和重读验证。

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
- **Launch progress**：`label={游戏名}启动`；`value={pending/running}，{阶段}，{真实百分比或进度未知}`；不读出由视觉条或时间猜测的百分比。
- **Failure/recovery**：`label={目标}操作结果`；`value={阶段}失败，{副作用事实}，{终态}`；`hint={恢复动作}`。`recoveryRequired` 必须读出“当前不能重试”。
- **Solution**：`Applied` 必须读出“方案已应用并验证，游戏尚未启动”；`RolledBack` 必须读出“应用未成功，应用前状态已恢复并确认”。
- **Runtime source**：分别读出“没有可用版本”“无法连接版本源”“版本源配置错误”“正在下载”，不能用空列表、颜色或 spinner 推断。
