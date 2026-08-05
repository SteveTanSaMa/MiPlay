# MiPlay UI Revision（2026-08-03）

> **文档状态**：UI Revision 冻结稿（供 Implementation 使用）
> **任务**：Task 4 — UI Agent
> **角色**：UI Agent
> **范围**：主窗口、Settings 窗口、多背景组入口、游戏 metadata、兼容性方案、性能选项和 Accessibility 结构
> **约束**：只定义 UI 结构、区域、层级、语义和验证要求；不修改 SwiftUI、ViewModel、Domain 状态模型或导航契约
> **上游依据**：`Docs/02-ux/ux-revision-2026-08-03.md`、`Docs/02-ux/ux-information-model.md`、`Docs/02-ux/ux-state-flow.md`、`Docs/01-research/research-revision-2026-08-03.md`
> **修订优先级**：本稿优先于同目录旧的尺寸、Settings 分栏和背景入口描述；旧文档中的基础视图职责仍然有效，冲突处以本稿为准。

## 1. Revision 边界

本稿解决以下用户验证问题：

| 问题 | UI 决定 | 不解决的内容 |
|---|---|---|
| 主按钮太小 | 主按钮稳定为 `220 × 64pt`，状态文案不改变外层尺寸 | 不在 View 内判断业务状态或任务动作 |
| 游戏图标过近 | Button 命中框 `64 × 64pt`，游戏间距 `12pt`，玻璃内容 `56 × 56pt` | 不改变 Game 状态模型 |
| 状态点被按钮层遮挡 | 状态点作为 Button label 内的独立渲染层，位于玻璃和 glyph 之后，使用外层稳定坐标 | 不从颜色推导业务状态 |
| hover 与 Liquid Glass 融合 | hover/selected 只变换 glyph，不变换玻璃材质和 hit frame；保留实验矩阵 | 不用透明手势层补救 hit testing |
| Settings sidebar 可消失 | Sidebar `240pt`、Detail `560pt`，强制显示且不提供可拖动/折叠路径 | 不改变独立 Settings Scene 和 `⌘,` 入口 |
| Settings 内容不完整 | 明确通用、Wine、三款 per-game 和关于层级；每个游戏拥有 metadata、方案、性能和背景组入口 | 不把 Deferred 高级配置伪装为可执行功能 |
| 背景组切换位置不明确 | 仅多背景时在主窗口顶部水平居中显示圆点；目标组失败保留上一有效组 | 不把媒体加载状态写成 Game 成功状态 |

本稿使用 UX 已冻结的业务事实：三款游戏按 Game ID 独立保存配置和背景组；TaskScheduler 仍只有 `pending`、`running`、`completed`、`failed`、`cancelled`；`unavailable`、`deferred`、`recoveryRequired` 和媒体结果只是 UI 投影，不是新 Task 状态。

## 2. 窗口与区域总览

### 2.1 MainWindow

| 区域 | 位置 | 固定结构 | 可见条件 |
|---|---|---|---|
| BackgroundLayer | 全窗口 | `1280 × 688pt`，当前 Game ID 的背景组 | 始终存在；无有效素材时使用非交互降级背景 |
| BackgroundGroupControl | 顶部水平中心 | 有效背景组的选择 Button 集合 | 仅当前游戏有多于 1 个有效背景组时显示 |
| GameSelectionRail | 左下角 | 3 个 Game Button，固定顺序 | 始终显示 |
| SettingsEntry | Game Rail 下方 | 1 个标准 Settings Button | 始终显示 |
| PrimaryActionRegion | 右下角 | `220 × 64pt` 主按钮 + 独立任务反馈区 | 始终显示；反馈按状态出现 |
| Loading/RecoveryOverlay | 当前窗口上层 | 只覆盖确实被阻断的区域 | 仅在媒体加载或恢复事实要求时显示 |

MainWindow 不新增中心信息卡、Rail 背景容器或第二个主操作按钮。背景是装饰层，不能承载游戏状态、版本结论、任务成功或失败语义。

### 2.2 Settings

Settings 保持独立 `Settings` Scene、`800 × 448pt`、单实例和现有 `⌘,` 入口。内容区固定为：

```text
Settings Window (800 × 448pt)
├── Sidebar (240pt, always visible, non-collapsible)
│   ├── 通用
│   ├── Wine 运行环境
│   ├── 原神
│   ├── 崩坏：星穹铁道
│   ├── 绝区零
│   └── 关于
└── Detail (560pt, remaining fixed width, independently scrollable)
```

- Sidebar 和 Detail 的宽度是结构约束，不是用户可调整的偏好。
- 不提供 sidebar toggle、隐藏 sidebar 的 toolbar action 或可拖至 `0pt` 的分隔线。
- 分隔区域只表达列边界，不是交互控件；不得获得键盘焦点或 VoiceOver 节点。
- 窗口保持 `.contentSize` 约束，Detail 内部内容通过滚动承载，不通过缩小 sidebar 解决溢出。
- 若 `NavigationSplitView` 的默认行为仍允许折叠或将 sidebar 拖至不可见，Implementation 必须使用等价的固定双列容器，但保持相同的 Settings Scene、Pane 顺序和 `⌘,` 契约。

## 3. MainWindow 结构

### 3.1 背景层与多背景组

背景组是一个完整媒体单元，包含同一组的图片、视频、theme/装饰素材、版本和来源身份。UI 只呈现当前 Game ID 提供的结构化背景组状态。

| 有效组数量 | 顶部控制 | 背景呈现 |
|---:|---|---|
| 0 | 不显示圆点；显示“当前没有可用背景组”状态 | 使用降级背景；不阻断不相关操作 |
| 1 | 不显示圆点，也不制造单项焦点 | 直接呈现唯一有效组 |
| 多于 1 | 在主窗口顶部水平居中显示对应数量的选择 Button | 使用当前已验证组；选择目标组后异步加载 |

背景组圆点要求：

- 只有有效组进入选择集合；无效、未验证或不适用的组不能生成可点击圆点。
- 圆点的数量与有效组数量一一对应，顺序稳定，当前选中状态可见。
- 每个圆点是标准 Button 的视觉内容，具有稳定的键盘命中区域；圆点本身不单独承载业务逻辑。
- 点选、VoiceOver 激活、方向键移动和 Return/Space 提交都调用同一背景组选择动作。
- 目标组加载时保留上一有效组，不清空背景、不显示“已切换”。
- 目标组的图片、视频和 theme 全部达到可用门槛并完成选择持久化、写回和重读后，才显示“已切换到{组名}背景组”。
- 目标组失败时显示“无法使用{组名}背景组，已保留上一组”，提供重试目标组或继续上一组；不静默切换到其他组。
- 背景组失败、加载或切换结果不改变游戏的安装、完整性、运行或启动成功状态。

背景层节点关系：

```text
BackgroundRegion
├── CurrentBackgroundGroup [decorative media, accessibilityHidden]
├── BackgroundFallback [decorative, accessibilityHidden]
└── BackgroundGroupControl [only when valid group count > 1]
    └── BackgroundGroupButton × validGroupCount
```

### 3.2 GameSelectionRail

```text
GameSelectionRail (fixed width >= 76pt)
├── GameIconButton × 3
│   └── Button label
│       ├── GlassPanel (56 × 56pt)
│       ├── Glyph
│       └── StatusDot (independent overlay, above GlassPanel)
└── SettingsButton (top separation 16pt)
```

几何和渲染约束：

- 每个游戏 Button 的稳定命中框为 `64 × 64pt`，游戏之间 `12pt` 固定间距。
- 玻璃面板固定 `56 × 56pt`，圆角保持现有 Liquid Glass 结构；玻璃层不得随 hover/selected 缩放。
- 状态点不放在会被玻璃重新合成的底层。渲染顺序为：Button hit frame → GlassPanel → Glyph → StatusDot → 非遮挡 focus 反馈。
- 状态点使用外层 Button label 的稳定坐标、独立 z-order 和不裁切的 overlay；必须完整可见，不覆盖 glyph 的主要识别区域，不被 GlassPanel 遮挡。
- 状态点使用 `allowsHitTesting(false)`，不创建第二个交互对象；状态事实由 Button 的 value 和详情文本提供。
- selected 最大 `1.08`、hover 最大 `1.04`，只应用于 glyph/非材质内容；不得对包含 `.glassEffect` 的整体施加 scale。
- hover 不改变 Button hit frame、布局尺寸、状态点位置或键盘 focus 边界。
- Settings Button 使用相同的稳定 `64 × 64pt` hit frame 和固定 `56 × 56pt` 玻璃内容，顶部与最后一个游戏 Button 保持 `16pt` 分隔。
- 游戏、Settings 和背景组控制均使用标准 Button；不得以 `onTapGesture` 作为入口动作。

### 3.3 PrimaryActionRegion

主按钮固定为 `220 × 64pt` 最小稳定区域，位于右下角。任务反馈位于同一主操作上下文中，但不能通过改变按钮 label、ProgressView 或错误文案改变按钮外层尺寸。

| 上游状态/事实 | 主按钮结构 | 同步反馈 |
|---|---|---|
| `PathUnset` / `NotInstalled` | `Locate Game` | 路径选择、授权、完整性结果在反馈区显示 |
| `Installed` | `Launch` | 启动前置检查、Wine 准备、进程确认 |
| `UpdateAvailable` | `Update` | 版本提示和官方更新边界 |
| `LaunchFailed` | `View Fixes` | 失败阶段、原因、兼容方案/性能入口 |
| `pending` / `running` | 当前任务文案，按真实状态 disabled 或提供任务动作 | 阶段、真实进度/不定进度、Cancel |
| `failed` | 当前唯一有效恢复动作 | 原因、终态、Retry/Choose Again/Reauthorize |
| `cancelled` | 重新提交当前允许动作 | 清理或回滚是否已确认 |
| `completed` | 具体 outcome 的下一步动作 | 不显示泛化“成功” |

`Running`、`WineReady`、`Applied`、文件存在、请求返回或进度达到 100% 都不能单独生成“游戏已启动”或“操作成功”。UI 只消费调用方提供的 action、enabled、phase、progress、error、recovery 和 outcome。

## 4. Settings 结构

### 4.1 通用 Pane

通用 Pane 只承载应用级事实，不放任何游戏的路径、`config.ini`、背景组或高级配置。

| Section | 内容 | 结构要求 |
|---|---|---|
| 应用 | 应用语言、更新与版本通知 | 使用系统 Picker/Toggle；保存失败保留原值并显示恢复动作 |
| AppData | 读取、备份、迁移、恢复或重新开始 | 状态、备份时间和当前可用动作分开；不把发现备份显示为已恢复 |
| 日志 | 查看/导出日志 | 导出任务的 pending/running/completed/failed 独立显示 |

### 4.2 Wine 运行环境 Pane

Wine Pane 只显示 MiPlay 托管 Wine：默认官方 GitHub，用户可主动选择预置可信镜像。不得显示系统 Wine、Whisky 或 CrossOver 的检测/导入入口。

| Section | 内容 | 必须区分 |
|---|---|---|
| 当前运行时 | 当前托管版本、架构、来源身份、就绪事实 | 已安装、已验证、`WineReady` 不混为一项 |
| 版本源 | 官方 GitHub / 已批准镜像选择 | 当前选定来源、查询中、403、网络失败、配置错误 |
| 可用版本 | 版本目录、版本、架构、来源、可下载/已安装 | 空目录不等于网络失败；目录成功不等于已就绪 |
| 下载与安装 | pending/running、真实阶段、可估算进度、取消、失败恢复 | 下载完成、内容校验、安装持久化、重读验证分开呈现 |

### 4.3 Per-game Pane

三款游戏分别有独立 Sidebar item 和独立 Detail 目标。切换 Pane 不共享、继承或合并另一款游戏的路径、metadata、方案、性能选项、背景组或高级配置。

每个游戏 Pane 使用单一可滚动 Detail，按以下稳定顺序组织 Section；不使用卡片套卡片：

```text
Game Pane ({Game ID})
├── 基本信息与当前状态
├── 路径与权限
├── Metadata 与证据
├── 完整性与版本
├── 兼容性方案入口
├── 性能选项入口
├── 高级配置（A-01 至 A-06）
└── 背景组
```

#### 基本信息与当前状态

- 显示中文名和 English name；名称来自固定 Game 注册信息，不从 `config.ini` 推断。
- 显示 Game ID、路径状态、最近可信版本、最近可信完整性结果、最近一次启动事实和当前业务状态。
- `Installed`、`Running`、`LaunchFailed`、`IntegrityFailed`、`IntegrityUnsupported`、`recoveryRequired` 等事实分开呈现。
- 缺少该游戏路径或 metadata 时保留该 Pane，显示该 Game ID 自己的空/不可用状态，不借用其他游戏结果。

#### 路径与权限

- 提供标准“选择游戏”“重新授权”“重新选择”入口，动作目标必须绑定当前 Game ID。
- stale bookmark 刷新、写回和重读状态在本 Section 显示；写回失败不得发布新的完整性、版本或启动结论。
- 权限失败、取消和清理/回滚状态使用事实文案，不把选择了路径显示成已接入。

#### Metadata 与证据

Metadata 以可复制的原始 Section/Key/Value 行显示，每组旁边提供来源、读取时间和可确认性。

| 显示组 | 必须显示 | 语义边界 |
|---|---|---|
| `config.ini` | 原始 section/key/value，包括 `game_version`、`channel`、`cps`、`sub_channel`、`sdk_version`（存在时） | 只作为配置/版本候选；不单独证明完整性或渠道友好名称 |
| `pkg_version` | 原始版本字段及其读取/校验结果 | 只有格式、目标关联和内容校验可信时才作为版本候选；不替代 manifest |
| manifest | manifest 身份、版本对应关系、条目校验结果 | 非空且全部必需条目通过才可显示 `IntegrityPassed` |
| 官方版本 | 当前本地候选、官方版本来源和比较结果 | 远程版本不能替代本地证据 |
| 未知字段 | 原始 key/value | 不改名、不补默认值、不推断 `wpf_version` 语义 |

#### 兼容性方案与性能选项入口

- 兼容性方案和性能选项必须在每个 Game Pane 中有可见、可聚焦的入口行，入口显示当前目标 Game ID。
- 入口激活调用现有 Game Detail/任务入口，并分别选中 `Compatibility` 或 `Performance` 页面；不得在通用 Settings 中复制另一套业务流程。
- 兼容性方案入口显示可用方案数量、当前 `Applied`/`RolledBack`/`Failed`/`Unavailable` 事实和当前恢复动作；`Applied` 明确说明游戏尚未启动。
- 性能选项入口显示该游戏自己的选项数量和读取状态。选项不可用或 Deferred 时显示原因和适用范围，不显示 Toggle、可提交表单或“已启用”。
- 方案或性能任务发生副作用后，失败、回滚、权限不足和恢复未确认仍返回同一 Game ID 上下文；不得把恢复动作移到全局 Pane。

#### 六项高级配置

A-01 至 A-06 在每个 Game Pane 中显示为状态行。UI 只显示 UX/发布清单提供的适用范围、Deferred、Unavailable 或已验证事实：

- Deferred：显示名称、目标、当前版本未实现；无 Toggle、Apply、成功任务或“已启用”。
- Unavailable：显示不适用于此游戏、版本、资源或权限的原因；无可执行动作，除非上游提供明确恢复动作。
- 可用：只有上游提供实际 action、enabled 和验证状态时才呈现可操作控件。

#### 背景组 Section

- 只读写当前 Game ID 的背景组选择，不与主窗口或其他游戏共享选择状态。
- 一组有效背景时显示当前组事实但不显示单项圆点；多组时显示组名/版本和当前选择，激活后复用主窗口的加载、验证、提交和失败保留上一组语义。
- 背景组失败不改变 Game 安装、完整性或运行状态，也不阻断兼容方案、性能选项或路径操作。

### 4.4 关于 Pane

关于 Pane 使用单一信息流：应用图标、MiPlay、版本/构建号、许可证和描述。所有内容是静态或只读信息，不嵌套表单卡片，不提供隐藏业务动作。

## 5. Accessibility 语义清单

不创建独立 `AccessibilityTree.swift`。每个现有 View 在自己的控件边界提供系统语义；装饰背景、玻璃、状态点视觉和分隔线隐藏或合并到所属控件。

### 5.1 MainWindow

| 对象 | Role | Label | Value | Hint / Action |
|---|---|---|---|---|
| GameIconButton | Button | `切换到{中文名}` / `Select {English name}` | `当前选中/未选中，{业务状态}` | 选择该游戏并显示其背景与可用操作；Space/Return |
| StatusDot | 不独立暴露 | 无 | 通过所属 Game Button value 提供 | `allowsHitTesting(false)`；不得抢焦点 |
| SettingsButton | Button | `设置` / `Settings` | Settings 窗口状态 | 打开或聚焦 Settings；Space/Return、`⌘,` |
| BackgroundGroupButton | Button / selection item | `{组名}背景组` / `{group name} background` | 当前选中、可用、加载中或失败 | 选择目标组；方向键移动，Return/Space 提交 |
| PrimaryActionButton | Button | 当前动作 | 业务状态、task phase、enabled/disabled 事实 | 执行调用方传入 action；不把 completed 读成成功 |
| TaskFeedback | Status group | `{目标}任务：{阶段}` | 真实百分比或“进度未知/进行中” | Cancel、Retry、Reauthorize 等动作作为独立 Button |
| BackgroundLayer | Hidden | 无 | 无 | `.accessibilityHidden(true)`；不暴露图片、视频、颜色或玻璃 |

### 5.2 Settings

| 对象 | Role | 必须表达 |
|---|---|---|
| Sidebar item | 单选导航项 | Pane 名称、当前选中、目标为全局或 Game ID；激活后焦点进入 Detail 标题/状态 |
| Fixed divider | 装饰 | 不可聚焦、不可拖动、无 VoiceOver 节点 |
| Section header | 标题/静态文本 | 当前信息分组和 Game ID 归属 |
| Metadata row | 静态文本/可复制值 | 原始 section/key、value、来源、时间、可确认性 |
| Compatibility entry | Button | 当前 Game ID、方案数量、应用/失败/不可用事实 | 打开现有兼容方案入口 |
| Performance entry | Button | 当前 Game ID、选项数量、读取/不可用/Deferred 状态 | 打开现有性能入口 |
| Deferred advanced option | 静态状态行 | 名称、适用范围、`Deferred` 和不可执行原因 | 不提供可激活动作 |
| Background group control | Selection item | 组名、版本、当前选择、加载/失败事实 | 选择成功或失败时播报保留上一组 |

### 5.3 动态状态

- `pending`：读出目标、已提交、尚未执行；仅在任务事实允许时提供 Cancel。
- `running`：读出目标、phase 和真实进度；不可估算阶段读“进度未知”，不猜百分比。
- `completed`：必须读取具体 `outcome`；版本检测和完整性校验的 completed 不能泛化为成功。
- `failed`：按目标、阶段、事实、副作用、终态、唯一恢复动作顺序呈现。
- `cancelled`：只有清理/回滚已验证才读“已取消”；取消请求本身不等于终态。
- `recoveryRequired`：读出“当前不能重试”和当前恢复/日志动作；不隐藏保护状态。
- `Unavailable`：读出资源、权限、适用范围或来源原因；不显示可激活 Apply/Toggle。
- `Applied`：读出“方案已应用并验证，游戏尚未启动”。
- `RolledBack`：读出“方案未应用，应用前状态已恢复并确认”。
- 背景组加载失败：读出目标组失败且上一组保留；不得读成背景已切换。

键盘焦点顺序遵循窗口阅读顺序：多背景控制（仅多组）→ Game Buttons → Settings → Primary Action → 当前任务动作；Settings 打开后，主窗口控件离开当前键盘路径。

## 6. Liquid Glass 与状态点验证

### 6.1 实验变量

实验必须将“材质融合”和“命中区域/层级问题”分开验证：

| 变体 | 固定条件 | 只改变的变量 | 观察项 |
|---|---|---|---|
| V0 当前基线 | `56pt` 玻璃、`8pt` 间距、整体 scale | 无 | 玻璃融合、状态点遮挡、hover 位移、误触 |
| V1 仅增间距 | 玻璃和整体 scale 不变 | 间距 `16pt` | 融合是否下降；状态点是否仍被材质遮挡 |
| V2 结构分离 | `64pt` hit frame、`56pt` glass、`12pt` 间距 | scale 只作用 glyph，StatusDot 位于上层 | 材质边界、hit testing、状态点完整性、focus |

V2 的几何预期为：相邻 Button 中心距离 `64 + 12 = 76pt`，固定玻璃面板边界间隙约 `76 - 56 = 20pt`。通过条件：hover 不改变布局和 hit frame，状态点完整可见，选中/hover 不引起玻璃层错误融合。

### 6.2 状态点专项检查

- 无状态、已安装/就绪、更新、启动中、运行中、启动失败各截一张；确认点的颜色/形状变化不改变 Button 几何。
- 检查点位是否在 GlassPanel 上方、是否被 `.clipShape`、mask、material 或 focus 背景裁掉。
- 检查点不覆盖 glyph 主要区域、不扩大 Button 的 hit testing、不成为独立 VoiceOver 元素。
- 键盘 focus、VoiceOver 激活和 hover 同时存在时，focus 反馈不得遮挡状态点或改变其语义。

## 7. 截图验证矩阵

本 UI Agent 只提供验证矩阵，不声称已经完成 macOS 截图。Implementation/Review 必须在 macOS 26、Apple Silicon、固定窗口尺寸下生成实际截图并记录结果。

### 7.1 MainWindow 矩阵

| 编号 | 背景/组状态 | 游戏状态 | 交互状态 | 必查内容 |
|---|---|---|---|---|
| M-01 | 0 个有效组 | 未定位 | 初始 | 无圆点；背景降级不阻断 Game Rail/Settings |
| M-02 | 1 个有效组 | 已定位 | 初始 | 无圆点；Game Button、状态点、主按钮清晰 |
| M-03 | 多个有效组 | 已定位 | 初始 | 圆点数量正确，顶部水平居中，当前组明确 |
| M-04 | 多个有效组 | 已定位 | hover/selected | glyph 反馈与玻璃分离；无融合、无布局位移 |
| M-05 | 多个有效组 | 启动中 | focus/VoiceOver | phase、真实进度/未知进度和禁用事实可读 |
| M-06 | 目标组加载中 | 启动失败 | loading | 上一组仍显示；不读“已切换” |
| M-07 | 目标组不可用 | 启动失败 | error/retry | 上一组保留；目标失败原因和唯一恢复动作可见 |
| M-08 | 任意组 | 运行中/失败 | keyboard | Game → Settings → Primary → task action 顺序稳定 |
| M-09 | 任意组 | 各业务状态 | status point | 状态点在 Button 上层完整显示，不被玻璃/mask/focus 遮挡 |

### 7.2 Settings 矩阵

| 编号 | Pane | 交互状态 | 必查内容 |
|---|---|---|---|
| S-01 | 通用 | 初始/滚动 | Sidebar 240pt、Detail 560pt，不可拖至消失；Section 层级完整 |
| S-02 | Wine | 查询中/空目录/403/网络失败 | 来源身份保留；空目录不显示为网络失败；系统 Wine 不出现 |
| S-03 | 原神 | 有路径/有 metadata | metadata 原始 key/value、来源、时间、完整性证据可区分 |
| S-04 | 星穹铁道 | 无路径/metadata 不可用 | 仍保留独立 Pane，不借用原神结果 |
| S-05 | 绝区零 | 方案/性能入口 | 两个入口可聚焦，目标 Game ID 正确，恢复返回同一上下文 |
| S-06 | 任一游戏 | A-01 至 A-06 Deferred/Unavailable | 无伪 Toggle、无伪成功、原因和适用范围可读 |
| S-07 | 任一游戏 | 多背景/单背景 | 单背景无圆点；多背景状态与 MainWindow 语义一致 |
| S-08 | 任意 Pane | VoiceOver/keyboard | Sidebar 选择、标题、状态、metadata、入口和恢复动作顺序完整 |
| S-09 | 重新打开 | 窗口生命周期 | Settings 每次相对 MainWindow 居中，未改变列宽和选中 Pane 契约 |

### 7.3 证据记录

每张截图至少记录：macOS 版本、设备架构、窗口 frame、MainWindow/Settings 尺寸、当前 Game ID、背景组数量、Task 状态、选中/hover/focus 条件和截图编号。VoiceOver 验证另外记录 label、role、value、hint、announcement 和键盘操作结果。

## 8. Implementation 交接与禁止项

Implementation 必须：

1. 只消费现有 Domain/ViewModel 的结构化状态和动作，不在 View 内新建业务状态或判断成功。
2. 将游戏、Settings、背景组、兼容方案、性能入口改为标准控件语义，保留现有窗口导航契约。
3. 固定 Button、玻璃、状态点和 Sidebar/Detail 的结构尺寸；hover/focus 不能通过 transform 改变布局或命中区域。
4. 使用 `.accessibilityHidden(true)` 隐藏背景和装饰层，把状态点事实合并到所属控件 value/详情节点。
5. 对动态状态保留错误、取消、回滚和恢复未确认事实；不以“重新渲染”为理由清除状态。

禁止：

- 创建独立 `AccessibilityTree.swift` 或另一套业务状态树。
- 使用 `onTapGesture` 代替 Button、Picker 或标准导航控件。
- 用颜色、玻璃亮度、圆点数量、spinner 或进度条推断业务结果。
- 把 Settings 做成多层嵌套卡片，或将 per-game 配置提升为共享全局配置。
- 将一组背景显示为无意义单项圆点，或在目标组失败时静默改选其他组。
- 将 `pkg_version`、`config.ini`、下载完成、进程创建、WineReady、Applied 或任务 completed 直接写成游戏成功。
- 将 UX 标记为 Deferred 的高级配置实现成可执行 Toggle/Apply。

## 9. 验收结论

本 Revision 满足以下 UI 设计验收条件：

- 主按钮和游戏 Button 在固定窗口尺寸下有稳定、可操作的命中区域。
- 状态点完整位于 Button 视觉层上方，不被 GlassPanel、mask、hover 或 focus 遮挡。
- hover 与 Liquid Glass 的影响变量已分离，并有 V0/V1/V2 实验及截图矩阵。
- Settings sidebar/detail 宽度固定，sidebar 不可拖至消失；通用、Wine、三款 per-game 和关于结构完整。
- 每款游戏独立承载 metadata、兼容性方案、性能选项、高级配置状态和背景组。
- 多背景圆点只在有效组多于一组时显示，并位于主窗口顶部水平中心。
- Accessibility label、value、hint、role、enabled、busy 和动态 announcement 均有明确归属；装饰层不进入 Accessibility Tree。
- 未新增业务状态或独立无障碍数据树，未覆盖 UX 未冻结的业务流程。
