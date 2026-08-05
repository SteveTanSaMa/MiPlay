# Visual Prompts（文生图模型视觉提示词）

> **文档状态**：活跃（Active）
> **目的**：为每个关键 Screen 生成可供文生图模型使用的视觉设计提示词
> **美学基准**：Apple 美学（macOS 26+ 原生质感）
> **Task 4 约束**：图标视觉必须承载于标准 Button；视觉提示不代表业务成功状态。

---

### MainWindow / GameLaunchView — Visual Prompt

**目标模型：** Midjourney

**English Prompt：**
```
A full-screen immersive game launcher interface on macOS 26, Apple Liquid Glass design aesthetic, fixed at 1280 by 688 pixels. The entire window is dominated by a fantasy game key visual artwork as the background, rendered edge-to-edge. At the lower left, exactly three compact game icon contents form a vertical GameSelectionRailView; each icon uses glassEffect, a 16pt corner radius, and a small status dot. Directly below the game rail sits a glass gear button that opens Settings. A single prominent PrimaryActionButton sits at the lower right, using glassEffect with Glass.regular and a 16pt corner radius, with no center information panel or secondary action menu. The button label is the only primary status cue. Loading is represented by an opaque white loading layer. The overall atmosphere is premium, serene, and unobstructed, with the background artwork remaining the visual focus. Soft dynamic shadows, subtle glass reflections, no window title bar visible, content spills edge to edge. 8K detail, cinematic lighting -- shot on 50mm lens, f/1.8.
```

**中文说明：**
一张 1280 × 688 的全屏沉浸式游戏启动器界面。背景主题素材铺满窗口；左下角是三个标准 `GameIconButton` 组成的 `GameSelectionRailView`，Button label 内是使用 `.glassEffect` 和 16pt 圆角的图标内容及状态圆点；Game Rail 下方是标准设置 Button。右下角只有一个使用 `Glass.regular`、`.glassEffect` 和 16pt 圆角的主操作按钮，不存在中心信息区或次要操作菜单。加载时显示不透明白色遮罩。整体保持背景素材为视觉焦点。

**设计依据：**
- 美学风格：Apple 美学（macOS 26+ 原生质感）— Liquid Glass 材质
- 参考来源：research-ui-patterns.md — YAAGL 全屏背景、MiPlay 旧版 ZStack 分层、Apple Liquid Glass 设计规范
- 关键视觉特征：`.glassEffect`、`GlassEffectContainer`、`Glass.regular`、16pt 圆角、左下游戏选择栏、Game Rail 下方设置入口、右下主操作按钮、不透明白色加载层、无窗口标题栏

---


---

## 按钮视觉策略（Button Visual Strategy）

> **适用版本**：UI-11 + UI-12 修复后；Settings 独立场景 (ADR 020)
> **设计原则**：按钮在任意背景色调下保持可辨识，遵循 Apple Liquid Glass 美学，不退回半透明遮罩方案。
> **CR-6 修复**：主操作按钮使用 `.primary` 文字，系统自动适配亮色/暗色模式。

### 材质策略

所有按钮和可点击图标使用毛玻璃材质替代固定颜色：

| 组件 | 材质 | 文字/图标色 | 说明 |
|------|------|------------|------|
| 设置齿轮图标按钮 | `.glassEffect` | `.primary` + 轻阴影 | Game Rail 下方入口 |
| 主操作按钮（定位/启动/更新） | `.glassEffect` + `Glass.regular` | `.primary` + 深阴影 | 右下角，16pt 圆角 |
| GameIconContent | `.glassEffect` | `.primary` | 左下游戏选择栏，16pt 圆角 |
| Settings 关闭 | 系统场景关闭行为 | — | 独立 Settings 场景 |

[^1]: 设置齿轮图标直接使用毛玻璃背景而非 `.foregroundStyle(.secondary)` 固定灰色，确保在深色背景素材上保持可见。毛玻璃材质自动根据背景明暗调整透明度和色调。

### Hover 悬停效果

所有可点击按钮和图标必须包含 hover 态反馈，遵循 macOS 原生质感：

| 组件 | Hover 效果 | 动画 |
|------|-----------|------|
| 设置齿轮图标 | 毛玻璃背景出现 + 轻微缩放 (1.05) | 0.15s ease-out |
| 主操作按钮 | 背景亮度提升 + 缩放 (1.03) + 阴影加深 | 0.2s ease-out |
| Game Rail 游戏卡片 | 图标亮度提升 + 缩放 (1.04) | 0.15s ease-out |
| 操作菜单按钮 | 毛玻璃背景高亮 + 缩放 (1.03) | 0.15s ease-out |
| Settings 关闭 | 红绿灯（系统原生） | — |

> 所有 hover 动画只作为标准 Button 的视觉反馈，不承载动作；不引入透明手势层或自定义点击路径。
> hover 效果不应过于夸张（缩放范围严格控制在 1.02~1.05），保持 macOS 精致低调的交互质感。

---


### GameSelectionRailView (Embedded in MainWindow) — Visual Prompt

**目标模型：** Midjourney

**English Prompt：**
```
A close-up detail view of a macOS 26 GameSelectionRailView at the lower left of a full-screen game launcher. Exactly three vertically arranged GameIconContent items use glassEffect and 16pt rounded corners, each with a game icon and a small colored status dot. A separate glass gear button sits directly below the rail. There is no rail background container and no center information panel. The background artwork remains visible around the controls. Cinematic macro shot, 8K detail, premium glass rendering with realistic reflections. Shot on 85mm lens, f/2.8.
```

**中文说明：**
macOS 26 游戏启动器左下角 `GameSelectionRailView` 的细节特写。三个 `GameIconContent` 垂直排列，使用 `.glassEffect` 和 16pt 圆角，每个图标旁有状态圆点；Game Rail 下方是独立设置齿轮。不包含 Rail 背景容器，背景主题素材直接可见。

**设计依据：**
- 美学风格：Apple 美学 — Liquid Glass 材质
- 参考来源：research-ui-patterns.md — macOS 26 设计规范 Sidebar、Apple Liquid Glass 底部导航
- 关键视觉特征：超薄毛玻璃、状态指示圆点、选中态发光环、边缘高光

---

### PathLocationFlow — Visual Prompt

**目标模型：** Midjourney

**English Prompt：**
```
A macOS 26 game path location flow using the native NSOpenPanel and a restrained Liquid Glass task feedback area. The system file picker selects an existing game executable or folder; selecting a path is not presented as installation or success. After the picker, show a compact task feedback region with the current phase, a determinate progress indicator only when a real estimate exists, and clear states for access denied, integrity failed, integrity unsupported, cancelled, and retryable failure. Use standard semantic buttons labeled "Cancel", "Retry", and "Choose Again". Keep the fixed 1280 by 688 main window structure and do not add a success banner.
```

**中文说明：**
macOS 26 已安装游戏路径定位流程，优先使用系统 `NSOpenPanel`。选择可执行文件或目录后，主窗口显示任务阶段和真实进度；权限拒绝、完整性损坏、无法验证、取消和可重试失败各自有清晰反馈。使用标准语义按钮 "Cancel"、"Retry"、"Choose Again"，不显示安装完成或通用成功横幅。

**设计依据：**
- 美学风格：Apple 美学 — Liquid Glass 材质
- 参考来源：research-ui-patterns.md — macOS 26 设计规范的 Progress Indicator、Apple 任务反馈设计语言
- 关键视觉特征：阶段/真实进度指示器、权限与完整性结果、重试和取消 Button、任务反馈区域

---

### GameDetailWindow / CompatibilitySolutionView — Visual Prompt

**目标模型：** Midjourney

**English Prompt：**
```
A macOS 26 standalone GameDetailWindow for browsing compatibility solutions, Apple Liquid Glass design. The fixed 550 by 700 window contains a game header, a segmented tab picker, and a CompatibilitySolutionView. The solution list shows risk, scope, availability, current application state, and diagnostic facts. A selected solution can show a standard "Apply" Button or a standard "Rollback" Button; Applying, RolledBack, Failed, and recovery-unconfirmed states are distinct, and Applied explicitly does not imply that the game is running. The window remains open after a verified solution result so the user can inspect the fact before returning to launch. Use semantic buttons and visible text, not color alone.
```

**中文说明：**
macOS 26 独立 `GameDetailWindow` 的兼容方案页，使用 Apple Liquid Glass 设计。固定窗口包含游戏信息头部、分段选择器和 `CompatibilitySolutionView`。方案列表显示风险、适用范围、可用性、应用记录和诊断事实；应用、回滚、失败和恢复未确认状态清晰区分。方案已验证不表示游戏正在运行；使用标准语义按钮和可读文本，不能只依赖颜色。

**设计依据：**
- 美学风格：Apple 美学 — Liquid Glass 材质
- 参考来源：research-ui-patterns.md — Apple Liquid Glass 窗口层级、macOS 26 标准窗口
- 关键视觉特征：独立详情窗口、分段选择器、风险和可用性事实、标准操作 Button、可读状态文本

---

### Settings — Visual Prompt

**目标模型：** Midjourney

**布局约束参考**：ADR 020 (独立 Settings 场景), macOS 26 设置规范
**关键约束**：
- 独立窗口 800×448，`.hiddenTitleBar` + `.contentSize` 尺寸锁定
- NavigationSplitView sidebar 240pt，6 个 Pane
- Detail 使用 Form + .formStyle(.grouped)，LabeledContent，42pt 行高

**English Prompt：**
```
A macOS 26 standalone settings window for a game launcher, Apple Liquid Glass design. The window is compact at 800pt by 448pt with a hidden title bar, floating independently — not as a sheet or overlay. Inside, a standard NavigationSplitView layout: left sidebar at 240pt width with 6 navigation items at 24pt row height — "General" (gear icon), three game entries (game controller icons), "Wine Environment" (wine glass icon), and "About" (info circle icon). A subtle divider separates the sidebar from the content area. On the right side, the detail panel uses macOS grouped Form style with sections containing LabeledContent rows at minimum 42pt height, showing configuration toggles, text info rows, and pickers — all natively spaced. The About pane features a centered VStack layout with a large app icon (64pt), app name "MiPlay" in bold title, version info, and a centered description. The overall feeling is native, clean, and premium — a dedicated settings window that feels like part of macOS itself. 8K detail, soft shadows, edge highlights on glass edges. Shot on 50mm lens, f/2.8.
```

**设计依据：**
- 美学风格：Apple 美学 — Liquid Glass 材质
- 参考来源：macOS 26 设置界面规范、ADR 020
- 关键视觉特征：独立窗口、NavigationSplitView 双栏、Form grouped 布局、LabeledContent 行、红绿灯关闭

---

### WineProgressSheet — Visual Prompt

**目标模型：** Midjourney

**English Prompt：**
```
A macOS 26 progress sheet showing Wine runtime download status, Apple Liquid Glass design. A compact frosted glass panel (420pt wide) floats in the center of a dark, blurred game background. The sheet's glass material is thick and translucent with subtle animated shimmer effects. In the center of the sheet, a large circular progress ring made of glass with a gradient glow (cyan to blue) animates smoothly -- showing approximately 67% completion. Inside the ring, the percentage "67%" in large white digits. Below the ring, a stage description "Downloading Wine Runtime..." in white, with a smaller sub-text "Stage 2 of 4 - Downloading (1.2 GB / 2.4 GB)" in light gray. A vertical list of four stage indicators on the left side of the ring: Stage 1 "Preparing" marked complete (green checkmark), Stage 2 "Downloading" marked active (cyan pulse), Stage 3 "Verifying" marked pending (gray), Stage 4 "Installing" marked pending (gray). At the bottom, a small "Cancel" glass button in subtle style. A faint network speed indicator "12.5 MB/s" at the bottom right. The overall feeling is smooth, technical, and premium -- like watching a sophisticated system prepare itself. 8K detail, subtle glass reflections, animated progress glow. Shot on 50mm lens, f/2.2.
```

**中文说明：**
macOS 26 Wine 运行时下载进度 Sheet，Apple Liquid Glass 设计。紧凑型毛玻璃面板（420pt 宽）居中浮动。中央环形玻璃进度指示器显示 67%，青到蓝渐变发光。下方是阶段描述和下载信息。左侧是四个阶段指示器。底部有"Cancel"玻璃按钮。流畅、技术感强、高端。

**设计依据：**
- 美学风格：Apple 美学 — Liquid Glass 材质
- 参考来源：research-ui-patterns.md — macOS 26 设计规范的环形进度指示器
- 关键视觉特征：环形玻璃进度指示器、阶段列表、下载速度显示、渐变发光动画、紧凑型 Sheet

---

### MainWindow (Empty Initial State) — Visual Prompt

**目标模型：** Midjourney

**English Prompt：**
```
A macOS 26 game launcher main window in its initial empty state, fixed at 1280 by 688 pixels. The full-screen game background remains unobstructed. At the lower left, three standard GameIconButton items form the GameSelectionRailView, each with a glassEffect label, 16pt rounded corners, and an optional neutral status dot; a semantic settings gear Button sits directly below the rail. At the lower right, a single Glass.regular PrimaryActionButton with a 16pt corner radius reads "Locate Game". There is no center information panel, no rail background container, and no secondary action menu. Loading uses an opaque white layer. The overall feeling is polished, welcoming, and focused. Cinematic lighting, 8K detail, subtle glass reflections, no window title bar. Shot on 50mm lens, f/2.2.
```

**中文说明：**
macOS 26 游戏启动器初始空状态主窗口，尺寸 1280 × 688。背景素材完整展示；左下角是三个承载于标准 Button 的图标内容，使用 `.glassEffect` 和 16pt 圆角，Game Rail 下方是标准设置 Button；右下角是使用 `Glass.regular` 和 16pt 圆角的唯一主操作按钮 "Locate Game"。没有中心信息区、Rail 背景容器或次要菜单；加载使用不透明白色遮罩。整体精致、专注。

**设计依据：**
- 美学风格：Apple 美学 — Liquid Glass 材质
- 参考来源：research-ui-patterns.md — Apple Web Design 的邀请式 CTA、macOS 26 设计规范
- 关键视觉特征：`.glassEffect`、`Glass.regular`、16pt 圆角、左下游戏选择栏、右下主操作、不透明白色加载层
