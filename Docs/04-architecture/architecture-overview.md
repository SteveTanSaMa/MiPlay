# MiPlay 分层架构概览

> **文档状态**：活跃（Active）
> **架构阶段**：Architecture Overview
> **更新日期**：2026-08-27
> **继承自**：Research Architecture Patterns、Product Domain、UX Information Model

## 1. 架构总览

MiPlay 采用经典的四层架构，严格遵循单向依赖原则：**UI → ViewModel → Domain → Infrastructure**。每一层只依赖其下层的抽象，不跨越层级或直接访问基础设施。

```text
┌─────────────────────────────────────────────────────────────┐
│                        UIWindow Layer                        │
│  MainWindow | SettingsWindow | GameDetailWindow | Sheet     │
│                       ↓                                        │
│                  UI Components                               │
├─────────────────────────────────────────────────────────────┤
│                     UI ViewModel Layer                       │
│     LibraryViewModel | SettingsViewModel | GameDetailViewModel│
│                       ↓                                        │
│                  @Observable State                           │
├─────────────────────────────────────────────────────────────┤
│                       Domain Layer                           │
│   GameRegistry | GameStateMachine | LaunchOrchestrator      │
│   SolutionEngine | TaskScheduler | VersionChecker           │
│                       ↓                                        │
│                   Domain Services                            │
├─────────────────────────────────────────────────────────────┤
│                   Infrastructure Layer                       │
│   PersistenceStore | FileSystem | Network | Process | Wine  │
│   Logger | MediaTranscoder | DownloadManager                │
└─────────────────────────────────────────────────────────────┘
```

## 2. 分层职责定义

### 2.1 UIWindow Layer (UI 层)

**职责**：纯视图层，负责像素渲染和用户输入接收。不包括任何业务逻辑、状态决策或任务执行。

**核心组件**：
- **MainWindow**：应用主窗口，沉浸式背景 + 游戏切换条 + 主操作按钮
- **SettingsWindow**：独立设置场景，NavigationSplitView 双栏布局
- **GameDetailWindow**：游戏详情独立窗口，兼容方案/性能/日志
- **WineProgressSheet**：Wine 安装进度 Sheet/Overlay
- **UI Components**：Liquid Glass 控件、背景素材、状态反馈组件

**输入**：从 ViewModel 的 @Observable 属性直接绑定渲染
**输出**：用户交互事件 → 调用 ViewModel 方法或通过 Action 通知 Service

### 2.2 UI ViewModel Layer (视图模型层)

**职责**：视图状态管理和业务规则表达。每个 ViewModel 负责一个主窗口的状态呈现，使用 `@Observable` 宏实现细粒度观察。

**核心组件**：
- **LibraryViewModel**：主窗口状态。管理当前选游戏、背景素材、游戏状态、主按钮状态、进度反馈
- **SettingsViewModel**：设置窗口状态。管理配置值、Wine 状态、游戏信息、读取/保存操作
- **GameDetailViewModel**：详情窗口状态。管理兼容方案列表、方案应用/回滚状态、风险确认

**关键原则**：
- 不包含业务逻辑，只表达 Domain 层的状态和意图
- 不直接调用 Infrastructure，所有持久化/网络/进程操作委托给 Domain
- 通过构造器注入或 Environment 获取 Domain 服务引用

### 2.3 Domain Layer (领域层)

**职责**：核心业务逻辑、状态机、编排协调、任务调度。所有业务规则在这里实现。

**核心 Agent**：
- **GameRegistry**：游戏注册、路径管理、权限验证
- **GameStateMachine**：游戏生命周期状态机，状态转换规则
- **LaunchOrchestrator**：游戏启动编排器，协调文件、权限、环境、进程
- **SolutionEngine**：兼容方案引擎，方案应用/回滚控制
- **TaskScheduler**：任务调度器，Task 生命周期管理
- **VersionChecker**：版本检测，本地与官方版本比较
- **PreLaunchValidator**：启动前置验证，综合检查

**关键原则**：
- 所有状态变化通过任务（Task）实现
- 不直接访问文件系统/网络/进程，委托 Infrastructure
- 定义明确的业务结果事实（Success Facts）和错误恢复路径

### 2.4 Infrastructure Layer (基础设施层)

**职责**：提供技术上可复用的底层服务，封装系统资源访问。全部使用 `actor` 实现线程安全。

**核心 Actor**：
- **PersistenceStore**：JSON 文件持久化存储
- **FileSystem**：文件系统操作（路径、权限、完整性校验）
- **NetworkService**：HTTP 下载、版本信息获取
- **ProcessManager**：进程创建、管理、监控
- **WineRuntimeProvider**：Wine 运行时管理、prefix 操作
- **Logger**：日志记录
- **MediaService**：背景视频/图片加载、转码、缓存

**关键原则**：
- 纯技术实现，无业务逻辑
- 通过 protocol 抽象，便于测试和替换
- 每个 actor 有自己独立的状态，状态不共享

## 3. 模块分解

### 3.1 UI 模块结构

```
MiPlay/UI/
├── Components/              # 可复用 UI 组件
│   ├── BackgroundScene.swift        # 沉浸式背景层
│   ├── GameSelectionRailView.swift  # 游戏切换栏
│   ├── PrimaryActionButton.swift    # 主操作按钮
│   ├── TaskFeedbackView.swift       # 任务反馈组件
│   ├── WineProgressUnit.swift       # Wine 进度细节
│   └── GlassEffectContainer.swift   # 玻璃材质容器
│
├── MainWindow/                # 主窗口场景
│   ├── MainWindowScene.swift    # 窗口定义和生命周期
│   ├── BackgroundView.swift     # 背景视图
│   ├── GameRailView.swift       # 游戏选择栏视图
│   └── PrimaryActionView.swift  # 主操作区视图
│
├── SettingsWindow/            # 设置窗口场景
│   ├── SettingsWindowScene.swift # 窗口定义
│   └── SettingsView.swift        # NavigationSplitView 内容
│
├── GameDetailWindow/          # 详情窗口场景
│   ├── GameDetailWindowScene.swift
│   └── GameDetailView.swift
│
└── ViewModels/                # 视图模型层
    ├── LibraryViewModel.swift        # 主窗口状态
    ├── SettingsViewModel.swift       # 设置窗口状态
    └── GameDetailViewModel.swift     # 详情窗口状态
```

### 3.2 Domain 模块结构

```
MiPlay/Domain/
├── Game/                          # 游戏相关
│   ├── Game.swift                    # Game 枚举定义
│   ├── GameLocation.swift            # 游戏路径授权
│   ├── GameRegistry.swift            # 游戏注册服务
│   ├── GameStateMachine.swift        # 游戏状态机
│   ├── PreLaunchValidator.swift      # 启动前置验证
│   └── LaunchOrchestrator.swift      # 启动编排器
│
├── Solution/                        # 兼容方案
│   ├── CompatibilitySolution.swift     # 方案定义
│   ├── SolutionEngine.swift            # 方案执行引擎
│   ├── SolutionApplication.swift       # 方案应用状态
│   └── RollbackOrchestrator.swift      # 回滚编排
│
├── Runtime/                         # 运行环境
│   ├── ManagedWineState.swift          # Wine 运行时状态
│   ├── WinePreflightChecker.swift      # 环境预检
│   └── PrefixManager.swift             # 共享 prefix 管理
│
├── Update/                          # 更新
│   ├── VersionChecker.swift            # 版本检测
│   ├── UpdateChecker.swift             # 更新可用性检查
│   └── GameConfigManager.swift         # 游戏配置管理
│
├── Utility/                         # 工具
│   ├── TaskScheduler.swift             # 任务调度器
│   ├── TaskQueue.swift                 # 任务队列实现
│   └── ErrorRecovery.swift             # 错误恢复策略
│
└── Protocols/                       # 领域协议
    ├── GameStateService.swift
    ├── LaunchService.swift
    ├── SolutionService.swift
    └── UpdateService.swift
```

### 3.3 Infrastructure 模块结构

```
MiPlay/Infrastructure/
├── Persistence/                     # 持久化
│   └── PersistenceStore.swift          # JSON 存储 actor
│
├── FileSystem/                      # 文件系统
│   ├── FileService.swift               # 文件操作
│   ├── IntegrityVerifier.swift         # 完整性校验
│   └── LocationManager.swift           # 路径授权管理
│
├── Network/                         # 网络
│   ├── NetworkService.swift            # HTTP 客户端
│   ├── DownloadManager.swift           # 下载管理
│   └── VersionFetcher.swift            # 版本信息获取
│
├── Process/                         # 进程管理
│   └── ProcessManager.swift            # 进程生命周期管理
│
├── Wine/                            # Wine 运行时
│   ├── WineRuntimeProvider.swift       # Wine 提供器
│   ├── WineInstaller.swift             # Wine 安装器
│   ├── WinePrefixInstaller.swift       # Prefix 安装器
│   └── WineVersionFactory.swift        # Wine 版本工厂
│
├── Logging/                         # 日志
│   └── Logger.swift                    # 日志 actor
│
└── Media/                           # 媒体素材
    ├── BackgroundVideoPlayer.swift     # 视频播放器
    ├── ImageBasedBackground.swift      # 图片背景
    ├── MediaCache.swift                # 媒体缓存
    └── MediaTranscoder.swift           # 转码服务
```

## 4. 依赖关系图

```
UI ← ViewModel ← Domain ← Infrastructure

依赖注入流程：
MiPlayApp 构造顺序：
Infrastructure (创建 Actor) 
    ↓ 注入到
Domain (创建 Service，依赖 Infrastructure)
    ↓ 注入到
ViewModel (创建 @Observable，依赖 Domain)
    ↓ 注入到
UI (创建 View，依赖 ViewModel)
```

### 4.1 层依赖规则

- ✅ **允许**：上层依赖下层
- ✅ **允许**：同层模块间的接口依赖
- ❌ **禁止**：下层依赖上层
- ❌ **禁止**：跨层依赖（如 UI 直接访问 Infrastructure）
- ❌ **禁止**：同级循环依赖

### 4.2 单向依赖证明

通过构造器注入实现：

```swift
// Infrastructure - 无依赖
final class PersistenceStore { }

// Domain - 依赖 Infrastructure
final class GameRegistry {
    private let fileService: FileService
    private let persistenceStore: PersistenceStore
    
    init(fileService: FileService, persistenceStore: PersistenceStore) {
        self.fileService = fileService
        self.persistenceStore = persistenceStore
    }
}

// ViewModel - 依赖 Domain
final class LibraryViewModel {
    private let gameRegistry: GameRegistry
    private let gameStateMachine: GameStateMachine
    
    init(gameRegistry: GameRegistry, gameStateMachine: GameStateMachine) {
        self.gameRegistry = gameRegistry
        self.gameStateMachine = gameStateMachine
    }
}

// UI - 依赖 ViewModel
struct MainWindow: View {
    @ObservedObject var viewModel: LibraryViewModel
    
    var body: some View {
        // 纯渲染
    }
}
```

## 5. 数据流方向

### 5.1 正向流（用户操作 → 系统响应）

```
用户点击 → UI 调用 ViewModel → ViewModel 调用 Domain 服务 → 
Domain 调用 Infrastructure → Infrastructure 执行操作 → 
返回结果 → Domain 更新业务状态 → ViewModel 读取新状态 → 
UI 重新渲染
```

### 5.2 反向流（系统通知 → UI 更新）

```
Infrastructure 完成异步操作 → 通过 Task/Continuation/AsyncStream 通知 Domain → 
Domain 更新领域模型 → ViewModel 的 Observable 属性变更 → 
SwiftUI 自动触发视图重渲染
```

### 5.3 异步流处理

- **ViewModel**：使用 `Task` 包装 Domain 调用，通过 `@State` 管理任务状态
- **Domain**：使用 `actor` 封装基础设施调用，通过 `AsyncStream`/`AsyncThrowingStream` 返回进度事件
- **Infrastructure**：使用 `Task` 和 Continuation 管理异步操作

## 6. 错误传播路径

```
Infrastructure 错误 → 封装为 Domain Error → 传递到 ViewModel → 显示给用户

错误原则：
1. Infrastructure 返回具体错误类型（NetworkError, IOError, ProcessError）
2. Domain 封装领域错误（LaunchFailed, PreflightError, SolutionApplyError）
3. ViewModel 保持错误模型不变，只改变文案
4. UI 展示错误事实 + 恢复动作，不猜测错误原因
```

## 7. 状态流动

1. **Task State**：`pending` → `running` → `completed/failed/cancelled`
2. **Business State**：由 Domain 状态机管理（Game 状态、Wine 状态等）
3. **Result Facts**：由任务完成的业务结果决定

三个层级独立，任何一层不能替代另一层。

## 8. 架构决策约束

- **主框架**：SwiftUI（App lifecycle）
- **语言版本**：Swift 6.4
- **最低部署**：macOS 26+
- **芯片架构**：Apple Silicon (arm64)
- **并发模型**：actor + @MainActor + Async/Await
- **状态管理**：@Observable（ViewModel & Service） + actor（Domain & Infra）
- **持久化**：JSON 文件 + PersistenceStore actor
- **依赖注入**：构造器注入 + Environment 注入的混合模式

## 9. 模块清单

| 模块 | 关键类/Actor | 作用 |
|------|--------------|------|
| PersistenceStore | actor | JSON 文件持久化存储 |
| FileService | actor | 文件系统操作 |
| IntegrityVerifier | actor | 游戏文件完整性校验 |
| NetworkService | actor | HTTP 网络请求 |
| ProcessManager | actor | 进程创建和监控 |
| WineRuntimeModule | actor | Wine 运行时管理 |
| GameRegistry | Service | 游戏注册和路径管理 |
| GameStateMachine | Service | 游戏状态机 |
| LaunchOrchestrator | Service | 游戏启动编排 |
| SolutionEngine | Service | 兼容方案执行 |
| TaskScheduler | Service | 任务调度器 |
| LibraryViewModel | @Observable | 主窗口状态管理 |
| SettingsViewModel | @Observable | 设置窗口状态管理 |

---

> **注意**：架构设计是静态的，具体实现细节需要遵循架构模式文档和领域模型文档。

