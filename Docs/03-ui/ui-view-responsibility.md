# View Responsibility（视图职责定义）

> **文档状态**：活跃（Active）
> **UI 阶段**：界面结构设计
> **Task 4 修正**：交互入口使用标准 Button；视图只呈现状态，不实现任务或业务判断。
> **Task 4 修正**：视图负责自身 Accessibility Tree 节点、固定几何和状态反馈语义。

---

### MainWindow

- **服务对象**：整个应用。作为应用的最外层容器，管理窗口生命周期和全局导航框架。
- **负责展示**：窗口框架（窗口控制按钮、标题栏）、Z 轴层级编排（背景层 → 内容层 → 导航层 → 操作层 → Sheet 层）、全局导航控件的布局（Game Rail、设置入口）和窗口焦点边界。
- **不负责**：不负责具体游戏内容的展示；不负责业务状态判断；不负责 Sheet 内部的内容渲染。
- **关联业务状态**：无直接关联（固定展示三款游戏，不依赖 GameLibrary 状态）。背景装饰不进入 Accessibility Tree。

---

### ImmersiveBackgroundView

- **服务对象**：GameLaunchView。提供当前选中游戏的版本主题视觉基底。
- **负责展示**：VersionBackground 素材（视频播放 / 图片渲染）；素材加载过渡状态；素材获取失败时的降级默认背景；加载反馈节点。
- **不负责**：不负责游戏切换时的背景过渡动画编排（由切换触发器协调）；不负责背景素材的下载管理；不向 VoiceOver 暴露图片、视频或材质。
- **关联业务状态**：Game（当前选中的游戏标识决定加载哪个素材）；VersionBackground（素材可用性决定展示内容或降级）。

---

---


### GameSelectionRailView

- **服务对象**：MainWindow。提供三款固定游戏的快速切换导航。
- **负责展示**：三款 64 × 64pt 标准 `GameIconButton`（Button action + 可本地化 label/value/hint + `GameIconContent` 视觉 label）；56 × 56pt 固定玻璃面板、12pt 间距、状态标识圆点、选中态和仅用于反馈的 hover/focus 状态。
- **不负责**：不负责游戏状态的聚合计算；不负责游戏图标内容的排序（固定顺序）；不负责游戏切换后背景内容的切换动画；不使用 `onTapGesture` 代替 Button。
- **关联业务状态**：Game（三款固定游戏的运行状态和安装状态，用于状态圆点标识）。

---

### PrimaryActionView

- **服务对象**：GameLaunchView。提供当前游戏状态对应的主操作入口。
- **负责展示**：稳定 220 × 64pt 的状态驱动主操作按钮（PathUnset/NotInstalled→"定位游戏" / Installed→"启动" / UpdateAvailable→"更新" / LaunchFailed→"查看修复方案" / Updating、Launching、Running→禁用），以及任务阶段、可信进度、失败、取消和重试反馈。主按钮位于右下角并保持现有 Liquid Glass 结构。
- **不负责**：不负责判断当前状态应该显示什么操作（由调用方传入）；不负责执行任务、重试策略、错误分类或业务状态转换；不把 `completed` 渲染成通用成功。
- **关联业务状态**：Game（运行状态、安装状态）；WineRuntime（就绪状态影响启动可行性）；CompatibilitySolution（可用性影响"查看修复方案"入口）。

---

### SystemControlView

- **服务对象**：MainWindow。提供应用级系统操作的常驻入口。
- **负责展示**：位于 Game Rail 下方的 64 × 64pt 标准设置 `Button`，使用固定玻璃面板；提供本地化 accessibility label/value/hint、系统 focus 和仅用于反馈的 hover。激活后调用 `openSettings()` 打开独立 `Settings` 场景，`⌘,` 作为同一入口的场景级快捷操作。
- **不负责**：不负责 Settings 的内容渲染；不负责设置数据的加载和持久化；不通过手势层处理点击。
- **关联业务状态**：无直接关联（始终可见）。

---

### PathLocationFlow

- **服务对象**：GameLaunchView。承载 `NSOpenPanel` 选择结果后的权限、路径和完整性事实。
- **负责展示**：任务 pending/running/failed/cancelled、阶段和真实进度；权限失败、`IntegrityPassed`、`IntegrityFailed`、`IntegrityUnsupported` 的可读结果；标准取消和重试 Button。
- **不负责**：不负责文件选择器、权限授权或完整性校验的执行；不把路径已选、任务完成或校验任务 `completed` 自动转换为游戏已就绪。
- **关联业务状态**：Game 的路径和完整性结果；Task 的路径定位/完整性校验状态。

---

### TaskFeedbackView / ErrorRecoveryView

- **服务对象**：MainWindow 主操作区、PathLocationFlow、GameDetailWindow 和 WineProgressSheet。
- **负责展示**：任务类型、目标、pending/running/failed/cancelled/completed、phase、可信进度、不定进度、失败事实、权限失败、Unavailable、取消清理、重试和回滚验证状态。
- **不负责**：不创建状态、不决定重试策略、不把任务 `completed` 转为业务成功；不在错误视图内执行 Domain 操作。
- **Accessibility**：进度和错误作为可读状态节点，Cancel/Retry/Choose Again/Reauthorize 为独立标准 Button；回滚开始后不提供取消。

---

### GameDetailWindow / CompatibilitySolutionView

- **服务对象**：GameLaunchView 打开的独立 `GameDetailWindow`。处理兼容方案的浏览、风险确认、应用与回滚。
- **负责展示**：启动失败原因摘要；可用和 `Unavailable` 方案列表；方案详情；`Applying` 阶段和真实进度；`Applied`、`RolledBack`、`Failed`、恢复未确认记录；风险确认、标准回滚 Button 和不可取消的恢复反馈。
- **不负责**：不负责方案应用、验证、回滚执行；不负责方案应用后的游戏状态更新；不负责方案推荐算法；不把 `Applied` 显示为游戏已启动。
- **关联业务状态**：Game（LaunchFailed — 触发条件）；CompatibilitySolution（可用方案列表）；SolutionApplication（应用记录）；GameDetailWindow 的当前 Tab。

---

### SettingsView

- **服务对象**：独立 `Settings` 场景，不依赖 MainWindow。
- **负责展示**：NavigationSplitView 双栏布局；Sidebar 240pt（6 个 Pane：通用、原神、星穹铁道、绝区零、Wine 环境、关于）；Detail 使用 `Form { Section }` + `.formStyle(.grouped)`；只读信息行使用 `LabeledContent`（macOS 13+）；表单行最小高度 42pt；每次出现相对主窗口居中。
- **不负责**：不负责配置项的验证逻辑（如依赖冲突检测）；不负责配置的持久化；不负责配置变更的即时生效触发。
- **关联业务状态**：Game（当前选中的游戏信息）；WineRuntime（运行时状态）；全局配置（所有全局配置项的值）。Sidebar、Form 控件和只读值必须保留系统 Accessibility 语义。

---

### WineProgressSheet

- **服务对象**：GameLaunchView / PathLocationFlow / Settings。展示 Wine 运行时获取的详细进度。
- **负责展示**：环形或不定进度指示；下载速度；当前阶段描述；阶段列表（已确认完成/进行中/待处理）；文件大小信息；预计剩余时间；网络状态指示；可取消任务的标准取消 Button 和失败后的重试 Button。
- **不负责**：不负责 Wine 实际下载的执行；不负责 Wine 获取完成后的状态转换。
- **关联业务状态**：WineRuntime（WineAcquiring — 获取进度；WineAcquisitionFailed — 失败原因；WineReady — 依赖准备完成）。WineReady 不等于游戏 `Running`，也不要求显示游戏成功提示。
