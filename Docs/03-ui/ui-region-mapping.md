# 区域划分与信息层级（Region Mapping & Information Hierarchy）

> **文档状态**：活跃（Active）
> **UI 阶段**：界面结构设计
> **最终结构**：BackgroundView + GameSelectionRailView + Settings gear + PrimaryActionButton
> **Task 4 修正**：图标入口采用标准 Button；任务反馈与业务结果分开呈现。
> **Task 4 修正**：稳定命中框、间距、主按钮尺寸与辅助技术层级。

---

## MainWindow 区域总览

| 区域 | 位置 | 承载内容 | 可见性 |
|------|------|----------|--------|
| 沉浸式背景区 | 全窗口 | BackgroundView，静态图片/视频及降级背景 | 始终可见 |
| 游戏选择区 | 左下角 | GameSelectionRailView、3 个 64pt GameIconButton、状态圆点和选中态 | 始终可见 |
| 设置入口区 | Game Rail 下方 | Settings Button，调用 `openSettings()` | 始终可见 |
| 主操作区 | 右下角 | 220×64pt PrimaryActionButton、任务阶段/真实进度/失败/取消/重试反馈 | 始终可见 |
| 加载反馈层 | 全窗口覆盖 | 不透明白色 Loading 遮罩 | 仅加载中可见 |

---

### 沉浸式背景区（Immersive Background Region）

- **位置**：全窗口覆盖，Z 轴第 0 层；窗口固定尺寸 1280 × 688 px。
- **承载内容**：当前游戏版本的官方主题背景素材（VersionBackground），包括静态图片或动态视频；素材不可用时展示默认背景。
- **交互用途**：非交互区域，负责传达当前游戏版本主题。
- **约束**：背景不承载设置面板、状态文字或中心信息区；加载状态使用不透明白色遮罩表达。

### 游戏选择区（Game Selection Region）

- **位置**：窗口左下角。
- **承载内容**：`GameSelectionRailView`，包含三个标准 `GameIconButton`；Button label 包含游戏图标和状态圆点。
- **材质与尺寸**：GameSelectionRailView 使用 `GlassEffectContainer`；Button 命中框固定 64 × 64pt，内部玻璃面板固定 56 × 56pt，游戏 Button 间距 12pt。hover/选中只变换 glyph，不变换玻璃面板。
- **交互用途**：通过鼠标、键盘或 VoiceOver 激活 Button 切换当前游戏，并通过状态圆点提供三款游戏的概览。
- **不承载内容**：不使用旧卡片容器、独立 Rail 背景或中心信息区。

### 设置入口区（Settings Entry Region）

- **位置**：Game Rail 下方，与游戏选择区保持同一左下角操作上下文。
- **承载内容**：标准设置齿轮 Button，使用 `.glassEffect`，拥有本地化 accessibility label/hint 和 tooltip。
- **交互用途**：Button 激活调用 `openSettings()` 打开独立 `Settings` 场景；不作为主窗口 overlay。`⌘,` 提供同一入口的键盘路径。

### 主操作区（Primary Action Region）

- **位置**：窗口右下角。
- **承载内容**：单一 `PrimaryActionButton`，使用 `.glassEffect` 与 `Glass.regular`，16pt 圆角。
- **交互用途**：根据上游传入状态执行定位游戏、启动、更新、重试或查看修复方案；任务进行时显示阶段和真实进度，失败时显示唯一恢复动作。
- **信息策略**：按钮文字承担主操作语义，不再配套中心状态文字、版本信息或次要按钮。
- **尺寸约束**：主按钮最小 220 × 64pt；hover 和 focus 不改变外层布局尺寸，英文文案在固定窗口内保持单行。

### 加载反馈层（Loading Feedback Layer）

- **位置**：覆盖主窗口内容，位于背景和交互控件之上。
- **承载内容**：不透明白色加载层与加载指示。
- **交互用途**：加载期间阻止底层交互；加载完成后移除。
- **约束**：不使用半透明黑色遮罩、渐变遮罩或毛玻璃遮罩。
- **约束**：遮罩只在确实阻断交互的加载阶段出现；不把素材加载完成渲染为游戏启动或安装成功。
- **无障碍约束**：背景和装饰素材隐藏于 Accessibility Tree；遮罩自身提供“正在准备背景素材”的进度事实，并阻断底层控件焦点。

---

## Settings 区域总览

`Settings` 为独立窗口，尺寸 800 × 448 px，内部使用 NavigationSplitView。

| 区域 | 位置 | 承载内容 |
|------|------|----------|
| Sidebar | 左侧，240pt | 6 个 Pane：通用、原神、星穹铁道、绝区零、Wine 环境、关于 |
| Detail | 右侧自适应 | `Form { Section {} }` + `.formStyle(.grouped)` |

Detail 内的只读信息使用 `LabeledContent`，表单行最小高度 42pt。

### Settings 窗口位置

- Settings 每次打开或重新出现时相对主窗口居中，不使用屏幕中心作为默认替代。
- 以当前主窗口 frame 和 Settings frame 计算中心点，并将结果限制在当前屏幕 `visibleFrame` 内。
- 关闭后再次打开重新计算；不把窗口位置写入业务持久化，也不改变既有 Settings Scene 单实例契约。
