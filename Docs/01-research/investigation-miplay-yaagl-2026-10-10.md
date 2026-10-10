# MiPlay / YAAGL 性能与稳定性阶段性调查

调查日期：2026-10-10（Asia/Shanghai）。基于本地工作区、已安装运行时、注册表文件、实际 YAAGL 资源包和 2026-10-09 的日志。未修改代码、运行时、Prefix、游戏文件或缓存；未启动游戏。仅执行只读检查及 `wine --version`，新增本文档。

## 结论摘要

1. **DXMT 未完整恢复到预期 v0.80。** Git HEAD 中的 d3d11.dll 内嵌 `v0.80`，当前工作区、两处已发现的 MiPlay Debug 应用包及已安装运行时则为 `654f547`。工作区五个 DXMT 二进制均有未提交修改。当前 VERSION 文件也写着 `dxmt-654f547`。
2. **Wine 和 DXMT 的主要文件确实高度对齐，但运行条件未完全对齐。** 三个 Wine 安装的 wine、wineserver、PE/Unix ntdll 哈希相同，均输出 `wine-11.0`。MiPlay 的 DXMT 五件套与 YAAGL/YAAGL ZZZ 的 dxmt 资产逐文件一致；但没有测试当时完整的模块加载清单，不能据此断言每个游戏进程实际加载的全部模块完全相同。
3. **尚不能认定《原神》是 CPU 算力瓶颈。** 已确认启动环境、Prefix、图形设置持久化内容存在差异；尚无逐帧时间、GPU 耗时、热点线程栈或实际 Present 参数。降低渲染精度不提高 FPS 支持“像素处理以外的限制”，但不能区分计算、等待、限帧及配置未生效。
4. **《绝区零》双方日志存在同类 Metal 计算管线异常。** 这与历史文档描述的 `654f547` 问题相符，是优先排查线索；不是已证明的共同根因。历史 110–140 秒不崩的测试也不足以证明某版本彻底修复。

## 一、运行环境核查

### 1. DXMT：声明、选择、安装、实际加载

| 层次 | 证据与结论 |
| --- | --- |
| 产品预期/历史记录 | `Docs/05-implementation/implementation-notes.md:473–476` 记载已替换为官方 v0.80；这是历史记录，不是当前文件证明。 |
| Git HEAD | 当前 HEAD 为 `00f97b3`。`git show HEAD:RuntimeAssets/dxmt/d3d11.dll` 的字符串包含 `v0.80`。 |
| 当前源码资源 | `RuntimeAssets/dxmt/VERSION` 为 `dxmt-654f547`；d3d11.dll 内嵌 `654f547`。五件套均不同于 HEAD，Git 显示未提交二进制修改，VERSION 未跟踪。 |
| 安装选择 | `LaunchCompatibilityEnvironment.swift:97–127,169–213`：优先应用包 RuntimeAssets，缺少 d3d11.dll 才回退 App Support。DXMT 没有独立下载版本选择器，也不读取 VERSION 来约束安装。 |
| 已发现应用包 | `build/GameNews/Build/Products/Debug/MiPlay.app` 和 Xcode DerivedData 中的 Debug MiPlay.app，d3d11.dll 均与工作区 `654f547` 相同。 |
| MiPlay 已安装运行时 | WineVersions 下三个 D3D DLL、winemetal.dll、winemetal.so 与当前工作区逐文件 SHA-256 相同。 |
| 本地历史回退资产 | 当前 `~/Library/Application Support/MiPlay/RuntimeAssets/dxmt` 不存在。已有启动日志多次标记 `bundledRuntimeAssets`。 |
| 游戏实际加载 | 本轮没有运行中的游戏可采集模块映射；最后一次游戏输出未明确打印 DXMT 版本。现有证据强烈支持部署了 `654f547`，**不能确认测试游戏实际加载 v0.80，且现有部署证据与此相反**。仍需在进程存活时核对实际模块路径、文件哈希及 HUD 构建标识。 |

文件 SHA-256 前 16 位如下（比较时使用完整哈希；表中缩写仅用于阅读）：

| 文件 | Git HEAD / v0.80 资源 | 当前 MiPlay 资源及安装 / YAAGL dxmt 资产 |
| --- | --- | --- |
| d3d11.dll | `7ca382af0eb32d8a` | `fbb95116abaf69a5` |
| dxgi.dll | `fc58aae0aba511a1` | `619cd3ef61e5b86e` |
| d3d10core.dll | `833d26971abc8661` | `121f2bb8f6e03aa0` |
| winemetal.dll | `514245d533c75059` | `8055c7532ffa1afd` |
| winemetal.so | `3d50d7f39c64778c` | `2d6966b5b445c781` |

本地 DXMT fork 中 `654f547` 对应 2026-09-17 的 `fix(winemetal): fix custom HUD metrics on macOS 27`。不能把提交标题当作全部构建差异的说明；本轮没有验证该资源对应完整源码树与编译选项。

**回退判断：当前最终状态未回到 HEAD 的 v0.80。** Git 能证明当前差异，不能恢复没有提交的每次替换/撤回操作顺序，也不能确认由哪一次操作留下。

### 2. Wine

代码固定标签为 `wine-crossover-11.0-1-signed`，来源 API 是 `https://api.github.com/repos/yaagl/anime-game-wine/releases?per_page=100`。目录策略见 `BuiltInWineVersions.swift:16,70–78` 与 `WineVersionManagerCatalog.swift:44–52`。

本地安装记录的资产为 `wine-crossover-11.0-1-osx64-signed.tar.xz`；由标签和文件名对应的发布地址为 `https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz`。本轮未重新下载或以远程文件覆盖验证。

三者已安装的以下文件一致：

| 文件 | SHA-256 前 16 位 |
| --- | --- |
| bin/wine | `38632e7c86c171a6` |
| bin/wineserver | `66fbeff4f723ec9d` |
| lib/wine/x86_64-unix/ntdll.so | `a56cc97e1cf9c6f8` |
| lib/wine/x86_64-windows/ntdll.dll | `066b34e12a3c0d13` |

三者 `wine --version` 均为 `wine-11.0`。检查的 Wine 主程序/Unix 库为 x86_64，PE ntdll 为 x86-64。MiPlay 与 YAAGL 的 winemac.so、winemac.drv 也相同。并未逐文件验证整个 Wine 分发包，不能声称所有依赖完全一致。

MiPlay AppData 的 `architecture` 写为 `arm64`，但资产名是 `osx64`，实际 Wine 主程序是 x86_64。这是**元数据与文件架构不一致**，不代表 MiPlay 实际使用了另一种架构；二者运行文件相同，不能用它直接解释 FPS 差距。建议后续确认该字段表示宿主还是资产架构并修正语义。

### 3. Prefix 与装载布局

| 项目 | MiPlay | YAAGL 原神 |
| --- | --- | --- |
| Prefix | `MiPlay/WinePrefixes/shared`，多游戏共享 | `Yaagl/wineprefix` |
| RetinaMode / LeftCommandIsCtrl | `y` / `n` | `y` / `n` |
| Windows 构建号 | 19045 | 19045 |
| Prefix 字体 LogPixels | 96 | 本轮未完整核对所有 DPI 路径 |
| 全局 Wine DllOverrides | 空节；启动覆盖禁用 winemenubuilder | 空节；YAAGL 启动实现传空覆盖 |
| 原神入口 | Wine → Steam 兼容存根 → YuanShen.exe | 相同，实际设置 steamPatch=true |
| 游戏目录 | CrossOver/Mihoyo 下 Genshin Impact | 同一个目录 |
| 游戏注册表配置 | 独立存于 MiPlay Prefix | 独立存于 YAAGL Prefix |

MiPlay 与 YAAGL Prefix 中 steam.exe、lsteamclient.dll、nvapi64.dll、nvngx.dll 均逐文件一致。

MiPlay 将 DXMT 覆盖进 Wine 目录，并将原 Wine D3D 副本放在 Prefix system32；因此 system32 的 d3d11.dll 不是 DXMT，**不能单凭此判定回退到了 wined3d**。YAAGL 启动日志同样记录了向 Wine 目录复制 DXMT；退出后目录中的三个 D3D DLL 已恢复为原文件。离线比较 YAAGL 的 Wine 目录与 MiPlay 的 Wine 目录会产生误导，须比较启动时路径与加载模块。

MiPlay staging 的版本判断只比大小与修改时间（`LaunchCompatibilityEnvironment.swift:476` 起），且没有资产清单校验。这是可靠性缺口；本轮实际 SHA-256 对比没有发现 MiPlay 当前五件套混装，不能将潜在风险写成现有根因。

## 二、《原神》性能差异

### 1. 已确认的配置差异

YAAGL 的实际 `neutralinojs.log:4000`（10 月 9 日 22:20:58）记录：

```text
WINEDEBUG=fixme-all,err-unwind,+timestamp
WINEESYNC=1
WINE_ENABLE_TIMEOUT_FIX=1
DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;
DXMT_CONFIG_FILE=<Yaagl>/dxmt.conf
DXMT_LOG_PATH=<Yaagl>/
MTL_HUD_ENABLED=1
GST_PLUGIN_FEATURE_RANK=atdec:MAX,avdec_h264:MAX
wine C:\windows\system32\steam.exe Z:\...\YuanShen.exe
```

MiPlay `LaunchOrchestrator.swift:250–311`、`LaunchCompatibilityEnvironment.swift:414–446` 装配：

```text
WINEPREFIX=<MiPlay>/WinePrefixes/shared
WINEDLLOVERRIDES=winemenubuilder.exe=d
WINEESYNC=1
GST_PLUGIN_FEATURE_RANK=atdec:MAX,avdec_h264:MAX
MTL_HUD_ENABLED=1  # 当前用户设置
wine C:\windows\system32\steam.exe Z:\...\YuanShen.exe
```

MiPlay 还继承父进程环境，仅清除继承的 `MTL_*` / `METAL_*`，之后合并显式覆盖（`ProcessManager.swift:164–192`）。它没有显式设置 WINEDEBUG、超时开关、DXMT 配置路径或限帧配置。**没有设置不等于测试时环境中一定不存在**：目前日志没有保存完整的最终环境，继承污染尚未排除。YAAGL 日志也主要记录显式命令环境，不是全部继承环境。

上述 YAAGL 设置同时在本机实际 `resources.neu` 中找到，因而不只是 References 代码推测。当前 YAAGL 的 dxmt.conf 不存在；MiPlay 游戏工作目录也未发现 dxmt.conf 或旁置 d3d11.dll/dxgi.dll。不能据此证明测试时文件从未存在。

### 2. 候选原因，按验证价值与证据排序

| 优先级 / 原因 | 具体证据及可解释现象 | 反证与限制 | 可信程度 / 下一步 |
| --- | --- | --- | --- |
| 1：Present 节奏、限帧或显示同步差异 | YAAGL 强制 preferredMaxFrameRate=60，MiPlay 不显式设置；可形成与渲染精度无关的等待、影响 Frame Time。 | `654f547` 对应源码的默认值是 0，不是 30；Present 时按 SyncInterval、初始刷新率和配置计算等待。缺少此变量**不能直接推出锁 30**，也不能保证补上后会变快。 | 配置差异已确认；性能因果未证实。先采帧时间是否集中 33.3ms、GPU 时间、显示刷新率和游戏 VSync。 |
| 2：Prefix 内游戏设置并非完全一致 | 两边原神保存分辨率均 1728×1117，全屏标记为 1；但 GENERAL_DATA 的 graphicsData 第 8 项 MiPlay=3、YAAGL=2，globalPerfData 保存项及版本历史也不同。 | 本轮没有可靠的 7.1 字段映射，不把 key 8 擅自解释成某具体选项；这是最后保存状态，可能包含测试后的更改。 | 不一致已确认，影响未确定。比较同场景时游戏设置截图，尤其 FPS/VSync/渲染精度；无需复制注册表。 |
| 3：游戏线程计算或同步等待瓶颈 | 0.6x–1.5x FPS 不响应与此相容。双方 WINEESYNC=1，但变量不证明机制实际启用；原神现有日志未出现确认 esync 的启动信息。 | Wine/ntdll 主体相同；未获得热点调用栈、每线程 CPU 或等待分布。不能把“CPU 总占用不满”当作排除依据。 | 合理候选，尚无直接证据。用同场景 CPU 栈采样区分执行热点、等待和 GPU 回压。 |
| 4：继承环境、LaunchServices 进程身份或调度差异 | MiPlay 通过 NSWorkspace → GameLauncher fork/exec；YAAGL 使用 shell 启动。MiPlay 保留非 Metal 环境变量，可能携带开发环境状态。 | 未发现显式降低游戏优先级/QoS 的代码；没有测试时进程调度证据，不能断言 App Nap 或 Xcode 导致降速。 | 低至中。采集游戏实际白名单环境、进程树及调度状态；必要时另做已构建同一应用从 Finder 启动的对照。 |
| 5：Wine 日志额外开销 | MiPlay 最后原神 launch.log 有大量 fixme；YAAGL 明确关闭 fixme。MiPlay 文件约 126KB，YAAGL 对应约 38KB。 | 时长不同，不可比较总字节就推导开销；现有文件规模不支持已发生持续高频日志洪泛。 | 差异已确认，解释 40% 差距的证据较弱。采样日志增长速率；仅在证据支持后做一次性 WINEDEBUG 对照。 |
| 6：超时修复设置 | YAAGL 22:20:58 成功运行会话的 WINE_ENABLE_TIMEOUT_FIX=1，之前两次为 0；MiPlay 不显式设置。 | 无控制实验，且本轮在所查 ntdll/kernelbase/kernel32 二进制字符串中未找到该变量。可能由别处处理，也可能该 Wine 构建不消费它。时间相关不等于因果。 | 设置差异确实存在，作用与影响未确认。先定位同版本 Wine 的实现或运行时效果，避免盲目加变量。 |
| 7：缓存冷热、编译和后台竞争 | Prefix 历史不同；shader 编译警告出现在日志中。可能解释首次场景抖动和低帧。 | 未定位并比对实际使用的 DXMT/Metal cache；不能把相对缓存路径直接当作落盘目录。稳定重复场景持续 30 FPS 尚难仅以冷缓存解释。MiPlay 背景视频代码在 scenePhase 非 active 时暂停。 | 低至中。先重复同场景并记录编译/CPU 活动；不清缓存。 |

限帧源码核对使用本地 Git 的 **654f547** 历史内容，而不是把 fork 最新 HEAD 当成已部署版本：`src/d3d11/d3d11_swapchain.cpp` 的 preferredMaxFrameRate 默认 0，Present1 内 `vsync_duration = max(SyncInterval / (preferred ? preferred : init_refresh_rate), preferred ? 1/preferred : 0)`。这是等待路径证据，不是本次实际 SyncInterval 或等待时长的记录。

### 3. 已检查但不足以支持的解释

- 未发现 MiPlay 显式写入 30 FPS 上限；MetalFX 性能选项被 `isSuspended` 过滤，当前 performanceOptions 为空。仍需排除继承的 DXMT 环境变量。
- 主路径仅每 500ms 检查一次 GameLauncher 存活，GameLauncher 父进程阻塞于 waitpid，游戏日志直接写文件；未发现这里有高频忙等。见 `ApplicationLauncher.swift:71–84`、`Tools/GameLauncher/GameLauncher.c:60` 起。
- 背景视频在应用非 active 时暂停（`BackgroundScene.swift:159–166`）；不能直接指控 SwiftUI/视频长期抢 GPU，但实际是否正确失活仍需观察。
- 日志中出现 MoltenVK 能力枚举，**不等于主渲染已回退 Vulkan/DXVK**。需要模块加载及主交换链证据。
- 相同 Wine 主体与相同 DXMT 文件，削弱了“版本不同直接导致 MiPlay 慢”的解释；并不排除 Prefix、启动环境、缓存、窗口行为和加载路径差异。
- 用户给出的 1% Low 属于分布反推的辅助证据；本报告不将其作为标准逐帧统计结果，也未用登录界面帧率否定实测。

## 三、《绝区零》：限定范围的日志结论

MiPlay 最后一次 `LaunchApps/ZenlessZoneZero.app/Contents/Resources/launch.log:491`：

```text
NSInvalidArgumentException
-[__NSCFNumber newComputePipelineStateWithDescriptor:options:reflection:error:]
unrecognized selector
```

YAAGL ZZZ 的 `game_1791556204980.log:380` 与 `game_1791556420867.log:384`，同一 selector 分别发给 NSTaggedPointerString、__NSTaggedDate。后续 `game_1791556485848.log` 持续产生约一小时跨度的日志，最后一次未出现该异常，与用户成功游玩描述相容。

这些记录支持：失败涉及 Metal 计算管线创建时的 Objective-C 接收对象异常；值得排查 DXMT/winemetal 的对象生命周期、并发或兼容性。没有有效符号化调用栈，无法从日志独立确认具体责任函数、内存破坏源或共同根因。历史文档将它断言为“构建回归已修复”，证据强度不足；当前仍可复现同类特征。

双方失败与成功日志都可能出现 WDFLDR.SYS 缺失、HoYoProtect 驱动加载失败；成功会话也出现，因此不能把这几行直接当作本次闪退的充分解释。与本次 22 点会话不同，DiagnosticReports/Retired 中 20:49 的 Wine 报告是 Code Signature Invalid，不能混为同一异常。

关键差异：MiPlay 直接启动 exe，共享 Prefix；YAAGL 经 cmd/config.bat、独立 ZZZ Prefix，当前启用自定义 1728×1117 窗口参数，并执行 fixWebview。MiPlay 最后保存的 ZZZ 分辨率字段为 2228×1440，不能假定与 YAAGL 本次启动一致。双方日志都确认 msync 启动。YAAGL ZZZ 三次会话显式环境相同，超时开关均为 0；从失败到成功没有看到对应的显式环境切换。缓存或执行时序变化仅是候选。

两个启动器使用相同游戏目录，因此 Vulkan loader 的移出/恢复等操作可能共享文件状态；Wine 和 Prefix 目录本身不同。本轮没有证据证明发生并发运行、错误恢复或缓存破坏。MiPlay 按包装进程退出恢复文件，而 YAAGL 还等待 wineserver 退出，这是一项生命周期差异，应在以后采集真实进程树时检查，尚非已证实的闪退原因。

## 四、建议修复方向（均未实施）

1. **先明确 DXMT 基线。** 若仍以 v0.80 为目标，确认后再备份当前五件套、校验可信的 v0.80 完整资产、重建应用包并检查 staging 后文件及进程模块。只改 VERSION 或只换 d3d11.dll 不够。回退应保持整套文件一致。不要把版本恢复与性能环境更改混在一个 A/B 中。
2. **补资产可追溯性。** 增加 DXMT 来源、版本、架构与五件套哈希清单；启动时校验并记录选中来源、实际安装摘要。避免仅凭大小/mtime 判断。规范 Wine architecture 字段。这是针对已确认管理缺口的小范围改进。
3. **性能修复由验证结果决定。** 若帧时间显示同步等待，优先验证 YAAGL 的 Present 配置；若线程热点证实 CPU 执行瓶颈，再修对应路径；若仅日志写入异常，再统一低开销日志配置。当前不建议无证据重构 ProcessManager 或调 Wine 同步参数。
4. **诊断留存。** 后续改为每次启动独立日志，保存最终环境白名单、命令、cwd、运行时/模块身份和真实游戏 PID。现在 ApplicationLauncher 每次启动会清空 launch.log，最后一次内容不能覆盖“多次闪退”的全部证据。GameLauncher 的 64MB 处理只在启动时检查，不是运行时持续限额。
5. **ZZZ 后续。** 先完成版本确认，再在备份与回退方案获确认后做单变量版本对照；若同样失败，收集带模块身份和崩溃线程的报告，转交 DXMT 独立工程调查。暂不清缓存、重建 Prefix 或切图形后端。

## 五、最少人工验证方案

### P0：一组原神同场景基线，优先执行

目的：同时核对真实加载、游戏设置、CPU/GPU/同步等待，避免先做多轮盲调。

操作：按现有方式分别启动 MiPlay、YAAGL，一次只运行一个游戏。进入已观察到差距的同一场景、同一镜头和角色；等载入活动稳定。保持 1728×1117、Retina、1.0x 及当前全屏方式。先不改任何参数。记录电源状态、显示器刷新率、是否通过 Xcode 启动 MiPlay；截取两边图形设置（含 FPS、VSync）与完整 HUD（含 DXMT 构建标识）。每边停留 60 秒。

配合方式：进入场景后通知我当前是哪一个启动器，我再进行只读的实际游戏 PID/父子进程、模块映射、白名单环境、CPU/线程采样和日志增长采集。短时栈采样与纯 FPS 记录分开，以免采样扰动性能数据。只读取 Wine/DXMT/Metal/DYLD 等相关变量，不导出账号或凭据环境。

记录：平均 FPS、逐帧时间（若工具可获得）、GPU frame time/利用率、CPU 热点或等待栈、实际模块路径与哈希、显示模式。无法获得逐帧数据时明确只记录 HUD/曲线，不计算“精确 1% Low”。

结果解释：稳定约 33.3ms 且 GPU 时间显著更短，优先查限帧/同步；GPU 时间接近总帧时间且随像素负载变化，优先查实际渲染/合成负载；单线程持续执行热点支持 CPU 计算瓶颈；主要卡在等待则继续区分游戏限帧、Wine 同步与 GPU 回压。只看总体 CPU 利用率不足以定案。

环境影响：只读采集不主动改变配置；正常游戏启动仍会按现有启动器逻辑 staging、写日志和缓存，无法承诺运行本身完全不写文件。每次退出后先保留本次日志再启动下一次。

### P1：在同一组会话中仅在必要时验证渲染精度

目的：确认设置实际生效，并验证 FPS 不响应的条件。

操作：若 P0 仍无法区分，在相同镜头分别切换 0.6x / 1.5x，各观察 30 秒，记录 GPU 时间、FPS 与画面变化，结束恢复 1.0x。两边都做同样步骤。

结果解释：GPU 时间变化而 FPS 不变，支持另有上限/等待；GPU 时间与画面都无变化，应优先确认设置应用时机或测量对象。若只有冷场景低帧而重复观察改善，增加缓存/编译假设的权重。

环境影响：会修改游戏设置并可能写缓存；这是后续建议，需用户确认后执行，本轮未实施。

### P2：只做一个有依据的单变量 A/B

依据 P0 结果选择一种：临时对齐 preferredMaxFrameRate、临时对齐 WINEDEBUG，或验证同一构建通过 Finder 启动的效果。保持 Wine、DXMT、Prefix 和游戏文件不变，一次只改一个变量，退出后恢复。对照效果必须在相同游戏场景确认，不能用登录界面代替。具体注入方式及回退命令将在确认选择后提供，当前不执行。

ZZZ 暂不要求重复启动。已有两边失败和 YAAGL 后续成功的日志，优先保留；待 DXMT 基线与原神采样明确后再决定是否需要一次受控崩溃复现。

## 证据入口

代码位置均为本地工作区当前版本：

- `RuntimeAssets/dxmt/VERSION`、五件套及 Git HEAD 对比。
- `MiPlay/Domain/Runtime/BuiltInWineVersions.swift`；`WineVersionManagerCatalog.swift:44`。
- `MiPlay/Domain/Launch/LaunchCompatibilityEnvironment.swift:105,169,390,414,432,476`。
- `MiPlay/Domain/Launch/LaunchOrchestrator.swift:250,299,631`。
- `MiPlay/Infrastructure/Process/ProcessManager.swift:164`；`ApplicationLauncher.swift:47,71,104`。
- `Tools/GameLauncher/GameLauncher.c`；`MiPlay/UI/Components/BackgroundScene.swift:159`。
- `References/YAAGL/src/clients/mhy/hk4e/program-launch-game.ts:166`；`nap/program-launch-game.ts:34`；`References/YAAGL/src/wine/wine.ts:76`。
- DXMT 本地 Git 对象 `654f547:src/d3d11/d3d11_swapchain.cpp`、`654f547:src/dxmt/dxmt_shader_cache.cpp`。

运行时证据位于 `~/Library/Application Support/`：

- `MiPlay/AppData.json`、`MiPlay/Logs/miplay.log`。
- `MiPlay/LaunchApps/GenshinImpact.app/Contents/Resources/launch.log`。
- `MiPlay/LaunchApps/ZenlessZoneZero.app/Contents/Resources/launch.log`。
- `MiPlay/WinePrefixes/shared/user.reg`、`system.reg`。
- `Yaagl/neutralinojs.log:3918,3951,4000`、`Yaagl/.storage/`、`Yaagl/resources.neu`、`Yaagl/wineprefix/user.reg`。
- `Yaagl ZZZ/neutralinojs.log:3887,3917,3947`、`Yaagl ZZZ/resources.neu`。
- `Yaagl ZZZ/logs/game_1791556204980.log`、`game_1791556420867.log`、`game_1791556485848.log`。

本轮到此结束静态调查。未证实的 GPU/CPU、缓存和时序问题需要受控运行证据；不扩大到无边界源码搜索或未经确认的修复。
