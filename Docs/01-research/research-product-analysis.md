# Research — Product Analysis

> **来源：** 对 References/ 目录中所有研究材料的系统性分析
> **状态：** 研究阶段输出 — 仅提供事实参考，不作设计决策

> **事实分层：** `References/MiPlay/` 描述历史参考实现；当前 MiPlay 的产品/架构事实以 `MiPlay/` 和冻结的 Product/UX/UI/Architecture 文档为准。研究建议不等于项目最终采用方案。

---

## YAAGL (Yet Another Anime Game Launcher)

### 产品定位
一款面向 macOS 和 Linux 的第三方米哈游游戏启动器，专注于解决米哈游游戏在非 Windows 平台上的安装、更新与启动问题。使用 Neutralinojs（跨平台桌面框架）+ SolidJS 构建，不依赖 Electron，体积小巧。

### 目标用户
- 在 macOS/Linux 上玩米哈游游戏（原神、星穹铁道、绝区零、崩坏3、尘白禁区）的玩家
- 有一定技术基础（至少能下载解压、拖入 Applications 文件夹）的用户
- 愿意通过 Discord 社区获取支持的玩家

### 核心价值主张
- 单一入口管理多款米哈游游戏
- 自动处理 Wine 环境配置、游戏文件完整性校验、版本更新
- 绕过复杂的官方启动器依赖，直接启动游戏
- 集成 sophon 后端实现高效的增量更新
- 提供社区验证的兼容方案（DXMT 图形转换、patch 系统等）

### 不解决的问题
- 不提供任何形式的账号管理或登录凭据处理
- 不破解反作弊程序，仅使用旧版本替换等非破解手段
- 不托管游戏安装包文件，安装通过官方资源进行
- 不提供游戏内画质设置或 Mod 管理
- 不内置用户间交流或社交功能
- 不提供非米哈游游戏的启动支持

---

## MiPlay 历史实现（仅作对比）

> 本节描述 `References/MiPlay/` 中的历史 SwiftUI 版本，不应作为当前实现的状态、布局或窗口事实。

### 产品定位
一款面向 Mac 用户的米哈游游戏启动器，用 Swift/SwiftUI 原生开发，专注于 Apple 平台的原生体验。目标是隐藏 Wine 等技术复杂性，让 Mac 用户像打开普通 Mac 应用一样启动米哈游游戏。

### 目标用户
- Mac 原生游戏玩家，不熟悉 Wine/转译/容器等概念
- 同时玩多款米哈游游戏，需要统一管理入口
- 兼容性敏感玩家，需要内置方案解决启动问题

### 核心价值主张
- 完全原生的 macOS 体验（SwiftUI 原生框架）
- Wine 零感知设计，所有技术细节隐藏在背后
- 沉浸式背景体验（每款游戏当前版本的官方背景素材）
- 统一的游戏状态管理（多款游戏一目了然）

### 不解决的问题
- 不处理账号管理、登录凭据或会话管理
- 不托管游戏安装包文件
- 不破解反作弊程序
- 不提供游戏 Mod 管理或游戏内画质设置
- 不支持多用户切换
- 不内置社区论坛或社交功能
- 不为非米哈游游戏提供支持

---

## MiPlay 当前实现（基于当前产品定义）

### 产品定位与冻结决策

- **Wine 固定策略（2026-08-27 用户硬修订）：** 仅使用 `wine-crossover-11.0-1-signed` 作为唯一托管 Wine 运行时，不提供多版本选择、来源选择、按游戏 Wine 覆盖或自由输入 URL。
- **共享先进前缀：** 三款游戏（原神、星穹铁道、绝区零）共用同一个 MiPlay 托管的共享 prefix。
- **不检测外部 Wine：** 不检测、不导入、不复用系统 Wine、Whisky 或 CrossOver Wine。
- **固定生命周期管理：** 区分固定 Release 的获取、校验、安装、失败、取消、恢复和受控升级。

### 核心功能范围

#### Must（必须）
- **游戏启动**：用户可选择已添加的游戏并发起启动请求。
- **固定 Wine 运行时管理**：仅支持唯一固定 Wine 版本。
- **共享运行环境状态**：三款游戏共用同一个固定托管 Wine 和共享 prefix。
- **固定 Wine 生命周期**：不形成用户可见的多版本目录或复杂下载目录管理。
- **固定运行时保护**：当前固定 Wine 和共享 prefix 不提供用户删除入口。
- **内置兼容方案应用**：将当前版本发布清单中的兼容方案应用到系统中。
- **游戏状态总览**：展示各款米哈游游戏的基本状态（未安装/已就绪/运行中/需更新）。
- **定位已安装游戏路径**：三款游戏从启动起即在系统中可见，无需手动"添加"。
- **游戏文件完整性校验**：检查游戏客户端文件是否完整。
- **诊断日志捕获**：记录核心流程的失败原因和恢复上下文，不记录敏感信息。
- **版本背景组切换**：每款游戏可在其有效的官方背景组之间切换。
- **按游戏独立设置**：每款游戏拥有独立的非 Wine 设置范围。

#### Should（应该）
- 版本检测与更新提示
- 多语言支持（中文/英文）
- 日志导出
- 设置页设备信息

#### Deferred（当前版本暂停）
- 官方游戏安装引导
- 自定义启动参数
- 帧率解锁
- A-01 至 A-06 高级配置（Retina、Steam patch 等）

#### Won't（不做）
- 账号管理
- 游戏文件托管
- 反作弊程序文件破解
- 游戏 Mod 管理
- 游戏内画质设置
- 多用户切换
- 游戏内覆盖功能
- 社区论坛或社交功能
- 多版本或可选 Wine 管理
- 非米哈游游戏支持
- 自主更新

### 产品形态与当前交互事实

- 当前实现是面向 macOS 的 SwiftUI 应用，主窗口使用沉浸式游戏背景和固定尺寸窗口。
- 主窗口左下角提供三款目标游戏的纵向选择栏，选择栏下方提供设置入口；当前没有右上角设置按钮。
- 主操作按钮位于底部操作行右侧，不在画面中央；按钮状态由 `LibraryViewModel.PrimaryButtonState` 驱动。
- 设置使用 SwiftUI `Settings` Scene 独立窗口，窗口内容采用 `NavigationSplitView`；当前没有主窗口设置 Sheet。
- 当前交互控件使用 `glassEffect` 与 `GlassEffectContainer`；历史 `.buttonGlass()`、`.regularMaterial` 等写法不代表当前代码。

### 当前实现与研究参考的边界

| 项目 | 当前 MiPlay 事实 | 研究参考/建议 |
|------|------------------|--------------|
| 主窗口布局 | ZStack 背景 + 左下游戏栏 + 底部右侧主按钮 | NavigationSplitView 可用于列表/详情类 macOS 页面 |
| 设置入口 | 独立 `Settings` Scene + NavigationSplitView | Sheet 可作为局部任务/短流程参考，但不是当前设置方案 |
| 材质 API | `glassEffect`、`GlassEffectContainer` | Apple 也提供 Material 变体；不应把平台能力写成项目事实 |
| 状态架构 | UI → ViewModel → Domain → Infrastructure | YAAGLSWIFTUI 的 Service 直接注入 Environment 是竞品模式，不是当前 MiPlay 架构 |
| Wine 策略 | 固定 single version + shared prefix | 竞品通常支持多版本/Wine 选择 |
| 兼容方案 | 当前发布清单仅 CS-01 条件可用 | CS-02 至 CS-04 Deferred，CS-05 Out of Scope |

### 产品层结论

- **产品最终采用：** 单一主窗口承载日常启动流，独立设置窗口承载通用设置，独立游戏详情窗口承载兼容方案/性能/日志相关操作。
- **研究建议：** 保持对 Apple 原生窗口语义和 Liquid Glass API 的跟踪；是否引入其他参考项目的布局或 DI 模式，需要由后续 Architecture/UI Agent 根据冻结需求另行决定。
- **关键约束：** 所有研究和参考设计必须尊重当前产品冻结决策，特别是 Wine 固定版本、共享 prefix、兼容方案发布清单和 Deferred 状态。

---

## Apple Liquid Glass Design System

### 产品定位
Apple 在 macOS 26+ 引入的全新动态材质设计系统，结合玻璃的光学特性和流动性，为所有 Apple 平台提供统一的视觉语言。由 WWDC 2025/2026 公布。

### 目标用户
所有 Apple 平台的开发者和设计师，尤其是正在开发或更新 macOS/iOS/iPadOS/tvOS/watchOS/visionOS 应用的团队。

### 核心价值主张
- 统一的跨平台视觉语言
- 自动适配标准系统组件（无需代码改动即可获得新外观）
- 可编程的玻璃效果 API（SwiftUI `glassEffect` modifier、AppKit `NSGlassEffectView`）
- 保持内容主次分明的层次结构
- 提供丰富的材质变体（regular/thin/thick/ultraThin/ultraThick/bar/tint）

### 不解决的问题
- 不替代 Human Interface Guidelines 中的设计准则
- 不提供应用特定内容的自动组织能力
- 不解决跨平台布局差异问题
- 不处理自定义动画性能优化

---

## Landmarks (Building an App with Liquid Glass)

### 产品定位
Apple 官方 WWDC 2025/2026 的 SwiftUI 示例应用，展示如何利用 Liquid Glass 构建一个功能完整的 macOS/iOS 应用。演示 NavigationSplitView、Material 背景、地图集成、集合管理等功能。

### 目标用户
学习 SwiftUI 和 Liquid Glass 设计思想的开发者。

### 核心价值主张
- 展示 NavigationSplitView 在 macOS 上的标准用法
- 演示 `@Observable` 模型数据管理与环境传递
- 展示 `.searchable` 全局搜索功能
- 演示 `.inspector` 侧边信息面板
- 展示 Liquid Glass 材质的实际应用方法

### 不解决的问题
- 不处理网络请求或持久化存储
- 不涉及游戏启动或 Wine 相关功能
- 不处理跨平台打包或部署问题
- 不演示复杂的异步数据流管理

---

## Apple Web Design (apple.com 设计语言分析)

### 产品定位
Apple 官方网站的设计语言系统，以产品摄影为主导的展示型设计体系。

### 目标用户
访问 Apple 官网浏览和购买产品的用户。

### 核心价值主张
- 摄影优先的展示方式，UI 退居幕后
- 单一品牌色（Action Blue #0066cc）承载所有交互信号
- 全出血平铺页面结构，颜色变化本身成为分节符
- SF Pro Display + SF Pro Text 字体系列的严格层次
- 极简的阴影体系——仅用于产品渲染图

### 不解决的问题
- 不处理复杂表单或数据展示
- 不提供独立的桌面应用 UI 模式
- 不处理多窗口或多任务场景
- 不涉及游戏或娱乐应用的设计需求

---

## macOS 26 设计规范

### 产品定位
从 Figma 设计稿逆向分析得出的 macOS 26 原生 UI 组件规范，涵盖窗口系统、导航、Sidebar、排版、工具栏、交互原则等完整体系。

### 目标用户
希望为 macOS 26+ 设计或开发原生风格应用的设计师和开发者。

### 核心价值主张
- 完整的 Z 轴层次体系（L0-L7）
- 六种窗口类型和五种布局模式
- Liquid Glass 材质在不同组件上的具体实现方式
- 详尽的交互原则（毛玻璃效果、阴影体系、混合模式、按钮体系）
- macOS 26 特有的 Modal 分层规范

### 不解决的问题
- 不涉及跨平台适配
- 不处理 iOS/iPadOS 特定组件
- 不提供触摸交互或手势系统的规范
- 不涉及特定 App 类型（游戏、媒体编辑等）的专门指导


---

## YAAGLSWIFTUI

### 产品定位
YAAGL 的 SwiftUI 原生移植版，保持与原版相同的用户功能集（多款米哈游游戏的安装、更新、启动），但技术栈从 Neutralinojs + SolidJS 切换为 SwiftUI + Foundation 原生框架。这个版本代表了"原生化"的设计选择——放弃跨平台兼容性，换取 macOS 系统深度集成。

### 目标用户
- macOS 用户（不支持 Linux/Windows）
- 倾向使用原生 macOS 应用的玩家
- 对于跨平台 Web 界面体验不满、偏好系统级交互（如原生导航、系统控件、无障碍支持）的用户

### 核心价值主张
- 与 YAAGL 相同的游戏启动功能集，但使用 SwiftUI 原生框架
- 零外部依赖的下载方案（URLSession 替代 aria2 外部进程）
- 原生 macOS 导航体验（NavigationSplitView 替代自定义布局）
- 系统标准控件（无 Web 组件库依赖）
- 更小的应用体积和更低的资源占用

### 架构选择差异（与 YAAGL 对比）

| 维度 | YAAGL | YAAGLSWIFTUI |
|------|-------|---------------|
| 框架 | Neutralinojs + SolidJS | SwiftUI + Foundation |
| 编程语言 | TypeScript | Swift 6 |
| 跨平台 | macOS + Linux | 仅 macOS |
| DI 模式 | 函数式组合（模块导入） | EnvironmentKey + AppContext 容器 |
| 状态管理 | SolidJS Signals | @Observable 宏 |
| 异步模式 | AsyncGenerator yield 元组 | AsyncThrowingStream<ProgressEvent, Error> |
| 下载方案 | aria2 RPC（外部进程） | URLSession（系统库） |
| 持久化 | Neutralino key-value | UserDefaults + Codable |
| 线程安全 | JS 单线程 | LockedDictionary + @unchecked Sendable |
| 导航 | 自定义全屏布局 | NavigationSplitView 原生导航 |
| 配置 UI | @hope-ui/solid Web 组件 | SwiftUI 原生控件 |
| 视频播放 | HTML5 Video | AVKit AVPlayer |
| 更新分发 | 外部进程管理 | 系统框架管理 |

### 不变的部分（与 YAAGL 保持一致）
- 游戏客户端协议（GameClient）的接口设计
- 游戏支持范围（Genshin Impact / Star Rail / ZZZ / Honkai Impact 3rd / Snowbreak）
- 游戏服务器定义（GameServer 数据结构）
- 安装/更新/启动的核心操作流程
- 全屏沉浸式背景 + 底部操作栏的 UI 布局概念
- Hoyoverse API 的数据结构解析
- Sophon 增量更新协议客户端
- Wine 版本管理和运行时集成
- /etc/hosts 网络屏蔽方案
- 配置面板垂直 Tab 布局 + Advanced 选项卡隐藏的渐进披露设计
