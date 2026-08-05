# UI 验证实验与 Accessibility Tree（Task 4）

> **文档状态**：活跃（Active）
> **日期**：2026-08-03
> **适用范围**：主窗口、Settings 窗口、启动任务反馈、错误恢复和兼容方案恢复状态
> **约束**：不修改业务状态模型，不创建 `AccessibilityTree.swift`，不改变既有窗口导航契约
> **对照**：UX State Flow、UX Edge Cases、Apple platform constraints、现有 `MiPlay/UI/`

## 1. Liquid Glass 融合实验

### 1.1 验证对象

实验固定使用主窗口 `1280 × 688`、现有 `GlassEffectContainer`、三款游戏图标、设置齿轮和真实背景素材。背景至少覆盖两种对比条件：高亮背景和深色背景。每个条件都测试：无选中态、选中态、单个游戏 hover、设置 hover、键盘 focus。

### 1.2 基线测量

当前实现的几何事实：

| 项目 | 当前值 | 推导 |
|------|--------|------|
| 游戏玻璃面板 | 56pt | `GameIconContent` 的玻璃和外层 frame 均为 56pt |
| 游戏图标间距 | 8pt | 三个图标 `VStack(spacing: 8)` |
| 相邻中心距离 | 64pt | 56 + 8 |
| 选中态玻璃投影尺寸 | 约 64.4pt | 56 × 1.15 |
| hover 态玻璃投影尺寸 | 约 59.4pt | 56 × 1.06 |
| 选中态最小边界余量 | 约 -0.4pt | 64 - 64.4，存在几何重叠 |

结论：融合并非单纯由背景颜色造成。`GlassEffectContainer` 中相邻玻璃层在低间距下被合成，且当前 scale 作用于包含玻璃面板的整体；选中态已经发生边界重叠，hover 会进一步改变玻璃层的视觉边界。

### 1.3 实验矩阵

| 方案 | 变更 | 验证假设 | 通过条件 |
|------|------|---------|---------|
| V0 基线 | 56pt、8pt、选中 1.15、hover 1.06，整体缩放玻璃 | 记录当前融合、相邻误触和焦点可见性 | 仅作对照，不作为交付方案 |
| V1 间距 | 保持整体缩放，只把游戏间距提升到 16pt | 只要边界分离，融合是否消失 | 最大玻璃边界间隙至少 7pt；状态点不被遮挡 |
| V2 结构分离 | Button 命中框 64pt；玻璃面板固定 56pt；游戏间距 12pt；hover/选中只放大 glyph，不放大玻璃面板 | 玻璃合成与 hover 视觉是否可以同时保留 | 玻璃边界约 20pt（不得小于 12pt）；hover 不改变 hit testing、不融合、不引起布局位移 |

### 1.4 决策

采用 **V2**：

- `GameIconButton` 使用稳定 `64 × 64pt` 命中框；其内部玻璃面板固定 `56 × 56pt`。
- 三个游戏 Button 之间使用 `12pt` 布局间距；设置 Button 使用独立 `16pt` 顶部间隔。
- 选中和 hover 的放大只作用于图标 glyph/非材质内容，最大分别为 `1.08` 和 `1.04`；玻璃面板不缩放。
- 保留 `GlassEffectContainer`、`.glassEffect`、16pt 圆角和现有窗口层级。
- hover 只改变发现反馈；键盘 focus 使用同一稳定 Button 边界和可见 focus 反馈。

V1 可以缓解重叠，但仍让整体玻璃面板随 hover/选中变换；V2 同时解决几何融合、命中区域变化和 Liquid Glass 边缘融合。该决策不引入新的业务状态或独立通用 UI 框架。

## 2. 固定窗口尺寸与布局决策

### 主窗口

- 主窗口继续固定 `1280 × 688pt`，不可因文案或 hover 改变尺寸。
- `GameSelectionRailView` 的 Button 命中框为 `64 × 64pt`；Rail 宽度至少 `76pt`，不得裁切玻璃或状态点。
- 主操作按钮稳定为最小 `220 × 64pt`；按钮内容可以使用现有 Glass 交互材质，但不对整个按钮做改变布局的 hover scale。
- 主操作区的右侧和底部安全间距继续使用现有窗口结构；英文 `View Fixes`、`Locate Game`、`Launching…` 等保持单行。

### Settings 窗口

- Settings 继续固定 `800 × 448pt`、独立 `Settings` Scene、`NavigationSplitView` 和单实例契约。
- 每次 Settings Scene 出现或重新打开时，计算 Settings frame 相对于当前主窗口 frame 的中心点：
  `x = main.midX - settings.width / 2`，`y = main.midY - settings.height / 2`。
- 计算结果必须限制在当前屏幕 `visibleFrame` 内；主窗口不可见时使用主窗口最后一次有效 frame，不改变 Settings 的业务状态。
- 用户打开同一 Settings 窗口时重新执行居中；关闭后再次打开仍重新相对主窗口居中。
- 该行为属于窗口呈现生命周期，不新增 ViewModel 字段或业务事件。

## 3. Accessibility Tree

不创建集中式 `AccessibilityTree.swift`。每个现有 View 在自己的 label/状态/动作边界上附加 SwiftUI accessibility modifiers；装饰层隐藏，交互层保持系统控件角色。

```text
MainWindow [window]
├── BackgroundView [accessibilityHidden: true]
├── GameSelectionRailView [navigation region, children contained]
│   ├── GameIconButton [button, selected state, game label/value/hint]
│   │   └── GameIconContent [visual label only; status dot is not a child element]
│   ├── GameIconButton [button, selected state, game label/value/hint]
│   ├── GameIconButton [button, selected state, game label/value/hint]
│   └── SettingsButton [button, label/value/hint, opens Settings]
├── PrimaryActionRegion [group]
│   ├── PrimaryActionButton [button, action label, current state value]
│   └── TaskFeedbackView [status group]
│       ├── TaskProgressView [phase + determinate/indeterminate progress]
│       ├── CancelButton [only while cancellation is allowed]
│       └── ErrorRecoveryView [error fact + recovery action]
│           ├── RetryButton / ChooseAgainButton / ReauthorizeButton
│           └── RollbackStatus [read-only while restoring]
└── MediaLoadingOverlay [modal progress; background controls covered]
```

### 3.1 Accessibility 节点约束

| 节点 | Label | Value | Hint/action |
|------|-------|-------|------------|
| `BackgroundView` | 无 | 无 | `.accessibilityHidden(true)`；不向 VoiceOver 暴露装饰图片、视频、色彩或渐变 |
| 游戏 Button | `切换到{游戏名}` / `Select {game name}` | `{选中状态}，{业务状态}` | `选择后显示{游戏名}的背景和可用操作`；Space/Return 选择 |
| 设置 Button | `设置` / `Settings` | 当前 Settings 窗口状态 | `打开设置窗口` / `Opens the Settings window`；Space/Return 与 `⌘,` 同一动作 |
| 主操作 Button | 当前动作，例如 `启动` / `Launch` | 当前业务状态或任务状态 | 执行传入动作；disabled 时仍读出“启动中/运行中”等事实 |
| Task progress | `{目标}任务：{阶段}` | 仅真实可估算时读出百分比，否则读出“进行中” | 可取消时由独立 Cancel Button 承载动作 |
| ErrorRecoveryView | `{目标}失败` / `{target} failed` | 失败阶段、事实和当前终态 | 读取唯一恢复动作；不读作成功或已修复 |
| Retry Button | `重试{目标}` / `Retry {target}` | 新任务尚未开始 | 提交新的任务，不覆盖上一条失败事实 |
| Permission failure | `无法访问{目标}` / `Cannot access {target}` | 需要重新授权或重新选择 | `重新授权` / `Choose Again` |
| `Unavailable` | `兼容方案不可用` / `Fix unavailable` | 资源、权限或适用范围原因 | `查看原因`、重新授权或选择其他方案 |
| Rollback in progress | `正在恢复应用前状态` / `Restoring previous state` | 阶段和验证状态 | 不提供取消；恢复结束前不读作已恢复 |
| `RolledBack` | `方案未应用` / `Fix not applied` | `应用前状态已恢复并确认` | 可重试或选择其他方案 |

游戏 Button 的状态圆点、背景图片、玻璃材质、选中高亮和 hover 反馈不产生额外 VoiceOver 节点；状态事实通过 Button value 或详情区域文本提供。

### 3.2 键盘顺序与状态动作

1. 主窗口顺序：三个游戏 Button（固定游戏顺序）→ Settings Button → PrimaryActionButton → 当前任务的 Cancel/Retry/Recovery Button。
2. Sheet/详情窗口打开后，焦点先进入窗口标题和当前状态，再进入可执行 Button；背景窗口控件不抢焦点。
3. `pending`：可取消任务提供 Cancel；不能显示完成或成功。
4. `running`：Progress 节点读出阶段；可取消时提供 Cancel；回滚任务开始后隐藏 Cancel。
5. `failed`：错误节点保留事实；只显示当前有效的 Retry、Choose Again、Reauthorize 或日志动作。
6. `cancelled`：只有清理/回滚确认后读出“已取消，清理已确认”。
7. `completed`：读出具体 outcome；完整性负面结果、方案 Applied 和 WineReady 均不能被泛化为游戏已启动。

## 4. 验证记录格式

实现阶段必须记录：

- V0/V1/V2 在亮背景、暗背景和选中/hover/focus 条件下的截图或录屏。
- 图标玻璃边界、命中框和相邻间隙的测量值；V2 的玻璃边界间隙不得小于 12pt。
- VoiceOver 朗读顺序、label/value/hint、错误恢复动作和 disabled 状态录音或文字记录。
- 键盘 Tab、Space、Return、Escape、`⌘,` 的操作记录。
- Settings 每次打开相对于主窗口的 frame 坐标和 visibleFrame 裁切结果。

没有真实截图或录屏时，不得把实验标记为视觉验证通过；只能标记为几何推导通过。
