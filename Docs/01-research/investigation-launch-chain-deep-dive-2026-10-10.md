# MiPlay 第二阶段专项审计：DXMT 帧同步、设备生命周期与 Wine 进程管理

审计日期：2026-10-10（Asia/Shanghai）
前置：`Docs/01-research/investigation-launch-chain-perf-audit-2026-10-10.md`（第一阶段）
方法：**只读**静态分析与既有资料复核（源码、Git 历史、注册表/日志、公开文档）。未启动游戏、未修改 Wine/DXMT/Prefix/缓存/游戏配置、未执行第一阶段 E1–E5。所有引用均为本地文件或 `git show <commit>:<path>` 的只读读取。
DXMT 基线：`654f547`（stock，YAAGL 用）与 `654f547+miplay-fb45156`（MiPlay 用，含成员初始化顺序补丁）。

证据级别：A=源码可证明；B=磁盘/配置/日志可证明；C=有机制解释但未实测；D=本机实验支持；E=已被削弱/排除。

---

## 1. 核心结论

1. **DXMT 帧同步假设需要修正（E 级：方向不成立）。** 源码（`654f547:src/d3d11/d3d11_swapchain.cpp:762`）表明 `preferredMaxFrameRate` 只用于计算传给 `presentDrawableAfterMinimumDuration` 的**最小呈现间隔**：
   ```
   after = max(SyncInterval/(preferred ? preferred : refresh), preferred ? 1/preferred : 0)
   ```
   `preferred=0`（MiPlay）在 `SyncInterval=0` 时 `after=0` → 完全不限速；`SyncInterval=1` 时 `after=1/刷新率`；`SyncInterval≥2` 时按 `SyncInterval/刷新率` 间隔。`preferred=60`（YAAGL）恒为 `≥1/60`。**在所有组合下，`preferred=60` 的帧率上限都不高于 `preferred=0`** ⇒ 无法用"没有设置 60 上限"解释 MiPlay 反而更慢。它可以解释的只有：MiPlay 在 `SyncInterval=0` 时**不做节拍**（帧间隔更不均匀、可能撕裂），而不是 FPS 更低。
   另有一条此前未发现的关键事实：**DXMT 把 `CAMetalLayer.displaySyncEnabled` 显式设为 `false`**（`654f547:src/dxmt/dxmt_presenter.cpp:19`，经 `winemetal_unix.c:1633` 落到图层）⇒ 呈现**不受显示器垂直同步约束**，节拍完全由 `after` + drawable 池 + 帧延迟栅栏决定。

2. **原神图形配置差异已确认（B 级，且比第一阶段更严重）。** 两侧 `GENERAL_DATA_h2389025596`（UTF-8 JSON）末条记录解析成功：游戏版本同为 `CNRELWin7.1.0`；但 **保存的分辨率相差正好 2×（MiPlay 3456×2234 vs YAAGL 1728×1117，即 4× 像素）**，且 `graphicsData.customVolatileGrades` 18 项中有 3 项不同（含 `RenderResolution`、`MotionBlur`），而 `FPS` 与 `VSync` 两项两侧相同。第一阶段提到的"graphicsData[8] = 3 vs 2"在当前数据中**无法复现**（key 8 两侧同为 2），该条应视为过期或误读。
   ⇒ **在这些设置对齐之前，不能把 FPS 差异归因于启动器。**

3. **DXMT 补丁存在明确的、可证明的目标缺陷，但"是否充分"仍未证实。**
   - 已证明：stock `654f547` 中 `ArgumentEncodingContext` 的 `ClearUAV` 等命令助手在**构造函数**里调用 `getComputePipeline`，而 `getComputePipeline` 使用 `ctx.device_`（`dxmt_context.cpp:1596-1606`），`device_` 当时尚未构造（声明在使用它的成员之后）⇒ 读取未初始化内存，`WMT::Device` 句柄为垃圾值，最终把 `newComputePipelineStateWithDescriptor:options:reflection:error:` 发给非设备对象——**与两侧日志中观察到的异常签名完全一致**（`src/winemetal/unix/winemetal_unix.c:391` 是唯一发送该 selector 的调用点）。这是**已确认的 C++ 生命周期缺陷**。
   - 补丁把 `device_` 前移到所有使用者之前，且校验了这些构造函数只用到 `device_` 与 `lib`（两者都已在前面）⇒ **该路径已被覆盖**。
   - 但**补丁不充分的判断没有新证据**：现有"打过补丁仍复现"只有单次、且未取得调用栈；同时"随机对象接收 selector"也能由**句柄被子销毁后复用**（对象生命周期问题）导致，这条路径本轮**未被排除**。

4. **wineserver 生命周期存在一个可证明（A 级）的会话内死锁入口，但不是崩溃根因。**
   `monitorProcess` 在 `releaseSharedPrefixLease()` 抛错时进入 catch：写入恢复记录后**保留** `currentLaunchProcessID` 守卫；而手动恢复入口 `retryProcessExitRecovery` 的第一行就是 `guard currentLaunchProcessID == nil` ⇒ **当次会话内恢复被自己的守卫拒绝**，只能靠重启应用自愈（重启后自动恢复可以成功）。这是正确性/可用性缺陷，与 ZZZ 崩溃无关。

---

## 2. 已确认的问题（附文件、函数、行号、原因、影响范围）

### 2.1 stock DXMT：`ArgumentEncodingContext` 成员初始化顺序缺陷（A 级）

| 项 | 内容 |
| --- | --- |
| 文件 | `References/dxmt` @ `654f547`：`src/dxmt/dxmt_context.hpp:829-840, 918-928`；`src/dxmt/dxmt_context.cpp:30-50, 1596-1606`；`src/dxmt/dxmt_command_clear.hpp:30-39`；`src/winemetal/unix/winemetal_unix.c:391` |
| 函数 | `ArgumentEncodingContext::ArgumentEncodingContext`、`SimpleCommandContext<ArgumentEncodingContext>::getComputePipeline`、`ClearUAV<ArgumentEncodingContext>::ClearUAV` |
| 原因 | C++ 按**声明顺序**初始化成员；`device_` 声明在 `clear_uav_cmd` 等之后，但后者的构造函数通过 `getComputePipeline` 读取 `device_`（`ctx.device_.newComputePipelineState(func, err)`）。构造函数初始化列表顺序与原声明顺序一致，因此 `-Wreorder` 不会告警——这是"语义依赖未表达"的缺陷，不是列表顺序笔误。 |
| 触发前提 | 只要该 `ClearUAV`（或同类助手）在初始化阶段创建计算管线即触发；是否真的读到非法句柄取决于未初始化内存/句柄表内容，因此**间歇性**。 |
| 影响范围 | 任何使用 stock `654f547` 的 Wine + DXMT 组合（含 YAAGL）；症状为游戏启动即崩，异常对象类型随机（`__NSCFNumber`/`NSTaggedPointerString`/`__NSTaggedDate` 均已观察到）。 |
| 现有日志支持 | 两侧日志的 selector 与接收对象类型一致；调用链闭合。 |
| 其它解释 | 句柄复用（对象先析构、句柄被回收后再被使用）也能产生同样签名；本轮未排除。 |

### 2.2 MiPlay：租约释放失败导致的会话内恢复死锁（A 级）

| 项 | 内容 |
| --- | --- |
| 文件 | `MiPlay/Domain/Launch/LaunchOrchestrator.swift:699-781`（`monitorProcess`）、`:735`（`releaseSharedPrefixLease()`）、`:793-806`（`retryProcessExitRecovery`）、`:610-628`（释放实现）；`MiPlay/Infrastructure/Wine/WineRuntimeProvider.swift:278-304`（`wineserver -k` 实现） |
| 原因 | `releaseSharedPrefixLease()`（内部执行 `wineserver -k` 并等待 ≤10s，退出码非 0/1 或超时即抛错）失败时，控制流进入 catch，**不执行** `currentLaunchProcessID = nil`；而恢复入口要求 `currentLaunchProcessID == nil`。 |
| 触发前提 | `wineserver -k` 超时或返回意外退出码（少见，但网络/磁盘繁忙或残留进程时可能）。 |
| 影响范围 | 该次会话内：启动守卫保持、按钮显示"需要恢复"、手动恢复被拒（错误信息"启动进行中，暂缓执行状态恢复"）；重启应用后自动恢复成功。 |
| 现有日志支持 | 日志会记录 `launch.exit_commit_failed`（`launch.exit` 事件，phase `exitCommit`，result `recoveryRequired`）。 |
| 最小修复思路（未实施） | 进程已确认退出时先清 `currentLaunchProcessID`/`currentGameID`（或把"进程守卫"与"租约守卫"拆成两个状态），再执行租约释放；`retryProcessExitRecovery` 另有独立守卫即可。 |

### 2.3 两侧游戏内设置不等价（B 级）

见 §第 4 节（同一次解析，作为"已确认差异"列出）：分辨率 4× 像素差异、`RenderResolution`/`MotionBlur` 项不同、`FPS`/`VSync` 项相同。

---

## 3. 尚未证实的假设（缺什么证据）

| 假设 | 缺什么 | 备注 |
| --- | --- | --- |
| MiPlay 原神"掉到 33.3ms 平台" | 逐帧时间分布 + `SyncInterval` 实际值 + 显示器刷新率 | §5 的参数矩阵显示：只有 `SyncInterval=2` 才会出现 33.3ms（60Hz），且该情况下两侧**行为相同**，故该假设目前**无机制支持**（E 级）。 |
| 无 `after` 节拍导致"帧间隔抖动/撕裂" | 帧时间直方图（HUD 帧间隔曲线） | 机制成立（`displaySyncEnabled=false` + `after=0`），但影响的是**均匀性**，不是平均值。 |
| Xcode `DYLD_*` 泄漏影响加载/性能 | 同一构建 Finder vs Xcode 对照 | 泄漏本身已实测（B 级）。 |
| esync/msync 是否真正生效 | 运行时证据（Wine 启动横幅/调试通道） | 变量存在≠生效，二者都只设置了变量。 |
| ZZZ 崩溃的残留根因 | 符号化调用栈或 Metal validation 断言点 | 补丁覆盖了已知路径，剩余可能是另一处初始化/句柄生命周期问题。 |
| 共享 Prefix 造成跨游戏状态干扰 | 单游戏会话后另一游戏 Prefix 状态对比 | 受"一次只跑一个游戏"约束，实际影响概率低。 |
| `wineserver -k` 后快速重启触发 `msync_init` 失败 | 固定间隔重复启动的失败率 | 现有证据为单点观察。 |

---

## 4. 原神图形配置差异的解析结果（任务 B）

来源：`HKCU\Software\miHoYo\原神\GENERAL_DATA_h2389025596`（REG_BINARY，UTF-8 JSON，末尾 `\x00`）。两个 Prefix：
- MiPlay：`~/Library/Application Support/MiPlay/WinePrefixes/shared/user.reg:665`
- YAAGL：`~/Library/Application Support/Yaagl/wineprefix/user.reg:800`

解析结果（末条记录，122 个顶层键，两侧键集合完全一致）：

| 项目 | MiPlay | YAAGL | 说明 |
| --- | --- | --- | --- |
| `graphicsData.volatileVersion` / `scriptVersion` | `CNRELWin7.1.0` | `CNRELWin7.1.0` | **同一游戏版本**，字段可比 |
| `graphicsData.currentVolatielGrade` | -1（自定义） | -1（自定义） | 相同 |
| 保存分辨率（`Screenmanager Resolution Width/Height`） | 3456×2234（`0xd80`/`0x8ba`） | 1728×1117（`0x6c0`/`0x45d`） | **正好 2×（4× 像素）** |
| `customVolatileGrades` 差异项 | key 2 = 1、key 11 = 4、key 19 = 3 | key 2 = 3、key 11 = 1、key 19 = 1 | 18 项中仅 3 项不同 |
| `FPS`（key 1） | 2 | 2 | **相同**（帧率档位无差异） |
| `VSync`（key 7） | 2 | 2 | **相同**（垂直同步档位无差异） |
| `gammaValue` | 2.60 | 2.53 | 非性能项 |
| 输入/陀螺仪/震动/音量等 | 不同 | 不同 | 非性能项（两张配置来自不同使用习惯） |

key 编号→选项名（**第三方**映射，来自开源工具 Myp3a/GenshinConfigurator `Enums.cs:37-58` 的 `SettingsType` 枚举：0=OverallQuality, 1=FPS, 2=RenderResolution, 3=ShadowQuality, 4=VisualEffects, 5=SFXQuality, 6=EnvironmentDetail, 7=VSync, 8=Antialiasing, 9=VolumetricFog, 10=Reflections, 11=MotionBlur, 12=Bloom, 13=CrowdDensity, 14=Empty, 15=SubsurfaceScattering, 16=TeammateEffects, 17=AnisotropicFiltering, 21=DynamicCharacterResolution）：

- **key 2 = 渲染精度（RenderResolution）**：MiPlay=1、YAAGL=3（该工具未给出数值→档位换算，因此**不声称**具体是 0.6 还是 1.0）。
- **key 11 = 动态模糊（MotionBlur）**：MiPlay=4、YAAGL=1。
- **key 19 未识别**：该枚举在 18–20 处缺项（工具版本早于游戏 7.1）。按用户要求标记为**未解决**。
- 其余 15 项两侧相同。

结论与限制：
1. 数据来自游戏自身设置存储，属于**游戏内图形设置**（结构：`graphicsData` 字符串内嵌 JSON + 同键下 `Screenmanager Resolution *` REG_DWORD）。
2. 项目内**没有**字段定义；上面的编号映射来自第三方工具源码，属**低可信度外部证据**（该工具读写同一注册表结构，README 亦说明数值与游戏内一致）。
3. **可以确认**：两侧设置不等价（分辨率 4× 像素、渲染精度与动态模糊档位不同），且这不属于启动器行为差异。
4. **不可以确认**：key 19 的含义；`RenderResolution` 数值→比例的确切换算；保存值是否等于"实测那一次运行"的值（保存值是最后一次会话写回的）。
5. 只读后续验证方式（将来需要时）：用该第三方工具的 `--read` 语义复述当前值，或"一次只改一项 → 退出游戏 → 重新 dump 该 blob → 观察哪个 key 变化"（需运行游戏，本轮不做）。

---

## 5. DXMT Present 详细调用链与参数矩阵（任务 A）

### 5.1 完整调用链（`654f547`，行号已核对）

```
游戏: IDXGISwapChain::Present(SyncInterval, Flags)
 └─ SwapChain::Present            d3d11_swapchain.cpp:247
     └─ Present1(...)             :248 起
         ├─ 非 TEST / 非 OCCLUDED 判定、EnterFullscreen/LeaveFullscreen 处理   :745-755
         ├─ 计算 vsync_duration = max(SyncInterval/(preferred?:refresh), preferred?1/preferred:0)   :762
         │    preferred_max_frame_rate ← Config "d3d11.preferredMaxFrameRate"（默认 0）  :169
         │    init_refresh_rate_ ← wsi::getCurrentDisplayMode()（显示器刷新率）          :171-175
         ├─ lock(device mutex) → device_context_->PrepareFlush()                        :756-758
         ├─ chunk->signal_frame_latency_fence_ = cmd_queue.CurrentFrameSeq()            :766
         ├─ presenter->synchronizeLayerProperties()（查询显示设置/必要时重建 PSO）       dxmt_presenter.cpp:104-152
         │    └─ 若需要重建：frame_presented_.wait(frame_requested_)  ←【阻塞点 1：等上一帧呈现完成，罕见】
         │    └─ layer_.setProps(layer_props_)（含 display_sync_enabled=false）        dxmt_presenter.cpp:19,129
         ├─ emitcc{ ctx.present(backbuffer, presenter, vsync_duration, metadata) }      d3d11_swapchain.cpp:795-800
         │    └─ ArgumentEncodingContext::present：仅登记 PresentData{after=vsync_duration}  dxmt_context.cpp:533-546
         ├─ ReleaseSemaphore(present_semaphore_, 1)                                     :790/:800
         ├─ lock.unlock() → cmd_queue.PresentBoundary()                                 :819-821
         │    └─ if (frame_count > max_latency_) frame_latency_fence_.wait(frame_count - max_latency_)
         │         ←【阻塞点 2：等 (N-3) 帧 GPU 完成】max_latency_ 默认 3（dxmt_command_queue.hpp:173,261-273）
         └─ UpdateStatistics(...)（HUD，无额外限速）                                    :809 起

命令队列线程（稍后执行该 chunk）：
 └─ PresentData::exec → presenter->encodeCommands(...)                                  dxmt_context.cpp:1095-1105
     ├─ Presenter::encodeCommands → layer_.nextDrawable()   ←【阻塞点 3：drawable 池耗尽（默认 3 张）】  dxmt_presenter.cpp:159
     ├─ 构建 present 渲染通道（blit / scale PSO；可能触发 frame_presented_.wait）         dxmt_presenter.cpp:159-185
     └─ if (after > 0) cmdbuf.presentDrawableAfterMinimumDuration(drawable, after)      dxmt_context.cpp:1101-1104
        else            cmdbuf.presentDrawable(drawable)
                    ↓
        winemetal unix 侧执行真实 Metal 调用                                            winemetal_unix.c:1304-1314
图层呈现：CAMetalLayer.displaySyncEnabled = false（构造期固定）                            dxmt_presenter.cpp:19 → winemetal_unix.c:1633
帧延迟栅栏：IDXGIDevice1::SetMaximumFrameLatency/GetFrameLatencyWaitableObject              d3d11_swapchain.cpp:952-984
    present_semaphore_ 初始计数 = kSwapchainLatency = 1                                      :33,149-150
    游戏可用 WaitForSingleObject(GetFrameLatencyWaitableObject()) 自行节拍（DXMT 只释放，不等待）
```

### 5.2 回答任务 A 的具体问题

1. **`vsync_duration` 在哪里计算**：`d3d11_swapchain.cpp:762`（参数来源 `:169` 配置、`:171-175` 显示器刷新率）。
2. **传递到哪**：`ctx.present(..., after, ...)`（`dxmt_context.cpp:533`）→ `PresentData::after`（`dxmt_context.hpp:252`）→ 命令队列执行时 `cmdbuf.presentDrawableAfterMinimumDuration(drawable, after)`（`dxmt_context.cpp:1101-1104`）。
3. **影响什么**：**显示时机**（最小呈现间隔），不阻塞 CPU；CPU 侧的等待另有其人（`frame_latency_fence_`、`nextDrawable`、可选的 `frame_presented_`）。
4. **`preferredMaxFrameRate=0`（MiPlay）真实行为**：`after = SyncInterval × 1/刷新率`。
   - `SyncInterval=0` ⇒ `after=0` ⇒ 无最小间隔，立即呈现（且图层 `displaySyncEnabled=false`）⇒ **不限速**（受 drawable 池/GPU/CPU 限制）。
   - `SyncInterval=1` ⇒ `after=1/刷新率` ⇒ 与 "60Hz 上等效 60 FPS" 的节拍一致。
   - `SyncInterval=2` ⇒ `30 FPS`（60Hz）。
5. **`preferredMaxFrameRate=60`（YAAGL）真实行为**：`after = max(SyncInterval/60, 1/60)`。
   - 60Hz：`SyncInterval=0/1` ⇒ 1/60（60 FPS 上限）、`SyncInterval=2` ⇒ 1/30（30 FPS）。
   - 120Hz：`SyncInterval=0/1` ⇒ 1/60（**把 120Hz 面板限制到 60**）、`SyncInterval=2` ⇒ 1/30。
6. **`SyncInterval=0/1/2`**：见上；本质是 `after` 的分子，`preferred` 存在时会用 `preferred` 取代刷新率作分母，并附加 `1/preferred` 下限。
7. **`displaySyncEnabled` 默认行为**：**不是默认值**——DXMT 显式写 `false`（`dxmt_presenter.cpp:19`）。因此 DXMT 下不存在"图层 vsync 兜底"，节拍完全由 `after` + drawable 池 + `max_latency_` 决定。
8. **其它限帧/同步机制**：`d3d11.preferredMaxFrameRate` 是**唯一**与帧同步相关的 DXMT 配置项（全树 `getOption` 扫描仅此一处）；此外有 `max_latency_=3`（CPU 等 GPU 完成）、`present_semaphore_` 初始计数 1（暴露给游戏的 Waitable Object）、`kSwapchainLatency=1`、可选 MetalFX 分支（MiPlay 已搁置）。
9. **16.7ms→33.3ms 的具体机制**：仅当 `SyncInterval=2`（或渲染/提交稳定超过一个刷新周期且上层自行节拍）时出现；`preferred=0` 与 `preferred=60` 在 `SyncInterval=2` + 60Hz 下**结果相同（都是 30 FPS）**。

### 5.3 任务 A2：原假设是否成立

不成立（E 级）。源码给出的是**上限**关系：`preferred=60` 只能让呈现"不早于 16.67ms"，而 `preferred=0` 的间隔 ≤ 前者（`SyncInterval≥1` 时相等或更短；`SyncInterval=0` 时为零）⇒ **不能解释"YAAGL 更快"**。需要区分的机制：

| 机制 | 由源码可确定的部分 | 需要实测的部分 |
| --- | --- | --- |
| 帧率上限 | `after` 是"最小呈现间隔"，等价于该值倒数的上限 | 实际呈现 FPS |
| 帧节奏稳定性 | `after>0` 时呈现被强制等间距；`after=0` 且 `displaySyncEnabled=false` 时呈现紧跟 GPU 完成（间隔可变） | 帧间隔直方图/曲线 |
| VSync | DXMT 不含图层 vsync；游戏侧 VSync 只通过 `SyncInterval` 进入 `after` | 游戏最终是否走了 Waitable Object 等待 |
| GPU 回压 | `frame_latency_fence_.wait(N-3)` 是每帧的 GPU 完成等待 | GPU frame time、等待占比 |
| CPU 提交阻塞 | `nextDrawable()`（drawable 池默认 3）与上述栅栏均可能阻塞渲染线程 | 渲染线程栈/等待时间 |
| 显示周期量化 | 只有 `after` 与刷新率相关；无其它量化逻辑 | 面板刷新率是否与 `after` 匹配 |

### 5.4 任务 A3：场景矩阵（S=源码可确定，M=需实测）

| 场景 | MiPlay（preferred=0） | YAAGL（preferred=60） | 结论 |
| --- | --- | --- | --- |
| VSync 关，60Hz | `after=0`：不限速（S），间隔随 GPU 波动（S），可能撕裂（S） | `after=1/60`：≤60 FPS 且等间距（S） | MiPlay 平均 FPS 更高或相等；均匀性 YAAGL 更好（M 验证幅度） |
| VSync 开，60Hz | `after=1/60`：等效 60 FPS 节拍（S） | `after=1/60`：同（S） | **行为等价**（S） |
| VSync 关，120Hz | `after=0`：不限速（S） | `after=1/60`：≤60（S） | MiPlay 可显著更高 |
| VSync 开，120Hz | `after=1/120`：可达 120（S） | `after=1/60`：≤60（S） | MiPlay 更高 |
| GPU 无法稳定 16.7ms | 间隔由 GPU 决定，无额外拖延（S） | `after` 只加"最小间隔"，不改善 GPU 慢帧（S） | 两者都掉帧；差异在分布（M） |
| CPU 无法稳定 16.7ms | 同上 | 同上；`max_latency_=3` 的等待对两者一致（S） | 需线程栈采样区分热点/等待（M） |

**可以确定**：在 VSync 开启且刷新率 = 60Hz 的常见配置下，两侧**不应有可测量的平均 FPS 差异**。因此若用户观察到明显差异，优先怀疑：① 游戏内设置/分辨率差异（§4，B 级）；② 实测时的运行配置（是否 Xcode、是否同一显示模式）；③ GPU/CPU 负载本质不同（缓存、场景）。

---

## 6. DXMT 对象生命周期分析（任务 C）

### 6.1 补丁完整性（C1）

- 补丁 diff（`Tools/DXMT/patches/fb45156-device-initialization.patch`）：把 `WMT::Device device_;` 从类尾部移到两个 `tess_*` 标量之后、`InternalCommandLibrary &lib` 之前；初始化列表顺序不变（原本已与"新声明顺序"一致）。
- 初始化时访问未构造成员：**已确认存在**（§2.1），且补丁修掉了唯一已知的使用点。
- 使用点核对（只在 `getComputePipeline` 内）：`ctx.lib.getLibrary()` 与 `ctx.device_.newComputePipelineState(...)`（`dxmt_context.cpp:1596-1606`）。补丁后 `lib` 与 `device_` 都在使用者之前声明/构造 ⇒ 该路径安全。
- 其它成员核对：`timestamp_state_`、`dummy_sampler_info_`、`queue_` 在 `dxmt_command_clear.hpp`/`dxmt_command_context.hpp`/`dxmt_command_blit.hpp` 中**均未被助手构造函数引用**（grep 无命中）⇒ 该类的同类风险未再发现。
- **不充分性的证据**：仍只是单次隔离实验复现 + 句柄复用这一未排除解释；本轮**没有新增**"补丁遗漏"的源码证据。因此结论是：**补丁覆盖已知路径，但不足以宣称崩溃已消除**。

### 6.2 同类问题扫描（C2，尽量穷尽）

| 检查项 | 方法 | 结果 |
| --- | --- | --- |
| 成员声明顺序与语义依赖不一致 | 枚举 `WMT::Device`/`WMT::Reference` 成员的类，比对使用点 | 仅 `ArgumentEncodingContext` 命中（已修） |
| 构造期依赖未初始化成员 | grep 助手构造函数体与其引用的 `ctx.*` | 无新增命中（仅 `lib`/`device_`） |
| 计算管线创建点 | 全树 `git grep newComputePipelineStateWithDescriptor` | **唯一调用点**：`src/winemetal/unix/winemetal_unix.c:391`（DXMT 侧经 `WMT::Device::newComputePipelineState`，`Metal.hpp:770` 起的 `Device` 包装） |
| 移动/复制导致引用失效 | 审阅 `WMT::Reference`/`Rc` 语义（`Metal.hpp`、`dxmt_context.hpp` 的 `SyncFrameState` 移动构造） | `SyncFrameState` 显式处理了移动（`d3d11_swapchain.cpp:707-718`），未发现悬垂使用 |
| 异步回调持有已销毁对象 | `emitcc` lambda 捕获 `this`，生命周期与设备/上下文一致 | 未发现越界捕获；需运行时验证 |
| 句柄复用（对象析构后句柄被再次使用） | 需 winemetal 句柄表实现细节 + 运行时观察 | **未排除**，属"需要运行时调用栈才能验证的假设" |

分类结论：
1. **已确认的 C++ 生命周期缺陷**：1 项（§2.1，stock 版本；MiPlay 已修）。
2. **高可信度但未证实**：句柄复用/对象生命周期导致的设备对象失效（与观察到的"随机对象接收 selector"同样吻合）。
3. **需要运行时调用栈**：ZZZ 崩溃的实际触发点（须带模块身份的符号化栈或 validation 断言）。

### 6.3 最小修复思路（不实施）

- 若要在 DXMT 侧进一步加固：在 `WMT::Device`/`WMT::Reference` 的转换处加断言（句柄有效性/类型），把"随机对象"变成可定位断言；对 `getComputePipeline` 之类"仅依赖 `device_`/`lib`"的路径加构造期守卫。
- MiPlay 侧无需改动（已含补丁）。

---

## 7. Wine 进程生命周期分析（任务 D）

### 7.1 退出与清理链（已核对行号）

```
包装进程（LaunchApps/<Game>.app/Contents/MacOS/<Game>）:
  setpgid → chdir(MIPLAY_LAUNCH_CWD) → execv(wine …)                     Tools/GameLauncher/GameLauncher.c:31-60
  waitpid(wine)  ← 只等 wine 启动器；Steam/Jadeite 可能先退出
  [MIPLAY_WAIT_WINESERVER] fork/exec wineserver -w（等整个 Prefix 无进程） :71-90
  写 launch.status（exit:/signal:）                                        :94-106
应用侧:
  ApplicationLauncher.waitForExit（500ms 轮询 kill(pid,0)）→ 读 launch.log/status  ApplicationLauncher.swift:71-101
  restoreStagedGameFiles()（只恢复被移开的 vulkan-1.dll）                  LaunchOrchestrator.swift:722
  gameRegistry.commitProcessExit(...)（AppData 写）                        :724
  停止安全作用域 → releaseSharedPrefixLease()                              :733-735
      └─ wineRuntimeProvider.shutdownSharedPrefix：`wineserver -k`，等待 ≤10s，接受退出码 0/1  WineRuntimeProvider.swift:291-303
  清 currentLaunchProcessID/currentGameID → 记录 launch.exit                 :737-750
  失败分支：recordProcessExitRecovery + 保留守卫（§2.2 的死锁入口）           :751-780
```

### 7.2 竞争条件检查（D2）

| 检查项 | 结论 | 依据 |
| --- | --- | --- |
| 未等清理完成就允许再次启动 | **不会**：`currentLaunchProcessID` 守卫 + 调度器 `sharedWinePrefix` 资源冲突 | `LaunchOrchestrator.swift:115-119`；`TaskScheduler.swift:240-251` |
| 并发启动请求操作同一 Prefix | **不会**（同一守卫/资源锁），但租约释放失败时会长期阻塞（§2.2） | 同上 |
| `wineserver -k` 是否有等待 | 有：`waitForTermination(timeout: 10)`，非 0/1 退出码即视为未确认 | `WineRuntimeProvider.swift:297-303` |
| DLL 恢复时机 vs 游戏仍在运行 | 由 `wineserver -w` 兜住（包装进程退出前保证 Prefix 内无进程）；**仅当走了 .app/GameLauncher 路径**。直接 ProcessManager 回退路径若不满足 `useHelper` 条件则不额外等待 | `GameLauncher.c:71-90`；`LaunchOrchestrator.swift:404-412` |
| 旧会话清理影响新会话 | 不会误杀：清理在守卫清除前完成，新启动被拒；错误分支见 §2.2 | `:610-628`, `:793-806` |
| 共享 Prefix 误杀其它游戏 | 单会话模型下不会；若存在 MiPlay 之外启动的残留进程，`wineserver -k` 会一并结束（设计如此） | `WineRuntimeProvider.swift:291-303` |
| 恢复入口可达性 | UI 提供入口（`MainWindowScene.swift:119`），但在 §2.2 场景下会被守卫拒绝 | `LaunchOrchestrator.swift:793-797` |

### 7.3 最小优化方案（D3，不实施）

1. **（正确性，最小）** 在 `monitorProcess` 中把"进程/会话守卫"与"租约"分开：进程已确认退出并提交后立即清 `currentLaunchProcessID`/`currentGameID`，随后再尝试释放租约；失败时只记录"租约未释放"事实而不阻塞恢复入口。
2. **（可观测性）** 为 `wineserver -k` 失败记录退出码/耗时并保留 stderr，便于将来判断 `msync_init` 竞争是否与之相关。
3. **（顺序保证）** 若将来允许"退出后立即重启"，在释放租约前显式等待 `wineserver` 进程消失（当前只有 10s 上限、无等待证据），以降低同步服务重新初始化的竞态概率。
> 以上都不涉及架构重构，均为局部顺序/状态修正。

---

## 8. 延后执行的人工测试清单（合并 E1–E5，最多 5 项，按信息增益排序）

> 用户目前无时间深度测试，全部推迟。每项标注：用户投入 / 用户要做 / Codex 可自动完成 / 观察什么 / 是否改环境 / 回退。**本轮未执行任何一项。**

| # | 项目 | 预计用户投入 | 用户要做 | Codex 可自动完成 | 观察结果 | 改环境？ | 回退 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T1 | **游戏内设置对齐后再测原神**（替代原 E1/E2） | 3–5 分钟 ×2 次 | 在 MiPlay 与 YAAGL 各自把原神设为同一分辨率（同一分辨率与显示模式）、渲染精度、动态模糊、VSync、FPS 档位，截图确认 | 事先给出"需要一致的字段清单"（§4 表格）；事后解析两侧 `GENERAL_DATA` 复核是否真的一致 | 若设置一致后 FPS 差异消失 ⇒ 差异来自设置；若仍存在 ⇒ 才值得继续查启动器 | 修改游戏内设置（可逆） | 记下原设置，改回即可 |
| T2 | **Finder vs Xcode 启动同一构建**（原 E2） | 2 分钟 ×2 | 用同一 MiPlay.app，先从 Finder 启动游戏记录 60 秒，再用 Xcode 运行同一构建重复 | 采集两侧 Wine 进程白名单环境、加载模块路径与哈希（只读） | 环境不同且 FPS 有差 ⇒ 需要收紧 `DYLD_*`；无差 ⇒ 排除该混淆 | 否（只读采集） | 无需回退 |
| T3 | **原神帧时间形态**（新，替代原 E1 的纯 FPS 对比） | 2 分钟 ×2 | 开启通用设置里的 Metal HUD（默认 Lite 面板含帧间隔曲线），在两个启动器同场景各看 60 秒 | 读取 HUD 数值/截图、与 §5.4 矩阵对照给出判定 | 是否出现 33.3ms 平台、GPU 时间占比、是否被 `after` 节流 | 仅打开 HUD 开关 | 关闭开关 |
| T4 | **ZZZ 崩溃取栈**（原 E4，隔离环境） | 10 分钟（可碎片） | 允许在隔离目录内连续 5 次启动并观察游戏窗口画面（40/140 秒标准） | 隔离环境准备、Metal validation 注入、模块哈希与崩溃报告收集、日志整理 | 是否出现 validation 断言/符号化栈 | 仅隔离环境 | 删除隔离目录 |
| T5 | **退出后重启稳定性**（原 E5） | 5 分钟 ×3 轮 | 一次一个游戏，退出后 0s/5s/30s 各重启 5 次 | 统计失败次数、抓取 `msync_init`/`bootstrap_look_up` 日志、汇总 | 失败率是否随间隔变短而上升 | 否 | 无需回退 |

（原 E1 的"注入 `DXMT_CONFIG`"实验**建议删除**：§5 已证明该参数只可能限制上限，单独注入不会带来 FPS 提升；保留为 T3 的判读依据即可。原 E3 的"实际加载模块确认"已并入 T2。）

---

## 9. 建议排序（按用户要求的顺序）

**A. 可由静态证据直接确认的正确性问题**
1. §2.2 MiPlay 租约释放失败的会话内死锁（改守卫顺序）。
2. §2.1 stock DXMT 成员初始化缺陷（MiPlay 已修；建议把补丁与构建来源写入资产清单，避免后续误替换回 stock 版本）。
3. 第一阶段文档三处过期/误读应在文档层修正：DXMT 身份（已统一为 `654f547+miplay-fb45156`）、"YAAGL 关闭 fixme"（实为开启）、"graphicsData[8]=3/2"（当前数据不可复现）。

**B. 需要实验才能确认的性能问题**
4. T1（设置对齐）优先于一切"启动器性能"结论。
5. T2（Xcode `DYLD_*` 污染面）与 T3（帧时间形态）。

**C. 长期可靠性改进**
6. DXMT 资产可追溯性（哈希清单 + staging 校验）。
7. 诊断留存（每次启动独立日志、固化最终环境与模块身份）。
8. ZZZ 取栈能力建设（隔离环境 + validation；不在主环境试验）。

---

## 10. 本次审计边界

未运行游戏、未修改任何代码/资产/Prefix/缓存/配置、未执行任何实验、未提交任何修复。§5 的机制结论均标注了"源码可确定 / 需实测"；§4 的 key→选项映射来自第三方工具（低可信度外部证据），key 19 明确标记为未解决。
