# Interface Structure Rationale（界面结构设计依据）

> **文档状态**：活跃（Active）
> **UI 阶段**：界面结构设计
> **最终规格**：MainWindow 1280 × 688；Settings 800 × 448
> **Task 4 修正**：Button 语义、任务事实和业务结果分层。
> **Task 4 修正**：基于 Liquid Glass 几何实验确定尺寸、间距和无障碍层级。

---

## 1. 沉浸式背景层

- **来源**：UX 信息模型中的 `VersionBackground`，以及“感知游戏版本主题”任务。
- **结构决定**：BackgroundView 占满 1280 × 688 主窗口，作为唯一视觉基础层。
- **设计原因**：保持游戏版本素材的沉浸感，并将交互控件压缩到必要的四个入口：游戏选择、设置、主操作和加载反馈。
- **加载约束**：加载反馈使用不透明白色遮罩；不使用半透明、渐变或毛玻璃遮罩，避免背景层产生额外视觉竞争。

## 2. 游戏选择区

- **来源**：UX 信息模型中的 `Game`，以及多游戏间切换管理任务。
- **结构决定**：使用 `GameSelectionRailView` + 三个标准 `GameIconButton`，Button label 内保留 `GameIconContent`，不再使用旧卡片容器或独立 Rail 背景组件。
- **位置决定**：固定在左下角，方便连续切换，同时让背景中心保持完整。
- **视觉约束**：`GameSelectionRailView` 使用 `GlassEffectContainer`，游戏图标内容使用 `.glassEffect`，统一 16pt 圆角；状态圆点直接表达安装、更新、运行和失败状态。

## 3. 设置入口

- **来源**：全局配置、Wine 管理和关于信息的访问需求。
- **结构决定**：设置齿轮位于 Game Rail 下方，与游戏切换保持同一左下角操作上下文；Button 激活调用 `openSettings()`，并由 `⌘,` 提供键盘路径。
- **设计原因**：设置属于辅助操作，放在 Game Rail 下方形成稳定的左下角操作组，不与右下角主操作竞争。
- **窗口关系**：`Settings` 是独立场景，不参与 MainWindow 的 ZStack 布局，因此不会改变背景、Game Rail 或主按钮的位置。

## 4. 主操作区

- **来源**：`Game`、`GameInstaller`、`WineRuntime` 和 `CompatibilitySolution` 的状态驱动操作。
- **结构决定**：只保留一个 `PrimaryActionButton`，位于右下角；移除中心信息区和次要按钮，任务阶段和失败恢复信息附着在主操作上下文中。
- **设计原因**：右下角是用户完成选择后执行操作的稳定位置，单一按钮使“安装 / 启动 / 更新 / 修复”保持一个明确入口。
- **视觉约束**：主按钮使用 `.glassEffect` 与 `Glass.regular`，16pt 圆角；按钮文字直接传达当前状态对应的操作，不把任务完成渲染成通用成功。

## 5. 状态表达

- **Game Rail**：使用游戏图标旁的状态圆点展示所有游戏的概览。
- **PrimaryActionButton**：使用按钮语义表达当前选中游戏的下一步操作。
- **辅助流程**：安装、兼容方案和 Wine 获取继续使用 Sheet 或进度视图承载详细阶段信息。
- **辅助流程**：路径定位、兼容方案和 Wine 获取使用现有系统选择器、Sheet 或进度视图承载详细阶段信息；权限失败、取消清理和回滚验证各自保留事实。
- **不再使用**：中心状态文字、版本元信息、独立信息反馈区和次要操作菜单。

## 6. Settings 窗口

- **来源**：ADR 020 与 macOS 26 设置界面规范。
- **结构决定**：`Settings` 场景尺寸 800 × 448，使用 NavigationSplitView。
- **Sidebar**：固定 240pt，包含 6 个 Pane：通用、原神、星穹铁道、绝区零、Wine 环境、关于。
- **Detail**：使用 `Form { Section {} }` + `.formStyle(.grouped)`；只读行使用 `LabeledContent`；表单行最小高度 42pt。
- **窗口行为**：使用 `.windowStyle(.hiddenTitleBar)` 和 `.windowResizability(.contentSize)`；关闭设置窗口不影响主窗口布局或业务状态。

## 7. 材质与尺寸

- **主按钮与游戏图标**：`.glassEffect` / `Glass.regular`，16pt 圆角。
- **设置齿轮**：`.glassEffect`，位于 Game Rail 下方。
- **加载遮罩**：不透明白色。
- **窗口尺寸**：MainWindow 1280 × 688；Settings 800 × 448。

## 8. Task 4 实验决策

- 当前 56pt 玻璃面板、8pt 间距和 1.15 选中缩放会产生约 64.4pt 的玻璃投影，超过相邻中心距离 64pt；因此融合包含可测量的几何重叠原因。
- 采用稳定 64pt Button 命中框、56pt 固定玻璃面板和 12pt 游戏间距；hover/选中只放大 glyph，保留 Liquid Glass 而不放大材质层。
- 主按钮使用稳定 220 × 64pt；这为 `Locate Game`、`View Fixes`、`Launching…` 和恢复动作提供一致命中区域，并避免窗口布局随状态文案变化。
- Accessibility Tree 由各现有视图提供，背景装饰隐藏，任务进度和错误恢复作为状态节点呈现；不创建集中式 `AccessibilityTree.swift`。
- 实验矩阵、通过条件和实现阶段证据要求见 `ui-validation-and-accessibility.md`。
