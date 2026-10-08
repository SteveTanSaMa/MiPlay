# MiPlay UI 回溯：统一 Wine runtime 与共享 prefix

日期：2026-08-28
责任阶段：UI Agent
回溯问题：`R-4`，承接 `I-4-OVERRIDE`

> **当前状态**：Product/Research 回溯后的 UI 输入稿。
> **硬约束**：三款游戏统一使用 `wine-crossover-11.0-1-signed`，共用一个 MiPlay 管理的 Wine runtime 和一个共享 prefix。
> **替代关系**：此前 I-4 的“全局 / 单独 Wine 版本”设计在 2026-08-27 已被用户新要求覆盖；本文件不再把旧选择模型作为实现输入。
> **范围**：只规定 UI 结构、状态投影、稳定布局和可访问性；不修改 Swift、Domain、Architecture、Persistence 或 Wine 下载逻辑。

## 1. 范围与边界

本次 UI 修改依据以下当前上游产出：

- `Docs/00-product/product-features.md`
- `Docs/00-product/product-runtime-revision-2026-08-05.md`
- `Docs/01-research/research-wine-shared-prefix-2026-08-27.md`

本次只修改设置窗口 UI 文档，不改变 Domain、Infrastructure、Persistence、下载状态来源或 Wine 安装逻辑。UI 不把下载完成、文件存在、解压目录存在或进度达到 100% 显示为安装成功、共享 prefix 就绪或 `WineReady`。

涉及源码：

- `MiPlay/UI/SettingsWindow/SettingsWineView.swift`
- `MiPlay/UI/SettingsWindow/SettingsAppViews.swift`
- `MiPlay/UI/SettingsWindow/SettingsWindowScene.swift`（固定列宽和相对主窗口定位已由前序 UI 修改保留）

## 2. 上游事实与 UI 边界

### 2.1 固定 runtime 与共享 prefix

当前 UI 只允许表达以下事实：

1. 固定 runtime 身份为 `wine-crossover-11.0-1-signed`。
2. 三款游戏共用同一个固定 runtime。
3. 三款游戏共用同一个 MiPlay 管理的共享 prefix。
4. 来源由产品固定和管理；用户不选择来源、镜像、URL 或外部路径。
5. 用户不选择 Wine 版本，不为游戏设置 Wine 覆盖，不删除固定 runtime 或共享 prefix。
6. 下载、安装、共享 prefix 准备和目标游戏启动前置验证是不同事实，不能互相替代。

Research 已确认共享 prefix 会进入三款游戏共同面对的 Wine 状态，但资源锁、并发限制和恢复协议仍由 Architecture/Implementation 冻结。UI 只显示这些上游状态的结构化投影。

### 2.2 稳定布局决策

| 实验 | 观察 | 决策 |
|---|---|---|
| A：动态阶段、字节量、速度和错误切换 | 同一任务的字段变化可能重建条件视图 | 固定单一任务区域和字段位置 |
| B：固定 runtime 身份始终不变 | 不存在多个版本行或操作列切换 | runtime 身份只读显示，不创建版本列表 |
| C：下载、安装、prefix 准备和恢复切换 | 各阶段高度不同会导致设置页抽动 | 所有阶段复用同一 `122pt` 任务区域 |
| D：三款游戏共用事实 | 单款游戏 readiness 不能替代公共 prefix 状态 | 共用 runtime/prefix 用只读结构表达，游戏启动前置另行投影 |
| E：高频进度更新 | 默认事务可能触发布局动画 | 任务区域关闭局部隐式布局动画；状态值继续更新 |

旧截图的窗口像素尺寸为 `800 × 480`（包括标题栏），只能作为窗口边界和旧任务区的历史证据，不能证明新的固定 runtime 页面已实现。

## 3. 稳定布局契约

| 区域/字段 | 稳定约束 | 动态内容规则 |
|---|---:|---|
| Settings 窗口 | `800 × 448pt` 内容尺寸 | 打开时相对主窗口中心定位，重新打开重新计算 |
| Sidebar | `min/ideal/max = 240pt` | 分隔线不可拖动到消失 |
| Detail | `min/ideal/max = 560pt` | 内容在 Detail 内滚动，不改变列宽 |
| 固定 runtime 行 | min `42pt` | 固定身份不换行；状态值尾部截断 |
| 共享 prefix 行 | min `42pt` | 状态值尾部截断；不显示路径 |
| 三款游戏共用行 | min `42pt` | 固定三款游戏事实，不出现选择控件 |
| 当前任务区域 | `122pt` | idle、下载、安装、prefix 准备、失败、取消、恢复共用区域 |
| 进度指示器 | `220 × 16pt` | 真实估算用确定进度，否则显示 indeterminate |
| 目标/状态行 | `20pt` 高，状态列 `72pt` | 固定目标 `wine-crossover-11.0-1-signed`，状态只更新值 |
| 阶段行 | `22pt` 高 | 阶段值最多一行，尾部截断；不创建新行 |
| 传输行 | `18pt` 高，速度列 `84pt` | 真实字节/速度显示真实值，否则显示未知占位 |
| 任务动作槽 | 固定位置 | 下载并安装、重试、取消最多显示一个，由上游 action 决定 |

动态文案不会以硬编码的最长字符串作为唯一依据；固定身份、单行截断、未知占位和稳定任务区域共同保证窗口不跳动。Liquid Glass 材料和设置窗口导航契约保持不变。

## 4. UI 状态映射

| 上游事实 | UI 主区域 | 可见动作/限制 |
|---|---|---|
| `NoManagedRuntime` | 固定 runtime 身份 + 未安装托管状态；共享 prefix 未就绪 | 单一“下载并安装”入口；不显示版本选择 |
| `Downloading` | 固定目标 + 下载阶段 + 真实进度/未知进度 | 按任务能力显示取消；不显示已安装或 `WineReady` |
| `ArtifactReady` | 固定目标 + 资源已校验，等待安装 | 等待安装提交；不显示已安装或 `WineReady` |
| `Installing` | 固定目标 + 安装阶段 | 保持任务区域稳定；不显示安装完成 |
| `Installed` | 固定 runtime 已安装 | 进入共享 prefix 准备；不显示 prefix 已就绪 |
| `PrefixPreparing` | 固定 runtime + 共享 prefix 准备中 | 三款游戏均不显示完整 `WineReady` |
| `PrefixReady` | 固定 runtime 已安装 + 共享 prefix 已准备 | 允许各游戏分别进行启动前置验证；不推断三款均通过 |
| `RuntimeNotReady` | 共享环境或目标启动前置未就绪，并显示具体事实 | 由上游 action 提供重试/修复；不显示成功 |
| `WineReady` | 固定 runtime、共享 prefix 与当前目标游戏启动前置均通过 | 仅表达当前目标游戏可进入启动流程 |
| `InstallFailed` / `RuntimeUnavailable` | 失败类别、固定目标和此前有效事实 | 只显示上游提供的单一重试或恢复动作 |
| `Cancelled` | 取消事实与清理结果 | 不覆盖此前有效 runtime/prefix；可重新提交同一固定目标 |
| `RecoveryRequired` | 恢复/清理未确认；固定 runtime/prefix 状态受保护 | 阻止新的下载、安装或启动；只显示恢复动作 |
| `Upgrading` / `UpgradeFailed` | 受控升级阶段或失败事实 | 不显示版本选择；失败时保留旧有效事实或进入恢复 |

### 4.1 共享状态与游戏状态边界

- `PrefixReady` 是公共环境状态，不等于三款游戏均为 `WineReady`。
- 某一游戏启动前置失败时，只在该游戏上下文显示失败，不创建新的 runtime 或 prefix，也不改变另外两款游戏的 Wine/prefix 身份。
- 共享 prefix 失效、恢复未完成或公共任务进行中时，三款游戏都必须看到公共环境未就绪事实；UI 不将某一游戏的旧成功显示为共享环境当前成功。

## 5. Accessibility 与交互

| 对象 | Role/Label | Value | 约束 |
|---|---|---|---|
| 统一 Wine 状态组 | `统一 Wine 运行环境` | 固定 runtime、共享 prefix、公共任务事实 | 只读，不表达三款游戏均已启动验证 |
| 固定 runtime 行 | `托管 Wine runtime` | `wine-crossover-11.0-1-signed` + 安装状态 | 不可选择、删除或替换 |
| 共享 prefix 行 | `共享 Wine prefix` | 准备、就绪、失败或恢复事实 | 不读出路径，不按游戏拆分 |
| 三款游戏共用行 | `共用运行环境的游戏` | 原神、星穹铁道、绝区零共用同一 runtime/prefix | 不提供激活动作 |
| 任务状态组 | `统一 Wine 任务` | 目标、阶段、进度/未知进度、传输和终态 | 高频速度不逐次播报 |
| 任务动作 | `下载并安装` / `重试` / `取消` | 当前唯一可执行动作 | 由上游 action 决定，UI 不自行推断 |

键盘与 VoiceOver 激活结果必须与鼠标一致。任务进行中保持相同焦点顺序；安装中、恢复中和不可用状态不制造版本行或删除按钮。共享 prefix 的公共状态变化可以播报，但不得把它播报为三款游戏的 `WineReady`。

## 6. 与其他 UI 结构的关系

本次回溯只替换 Wine 页面，不改变此前已冻结的 I-2 背景圆点和 I-5 “此 Mac”结构：

- I-2 背景圆点仍按现有 UI 文档的隐藏、顶部悬停区、位置和 hover 反馈规格执行。
- I-5 “此 Mac”仍为机型、芯片、内存、macOS 版本四行只读信息；未知或失败时不推断。
- “此 Mac”与固定 Wine/shared prefix 状态分开，不用设备信息推断 runtime/prefix readiness。

## 7. 验证记录

### 7.1 文档检查

- [x] 固定 runtime 身份为 `wine-crossover-11.0-1-signed`。
- [x] 明确三款游戏共用一个 runtime 和一个 prefix。
- [x] 移除 Wine 作用范围、版本选择、来源选择、按游戏 Wine 覆盖和固定 runtime 删除入口。
- [x] 统一下载、安装、重试入口，取消只作为同一任务槽中的上游动作。
- [x] 失败、下载中、安装中和恢复中共用稳定任务区域。
- [x] 明确共享 runtime/prefix 就绪不等于三款游戏均通过启动前置验证。

### 7.2 运行验证边界

现有 `validation-artifacts/settings-wine-*.jpg` 截图来自旧多版本 Wine 页面，只能证明旧窗口尺寸和旧任务区的历史边界，不能证明本稿的新 UI 结构。新结构尚未有运行截图，因为本 UI Agent 不修改 Swift 实现。

新结构需要由 Implementation/Review/QA 验证：

1. Settings 在 `800 × 448pt` 内容尺寸下无重叠、无版本列表和无按游戏 Wine 控件。
2. 固定 runtime、共享 prefix、三款游戏共用说明和单一任务入口在下载、安装、失败、取消、恢复状态下保持布局稳定。
3. 共享 prefix 已就绪时，UI 不把三款游戏全部标记为 `WineReady`；目标游戏 readiness 仍独立投影。
4. 旧 schema 迁移或新状态读取失败时，UI 不恢复“全局 / 单独”选择，不恢复旧版本列表，也不恢复删除固定 runtime 的路径。

## 8. 交接

- Product/Research：固定 runtime 与共享 prefix 事实已作为本稿输入。
- UX：需基于本稿重跑 Wine 用户流程、状态文案和失败恢复流程，不能沿用 I-4 作用范围流程。
- Architecture：需冻结共享 prefix 生命周期、资源锁、并发和恢复契约；UI 不代替这些定义。
- Implementation：按本稿重构 SettingsWineView 的 UI 投影；不得新增 UI 层业务判断或持久化字段。
- Review/Performance/QA/Release：使用新的统一 runtime/prefix 验收矩阵，不引用旧多版本截图作为通过证据。
