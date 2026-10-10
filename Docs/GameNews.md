# 主窗口游戏新闻

实现与验证日期：2026-10-09。

## 审查与布局决定

主窗口固定 1280×688。现有选择栏宽 76，左右边距 30、底边距 48；主操作在右下。
检查了 BackgroundView、BackgroundScene、GameSelectionRailView、PrimaryActionButton、MainTaskFeedbackView，以及本机缓存的三款官方静态背景和 theme 图。原神左侧上方是版本文案；星穹铁道中央是人物，左下较暗；绝区零左上是活动标题，人物在右侧。

新闻作为底部 HStack 的独立子视图，位于选择栏右侧，留出 18 点额外间距。宽度为窗口宽度的 27%，上限 340 点；Banner 保持原比例，高度上限 160 点；分类下最多三条新闻，剩余条目在原生 popover 中打开。没有固定大面板或无限列表。所有控件保持原位置与行为。关闭新闻会移除整个子视图及其任务，恢复原有布局。

图片本身无玻璃覆盖。新闻文字区与小型轮播控制条各使用独立单层 regularMaterial，不使用嵌套玻璃、发光或额外阴影。Increase Contrast / Reduce Transparency 下文字区采用系统窗口颜色。原生 Picker、Link、Button 与原生 popover 提供键盘、Focus 和无障碍语义。

## 数据源与参考

技术参考：[DreamedWorker/Mingora](https://github.com/DreamedWorker/Mingora)，本地参考 checkout 在 References/Mingora，审查版本 `71adf0d6d67d874e051bbc3430d888bfe8e4f773`。阅读了 GameNotice.swift、HomeView.swift、AppState.swift、HomeService.kt、HoyoApiService.kt、HYPClient.kt、GameId.kt 及 GameContentWrapper.kt。参考仓库仅本地保留，未复制其实现，也未引入 Kotlin 或图片第三方依赖。

真实数据来自 HoYoPlay 的 HTTPS GET 接口：

`https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getGameContent`

参数 `launcher_id=jGHBHlcOq1`、`language=zh-cn`，`game_id` 映射：

| MiPlay 游戏 | API ID | biz |
| --- | --- | --- |
| 原神 | 1Z8W5NHUQb | hk4e_cn |
| 崩坏：星穹铁道 | 64kMb5iAWu | hkrpg_cn |
| 绝区零 | x6znKlJ0xK | nap_cn |

当天三接口都返回 `retcode=0`，分别有 6/7/6 张 Banner、8/7/8 条新闻。返回包为 `data.content`；Banner 是 `id` 和 `image.url/link`，新闻是 `id/type/title/date/link`。分类值为 `POST_TYPE_ACTIVITY`、`POST_TYPE_ANNOUNCE`、`POST_TYPE_INFO`。日期只提供月/日；保留其显示格式，近期新闻按日期排序，跨年时以获取时间处理月/日先后。

解析同时核对响应的 game.id 和 biz。过滤未知分类、重复 ID、空标题及非 HTTP(S)、带凭据或缺少主机的链接。图片只接受 HTTPS。点击用原生 Link，在系统默认浏览器打开。

## 架构与状态

- Domain/News/GameNews.swift：Sendable/Codable 模型、分类、链接规则、日期排序、可替换提供者协议。
- Infrastructure/News/HoYoPlayNewsProvider.swift：复用 NetworkDownloadProvider、LogWriter；解析、身份检查、缓存。
- Infrastructure/News/NewsBannerImageCache.swift：图片下载、ImageIO 后台缩略解码、内存和磁盘缓存。
- UI/ViewModels/GameNewsViewModel.swift：加载/成功/空/失败/缓存状态；缓存优先、取消检查、请求 token。
- UI/MainWindow/GameNewsPanel.swift：新闻展示、分类、最多三行、更多 popover、手动/自动轮播。
- MainWindowScene.swift、MiPlayApp.swift：局部布局与依赖注入。
- SettingsAppViews.swift：默认开启的 `@AppStorage("showGameNews")` 开关，复用现有 UserDefaults 设置方式。
- MiPlayTests/GameNewsTests.swift 与 project.pbxproj：新增新闻测试。
- script/build_and_run.sh 与 .codex/environments/environment.toml：可复现构建/运行入口。

新闻 JSON 按游戏分开缓存在系统 Caches/MiPlay/GameNews-v1，30 分钟内无需重复请求。过期先显示缓存，再异步刷新。失败保留旧内容并显示简短提示；首次失败提供刷新按钮，日志只影响附加新闻功能。原子写入失败不会丢弃网络获取的内容。没有后台轮询或数据库。

图片按 URL SHA256 存储，磁盘有效期七天，上限 30 文件/40 MB，内存最多 18 张，最长边解码到 900 像素。文件读取、写入和解码位于 actor；主线程只展示 CGImage。图片失败回退为可点击的官方活动入口。

SwiftUI `.task(id:)` 管理加载和轮播，视图移除自动取消，切换游戏和 Banner 集合重置页码；请求 token 防止不配合取消的旧请求覆盖新游戏。多 Banner 才启用八秒轮播；暂停、鼠标悬停、键盘/无障碍焦点、窗口非活动和 Reduce Motion 均停止自动轮播。

## 验证与限制

Debug Xcode build 与应用运行成功。全量 144 项 XCTest 无失败，包含七项新增测试：三游戏映射与身份核对、链接过滤/空内容、跨年排序、磁盘缓存跨 provider 恢复/HTTP 503 降级、TTL/强制刷新、旧请求竞争、取消与首次失败。日志位于本地 QAArtifacts/GameNews-20261009。

真实 MiPlay 窗口验证原神/绝区零新闻切换、分类、Banner、暂停和缓存跨进程恢复。星穹铁道在使用生产视图与真实接口的独立 Preview.app 中检查，因本机主应用未定位该游戏，不声称完成其主应用安装/启动流程。三款静态构图下新闻与游戏选择/设置/右下主操作无重叠。原神新闻点击在 Safari 打开准确的官方活动 URL。

通用设置开关实际切换与重启持久化检查记录在 QAArtifacts/GameNews-20261009/interaction-check.md。

限制：接口来自官方启动器但没有稳定性保证；可替换 provider 将解析与 UI 隔离。目前与 MiPlay 背景保持一致，统一使用国服简体中文新闻，未添加国际服/渠道服新闻选择。未验证所有动态背景帧或未来素材，也未运行真实游戏启动、完整 VoiceOver 朗读、系统全局 Reduce Motion/Increase Contrast 切换或 Instruments 性能分析。无障碍相关分支、轮播生命周期已代码审查；实际辅助功能验收仍需要这些额外检查。


## 2026-10-09 外观与交互调整

Banner 与文字合并为一个共用圆角、描边和深色系统材质的卡片，中间轮播控制栏已移除。新闻列表固定三行所占的 84 点高度；两条、三条、空内容与加载状态均使用这一区域，“更多”与缓存状态放在标题行，避免改变底部高度。Banner 加载和图片失败回退也保持 160 点高度，图片仍按原比例适配。

取消所有用户可见的刷新、暂停、继续与翻页入口，包括右键菜单。Banner 使用八秒自动轮播，悬停、焦点、窗口失活、Reduce Motion 时自动暂停；数据依照缓存 TTL 和游戏切换自动加载。分类仍是原生分段控件。真实窗口已对比星穹铁道三条活动和两条资讯，卡片边界与高度一致；Debug 编译与启动通过。

## 悬停切换按钮

移除了可见的“游戏新闻”和缓存状态标题行，分类与列表直接位于 Banner 下方。图片两侧各有一个悬停时淡入的切换按钮，离开图片后隐藏；点击立即切换，并将自动轮播恢复时间推迟到本次点击后的 20 秒，每次点击重新计时。恢复后仍按八秒周期轮播；悬停、键盘/无障碍焦点和 Reduce Motion 保护保持有效。方向键与无障碍上一张/下一张操作采用相同的短暂停逻辑。

本轮 Debug 编译和启动通过。实际窗口确认文字标签移除、悬停显示箭头、点击切换、离开隐藏；手动切换后约十秒图片保持不变，随后已观察到自动轮播恢复。新闻三行的固定高度保留。


## 固定高度滚动列表

新闻列表改为原生纵向 ScrollView，完整展示当前分类的所有条目，保持 84 点（三行）的可见高度。超过三条时允许鼠标滚轮和触控板滚动，三条及以下禁用滚动；移除“更多”按钮和 popover。切换游戏或分类时重建该滚动区域，回到列表顶部。

## 底边对齐

主窗口保留现有 bottom 对齐与 48 点外边距。移除游戏选择栏的底部内边距，并把设置按钮的 56 点可见表面及描边对齐到其 64 点点击区域的底部，使设置按钮、主操作按钮、新闻卡片的可见下沿一致。Debug 编译、启动与真实窗口截图检查通过。

## 主界面文字放大

新闻标题及状态文字调整为 14 点，日期为系统 body；分类使用较大的原生分段控件。新闻行高同步改为 32 点，列表保持三行可见高度（96 点），滚动规则不变。主操作文字调整为 title2，任务反馈、进度百分比、恢复说明与启动准备文字也适当放大。Debug 编译、启动与真实三行新闻界面检查通过，底部对齐保持一致，文字未发生纵向裁切。
