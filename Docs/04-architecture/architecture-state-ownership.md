# MiPlay 状态所有权与传播

> **文档状态**：活跃（Active）
> **状态阶段**：State Ownership
> **更新日期**：2026-08-27
> **继承自**：UX Information Model、UX State Flow

## 1. 状态分层原则

MiPlay 维护三层独立的状态，**任何一层都不能替代另一层**：

1. **Task State**（任务状态）：任务的生命周期，描述“请求是否被接受、执行中、完成、失败或取消”。
2. **Business State**（业务状态）：Game、Runtime、Solution 等业务实体的最终状态，描述“系统当前处于什么业务事实”。
3. **Result Facts**（结果事实）：任务完成时产生的业务结果，描述“任务达成了什么具体业务目标”。

这三层必须**同时可读**，且**分开存储/传播**。

### 1.1 三层关系

```
用户点击 → Task created (pending) → Task running → 
Domain 执行 → Business State 变更 → Result Facts 产生 → 
Task completed + outcome + recovery

UI 同时展示三层：
- 任务状态：正在执行中...
- 业务状态：游戏未启动（原状态不变）
- 结果事实：前置校验未通过，请修复后重试
```

### 1.2 禁止的混淆行为

- ❌ 不得用 `TaskStatus.completed` 推断业务成功
- ❌ 不得用业务状态 `Running` 代替任务状态
- ❌ 不得用结果事实 `PreFlightRejection` 覆盖业务状态
- ❌ 不得用进程创建（Infrastructure 中间事实）作为成功终态

## 2. 状态归属 (State Ownership)

### 2.1 谁拥有状态？(Owner)

| 状态类型 | 所有权实体 | 修改权限 | 观察者 |
|---------|-----------|---------|--------|
| **GameBusinessState** | `GameRegistry` (作为聚合根) | 仅 `GameStateMachine` 可修改 | `TaskScheduler`, `LaunchOrchestrator`, `ViewModel` |
| **TaskState** | `TaskScheduler` | 仅 `TaskScheduler` 可修改 | `ViewModel`, 相关 Domain 服务 |
| **RuntimeReadiness** | `WineVersionManager` (聚合根) | 仅 `WineRuntimeSetup` / `WinePreflightChecker` 可修改 | `GameRegistry`, `ViewModel` |
| **SolutionApplication** | `SolutionEngine` | 仅 `SolutionEngine` 可修改 | `GameRegistry`, `ViewModel` |
| **IntegrityCheckResult** | `FileIntegrityVerifier` | 仅 `FileIntegrityVerifier` 可修改 | `GameRegistry`, `ViewModel` |
| **VersionCheckResult** | `VersionChecker` | 仅 `VersionChecker` 可修改 | `GameRegistry`, `ViewModel` |
| **GameLocation** | `GameRegistry` | 仅用户提交路径时修改，需经过 `LocationRecoveryFact` 验证 | `FileSystem`, `ViewModel` |

### 2.2 关键原则

- **GameRegistry 作为 Game 的业务状态中心**：所有 Game 的业务状态变更必须通过 `GameRegistry` 的 `updateState()` 方法，并触发领域事件。
- **TaskScheduler 作为任务状态的唯一写入者**：任何服务可以请求状态变更，但只有 `TaskScheduler` 可以真正修改 `Task.status` 并记录 `TaskId`。
- **Domain 服务不可 muccha/直接观察**：ViewModel 不能直接 `@ObservedObject` 一个 `Actor`。必须通过 `EventStream` 或 `Snapshot` 机制。

### 2.3 状态机约束 (GameStateMachine)

`GameStateMachine` 是 `Game` 状态转换的**唯一合法校验器**。它不执行 I/O，只接受来自 `LaunchOrchestrator`、`PreLaunchValidator`、`IntegrityVerifier` 的结果。

**有限状态自动机**：
- 状态：`PathUnset`, `NotInstalled`, `Installed`, `UpdateAvailable`, `GameUpdating`, `Launching`, `Running`, `LaunchFailed`
- 转换规则：见 `ux-state-flow.md`，例如 `Installed` 点击启动 → `Launching` → `Running` 或 `LaunchFailed`
- 禁止非法转换：如 `NotInstalled` → `Running` 立即跳转。

## 3. 状态传播方式

### 3.1 ViewModel 与 Domain 的连接模型

**禁止的直接绑定**：
```swift
// ❌ 禁止：直接持有一个 Observable Actor
final class GameRegistry: @Observable {
    var games: [Game] = []
}
// ViewModel:
final class LibraryViewModel {
    @ObservedObject var registry: GameRegistry // 错误
}
```

**正确的异步订阅模式**：
```swift
// ✅ 允许：Domain 服务通过 AsyncStream 发布事件
final class GameRegistry {
    private let eventStream: AsyncStream<GameEvent>
    func eventStream() -> AsyncStream<GameEvent> { ... }
}

// ViewModel 订阅
final class LibraryViewModel {
    private var cancellables = Set<AnyCancellable>()
    
    init(registry: GameRegistry) {
        Task {
            for await event in registry.eventStream {
                await MainActor.run {
                    updateProjection(from: event)
                }
            }
        }
    }
}
```

### 3.2 投影构建 (Projection)

**ViewModel 不保存业务状态**，只保存投影数据用于渲染。

```swift
struct GameProjection {
    let gameId: String
    let displayName: String
    let installStatus: String // Only for rendering
    let launchStatus: String  // Only for rendering
    let primaryButtonState: PrimaryButtonState
    let taskSnapshot: TaskSnapshot?
}

final class LibraryViewModel {
    @ Observable
    var projections: [String: GameProjection] = [:]
    
    func updateProjection(from event: GameEvent) {
        // 从事件构造投影，不包含业务逻辑
        let projection = GameProjection(
            gameId: event.gameId,
            displayName: event.displayName,
            installStatus: event.game.installStatus.description,
            launchStatus: event.game.launchStatus.description,
            primaryButtonState: determinePrimaryButton(for: event.game),
            taskSnapshot: event.taskSnapshot
        )
        projections[event.gameId] = projection
    }
}
```

### 3.3 快照与事件流 (Snapshot & Event Stream)

Domain 向 ViewModel 提供两种消费方式：

1. **Snapshot（初始状态 + 增量快照）**：用于快速加载 UI，减少事件风暴。
2. **EventStream（顺序事件流）**：用于增量更新，保证顺序和一致性。

**规则**：
- ViewModel 必须先获取 **带序列号的初始快照**，然后订阅 **事件流**。
- 事件必须在 **序列号之后** 才能应用，防止乱序。
- 任何 **`recoveryRequired`** 事件必须暂停发布消费者结果，直到恢复完成。

## 4. 状态变更事务性

### 4.1 原子性原则

一个业务操作可能涉及多个状态变更，但必须保证 **在一个原子事务内** 完成：

**示例：游戏启动**
```
1. TaskScheduler: GameLaunch(taskId) → status=pending
2. PreLaunchValidator: 结果 = Failed
3. TaskScheduler: status=failed, error=...
4. GameRegistry: BusinessState 不变 (仍为 Installed)
5. LaunchOrchestrator: 不产生副作用
```

**反例：分裂的事务**
```
1. GameRegistry: 立即将 GameStatus 设为 Running
2. TaskScheduler: 还未创建 task，status 未更新
→ 错误：UI 显示 Running，但任务未开始
```

### 4.2 回滚一致性

**关键对象**：
- `SolutionApplication` 状态变更必须与 `RollbackOrchestrator` 的状态联动。
- `RestartRecoveryFact` 必须在进程退出后读取确认，才能更新游戏状态。

**原则**：
- 产生副作用的操作（修改文件、创建进程）必须进行 **后置验证**。
- 如果验证失败，必须 **自动回滚** 到应用前状态。
- 回滚开始后 **不可取消**，必须等待恢复验证完成。

### 4.3 保护状态 (Guard States)

以下状态必须作为 **保护性事实**，阻止其他并发操作：

- `recoveryRequired`：任何恢复未确认的状态，阻止新的副作用任务。
- `recoveryCommitPending`：恢复提交待确认，阻止发布结果。
- `prefixOccupancy.busy`：共享 prefix 正在使用中，阻止新的初始化。
- `LocationRecoveryFact.locationRefreshPersistenceFailed`：路径刷新但未保存，阻止发布成功。

**传播规则**：这些状态是 **最高优先级**，UI 和 Domain 必须立即响应，暂停其他操作。

## 5. 可观测性设计

### 5.1 Domain 服务作为事件源

**禁止**：Service 直接标记为 `@Observable`。

**推荐**：每个 Domain 服务提供一个 **事件发布器**：

```swift
protocol GameEventSource {
    var gameEvents: AsyncStream<GameEvent> { get }
    func takeSnapshot() -> GameSnapshot
}

final class GameRegistry: GameEventSource, GameRegistryProtocol {
    private let eventSubject = AsyncStream<GameEvent>.makeStream()
    var gameEvents = eventSubject.stream
    
    func updateState(_ state: GameLaunchStatus) {
        // 修改游戏状态
        // 发送事件
        eventSubject.yield(GameEvent(...))
    }
}
```

### 5.2 ViewModel 的投影缓存

ViewModel 会缓存投影数据以优化渲染，但必须 **与最新事件保持一致**：

```swift
final class LibraryViewModel {
    private var lastSnapshotSeq: Int = 0
    private var pendingEvents: [GameEvent] = []
    
    func processEvent(_ event: GameEvent) {
        guard event.sequenceNumber > lastSnapshotSeq else {
            // 乱序事件，丢弃或重组
            return
        }
        lastSnapshotSeq = event.sequenceNumber
        updateProjection(from: event) // 只更新 UI 需要的字段
    }
}
```

### 5.3 Accessibility Projection

**特殊投影**：辅助功能的状态必须从 **结构化数据** 生成，不依赖视觉层。

```swift
struct AccessibilityProjection {
    let role: AXRole
    let label: String
    let value: String
    let hint: String?
    let enabled: Bool
    let busy: Bool
    let recoveryAction: String?
}
```

**生成规则**：
- 由对应 `@MainActor` ViewModel 从结构化快照/事件生成。
- 不依赖颜色、文字阴影、玻璃材质等视觉效果。
- 进度必须真实：有数值时显示百分比，无数值时显示“进行中”。

## 6. 状态不敏感性 (State Indifference)

### 6.1 无状态 Service

**禁止**：Service 持有可变的业务状态。

**推荐**：Service 只包含业务逻辑，状态通过参数传递：

```swift
final class LaunchOrchestrator {
    func launch(_ game: Game, _ runtime: RuntimeReadiness) 
    async throws -> LaunchOutcome {
        // 只执行逻辑，不保存状态
        // 返回结果，由调用者负责更新状态
    }
}
```

### 6.2 事件驱动的状态机

`GameStateMachine` 不保存状态，只校验：

```swift
struct GameStateMachine {
    func validateTransition(from: GameLaunchStatus, to: GameLaunchStatus) -> Bool {
        // 检查转换是否合法
    }
}

// GameRegistry 持有实际状态
final class GameRegistry {
    var currentStatus: GameLaunchStatus = .PathUnset
    
    func tryTransition(to: GameLaunchStatus) throws {
        guard GameStateMachine.validateTransition(from: currentStatus, to: to) else {
            throw InvalidStateTransitionError()
        }
        currentStatus = to
        // 发送事件
    }
}
```

## 7. 状态文档化

### 7.1 状态映射表

以下表格定义了每项业务的 **状态所有权** 和 **传播规则**：

| 业务对象 | 状态类型 | 所有权 | 修改者 | 观察者 | 是否持久化 | 优先级 |
|---------|---------|--------|--------|--------|------------|----------|
| Game | GameLaunchStatus | GameRegistry | GameStateMachine | ViewModel, TaskScheduler | 是 | 高 |
| Game | GameInstallStatus | GameRegistry | IntegrityVerifier | ViewModel, TaskScheduler | 是 | 高 |
| Task | TaskStatus | TaskScheduler | TaskScheduler | ViewModel, Affected Services | 否 | 中 |
| Runtime | RuntimeReadiness | WineVersionManager | WinePreflightChecker | GameRegistry, ViewModel | 是 | 高 |
| Solution | SolutionApplication | SolutionEngine | SolutionEngine | GameRegistry, ViewModel | 是 | 高 |

### 7.2 状态转换矩阵

关键状态转换必须被记录在 `ux-state-flow.md` 中，并在此文档中引用。

**示例：游戏启动流**
- `Installed` → `Launching` (用户点击启动)
- `Running` (进程确认后)
- `LaunchFailed` (前置校验失败/进程启动失败/异常退出)

## 8. 实现约束

- ❌ **禁止**：一个 `@Observable` Service 作为所有 Domain/Infrastructure 服务的并发方案。
- ❌ **禁止**：直接把 Domain Actor 的属性暴露给 ViewModel 进行双向绑定。
- ❌ **禁止**：将任务 `completed` 单独升级为业务成功（如 `Running`）。
- ❌ **禁止**：在“未恢复”的状态下发布新的业务事实。

---

> **注意**：状态所有权是系统一致性的基石。每个 Agent 在实现时必须严格遵守此文档中的归属规则和传播方式。如有冲突，以 **Domain 作为唯一的状态源** 为准。

