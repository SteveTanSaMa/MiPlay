# Research — Design Principles

> **接收方：** 所有 Agent（UX / UI / Architecture Agent 的长期参考）
> **内容：** 从 References/ 中归纳的设计原则，不依赖单一产品
> **要求：** 至少 5 条原则，每条附带 Trade-off，标注来源

> **事实分层：** Apple 章节是平台规范与能力参考；MiPlay 引用以 `MiPlay/` 当前代码为准；历史 `References/MiPlay/` 和 YAAGLSWIFTUI 只用于对比。原则中的“适用场景”是研究建议，不自动构成项目最终方案。

---

## 设计原则综述

### 原则 1：Liquid Glass API 表达层次

- **来源：** Apple Liquid Glass Design System（`References/Apple/apple-liquid-glass-docs/04-SwiftUI-API-Reference.md`、`References/Apple/apple-liquid-glass-docs/06-SwiftUI-Material-Reference.md`）、macOS 26 设计规范（`References/Apple/macOS-26-设计规范.md`）
- **描述：** Apple 的 Liquid Glass API 使用玻璃效果和形状边界表达层级，主要入口是 SwiftUI `glassEffect(_:in:)`、`Glass` 和 `GlassEffectContainer`。`Material`（包括 `.ultraThinMaterial`、`.regularMaterial` 等）仍是 Apple 平台的通用材质参考，但不应被写成 MiPlay 当前采用的实现。当前 MiPlay 采用 `glassEffect` 系列 API。
- **适用场景：** 需要优雅表达界面层次但又不想引入视觉噪声的桌面应用；内容区、侧边栏、工具栏之间的前后关系表达。当前 MiPlay 的实际采用 API 是 `glassEffect` 与 `GlassEffectContainer`，不是旧 Material 修饰符。
- **Trade-off（选择此原则的代价）：**
  - 动态模糊材质有 GPU 开销，对低端硬件或高帧率需求场景不友好
  - 透明度层级在不同背景内容上的视觉效果不一致（深色 vs 浅色背景差异显著）
  - 残障用户（低视力）可能难以仅通过透明度区分层次，需要配合其他视觉提示

### 原则 2：统一交互语义（Consistent Interactive Affordance）

- **来源：** Apple HIG（Human Interface Guidelines — 一致性与交互语义）、Apple Web Design（`References/Apple/DESIGN.md`：#0066cc Action Blue 承载所有交互信号）、macOS 26 设计规范（`References/Apple/macOS-26-设计规范.md`：#0088FF 按钮色、#0D6FFF 表单控件色、#007AFF 图标选中色）
- **描述：** 所有可交互元素应保持一致的交互语义，而非强制使用完全一致的 RGB 数值。Apple 的核心理念是"交互语义统一"——用户看到蓝色就知道可以点击，但不同控件（按钮、开关、链接、滑块）因材质和上下文不同，蓝色取值可以有细微差异。这属于系统设计的一部分而非不一致。具体分配规则如下：
  - **操作类控件**（按钮、菜单项、工具栏）→ 系统 Accent / Tint
  - **表单控件**（Toggle、Checkbox、Radio）→ 系统 Tint
  - **聚焦指示**（TextField Focus Ring）→ 系统 Focus Ring（双层蓝色阴影）
  - **导航状态**（Sidebar 选中、Tab 选中）→ 系统 Accent
  - **语义状态**（成功 / 警告 / 错误）→ 对应语义色（Green / Orange / Red）
- **适用场景：** 所有使用 SwiftUI 标准控件的界面；目标体验为"像 Apple 原生应用"的 macOS 应用。
- **Trade-off（选择此原则的代价）：**
  - 品牌化需求强烈时可能需要自定义 Tint Color，覆盖系统默认行为
  - 在不同控件族上使用略有差异的蓝色，在设计审查时可能被误判为"不一致"
  - 语义色（红/绿/橙）与系统 Tint 蓝并存，需注意语义色的节制使用，避免喧宾夺主

### 原则 3：颜色变化即分割

- **来源：** Apple Web Design（`References/Apple/DESIGN.md`：tile 间的 light ↔ dark 颜色变化作为分割）、Landmarks（`References/LandmarksBuildingAnAppWithLiquidGlass/` 中 NavigationSplitView sidebar 与 content 之间无明确分割线）
- **描述：** 区块之间的视觉分割可以通过颜色或材质的变化实现，不需要额外的分割线、边框或间距。Apple 的产品 tile 通过白色 ↔ 近黑色的颜色变化自然区分段落；macOS 的 sidebar 和 content 通过 Liquid Glass 材质的差异自然区分。
- **适用场景：** 全出血布局（full-bleed layout）中区块间的自然过渡；不希望视觉噪声干扰内容的场景。
- **Trade-off（选择此原则的代价）：**
  - 区块数量受限于可用的深浅交替次数，过多交替会造成视觉疲劳
  - 颜色差异不够明显时，相邻区块可能被视为一体
  - 可访问性方面，色觉异常用户可能无法感知颜色变化带来的分割

### 原则 4：并发操作队列化

- **来源：** YAAGL（`References/YAAGL/src/launcher/task-queue.ts`：AsyncGenerator 任务队列 + 双队列设计）、MiPlay 当前实现（`MiPlay/Domain/TaskScheduler/TaskScheduler.swift`、`MiPlay/Infrastructure/Process/ProcessManager.swift`：任务调度与 actor 资源隔离）
- **描述：** 涉及系统资源（进程、文件、网络）的耗时操作应串行化执行，避免并发冲突。操作定义为可产出的过程（生成器/actor），按序放入队列执行。YAAGL 使用异步生成器 + Signal 的状态解耦方案；MiPlay 使用 Swift actor 的异步方法保证串行化。
- **适用场景：** 多个可能冲突的异步操作（游戏安装 + 更新 + 启动 + 完整性检查）；需要精确进度反馈的耗时操作序列；共享系统资源的场景。
- **Trade-off（选择此原则的代价）：**
  - 串行化限制了并行能力，某些可并行的操作（如下载多个文件）无法同时进行
  - 队列中的阻塞操作会影响后续所有任务
  - 需要额外设计"紧急中断"机制（用户取消操作）

### 原则 5：状态驱动交互入口

- **来源：** YAAGL（`References/YAAGL/src/launcher/index.tsx`：`installState()` 驱动的按钮行为）、MiPlay 当前实现（`MiPlay/UI/ViewModels/LibraryViewModel.swift`、`MiPlay/UI/Components/PrimaryActionButton.swift`：`PrimaryButtonState`）、MiPlay Product Domain（`Docs/00-product/product-domain.md`：Per-Game 状态表）
- **描述：** 主交互入口（按钮/控件）的标签、图标、行为和可用性由当前状态动态决定。同一个入口在不同状态下呈现不同的语义，用户不需要找多个按钮，一个按钮适配所有状态。当前 MiPlay 的 `PrimaryActionButton` 由 `LibraryViewModel.PrimaryButtonState` 驱动，并位于底部操作行右侧，不是居中按钮。
- **适用场景：** 单一实体有明确生命周期（not_installed → downloading → installed → running）的场景；希望简化界面、减少按钮数量的场景。
- **Trade-off（选择此原则的代价）：**
  - 边界状态（error、broken、unknown）需要精确的映射规则
  - 用户可能对状态突变感到困惑（例如从"开始游戏"切换为"更新游戏"）
  - 状态判断的延迟可能导致按钮在状态转换期间显示不正确的语义

### 原则 6：Wine 技术零感知

- **来源：** MiPlay Product Vision（`Docs/00-product/product-vision.md`：Wine 零感知成功标准）、YAAGL（`References/YAAGL/src/wine/wine.ts`：直接暴露 exec/exec2 给调用层）
- **描述：** 游戏启动工具的核心原则之一：用户不需要了解 Wine 是什么、从哪获取、如何配置。所有 Wine 相关操作（下载、版本管理、prefix 创建、环境变量设置）由应用自动处理。YAAGL 在应用中管理 Wine 但 UI 层仍然直接暴露 Wine Distribution 配置项（违反了"零感知"原则）；MiPlay 设计目标则是完全隐藏 Wine 概念。
- **适用场景：** 目标用户为非技术玩家（不了解 Wine/转译概念）的桌面应用。
- **Trade-off（选择此原则的代价）：**
  - 完全隐藏 Wine 意味着当出现 Wine 特定问题时用户无法自助排查
  - 高级用户可能希望手动指定 Wine 版本或配置
  - 自动管理 Wine 版本增加了应用的复杂度和下载量

### 原则 7：可发现性的渐进披露

- **来源：** YAAGL（`References/YAAGL/src/config/index.tsx`：Advanced 配置通过连击版本号 5 次显示）、Apple 设计哲学（HIG 渐进披露原则）
- **描述：** 高级或危险的配置选项默认隐藏，只在用户主动探索时才显示。YAAGL 的 Advanced 配置页需要通过连续快速点击版本号 5 次才解锁，并在解锁前弹出 notification 确认。这种设计防止新用户意外修改危险配置。
- **适用场景：** 配置项中包含可能影响稳定性或安全性的高级选项；面向非技术用户的工具。
- **Trade-off（选择此原则的代价）：**
  - 隐藏高级选项降低了可发现性，高级用户可能不知道存在这些选项
  - 需要额外的"解锁机制"，增加用户体验的摩擦
  - 如果解锁机制过于隐蔽，用户可能误以为应用功能缺失

### 原则 8：沉浸式内容优先

- **来源：** Apple Web Design（`References/Apple/DESIGN.md`：摄影优先，UI 退居幕后）、YAAGL（`References/YAAGL/src/launcher/index.tsx`：全屏游戏背景）、MiPlay 当前实现（`MiPlay/UI/MainWindow/MainWindowScene.swift`、`MiPlay/UI/Components/BackgroundScene.swift`）
- **描述：** 应用的视觉焦点是内容本身（游戏背景/产品摄影），UI 控件和 chrome 最小化，叠加在内容之上而非并排展示。Apple 的产品展示没有装饰性边框、阴影或渐变——产品本身就是视觉主体。游戏启动器使用全屏游戏主题背景作为视觉锚点。
- **适用场景：** 展示型应用或工具（启动器、产品展示页、媒体浏览器）；用户操作频率低、单次使用时间短的工具。
- **Trade-off（选择此原则的代价）：**
  - 沉浸式背景需要高质量的视觉素材（视频/图片），增加应用大小或网络依赖
  - 动态背景上文字的可读性需要额外保障层
  - 内容加载成为用户等待的关键路径


### 原则 9：Service 即状态源（无 ViewModel 层，竞品参考）

- **来源：** YAAGLSWIFTUI（`@Observable` Service 直接暴露状态给视图层，无独立 ViewModel）、Apple WWDC 2023 "Discover Observation with Swift"、WWDC 2024 "Swift 6 Observation"、WWDC 2025 "Adapt Observation for Swift 6 concurrency"
- **描述：** Swift 6 的 `@Observable` 宏使任意 class 的存储属性自动获得细粒度的观察能力。这使得 Service 层可以直接承担状态持有者的角色，而不需要像 MVVM 那样在 ViewModel 中复制或转换 Service 的状态。视图通过 `@Environment(Service.self)` 获取 Service 实例，编译器自动追踪视图读取了哪些属性，仅在那些属性变化时触发重渲染——零运行时开销。YAAGLSWIFTUI 的 GameService、ConfigService、WineService 等均以此模式工作。
- **适用场景：** 不需要为每个视图裁切身独有状态投影的中等复杂度应用；Service 职责边界清晰，每个 Service 的自然属性就是视图所需的状态。
- **Trade-off（选择此原则的代价）：**
  - 无法为不同视图裁剪状态的子集（所有读取 Service 的视图都会看到完整状态）
  - Service 的测试需要初始化其所有依赖，因为状态与逻辑耦合在同一类中
  - UI 状态属性（如 statusText、progress）与业务逻辑方法混在同一类声明中，降低可维护性
  - 多个视图共享同一个 Service 实例时，一个视图的交互可能意外触发其他视图的重渲染

### 原则 10：原生的异步进度流

- **来源：** YAAGLSWIFTUI（`AsyncThrowingStream<ProgressEvent, Error>` 替代回调/Promise）、YAAGL（`AsyncGenerator` 替代回调）、Apple WWDC 2021 "Meet AsyncSequence"
- **描述：** 长耗时操作应返回一个异步序列（`AsyncSequence`），逐步 yield 进度事件，而非通过回调或 Promise 链传递。`ProgressEvent` 枚举可以涵盖下载（含速度）、解压、补丁、校验、不确定、完成、失败等多种进度类型。视图通过 `for try await event in operation()` 的范式统一消费，无需为每个操作编写独立的回调闭包。
- **适用场景：** 多阶段耗时操作（安装、更新、下载、解压）；需要精细进度反馈的场景；操作可取消的场景。
- **Trade-off（选择此原则的代价）：**
  - `AsyncThrowingStream` 的 `continuation.finish()` 遗漏会导致视图永远等待
  - 不适合同步操作或仅需最终结果的场景（应直接使用 async/await）
  - 多个流的合并和切换（如并行下载的进度合并）需要额外的协调逻辑

### 原则 11：解耦并发安全（Lock + @unchecked Sendable）

- **来源：** YAAGLSWIFTUI（`LockedDictionary`：NSLock + `@unchecked Sendable`）、Apple Swift 6 Concurrency Migration Guide、"Retroactive Concurrency Safety" 技术说明
- **描述：** 对于需要在非主线程访问的小规模共享可变状态（如活跃任务映射表），使用显式锁（NSLock/NSRecursiveLock）+ `@unchecked Sendable` 是非 actor 方案的合理选择。actor 会强制所有异步访问串行化并通过 reentrancy 重新入栈，对于简单的读写操作来说开销过高。而 `LockedDictionary` 模式将线程安全的保证封装在字典内部，对外的接口是 Sendable-safe 的。
- **适用场景：** 小规模共享可变集合的线程安全包装；需要在 URLSession 回调中快速读写的场景；对 actor reentrancy 和性能开销敏感的场景。
- **Trade-off（选择此原则的代价）：**
  - `@unchecked Sendable` 将并发安全性的静态检查责任从编译器转移到开发者
  - NSLock 在 async 上下文中使用可能导致死锁（locked await 模式）
  - 不支持 actors 提供的 reentrancy 保证和结构化并发取消传播
  - 调试困难：锁竞争、死锁、优先级反转等问题难以重现

### 原则 12：Environment 生态的 DI

- **来源：** YAAGLSWIFTUI（`EnvironmentKeys.swift` + `AppContext.swift` + 入口处 `.environment()` 注入）、Apple SwiftUI 数据流文档
- **描述：** 通过 SwiftUI EnvironmentKey 模式实现依赖注入。每个 Service 有自己私有的 EnvironmentKey 结构体和 `EnvironmentValues` 计算属性扩展。在 App 入口处通过 `.environment()` 将单体化且配置好的 Service 实例覆盖 Environment 中的默认值。视图通过 `@Environment(Service.self)` 按需获取依赖。这种模式保证了视图层对依赖注入"无感"——不需要在视图初始化器中传递任何 Service 引用。
- **适用场景：** SwiftUI 为主架构的应用；Service 数量中等（5-10 个）且生命周期与 App 一致；视图树深度较浅的场景。
- **Trade-off（选择此原则的代价）：**
  - 每个 Service 需要约 15 行样板代码（private struct Key + extension EnvironmentValues + defaultValue）
  - EnvironmentValue 的传递是隐式的，当视图树多层覆盖时难以追踪某个值的来源
  - `defaultValue` 模式鼓励创建独立实例，可能在测试和预览中产生非预期的状态隔离
  - 不适合树状作用域隔离的场景（如不同分支使用不同 Service 实例）

### 原则 13：渐进披露的高级配置（历史/竞品参考）

- **来源：** YAAGL（连击版本号 5 次显示 Advanced Tab）、YAAGLSWIFTUI（同样实现 `unlockAdvanced()` 连击解锁）、Apple HIG 渐进披露原则
- **描述：** 危险或高级配置默认隐藏，需通过特定的交互技巧（如连击）解锁。YAAGLSWIFTUI 的 `ConfigurationView.unlockAdvanced()` 在检测到用户连续快速点击版本号区域 5 次后才将 Advanced Tab 加入可见列表，并在 1 秒无操作后重置计数。这种设计防止了非技术用户误操作高风险配置。
- **适用场景：** 配置面板中包含可能影响系统稳定性或应用行为的选项；目标用户包含非技术用户。
- **Trade-off（选择此原则的代价）：**
  - 高级用户每次需要配置时都要执行解锁操作，降低了效率
  - 解锁机制本身对部分用户可能不可发现
  - 增加维护成本——解锁条件（连击次数、时间窗口）可能需要在用户反馈后调整

### 当前项目方案标注

- **已采用：** 当前 MiPlay 使用 `glassEffect` / `GlassEffectContainer`，主窗口采用 ZStack 沉浸式布局，设置采用独立 `Settings` Scene，状态采用 ViewModel 驱动。
- **不应误写为当前实现：** `.regularMaterial`、`.ultraThinMaterial`、`.buttonGlass()`、右上角设置按钮、居中主按钮、主窗口设置 Sheet。
- **研究建议：** Apple Liquid Glass 的 API、材质层级与 macOS 窗口规范继续作为参考；具体组件和窗口布局以当前代码与冻结 UI/Architecture 文档为准。
