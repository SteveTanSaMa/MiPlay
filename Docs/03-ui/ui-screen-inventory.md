# Screen Inventory（屏幕清单）

> 当前实现核对（2026-10-09）：实际界面为沉浸主窗口、独立 Settings、启动准备遮罩、系统目录 Sheet 与 Alert。游戏详情、兼容方案独立页面及历史 WineProgressSheet 不在当前实际 UI 中。以下历史条目不能作为重新添加界面的依据；当前文件与验证清单见 [原生 UI 审查](ui-native-review-2026-10-09.md)。


> **文档状态**：活跃（Active）
> **UI 阶段**：界面结构设计
> **继承来源**：UX 任务分析、UX 用户旅程、UX 信息模型
> **Task 4 修正**：按当前 `MiPlay/UI/` 结构呈现真实任务状态；不添加不存在的成功屏幕。
> **Product/Research 回溯修订**：2026-08-28。用户新硬约束覆盖此前 I-4；当前只允许固定 `wine-crossover-11.0-1-signed`、一个共享 Wine runtime 和一个共享 prefix。
> **废止说明**：此前“全局 / 单独 Wine 版本”结构、Wine 版本列表、来源选择和按游戏 Wine 控件不再是 UI 输入。

---

## Screen 总览

| 序号 | Screen 名称 | 用途 | 显示方式 |
|------|------------|------|---------|
| 1 | MainWindow | 应用主窗口，承载所有核心交互与固定三款游戏的切换管理 | 原生窗口（文档类型） |
| 2 | GameLaunchView | 单游戏沉浸式启动视图，三款游戏共用同一布局结构 | 主窗口内容区 |
| 3 | PathLocationFlow | 选择已安装游戏路径、反馈权限和完整性结果 | 系统 `NSOpenPanel` + 主窗口任务反馈 |
| 4 | GameDetailWindow | 浏览、确认与应用兼容方案，以及游戏详情 | 独立窗口 |
| 5 | Settings | 通用配置、三款游戏非 Wine 设置与统一 Wine runtime 管理 | 独立 Settings 场景 |
| 6 | WineProgressSheet | 统一固定 Wine 与共享 prefix 的单一准备任务反馈 | Sheet（模态）/ Overlay |

---

### 1. MainWindow

- **用途（Purpose）**：作为应用的主容器窗口，管理三款固定游戏（原神、星穹铁道、绝区零）的切换，根据选中的游戏切换背景和主操作。提供精简的全局交互框架（GameSelectionRailView、Rail 下方设置入口、右下角主操作按钮）。
- **入口（Entry）**：应用启动时自动打开；或从菜单栏点击打开。
- **出口（Exit）**：用户关闭窗口（窗口关闭不等同于应用退出，应用可在菜单栏驻留）。
- **归属任务（Owned Tasks）**：切换游戏、总览游戏状态（通过 Game Rail 状态圆点）。
- **引用 UX 任务（Reference UX Tasks）**：任务"总览游戏状态"、任务"切换游戏"、旅程 6（多游戏间切换管理）。
- **布局约束**：
  - BackgroundView 使用 `.frame(width: 1280, height: 688)` 固定尺寸
  - BackgroundView 占满窗口；窗口尺寸为 1280 × 688 px
  - GameSelectionRailView 位于左下角，Settings gear 位于 Game Rail 下方
  - PrimaryActionButton 位于右下角，不设置独立中心信息区
  - 背景组圆点仅在有效背景组多于 1 个时存在：默认 `opacity 0`，指针进入顶部 40pt 悬停区后显示，离开后恢复隐藏
  - 背景组圆点区固定位于窗口顶部 `top: 12pt`、水平居中；单圆点命中框 `24 × 24pt`、圆点间距 `10pt`，与左下 Game Rail 和右下主操作区无重叠
  - 圆点 hover 时圆点内容放大并高亮，不改变命中框、布局尺寸或窗口层级
  - 状态通过 Game Rail 状态圆点、主按钮语义和任务反馈传达；不显示泛化成功状态
  - 游戏图标和设置齿轮均为标准 `Button`，可被 VoiceOver 和键盘激活
  - 加载遮罩为不透明白色，不使用半透明材质

---

### 2. GameLaunchView

- **用途（Purpose）**：单游戏的沉浸式启动视图。展示当前游戏版本的官方主题背景素材，并为 GameSelectionRailView 和 PrimaryActionButton 提供当前游戏上下文。三款游戏共用同一套背景与操作结构。
- **入口（Entry）**：用户在 Game Rail 中选中某游戏时自动切换到此视图；或应用启动后默认展示最近一次选中的游戏。
- **出口（Exit）**：用户通过 Game Rail 切换到另一款游戏；或进入路径定位、兼容方案、设置等辅助流程。
- **归属任务（Owned Tasks）**：日常启动游戏、游戏更新、感知游戏版本主题、管理性能选项、应用兼容方案（入口）、Wine 运行时管理（入口）。
- **引用 UX 任务（Reference UX Tasks）**：任务"日常启动游戏"、任务"游戏更新"、任务"管理性能选项"、任务"感知游戏版本主题"、旅程 3（日常打开即玩）、旅程 4（游戏版本更新）。

---

### 3. PathLocationFlow

- **用途（Purpose）**：承载选择已安装游戏可执行文件或目录后的访问授权、路径识别和完整性结果反馈。选中路径不等于已接入，只有可信校验结果才能改变游戏业务状态。
- **入口（Entry）**：从 GameLaunchView 的 `定位游戏` 主操作触发系统 `NSOpenPanel`。
- **出口（Exit）**：用户取消选择 → `cancelled`，原状态不变；权限失败 → `failed`，不标记已安装；完整性通过 → 显示已确认结果并回到可用操作；损坏或不支持 → 保留对应结果，不显示已就绪。
- **归属任务（Owned Tasks）**：路径定位、访问授权和完整性校验反馈。
- **引用 UX 任务（Reference UX Tasks）**：任务"定位已安装游戏路径"、旅程 2（定位已安装游戏）、旅程 6（完整性校验）。

---

### 4. GameDetailWindow

- **用途（Purpose）**：为处于 `LaunchFailed` 状态的游戏提供兼容方案浏览、风险告知、方案应用与回滚的能力，并承载当前 `GameDetailWindowScene` 的游戏信息和性能选项页。
- **入口（Entry）**：从 GameLaunchView 触发（游戏状态为 `LaunchFailed` 时主操作按钮为"查看修复方案"），打开独立 `GameDetailWindow` 并选中兼容方案页。
- **出口（Exit）**：显示 `Applied`、`RolledBack`、`Failed` 或 `Unavailable` 的具体结果后关闭/返回；`Applied` 只表示方案已验证，仍需单独重新启动游戏；用户取消若已发生修改必须先完成回滚。
- **归属任务（Owned Tasks）**：应用兼容方案解决启动问题。
- **引用 UX 任务（Reference UX Tasks）**：任务"应用兼容方案"、旅程 5（启动失败与自助修复）、旅程 8（首次兼容方案应用）。

---

### 5. Settings

- **用途（Purpose）**：提供所有可配置项的浏览与修改界面。包含通用、三款游戏的非 Wine 设置、统一 Wine 环境和关于信息。六项配置 Pane 通过 NavigationSplitView 的 Sidebar 导航切换。
- **入口（Entry）**：从 MainWindow 的 Game Rail 下方设置齿轮按钮（`openSettings()`）进入；键盘快捷键 `⌘,`；菜单栏"设置…"。
- **出口（Exit）**：用户关闭窗口（红绿灯按钮 / ⌘W）。关闭后设置状态保持，不阻塞主窗口操作。
- **归属任务（Owned Tasks）**：通用配置、单游戏非 Wine 信息查看、统一 Wine runtime 与共享 prefix 状态查看。
- **引用 UX 任务（Reference UX Tasks）**：任务"管理性能选项"（配置入口）、旅程 7（调优游戏表现）。
- **窗口规格**：
  - 独立 `Settings` Scene 和独立 `GameDetailWindow`，非主窗口 overlay
  - 固定尺寸 800 × 448 px，`.windowStyle(.hiddenTitleBar)`，`.windowResizability(.contentSize)`
  - 同一时刻仅一个设置窗口实例
  - 设置窗口开启/关闭不影响主窗口任何布局
- **布局约束**：
  - 内部使用 NavigationSplitView（sidebar + detail），无 toolbar sidebar toggle 限制
  - Sidebar 宽度 240pt，列表项 24pt 行高，6 个 Pane
  - Detail 使用 `Form { Section }` + `.formStyle(.grouped)`，行高 min 42pt
  - 只读信息行使用 `LabeledContent`（macOS 13+）
  - Wine 环境 Pane 只展示一个固定 runtime、一个共享 prefix 和一个统一任务区域；不展示作用范围切换、版本选择或版本列表
  - 固定 runtime 身份显示为 `wine-crossover-11.0-1-signed`；来源由产品管理，页面不提供来源选择、URL 或外部路径
  - 统一任务区域提供单一下载/安装/重试入口；任务进行中、失败、取消和恢复中的字段位置保持稳定
  - 三款游戏以只读事实显示共用同一个 Wine runtime 和共享 prefix；不得为游戏显示不同 Wine、不同 prefix 或选择控件
  - 共享 runtime/prefix 就绪只表示公共运行环境事实；不得由该状态推断三款游戏的启动前置均已通过
  - 通用 Pane 的“此 Mac”为只读四行：机型、芯片、内存、macOS 版本；未读取字段显示明确未知态，不做推断
  - Wine 目标磁盘空间作为独立只读行，不进入“此 Mac”主层级
  - 关闭方式：红绿灯关闭按钮 / ⌘W

- **macOS 26 规范合规性**：

| 规范项 | 状态 | 说明 |
|--------|------|------|
| Sidebar 宽度 240pt（合规 180-240pt） | ✅ 240pt |
| Sidebar 列表项 24pt 行高 | ✅ 已标注 |
| NavigationSplitView 无 toolbar toggle 限制 | ✅ 独立窗口 |
| Detail `Form { Section }` + `.formStyle(.grouped)` | ✅ 已使用 |
| LabeledContent 替代手写 HStack（macOS 13+） | ✅ 已标注 |
| 表单行最小高度 42pt | ✅ 已标注 |
| Section Header Bold 700, 13px | ✅ 系统默认 |
| 文字颜色系统（.primary/.secondary/.tertiary） | ✅ 系统默认适配 |
| 关闭方式 | ✅ 红绿灯 + ⌘W |
| 窗口尺寸 800×448 | ✅ ADR 020 固定 |
| 同一时刻单实例 | ✅ Settings 场景保证 |
