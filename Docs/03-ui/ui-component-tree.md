# 组件布局树（Component Layout Tree）

> **文档状态**：活跃（Active）
> **UI 阶段**：界面结构设计
> **Task 4 修正**：所有图标入口使用标准 `Button`，状态反馈不创建业务状态。
> **Task 4 修正**：稳定 Button 几何、Liquid Glass 分离和辅助技术节点。

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

├── GameSelectionRailView — 左下角游戏选择栏 [GlassEffectContainer, accessibility children contained]
│   └── GameIconButton (×3) — 标准 Button，命中框 64 × 64pt，间距 12pt
│       └── GameIconContent — Button label 的视觉内容 [glassEffect 56 × 56pt, cornerRadius: 16pt]
│           ├── GameIconView — glyph，hover/选中仅变换此内容
│           └── StatusDotView — 状态标识圆点（不单独进入 Accessibility Tree）
│
├── PrimaryActionView — 右下角主操作区
│   ├── ActionButtonSection — 主操作按钮
│   │   └── PrimaryActionButton — 状态驱动的大按钮 [220 × 64pt, Glass.regular, glassEffect, cornerRadius: 16pt]
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
    │   │   ├── ScopeLabelView — 作用范围标识（全局/局部）
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

```
Settings  [800 × 448, hiddenTitleBar, contentSize]
│
└── NavigationSplitView  [无 sidebar toggle 限制]
    │
    ├── Sidebar  [固定 240pt, 列表项 24pt]
    │   └── List(selection: $selectedPane)
    │       ├── PaneItem — "通用" (gearshape)
    │       ├── PaneItem — "原神" (gamecontroller)
    │       ├── PaneItem — "星穹铁道" (gamecontroller)
    │       ├── PaneItem — "绝区零" (gamecontroller)
    │       ├── PaneItem — "Wine 环境" (wineglass)
    │       └── PaneItem — "关于" (info.circle)
    │
    └── Detail  [Form + .formStyle(.grouped), padding(32)]
        ├── GeneralPaneView  [通用]
        │   ├── Section "语言" → Picker
        │   ├── Section "更新与版本" → Toggle
        │   └── Section "系统环境" → LabeledContent [行高 min 42pt]
        │
        ├── GamePaneView(×3)  [单款游戏，按选中切换]
        │   ├── Section "基本信息" → LabeledContent
        │   ├── Section "安装状态" → LabeledContent
        │   └── Section "兼容方案" → caption
        │
        ├── WinePaneView  [Wine 环境]
        │   ├── Section "运行时状态" → LabeledContent
        │   └── Section "已安装版本" → list
        │
        └── AboutPaneView  [VStack 居中, spacing >= 20]
            ├── AppIconView — 应用图标 (64pt)
            ├── AppNameView — "MiPlay"
            ├── VersionInfoView — 版本 + 构建号
            ├── LicenseView — 许可证
            ├── Divider
            └── DescriptionView — 描述文字
```
## WineProgressSheet 组件树

```
WineProgressSheet
├── SheetHeaderSection — Sheet 标题区
│   ├── SheetTitleView — "正在准备运行环境"
│   └── SheetSubtitleView — 当前触发的操作描述（启动/路径定位）
│
├── ProgressVisualSection — 进度可视化区
│   ├── ProgressRingView — 确定或不定进度指示，取决于真实进度
│   ├── ProgressPercentageView — 仅在可估算时显示百分比
│   └── DownloadSpeedView — 下载速度
│
├── StageDescriptionSection — 阶段描述区
│   ├── CurrentStageLabel — 当前阶段文字（下载中/校验中/解压中）
│   └── StageProgressListView — 阶段列表
│       └── StageItemView (×N) — 单个阶段项（已完成/进行中/待处理）
│
├── StatusDetailSection — 状态细节区
│   ├── FileSizeInfoView — 文件大小信息
│   ├── EstimatedTimeView — 预计剩余时间
│   └── NetworkStatusView — 网络状态指示
│
└── SheetActionSection — 底部操作区
    ├── CancelButtonView — 可取消任务的标准 Button
    └── RetryButtonView — 可恢复失败的标准 Button
```
