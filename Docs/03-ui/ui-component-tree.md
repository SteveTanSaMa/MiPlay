# 组件布局树（Component Layout Tree）

> **文档状态**：活跃（Active）
> **UI 阶段**：界面结构设计
> **Task 4 修正**：所有图标入口使用标准 `Button`，状态反馈不创建业务状态。
> **Task 4 修正**：稳定 Button 几何、Liquid Glass 分离和辅助技术节点。
> **Product/Research 回溯修订**：2026-08-28。此前 I-4 的“全局 / 单独 Wine 版本”组件树已废止，改为固定 runtime + 共享 prefix。

---

## 主窗口组件树

```
MainWindow
├── ImmersiveBackgroundView — 全屏沉浸式背景展示
│   ├── BackgroundMediaSection — 版本主题媒体素材 [accessibilityHidden]
│   │   ├── VideoBackgroundPlayer — 动态视频背景播放
│   │   └── ImageBackgroundView — 静态图片背景
│   └── BackgroundFallbackSection — 降级背景 [accessibilityHidden]
│       └── DefaultBackgroundView — 系统默认背景
│
├── BackgroundGroupControl — 顶部居中背景组圆点控制 [仅有效组 > 1；默认 opacity 0；hover 区域触发显示]
│   ├── BackgroundRevealStrip — 顶部 40pt 悬停检测区 [仅 onHover，不拦截点击/手势]
│   │   └── BackgroundGroupButton (×N) — 标准 Button [24 × 24pt 命中框，间距 10pt]
│   │       ├── BackgroundDotView — 10pt 圆点；hover 放大/高亮仅作用于圆点内容
│   │       └── BackgroundPreviewFeedback — 预览加载失败事实（失败时显示）
│

├── GameSelectionRailView — 左下角游戏选择栏 [GlassEffectContainer, accessibility children contained]
│   └── GameIconButton (×3) — 标准 Button，命中框 64 × 64pt，间距 12pt
│       └── GameIconContent — Button label 的视觉内容 [glassEffect 56 × 56pt, cornerRadius: 16pt]
│           ├── GameIconView — 官方 icon；缺失时使用 SF Symbol 与原生黑色玻璃
│           ├── StatusOutline — 业务状态颜色描边（与图标同步变换）
│           └── SelectionMarker — 左侧 3 × 20pt 白色标记，独立表达当前选择 [accessibilityHidden]
│
├── PrimaryActionView — 右下角主操作区
│   ├── ActionButtonSection — 主操作按钮
│   │   └── PrimaryActionButton — 状态驱动的大按钮 [220 × 64pt, Glass.clear + black tint 0.18, glassEffect, cornerRadius: 16pt]
│   │       ├── ButtonLabelView — 按钮文字（定位游戏/启动/更新/查看修复方案）
│   │       ├── ButtonLoadingIndicator — 仅在真实任务进行时展示
│   │       └── TaskFeedbackView — 阶段、可信进度、失败事实、取消或重试入口 [accessibility group]
│   │           ├── TaskProgressView — phase + determinate/indeterminate progress
│   │           ├── CancelButton — 可取消任务的标准 Button
│   │           └── ErrorRecoveryView — 错误事实 + Retry/Choose Again/Reauthorize
│

└── SystemControlView — Game Rail 下方系统控制区
    └── SettingsButtonSection — 设置入口
        └── SettingsButtonView — 标准 Button 的齿轮 label [64 × 64pt, glassEffect, hover: 仅反馈]

LoadingOverlay
└── OpaqueWhiteLoadingView — 不透明白色加载遮罩 [modal progress, covers underlying focus]
```

---

## PathLocationFlow 组件树

```
PathLocationFlow
├── NSOpenPanelTrigger — 系统文件/目录选择器入口
├── PermissionFeedbackView — 访问权限事实和重新选择/授权动作
├── IntegrityFeedbackView — 完整性通过、损坏或无法确认的结果
└── TaskFeedbackView — 定位任务的等待、执行、取消、失败和重试状态
```

---

## GameDetailWindow / CompatibilitySolutionView 组件树

```
GameDetailWindow
├── GameInfoHeaderView — 当前游戏名称和英文名
├── DetailTabPicker — 游戏信息/兼容方案/性能选项
└── CompatibilitySolutionView — 当前游戏的兼容方案区
    ├── DetailHeaderSection — 兼容方案标题区
    │   ├── DetailTitleView — "兼容方案"
    │   ├── DetailSubtitleView — 当前游戏名称
    │   └── DetailCloseButton — 标准关闭 Button [hover: 仅反馈]
│
    ├── ProblemSummarySection — 问题摘要区
    │   ├── FailureReasonView — 启动失败原因描述
    │   └── DiagnosticInfoView — 诊断信息摘要
│
    ├── SolutionListSection — 方案列表区
    │   ├── SolutionCardView (×N) — 单个兼容方案卡片
    │   │   ├── SolutionNameView — 方案名称
    │   │   ├── SolutionDescriptionView — 方案简述
    │   │   ├── RiskLevelBadge — 风险等级标识（低/中/高）
    │   │   ├── ScopeLabelView — 兼容方案作用范围标识（全局/局部；非 Wine 作用范围）
    │   │   └── WineRequirementView — 所需 Wine 版本（如需要）
    │   └── SolutionApplicationRecordView — 方案应用记录
    │       ├── ApplicationStateView — Applied / RolledBack / Failed / 恢复未确认
    │       ├── AppliedTimeView — 应用时间（仅有记录时）
    │       └── RollbackButtonView — 标准回滚 Button；回滚开始后不可取消
    │
    ├── RiskConfirmationSection — 风险确认区（应用前弹窗）
    │   ├── RiskWarningView — 风险警告文字
    │   ├── ScopeImpactView — 影响范围说明
    │   └── ConfirmApplyButton — "确认应用"标准 Button [glassEffect]
    │
    └── DetailActionSection — 详情操作区
        ├── ApplySolutionButton — "应用方案"标准 Button [glassEffect]（Unavailable 或未选方案时禁用）
        └── CloseButtonView — 关闭/返回 Button；不暗示方案或游戏成功
```

---

## Settings 组件树

> **布局约束参考**：ADR 020 (独立 Settings Scene), macOS 26 规范 (sidebar 240pt, LabeledContent, 42pt 行高)
> **关键约束**：
> - 独立 `Settings` Scene，通过 `openSettings()` 打开，`⌘,` 快捷键绑定
> - 窗口尺寸 800 × 448 px，`.windowStyle(.hiddenTitleBar)`，`.windowResizability(.contentSize)`
> - 内部使用 NavigationSplitView（无 toolbar sidebar toggle 限制，因独立窗口）
> - Sidebar 宽度 240pt，列表项 24pt 行高
> - Detail 使用 `Form { Section }` + `.formStyle(.grouped)`，行高 min 42pt
> - 只读信息行使用 `LabeledContent`（macOS 13+）
> - 同一时刻仅一个设置窗口实例
> - Wine 设置不包含“全局 / 单独”作用范围、版本列表、来源选择或删除当前 runtime 的控件

```
Settings [800 × 448pt, hiddenTitleBar, contentSize]
└── NavigationSplitView
    ├── Sidebar [240pt, native List]
    │   ├── Section 应用 → 通用 / Wine 环境
    │   ├── Section 游戏 → 原神 / 星穹铁道 / 绝区零
    │   └── 关于
    └── Detail [560pt]
        ├── PageHeader → 当前页面标题 / 一行范围说明
        └── Form [grouped, scrollable, identity = selectedItem]
            ├── 通用 → 游戏运行 / 语言 / 更新 / 目录
            ├── 游戏 ×3 → 游戏 / 操作 / 性能选项
            ├── Wine → 固定版本 / 来源 Link / 运行状态 / 共享 prefix / 恢复动作
            └── 关于 → 应用版本 / 许可证 / 此 Mac
```
## WineProgressSheet 组件树

```
WineProgressSheet  [统一任务的临时反馈，不是第二个管理入口]
├── RuntimeTaskHeaderSection — 固定 runtime 身份与当前阶段
├── RuntimeProgressSection — 确定或不定进度、传输量与速度
├── SharedPrefixStateRow — 共享 prefix 准备/验证事实
└── RuntimeTaskActionSection — 单一动作槽：取消或重试；不提供版本选择/删除
```

---

### RecoveryOverlay 组件树

```
RecoveryOverlay  [重启恢复 / 路径授权刷新遮罩，Z 轴覆盖主窗口交互层]
├── RecoveryOverlayBackground — 半透明不光标遮罩，阻断底层交互
├── RecoveryContainer — 居中容器，GlassEffect
│   ├── RecoveryTitleView — 恢复阶段标题（“上次游戏状态未完成同步，正在恢复” / “正在刷新游戏路径授权”）
│   ├── RecoveryProgressView — 进度指示器（环形/不定）
│   ├── RecoveryDescriptionView — 辅助说明文本（“已保留原数据，正在重新同步状态” / “旧授权已过期，正在创建新授权”）
│   ├── RecoveryStatusRow — 具体事实行（重启恢复：进程退出确认 / 路径刷新：写回中）
│   └── RecoveryErrorView — 失败事实（恢复提交失败 / 写回失败）
└── RecoveryActionSlot — 仅当失败时显示重试 Button；恢复进行中无操作入口
```


## 2026-10-08 任务反馈组件更新

`MainTaskFeedbackView` 从主场景拆出，位于主按钮上方，宽 300pt、内边距 16pt、圆角 16pt。
只在存在启动进度或未解决恢复记录时生成；不产生空白卡片。
使用深色 `regularMaterial` 内容面板，操作按钮继续使用原生 Liquid Glass。
确定进度为阶段文字、百分比及进度条；未知进度为阶段文字和 spinner。
恢复内容为警示标题、真实 detail（最多三行，help 与 accessibility 保留全文）、重试按钮。
详情与完整验证记录见 [UI 优化修订](ui-revision-2026-10-08.md)。

## 当前实现补充：原生优化（2026-10-09）

本节覆盖早期树中与当前实现冲突的说明。游戏图标、状态描边均为固定几何；移除 GameIconScale / 自定义 hover 变换，仅保留预加载回调。游戏/设置/主按钮使用 borderless Button、系统 focusable 与 Space/Return key-down 激活。任务内容面板为 280pt 宽、12pt padding，仅真实任务期间生成。启动遮罩显示时主操作区域 disabled 且 accessibilityHidden。设置详情只显示单行页面标题，不再显示范围副标题。

`BackgroundScene` 在生命周期任务中准备播放器；未选中、scene 非 active 或 Reduce Motion 时暂停，Reduce Motion 下显示静态图。`ImageBackgroundView` 统一加载背景/主题图，body 不做磁盘 I/O。无引用的 `GameInformationView` 兼容存根已删除。完整记录见 [原生 UI 审查](ui-native-review-2026-10-09.md)。
