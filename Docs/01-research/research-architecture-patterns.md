# Research — Architecture Patterns

> **接收方：** Architecture Agent
> **内容：** 项目结构、模块划分、状态管理、任务管理、配置管理
> **来源：** References/ 目录下的所有研究材料

> **事实分层：** `References/MiPlay/` 是历史参考实现；当前项目事实以 `MiPlay/` 目录为准。Apple 与 YAAGLSWIFTUI 章节提供平台/竞品模式，不代表 MiPlay 当前采用。

---

## YAAGL

### 项目结构

```
YAAGL/
├── src/
│   ├── app.tsx              # 应用入口：Wine 检查 → 初始化 → AppRoot
│   ├── index.tsx            # 渲染入口
│   ├── launcher/
│   │   ├── index.tsx        # 启动器 UI 主组件
│   │   └── task-queue.ts    # 异步任务队列管理
│   ├── clients/
│   │   ├── index.ts         # 客户端导出（按环境变量选择）
│   │   ├── hk4ecn.ts        # Genshin Impact CN 注册
│   │   ├── hk4eos.ts        # Genshin Impact OS 注册
│   │   ├── hkrpgcn.ts       # Star Rail CN
│   │   ├── hkrpgos.ts       # Star Rail OS
│   │   ├── napcn.ts         # ZZZ CN
│   │   ├── napos.ts         # ZZZ OS
│   │   ├── bh3glb.ts        # Honkai Impact 3rd
│   │   ├── cbjq.ts          # Snowbreak
│   │   ├── mhy/             # miHoYo 通用模块
│   │   │   ├── hk4e/        # Genshin Impact 实现
│   │   │   ├── hkrpg/       # Star Rail 实现
│   │   │   └── nap/         # ZZZ 实现
│   │   │   ├── hyp-connect.ts  # HoYo 官方 API 连接
│   │   │   ├── launcher-info.ts # 启动器 API 数据类型
│   │   │   ├── patch.ts     # 通用 patch 系统
│   │   │   └── unity.ts     # Unity 引擎版本检测
│   │   └── seasun/          # 尘白禁区模块
│   ├── wine/
│   │   ├── wine.ts          # Wine 封装（exec/exec2/属性设置）
│   │   ├── distro.ts        # Wine 构建版本管理
│   │   ├── cert.ts          # 证书管理
│   │   └── mf.ts            # Media Foundation 支持
│   ├── config/
│   │   ├── index.tsx        # 配置面板 UI
│   │   ├── config-def.ts    # 配置类型定义
│   │   └── [config-xxx].tsx # 各配置项实现
│   ├── sophon.ts            # Sophon 客户端（增量更新协议）
│   ├── aria2.ts             # Aria2 下载客户端
│   ├── updater.ts           # 自动更新模块
│   ├── github.ts            # GitHub API 模块
│   ├── downloadable-resource.ts # 可下载资源管理
│   └── utils/               # 工具函数
├── sophon_server/           # Python 增量更新后端
│   ├── server.py            # Sophon 服务端
│   ├── sophon_api.py        # API 路由
│   ├── models.py            # 数据模型
│   └── tasks.py             # 后台任务
└── sidecar/                 # 第三方二进制
    ├── aria2/               # 下载工具
    ├── 7z/                  # 解压缩
    ├── hpatchz/             # 增量补丁
    ├── xdelta/              # 增量差分
    └── protonextras/        # Steam 模拟层
```

### 模块划分

- **应用层（app.tsx）：** 启动入口、Wine 检查、依赖服务启动、App Root 组装
- **启动器层（launcher/）：** 游戏启动 UI、任务队列管理
- **客户端层（clients/）：** 每个游戏一个 ChannelClient 实现，封装安装/更新/启动/完整性检查
- **Wine 层（wine/）：** Wine 运行时封装，提供 exec/exec2/属性设置/证书管理
- **配置层（config/）：** 配置项 UI 和配置管理，各配置项独立文件
- **下载层（aria2.ts, sophon.ts）：** 下载管理和增量更新协议客户端
- **工具层（utils/）：** 平台抽象（Neutralino.js 封装）、Shell 命令构建

### 状态管理
- **SolidJS Signals：** 每个 ChannelClient 使用 `createSignal` 管理状态（安装状态、进度、游戏目录等）
- **`batch()` 批量更新：** 多个信号同时变更时使用 `batch()` 减少渲染次数
- **Task Queue Pattern：** 使用 `AsyncGenerator` 将异步操作与状态更新解耦
- **双队列：** `taskQueue`（主操作）+ `nonUrgentTaskQueue`（后台操作如预下载）
- **配置状态：** `config: Partial<Config>` 对象中收集，通过 `createConfiguration` 集中管理

### 任务管理
- **异步生成器模式：** 每个耗时操作返回 `CommonUpdateProgram`（`AsyncGenerator`），yield `["setProgress", n]` 或 `["setStateText", key]` 更新状态
- **单线程串行队列：** `taskQueue` 确保耗时操作按序执行，不并发
- **`fatal(e)` 全局错误处理：** 队列中出现未捕获异常时调用 `fatal` 终止
- **双队列设计：** 预下载在 `nonUrgentTaskQueue` 中运行，不影响主队列状态

### 配置管理
- **Neutralino `setKey`/`getKey` 持久化：** 使用 Neutralino 的 key-value 存储
- **`config-def.ts` 类型定义：** 所有配置项的类型集中定义
- **配置项独立实现：** 每个配置项一个独立的 `.tsx` 文件，包含 UI 和持久化逻辑
- **配置面板 Tab 组织：** General / Game / Wine / Advanced / Licenses
- **Advanced 模式隐藏：** 默认隐藏高级配置项，需要特定触发（连击版本号 5 次）

---

## MiPlay 历史实现（仅作对比）

> 以下结构来自 `References/MiPlay/`，不是当前 `MiPlay/` 目录。当前实现见下一节。

### 项目结构

```
MiPlay/
├── Models/
│   ├── Game.swift              # GameType/Game/GameInstallStatus 模型
│   ├── AppSettings.swift       # 应用设置模型
│   ├── LaunchConfiguration.swift # 启动配置
│   ├── WineConfig.swift        # Wine 配置模型
│   └── GameBackground.swift    # 游戏背景素材模型
├── ViewModels/
│   ├── LibraryViewModel.swift  # 主页 ViewModel
│   ├── SettingsViewModel.swift # 设置页 ViewModel
│   └── LaunchViewModel.swift   # 启动流程 ViewModel
├── Views/
│   ├── Library/
│   │   ├── LibraryView.swift   # 主页（沉浸式背景 + 游戏栏 + 按钮）
│   │   ├── GameCardView.swift  # 游戏卡片
│   │   ├── GameRailView.swift  # 游戏选择栏（底部）
│   │   └── BackgroundImageView.swift # 背景图片视图
│   └── Settings/
│       └── SettingsView.swift  # 设置页
├── Launcher/
│   ├── GameLauncher.swift      # 游戏启动器 Actor
│   ├── LaunchService.swift     # 启动服务
│   └── LaunchValidator.swift   # 启动验证器
├── Wine/
│   ├── WineManager.swift       # Wine 运行时管理
│   ├── WinePrefix.swift        # Wine Prefix 管理
│   ├── WineEnvironment.swift   # 环境变量管理
│   ├── WineVersion.swift       # 版本信息模型
│   └── WineDownloader.swift    # Wine 下载器
├── Persistence/
│   ├── ConfigManager.swift     # JSON 配置持久化
│   └── SettingsStore.swift     # 设置存储
├── Updates/
│   ├── LauncherUpdater.swift   # 启动器更新
│   ├── UpdateManager.swift     # 更新管理
│   └── RuntimeUpdater.swift    # 运行时更新
└── Utilities/
    ├── Logger.swift            # 日志系统
    ├── Shell.swift             # Shell 执行器
    └── Extensions/             # SwiftUI/Color/Bundle 扩展
```

### 模块划分

- **模型层（Models/）：** 纯数据模型（Codable），不与视图直接耦合
- **ViewModel 层（ViewModels/）：** `@Observable` 类，持有数据模型和业务服务引用
- **视图层（Views/）：** SwiftUI 视图，从 ViewModel 读取状态
- **启动层（Launcher/）：** 游戏进程管理（Process 封装），使用 Swift `actor` 保证线程安全
- **Wine 层（Wine/）：** Wine 版本管理、下载、Prefix 管理
- **持久化层（Persistence/）：** JSON 文件持久化（ConfigManager actor）
- **更新层（Updates/）：** 启动器和运行时更新
- **工具层（Utilities/）：** 日志、Shell 执行、扩展

### 状态管理
- **`@Observable` 宏（Swift 6）：** ViewModel 使用 `@Observable` 宏实现属性级观察
- **`@State` 视图本地状态：** 背景素材、选中游戏、UI 状态（isPreparing 等）
- **`@Environment` 注入：** 尚未使用（旧版本使用构造函数注入）
- **Actor 隔离：** `GameLauncher` 和 `WineManager` 和 `ConfigManager` 使用 `actor` 保证线程安全
- **异步 async/await：** ViewModel 方法标记为 `@MainActor`，服务调用使用 async

### 任务管理
- **直接异步调用：** ViewModel 方法直接调用 Service 的 async 方法，不使用额外的队列抽象
- **actor 串行化：** `GameLauncher actor` 保证启动操作串行执行
- **进程管理：** `Process` 对象管理 + `withCheckedContinuation` 异步等待进程退出
- **后台预加载：** 使用 `Task { }` 在后台加载其他游戏的素材

### 配置管理
- **JSON 持久化：** `ConfigManager actor` 使用 JSONEncoder/Decoder 存取配置文件到 `Application Support/MiPlay/Configs/`
- **泛型 `saveConfiguration<T: Codable>`：** 类型安全的配置存取
- **`AppSettings` 模型：** 应用级设置模型，SwiftUI 绑定
- **配置命名：** 以 `.json` 文件名作为配置标识

---

## MiPlay 当前实现（代码事实）

### 项目结构

```
MiPlay/
├── MiPlayApp.swift                 # @main + AppDelegate + Main/Settings/Detail Scenes
├── Infrastructure/                 # actor 基础设施：持久化、文件、网络、进程、Wine、日志、媒体
├── Domain/                          # 游戏状态、启动编排、兼容方案、更新、性能、任务调度
└── UI/
    ├── Components/                 # 背景场景、Liquid Glass 控件、反馈组件
    ├── MainWindow/                 # 主窗口 ZStack、游戏选择栏、底部主操作
    ├── SettingsWindow/             # 独立 Settings Scene 的 NavigationSplitView
    ├── GameDetailWindow/           # 兼容方案、性能和日志详情窗口
    └── ViewModels/                 # LibraryViewModel、SettingsViewModel、GameDetailViewModel
```

### 模块划分

- **基础设施层（Infrastructure/）：** 使用 actor 管理 JSON 持久化、文件系统、网络下载、进程、Wine、日志和媒体缓存/转码。
- **领域层（Domain/）：** `GameRegistry`、`GameStateMachine`、`LaunchOrchestrator`、`SolutionEngine`、`TaskScheduler` 等负责状态、启动、兼容方案和任务协调。
- **ViewModel 层（UI/ViewModels/）：** `LibraryViewModel` 管理主窗口游戏库、背景素材与主操作；`SettingsViewModel` 管理设置窗口状态；`GameDetailViewModel` 管理详情窗口状态。
- **主窗口（UI/MainWindow/）：** 沉浸式背景 + 左下游戏选择栏 + 底部右侧状态驱动主操作按钮。
- **设置窗口（UI/SettingsWindow/）：** 由 SwiftUI `Settings` Scene 注册，内容使用 `NavigationSplitView`，不是主窗口 Sheet。
- **Liquid Glass 组件（UI/Components/）：** `GlassEffectContainer`、`glassEffect` 和 `Glass.regular.interactive(true)` 用于当前交互控件。

### 状态管理

- **ViewModel 主导：** 当前 MiPlay 仍保留独立 ViewModel 层。`LibraryViewModel`、`SettingsViewModel` 和 `GameDetailViewModel` 使用 `@Observable` 暴露视图所需状态。
- **Domain/Infrastructure 混合并发模型：** 共享资源服务（文件、网络、进程、Wine、持久化等）主要使用 actor；部分状态服务使用 `@Observable` 类。
- **构造器注入：** `MiPlayApp` 按基础设施 → 领域 → ViewModel 的依赖顺序构造对象，并通过 View 初始化器传入 ViewModel；当前没有采用 YAAGLSWIFTUI 的 EnvironmentKey + Service 直接注入作为主 DI 方式。
- **状态驱动主操作：** `LibraryViewModel.PrimaryButtonState` 决定主按钮文字、可用状态和操作分支；UI 不根据游戏状态自行实现启动/定位/修复业务逻辑。

### 窗口与导航

- **主窗口：** `MainWindowScene` 使用固定 1280×688、隐藏标题栏的 `WindowGroup`，主内容为沉浸式 `ZStack`。
- **主窗口导航：** `GameSelectionRailView` 位于左下角，游戏图标纵向排列；设置入口位于游戏选择栏底部，不在右上角。
- **主操作位置：** `PrimaryActionButton` 位于底部操作行右侧，借助 `Spacer()` 与游戏选择栏同排，不是居中主按钮。
- **设置窗口：** `MiPlayApp` 的 `Settings` Scene 打开 `SettingsWindowScene`；设置内容使用双列 `NavigationSplitView`，固定内容尺寸 800×448。
- **详情窗口：** `WindowGroup(id: "game-detail")` 承载兼容方案、性能和日志相关详情，不使用主窗口内的旧详情 Sheet。

### 当前采用方案与研究建议

- **项目最终采用：** 四层依赖方向（UI → ViewModel → Domain → Infrastructure）、ViewModel 状态管理、actor 基础设施、主窗口沉浸式 ZStack、独立 Settings Scene、主操作底部右侧布局、Liquid Glass `glassEffect`/`GlassEffectContainer`。
- **研究建议（非当前实现）：** YAAGLSWIFTUI 的 `@Observable Service` 直连 Environment、`AsyncThrowingStream`、`NavigationSplitView` 单窗口导航可作为模式参考，但不能覆盖 MiPlay 已冻结的 ViewModel、独立设置窗口和当前任务调度设计。

---

## Apple Liquid Glass Design System

### 项目结构
- Liquid Glass 是系统级设计语言，无项目结构
- API 分布于各框架：SwiftUI / UIKit / AppKit

### 模块划分
- **SwiftUI API：** `glassEffect(_:in:)`、`GlassEffectContainer`、`Glass` 结构体、`GlassEffectTransition`
- **AppKit API（macOS 26+）：** `NSGlassEffectView`、`glassColor`、`style`
- **UIKit API（iOS/iPadOS）：** `UIVisualEffectView` + `UIBlurEffect.Style` 扩展
- **Liquid Glass API：** `glassEffect(_:in:)`、`Glass.regular`、`Glass.interactive(_:)`、`GlassEffectContainer`
- **Material API（平台参考）：** `Material.regular` / `.thin` / `.thick` / `.ultraThin` / `.ultraThick` / `.bar`；这些是 Apple 平台能力，不是 MiPlay 当前实现的描述

### 状态管理
- Liquid Glass 是表现层系统，不涉及应用状态管理
- 材质变体声明式指定（`.glassEffect(.regular)`）
- 交互态材质可通过 `Glass.interactive(Bool)` 控制响应行为

### 任务管理
- 不涉及

### 配置管理
- 系统级配置通过 Xcode asset catalog、Info.plist、window style mask 管理
- Glass 效果配置通过 `Glass` 结构体参数传递
- 窗口类型和样式通过 `NSWindow.styleMask` 组合配置

---

## Landmarks (Building an App with Liquid Glass)

### 项目结构

```
Landmarks/
├── LandmarksApp.swift                 # @main 入口
├── Model/
│   ├── ModelData.swift                # 中心化数据模型（@Observable）
│   ├── Landmark.swift                 # 地标数据模型
│   ├── LandmarkData.swift             # 示例数据
│   ├── LandmarkCollection.swift       # 收藏集模型
│   ├── LandmarkCollectionData.swift   # 收藏集示例数据
│   ├── Badge.swift / BadgeProgress.swift # 徽章模型
│   ├── Activity.swift                 # 活动模型
│   ├── Elevation.swift                # 海拔数据
│   ├── Constants.swift                # 常量
│   └── LocationFinder.swift           # 位置查找
├── Views/
│   ├── Landmarks Split View/
│   │   ├── LandmarksSplitView.swift   # NavigationSplitView 主结构
│   │   └── NavigationOptions.swift    # 导航选项枚举
│   ├── Landmarks/
│   │   ├── Landmarks View/            # 主页视图
│   │   ├── Landmark Detail/           # 详情页
│   │   ├── Landmark Grid/             # 网格展示
│   │   └── Landmark Selection/        # 选择列表
│   ├── Collections/                   # 收藏集相关
│   ├── Badges/                        # 徽章视图
│   └── Map/                           # 地图视图
└── Resources/                         # 素材资源
```

### 模块划分
- **模型层（Model/）：** `@Observable` 的 `ModelData` 中心化数据管理，`Codable` 数据模型
- **视图层（Views/）：** 按功能模块分组（Landmark / Collection / Badge / Map）
- **资源层（Resources/）：** Assets、本地化字符串

### 状态管理
- **`@Observable @MainActor` ModelData 类：** 单一数据源，所有视图通过 `@Environment(ModelData.self)` 注入
- **`@Environment` 注入：** 在 `LandmarksApp` 级别通过 `.environment(modelData)` 注入
- **`@State` 本地状态：** 视图本地状态（如 `preferredColumn`、`inspectorIsPresented`）
- **`@Bindable` 可变绑定：** 当需要从子视图修改父视图的 ModelData 时使用 `@Bindable var modelData`
- **计算属性：** `earnedBadges` 等基于其他状态的派生数据
- **`didSet` 观察者：** `NavigationPath.didSet` 自动处理 Inspector 关闭逻辑

### 任务管理
- 不涉及复杂任务管理
- 异步操作：`fetchMapItems` 使用 `async/await` 单独处理

### 配置管理
- 不涉及用户配置管理
- 静态示例数据驱动 UI

---

## macOS 26 设计规范（Figma 逆向分析）

### 窗口架构
- **Z 轴层级（L0-L7）：** Desktop → Menu Bar → Glass Overlay → 应用窗口 → Modal Overlay → Alert/Dialog → Floating Menu → Dock
- **六种窗口类型：** 文档窗口 / 工具窗口 / 对话框 / 弹窗 / 通知横幅 / 菜单
- **五种布局模式：** 纯标题栏（文档）/ 纯标题栏+Tab（工具）/ Monobar / Titlebar独立 / 标准模式

### 导航架构
- **Menu Bar（34px 全宽）：** 系统级导航，Leading（Apple Logo + 菜单项）+ Trailing（系统状态）
- **Sidebar（五种变体）：** 240px 标准 / 136px 紧凑 / 撑满 / Monobar
- **Sub-nav（52px 毛玻璃）：** 页面级导航，分类名 + 内联链接 + 主 CTA
- **Tab 栏（30px）：** 工具窗口内 Tab 切换

### 组件架构
- **Button 体系：** 弹窗按钮（110×32px，圆角100px）/ 对话框按钮（63-74×24px，圆角6px）/ 表单按钮（67×24px，圆角6px）
- **Toolbar 四尺寸：** 超小32px / 小32px / 中36px / 大52px
- **TextField 状态：** 默认（1px border）→ 聚焦（3.5px+1px double focus ring）
- **表单行：** 42px 高，flex-direction row，gap 16px，底部 1px 分割线
- **Modal 分层：** Desktop Modal（无遮罩）/ Window Modal（窗口遮罩 rgba(0,0,0,0.2)）/ Dialog Modal（自身阴影）

### 圆角体系
- 窗口 26px / 16px，工具窗口 15px，Sidebar 18px / 8px，通知 16px，菜单 13px，Dock 15px，胶囊按钮 100px，直角按钮 6px


---

## YAAGLSWIFTUI

### 项目结构

```
YAAGLSWIFTUI/
├── YAAGLSWIFTUIApp.swift          # @main 入口 + NSApplicationDelegateAdaptor
├── App/
│   ├── AppContext.swift            # 集中式 DI 容器（@Observable），持有所有 Service 单例
│   ├── AppDelegate.swift           # NSApplicationDelegate（wineserver 优雅关闭）
│   ├── EnvironmentKeys.swift       # EnvironmentKey + EnvironmentValues 扩展
│   └── RootView.swift              # 根视图（NavigationSplitView）
├── Services/
│   ├── ConfigService.swift         # 配置管理（@Observable + UserDefaults 持久化）
│   ├── WineService.swift           # Wine 运行时管理
│   ├── DownloadService.swift       # 下载服务（URLSession，替代 aria2）
│   ├── GameService.swift           # 游戏操作编排（安装/更新/启动/完整性检查）
│   ├── SophonService.swift         # Sophon 增量更新协议客户端
│   ├── GitHubService.swift         # GitHub API 客户端（Wine 发行版获取）
│   ├── UpdaterService.swift        # 自动更新模块
│   ├── FileSystemService.swift     # 文件系统工具
│   ├── HostsService.swift          # /etc/hosts 管理
│   ├── LocaleService.swift         # 本地化管理
│   ├── LogService.swift            # 日志服务
│   ├── ProcessService.swift        # 进程管理
│   └── DownloadableResourcesService.swift # 可下载资源管理
├── Clients/
│   ├── GameClientProtocol.swift     # GameClient 协议定义
│   ├── HK4EClient.swift            # Genshin Impact（国服+国际服）
│   ├── HKRPGClient.swift           # Star Rail
│   ├── NAPClient.swift             # ZZZ
│   ├── BH3Client.swift             # Honkai Impact 3rd
│   └── CBJQClient.swift            # Snowbreak
├── Models/
│   ├── Game.swift                  # Game 枚举 + GameServer 定义 + GameInstallState
│   ├── Config.swift                # AppConfig 结构体（Codable）
│   ├── DownloadTask.swift          # DownloadTask + DownloadProgress + ProgressEvent
│   └── WineDistribution.swift      # Wine 发行版模型
├── Views/
│   ├── GamePickerView.swift        # 侧边栏游戏选择
│   ├── LauncherView.swift          # 主启动器视图（ZStack 沉浸布局）
│   ├── ConfigurationView.swift     # 参考项目的配置 Sheet（垂直 Tab 布局）
│   ├── ProgressOverlayView.swift   # 进度覆盖层
│   └── WineInstallView.swift       # Wine 安装视图
└── Utilities/
    ├── BinaryUtils.swift           # 二进制操作工具
    ├── CommandBuilder.swift        # 命令构建
    └── Extensions.swift            # Swift 扩展
```

### 模块划分

- **应用层（YAAGLSWIFTUIApp.swift）：** @main 入口，通过 `.environment()` 向视图树注入 Service 实例
- **App 基础设施层（App/）：** DI 容器（AppContext）、EnvironmentKey 注册、AppDelegate 生命周期、根导航视图
- **服务层（Services/）：** 纯业务服务类，所有服务均为 `@Observable final class`，无 Protocol 抽象层。服务间通过初始化器参数注入
- **客户端层（Clients/）：** GameClient 协议定义 + 各游戏实现。每个客户端封装一款游戏的安装/更新/启动/完整性检查逻辑
- **模型层（Models/）：** 纯数据模型，不使用引用类型。Game 枚举 + AppConfig 结构体为主的 Codable 数据
- **视图层（Views/）：** 5 个主视图 + 配置相关子视图，通过 `@Environment(Service.self)` 直接获取服务
- **工具层（Utilities/）：** 工具函数和扩展，无对象状态

### 状态管理

- **@Observable 宏 + Service 即状态持有者：** 这是 YAAGLSWIFTUI 与 YAAGL/MiPlay 旧版本最核心的架构差异。不设立独立的 ViewModel 层，Service 自身通过 `@Observable` 宏的可观测属性（如 `GameService.statusText`、`ConfigService.config`）承担状态源的角色。视图直接通过 `@Environment(Service.self)` 读取这些属性，SwiftUI 自动追踪依赖并触发重渲染。
- **无 ViewModel 层：** 传统 MVVM 中的 ViewModel 职责直接由 Service 承担——Service 既包含业务逻辑又持有 UI 所需状态。这种模式在中等复杂度应用中减少了抽象层级。`@Observable` 宏带来的属性级追踪使视图仅读取它实际需要的属性，避免了 ObservableObject 的 "整个对象" 更新问题。
- **@State 本地状态：** 视图级别仅使用 `@State` 管理 UI 本地状态（如 `selectedTab`、`showAdvanced`、`isSettingsPresented`），避免视图层与 Service 层职责混淆。
- **@Bindable 可变绑定：** 当视图需要从子视图修改 Service 的可观测属性时（如 `ConfigView` 修改 `ConfigService.config.metalHudEnabled`），使用 `@Bindable var cfg = configService` 创建可变绑定。

### 依赖注入（DI）模式

- **中央容器（AppContext）：** 一个 `@Observable final class` 作为 DI 容器，在 `init()` 中按依赖顺序实例化所有 Service。Service 之间的引用通过构造器参数传递，形成明确的依赖链。
- **Environment 注入：** 在 `YaaglSwiftuiApp.swift` 的 `WindowGroup` 中使用 `.environment(appContext.configService)` 等方式将 Service 实例注入 SwiftUI Environment。每个 Service 以自身类型作为 EnvironmentKey 的 value 类型注册。
- **EnvironmentKey 注册模式：** `EnvironmentKeys.swift` 中为每个 Service 定义一个 `private struct XXXKey: EnvironmentKey`，设置 `defaultValue = XXXService()`，然后通过 `extension EnvironmentValues` 添加计算属性。视图通过 `@Environment(ConfigService.self)` 获取。
- **视图级按需注入：** 视图只声明它实际需要的 Service（如 `LauncherView` 注入 Config/Game/Wine/Download 4 个 Service），未使用的 Service 不在视图声明中。

### 异步模式

- **AsyncThrowingStream 替代生成器：** YAAGL 使用 TypeScript `AsyncGenerator` 产生进度元组；YAAGLSWIFTUI 使用 `AsyncThrowingStream<ProgressEvent, Error>` 作为异步操作的进度通道。`ProgressEvent` 是一个 enum，涵盖 `.download(DownloadProgress)`、`.extraction(current:total:)`、`.patch(current:total:)`、`.integrityCheck(current:total:)`、`.message(String)`、`.indeterminate`、`.completed`、`.failed(Error)` 等变体。
- **Service 层封装 AsyncThrowingStream：** `GameService.install(game:to:)` 等方法返回 `AsyncThrowingStream<ProgressEvent, Error>`，内部通过 `Task` 包装 GameClient 的流式方法。视图层通过 `for try await event in gameService.install(game:to:)` 消费事件。
- **async/await 基础：** 非流式异步操作（如 `installState(for:)`、`updateRequired(for:)`）直接使用 `async` 方法返回标量值。

### 线程安全

- **LockedDictionary<Key, Value>：** 一个基于 NSLock 的泛型线程安全字典，标记为 `@unchecked Sendable`。`ActiveTasksStore` 类型别名 `LockedDictionary<URL, URLSessionDownloadTask>` 用于管理活跃下载任务字典。
- **@unchecked Sendable + NSLock 模式：** 在需要绕过 `@MainActor` 隔离的 Service 属性（如 `DownloadService` 的 URLSession delegate）上使用 `@unchecked Sendable` + 显式锁，而非 actor 隔离，以维持访问灵活性和性能。
- **DownloadService 的非 actor 设计：** `DownloadService` 声明为 `@unchecked Sendable` 并持有 `nonisolated private let activeTasksStore`，确保 URLSession 回调可在非主线程执行。

### 任务管理

- **Swift Task 封装：** 耗时操作通过 `Task { }` 发起，内部使用 `for try await` 消费 GameClient 返回的 `AsyncThrowingStream`。
- **视图层进度管理：** 视图通过 `@State` 管理 `progress`、`statusText`、`isBusy` 等进度状态，在 `for try await` 循环中逐个更新。
- **串行操作保障：** 虽然没有显式的 "Task Queue" 结构，但 YAAGLSWIFTUI 中 Service 的方法是点对点调用的，从视图层看每次操作在 Task 内串行执行。

### 配置管理

- **AppConfig 纯净数据模型：** 一个 `Codable struct` 包含所有配置项，按领域分组（General、Game-Specific、Wine、Advanced）。支持 per-game install directory。
- **UserDefaults 持久化：** `ConfigService` 使用 `UserDefaults(suiteName:)` 存储 JSON 编码的 `AppConfig`。`didSet { save() }` 观测器确保每次变更自动保存。
- **@Observable ConfigService：** 配置服务本身是 `@Observable` 的，视图通过 `@Bindable var cfg = configService` 绑定到 `config.metalHudEnabled` 等具体属性。

### 导航模式

- **NavigationSplitView 三列布局（实际双列）：** 使用 `columnVisibility: .all` 显示 sidebar + detail 两列。Sidebar 固定宽度 200-260px，`navigationSplitViewStyle(.balanced)` 自动平衡两侧空间。
- **List + NavigationLink 侧边栏：** `GamePickerView` 使用 `List(Game.allCases, selection: $selectedGame)` + `NavigationLink(value: game)` 实现游戏选择。Sidebar 导航标题设为 "YAAGL"。
- **Detail 视图切换：** `LauncherView(game:)` 根据 `selectedGame` 变化重新初始化（通过 `onChange(of: game)` 触发刷新）。
- **Sheet 弹窗：** 这是 YAAGLSWIFTUI 参考项目的实现事实；不适用于当前 MiPlay。当前 MiPlay 使用独立 `Settings` Scene 和独立游戏详情 `WindowGroup`。

### 错误处理

- **GameError 枚举：** `GameService.GameError` 定义领域特定错误（notInstalled、executableNotFound、gameClientNotAvailable、installDirectoryNotFound）。
- **AsyncThrowingStream 的 .failed(Error) 变体：** `ProgressEvent.failed(Error)` 用于在进度流中传递失败信息，视图层通过 `catch` 分支处理或在 `handleProgressEvent` 中分发。
- **视图层错误展示：** 使用 SwiftUI `.alert` 修饰符展示 `errorMessage`，通过 `onChange` 或 `catch` 块设置。
