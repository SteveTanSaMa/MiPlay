# 绝区零：保持 DXMT 不变的修复尝试与验收记录

状态：**尚未达到连续五次、每次 40 秒和 140 秒有游戏画面的验收标准。**

最新结果：用户授权原生截图后，重新开始的有效序列在**第 2 次启动失败**。第 1 次两张截图都有游戏画面；第 2 次在 40 秒之前复现 `NSTaggedPointerString newComputePipelineStateWithDescriptor…` 异常。没有完成五连成功，没有提交生产代码修复。

## 本轮工作

- 使用新的 `build/ZZZFreshAcceptance` 构建目录编译当前本地项目。
- 应用原生下载请求发生 TLS 错误。随后通过官方 GitHub Release 的跳转重新下载同一固定 Wine 资产；代理传输中断后从官方 CDN 续传，没有关闭 TLS 校验。
- 下载文件为 `wine-crossover-11.0-1-osx64-signed.tar.xz`，456,021,524 字节，SHA-256：`89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35`。XZ 校验通过。此步骤不代表应用内下载链路验收通过。
- 用生产代码 `WineVersionDownloader.extractArchive` 完成归档条目、链接与解压树校验；用 `WineVersionManager` / `WineRuntimeProvider` 初始化全新运行时与 Prefix。
- 测试继续使用已安装的游戏文件，没有重新下载整个游戏。测试运行时和 Prefix 与原 MiPlay/YAAGL 安装分离；临时 staging 的游戏 Vulkan loader 在结束后已恢复。
- DXMT 项目资源七件套 SHA-256 在测试前后相同，没有替换版本、重编 DXMT 或修改其源码。
- 新增显式启用的真实游戏测试 `MiPlayCoreTests.testZZZFreshRuntimeAcceptance`。默认单元测试会跳过；需要环境变量 `TEST_RUNNER_MIPLAY_ZZZ_ACCEPTANCE_ROOT`、专门测试目录和截图观察器。

## 第一次真实启动

验收环境：全新 Wine / Prefix，Retina 开，msync 开，Metal HUD 开，DLSS/NVEXT 关，使用生产 staging 与具名 LaunchServices 游戏入口。测试直接复用启动边界，未覆盖完整主界面点击、游戏注册与任务调度流程。

| 验收点 | 包装进程存活 | 有效截图 | 结果 |
| --- | --- | --- | --- |
| 第 40 秒 | 是 | 否 | 不通过 |
| 第 140 秒 | 是 | 否 | 不通过 |

这一会话的日志没有出现此前的 `newComputePipelineStateWithDescriptor` 异常，但没有可验证的游戏画面，不能把“存活 140 秒”称为启动成功，也不能称为闪退已修复。连续测试在第一轮失败后停止，没有挑选或累计成功样本。

截图观察器存在两项问题：后台定时回调未在工具调用之外取得预期截图；随后显式选取隔离游戏应用时，CUA 返回 ScreenCaptureKit `-3811`（捕捉失败）。这些是截图验收问题，不是已证明的游戏闪退。用户随后明确授权原生 `screencapture`，后续执行结果见下文。

最初还出现一次测试程序重复删除解压器已清理归档的错误，已修正后换新空白安装目录；该错误发生在游戏启动之前，不计为游戏启动次数。

## 新发现的 DXMT 根因线索

本地 DXMT Git 对象 `654f547` 中：

1. `ArgumentEncodingContext` 的 `device_` 成员声明在命令辅助对象之后。
2. `ClearUAV` 构造函数立即调用 `ctx_.getComputePipeline`。
3. 该方法使用 `ctx.device_` 创建 Metal 计算管线，此时该成员尚未初始化。

上游提交 `fb4515681daefb789a4d0f403c4bdbca88f3b3de`（2026-09-30）将 `device_` 的声明及初始化移到这些子对象前面；提交描述明确提到向 `NSTaggedPointerString` 发送 `newComputePipelineStateWithDescriptor` 导致启动死亡，与此前 MiPlay/YAAGL 日志特征一致。

这是比先前“缓存或 Retina 导致异常”的推测更具体的源码证据，但本轮尚未获得失败时的符号化栈，首次新环境运行也没有复现该异常。因此它是高度吻合的缺陷线索，不能把本轮截图失败归因于它。

该初始化过程没有已找到的配置开关可以安全跳过；关闭缓存或调整分配器可能改变内存布局，但并未修复未初始化读取。没有将这类不确定的参数变化写入生产启动配置。也没有用注入钩子、重试筛选或切换非 DXMT 后端掩盖问题。

## 证据目录

- `QAArtifacts/ZZZ-NoDXMTChange-20261010/Downloads/transfer-complete.json`：新下载文件身份。
- `QAArtifacts/ZZZ-NoDXMTChange-20261010/native-download-tls-failure.log`：应用内下载失败。
- `QAArtifacts/ZZZ-NoDXMTChange-20261010/upstream-fb45156.txt`：相关上游修复内容。
- `QAArtifacts/ZZZ-NoDXMTChange-20261010-acceptance/acceptance-output.log`：本轮编译与验收输出。
- `QAArtifacts/ZZZ-NoDXMTChange-20261010-acceptance/run-1.log`：第一次真实游戏输出。
- `QAArtifacts/ZZZ-NoDXMTChange-20261010-acceptance/run-1-t40.request.json`、`run-1-t140.request.json`：检查时刻和存活事实；不是截图成功证明。
- 两个目录中的 `dxmt-before.json`：DXMT 资源基线。

## 原生截图授权后的连续序列

重新使用空白 `build/ZZZNativeAcceptance` 完成全量构建。先验证终端原生截图可用；但 XCTest 宿主内发起的 `screencapture` 返回 `could not create image from display`。这次仍属于截图准备失败，日志保留在 `QAArtifacts/ZZZ-NoDXMTChange-20261010-native`，没有算作游戏验收成功。

随后改为独立终端截图观察器，重编测试入口，并在另一个空白运行环境 `QAArtifacts/ZZZ-NoDXMTChange-20261010-observed/FreshSupport` 安装本轮新下载的同一归档。没有复用已有安装或 Prefix；没有再次下载相同的 456 MB 包。观察器按测试的 40 / 140 秒请求采集屏幕，保存开始、结束时间和错误。计时从 LaunchServices 启动请求开始；检查循环最多约一秒调度误差，截图本身还有下表所列延迟。

| 连续启动 | 40 秒 | 140 秒 | 结果 |
| --- | --- | --- | --- |
| 第 1 次 | 协议提示，真实游戏 UI；采集延迟 0.069 秒 | 登录主界面，真实游戏 UI；采集延迟 0.104 秒 | 启动画面检查通过；不代表登录后关卡稳定 |
| 第 2 次 | 游戏已经退出；观察器留下的图片只有桌面，延迟 0.079 秒 | 未继续检查 | 失败，序列停止 |
| 第 3～5 次 | 未执行 | 未执行 | 不能计入成功样本 |

第 1 次截图中的 HUD 显示 `DXMT D3D11 FL_11_1 654f547`，补充了实际加载版本的直接证据。第 2 次 `run-2.log` 在 2026-10-10 08:45:33.744（北京时间）记录：

```text
NSInvalidArgumentException
-[NSTaggedPointerString newComputePipelineStateWithDescriptor:options:reflection:error:]: unrecognized selector
libc++abi: terminating due to uncaught exception of type NSException
```

这次失效有异常日志与第 40 秒无游戏画面相互印证，属于真实启动崩溃。它发生在全新环境的第二次启动，说明“只重装 Wine / 重建 Prefix 就解决问题”不成立。该复现也进一步支持上述初始化顺序缺陷是主要候选根因；仍缺乏符号化栈，不能把二进制中具体指令位置写成已直接证明。

### 保持环境与验证边界

- 项目 DXMT 七个 DLL / SO 测试前后 SHA-256 完全相同，构建产物七个文件也全部与基线匹配。运行时核心 D3D DLL 与基线匹配；关闭 NVEXT 的测试保留 Wine 自带 NVAPI / NGX，未安装 DLSS 兼容资源。
- 已恢复 `ZenlessZoneZero_Data/Plugins/x86_64/vulkan-1.dll`，没有遗留 `.bak`；隔离测试游戏与 wineserver 已退出。原 MiPlay / YAAGL Prefix 没有重建或清理。
- 只增加验收测试与报告，没有将猜测性的参数修改写入产品启动代码，也没有修改 DXMT 源码或资产。
- 应用原生下载 TLS 问题仍未修复。使用官方归档的外部传输不能称为完整应用内下载链路通过；游戏安装复用现有文件，未重新下载整款游戏。
- 验收入口直接复用生产安装、Prefix、staging 和具名游戏应用边界，并非完整主界面操作。两张成功截图处于协议 / 登录阶段，不用于推断游戏内性能或关卡稳定性。

### 后续建议

当前没有找到不改 DXMT 的可靠根因修复。该成员读取发生在渲染上下文构造过程中，修改游戏缓存、同步开关或启动轮询不能纠正 C++ 成员初始化顺序。随机改变内存布局、自动重启或不断重建 Prefix 都不适合作为修复。

在保持本次限制的前提下，保留失败证据，不宣称修复成功。如果之后允许更新 DXMT，应优先采用已修复初始化顺序的明确构建，再从新的连续五次序列验证；这属于后续方向，本轮没有执行。

最新完整证据位于 `QAArtifacts/ZZZ-NoDXMTChange-20261010-observed`：`acceptance-output.log`、`run-1.log`、`run-2.log`、三张截图、对应 request / capture JSON、`capture-observer.log`、`dxmt-before.json`、`dxmt-after.json`。测试结果为 `build/ZZZNativeAcceptance/Logs/Test/Test-MiPlay-2026.10.10_08-40-25-+0800.xcresult`，结果明确为失败。

## 补充：YAAGL 参考源码是否最新、是否有可借鉴方案

2026-10-10 通过远程 Git 实时核查：

- `References/YAAGL` 工作目录干净，当前 `main` 为 `dae126a31a37080f8e114abfa211ab5cea2ac2b1`（提交时间 2026-10-06 22:51:56 +0900）。
- 远程 `main` 为 `784dda385c536286ef75f92e990514ac81509784`（2026-10-07 10:17:35 +0900），本地落后一个提交。最新发布标签 `0.3.21` 为 `5c1f50c0ad5863c40135c6f938879831a771858c`；主分支和发布标签是不同版本边界。
- 执行了 `git fetch origin main --no-tags` 获取比较对象，没有 checkout / merge / pull 工作目录。远程旧地址 `3Shain/yet-another-anime-game-launcher` 对应现 `yaagl/yet-another-anime-game-launcher`。
- 新提交只改设置界面、明暗主题与相关展示。绝区零启动文件、Wine 清单、DXMT 下载配置和通用 patch 文件均无差异；绝区零启动文件 SHA-256 在本地与远程对象中都是 `0dce90ca4e9b02a217860d740efc9a6d50bb33303a14db8a94c083aa5dab506a`。因此没有遗漏在这个新提交中加入的绝区零启动修复。
- `References/YAAGLSWIFTUI` 没有独立 `.git`，是本工程中的参考快照，不能用 YAAGL 主仓库的最新提交代表它也已同步。

| 可借鉴项 | 源码证据及 MiPlay 差异 | 对本次异常的判断 |
| --- | --- | --- |
| Steam 兼容存根 | `src/config/index.tsx:216–222` 的推荐设置为 `nap` 开启 `config_steam_patch`；`nap/program-launch-game.ts:101–109` 经 `steam.exe` 启动。MiPlay `launchInvocation` 只对原神采用存根，绝区零直启。 | 是值得优先受控测试的兼容性差异，但没有证据能纠正 DXMT 的未初始化成员读取。 |
| Timeout Fix | 同一推荐设置开启 `config_timeout_fix`；`nap/program-launch-game.ts:111` 显式传 `WINE_ENABLE_TIMEOUT_FIX=1/0`。MiPlay 没有显式传这个变量。 | 可以与 Steam 项分开验证。它是 Wine 行为开关，不应直接称为 Metal 管线异常的修复。 |
| 登录 WebView 修正 | `nap/program-launch-game.ts:38,142–193` 在启动前删除 `MIHOYOSDK_WEBVIEW_RENDER_METHOD_h1573598267` 和匹配 `HOYO_WEBVIEW_RENDER_METHOD_ABTEST_` 的值；MiPlay 无相应逻辑。 | 本次失败的隔离 Prefix `user.reg` 中没有找到这两类值，暂不能解释本次失败。更适合诊断登录 UI 问题。 |
| msync、图形资产与日志 | YAAGL 为 DXMT / ZZZ 开启 `WINEMSYNC=1`、相同视频解码 rank；它仍声明 DXMT `654f547`，固定推荐 Wine 归档 SHA 与本轮重新下载一致。YAAGL 还传 DXMT 配置文件路径与较少 Wine 日志。 | msync 和核心资产已有对齐。未找到由这些配置安全跳过 DXMT 上下文构造缺陷的实现。 |

本机 `Yaagl ZZZ/.storage` 的当前状态：`config_steam_patch=false`，`config_timeout_fix` 不存在（源码缺省关闭），`wine_tag=11.0-1-crossover-signed-experimental`，`installed_dxmt_version=654f547`。这不是用户此前每次测试启动时的环境快照，但说明“YAAGL 推荐开启”与“本机 YAAGL 实际保存开启”不能混为一谈。不能据此宣称 Steam / Timeout Fix 是 YAAGL 此前成功启动的原因。

结论：参考源码略旧，但最新差异没有现成的绝区零修复。可从现有推荐设置中提取 Steam 兼容存根与 Timeout Fix 两个受控验证候选；应逐项测试、保留崩溃签名，最后再执行连续五次验收。一次成功或崩溃频率下降仍不能证明根因消除。本次仅分析，没有开启开关、修改 Prefix 或再次启动游戏。

## 后续：已同步 YAAGL，核查三款游戏推荐设置

按用户随后指示，已将 `References/YAAGL` 快进到 `784dda385c536286ef75f92e990514ac81509784`，再次 fetch 确认 `HEAD...origin/main` 为 `0 0`，参考仓库工作目录干净。该操作更新参考源码，没有更新已安装的 YAAGL 应用或修改 MiPlay / Wine / DXMT。

最新源码 `src/config/index.tsx:266–276` 的推荐设置如下：

| 游戏 | Steam 存根 | Timeout Fix | 临时网络屏蔽 | DXMT 同步 | 游戏入口 |
| --- | --- | --- | --- | --- | --- |
| 原神 | 推荐开启 | 推荐开启 | 推荐关闭 | esync | `steam.exe → 游戏` |
| 绝区零 | 推荐开启 | 推荐开启 | 推荐关闭 | msync | `steam.exe → 游戏` |
| 崩铁 | 启动流程无此选项 | 启动流程未设置此变量 | 推荐开启 | msync | `cmd /c config.bat → jadeite.exe → 游戏` |

崩铁入口见 `src/clients/mhy/hkrpg/program-launch-game.ts:39–49,90–108`：先处理 WebView、Prefix 属性和 NV 扩展，再在批处理里调用 Jadeite；DXMT 分支还设置 60 FPS、NVIDIA vendor/device ID 和 `DXMT_ENABLE_NVEXT=1`。这些行为与其他两款不同。

再次只读检查本机保存配置发现：`Yaagl` 和 `Yaagl ZZZ` 当前均保存 `config_steam_patch=true`、`config_timeout_fix=true`、`config_block_net=false`。这与上次检查 ZZZ 的状态不同，是本次读取时的事实；本轮没有写这些配置，也不能用当前值回推先前测试时的值。没有发现独立的 YAAGL 崩铁支持目录，因此无法证明本机崩铁实际保存了推荐值。源码推荐 `blockNet=true`，不等于缺省或本机实际开启；其 UI 缺省仍为关闭。

用户所说 Steam 兼容确实就是 MiPlay 原神现用的 `steam.exe` 存根路线。可复用存根安装和调用基础方法，但不能据此为崩铁启用 Steam，也不能抹去三款的同步、帧率、NV 扩展和网络行为差异。三款采用相同选项这一合并条件不成立，本轮没有改动 MiPlay 启动逻辑，也没有再次运行游戏。

## 最新用户实机失败：2026-10-10 10:53

用户完成新启动策略后的实机启动，仍发生闪退。只读检查与证据保全如下，没有再次启动游戏、清缓存或重建 Prefix：

- 当前运行的 MiPlay 来自 Xcode DerivedData，主程序构建时间为 10:51:50；其随包 GameLauncher 与项目当前入口二进制 SHA-256 一致。Prefix 的 64 位 Steam 与 lsteamclient 文件分别匹配本次应用随包资产。
- 当前 Wine 的 `d3d11.dll` 与该应用随包 DXMT 文件一致。仍缺少此次实际进程的完整模块映射，不能仅凭这个事实宣称全部加载链路已确认。
- 10:53:03 完成 bundledRuntimeAssets staging 与 NV 扩展准备，10:53:33 创建启动进程，10:53:34 确认运行，10:53:48 记录异常退出。时间均为北京时间。
- 游戏日志明确显示 `msync: up and running`。异常为 `NSInvalidArgumentException`：`-[__NSTaggedDate newComputePipelineStateWithDescriptor:options:reflection:error:]: unrecognized selector`，随后 `libc++abi` 终止；包装入口 `launch.status` 为 `exit:1`。
- 现有结构化日志未记录完整 Wine argv / 环境快照，无法在进程已退出后直接确认这次 Steam 与 Timeout Fix 的实际传入值。资源和构建记录支持新版代码已部署，但不能替代调用值证据。

这次随机 Objective-C 接收对象从先前字符串变成 tagged date，与已发现的未初始化 `device_` 问题高度吻合。不能把 Steam / Timeout Fix 集成或全新环境视为已经修复该根因；目前仍没有可靠的不改 DXMT 的根因修复证据。若进一步复现，应收集异常断点的符号化栈及明确的启动调用快照，而不是继续清理缓存或累计重试。

原始证据副本保存于 `QAArtifacts/ZZZ-UserCrash-20261010-1053`：`launch.log`、`launch.status` 与 `launch-events.jsonl`。

## YAAGL ZZZ 成功会话的数据目录对照

用户确认 YAAGL 可以正常启动后，直接只读检查 `/Users/stevetan/Library/Application Support/Yaagl ZZZ`。最新 `game_1791601487855.log` 对应北京时间 11:04:47.855 启动，最后修改为 11:07:37.370；日志没有本次 MiPlay 的管线异常，包含多个 DXMT feature-level 与渲染阶段记录。用户的实机成功反馈与日志一致；本轮没有自行操作 YAAGL 游戏。

### 主要新线索：NV 扩展链路没有对齐

| 项目 | YAAGL ZZZ | MiPlay 本次失败环境 |
| --- | --- | --- |
| Steam / Timeout Fix 保存值 | 均为 true | 新版代码启用；上一节说明实际 argv 快照缺失 |
| NV 扩展 | ZZZ 启动代码不设置 `DXMT_ENABLE_NVEXT` | `AppData.json` 的 `dlssCompatibility=true`，失败会话记录 `launch.nvext_prepared` |
| runtime 与 Prefix 的 nvapi64.dll | Wine 原始文件，SHA 前缀 `206693df4a1c1cb1` | DXMT 配套文件，`fdfb7dc5725c96b8` |
| runtime 与 Prefix 的 nvngx.dll | Wine 原始文件，`756eb5cf9b082572` | DXMT 配套文件，`168dd9a186ea908f` |
| NVIDIA Global / nvlddmkm 识别值及 NGX FullPath | 检查的对应节没有值 | 有识别值 `dword:1` 和 `C:\\Windows\\System32` |

YAAGL `src/clients/mhy/patch.ts:90–95` 只为崩铁部署 DXMT NGX；绝区零没有采用这条扩展链路。因此不能继续把两边称为完整图形运行环境相同。MiPlay 的 DLSS 兼容集成是显式实验开关，但当前处于开启状态，必须纳入失败分析。这个差异比继续无差别清理缓存更适合优先验证。

NV 扩展差异已经确认，**它导致本次闪退还未确认**。此前全新 Prefix、NVEXT 关闭的隔离验收也曾出现相同管线异常，所以不能据此声称关闭扩展必然修复；初始化顺序缺陷仍然是强候选。扩展可能增加相关调用或改变初始化条件，也可能与本次根因无关，现有证据无法区分。

### 不应误判的差异

- YAAGL 退出后 `patchRevertProgram` 恢复 Wine 原始 D3D DLL；所以退出状态下 Wine runtime 的 d3d11 / dxgi 与 MiPlay 不同。YAAGL 的 `dxmt` 核心资产仍与 MiPlay 逐文件一致，不能把退出后的文件差异当作运行时使用了其他 DXMT 的证据。
- Wine 主程序、wineserver、PE/Unix ntdll、winemac 与 winemetal 已检查文件哈希一致。Retina 为 y，左 Command 为 n，DPI 96、Windows build 19045 一致。
- YAAGL 成功日志仍出现 WDFLDR / ZwLoadDriver、SOCK_RAW 等错误，不能单独用这些条目解释 MiPlay 闪退。
- YAAGL 设置 `WINEDEBUG=fixme-all,err-unwind,+timestamp` 与 DXMT 日志/配置文件路径；MiPlay 没有完全同样的日志环境。YAAGL 目录中当前不存在 dxmt.conf，暂无该文件提供额外图形修复参数的证据。

### 最小下一步验证

在保留 Steam、Timeout Fix、Wine、DXMT、Prefix 和游戏文件的前提下，先只关闭 MiPlay 的 DLSS 实验开关，确认启动环境实际为 `DXMT_ENABLE_NVEXT=0`，重复既定 40 / 140 秒画面标准。此操作改变一个应用设置，不要求重新下载 Wine 或清缓存。关闭开关不会自动还原已部署的 DLL，所以这是“扩展开关”对照，而非完整复制 YAAGL 的 DLL 状态。

若仍失败，再在隔离环境中对照 Wine 原始 NVAPI / NGX 与 DXMT 扩展文件，避免直接覆盖原共享 Prefix、破坏崩铁兼容准备。还应记录真实启动 argv 和关键变量，必要时采集符号化异常栈。只有稳定通过连续五次之后，才能把某项改动称为有效方案。本轮没有改变开关、DLL、注册表、缓存或启动任何游戏。

证据副本及完整 DLL 哈希保存于 `QAArtifacts/YAAGL-ZZZ-Comparison-20261010`。

## 关闭 DLSS 后仍失败的对照结果

用户随后关闭 MiPlay DLSS 实验开关，保持其他条件不变，再次启动失败。只读核查确认：

- `AppData.json` 中 `dlssCompatibility=false`，Retina / Metal HUD 等设置保持开启。
- Prefix 中 NVIDIA 识别值和 NGX `FullPath` 已不存在，符合 DXMT 在 `DXMT_ENABLE_NVEXT != 1` 时清除这些值的代码行为。这比只看开关值提供了更强的运行副作用证据；仍不是完整环境快照。
- 新日志仍是相同 selector 异常，接收对象这次为 `NSIndexPath`，包装入口结果 `exit:1`。
- Prefix 的 NVAPI / NGX DLL 仍为 DXMT 扩展文件，哈希没有自动还原为 YAAGL ZZZ 的 Wine 原始文件。

结论：关闭扩展开关未解决问题，“仅因为 NVEXT 开启才崩溃”已不支持作为唯一解释。不能把全部 NVAPI 文件差异也一并排除，但不应继续让用户重复开关或清缓存。随机错误接收对象持续变化，与未初始化对象指针缺陷仍高度吻合，最终定位仍需符号化异常栈。

下一步优先顺序：在独立诊断环境中用 Wine 原始 NVAPI / NGX 完成真正与 YAAGL ZZZ 对齐的文件状态，再对照相同 runtime / Prefix 下的启动调用与环境，区分资产部署和 LaunchServices / Wine 启动链差异。若仍出现同一异常，使用异常断点确定实际调用位置。原共享 Prefix、游戏文件、DXMT 资产暂不改变。

证据副本位于 `QAArtifacts/ZZZ-NVEXT-Off-Crash-20261010`。
