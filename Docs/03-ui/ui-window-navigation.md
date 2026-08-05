# 窗口结构与导航框架（Window Structure & Navigation Framework）

> **文档状态**：活跃（Active） | **UX-34 设置独立窗口更新**
> **UI 阶段**：界面结构设计
> **Task 4 修正**：标准 Button 负责导航激活，任务结果不由窗口切换推断。
> **Task 4 修正**：Settings 相对主窗口居中；焦点和 Accessibility Tree 随窗口边界切换。

---

## 主窗口

### 结构描述

MiPlay 采用**主窗口 + Settings 独立场景 + Sheet 模态层**的架构。主窗口承载背景、游戏选择和主操作；设置通过独立 `Settings` 场景呈现。

主窗口的结构沿 Z 轴由深到浅分为以下层级：

```
Z 轴层级（从深到浅）：
┌─ Layer 0: 沉浸式背景层 ─────────────────────────────────┐
│  游戏版本主题背景素材（视频/图片），全屏覆盖                │
├─ Layer 1: 游戏选择层 ─────────────────────────────────────┤
│  左下 GameSelectionRailView + 状态圆点                       │
├─ Layer 2: 设置入口层 ──────────────────────────────────────┤
│  Game Rail 下方 Settings gear                               │
├─ Layer 3: 主操作层 ────────────────────────────────────────┤
│  右下角 PrimaryActionButton                                 │
├─ Layer 4: Sheet 模态层 ────────────────────────────────────┤
│  兼容方案浏览、运行环境进度、任务反馈                         │
└──────────────────────────────────────────────────────────┘
```

### 关键布局约束

#### Constraint-1：主窗口固定尺寸与位置

- MainWindow 固定为 1280 × 688 px。
- `GameSelectionRailView` 固定在左下角，Settings gear 固定在 Game Rail 下方。
- `GameIconButton` 使用稳定 64 × 64pt 命中框，游戏间距 12pt；玻璃面板不随 hover/选中缩放。
- `PrimaryActionButton` 固定在右下角，最小 220 × 64pt，使用 16pt 圆角。
- 不创建中心信息区，不使用旧卡片容器或 Rail 背景组件。
- 加载反馈为不透明白色遮罩。

#### Constraint-2：Settings 排版布局约束

设置面板内容区需遵循以下布局规则：

- **内容区 padding**：统一使用 `.padding(32)`，确保文字与面板边缘留有舒适间距
- **导航栏顶部**：左侧导航栏列表项起始位置应有适当顶部间距（建议 `padding(.top, 8)`）
- **Section 间距**：`Form` + `.formStyle(.grouped)` 模式下保持系统默认 Section 间距，不得额外压缩
- **表单项对齐**：所有配置项保持 macOS 表单标准左对齐 + 右值布局
- **关于页面**：使用 `VStack` 居中布局，图标→名称→版本→描述 之间保持至少 20pt 间距
- **影响范围**：Settings 场景所有子视图


### 导航方式

MiPlay 的导航框架遵循**内容切换式导航（Content Switching）**——三款固定游戏之间通过 Game Rail 切换，辅助功能通过 Sheet 模态呈现。

| 导航类型 | 方式 | 触发 |
|---------|------|------|
| **游戏切换** | 底部 Game Rail 的标准 Button | 用户点击、VoiceOver 激活或键盘 Space/Return |
| **辅助功能** | Sheet/任务反馈视图 | 主操作按钮或当前任务状态触发 |
| **设置** | 独立 `Settings` 场景 | Game Rail 下方设置 Button 或 `⌘,` |
| **系统文件选择** | NSOpenPanel（由主操作触发） | PathLocationFlow 触发系统级文件/目录选择 |

**具体导航规则：**

1. **游戏切换**：用户激活 GameSelectionRailView 中另一款游戏 Button → 当前背景和 PrimaryActionButton 同步更新 → 背景切换使用 cross-fade。Button 的 VoiceOver、键盘和鼠标结果一致。

2. **状态驱动的操作导航**：主操作按钮根据游戏状态决定操作类型：
   - `PathUnset` / `NotInstalled` → 打开系统 `NSOpenPanel` 定位游戏路径
   - `Installed` → 执行启动流程（可能自动触发 WineProgressSheet）
   - `UpdateAvailable` → 触发游戏更新流程
   - `Launching` → 显示进度（不可操作）
   - `Running` → 显示"运行中"（不可操作）
   - `LaunchFailed` → 打开 `GameDetailWindow` 并选中 `CompatibilitySolutionView`

3. **设置入口**：激活 Game Rail 下方设置 Button → 调用 `openSettings()` 打开独立 `Settings` 场景。设置窗口与主窗口无布局耦合，关闭后状态保持。快捷键 `⌘,` 由 Scene 注册。

4. **WineProgressSheet 自动管理**：启动依赖 WineRuntime 未就绪时展示获取阶段。`WineReady` 只表示依赖准备完成；随后仍需等待游戏进程确认，不显示游戏启动成功。

---

## 辅助窗口（Settings Scene + Sheet）

MiPlay 采用**独立设置窗口 + Sheet 模态层**的混合架构。主要辅助通道如下：

| 功能 | 呈现方式 | 尺寸 | 关闭方式 |
|------|---------|------|---------|
| **Settings** | 独立 Settings Scene | 固定尺寸（800 × 448 px） | 红绿灯关闭 / ⌘W |
| **GameDetailWindow** | 独立窗口 | 550 × 700 px | 窗口关闭 / ⌘W |
| **PathLocationFlow** | 系统 `NSOpenPanel` + 主窗口反馈 | 系统选择器 | 取消返回；权限/完整性结果留在主窗口 |
| **WineProgressSheet** | Sheet 或内嵌 Overlay | 自适应（建议宽 400-500pt） | 操作完成自动关闭 |

### Settings 独立窗口约束

#### Constraint-3：NavigationSplitView 原生使用 + Settings Scene

设置窗口原生使用 NavigationSplitView，不再受 ZStack overlay 的 toolbar 溢出限制。

- 左侧 Sidebar：固定宽度 240pt，使用 List 手动绑定选中项，包含 6 个 Pane：通用、原神、星穹铁道、绝区零、Wine 环境、关于
- 右侧 Detail：根据选中项切换显示不同配置面板
- Detail 使用 `Form { Section {} }` + `.formStyle(.grouped)`，只读信息使用 `LabeledContent`，表单行最小高度 42pt
- 使用 `.windowStyle(.hiddenTitleBar)` + `.windowResizability(.contentSize)`
- Settings 每次出现时相对 MainWindow frame 居中，并将 frame 限制在当前屏幕 `visibleFrame` 内；不改变 Scene、导航或单实例契约。

### Accessibility focus 边界

- 主窗口焦点顺序为游戏 Button（固定顺序）→ Settings Button → PrimaryActionButton → 当前任务动作。
- Settings 或 GameDetailWindow 打开后，焦点进入新窗口的标题/当前状态；主窗口控件不参与当前窗口的 Tab 顺序。
- `BackgroundView` 和装饰性媒体隐藏；Progress、错误、重试、重新授权和回滚状态作为当前窗口的可读节点。



### Sheet 行为规则
- PathLocationFlow 取消后保留原业务状态；路径选择本身不显示已安装或已就绪。
- WineProgressSheet 在依赖准备完成后可关闭或回到启动流程，但不产生游戏成功状态。
- GameDetailWindow 应用方案后不自动关闭，等待用户查看具体结果或关闭；`Applied` 不自动触发游戏启动。
## 窗口规格

### 固定尺寸

| 项目 | 值 | 说明 |
|------|-----|------|
| **窗口尺寸** | 1280 × 688 px | 固定尺寸，不可缩放。16:9 比例，窗口尺寸直接等于内容安全区，无额外安全区偏移。适配主流 MacBook 屏幕 |
| **宽高比** | 16:9 固定 | 窗口大小恒定，背景素材比例固定，无需自适应 |
| **安全区策略** | 顶部红绿灯区域由系统原生处理 | 窗口标题栏隐藏（`.hiddenTitleBar`），红绿灯按钮区域由系统自动叠加在窗口右上角；背景内容可延伸至红绿灯按钮下层；所有 UI 控件（Game Rail、操作区）严格保持在内容安全区内 |

### 窗口缩放行为

| 行为 | 策略 | 说明 |
|------|------|------|
| **缩放** | 不可缩放 | 窗口尺寸恒定 1280×688 px，缩放控制禁用 |
| **全屏模式** | 支持（Enter Full Screen） | 全屏时背景素材按 aspect-fill 展开至全屏尺寸，UI 控件位置不变，两侧或上下补充暗色边缘遮罩 |
| **窗口恢复** | 记住窗口位置 | 仅记住窗口在屏幕上的位置（不记忆尺寸，因尺寸固定） |
