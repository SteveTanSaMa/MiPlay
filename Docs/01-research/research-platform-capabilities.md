# Platform Capabilities — macOS 26+ Liquid Glass

> **接收方：** UI Agent、Implementation Agent
> **内容：** macOS 26+ 平台能力（Liquid Glass）的事实性参考，包含 API、材质体系、性能说明
> **状态：** 研究阶段输出 — 仅提供事实参考，不作设计决策
> **更新策略：** 随 Apple 平台版本更新（macOS 27+ 新增 API 时补充到本文档，无需修改 Pattern Library）

---

## Liquid Glass 材质体系

Liquid Glass 是 macOS 26+ 引入的动态材质系统，结合玻璃的光学特性和流动性。标准 SwiftUI/AppKit 组件自动获得 Liquid Glass 外观。

### 自动适配范围

以下标准组件在 macOS 26+ SDK 上自动应用 Liquid Glass 材质，无需额外代码：

- **窗口**（Window）— 应用窗口背景
- **侧边栏**（NavigationSplitView Sidebar）— 自动渲染为半透明玻璃材质
- **菜单**（Menu）— 菜单和菜单项
- **表单组**（Form / Grouped Form）— 分组卡片布局
- **工具栏**（Toolbar）— 自动适配
- **通知横幅**（Notification Banner）
- **弹窗与 Sheet**（Popover / Sheet）
- **开关、滑块、选择器**等标准控件

---

## SwiftUI API

### glassEffect

为任意 View 添加 Liquid Glass 材质。

```swift
func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
```

**参数：**
- `glass`：`Glass` 配置实例，控制材质外观
- `shape`：定义玻璃效果边界的 Shape

**示例：**
```swift
Text("Hello")
    .padding()
    .glassEffect()

// 自定义 tint
.glassEffect(.tint(.blue))

// 交互态材质
.glassEffect(Glass.tint(.purple).interactive(true))
```

### Glass

定义 Liquid Glass 材质的配置结构体。

```swift
struct Glass
```

**变体：**
| 变体 | 描述 |
|------|------|
| `.regular` | 标准 Liquid Glass 材质 |
| `.tint(Color?)` | 带 tint 色的玻璃，传 nil 移除 tint |
| `.interactive(Bool = true)` | 交互态材质，响应 hover 和用户输入 |

### GlassEffectContainer

将多个 Liquid Glass 效果聚合到同一个形状容器中，支持形状间平滑变换。

```swift
struct GlassEffectContainer<Content> where Content : View
```

**示例：**
```swift
GlassEffectContainer {
    Text("First").padding().glassEffect()
    Text("Second").padding().glassEffect()
}
```

### GlassEffectTransition

玻璃材质的出现/消失过渡动画。

| 过渡类型 | 描述 |
|---------|------|
| `.glassMaterialize` | 淡入内容 + 玻璃材质动画 |
| `.glassMatchedGeometry(from:in:)` | 几何匹配过渡 |

**示例：**
```swift
.animation(.easeInOut) {
    if showContent {
        Text("Content")
            .glassEffect()
            .transition(.glassMaterialize)
    }
}
```

### Glass 按钮样式

```swift
Button("Action") { }
    .buttonStyle(.glass)
```

使用 Liquid Glass 材质渲染按钮，提供视觉深度和玻璃特征。

### backgroundExtensionEffect

将内容扩展到侧边栏和 Inspector 后方。

```swift
func backgroundExtensionEffect() -> some View
```

---

## AppKit API（macOS 26+）

### NSGlassEffectView

AppKit 层原生 Liquid Glass 视图。

```swift
class NSGlassEffectView
```

**属性：**
| 属性 | 描述 |
|------|------|
| `style: GlassStyle` | `.regular` / `.prominent` / `.subtle` |
| `glassColor: GlassColor` | `.default` 或自定义 |

**示例：**
```swift
let glassView = NSGlassEffectView(frame: view.bounds)
glassView.style = .regular
glassView.glassColor = .default
view.addSubview(glassView, positioned: .below, relativeTo: nil)
```

### NSVisualEffectView（macOS 10.10+）

兼容性视觉特效视图。

**材质类型：**
`.titlebar` / `.selection` / `.menu` / `.popover` / `.sidebar` / `.headerView` / `.sheet` / `.windowBackground` / `.hudWindow` / `.fullScreenUI`

**状态：**
| 值 | 描述 |
|----|------|
| `.followsWindowActiveState` | 根据窗口激活状态自动更新 |
| `.active` | 效果始终激活 |
| `.inactive` | 效果始终停用 |

---

## Material 材质层级

SwiftUI 提供 5+1 级材质透明度变体：

| 层级 | 材质 | 透明度 | 典型用途 |
|------|------|--------|---------|
| 最透明 | `.ultraThinMaterial` | 极高 | 最底层背景装饰 |
| 透明 | `.thinMaterial` | 高 | 浮层背景、Popover |
| 标准 | `.regularMaterial` | 中 | 侧边栏、工具栏、标准背景 |
| 不透明 | `.thickMaterial` | 低 | 强调容器、深色模式组件 |
| 最不透明 | `.ultraThickMaterial` | 极低 | 需要最强存在感的层级 |
| 特殊 | `.barMaterial` | — | 工具栏/标签栏专用 |

**应用规则：** 更透明的材质在视觉上"更靠后"，更不透明的材质"更靠前"。通过材质透明度自然表达 UI 层次，不需要额外边框或阴影。

---

## 视觉参数参考（macOS 26+）

### Z 轴层级体系

```
L0: Desktop Wallpaper
L1: Menu Bar (34px)
L2: Glass Overlay (rgba(255,255,255,0.08~0.15))
L3: Application Window
L4: Overlay (rgba(0,0,0,0.2) — Window Modal)
L5: Alert / Dialog
L6: Floating Menus
L7: Dock
```

### 窗口圆角体系

| 元素 | 圆角 |
|------|------|
| 文档窗口 | 16-26px |
| 工具窗口 | 15px |
| 对话框 | 10-26px |
| 弹窗 | 10px |
| 通知横幅 | 16px |
| 菜单 | 13px |
| Sidebar | 8px / 18px |
| Dock | 15px |
| 胶囊按钮 | 100px |
| 直角按钮 | 6px |
| TextField | 6px |
| Checkbox | 5.5px |

### 阴影体系

| 层级 | 阴影值 |
|------|--------|
| 窗口级 | `0px 0px 0px 1px rgba(0,0,0,0.23)` + `0px 16px 48px rgba(0,0,0,0.35)` |
| 工具窗口 | `0px 5px 20px rgba(0,0,0,0.3)` |
| 弹窗（外层） | `drop-shadow(0px 0px 1px rgba(0,0,0,0.2))` + `drop-shadow(0px 17px 45px rgba(0,0,0,0.5))` |
| 弹窗（内层） | `box-shadow: 0px 8px 40px rgba(0,0,0,0.12)` |

---

## 性能说明

1. **动态材质有 GPU 开销** — Liquid Glass 材质依赖 GPU 实时渲染模糊和混合效果。对于窗口数量少、内容更新不频繁的界面（如 MiPlay 的主窗口），影响可忽略。
2. **过度使用会失去层次感** — 不应为所有元素添加玻璃效果。推荐策略：系统控件使用自动适配，自定义控件在需要表达层级时使用。背景层（沉浸式背景 L0/L1）不应使用 Liquid Glass。
3. **`GlassEffectContainer` 优化** — 同一区域多个玻璃效果视图应使用 `GlassEffectContainer` 聚合渲染，减少独立离屏渲染的消耗。
4. **Low Power 模式** — 在低功耗模式下材质效果可能自动降级（模糊半径减小），设计时应确保降级后界面仍然可用。

---

## Apple 推荐使用场景

- **窗口和面板背景** — 标准窗口背景自动适配，无需额外操作
- **侧边栏和分割视图** — NavigationSplitView sidebar 自动使用适配的玻璃材质
- **工具栏和搜索栏** — 标准 Toolbar 自动适配
- **浮层和弹出窗口**（Popover / Sheet / Menu）— 系统自动处理
- **自定义控件背景** — 使用 `.glassEffect()` 为自定义交互元素提供材质背景
- ****不推荐**：** 沉浸式全屏背景（应使用纯色/图片/视频）；需要精确色彩匹配的品牌区域；低端硬件上的高频更新界面

---

> **来源：** `References/Apple/apple-liquid-glass-docs/`（04-SwiftUI-API-Reference.md, 05-macOS-AppKit-API-Reference.md, 06-SwiftUI-Material-Reference.md, 02-Adopting-Liquid-Glass-Guide.md）、`References/Apple/macOS-26-设计规范.md`


---

## SwiftUI macOS API 能力覆盖（YAAGLSWIFTUI 参考）

### NavigationSplitView（macOS 13+）

SwiftUI 的原生分栏导航组件，提供 macOS 标准的侧边栏 + 内容区布局。

| 属性 | 描述 |
|------|------|
| **最低部署** | macOS 13+（YAAGLSWIFTUI 全面采用） |
| **API** | `NavigationSplitView(columnVisibility:sidebar:detail:)` + `navigationSplitViewStyle()` + `navigationSplitViewColumnWidth()` |
| **列模式** | .all（三列全显）、.doubleColumn（双列）、.detailOnly（仅详情） |
| **样式** | `.balanced`（自动平衡各列宽度）、`.prominentDetail`（详情优先） |
| **Sidebar** | `List` + `NavigationLink(value:)` + `List(selection:)` 实现选中态 |
| **替代方案** | 自定义 ZStack 布局（MiPlay 旧版本采用）、NavigationStack（macOS 14+）、TabView |

### @Observable 宏（Swift 6 / macOS 26+）

| 属性 | 描述 |
|------|------|
| **最低部署** | macOS 26+（标准 Swift 6 特性）、Swift 5.9+（@Observable 预览） |
| **覆盖能力** | 替代 `ObservableObject` + `@Published` + `@StateObject` 组合 |
| **特性** | 属性级追踪（编译器生成观察访问器），零运行时开销 |
| **限制** | 仅支持引用类型（class）；跨 Sendable 边界使用时需注意 @MainActor |

### AsyncThrowingStream（Swift 5.5+）

| 属性 | 描述 |
|------|------|
| **最低部署** | macOS 12+ |
| **覆盖能力** | 异步序列协议，替代闭包回调、Delegate 回调、Combine Publisher |
| **使用模式** | `AsyncThrowingStream<Element, Failure>` 构造 + `continuation.yield()` / `continuation.finish()` |
| **生命周期** | 需确保所有代码路径均调用 `finish()` 避免视图层永久挂起 |

### AsyncImage（macOS 13+）

| 属性 | 描述 |
|------|------|
| **最低部署** | macOS 13+ |
| **覆盖能力** | 声明式远程图片加载，替代 `URLSession` + `NSImage(contentsOf:)` |
| **使用模式** | `AsyncImage(url:)` 或 `AsyncImage(url:scale:)`，支持 `content` + `placeholder` 参数 |
| **限制** | 无内置缓存策略；不支持渐进式加载；每次视图重绘可能重新发起网络请求 |

### environment / @Environment 注入（SwiftUI 基础）

| 属性 | 描述 |
|------|------|
| **最低部署** | macOS 11+ |
| **DI 模式** | EnvironmentKey + EnvironmentValues 扩展 + `.environment()` 注入 + `@Environment` 读取 |
| **限制** | defaultValues 是全局一次性设置；传递路径在深层视图树中难以追踪 |

### URLSession（Foundation）

| 属性 | 描述 |
|------|------|
| **覆盖能力** | 替代 YAAGL 的 aria2 WebSocket RPC 下载方案 |
| **下载 API** | `downloadTask(with:)` / `downloadTask(withResumeData:)`（支持断点续传） |
| **进度追踪** | `task.progress.observe(\.fractionCompleted)` KVO 观察 |
| **限制** | 原生 URLSession 无 aria2 的分片并行加速；PDF 或小文件下载效率无差异 |

### UserDefaults（Foundation）

| 属性 | 描述 |
|------|------|
| **覆盖能力** | JSON 编码/解码 Codable 结构体作为持久化方案 |
| **使用模式** | `JSONEncoder.encode(AppConfig)` → `defaults.set(data, forKey:)` |
| **限制** | 不适合大量或二进制数据；UserDefaults 的 suiteName 隔离需要注意隐私约束 |

### Security-Scoped Resource（App Sandbox）

| 属性 | 描述 |
|------|------|
| **覆盖能力** | 通过 `fileImporter` 获取用户指定的目录并保持访问权限 |
| **使用模式** | `url.startAccessingSecurityScopedResource()` + `defer { url.stopAccessingSecurityScopedResource() }` |
| **最低部署** | macOS 11+（但 SwiftUI `.fileImporter` 为 macOS 13+） |

### NSApplicationDelegateAdaptor（SwiftUI）

| 属性 | 描述 |
|------|------|
| **覆盖能力** | SwiftUI 应用中集成 NSApplicationDelegate 生命周期回调 |
| **使用场景** | `applicationWillTerminate` 中执行 wineserver 优雅关闭等清理工作 |

---

## URLSession 下载替代方案对比（YAAGLSWIFTUI vs YAAGL）

| 维度 | YAAGL（aria2 RPC） | YAAGLSWIFTUI（URLSession） |
|------|--------------------|---------------------------|
| **架构** | 外部进程（WebSocket IPC） | 系统库（进程内） |
| **多线程下载** | 原生支持（多连接分片） | 单连接下载 |
| **断点续传** | 支持 | 支持（resumeData） |
| **进度追踪** | WebSocket 事件推送 | progress.fractionCompleted KVO |
| **并发限制** | aria2 配置 | URLSessionConfiguration.httpMaximumConnectionsPerHost |
| **依赖** | 外部二进制（sidecar/aria2） | 系统库（零外部依赖） |
| **部署负担** | 需捆绑 + 进程管理 | 无额外部署成本 |
