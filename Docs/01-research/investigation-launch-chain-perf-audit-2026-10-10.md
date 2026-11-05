# MiPlay / YAAGL 游戏启动链路与性能差异审计

审计日期：2026-10-10（Asia/Shanghai）
范围：游戏启动链路（FPS/帧时间/稳定性）；不含 UI、下载、新闻、账户。
方法：只读静态分析（源码 + 已安装运行时 + 应用包 + 本地日志）。**未修改任何代码/运行时/Prefix/游戏文件/缓存，未启动游戏。**
基准：MiPlay 工作区 @ `ee04690`（工作区仅 `Docs/05-implementation/implementation-notes.md` 有未提交改动）；YAAGL `References/YAAGL` @ `784dda385c536286ef75f92e990514ac81509784`，**与上游 `origin/main` HEAD 一致**（`git ls-remote` 核对，未过期）。

证据分级（全文使用）：

| 级 | 含义 |
| --- | --- |
| A｜已确认代码差异 | 两侧源码/资产可逐行核对，差异客观存在 |
| B｜已确认运行环境差异 | 磁盘上的实际文件、注册表、日志可证 |
| C｜有机制解释的假设 | 有源码级机制，但未在本机实测复现因果 |
| D｜实验已支持 | 有本机测量数据支持 |
| E｜已被削弱/排除 | 有反证或证据不足以支撑 |

---

## 1. 执行摘要

**启动链路的关键区别（按重要性）**

1. **帧节奏配置**：YAAGL 原神显式 `DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;`；MiPlay 原神**不设置任何 `DXMT_CONFIG`**（A）。这是两侧原神启动环境里唯一影响呈现节奏的实质差异。
2. **DXMT 二进制不同**：MiPlay 是打过补丁的 `654f547+miplay-fb45156`（修 `ArgumentEncodingContext` 成员初始化顺序）；YAAGL 是上游 stock `654f547`（A/B）。补丁只改变成员声明顺序，**不预期影响 FPS**，但**直接影响启动崩溃概率**。
3. **进程创建通道不同**：MiPlay 走 LaunchServices → 打包 `.app` → `GameLauncher` fork/exec（自有进程组、状态文件、`wineserver -w` 等待）；YAAGL 走 Neutralino 的 shell 字符串 `spawnProcess`（`&>` 重定向、无进程组、无 cwd 选项、退出码只看包装器）。
4. **环境过滤不同**：MiPlay 只剔除继承的 `MTL_*`/`METAL_*` 后合并显式覆盖；YAAGL 不做任何过滤（且 `WINEDLLOVERRIDES: ""` 因 `command-builder.ts:41-43` 丢弃假值而**从未真正清空**）。**已实测**：从 Xcode 启动 MiPlay 时，Xcode 的 `DYLD_LIBRARY_PATH`/`DYLD_FRAMEWORK_PATH` 会进入 Wine 进程（B）。
5. **Prefix 粒度**：MiPlay 三款游戏共享一个 Prefix 与一个 wineserver；YAAGL 每个游戏实例各自一个 Prefix（A/B）。
6. **会话结束**：MiPlay 在退出后执行 `wineserver -k`；YAAGL 只 `wineserver -w`，从不 kill（A）。
7. **其余已对齐**：esync/msync 分配、`WINE_ENABLE_TIMEOUT_FIX`、`GST_PLUGIN_FEATURE_RANK`、Steam 存根四件套、Retina/LeftCommand、wine/winemetal 资产哈希（A/B）。`Docs/05-implementation/yaagl-launch-profiles-2026-10-10.md` 的对齐成果在 HEAD 中已生效。

**真正可能影响 FPS / 帧时间的区别**：只有第 1 项（帧节奏配置）有明确的源码机制；第 2/3/4 项的机制存在但方向不明或未证实；第 5/6 项更偏稳定性与启动时序。

**真正可能影响启动稳定性的区别**：第 2 项（DXMT 补丁：MiPlay 修了一个 stock 版本会导致游戏在 `newComputePipelineStateWithDescriptor` 上崩溃的未初始化 `device_` 缺陷，方向对 MiPlay 有利，但**该补丁不充分**——隔离实验里 MiPlay 侧仍复现过一次同类异常）；第 6 项（`wineserver -k` 后快速重启 Prefix 可触发 `msync_init Failed bootstrap_look_up`）；第 5 项（共享 wineserver 的连带影响，受"一次只跑一个游戏"约束而减小）。

**最值得怀疑的原因**：原神——**无帧节奏上限时的 present 时序**（C，可用单变量实验在 10 分钟内证实或否证）；绝区零——**stock DXMT 的未初始化对象**（C→D 方向，MiPlay 已修其中一处，残留路径未知）。

**仍不能确认的**：MiPlay 是否真的被锁在 30 FPS（无逐帧数据）；实际游戏进程加载的模块清单与 DXMT 构建标识（从未在游戏存活时采集）；esync/msync 是否真正生效；游戏内图形设置是否可比。

---

## 2. 双方完整启动时序

### 2.1 MiPlay（`MiPlay/`，HEAD `ee04690`）

```
点击启动 (MainWindowScene.swift:129)
→ LibraryViewModel.performPrimaryAction (:554) → launchGame (:564/:572)
→ TaskScheduler.enqueue → enqueueReceipt → persist(AppData 写#1) → schedule (:203/:308)
→ TaskScheduler.run → commit(AppData 写#2) → phase("正在检查游戏文件和权限")(AppData 写#3) (:43/:50/:61)
→ LaunchOrchestrator.launch(game:) (:115)
   ├ PreLaunchValidator.validate：系统版本、安全作用域可达性、完整性清单(缺失即 unsupported)、磁盘空间 (:149)
   ├ gameRegistry.transitionGame(.launching)(AppData 写#4) (:178)
   ├ 获取安全作用域书签 (:184) [+ 可选 updateResolvedLocation(AppData 写) (:191)]
   ├ WineVersionManager.validatedRuntime() / acquireSharedPrefixLease() (:202/:206)
   ├ WineRuntimeProvider.load()：首次 `wine --version`（进程内按二进制指纹缓存）(:208)
   ├ prepareSharedPrefix：读 user.reg 判断 RetinaMode/LeftCommandIsCtrl → 需要才 `wine reg add`；
   │  未就绪才 `wine wineboot -u` (:209-212 → WineRuntimeProvider.swift:313/345/362)
   ├ firstExistingExecutable(at:) → 解析实际 exe (:214, GameConstants.swift:86)
   ├ gameEnvironmentSettings()（AppData 读）(:220)
   ├ LaunchCompatibilityEnvironment.stage(...)（同步、逐文件 copy-if-changed）(:223)
   │   DXMT 五件套 → runtime lib/wine/x86_64-windows；原始 D3D 副本 → Prefix system32；
   │   winemetal.dll → system32；nvapi64/nvngx → system32(缺失才复制)；
   │   protonextras 四件套 → system32/syswow64(steam.exe/lsteamclient.dll)；
   │   <gameDir>/Plugins/vulkan-1.dll 移开为 .bak（记录待恢复）；
   │   HoYoKProtect.sys → system32
   ├ GameLaunchPreparation.fixWebview（非原神：`wine reg query/delete` 清 WebView 渲染值）(:238)
   ├ [崩铁] prepareStarRailVendorRegistry：3× `wine reg add` (:241)
   ├ launchInvocation(...)：选 Steam 存根（原神/绝区零）或 Jadeite（崩铁）(:277)
   ├ argv = [program] + arguments + 性能选项参数（当前为空）
   ├ env = WINEPREFIX + WINEDLLOVERRIDES=winemenubuilder.exe=d + MIPLAY_WAIT_WINESERVER
   │        + per-game(WINEESYNC/WINEMSYNC/TIMEOUT_FIX/GST_RANK[/DXMT_CONFIG])
   │        + 性能选项 env（空） + MTL_HUD_ENABLED(可选) + DXMT_ENABLE_NVEXT(0/1)
   │        +[LaunchServices 路径] MIPLAY_LAUNCH_LOG/STATUS/CWD
   │        → ProcessManager.childEnvironment：剔除继承 MTL_*/METAL_*，再合并以上覆盖 (:283-356)
   ├ prepareAppBundle：写 LaunchApps/<Game>.app（GameLauncher 拷贝 + Info.plist + icns）(:344)
   └ ApplicationLauncher.launch → NSWorkspace.openApplication(:358 → ApplicationLauncher.swift:47)
        argv = [wineBinary] + argv（同上前提）→ launchd 启动 .app
        GameLauncher.c：setpgid → chdir(MIPLAY_LAUNCH_CWD) → execv(wine, …)
          → wine "C:\windows\system32\steam.exe" "Z:\…\<game>.exe"
          → steam 存根 → 游戏进程
        GameLauncher 父进程 waitpid(wine) → [MIPLAY_WAIT_WINESERVER] wineserver -w → 写 launch.status
→ LaunchOrchestrator：recordLaunchConfirmed(AppData 写#5) (:467)
→ monitorProcess：500ms 轮询 kill(pid,0)；退出后读 launch.log/launch.status (:699)
→ 退出清理：restoreStagedGameFiles（仅恢复被移开的 vulkan-1.dll）→ commitProcessExit(AppData 写#6)
   → 释放安全作用域 → releaseSharedPrefixLease（`wineserver -k`，等待 ≤10s） (:722/733/735/610)
```

关键事实：`steam.exe` 存根为**强制路径**（`usesSteamCompatibilityStub = true`，`LaunchCompatibilityEnvironment.swift:456`）；直启分支保留但被 `missingRequiredLaunchAssets` 拦住（`:470`）。

### 2.2 YAAGL（`References/YAAGL` @ `784dda3`）

```
点击启动 (src/launcher/index.tsx:258) → taskQueue.next(() => launch(config)) (:117/:123)
→ ChannelClient.launch (hk4e/index.tsx:256, nap/index.tsx:319, hkrpg/index.tsx:302)
   ├ checkAndDownload{DXMT,Jadeite,Reshade}（版本固定，按需下载）
   ├ launchGameProgram({...}) (hk4e/program-launch-game.ts)
   ├ wine.setProps(config)：生成 winedrv_config.bat（写 RetinaMode / LeftCommandIsCtrl）
   │    → wine exec "cmd /c bat" → waitUntilServerOff() (wine.ts:119-137)
   ├ [可选] HDR / 自定义分辨率注册表写入（原神）
   ├ await wine.waitUntilServerOff()（清空 Prefix 内 wineserver）
   ├ [绝区零/崩铁] fixWebview：删除 WebView 渲染值注册表项
   ├ [崩铁] wine.setNVExtension()（3× reg add，NVAPI/NGX 标识）
   ├ 生成并写出 config.bat（cd /d 游戏目录；copy HoYoKProtect.sys；启动游戏）
   ├ patchProgram：DXMT 三件套 `.bak` 换入 wine/lib/…、winemetal 两处复制、
   │    protonextras 四件套 → system32/syswow64、[可选] ReShade → 游戏目录 (patch.ts:29-127)
   ├ [可选] blockNet AppleScript（管理员授权 hosts 屏蔽，原神/崩铁）
   └ wine.exec2(program, args, env, logfile) (wine.ts:47-64)
        默认：wine cmd /c "Z:\…\config.bat"
        steamPatch：wine C:\windows\system32\steam.exe Z:\…\<game>.exe
      → unixExec2 → build(segments, env)（KEY=value 前缀 + 转义）→ Neutralino.os.spawnProcess(整条 shell 字符串)
        stdout/stderr 由 shell `&>` 重定向到 logs/game_<ts>.log
   → wine.waitUntilServerOff()：wineserver -w（整个游玩期间保持"忙碌"）(wine.ts:66)
   → removeFile(config.bat) → patchRevertProgram（恢复 3 个 D3D DLL 的 .bak、删除 ReShade）
   → 注册表回滚（HDR/分辨率）；WebView 值不回滚
```

关键事实：YAAGL 的 `WINEDLLOVERRIDES: ""` 不会到达命令行（假值被丢弃）；`fpsUnlock` 配置项在启动链路中**无任何读取点**（死代码）。

---

## 3. 源码级差异矩阵

| 环节 | MiPlay | YAAGL | 可能影响 | 证据 | 验证方法 |
| --- | --- | --- | --- | --- | --- |
| 帧节奏（原神） | 不设 `DXMT_CONFIG` | `d3d11.preferredMaxFrameRate=60;` | **帧时间平台/抖动**；不设=不额外限速，设 60=显式 1/60 节奏目标 | A：`LaunchCompatibilityEnvironment.swift:488-494`；`hk4e/program-launch-game.ts:179`；DXMT `654f547:src/d3d11/d3d11_swapchain.cpp:169,762` | 单变量注入 60 后对比帧时间 |
| DXMT 二进制 | `654f547+miplay-fb45156`（含成员初始化顺序修复） | stock `654f547` | 启动崩溃概率（方向利于 MiPlay）；不预期影响 FPS | A/B：`RuntimeAssets/dxmt/VERSION`、`Tools/DXMT/patches/fb45156-device-initialization.patch`、`downloadable-resource.ts:141`；工作区=HEAD=已安装（SHA 一致） | 运行中 dump 模块哈希；崩溃复现对照 |
| 进程创建 | LaunchServices→`.app`→GameLauncher(fork/exec, setpgid, chdir, 状态文件, `wineserver -w`) | shell 字符串 spawn（无进程组/cwd，`&>` 重定向） | 退出判定与清理时序；信号传递；环境泄漏面 | A：`ApplicationLauncher.swift:47`、`GameLauncher.c:31-106`；`neu.ts:39-50` | 采集进程树/pgid/退出码 |
| 环境过滤 | 剔除继承 `MTL_*`/`METAL_*`，再合并覆盖 | 无过滤；`WINEDLLOVERRIDES=""` 被丢弃 | Xcode 下 `DYLD_*` 泄漏（已实测）；用户全局 override 仍生效 | B/A：`ProcessManager.swift:164-187`；`command-builder.ts:41-43`；`zzz-isolated-…-2026-10-10.md`（实测 Wine 进程含 Xcode `DYLD_LIBRARY_PATH`/`DYLD_FRAMEWORK_PATH`） | Finder vs Xcode 启动对照 |
| 同步机制 | `WINEESYNC`/`WINEMSYNC` 显式一开一关（原神 esync，绝区零/崩铁 msync） | 同上，但**不关闭**另一个 | 若继承环境含相反开关，行为不确定 | A：`LaunchCompatibilityEnvironment.swift:488-503`；`hk4e:177`、`nap:114` | 采集游戏进程最终环境 |
| WINEDEBUG | 不设置（沿用 Wine 默认） | `fixme-all,err-unwind,+timestamp` | 日志量/时间戳开销；**方向与旧结论相反** | A：`wine.ts:78` vs MiPlay 无该键 | 对比同一场景日志增长速率 |
| Prefix 粒度 | 三游戏共享 `WinePrefixes/shared`，单 wineserver | 每实例独立 Prefix（`app.tsx:105`），各自 wineserver | 状态干扰、连带 kill、缓存混用 | A/B：`WineRuntimeProvider.swift:306`；`app.tsx:105` | 单游戏会话后检查另一游戏 Prefix 状态 |
| 会话结束 | `wineserver -k`（+ `MIPLAY_WAIT_WINESERVER` 先 `-w`） | 仅 `wineserver -w`，从不 kill | 快速重启可触发 `msync_init Failed bootstrap_look_up`；冷启动更慢 | A/D：`WineRuntimeProvider.swift:288-297`；`wine.ts:66-70` | 退出→立即重启 N 次，统计启动失败 |
| DLL staging | copy-if-changed（size+mtime），DXMT 常驻 runtime，`.bak` 只留一次，**永不回滚** | 每次启动 `.bak` 换入 3 个 D3D DLL，退出回滚；winemetal/nvngx 不回滚 | 离线目录差异会误导比较；MiPlay 少一次换文件开销 | A/B：`LaunchCompatibilityEnvironment.swift:175-220,537-561`；`patch.ts:70-96,162-167` | 运行中比对加载路径 |
| 退出判定 | 包装进程退出 + 状态文件；`wineserver -w` 兜住 Steam/Jadeite 早退 | `exec2` promise = 包装器退出码 0，随后 `wineserver -w` | 会话时长判定；异常退出是否被发现 | A：`GameLauncher.c:71-106`；`neu.ts:57-67`、hk4e:195 | 记录包装器与游戏进程各自的退出时间 |
| 启动期 I/O | 6 次 AppData 全量读改写 + 逐文件 copy + 多进程 reg query/add | 文件写 + 若干 wine 辅助进程（cmd/regedit/regsvr32/wineserver） | 只影响启动耗时，不影响游戏内 FPS | A：`PersistenceStore.swift:159-196`、`TaskSchedulerScheduling.swift:43-61` | 启动耗时分解 |

---

## 4. 原神性能分析

### 4.1 已确认的事实

- Wine 主体一致：`bin/wine`、`bin/wineserver`、ntdll（PE/Unix）哈希一致，`wine --version` 均为 `wine-11.0`（B，见既有调查）。
- 启动入口一致：两侧都是 `wine C:\windows\system32\steam.exe Z:\…\YuanShen.exe`（A）。
- 同步与兼容开关一致：esync、`WINE_ENABLE_TIMEOUT_FIX=1`、`GST_PLUGIN_FEATURE_RANK`（A）。
- **帧节奏配置不一致**（A，唯一实质差异）：
  - YAAGL：`DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;`（`hk4e/program-launch-game.ts:179`）
  - MiPlay：原神分支不含 `DXMT_CONFIG`，且 `DXMT_ENABLE_NVEXT=0`（`LaunchCompatibilityEnvironment.swift:488-494`、`AppData.swift:360`）
- 该参数的源码语义（`654f547:src/d3d11/d3d11_swapchain.cpp`）：
  ```
  :169  preferred_max_frame_rate = Config::getOption<int>("d3d11.preferredMaxFrameRate", 0);
  :762  double vsync_duration = std::max(
             SyncInterval * 1.0 / (preferred ? preferred : init_refresh_rate_),
             preferred ? 1.0 / preferred : 0);
  ```
  - `preferred = 0`（MiPlay）⇒ `vsync_duration = 0`：**DXMT 不施加节拍等待**，呈现节奏交给 `CAMetalLayer.nextDrawable()` 的可用性（`dxmt_presenter.cpp:159`；两侧代码都**未显式设置** `displaySyncEnabled`/`maximumDrawableCount`）。
  - `preferred = 60`（YAAGL）⇒ `vsync_duration = max(SyncInterval/60, 1/60)`：**即使游戏关闭垂直同步，也按 1/60 的节拍目标呈现**。
- 因此：**YAAGL 的配置只会"限制上限"，不可能把 YAAGL 变得更快**；它能解释的只有"MiPlay 在没有显式节拍时更容易掉到 33.3ms 平台（30 FPS）"这一条路径（C）。

### 4.2 候选原因排序（按证据强度）

| # | 候选 | 机制 | 支持证据 | 反证/未排除 | 级别 |
| --- | --- | --- | --- | --- | --- |
| 1 | 无显式帧节奏 ⇒ 呈现落在 display-sync 上，命中即 33.3ms 平台 | 未限速时 present 由 `nextDrawable` 可用性驱动；一次错过 vblank 即翻倍；限 60 时呈现器有明确 1/60 目标 | 源码公式（A）；YAAGL 实际配置（B） | 公式只会"封顶"，给定限速后必须快于未限速的假设，需要帧时间证据；未排除游戏自身 VSync 设置差异 | C |
| 2 | 游戏内图形设置不可比 | `GENERAL_DATA` 的 `graphicsData` 第 8 项 MiPlay=3 / YAAGL=2，`globalPerfData` 项与版本历史不同（B） | 既有调查的 Prefix 对比 | 字段含义未映射，不能断言是 VSync/FPS/渲染精度 | C |
| 3 | Xcode 启动时的环境泄漏 | 实测 Wine 进程带 Xcode `DYLD_LIBRARY_PATH`/`DYLD_FRAMEWORK_PATH`；MiPlay 只过滤 `MTL_*`/`METAL_*` | B（隔离实验采集）+ A（过滤代码） | 未证明这些路径实际改变了库解析结果；Finder 启动即无此变量 | C |
| 4 | esync/msync 是否真正启用未知 | 变量存在不等于机制生效 | 两侧都设置（A） | 日志无 esync/msync 初始化证据；无法据此判定 CPU 同步开销 | E（用于排除，不足以定性） |
| 5 | CPU 计算热点/锁竞争 | 0.6x–1.5x 分数不响应渲染精度与此相容 | 无热点栈数据 | 无逐线程采样；不能因总 CPU 不满而排除 | C（需采样） |
| 6 | GPU 回压/合成开销 | 窗口模式、分辨率、Retina、状态栏合成 | 两侧 Retina=y、分辨率字段相同（B） | 无 GPU frame time | C（需测量） |
| 7 | Prefix/着色器/Metal 缓存冷热 | 首次进入场景抖动 | 缓存路径存在，未定位实际使用的 DXMT/Metal 缓存 | 稳定 30 FPS 难以仅用冷缓存解释 | C（低） |
| 8 | 日志开销 | MiPlay 不设 WINEDEBUG，YAAGL 设 `fixme-all,+timestamp` | A（方向与旧文档相反） | 旧文档"MiPlay fixme 更多"的结论不成立（同一文档引用的 YAAGL 命令行本身含 fixme-all） | E |
| 9 | SwiftUI/视频/App Nap 抢资源 | 视频在应用非 active 时暂停 | `BackgroundScene.swift:159` | 无证据；游戏窗口为前台时 MiPlay 主窗口不再合成可见内容（仍然存在，未测量） | E（不成立为定性原因） |

### 4.3 结论

- 相同 Wine/DXMT 文件**不成立**：DXMT 二进制已不同（MiPlay 带补丁），但补丁只重排成员，**不构成 FPS 差异机制**。
- 唯一有源码机制的候选是**帧节奏配置**；它**不能**解释"YAAGL 更快"，只能解释"MiPlay 更容易掉帧/掉档"。要判定必须拿到帧时间分布与 GPU 时间。

---

## 5. 绝区零稳定性分析

### 5.1 已确认

- 两侧日志都出现 `-[<非设备对象> newComputePipelineStateWithDescriptor:options:reflection:error:]`（unrecognized selector）：MiPlay `LaunchApps/ZenlessZoneZero.app/…/launch.log:491`（`__NSCFNumber`）；YAAGL `logs/game_1791556204980.log:380`（`NSTaggedPointerString`）、`game_1791556420867.log:384`（`__NSTaggedDate`）（B）。
  接收者是**随机的非设备对象**，符合"把未初始化内存当成 `WMT::Device` 使用"。
- MiPlay 已针对该模式打补丁（A）：`ArgumentEncodingContext` 中 `WMT::Device device_` 原先声明在使用它的命令成员**之后**，构造顺序导致 `ClearUAV` 等通过 `getComputePipeline` 读到未初始化 `device_`。补丁把 `device_` 前移（`Tools/DXMT/patches/fb45156-device-initialization.patch`）。
- YAAGL 使用 stock `654f547`（无该修复），**同一异常在 YAAGL 侧同样出现**（B）。
- MiPlay 隔离矩阵（`Docs/01-research/zzz-isolated-dll-launch-diagnostics-2026-10-10.md`）：三组单次对照中，直接 GameLauncher 组复现同一异常，两组 LaunchServices 组 40/140 秒包装进程存活（D，但**单次、且"存活"不等于在渲染**）。
- LLDB 附加失败（Rosetta debugserver 阻塞），**至今没有符号化调用栈**（B）。因此不能宣称已定位崩溃根因。

### 5.2 值得进一步验证的差异

1. **残留的未初始化/竞态路径**：补丁修了一处（B），但隔离实验中**打过补丁的 MiPlay 仍复现一次**（D）⇒ 同族缺陷可能不止一处。优先用符号化栈或 Metal API validation（`MTL_DEBUG_LAYER`，注意 MiPlay 会剔除继承值，需显式注入）定位。
2. **共享 Prefix 的连带影响**：三游戏共用一个 wineserver；任一会话结束的 `wineserver -k` 会影响其它游戏残留状态（A）。
3. **`wineserver -k` 后快速重启**：观察过 `err:sync:msync_init Failed bootstrap_look_up` 导致当次启动失败、重试即成功（D，来自测试脚本时序）⇒ 与 kill 后立即启动相关。
4. **启动通道（LaunchServices vs 直接入口）**：单次差异不足以定论（D），需固定次数的重复对照（且必须满足既有的"游戏窗口画面"验收标准，而非进程存活）。
5. **Xcode `DYLD_*` 泄漏**：已在 Wine 进程实测（B）⇒ 任何在 Xcode 下做的稳定性对照都混入该变量。
6. **游戏侧 Vulkan/DXVK 载入器文件共享**：两侧使用同一游戏目录，`vulkan-1.dll` 的移开/恢复是共享文件状态（A）⇒ 并发或异常退出时可能互相影响（当前不并发，风险低）。

### 5.3 不应做的事

不盲目替换 DLL、清缓存、重建 Prefix（违反"单变量 + 假设驱动"）；在拿到调用栈或稳定复现之前，不宣称任何根因。

---

## 6. 优先级排序

**P0（最可能解释现象，先验证）**

1. 原神：帧节奏配置差异（MiPlay 无 `DXMT_CONFIG`）——单变量、可逆、10 分钟可判定（C→D）。
2. 绝区零：DXMT 补丁充分性——用符号化栈或 validation 确认残留路径（C）。
3. 消除测量混淆：游戏内图形设置对齐（含 VSync/FPS/渲染精度）+ MiPlay 从 Finder（非 Xcode）启动（C）。

**P1（机制合理、证据不足）**

4. Xcode `DYLD_*` 进入 Wine 进程的实际影响（B→C）。
5. CPU/同步：esync/msync 是否真正启用 + 线程栈采样（C）。
6. `wineserver -k` 与快速重启的启动失败率（D 的单点证据）。
7. 共享 Prefix 的跨游戏状态干扰（A，影响概率受"单线测试"限制）。

**P2（长期可靠性/低影响）**

8. 资产可追溯性：DXMT/winemetal 版本与哈希清单 + staging 校验（当前只看 size+mtime）。
9. 启动耗时：6 次 AppData 全量写、LogWriter 每事件正则编译 + 全文件重写、`wine reg query` 系列子进程。
10. YAAGL 侧遗留问题（非 MiPlay 责任，但影响对照解释）：`fpsUnlock` 死配置、`WINEDLLOVERRIDES=""` 无效、退出时不回滚 WebView 注册表。

---

## 7. 最小验证计划（≤5 项，均需你授权后执行）

> 共同前提：一次只改一个变量；同一场景同一镜头；保留现有缓存；记录显示器刷新率与电源状态；每项都给出回退方式。**本文档未执行任何一项。**

**E1｜原神帧节奏单变量（最高优先级）**
- 假设：MiPlay 原神因缺少 `DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;` 而在 present 上掉落 33.3ms 平台。
- 步骤：以现有方式启动 MiPlay 原神（先从 Finder 启动，避免 Xcode 变量）→ 记录基线（Metal HUD 帧时间图 + 平均 FPS，60 秒）→ 退出 → 仅在启动环境注入 `DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;`（不改代码：可用 MiPlay 的暂缓性能选项机制或一次性启动脚本）→ 同场景 60 秒。
- 采集：平均 FPS、帧时间直方图（是否有 16.7/33.3ms 平台）、GPU 时间（HUD）、游戏内 VSync/FPS 设置截图。
- 判读：帧时间由 33.3ms 平台变为 16.7ms ⇒ 支持假设；两者都稳定 16.7ms ⇒ 该差异与你的观察无关，转向 E3；两者都 33.3ms ⇒ 检查游戏内 VSync/限帧设置与显示模式。
- 风险/回退：只影响环境变量，删除即回退；不写 Prefix、不动游戏文件。

**E2｜启动通道对照（Finder vs Xcode）**
- 假设：Xcode 注入的 `DYLD_*`（及调试附加）影响 Wine/DXMT 解析或调度。
- 步骤：同一台机器、同一场景，先用 Xcode 运行 MiPlay 启动原神并记录；退出后从 Finder 启动同一个已构建的 MiPlay.app 再记录。
- 采集：两个 Wine 进程的 `ps -E` 白名单环境、加载的 DXMT/winemetal 路径与哈希、FPS/帧时间。
- 判读：环境不同且 FPS 有差 ⇒ 需要在 MiPlay 侧收紧环境过滤（见 §8）；环境不同但 FPS 无差 ⇒ 排除该混淆。
- 风险/回退：只读采集 + 正常启动，无副作用。

**E3｜实际加载模块与同步机制确认（只读，游戏运行中）**
- 假设：实际加载的 DXMT/winemetal 与我们以为的一致；esync/msync 确实生效。
- 步骤：在两个启动器各自游戏窗口出现后（授权后），对游戏进程做 `vmmap`/`lsof` + 关键变量读取（不导出凭据）。
- 采集：`d3d11.dll`/`winemetal.dll`/`winemetal.so` 的实际文件路径与 SHA-256、`WINEESYNC`/`WINEMSYNC`/`DXMT_CONFIG` 实际值、DXMT 构建标识（HUD 或日志）。
- 判读：模块路径/哈希不一致 ⇒ 先统一资产再谈性能；一致且设置一致 ⇒ 差异不在资产层。
- 风险/回退：只读；不附加调试器（避免重现 LLDB 阻塞）。

**E4｜绝区零 DXMT 崩溃复现与栈采集**
- 假设：崩溃源自 DXMT/winemetal 中另一处未初始化对象/竞态；补丁不充分。
- 步骤：只在一个隔离环境（此前 `QAArtifacts/ZZZ-Isolated-Matrix-20261010` 的模式）内，启用 Metal API validation（显式注入 `MTL_DEBUG_LAYER=1`，注意 MiPlay 会剔除继承值）→ 连续 5 次启动，每次观察 40/140 秒**游戏窗口画面**（不以进程存活为准）。
- 采集：带模块身份（`dyld` 镜像列表）的崩溃报告/异常线程；DXMT 日志；如仍无栈，记录 validation 断言的编码器/纹理格式。
- 判读：拿到断言点或栈 ⇒ 转 DXMT 工程定位；仍无栈 ⇒ 改用 `WINEDEBUG=+seh` 或 Wine 崩溃转储路径；两种都失败时，结论应为"证据不足"，不做无假设的 DLL 更换。
- 风险/回退：仅隔离环境，不动现有 Prefix/运行时；失败即删除隔离目录。

**E5｜会话结束与快速重启稳定性**
- 假设：`wineserver -k` 后立即重启会提高启动失败率（`msync_init` bootstrap 竞态）。
- 步骤：一次一个游戏，启动→正常退出→间隔 0s/5s/30s 各重复 5 次，仅记录启动结果与日志中的 `msync_init`/`bootstrap_look_up`。
- 采集：失败次数、失败时的时间间隔、日志片段。
- 判读：间隔越短失败率越高 ⇒ 为 MiPlay 的 release 路径加"等待 wineserver 退出/延迟释放"依据（§8）。
- 风险/回退：只影响测试会话；不改代码。

---

## 8. 代码优化建议（均未实施）

| # | 建议 | 位置 | 预期收益 | 副作用 | 是否需先做实验 | 影响其它游戏 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 原神对齐显式帧节奏上限（或做成"帧率上限"用户项） | `LaunchCompatibilityEnvironment.additionalEnvironment`（原神分支） | 若 E1 成立，消除 33.3ms 平台 | 会把原神封顶 60（与 YAAGL 现状一致）；高分屏用户可能希望更高 | **是（E1）** | 仅原神 |
| 2 | 环境过滤扩展为白名单/剔除 `DYLD_*`（至少剔除 Xcode 注入） | `ProcessManager.developmentOnlyMetalVariables` → 改名并覆盖 `DYLD_*` | 消除 Xcode 会话的污染面；行为在 Finder/Xcode 下一致 | 可能影响未来依赖 `DYLD_*` 的调试用注入；需保留显式覆盖能力 | 是（E2） | 三款游戏 |
| 3 | 资产可追溯性：DXMT 五件套哈希清单 + staging 校验（替代 size+mtime） | `LaunchCompatibilityEnvironment.stage` / `resolveAssetSourceRoot` | 避免"部署了哪个构建"再次失焦 | 新增校验 I/O（一次性）；哈希清单需随资产更新 | 否 | 三款游戏 |
| 4 | 会话结束顺序：`wineserver -k` 前确认 `-w` 已完成，或改为延迟/复用服务器 | `WineRuntimeProvider.shutdownSharedPrefix` + `LaunchOrchestrator.releaseSharedPrefixLease` | 降低快速重启的启动失败率 | 复用服务器会改变"隔离"假定；需确认不会残留用户态状态 | 是（E5） | 三款游戏 |
| 5 | 启动耗时削减：AppData 写合并、LogWriter 正则预编译 | `TaskSchedulerScheduling` / `LogWriter.sanitize` | 缩短点击到进程创建的耗时（不影响游戏内 FPS） | 日志格式/顺序变化需同步测试 | 否（可先测耗时） | 全局 |
| 6 | 诊断留存：每次启动独立日志 + 固化最终环境白名单与模块身份 | `ApplicationLauncher.prepareSessionFiles` / `LaunchOrchestrator` 日志 | 让后续故障有可比对证据（当前 launch.log 每次被清空） | 磁盘占用增加；需脱敏 | 否 | 三款游戏 |
| 7 | ZZZ 崩溃定位：在 DXMT 侧为 `WMT::Device` 引用加断言/校验（隔离环境先行） | DXMT 独立工程（`References/dxmt`） | 把"随机对象"变成可定位断言 | 属独立工程改动，不进 MiPlay 主链 | 是（E4） | 仅诊断用 |

---

## 9. 证据入口（复核用）

代码（工作区当前版本）：
- `MiPlay/Domain/Launch/LaunchOrchestrator.swift:115,149,178,202-229,277-313,344-364,467,486,699,722,735`
- `MiPlay/Domain/Launch/LaunchCompatibilityEnvironment.swift:93-135,142-325,327-335,429-449,456-473,482-510,537-561`
- `MiPlay/Domain/Launch/GameLaunchPreparation.swift:23-53,86-88`
- `MiPlay/Infrastructure/Process/ProcessManager.swift:148-190`；`MiPlay/Infrastructure/Launch/ApplicationLauncher.swift:39-133`
- `Tools/GameLauncher/GameLauncher.c:31-106`；`Tools/DXMT/patches/fb45156-device-initialization.patch`
- `RuntimeAssets/dxmt/VERSION`（`654f547+miplay-fb45156`）
- `References/YAAGL/src/wine/wine.ts:47-81,119-154`；`hk4e/program-launch-game.ts:106-208`；`nap/program-launch-game.ts:34-141`；`hkrpg/program-launch-game.ts:38-124`；`src/clients/mhy/patch.ts:29-173`；`src/utils/command-builder.ts:34-59`；`src/app.tsx:105`
- DXMT（`References/dxmt`，只读 `git show 654f547:…`）：`src/d3d11/d3d11_swapchain.cpp:169,762`；`src/dxmt/dxmt_presenter.cpp:159`；`src/dxmt/dxmt_context.hpp:829-840`；`src/dxmt/dxmt_command_clear.hpp:30`；`src/dxmt/dxmt_context.cpp:1596`

运行时（只读）：
- `~/Library/Application Support/MiPlay/{AppData.json, Logs/, WinePrefixes/shared/, WineVersions/, LaunchApps/}`
- `~/Library/Application Support/Yaagl*/{neutralinojs.log, wineprefix/, logs/, dxmt/}`

既有调查（复用，未重复）：`Docs/01-research/investigation-miplay-yaagl-2026-10-10.md`、`zzz-isolated-dll-launch-diagnostics-2026-10-10.md`、`Docs/05-implementation/yaagl-launch-profiles-2026-10-10.md`、`Docs/GameNews.md`（新闻无关性能，仅确认范围外）。

**相对既有调查的变化（必须记录）**：① DXMT 资产已由后续提交统一为 `654f547+miplay-fb45156`，工作区=HEAD=已安装，历史文档"未恢复到预期 v0.80"的结论**已过期**；② 该构建带 MiPlay 专属补丁，因此"两侧 DXMT 文件完全相同"不再成立；③ MiPlay 已在代码中补齐 `WINE_ENABLE_TIMEOUT_FIX` 与 esync/msync 互斥开关（历史文档记录的是补齐前的状态）；④ 历史文档"YAAGL 关闭 fixme"与它自己引用的 YAAGL 命令行矛盾，实际是 YAAGL **开启** fixme、MiPlay 不设置。

## 10. 本次审计的边界

未运行游戏、未修改代码/资产/Prefix/缓存、未附加调试器、未执行任何实验。第 4 节的因果判定、第 5 节的崩溃根因、第 6 节的优先级均标注了证据级别；其中"C 级"结论**不能**当作已证实原因使用。
