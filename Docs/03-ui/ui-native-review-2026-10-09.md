# MiPlay 原生 UI/UX 审查与优化

日期：2026-10-08 开始，2026-10-09 完成。负责人：Codex。
状态：代码完成；Debug 构建及 137 项回归通过；原生独立预览和部分真实输入验证完成。未宣称达到 Apple 第一方应用的全面验收标准。

## 审查依据与范围

以当前生产代码为准，检查全部 `MiPlay/UI` 文件、App/Scene、Library/Settings ViewModel 的展示状态与初始化路径。当前有效界面为主窗口、独立 Settings、启动准备遮罩、系统目录选择和 Alert。游戏详情/兼容方案独立窗口已经移除，未恢复这些历史界面。

工具链：Xcode 27.0（27A5218g），macOS 27.0 SDK；MiPlay target 实际 deployment target 为 **26.0**，Swift language mode 为 **5.0**。项目级或历史文档中的其他数字不替代 target 的有效 build settings。

本地参考：

- `References/Apple/apple-liquid-glass-docs/02-Adopting-Liquid-Glass-Guide.md`：先采用原生组件，避免无价值的全界面材质化。
- `04-SwiftUI-API-Reference.md` 与 `06-SwiftUI-Material-Reference.md`：材质、控件及玻璃 API 的参考。
- `References/Apple/macOS-26-设计规范.md`：侧栏、表单、排版和尺寸的提取参考；具体渲染交给系统控件。
- `References/Apple/DESIGN.md`：Apple 官网视觉分析，作为内容优先、减少装饰的参考，不作为 macOS 控件实现规范。

官方依据：[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)、[SwiftUI Focus](https://developer.apple.com/documentation/swiftui/focus)、[Reduce Transparency](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityReduceTransparency)。本地部分示例属于摘要，实际 API 以当前 SDK 的公开接口和编译验证为准。

## 审查与实施方案

| 优先级 / 类别 | 当前问题与修改理由 | 设计原则 / 实现 | 结果与风险 |
|---|---|---|---|
| P0 / 交互、无障碍 | 遮罩只覆盖鼠标，底下的游戏按钮仍可能接受键盘或辅助技术输入 | 模态层隔离：主操作区域 disabled + accessibilityHidden；准备标题进入辅助技术焦点 | 避免准备期间误操作；主场景集成焦点还需真实应用验收 |
| P0 / 视觉、状态 | 白色遮罩在 Dark Mode 使用默认前景；failure 无 detail 时不显示原因 | 保留用户指定白色背景，局部 light scheme + primary 前景；优先展示 failure；按 Wine/媒体阶段命名失败 | Dark Mode 静态截图文字可辨，失败原因和原生默认重试按钮可见 |
| P0 / 性能、动态效果 | 三个背景由 opacity 隐藏，但都可能播放；body 内创建/启动播放器 | 将创建与播放移到视图生命周期；仅选中且 scene active 时播放；关闭/切换暂停；Reduce Motion 使用静态图片 | 自动化验证播放器初始暂停、批量暂停与复用；未做 Instruments 帧率/耗能测量 |
| P1 / 原生交互 | 目录选择手工定位并使用 runModal，阻塞应用事件循环 | 原生 NSOpenPanel beginSheetModal；无所属窗口时 begin；沿用原 URL → ViewModel 授权路径 | 原生 Sheet 管理位置/焦点；未实测真实目录授权或 Escape 取消 |
| P1 / 视觉、交互 | 图标有额外缩放、spring、brightness 和多份 hover 状态；自定义按钮没有可靠 Tab 停靠 | 删除变换及 hover state，仅保留媒体预加载回调；borderless Button + 系统 focusable；Space/Return 在 key-down 激活 | 实际键盘、选择 trait 和系统焦点可见；保持 56pt 图标 / 64pt 命中区域 |
| P1 / 可读性 | clear 玻璃在 Increase Contrast 下仍透明，禁用主按钮前景不够明确 | Increase Contrast 或 Reduce Transparency 使用不透明深色 fallback；普通外观保留 clear 黑 tint；禁用仅降低文字强度 | 不叠加玻璃、保留既有视觉方向；系统辅助功能开关的实际切换尚未验证 |
| P1 / 信息组织 | 设置副标题、重复固定 frame、说明文字及注释行占用空间；Toggle AX 标签变成说明文字 | 移除副标题和重复 frame；原生 Section footer；缩短说明；明确 Toggle label/hint；Wine 状态提供包含名称与状态的 accessibilityRepresentation | 原生表单、更少文字；实际检查后补齐辅助技术标签 |
| P1 / 展示正确性 | 主窗口读取全局第一个恢复记录，可能显示其他游戏的恢复提示 | 仅展示当前游戏尚未解决的记录，保持原 retry 回调 | 展示与当前选择一致，不变更任务/领域状态或持久化 |
| P2 / 代码组织 | 图片在 body 内访问磁盘；主题图片与背景图片重复实现；无引用兼容存根 | task(id:) + 后台读取 Data；共享同一图片视图；删除未引用 GameInformationView；删除未使用 onRemoveGame 参数 | 文件读取不随 body 重算重复触发；未引入通用框架或第三方依赖 |

## 重要保留决策

主窗口保留沉浸背景、左下游戏栏和右下主操作。主窗口 1280 × 688pt、设置 800 × 448pt 的尺寸保留：它们是既有产品约定，并参与 AppDelegate 的窗口识别/定位。背景保持固定 1280 × 688pt 布局与 -16pt 补偿，不裁切延伸到隐藏 titlebar 的背景（见下方用户像素测量修订）；设置宽度只由 NavigationSplitView 与根窗口约束，不重复给子视图固定 frame。

游戏彩色描边是用户已有要求，继续表达业务状态；白色短条独立表达选择。系统焦点边界不通过自绘颜色或放大与选择混用。玻璃范围仍限于主窗口浮动操作，不加全屏 scrim、永久状态卡片、独立详情或管理面板。

任务反馈仅真实任务/恢复期间出现，缩至 280pt 宽、12pt padding，继续使用普通 regularMaterial 内容层；Increase Contrast/Reduce Transparency 使用不透明深色 fallback。进度直接展示既有事实，不伪造百分比，不新增业务事件。

设置窗口继续使用原生 List / NavigationSplitView / grouped Form，保留同一时刻一个设置窗口、点击主窗口关闭设置和 main/key 分离的既有行为。Wine 的来源保留用户指定的完整可点击仓库 URL；“共享 prefix”展示名改为“共享游戏环境”。

## 主要代码

- `UI/MainWindow/GameSelectionRailView.swift`：去掉自定义变换/hover 状态，系统焦点及键盘激活，异步官方图标读取，去掉错误的“设置未打开”固定 accessibilityValue。
- `UI/Components/PrimaryActionButton.swift`、`DarkGlassSurface.swift`：系统键盘焦点、明确 Disabled 前景、减少动态效果与高对比/减少透明度 fallback。
- `UI/MainWindow/MainWindowScene.swift`、`MainTaskFeedbackView.swift`：启动遮罩隔离、当前游戏恢复反馈、原生目录 Sheet、减少临时反馈占用。
- `UI/MainWindow/BackgroundView.swift`、`UI/Components/BackgroundScene.swift`：单一背景切换动画、父布局裁切、异步图片读取、播放器生命周期控制；合并主题图片实现。
- `UI/Components/StartupPreparationOverlay.swift`：固定白底下的语义前景、失败文本、标题辅助技术焦点与默认重试动作。
- `UI/SettingsWindow/SettingsWindowScene.swift`、`SettingsAppViews.swift`、`SettingsGameView.swift`、`SettingsWineView.swift`：简化导航/表单、说明文案及辅助技术标签。
- 删除 `UI/MainWindow/GameInformationView.swift`：无引用的空兼容存根。
- `MiPlayTests/UIReadinessTests.swift`：增加播放器生命周期回归，不改变其他测试断言。

没有改动 ViewModel、Domain、Infrastructure、数据 schema、游戏下载、游戏启动或持久化行为。

## 编译与实际验证

证据目录：`QAArtifacts/UI-Native-20261008/`（沿用任务开始日期命名）。

- `build.log`：Debug arm64 build 成功。
- `tests-final.log`：最终 Debug arm64 137 tests / 0 failures；包含已有窗口焦点/状态回归和新增播放器创建暂停/复用/批量暂停测试。最终日志仅显示无 AppIntents 依赖时跳过元数据提取的提示；独立 swiftc 预览编译另有既有弃用/多余 await 警告，不表述为零警告。
- `Preview.swift` 与 `build_preview.py`：直接编译生产 UI 与隔离依赖，运行于原生 NSHostingView / NSWindow。Settings 使用临时 FileSystem/Persistence 目录；未调用 MiPlayApp 的启动初始化或游戏启动。
- 静态截图：浅/深背景控件、通用设置 Light/Dark、原神/Wine/关于详情、Dark Mode 下白色准备与失败状态、官方主题背景的空闲/任务状态。
- computer use 实际输入：点击游戏后 selection trait / value 更新；Tab、Shift-Tab 在游戏、设置及主按钮之间导航；Space/Return 切换游戏；主按钮 Space 后回调计数 1、Return 后计数 2，未发生重复调用；系统焦点边界可见。
- Settings 实际输入：侧栏点击通用→原神→Wine，Down 键从 Wine 进入原神；通用 Form 滚动到末尾，滚动条 value 从 0 到 1；未定位游戏的检查/校验按钮确认为 disabled。
- AX 树核对后，为多行 Toggle 补充明确 label/hint；该检查不等同于 VoiceOver 实际朗读。

第一次异步图片预览暴露空 Group 未触发 task，已改为稳定 ZStack 承载并重新截图；第一次 focusable 复验暴露 Space 未激活，已为 Space/Return 添加 key-down 路由并完成上述实际复验。修复后才保留最终截图为当前证据。

## 尚未验证与后续建议

- 未启动 VoiceOver，未切换全局 Reduce Motion / Reduce Transparency / Increase Contrast。运行环境三项均为 false；只完成相应代码路径审查和播放器回归。它们是系统只读环境值，未以伪造的 environment override 宣称通过。
- 未对完整 MiPlay 启动流程、遮罩的真实焦点迁移、⌘,、目录 Sheet 的 Escape/授权、长错误信息进行系统端到端验收。
- 背景视频的暂停/静态退化已实现和单元验证；真实视频切换、首帧及窗口失活后的播放视觉仍需检查。未运行 Instruments，不量化性能改善。
- 仍使用固定窗口尺寸和经像素测量确定的 -16pt 标题栏居中补偿；未来若支持缩放，应单独修订窗口识别和背景布局契约。

建议下一轮优先完成真实应用的 VoiceOver 与三项系统辅助功能验收，再根据实际观感决定是否调整 clear 玻璃参数。保留此前工作区修改，未创建 Git 提交。


## 用户像素测量修订：回退背景布局（2026-10-09）

用户反馈原生优化后主窗口上方出现白条。此前把 BackgroundView 的固定 frame 改成父布局填充并新增 clipped，破坏了隐藏 titlebar 的背景覆盖约定。本轮只恢复 `.frame(width: 1280, height: 688)` 并移除背景容器的 `.clipped()`，保留原生控件、图片异步读取、播放器生命周期和 Reduce Motion 等其他优化。

用户确认：总高度 720 包含隐藏 titlebar 的三十几像素和原内容区的六百八十多像素；居中后需要向上补偿十几像素。生产代码三层媒体已有的 `offset(y: -16)` 是像素级测量结果，必须保留，不应当作为任意历史偏移清理。`ui-screen-inventory.md` 仍保留固定 BackgroundView frame 的旧约束；720/隐藏标题栏的具体解释以此次用户说明补齐。

本次几何回退 Debug arm64 构建通过（`QAArtifacts/UI-Native-20261008/background-layout-rollback-build.log`），不重复全量业务测试。前述 137 项测试属于回退前的原生优化验证；真实 SwiftUI 主窗口的白条消除效果尚待运行确认，不能用无标题栏的独立预览替代。
