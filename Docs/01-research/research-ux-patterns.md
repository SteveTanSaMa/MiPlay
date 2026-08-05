# Research — UX Patterns

> **接收方：** UX Agent
> **内容：** 核心交互流程、状态反馈机制、异常处理、首次使用体验、设计原则提炼
> **来源：** References/ 目录下的所有研究材料

---

## YAAGL

### 核心交互流程

**启动游戏流程：**
1. 应用启动 → 检查 Wine 是否就绪 → 若无 Wine，进入 Wine 安装流程
2. Wine 就绪 → 初始化客户端（根据环境变量 `YAAGL_CHANNEL_CLIENT` 加载对应游戏模块）
3. 客户端初始化 → 检查游戏安装状态 → 检查更新 → 渲染启动界面
4. 用户点击主按钮 → 根据 `installState()` 判断行为：
   - `NOT_INSTALLED` → 提示选择安装目录 → 执行安装
   - `INSTALLED` + `updateRequired()` → 执行更新
   - `INSTALLED` + 无需更新 → 执行启动
5. 启动：应用 patch → 设置 Wine 属性 → 启动游戏进程 → 等待进程退出 → revert patch

**安装游戏流程：**
1. 点击 "Install" 按钮 → 调用 `selectPath()` 打开目录选择器
2. 检查磁盘空间（需要 1.2 倍安装大小）
3. 启动 sophon_server 后端 → 连接到官方分发服务器
4. 下载并解压游戏文件 → 显示进度
5. 安装完成 → `batch()` 更新状态信号

**配置流程：**
1. 点击设置齿轮按钮 → 打开 Modal 弹窗
2. 垂直 Tab 导航：General → Game → Wine → Advanced(隐藏) → Licenses
3. 每个 Tab 包含对应配置项
4. 关闭 Modal 时可选执行完整性检查

### 状态反馈机制
- **Task Queue 模式：** 所有耗时操作通过异步生成器 `AsyncGenerator` 管理，逐步 yield 状态更新
- **三信号系统：** `statusText`（文字描述）+ `progress`（0-100 进度值）+ `programBusy`（忙碌状态布尔值）
- **进度条双模式：** `progress == 0` 时显示 `indeterminate`（不确定进度动画），否则显示具体进度
- **双队列设计：** `taskQueue`（主操作队列）+ `nonUrgentTaskQueue`（非紧急后台任务如预下载）
- **预下载提示：** 通过 `Popover` 在启动按钮上方弹出，用户可选择立即预下载

### 异常处理方式
- **启动失败：** `fatal(e)` 全局错误处理，显示错误信息
- **磁盘空间不足：** 检查剩余空间 → `locale.alert()` 弹窗提示
- **版本不兼容：** 检查游戏版本是否在 `UPDATABLE_VERSIONS` 列表中 → 若太旧则提示需要重新安装
- **下载服务启动失败：** `Promise.race` 超时竞争 → 提示 "Fail to launch sophon" 或 "Failed to start download service"
- **完整性检查：** 启动时自动执行 `checkIntegrityProgram`，文件异常时通知用户
- **网络屏蔽：** 使用 `blockNet` 选项配合 `/etc/hosts` 临时修改 + 自动清理

### 首次使用体验
1. 首次启动：检测 `wineStatus.wineReady == false` → 直接进入 Wine 安装界面（`createWineInstallProgram`）
2. Wine 安装完成后 → 自动进入游戏选择界面
3. 每款游戏首次安装需要用户选择安装目录
4. 安装过程中用户会看到进度条 + 状态文字
5. 配置界面中 `Advanced` 标签页隐藏，需要连续快速点击版本号 5 次才出现

### 设计原则提炼

#### 原则 1：任务队列状态分离
- **选择：** 所有异步操作通过生成器（Generator）驱动，与 UI 状态通过信号（Signal）耦合
- **原因：** 避免异步操作与 UI 更新之间的竞态条件，保持 UI 响应式
- **代价：** 增加代码复杂度，需要维护任务队列的生命周期

#### 原则 2：配置面板标签化组织
- **选择：** 使用垂直 Tab 将配置项分组（General / Game / Wine / Advanced / Licenses）
- **原因：** 大量配置项需要分类组织，Tab 布局使导航路径清晰
- **代价：** 需要额外的 Tab 切换操作，少量常用项被埋入深层

#### 原则 3：预下载非阻塞
- **选择：** 新版本发布时通过非紧急队列提示预下载，不影响当前游戏操作
- **原因：** 大型更新包的下载时间较长，提前下载可减少用户等待
- **代价：** 需要管理两个任务队列，增加状态同步复杂度

---

## MiPlay (旧版本)

### 核心交互流程

**启动游戏流程：**
1. 用户从底部 GameRail 选择游戏 → `selectedGame` 更新 → 背景切换动画
2. 点击主按钮 → 根据 `installStatus` 判断行为：installed → launch / notInstalled → 文件选择器
3. Launch：调用 `LaunchService.launch()` → 创建启动脚本 → 设置环境变量 → 启动 wine64 进程
4. 异步等待进程退出（`withCheckedContinuation` + `DispatchQueue.global`）
5. 进程退出后清理脚本和日志

**首次安装流程：**
1. 对 `notInstalled` 游戏点击主按钮 → 打开 `fileImporter` 文件选择器
2. 用户选择目录后 → `didSelectGameDirectory()` 自动检测游戏类型
3. 可识别 → 自动添加并刷新；不可识别 → 弹出 `unrecognizedGameSheet` 手动选择
4. 安装完成后游戏状态更新

**切换游戏流程：**
1. 底部 GameRail 点击另一个游戏标签 → `selectedGame` 变化
2. `.id(selectedGame)` 强制视图重建 → 背景视觉元素过渡动画
3. 背景视频/图片根据新游戏的当前版本素材切换

### 状态反馈机制
- **加载过渡页：** 准备阶段显示全屏 LoadingOverlay（`isPreparing = true`）
- **启动状态：** `isLaunching` 标志位 + `launchProgress` 进度 → 按钮切换为 `ButtonLaunchingStateView()`
- **错误提示：** `.alert` 绑定 `showError`
- **日志系统：** 使用 `Logger.shared` 统一日志记录
- **游戏运行状态：** `GameLauncher.isGameRunning` 属性检查进程状态

### 异常处理方式
- **启动失败：** catch 错误 → 设置 `errorMessage` + `showError = true` → Alert 弹窗
- **游戏未安装：** `LaunchError.gameNotInstalled` → 引导用户选择安装路径
- **Wine 未配置：** `LaunchError.wineNotConfigured` → 自动触发 Wine 下载流程
- **可执行文件未找到：** `LaunchError.executableNotFound` → 错误提示 + 日志记录
- **进程异常退出：** 非零退出码记录到日志（非阻塞，不弹窗）
- **文件损坏：** 完整性校验失败时通知用户

### 首次使用体验
1. 首次启动 → `loadGameData()` + `prepareBackgrounds()` 异步加载
2. `isPreparing = true` 期间显示 "正在准备素材..." 过渡页
3. 自动下载所有三款游戏的背景素材和视频
4. 视频素材需要本地转码（FFmpeg 转换）
5. 后台预加载其他游戏的素材（主游戏完成后 Task 异步执行）
6. 首次启动某款未安装游戏 → 自动弹出文件选择器

### 设计原则提炼

#### 原则 1：沉浸式背景优先
- **选择：** 全屏游戏背景素材作为界面主体，所有 UI 控件叠加在背景之上
- **原因：** 让启动体验与游戏版本内容产生情感关联
- **代价：** 背景素材需要网络下载和本地转码，增加首次加载时间；文字在动态背景上的可读性需要额外保障（ReadabilityOverlay 渐变条）

#### 原则 2：状态驱动的按钮语义
- **选择：** 主按钮的文字和图标根据游戏状态动态变化（安装 / 下载中 / 开始游戏 / 更新游戏）
- **原因：** 单一入口适配所有状态，减少用户理解成本
- **代价：** 状态的边界情况需要精确处理（如 downloading 状态下的按钮禁用）

#### 原则 3：延迟后台准备
- **选择：** 立即加载当前选中游戏的素材，后台异步准备其他游戏的素材
- **原因：** 用户首次看到界面时当前游戏应立即可用，其他游戏延迟加载不影响体验
- **代价：** 切换到其他游戏时可能有短暂延迟（素材未就绪时回退到静态占位）

---

## Apple Liquid Glass Design System

### 核心交互流程

**窗口操作流程：**
1. 打开窗口 → 自动应用 Liquid Glass 材质
2. 窗口操作（缩放/移动/切换）→ 玻璃效果实时更新
3. 模态呈现 → 父窗口自动 dimming（`rgba(0,0,0,0.2)` Window Modal 遮罩）
4. 关闭模态 → 遮罩消失，父窗口恢复正常

**搜索流程（macOS）：**
1. 用户调用搜索（Cmd+F 或点击搜索字段）
2. 搜索栏自动获得焦点 → 显示搜索结果建议
3. 输入或选择搜索建议 → 内容区显示筛选结果

**导航流程：**
1. NavigationSplitView sidebar 选择 → content 区更新
2. NavigationStack push → 导航栏自动显示返回按钮
3. 在 Detail 内使用 Inspector → 右侧面板滑动出现

### 状态反馈机制
- **Focus Ring：** TextField 聚焦时 3.5px `rgba(0,122,255,0.25)` 外圈 + 1px `rgba(0,122,255,0.15)` 内圈
- **Button Press：** `transform: scale(0.95)` 微缩放反馈
- **Toggle/Switch：** 立即反映状态变化（蓝色填充或灰色）
- **Progress Indicator：** 确定进度条 / 不确定进度动画（indeterminate）
- **窗口状态：** 红绿灯按钮颜色（Close #FF736A / Minimize #FEBC2E / Zoom #19C332）明确窗口状态

### 异常处理方式
- **Alert/Sheet：** 使用标准弹窗系统展示错误信息
- **Dialog：** 保存对话框包含 "Cancel" + 默认按钮
- **不可用状态：** 禁用菜单项使用 `#BFBFBF` 文字色
- **验证状态：** Form 表单错误使用红色提示标注（`rgba(255,56,60,0.23)` 危险按钮背景）

### 首次使用体验
- 系统级设计语言，对新用户来说界面行为与系统其他应用一致（降低学习成本）
- 所有标准组件在首次编译时自动应用 Liquid Glass 外观
- 窗口创建和打开由系统窗口管理器处理，开发者无需关心
- 无特殊引导流程——设计原则是"与系统其他应用一致"

### 设计原则提炼

#### 原则 1：材质层次表达结构
- **选择：** 使用 Liquid Glass 材质的透明度不同（ultraThin → ultraThick）表达界面层次
- **原因：** 视觉层次不需要额外边框或阴影，材质透明度自然区分前后关系
- **代价：** 动态材质需要 GPU 开销；自定义视图需要明确指定材质变体，默认选择可能不符合预期

#### 原则 2：标准组件自动适配
- **选择：** 标准组件（NavigationSplitView、Toolbar、Sidebar 等）自动获得 Liquid Glass 外观
- **原因：** 开发者不需要额外工作即可获得一致外观
- **代价：** 自定义视图需要手动应用玻璃效果 API，增加了自定义成本

#### 原则 3：统一交互反馈
- **选择：** 所有按钮使用 `scale(0.95)` 按压力反馈，所有 TextField 使用统一的 Focus Ring
- **原因：** 统一交互语言减少用户学习成本
- **代价：** 特殊交互需求的按钮需要额外工作覆盖默认行为

---

## Landmarks (Building an App with Liquid Glass)

### 核心交互流程

**浏览地标流程：**
1. 打开应用 → NavigationSplitView 显示侧边栏 + 地标列表
2. 侧边栏选择导航项（Landmarks / Collections / Badges / Map）
3. 内容区展示对应视图（精选推荐 + 列表/网格）
4. 点击某个地标 → NavigationStack push 到地标详情页
5. 详情页可点击收藏按钮、查看地图位置、查看检查器信息

**收藏流程：**
1. 在地标详情页点击收藏按钮（`LandmarkFavoriteButton`）
2. 调用 `modelData.toggleFavorite(landmark)` → 更新 `favoritesCollection`
3. 收藏状态反映到 UI（星标填充状态变化）
4. 收藏状态也影响侧边栏 Badges 视图中的徽章进度

**检查器交互：**
1. 在地标详情页中触发 Inspector（Command+Option+I 或工具栏按钮）
2. Inspector 从右侧滑入 → 显示地标详细信息
3. 关闭 Inspector 后地标选择状态清除

### 状态反馈机制
- **导航路径追踪：** `NavigationPath` 通过 `didSet` 观察者自动管理 Inspector 关闭逻辑
- **窗口大小追踪：** `onGeometryChange` 将窗口尺寸同步到 `modelData.windowSize`
- **搜索过滤：** `searchString` 实时过滤列表内容
- **地图加载状态：** 异步 `fetchMapItems` 完成后更新 `@MainActor` mapItems
- **徽章进度：** `earnedBadges` 计算属性根据收藏状态自动更新

### 异常处理方式
- 地图 Item 获取失败：打印错误信息到控制台，不中断用户体验
- 地标数据加载失败：使用 `#Preview` 和 `exampleData` 进行测试
- Inspector 导航保护：当导航返回时自动关闭 Inspector（`didSet` 检测 `path.count` 减少）

### 首次使用体验
- 启动时加载示例数据集（`Landmark.exampleData`）
- 异步获取地图位置数据（`fetchMapItems`），完成后自动更新
- 默认显示 "Landmarks" 视图（精选推荐 + 按大洲网格分组）
- 无首次运行引导——示例数据预填充让用户立即浏览
- 搜索功能随时可用

### 设计原则提炼

#### 原则 1：单一数据源
- **选择：** 所有视图通过 `@Environment(ModelData.self)` 共享同一个 ModelData 实例
- **原因：** 状态变更在单一位置反映到所有相关视图
- **代价：** 大量观察属性可能导致不必要的视图更新；需注意 `@MainActor` 约束

#### 原则 2：导航路径自动管理
- **选择：** 使用 `NavigationPath` 的 `didSet` 观察者自动处理 Inspector 关闭等副作用
- **原因：** 将导航相关的副作用逻辑集中到一处，避免分散在各视图中
- **代价：** `didSet` 中的副作用不易追踪，调试困难

---

## Apple Web Design (apple.com)

### 核心交互流程

**产品浏览流程：**
1. 打开首页 → 看到全出血产品展示 tile（hero → dark tile → light tile → dark tile）
2. 滚动 → tile 之间通过颜色变化自然过渡
3. 点击 "Learn more" 或 "Buy" 蓝色药丸按钮 → 进入产品详情或商店
4. 产品配置器中选择配置项 → 配置芯片（configurator-option-chip）切换选中态

**购买流程：**
1. 在产品页面选择配置选项
2. 页面底部浮动粘性栏（floating-sticky-bar）显示价格总和
3. 点击 "Add to Bag" → 进入结账流程
4. 子导航栏始终可见，显示当前步骤

### 状态反馈机制
- **Button Press：** `transform: scale(0.95)` 系统级按下反馈
- **Focus Ring：** Keyboard 聚焦时 2px `#0071e3` outline
- **Link hover：** 文本链接颜色变化（无下划线或仅有下划线）
- **背景过渡：** tile 间颜色变化本身是视觉过渡

### 异常处理方式
- 标准浏览器错误页面（404/500）
- 表单验证错误（设计稿中未遇到，属于已知缺口）
- 搜索无结果展示空状态

### 首次使用体验
- 首页直接展示产品 hero tile，无需任何引导
- 导航结构清晰（global-nav + sub-nav），用户可根据产品层级自由浏览
- 无注册或登录要求即可浏览产品

### 设计原则提炼

#### 原则 1：单色交互信号
- **选择：** #0066cc（Action Blue）是唯一的交互色，所有"可点击"元素使用此色
- **原因：** 用户只需学习一个颜色信号，降低认知负载
- **代价：** 在需要多级交互优先级的场景下缺乏区分度（如次要 CTA 只能使用描边而非其他颜色）

#### 原则 2：颜色变化即分割
- **选择：** tile 之间的颜色变化（light ↔ dark）取代传统分割线或间距
- **原因：** 无需额外装饰即有清晰的分区感
- **代价：** 需要足够多的颜色变体来维持节奏；section 数量受限于可用的深浅交替模式

#### 原则 3：阴影唯一性
- **选择：** 仅产品渲染图使用阴影，UI 元素（卡片、按钮、文本）不使用阴影
- **原因：** 阴影语义单一——表达"物体重量"而非"UI 层级"
- **代价：** 卡片层级无法通过阴影区分；需要依靠背景色变化来表达容器关系


---

## YAAGLSWIFTUI

### 核心交互流程

**启动游戏流程：**
1. 应用启动 → `RootView` 渲染 `NavigationSplitView`（sidebar: GamePickerView / detail: LauncherView）
2. `LauncherView.initialize()` 异步执行：
   a. 获取游戏背景素材（Hoyoverse API：backgroundURL + backgroundVideoURL + logoURL + iconURL）
   b. 检查游戏安装状态（`gameService.installState(for:)`）
   c. 检查是否需要更新（`gameService.updateRequired(for:)`）
   d. 检查 Wine 状态（`wineService.status`）
   e. 检查预下载提示（`gameService.predownloadInfo(for:)`）
3. 主按钮状态由 `installState` + `updateRequired` + `wineStatus` 联合驱动：
   - Wine 未安装（`.notInstalled`）→ 提示安装 Wine
   - 游戏未安装 + Wine 就绪 → "Install" 按钮 → `.fileImporter` 选择目录 → 执行安装
   - 游戏已安装 + 需更新 → "Update" 按钮 → 执行更新
   - 游戏已安装 + 无需更新 → "Launch" 按钮 → 执行启动
4. 启动：通过 `GameClient.launch(config:)` 执行 → 应用 patch → 设置 Wine 属性 → 启动游戏进程
5. 启动完成后：持续跟踪游戏进程状态（通过 `ProcessService`）

**安装游戏流程：**
1. 点击 "Install" → `.fileImporter(.folder)` 显示目录选择器
2. 选择目录 → `configService.setInstallDir(path:)` 保存路径 → `startInstall(to:)`
3. 调用 `gameService.install(game:to:)` → 内部转发到 `GameClient.install(to:)` → 返回 `AsyncThrowingStream<ProgressEvent, Error>`
4. 视图通过 `for try await event in gameService.install(game:to:)` 消费事件：
   - `.message(msg)` → 更新 `statusText`
   - `.download(dp)` → 更新 `progress` + 速度格式化状态文字
   - `.extraction(c, t)` → 更新进度 `Double(c)/Double(t)`
   - `.patch(c, t)` → 更新进度
   - `.indeterminate` → 进度归零（切换为不确定动画）
   - `.completed` → `refreshState()` 刷新安装状态
   - `.failed(error)` → 显示错误 Alert
5. 完成后自动刷新状态以更新 UI 按钮

**更新游戏流程：**
1. 检查 `updateRequired` → 若为 true，主按钮切换为 "Update" 语义
2. 点击 "Update" → 调用 `gameService.update(game:)` → 进度流转同上
3. 更新完成后自动刷新状态

**预下载流程：**
1. 视图初始化时检查 `gameService.predownloadInfo(for:)` → 若 pre-download 可用，显示 `showPredownloadPrompt`
2. 弹出 `.alert` 提示用户：版本号预下载可用
3. 用户选择 "Download Now" → 执行 `gameService.predownload(game:)` 操作；"Later" → 调用 `client.dismissPredownload()` 忽略
4. 预下载进度同样通过 `AsyncThrowingStream` 驱动

**配置流程：**
1. 点击 gear 按钮 → `.sheet` 打开 `ConfigurationView`
2. 垂直 Tab 导航：General → Game → Wine → Advanced(默认隐藏) → Licenses
3. General Tab：安装目录显示、Metal HUD / Retina Mode / Left Command as Ctrl / Proxy / UI Language
4. Game Tab：游戏特定配置（通过 `GameClient.configSections()` 动态驱动）
5. Wine Tab：Wine 版本选择、Wine 状态显示、重新安装按钮
6. Advanced Tab：通过"连续点击版本号 5 次"解锁（FPS Unlock、ReShade、Reset All Settings）
7. Quick Actions 侧边栏：Check Integrity、Open CMD Window、Open Game Folder、Open YAAGL Folder、Check for Updates

### 状态反馈机制
- **AsyncThrowingStream 进度通道：** 所有耗时操作通过 `AsyncThrowingStream<ProgressEvent, Error>` 返回进度事件，视图在 `for try await` 循环中逐个处理
- **三信号本地状态：** 视图使用 `@State private var statusText`（文字描述）+ `@State private var progress: Double`（进度值）+ `@State private var isBusy: Bool`（忙碌状态）
- **进度条表现：** `progress == 0` 时使用 `ProgressView()` 的不确定进度模式，否则显示具体百分比
- **预下载双阶段 Alert：** 通过 `showPredownloadPrompt` 布尔值控制预下载提示的显示
- **Video 加载状态：** `videoLoaded` 布尔值跟踪背景视频是否已就绪

### 异常处理方式
- **GameError 领域错误：** `GameService.GameError` 枚举（notInstalled、executableNotFound、gameClientNotAvailable、installDirectoryNotFound），通过 `AsyncThrowingStream` 的 `finish(throwing:)` 传播
- **ProgressEvent.failed(Error)：** 在进度流中使用 `.failed(error)` 事件传递错误，视图在 `handleProgressEvent` 中统一分发
- **错误 Alert：** 使用 SwiftUI `.alert` 修饰符绑定 `errorMessage`，一次仅展示一个错误
- **目录选择权限：** `fileImporter` 返回 URL 后需要调用 `startAccessingSecurityScopedResource()`，失败时展示权限错误
- **Network 错误：** `DownloadService` 使用 URLSession 的标准错误处理，支持 resume data 中断续传（最多重试 3 次）
- **Wine 进程清理：** `AppDelegate.applicationWillTerminate` 中优雅关闭 wineserver，防止僵尸进程

### 首次使用体验
1. 首次启动：应用打开即显示 `NavigationSplitView`，左侧 sidebar 展示所有游戏，右侧 `LauncherView` 执行初始化
2. 初始化过程中：背景图片/视频从网络加载（可能有延迟），首页显示默认背景
3. Wine 未安装时：主按钮区域提示 Wine 未安装，点击 `WineInstallView` 引导安装
4. 游戏未安装时：主按钮显示 "Install"，点击后触发目录选择器
5. 多游戏切换：通过 Sidebar 点击切换游戏，每次切换触发 `LauncherView` 的 `onChange(of: game)` 重新初始化
6. 配置面板：通过右上角齿轮按钮进入，取消无确认提示，直接关闭

### 设计原则提炼

#### 原则 8：Service 即状态源（无 ViewModel 层）
- **来源：** YAAGLSWIFTUI（`@Observable` Service 直接暴露状态给视图层）
- **描述：** 业务 Service 同时承担状态持有者的角色，不引入独立的 ViewModel 抽象层。@Observable 宏的属性级追踪确保视图仅读取其实际需要的属性时才会重渲染。视图通过 `@Environment(Service.self)` 直接注入服务，无需中间层适配。
- **适用场景：** 中等复杂度、Service 职责清晰的 SwiftUI 应用；团队偏好扁平架构而非多层抽象。
- **Trade-off：** ViewModel 缺失意味着无法为不同视图裁剪状态视图（投影模式）；Service 的测试需要模拟整个依赖链而非 ViewModel 级别的单元测试；Service 的 UI 相关属性（如 statusText、progress）与业务逻辑混在同一声明中。

#### 原则 9：Enum 驱动的配置 UI
- **来源：** YAAGLSWIFTUI（`GameConfigSection` + `GameConfigItem` 枚举）
- **描述：** 游戏特定配置项通过客户端协议返回结构化的配置定义（Section → Item 层级），视图层根据 `GameConfigItem` 枚举变体渲染对应的控件。新增游戏配置时只需在对应 Client 中追加 `GameConfigItem` 枚举值，无需修改视图层代码。
- **适用场景：** 多个实体（游戏）各自定义自己独特的配置项，且配置类型有限（toggle/textField/picker/info）。
- **Trade-off：** 枚举扩展性有限（新增配置控件类型需要修改枚举定义）；枚举变体的 action 闭包持有引用上下文，需小心循环引用；配置布局顺序由返回数组决定，无法在视图层灵活重排。

#### 原则 10：原生 macOS 导航优先
- **来源：** YAAGLSWIFTUI（使用 NavigationSplitView 而非自定义 ZStack 布局）
- **描述：** 优先使用 SwiftUI 原生导航组件（NavigationSplitView、NavigationLink、List selection），而非自定义布局。这与 MiPlay 旧版本的自定义 ZStack 布局形成了鲜明对比。NavigationSplitView 提供了 macOS 标准的侧边栏导航行为：可调整列宽、自动保存状态、系统级动画、无障碍支持。
- **适用场景：** 内容+详情类布局；多个可选项需要通过列表导航切换的场景。
- **Trade-off：** 沉浸式布局受限——NavigationSplitView 强制侧边栏占位空间；自定义导航动画和交互（如滑动切换）无法实现；ColumnVisibility 的控制粒度有限。
