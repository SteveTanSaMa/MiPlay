# Research — UI Patterns

> **接收方：** UI Agent
> **内容：** 每个研究对象的界面组织方式、视觉语言特征
> **来源：** References/ 目录下的所有研究材料

> **事实分层：** “历史实现”只用于对比；“当前实现”来自 `MiPlay/` 代码；“研究建议”描述可参考的 Apple/竞品模式，不等于项目已采用方案。

---

## YAAGL

### 整体布局
- 单窗口全屏启动器界面，无原生窗口装饰（Neutralinojs 框架）
- 全屏背景层体系：三层 Z-stack — video 背景层（z-index: -2）→ theme 覆盖层（z-index: -1）→ 主内容层（z-index: auto）
- 游戏 Logo 定位在画面左上区域（position: absolute, top: 0, left: 0），尺寸固定 234×416px
- 版本图标位于右下偏上位置（right: 10vw, bottom: calc(23vh - 2px)）
- 底部操作区：Flex 布局 `direction="column-reverse"`，按钮在右下角，进度信息在按钮上方
- 配置界面使用 Tab 布局（垂直标签 + 内容面板），宽度 1000px，高度 570px

### 信息层级
1. **最上层：** 视频/图片背景游戏主题画面
2. **中层 overlay：** theme 覆盖层（与视频对齐，含装饰性元素）
3. **信息层：** 游戏 Logo（视觉锚点） + 版本图标
4. **操作层：** 底部按钮区（启动/安装/更新）+ 进度状态文字 + 进度条
5. **浮层：** 配置 Modal、Popover 预下载提示、更新提示 Modal

### 组件使用方式
- **Button 按钮：** @hope-ui/solid 组件库，`size="xl"` 大按钮用于主操作（安装/启动/更新），`ButtonGroup` 组合主按钮 + 设置齿轮按钮
- **Progress 进度条：** 底部进度指示器，`size="sm"`，支持 `indeterminate` 状态（值为 0 时切换）
- **Modal 弹窗：** 用于配置页和更新提示，配合 `ModalOverlay` + `ModalContent` + `ModalHeader` + `ModalBody` + `ModalFooter` 完整结构
- **Popover 弹出框：** 预下载提示使用 `Popover` 从启动按钮弹出，`placement="top"`，`closeOnBlur=true`
- **Tabs 标签页：** 配置界面使用垂直 Tabs（General / Game / Wine / Advanced / Licenses）
- **FormControl 表单：** 配置项使用 `FormControl` + `FormLabel` 布局
- **Divider 分割线：** 用于配置面板中不同配置组之间的分隔

### 视觉语言特征
- 全屏沉浸式背景（游戏官方视觉素材），无多余 UI chrome
- 深色主题背景上使用白色文字 + 文字阴影（`text-shadow: 1px 1px 2px #333`）
- 启动按钮带阴影（`box-shadow: 0 2px 2px rgba(0, 0, 0, 0.2)`）
- 简单自定义滚动条样式（8px 宽，#cccccc thumb）
- 配置 Modal 有垂直 Tab 导航布局
- 使用 @hope-ui/solid 组件库的语义化色彩系统（success/danger/ghost 按钮变体）
- 无毛玻璃或复杂视觉效果

---

## MiPlay 历史实现（仅作对比）

> 以下内容来自 `References/MiPlay/`，不是当前 `MiPlay/` 目录的实现。当前实现见下一节。

### 整体布局
- 原生 SwiftUI 窗口，全屏 (`ignoresSafeArea`)
- 多层 ZStack 结构：
  - **层1:** 视频/图片背景（全屏覆盖）
  - **层2:** 底部可读性渐变（ReadabilityOverlay）
  - **层3:** 左下角游戏栏（GameRailView — 游戏选择导航）
  - **层4:** 右上角设置按钮
  - **层5:** 右下角主操作按钮（启动/安装/更新）
- 过渡页：准备阶段展示 LoadingOverlay，提示文字 + 加载状态
- 设置和未识别游戏类型使用 Sheet（历史窗口尺寸分别为 800×520px、340px）

### 信息层级
1. **背景层：** 游戏当前版本的官方视频/图片素材（全屏沉浸）
2. **可读性渐变层：** 底部半透明渐变保证文字可读性
3. **功能层：** 游戏切换栏（左下） + 主按钮（右下） + 设置按钮（右上）
4. **覆盖层：** Error Alert、FileImporter、Sheet、各种 Modal

### 组件使用方式
- **SwiftUI NavigationSplitView：** 未使用（采用自定义 ZStack 布局）
- **Button 按钮：** `.borderedProminent` 风格 + `.controlSize(.large)`，`tint(.white.opacity(0.2))` 半透明白色背景
- **按钮样式扩展：** 历史版本使用自定义毛玻璃修饰符；该方案不代表当前 Liquid Glass API 或当前 MiPlay 实现
- **Image SF Symbol：** 状态相关图标（play.fill / arrow.down.circle / arrow.up.circle）
- **Alert：** 使用 SwiftUI `.alert` 修饰符绑定 `showError`
- **fileImporter：** 使用 SwiftUI `.fileImporter` 文件选择器
- **Sheet：** 历史设置页和未识别游戏类型选择使用 `.sheet`
- **动画：** 游戏切换时背景过渡使用 `.animation(.easeInOut(duration: 0.5), value: selectedGame)`
- **ZStack 分层布局** 替代 macOS 标准的 NavigationSplitView

### 视觉语言特征
- 全屏沉浸式背景（游戏官方视频/图片素材）
- 历史自定义半透明毛玻璃按钮
- 白色半透明按钮风格（`.white.opacity(0.2)`）
- 底部渐变增强可读性（视频背景上的文字可见性）
- 无传统窗口标题栏或工具栏（全屏内容优先）
- 游戏切换使用底部水平横条（GameRailView）
- 版本背景素材的自动下载 + 视频转码准备流程

---

## MiPlay 当前实现（代码事实）

### 整体布局
- 主窗口由 `MainWindowScene` 承载，使用隐藏标题栏的固定 1280×688 窗口；这属于项目当前窗口配置，不是 Apple 平台强制规范。
- 主内容使用 `ZStack`：`BackgroundView` 位于底层，按游戏类型切换自包含的图片/视频/主题叠加层。
- 前景操作位于底部：左侧是 `GameSelectionRailView`，右侧是 `PrimaryActionButton`；主按钮不是居中按钮，也不是右上角按钮。
- 设置入口位于左下游戏选择栏的下方，与游戏图标保持独立间距；当前没有右上角设置按钮。
- 设置不使用 Sheet：App 入口注册独立的 `Settings` Scene，内容由 `SettingsWindowScene` 以 `NavigationSplitView` 展示，窗口内容尺寸为 800×448。

### 信息层级
1. **背景层：** `BackgroundView` / `BackgroundScene` 渲染图片、循环视频与主题装饰层
2. **导航层：** 左下 `GameSelectionRailView`，包含三款游戏入口和状态点
3. **操作层：** 底部右侧 `PrimaryActionButton`，由 `LibraryViewModel.PrimaryButtonState` 驱动
4. **应用层窗口：** 独立设置窗口和游戏详情窗口由 SwiftUI Scene 管理
5. **反馈层：** 主窗口错误 Alert、加载覆盖层、游戏定位用 `NSOpenPanel`

### Liquid Glass 使用方式
- 当前项目使用 SwiftUI `glassEffect`，而不是旧的自定义毛玻璃修饰符。
- `GameSelectionRailView` 使用 `GlassEffectContainer` 聚合游戏图标和设置入口；各入口使用 `.glassEffect(in:)` 配合圆角矩形形状。
- `PrimaryActionButton` 使用 `.glassEffect(Glass.regular.interactive(true), in:)`，将交互态玻璃效果显式应用于主操作按钮。
- 当前 `MiPlay/` 中未使用 `.regularMaterial`、`.ultraThinMaterial` 或自定义 `buttonGlass` 作为项目实现。Material/Liquid Glass API 的平台能力仍保留在 Apple 参考章节，不能反推为项目要求。

### 项目最终采用方案
- **已采用：** ZStack 沉浸式主窗口、左下游戏选择栏、底部右侧状态驱动主按钮、`glassEffect` / `GlassEffectContainer`、独立 Settings Scene。
- **未采用：** 右上角设置按钮、居中主按钮、设置 Sheet、历史自定义毛玻璃修饰符。

### 研究建议（非当前实现）
- Apple Liquid Glass 参考建议优先使用 `glassEffect`、`GlassEffectContainer` 和系统标准控件来建立层级；这只是平台能力与研究建议，不能改写为 MiPlay 当前必须采用的布局。
- `NavigationSplitView` 适合作为设置窗口的 macOS 原生导航模式；当前项目已在设置窗口采用它，但主窗口仍保持沉浸式 ZStack。

---

## Apple Liquid Glass Design System

### 整体布局
- 标准窗口布局模式（文档窗口/工具窗口/对话框/弹窗/通知横幅）
- 五种布局模式：纯标题栏（文档）/ 纯标题栏（工具）/ Monobar / Titlebar 独立 / 标准模式
- NavigationSplitView 主导的侧边栏 + 内容区结构
- 一致的 Z 轴层级（L0-L7）定义窗口模态关系

### 信息层级
- Menu Bar（L1）→ 窗口（L3）→ Overlay（L4）→ Alert/Dialog（L5）→ Floating Menu（L6）→ Dock（L7）
- 窗口内部：Titlebar → Toolbar → Sidebar → Content → Inspector
- 内容区的层次通过 Material 材质的透明度差异表达

### 组件使用方式
- **SwiftUI glassEffect modifier：** 核心 API，为任意 View 添加 Liquid Glass 材质
- **GlassEffectContainer：** 聚合多个玻璃效果视图以优化渲染
- **Glass.buttonStyle(.glass)：** 专用玻璃按钮样式
- **NavigationSplitView：** 标准侧边栏 + 内容区导航（三栏或两栏）
- **NSGlassEffectView（macOS 26+）：** AppKit 层玻璃效果视图
- **Material 材质：** `.regular` / `.thin` / `.thick` / `.ultraThin` / `.ultraThick` / `.bar`
- **backgroundExtensionEffect()：** 扩展背景效果，将内容延伸到侧边栏和检查器后
- **glassMaterialize transition：** 玻璃材质出现的过渡动画
- **glassMatchedGeometry transition：** 玻璃材质的几何过渡动画

### 视觉语言特征
- **动态玻璃材质：** 结合玻璃光学特性和流动性
- **毛玻璃效果（backdrop-filter blur）：** 窗口、侧边栏、菜单等自动应用
- **双阴影体系：** 窗口级阴影 + 组件级阴影
- **混合模式：** `plus-lighter`、`plus-darker`、`color-dodge`、`screen`、`multiply` 等系统级混合
- **SF Pro 字体系列：** 一致的系统字体
- **圆角体系：** 窗口 16-26px，工具窗口 15px，通知横幅 16px，菜单 13px，胶囊按钮 100px
- **表单控件：** 统一 16×16px Checkbox/Radio，36×16px Switch

---

## Landmarks (Building an App with Liquid Glass)

### 整体布局
- NavigationSplitView 布局（sidebar + detail）
- 侧边栏包含：主页面导航链接列表（Landmarks / Collections / Badges / Map）
- 内容区：Landmarks 视图为主页，按大洲分组
- Inspector（检查器侧栏）：显示地标的额外信息（条件性显示）
- 最小窗口尺寸：375×600px

### 信息层级
- **侧边栏导航：** 应用页面级导航（Landmarks / Collections / Badges / Map）
- **内容区：** 精选推荐（Featured Item）+ 水平滚动列表（Horizontal List）+ 分类网格（Grid by Continent）
- **导航栈：** Landmark → Detail View（导航推送），Collections → Collection Detail
- **Inspector：** 地标详情面板（条件性显示，绑定 selectedLandmark）
- **搜索：** `.searchable` 全局搜索（系统自动定位搜索栏）

### 组件使用方式
- **NavigationSplitView：** 标准两栏布局（sidebar + detail），`preferredCompactColumn` 控制紧凑模式
- **NavigationStack：** 导航栈用于内容区页面推送
- **NavigationLink：** 导航到地标详情
- **searchable：** 全局搜索绑定 `modelData.searchString`
- **inspector：** 条件性显示地标信息面板
- **List + Section：** 侧边栏和内容区的标准列表结构
- **badge修饰符：** `.showsBadges()` 自定义视图修饰符展示徽章状态
- **LazyVGrid：** 集合页面网格布局
- **GlassEffectContainer：** 容器内多个玻璃效果视图共享优化
- **onGeometryChange：** 用于跟踪窗口大小变化

### 视觉语言特征
- Liquid Glass 材质自动应用于标准组件（侧边栏、工具栏、搜索栏）
- 侧边栏自动渲染为 Liquid Glass 材质（translucent background）
- Map 视图集成（MKMapView）
- 地标详细页使用 FlexibleHeader（滚动视差效果）
- 可读性矩形（ReadabilityRoundedRectangle）确保文字在背景上的可读性
- 水平滚动的 Featured Item 展示，网格分类

---

## Apple Web Design (apple.com)

### 整体布局
- 全出血（full-bleed）产品平铺布局——每个 tile 占据整个视口宽度
- 交替的浅色/深色 tile 模式（白色 → 近黑色 → 浅色 → 深色 → 浅色）
- 最大内容宽度：文本区 ~980px，产品网格 ~1440px
- 内容居中对齐，上下有 80px 间距

### 信息层级
- 每个 tile 结构（从上到下）：产品名称（display-lg 40px）→ tagline（lead 28px）→ 双 CTA 按钮（蓝色药丸）→ 产品渲染图
- 两行导航：global-nav（44px 黑色）+ sub-nav-frosted（52px 毛玻璃）
- 页脚密集链接布局（使用 line-height 2.41 保持可读性）

### 组件使用方式
- **产品 tile（4种变体）：** light / parchment / dark / dark-2 / dark-3 — 颜色变化即分割线
- **按钮系统（6种）：** primary pill、secondary pill、dark utility、pearl capsule、store hero、icon circular
- **store-utility-card：** 网格展示产品，18px 圆角，24px padding
- **configurator-option-chip：** 药丸形配置选择器
- **floating-sticky-bar：** 底部浮动粘性操作栏（购买页）
- **search-input：** 药丸形搜索输入框

### 视觉语言特征
- **单一品牌色：** Action Blue #0066cc 用于所有交互元素
- **摄影优先：** 产品渲染图是视觉核心，UI 退居幕后
- **无装饰性渐变：** 氛围来自摄影作品而非 CSS 渐变
- **SF Pro Display / SF Pro Text：** 系统字体体系
- **负字间距：** 标题级字号使用负字间距（-0.28 到 -0.374px）
- **唯一阴影：** 仅产品渲染图使用 `rgba(0,0,0,0.22) 3px 5px 30px` 阴影
- **药丸圆角（9999px）：** 所有操作按钮使用药丸形状
- **最小按钮交互：** `transform: scale(0.95)` 系统级反馈

---

## macOS 26 设计规范（Figma 逆向分析）

### 整体布局
- 六种窗口类型：文档窗口 900×600px / 工具窗口 300×300px / 对话框 / 弹窗 / 通知横幅 382×72px / 菜单
- 五种布局模式：纯标题栏 / 纯标题栏+Tab / Monobar / Titlebar 独立 / 标准 Toolbar
- Menu Bar 全宽 1512×34px，Dock 882×62px
- Sidebar 五种变体：标准含 Titlebar(240px) / 标准无 Titlebar(240px) / 紧凑型(136px) / 撑满型 / Monobar 型

### 信息层级
- Z 轴：Desktop → Menu Bar → Glass Overlay → 应用窗口 → Modal Overlay → Alert/Dialog → 菜单 → Dock
- 窗口内部：Titlebar（标题）→ Toolbar（操作）→ Sidebar（导航）→ 内容区 → 底部状态栏
- 列表行结构：[Icon] [Label] [flex:1] [Chevron]

### 组件使用方式
- **Sidebar 列表项：** 24px 高，圆角 8px，选中态 `rgba(0,0,0,0.11)` + `mix-blend-mode: multiply`
- **Segmented Control：** 79×24px/67×36px，Liquid Glass 材质
- **Toolbar 四尺寸：** 超小 32px / 小 32px / 中 36px / 大 52px
- **Search Bar：** 药丸形 130×24px/168×24px，Toolbar 版使用 Liquid Glass
- **Pop-Up Button：** 229×24px，圆角 6px
- **App Icon：** 26×26px / 20×20px，圆角 5px，内发光
- **表单控件：** Checkbox 16×16px，Radio 16×16px，Switch 36×16px，Stepper 64×24px
- **按钮体系：** 弹窗按钮 110×32px（圆角 100px）/ 对话框按钮 63-74×24px（圆角 6px）

### 视觉语言特征
- **Liquid Glass 材质：** 窗口、侧边栏、菜单、工具栏、通知横幅自动使用
- **毛玻璃模糊：** Dock blur(67.957px)，Menu Bar 选中态 blur(30px)
- **阴影体系：** 窗口级 16px 48px rgba(0,0,0,0.35)，弹窗双层 drop-shadow
- **混合模式广泛使用：** plus-darker 用于 sidebar 标签、菜单标签等；multiply 用于选中态；screen 用于玻璃效果
- **SF Pro 全系字体：** 字号从 9px 到 16.3px
- **响应式圆角：** 窗口 26px / 16px，Sidebar 18px / 8px，菜单 13px，胶囊 100px
- **红绿灯按钮：** 14×14px（文档窗口）/ 10×10px（工具窗口），标准 macOS 颜色


---

## YAAGLSWIFTUI

### 整体布局
- 原生 SwiftUI `WindowGroup` + `NavigationSplitView` 三列布局（实际显示 sidebar + detail 双列）
- 窗口最小尺寸 800×500px，`windowResizability(.contentMinSize)` 按内容自适应
- Sidebar 固定最小 200px/理想 260px，标题 "YAAGL"，使用 `List` + `NavigationLink` 选择游戏
- Detail 视图（LauncherView）采用 ZStack 全沉浸布局：
  - **层1:** 背景图片（`AsyncImage` 从 Hoyoverse API 获取，全屏覆盖）
  - **层2:** 背景视频（`AVKit` 播放器 overlayed 在图片上）
  - **层3:** 游戏 Logo（左上定位，234px 高度，scaledToFit）
  - **层4:** 版本图标（右上偏下位置，可点击打开官网）
  - **层5:** 版本号叠加（右上角半透明黑底白字标签）
  - **层6:** 底部操作区（Spacer + padding + 按钮/进度信息）
- 配置界面使用 `.sheet` 呈现，内部分左右双栏布局：
  - 左栏：垂直 Tab 列表（120px 宽，历史参考项目的 `.regularMaterial` 背景），5 个 Tab：General / Game / Wine / Advanced / Licenses
  - 中间：Tab 内容区（ScrollView）
  - 右栏：Quick Actions 侧边栏（160px 宽，历史参考项目的 `.regularMaterial` 背景）
- Wine 安装使用单独的 `.sheet`（WineInstallView）

### 信息层级
1. **最深层：** 游戏官方背景图片（全屏覆盖）
2. **视频覆盖层：** 若存在背景视频则叠加在当前帧上
3. **Logo 层：** 游戏标志性 Logo（左上视觉锚点）
4. **版本与图标层：** 版本图标（右上）+ 版本号标签（右上）
5. **操作层：** 底部操作区（启动/安装/更新按钮 + 进度状态文字 + 进度条）
6. **浮层：** 配置 Sheet、Wine 安装 Sheet、Alert 错误提示、FileImporter 目录选择

### 组件使用方式
- **NavigationSplitView：** 替代 YAAGL 的 SolidJS 自定义布局，实现 macOS 原生侧边栏导航。`navigationSplitViewStyle(.balanced)` 平衡两列空间
- **List + NavigationLink：** 侧边栏游戏列表，`Game.allCases` 驱动，每个项包含 SF Symbol 图标 + 游戏名称 + 区域标签（China/Global）
- **AsyncImage：** 背景图片和 Logo 使用 `AsyncImage` 从远程 URL 异步加载，支持 success/failure/loading 三个阶段
- **AVKit Player：** `AVPlayer` 用于播放 Hoyoverse 提供的背景视频
- **ZStack：** 全屏沉浸式内容的主要布局容器，ignoresSafeArea 确保边缘到边缘
- **Button：** 启动按钮使用 `.borderedProminent` + `.large`，配置按钮使用 gear SF Symbol
- **Sheet：** 配置面板和 Wine 安装使用 `.sheet` 修饰符
- **Alert：** 错误提示和预下载确认使用 `.alert` 修饰符
- **fileImporter：** 安装目录选择使用 `.fileImporter(.folder)`，支持 security-scoped resource
- **Divider：** 用于配置面板中配置组之间的分隔
- **Toggle / TextField / Picker：** 标准 SwiftUI 控件用于配置项的交互
- **进度条：** ZStack 底部的 ProgressView

### 视觉语言特征
- 全屏沉浸式背景（Hoyoverse 官方背景图片/视频），与 YAAGL 设计理念一致
- 无窗口标题栏或工具栏（沉浸式场景），但保留了 `.windowStyle(.titleBar)` 的原生窗口装饰
- 白色半透明文字（版本号标签）：`white.opacity(0.7)` + `black.opacity(0.3)` 背景
- 配置面板使用历史参考项目的系统材质（`.regularMaterial`）分隔侧栏和主内容区；这不是当前 MiPlay 设置窗口的实现
- 原生 SwiftUI 控件风格（系统 Accent Color），无自定义组件库
- 配置界面使用标准 macOS 表单布局（Toggle 行、TextField、Picker）
- 游戏图标使用 SF Symbols 映射（star.fill / tram.fill / bolt.fill / heart.fill / snowflake）
- 整体遵循 macOS 原生设计语言，无 Web UI 痕迹

### 关键差异（与 YAAGL 对比）
| 维度 | YAAGL | YAAGLSWIFTUI |
|------|-------|---------------|
| 窗口框架 | Neutralinojs 无框窗口 | SwiftUI WindowGroup + titleBar |
| 布局系统 | SolidJS Flex + absolute | SwiftUI ZStack + NavigationSplitView |
| 导航 | 无标签，全屏单视图 + Modal | NavigationSplitView sidebar + detail |
| 背景组件 | CSS background-image/video | SwiftUI AsyncImage + AVPlayer |
| 配置 UI | @hope-ui/solid 组件库 | 原生 SwiftUI 控件 |
| 按钮样式 | @hope-ui Button size="xl" | .borderedProminent .large |
| 图标 | 自定义 SVG | SF Symbols |
| 配置布局 | 垂直 Tabs 全宽 1000px | 垂直 Tab + 双栏布局（内容+Quick Actions） |
| 风格 | Web 组件库风格 | macOS 原生系统风格 |
