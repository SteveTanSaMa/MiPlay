# Research — Pattern Library

> **接收方：** 所有 Agent
> **内容：** 事实性模式参考库 — 从 References/ 中提炼的可复用模式
> **要求：** 至少 10 个模式，覆盖 UI / Interaction / Architecture / State 四类

> **事实分层：** 模式来源可能是历史参考项目、当前 `MiPlay/` 实现或 Apple 平台规范；“来源”字段标明依据，模式本身不自动表示 MiPlay 已采用。

---

## UI Patterns

### UI-1：全屏沉浸式背景

| 属性 | 描述 |
|------|------|
| **类别** | UI — 布局 |
| **来源** | YAAGL（`app.css: .background/.background-video`）、MiPlay 当前实现（`MiPlay/UI/MainWindow/BackgroundView.swift`、`MiPlay/UI/Components/BackgroundScene.swift`）、Apple Web Design（产品 tile） |
| **描述** | 应用内容以全屏背景素材为基础，UI 控件叠加在背景之上。背景可以是图片、视频或主题装饰层。YAAGL 使用三层结构：video(z-index:-2) → theme(z-index:-1) → 内容；MiPlay 使用 ZStack 层叠。 |
| **优点** | 视觉效果强烈，与游戏/产品主题产生情感关联；内容区域最大化 |
| **缺点** | 背景素材需要网络下载和本地处理；文字可读性需要额外保障（渐变遮罩/文字阴影） |
| **适用条件** | 应用以展示内容为主、操作控件较少时适用；每屏操作点 ≤ 5 个时效果最佳 |

### UI-2：底部操作栏布局

| 属性 | 描述 |
|------|------|
| **类别** | UI — 布局 |
| **来源** | YAAGL（`launcher/index.tsx`：Flex bottom area）、MiPlay 当前实现（`MiPlay/UI/MainWindow/MainWindowScene.swift`：底部 `HStack` + `PrimaryActionButton`） |
| **描述** | 主操作按钮位于主窗口底部操作区的右侧，游戏选择栏位于同一底部行的左侧。当前 MiPlay 通过 `VStack` 的底部区域、`HStack`、`Spacer()` 和底部 padding 实现，不是居中按钮。 |
| **优点** | 不干扰背景展示；符合"底部操作栏"的移动端和桌面端通用习惯；大屏幕右下角自然符合 Fitts 定律 |
| **缺点** | 按钮远离内容中心区域；超宽屏幕下右下角按钮可能偏离视觉中心 |
| **适用条件** | 沉浸式全屏布局、主操作单一（1-2 个按钮）的场景 |

### UI-3：标签化配置面板

| 属性 | 描述 |
|------|------|
| **类别** | UI — 信息组织 |
| **来源** | YAAGL（`config/index.tsx`：垂直 Tabs）、MiPlay 当前设置窗口（`MiPlay/UI/SettingsWindow/SettingsWindowScene.swift`：NavigationSplitView sidebar）、macOS 26 设计规范（工具窗口 Tab 栏 30px） |
| **描述** | 大量配置项时使用 Tab 导航进行分组组织。YAAGL 使用 @hope-ui/solid 的垂直 Tabs（General / Game / Wine / Advanced / Licenses）；macOS 标准使用 30px 水平 Tab 栏。 |
| **优点** | 分类清晰，大量配置项可扩展；垂直 Tab 适合多类别（>4），水平 Tab 适合少类别（≤4） |
| **缺点** | 需要额外 Tab 切换操作；少量常用配置可能被埋入深层 Tab |
| **适用条件** | 配置项 ≥ 10 个且可自然分组的场景 |

### UI-4：药丸形操作按钮

| 属性 | 描述 |
|------|------|
| **类别** | UI — 组件 |
| **来源** | Apple Web Design（`button-primary` 圆角 pill 9999px）、macOS 26 设计规范（胶囊按钮 100px） |
| **描述** | 操作按钮使用大圆角（pill/胶囊形状）作为视觉特征。Apple 使用 `border-radius: 9999px` 作为所有主 CTA 的标志性形状。macOS 原生也使用圆角 100px 的按钮。 |
| **优点** | 视觉识别度高，一眼可识别为可操作元素；Apple 品牌用户熟悉 |
| **缺点** | 在非操作元素（如卡片、容器）上使用会混淆交互语义；直立文本在极高圆角下视觉不平衡 |
| **适用条件** | 主要操作按钮、主 CTA、配置选择芯片（configurator chip） |

### UI-5：文字背景可读性保障层

| 属性 | 描述 |
|------|------|
| **类别** | UI — 覆盖层 |
| **来源** | YAAGL（`text-shadow: 1px 1px 2px #333`）、MiPlay 历史参考（`References/MiPlay/Views/Components/ReadabilityOverlay.swift`）、MiPlay 当前背景层（`MiPlay/UI/Components/BackgroundScene.swift`）、Landmarks（`ReadabilityRoundedRectangle`） |
| **描述** | 在动态背景（视频/图片）上叠加文字时使用额外的视觉处理确保可读性。YAAGL 使用白色文字 + 深色文字阴影；MiPlay 使用底部渐变 overlay；Landmarks 使用半透明圆角矩形衬底。 |
| **优点** | 保障动态背景上文字始终可读；不同方法适用于不同场景 |
| **缺点** | 文字阴影在高对比背景上可能显得突兀；渐变 overlay 会改变背景视觉效果 |
| **适用条件** | 动态/不可预测背景上的文字展示 |

### UI-6：自适应材质层（Adaptive Material Layer）

| 属性 | 描述 |
|------|------|
| **类别** | UI — 材质与层级 |
| **来源** | Apple Liquid Glass（`References/Apple/apple-liquid-glass-docs/`）、macOS 26 设计规范（`References/Apple/macOS-26-设计规范.md`）、Landmarks（`References/LandmarksBuildingAnAppWithLiquidGlass/`） |
| **描述** | 利用 macOS 26 的 Liquid Glass API 建立界面层级。当前 MiPlay 的采用方式是 `glassEffect(_:in:)`、`Glass.regular.interactive(true)` 与 `GlassEffectContainer`，应用于游戏选择栏、状态图标和主操作按钮。`Material.regular`、`.ultraThinMaterial` 等旧 Material API 是平台参考能力，不是当前 MiPlay 的实现描述。关键原则：(1) 玻璃效果只用于需要表达交互或层级的元素；(2) 使用形状参数明确玻璃边界；(3) 始终确保动态背景上的内容可读性。 |
| **优点** | 视觉层次天然清晰；自适应明/暗模式和桌面背景；减少固定颜色和阴影的维护成本；符合 macOS 平台原生外观 |
| **缺点** | 动态材质有 GPU 开销；材质效果依赖底层背景内容，在某些背景上可读性可能下降；过度使用材质（所有元素都上玻璃效果）会失去层次感 |
| **适用条件** | 追求 macOS 原生感的桌面应用；需要表达 UI 层次但又不想引入视觉噪声的场景；当前 MiPlay 的游戏选择栏和主操作按钮等交互控件。 |

---

## Interaction Patterns

### INT-1：任务队列状态解耦

| 属性 | 描述 |
|------|------|
| **类别** | Interaction — 异步操作 |
| **来源** | YAAGL（`launcher/task-queue.ts`：AsyncGenerator + Signal） |
| **描述** | 将耗时异步操作与 UI 状态更新解耦。操作以 `AsyncGenerator` 形式定义，通过 yield 输出状态更新指令（`["setProgress", n]` / `["setStateText", key]`），由 Task Queue 统一管理执行和状态推送。 |
| **优点** | 避免异步操作与 UI 状态更新之间的竞态；任务串行执行，无并发冲突；进度推送与操作解耦 |
| **缺点** | 生成器代码可读性较差；需要维护队列生命周期（start/complete/error） |
| **适用条件** | 多个可能互相冲突的异步耗时操作（安装/更新/启动/完整性检查） |

### INT-2：状态驱动按钮语义

| 属性 | 描述 |
|------|------|
| **类别** | Interaction — 状态表达 |
| **来源** | YAAGL（`installState() == "INSTALLED"` 判断）、MiPlay 当前实现（`LibraryViewModel.PrimaryButtonState` 动态文字和操作） |
| **描述** | 主操作按钮的文字、图标、行为根据当前状态动态变化。例如：游戏未安装时显示"安装" → 安装中显示"下载中"（禁用）→ 已安装显示"开始游戏" → 需更新显示"更新游戏"。 |
| **优点** | 单一入口适配所有状态，减少用户界面复杂度；状态变更自然映射到交互变更 |
| **缺点** | 状态边界情况需要精确处理；用户可能对状态变化感到困惑（如从"开始游戏"突变为"更新游戏"） |
| **适用条件** | 单一主操作入口需要适配多个状态 |

### INT-3：双队列优先级分离

| 属性 | 描述 |
|------|------|
| **类别** | Interaction — 任务调度 |
| **来源** | YAAGL（`launcher/index.tsx`：`taskQueue` + `nonUrgentTaskQueue`） |
| **描述** | 将主要操作（安装/更新/启动）和后台操作（预下载/完整性检查）分为两个独立的任务队列。主队列持有操作锁（`programBusy()`），后台队列不影响主操作。 |
| **优点** | 后台任务不阻塞主操作；用户可同时进行预下载和当前游戏启动 |
| **缺点** | 需要管理两个队列的状态同步（如预下载完成时主队列状态是否需要更新） |
| **适用条件** | 存在可后台执行的耗时操作且不应影响主操作 |

### INT-4：预下载提示 Popover

| 属性 | 描述 |
|------|------|
| **类别** | Interaction — 通知 |
| **来源** | YAAGL（`launcher/index.tsx`：Popover + `showPredownloadPrompt`） |
| **描述** | 当新版本可预下载时，在启动按钮上方弹出 Popover 提示用户。用户可点击开始预下载，也可关闭提示（`dismissPredownload`）。提示条件：预下载可用 + 当前未下载 + 版本号大于当前。 |
| **优点** | 非侵入式的上下文提示；用户可选择忽略或执行；提示位置紧邻操作按钮 |
| **缺点** | Popover 可能在点击时意外关闭（`closeOnBlur=true`） |
| **适用条件** | 需要用户注意但不紧急的操作建议 |

---

## Architecture Patterns

### ARCH-1：插件化客户端架构

| 属性 | 描述 |
|------|------|
| **类别** | Architecture — 模块化 |
| **来源** | YAAGL（`clients/` 目录：每个游戏一个 ChannelClient 实现） |
| **描述** | 每个游戏（或游戏版本）作为一个独立的 ChannelClient 模块实现，通过统一的接口暴露。应用启动时根据环境变量（`YAAGL_CHANNEL_CLIENT`）加载对应的客户端模块。所有客户端共享通用的基础设施层（Wine、下载、配置）。 |
| **优点** | 新增游戏支持只需新增客户端模块；不同游戏的特殊处理（安装/更新/启动逻辑）隔离在各自模块中；共享基础设施减少重复代码 |
| **缺点** | 公共接口需要足够抽象以覆盖所有游戏差异；特定游戏的功能泛化到公共接口时的过度设计风险 |
| **适用条件** | 多产品线（3+ 产品或变体）需要统一平台管理的场景 |

### ARCH-2：Actor 隔离的服务层

| 属性 | 描述 |
|------|------|
| **类别** | Architecture — 并发 |
| **来源** | MiPlay 当前实现（`Infrastructure/Process/ProcessManager.swift`、`Infrastructure/Wine/WineRuntimeProvider.swift`、`Infrastructure/Persistence/PersistenceStore.swift`） |
| **描述** | 对共享资源（进程、文件系统）的操作封装在 Swift `actor` 中，保证线程安全。每个 actor 管理自己的状态，通过 async 方法暴露给外部。进程管理、Wine 版本管理、配置持久化分别独立 actor。 |
| **优点** | 编译器级线程安全；天然防止数据竞争；actor 隔离简化并发推理 |
| **缺点** | actor 间调用需要跨 actor 边界，增加一定的调用开销；需要避免 actor 间的循环依赖 |
| **适用条件** | Swift 原生项目需要管理共享可变状态或系统资源 |

### ARCH-3：后端辅助的增量更新系统

| 属性 | 描述 |
|------|------|
| **类别** | Architecture — 更新分发 |
| **来源** | YAAGL（sophon_server/ + sophon.ts） |
| **描述** | 使用独立的 Python 后端服务（sophon_server）管理游戏增量更新。Sophon 协议处理版本差异计算、增量包分发、文件完整性验证。启动器通过 HTTP 连接 sophon 服务获取更新信息，使用 aria2 进行多线程下载。 |
| **优点** | 增量更新大幅减少下载量；服务端和客户端分离可独立演进；aria2 多线程加速下载 |
| **缺点** | 需要维护独立的服务器端组件；需要管理 sophon 进程生命周期；网络依赖性强 |
| **适用条件** | 大型游戏客户端需要高效的版本更新 |

### ARCH-4：中性数据源 + 环境注入

| 属性 | 描述 |
|------|------|
| **类别** | Architecture — 数据流 |
| **来源** | Landmarks（`ModelData @Observable` + `@Environment` injection） |
| **描述** | 应用级数据模型使用 `@Observable` 声明为单一数据源（Single Source of Truth），通过 SwiftUI 的 `@Environment` 注入到视图层级中。所有视图从同一个 ModelData 实例读取状态，修改通过其方法统一操作。 |
| **优点** | 数据流单向清晰；状态变更在所有视图中自动反映；SwiftUI 系统级支持 |
| **缺点** | @Observable 宏假设所有属性变更都需要通知视图；大量观察属性可能导致冗余更新；需注意 @MainActor 约束 |
| **适用条件** | 中小型 SwiftUI 应用（1-3 个数据源） |

---

## State Patterns

### STATE-1：信号驱动的响应式状态

| 属性 | 描述 |
|------|------|
| **类别** | State — 状态管理 |
| **来源** | YAAGL（SolidJS `createSignal` + `batch()`） |
| **描述** | 所有可变状态被包装为 Signal（`[getter, setter]` 对）。UI 从 Signal 读取，状态变更时自动触发相关 UI 重渲染。批量变更使用 `batch()` 合并多次 setter 调用为一次渲染。派生状态使用 `() => expression` 计算属性。 |
| **优点** | 细粒度响应更新，只重渲染依赖变更的部分；无需 Virtual DOM diff；声明式编程模型 |
| **缺点** | Signal 需要显式追踪依赖；闭包中的 Signal 读取需要在渲染阶段进行才能被正确追踪 |
| **适用条件** | SolidJS 项目、细粒度响应 UI |

### STATE-2：异步生成器进度通道

| 属性 | 描述 |
|------|------|
| **类别** | State — 状态传递 |
| **来源** | YAAGL（`CommonUpdateProgram` 类型：`AsyncGenerator<unknown, void, () => CommonUpdateProgram>`） |
| **描述** | 耗时操作（安装/更新/启动）定义为异步生成器函数，通过 yield 输出进度元组 `["setProgress", 50]` / `["setStateText", "DOWNLOADING"]`。Task Queue 消费这些 yield 值并更新对应的 Signal。 |
| **优点** | 操作定义与状态更新逻辑共处一处；进度信息类型安全（元组协议）；生成器可组合（`yield*` 子生成器） |
| **缺点** | 生成器语法在复杂操作中可读性下降；错误处理需要在生成器内外分别处理 |
| **适用条件** | 长耗时、多阶段、需要逐步反馈的异步操作 |

### STATE-3：@Observable 属性级观察

| 属性 | 描述 |
|------|------|
| **类别** | State — 响应式绑定 |
| **来源** | MiPlay 当前实现（`MiPlay/UI/ViewModels/LibraryViewModel.swift`）、Landmarks（`@Observable @MainActor class ModelData`） |
| **描述** | Swift 6 的 `@Observable` 宏自动为类的存储属性生成观察访问器。当前 MiPlay 在 ViewModel、部分 Domain 服务和组件状态对象中使用该模式；视图通过构造器持有 ViewModel，未使用 YAAGLSWIFTUI 的 `@Environment(Service.self)` 作为主应用 DI 模式。 |
| **优点** | 编译器级观察追踪，零运行时开销；无需手动标记可观察属性；属性级细粒度更新 |
| **缺点** | 仅支持引用类型（class）；@MainActor 约束意味着主线程更新；Swift 6 最低部署版本要求 |
| **适用条件** | Swift 6+ 项目、需要细粒度状态观察的 ViewModel 层 |

### STATE-4：流程状态机枚举

| 属性 | 描述 |
|------|------|
| **类别** | State — 状态机 |
| **来源** | MiPlay 当前实现（`Domain/Game/GameStateMachine.swift`、`Domain/Game/GameConstants.swift`）、MiPlay Product Domain（`Per-Game 状态` 表：PathUnset / NotInstalled / Installed / GameUpdating / UpdateAvailable / Launching / Running / LaunchFailed） |
| **描述** | 业务流程中的状态通过有限状态机枚举表达，状态之间的转换受规则约束。MiPlay 的 GameInstallStatus 有 5 个状态（notInstalled / downloading / installed / needsUpdate / broken）；产品定义则有 8 个 per-game 状态。 |
| **优点** | 状态转换清晰可预测；非法状态转换在编译期或运行时易检测；系统行为易于形式化验证 |
| **缺点** | 状态数量增加时枚举组合爆炸；需要处理外部事件触发的状态转换（如游戏进程意外退出） |
| **适用条件** | 具有明确生命周期和状态转换的实体 |

### UI-7：Liquid Glass 交互控件组合

| 属性 | 描述 |
|------|------|
| **类别** | UI — Liquid Glass |
| **来源** | MiPlay 当前实现（`GameSelectionRailView.swift`、`PrimaryActionButton.swift`） |
| **描述** | 使用 `GlassEffectContainer` 组合多个玻璃元素，并用 `glassEffect(in:)` 为单个图标或按钮指定形状；主按钮额外使用 `Glass.regular.interactive(true)` 表示交互态。当前项目采用该 API 组合，不使用历史 `.buttonGlass()` 或 `.regularMaterial` 描述当前控件。 |
| **优点** | 与 macOS 26 SwiftUI API 对齐；玻璃边界和交互态显式；可以让相邻玻璃元素在同一容器中协调渲染 |
| **缺点** | 依赖 macOS 26 API；动态背景可能影响对比度；容器和形状边界需要与布局一起验证 |
| **适用条件** | 需要在沉浸式背景上保留少量高辨识度交互控件的场景 |

### INT-5：独立 Settings Scene

| 属性 | 描述 |
|------|------|
| **类别** | Interaction — macOS 窗口流程 |
| **来源** | MiPlay 当前实现（`MiPlay/MiPlayApp.swift`、`MiPlay/UI/SettingsWindow/SettingsWindowScene.swift`） |
| **描述** | 使用 SwiftUI `Settings` Scene 注册设置窗口，通过 `openSettings()` 从主窗口打开；设置内容内部使用 `NavigationSplitView`，而不是主窗口内的设置 overlay 或 `.sheet`。 |
| **优点** | 符合 macOS 设置窗口和 `⌘,` 入口语义；设置生命周期与主窗口分离；主窗口保持沉浸式操作流 |
| **缺点** | 用户需要在主窗口与设置窗口之间切换；设置状态和主窗口状态需要通过 ViewModel/服务保持一致 |
| **适用条件** | 设置项较多、需要独立窗口承载、且主窗口强调内容沉浸的 macOS 应用 |


---

## YAAGLSWIFTUI 模式

### UI-10：GameConfigSection / GameConfigItem 枚举驱动配置 UI

| 属性 | 描述 |
|------|------|
| **类别** | UI — 动态配置表单 |
| **来源** | YAAGLSWIFTUI（`GameClientProtocol.swift`：`GameConfigSection` + `GameConfigItem` 枚举） |
| **描述** | 配置 UI 由 GameClient 协议的方法 `configSections() -> [GameConfigSection]` 驱动。`GameConfigSection` 包含 `id`、`title`、`items: [GameConfigItem]`。`GameConfigItem` 是一个枚举，变体包括 `.toggle(id:title:isOn:action)`、`.textField(id:title:value:action)`、`.picker(id:title:options:selection:action)`、`.info(id:title:value)`。视图层根据枚举变体选择性地渲染对应的 SwiftUI 控件。 |
| **优点** | 游戏特定的配置项由其 Client 自我描述，新增游戏时配置 UI 自动扩展；枚举保证配置类型的安全检查；服务端无需定义配置模型的变体代码 |
| **缺点** | 枚举变体的 action 闭包会持有引用，需注意循环引用；变体数量有限，复杂配置布局需要扩展枚举；闭包调试相对困难 |
| **适用条件** | 多实体需要各自定义配置表单、且每个实体的配置项类型有限时 |

### STATE-5：AsyncThrowingStream 进度通道

| 属性 | 描述 |
|------|------|
| **类别** | State — 异步进度传递 |
| **来源** | YAAGLSWIFTUI（`DownloadTask.swift`：`ProgressEvent` 枚举 + `AsyncThrowingStream<ProgressEvent, Error>`） |
| **描述** | 耗时操作为视图层提供 `AsyncThrowingStream<ProgressEvent, Error>` 作为进度通道。`ProgressEvent` 枚举定义多个变体：`.download(DownloadProgress)`（带速度的下载进度）、`.extraction(current:total:)`（解压进度）、`.patch(current:total:)`（补丁进度）、`.integrityCheck(current:total:)`（校验进度）、`.message(String)`（文字状态）、`.indeterminate`（不确定进度）、`.completed`（完成）、`.failed(Error)`（失败）。视图层通过 `for try await event in stream` 消费事件。 |
| **优点** | 类型安全的进度协议；变体可扩展；与 Swift 异步生态原生兼容；视图层统一消费方式 |
| **缺点** | 相比 YAAGL 的 AsyncGenerator + yield 元组更冗长；Enum 模式匹配需要 exhaustive switch；`AsyncThrowingStream` 的生命周期管理（finish 遗漏）容易造成内存泄漏 |
| **适用条件** | 需要逐步反馈的异步操作（下载、解压、校验、补丁应用等） |

### STATE-6：@Observable Service 即状态持有者（无 ViewModel）

| 属性 | 描述 |
|------|------|
| **类别** | State — 状态管理架构 |
| **来源** | YAAGLSWIFTUI（所有 Service 使用 `@Observable final class`，无独立 ViewModel 层） |
| **描述** | Service 层同时承担业务逻辑和状态持有者的双重角色。Service 的属性（如 `GameService.statusText`、`ConfigService.config`）直接通过 `@Observable` 宏发布变更。视图通过 `@Environment(Service.self)` 注入这些 Service，SwiftUI 自动追踪视图读取了哪些属性并仅在那些属性变化时重渲染。 |
| **优点** | 减少 ViewModel 抽象层；属性级细粒度更新（`@Observable` 优于 `ObservableObject` 的 objectWillChange）；适合中等复杂度的应用；Service 自然成为单一数据源 |
| **缺点** | Service 职责边界模糊（业务逻辑 + UI 状态耦合）；多视图共享同一 Service 实例时状态突变追踪困难；大 Service 的可测试性下降；无法像 ViewModel 那样为每个视图独立裁剪状态 |
| **适用条件** | 中等复杂度 SwiftUI 应用（<10 个 Service 类型），团队偏好扁平架构 |

### ARCH-5：EnvironmentKey + AppContext 双重 DI

| 属性 | 描述 |
|------|------|
| **类别** | Architecture — 依赖注入 |
| **来源** | YAAGLSWIFTUI（`AppContext.swift` + `EnvironmentKeys.swift` + `YAAGLSWIFTUIApp.swift` 的 `.environment()` 注入） |
| **描述** | 结合中央容器（AppContext）和 SwiftUI Environment 的双重 DI 模式。AppContext 在 `init()` 中按依赖顺序构造所有 Service；在 App 入口处通过 `.environment()` 将每个 Service 以自身类型为 key 注入 Environment；视图端通过 `@Environment(ConfigService.self)` 按需获取。每个 Service 的 `EnvironmentKey.defaultValue` 为避免可选绑定提供了默认值（但默认值是独立实例，需要在实际注入时替换）。 |
| **优点** | 视图层注入无感——无需手动传递；类型安全（key 就是 Service 自身的类型）；视图按需声明依赖；SwiftUI 系统级支持 |
| **缺点** | 每个 Service 需要约 15 行样板代码（private struct Key + extension EnvironmentValues）；defaultValue 模式鼓励独立实例，可能被误用；环境继承栈深时调试困难；视图层不易看到完整的依赖关系图 |
| **适用条件** | SwiftUI 为主架构的应用，Service 数量中等（5-10 个），团队偏好 Environment 生态 |

### ARCH-6：LockedDictionary 非 actor 线程安全

| 属性 | 描述 |
|------|------|
| **类别** | Architecture — 并发 |
| **来源** | YAAGLSWIFTUI（`LockedDictionary.swift`：NSLock + `@unchecked Sendable` 模式） |
| **描述** | 使用 `NSLock` + `@unchecked Sendable` 实现线程安全的字典容器，用于需要在非主线程访问的共享可变状态（如 `ActiveTasksStore`）。提供 `subscript`、`removeValue(forKey:)`、`allValues`、`removeAll()` 方法，所有操作通过 `lock.withLock { }` 序列化访问。 |
| **优点** | 轻量级，无 actor 重新入栈开销；`@unchecked Sendable` 灵活绕过 strict concurrency 检查；接口简单，适合作为集合的线程安全包装 |
| **缺点** | `@unchecked Sendable` 将安全性保证完全交给开发者；NSLock 可能导致死锁（reentrant lock 场景需要 NSRecursiveLock）；不支持 async 上下文中的锁等待（相比 actor 模型） |
| **适用条件** | 小规模共享可变集合（如活跃任务映射表），且不需要 async 上下文协调的场景 |

### ARCH-7：NavigationSplitView 单窗口导航

| 属性 | 描述 |
|------|------|
| **类别** | Architecture — 导航 |
| **来源** | YAAGLSWIFTUI（`RootView.swift`：`NavigationSplitView` + `columnVisibility: .all`） |
| **描述** | 使用 SwiftUI 的 `NavigationSplitView` 实现浏览器类应用的导航结构。左侧 Sidebar（`GamePickerView`）包含所有可选项（Game.allCases），右侧 Detail（`LauncherView`）展示选中项的详细内容。`navigationSplitViewStyle(.balanced)` 使多列在空间充裕时自然分布。`NavigationLink(value:)` 结合 `List(selection:)` 实现选中态同步。 |
| **优点** | macOS 系统级导航模式，与 Finder、Mail、Xcode 等原生应用一致；Sidebar 自动获得 Liquid Glass 材质；NavigationLink 管理选中态和列表高亮；无需手动跟踪 selectedGame 的视图切换 |
| **缺点** | 占据水平空间，窄窗口下 Content 区被压缩；`columnVisibility` 控制有限；非标准的沉浸式布局需要额外定制 |
| **适用条件** | 内容预览类应用（左侧列表 + 右侧详情）、需要 macOS 原生导航体验的场景 |
