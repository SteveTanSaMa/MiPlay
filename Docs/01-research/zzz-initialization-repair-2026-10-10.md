# 绝区零初始化异常修复（2026-10-10）

状态：**SUCCESS — 已修复并完成验收**。重新构建的 MiPlay 生产 orchestrator 在隔离运行环境中连续五次进入真实角色场景，各观察至少 180 秒；每轮独立结束并重启，保留完整截图、真实游戏 PID、窗口、文件映射、环境和日志。

## 根因与证据

MiPlay 原随包 DXMT 为 `654f547`。该提交的 `src/dxmt/dxmt_context.hpp:921` 将 `ArgumentEncodingContext::device_` 声明在 `clear_uav_cmd` 后面。C++ 按成员声明顺序构造；构造列表把 `device_(device)` 写在某处不能改变这一规则。

`ClearUAV` 构造函数（`src/dxmt/dxmt_command_clear.hpp:29`）立即通过 `ctx_.getComputePipeline()` 创建清除用计算管线。该特化实现读取尚未构造的 `ctx.device_`，经 Wine Unix bridge 的 `_MTLDevice_newComputePipelineState` 把其值作为 Objective-C 接收对象发送 `newComputePipelineStateWithDescriptor:options:reflection:error:`。这里的 `WMT::Device` 是保存 handle 的非 owning 包装；正常 device 由上层设备持有。本次缺陷发生在首次使用早于成员初始化，不能靠延长 retain 生命周期修复。

因此，若内存恰好为零或先前合法的设备句柄，可能暂时不报相同异常；若包含其他数据，则可被解释为 tagged NSString、NSDate、NSNumber 或无效指针。不同对象名称并不代表不同修复方式，也不能仅凭对象名作上述推断。

本轮补足了以下证据链：

1. 旧二进制真实游戏再次崩溃，`A-inherited/game.log` 报 `__NSCFNumber` 同一 selector，接收值 `0x5c77656e5f657461`。
2. 用相同工具链、源码基线、桥接库分别构建未修复及修复 D3D11；在独立 D3D11 复现程序中，合法分配、填充并释放 `CommandQueue` 同尺寸堆块后创建设备。没有越界写、释放后写或游戏文件修改。
3. **关闭诊断注入**后，未修复版连续两组都在第 2 次设备创建失败；修复版两组各完成 40 次。按“旧→新→旧→新”执行，其他二进制和运行配置一致，版本显示字符串随控制组变化。
4. 定向 Objective-C 异常记录得到 `_MTLDevice_newComputePipelineState → __wine_unix_call_dispatcher` 的真实 native 栈。此栈来自独立复现程序，并非声称获得完整游戏的 Windows/C++ 栈。
5. MiPlay 生产启动路径已用新资源进入游戏内街区，窗口截图 HUD 显示修复版版本前缀；真实游戏 PID 的文件映射指向隔离 runtime 的 d3d11/dxgi/winemetal，与随包 SHA-256 一致。

修复采用上游原补丁 [fb4515681daefb789a4d0f403c4bdbca88f3b3de](https://github.com/3Shain/dxmt/commit/fb4515681daefb789a4d0f403c4bdbca88f3b3de)，同时提前声明和初始化 `device_`。没有替换异常对象、吞掉异常或用 nil 防护掩盖失败。此证据足以确认并修复这处缺陷；不能排除游戏内还有其他独立崩溃。

之前关闭 NVEXT、更换原始 NV DLL、Steam/Timeout 调整没有改变这条 D3D11 内部构造链，因此不能保证解决这个问题。

## 其他假设和诊断限制

- DYLD 对照：保留两次，一次崩溃、一次在短观察期存活；移除两次均未见该异常。样本很少，存活组不能据此认定稳定或建立因果。未将环境过滤写入生产代码。修复后的生产包装进程仍实际继承 Xcode DYLD 路径。
- 实际 Wine 进程改写 argv/environ 后，`ps -E` 不显示某个键不能证明键不存在。分别保留包装进程环境、Wine 可观察字段及真实游戏 DLL 映射，不混淆它们。
- LLDB：独立 x86_64 Objective-C 小程序在 `run` 阶段也超过 20 秒未完成，出现读取 host shared cache 失败警告；系统为 macOS 27.2 beta，工具链为 Xcode 27.0 beta。说明阻塞不限于 Wine，但尚不能确认具体 LLDB/Rosetta 缺陷。没有关闭 SIP、改签 Wine 或调整系统调试策略。
- 初版异常探针遇到架构不符，之后 RTLD_NEXT 转发发生递归；均保留失败证据。最终探针为 universal，直接转发原 `objc_exception_throw`，独立 self-test 确认恰好捕获一次并正常到达 catch。回归对照最终在完全无注入条件下执行。
- 最初截图选择错误地限制 layer=0；实际 Wine 全屏窗口在 layer=26。现在按真实游戏 PID、标题及尺寸选取游戏窗口。初始生产观察器短暂误选了 argv 中包含游戏路径的 Steam PID，已修正为首个 executable 的精确身份，旧记录单独保存，未开始验收计时。

## 连续重启中发现的退出清理竞态

渲染修复后，严格重启序列暴露了独立的 MiPlay 生产问题：`cleanup()` 与 `monitorProcess()` 在 actor 的 `await` 处交错，两条路径都取得同一 `activeSharedPrefixLease`，都执行关闭与释放。日志出现“共享 prefix lease 释放顺序不一致”，随后被写入未完成的退出恢复事实，阻止下一轮启动。此问题解释退出后重新启动被阻断，不将它当作 Metal 初始化异常的原因。

`Production/interrupted-series-3/round-2/launch-failure.txt` 与 `production-test-4.log` 保存实际失败。生产修复保留按会话标识的监控任务；监控启动后由它唯一提交退出状态、释放作用域与 Prefix lease，主动清理终止进程后等待同一任务完成。状态守卫也按会话一起清除，避免旧任务清除新会话的游戏标识。监控尚未启动的预启动失败仍走原清理路径；提交失败仍保留恢复守卫。

新增重复停止后连续重启回归，与原自然退出测试一起通过（2 项，0 失败，`cleanup-regression.log`）。这两项验证进程管理与状态提交，不替代游戏验收。

## 实际修改与构建

- `Tools/DXMT/patches/fb45156-device-initialization.patch`：可追溯的上游初始化修复。
- `Tools/DXMT/build_patched.py`：独立目录重建七件套，固定源码基线，检查非系统 Mach-O 依赖，生成哈希清单；不会改动已安装 Wine。
- `Tools/DXMT/device_repro.c`：可复现的非零堆内存设备创建回归程序，仅隔离环境使用。
- `RuntimeAssets/dxmt`：七个二进制同基线重建，版本 `654f547+miplay-fb45156`，清单含完整提交及哈希。它是本地构建修复版，不是官方 0.80。
- `MiPlay/Domain/Launch/LaunchOrchestrator.swift`：统一运行阶段退出清理的所有权，消除重复释放 Prefix lease。
- `MiPlayTests/WineSchedulerTests.swift`：新增退出清理回归与显式启用的生产 orchestrator 验收入口。默认跳过；外部观察器负责实际 PID/窗口/画面/时间/响应证据，任何一轮失败停止，不跨失败累计。
- Wine 运行版本保持 CrossOver 11.0-1。Wine 8.16 SDK 仅用于编译 DXMT，与上游构建方式一致，不是游戏运行时降级。
- App `build-for-testing` 成功；运行包在 `build/ZZZRepair/Build/Products/Debug/MiPlay.app`。源码调试符号与大体积隔离环境留在忽略的 QAArtifacts，未装入应用。独立 DXMT/LSFG 工程未修改。

当前构建为 debugoptimized 并剥离随包调试符号；其他游戏及 DLSS 路径本轮未作实机回归。没有主动过滤全部 DYLD、改变同步参数或清理用户缓存。

## 验收记录

最终序列采用同一个已登录的隔离 Prefix 与 Wine 11.0，没有在五轮之间重建 Prefix 或更换 Wine。启动走实际 `LaunchOrchestrator → LaunchServices 游戏应用 → GameLauncher → Steam stub → ZenlessZoneZero.exe`。测试入口只替换隔离数据目录和创建所属测试应用的 bookmark。登录、加载及 API 返回后的等待均不计入下表。

| 轮次 | 角色画面确认后的运行时间 | 游戏 PID | 游戏窗口 | 崩溃/意外退出 | 结果 |
|---|---:|---:|---|---|---|
| 1 | 181.5 秒 | 33111 | 完整角色画面，ID 16297 | 未发生 | 通过 |
| 2 | 183.4 秒 | 33885 | 完整角色画面，ID 16465 | 未发生 | 通过 |
| 3 | 182.8 秒 | 34530 | 完整角色画面，ID 16514 | 未发生 | 通过 |
| 4 | 183.3 秒 | 35248 | 完整角色画面，ID 16569 | 未发生 | 通过 |
| 5 | 183.2 秒 | 36100 | 完整角色画面，ID 16642 | 未发生 | 通过 |

每轮 `Production/round-N/start.png`、`middle.png`、`final-after-180.png` 是开始、运行中和 180 秒后的证据。用户操作产生的角色位置、视角及场景变化证明可响应；同时持续检查实际游戏 PID 和系统窗口清单。用户要求接管操作后，自动点击与键盘已停用，观察器只截图和采集进程。末次截图均是游戏内角色画面，没有将登录、桌面、包装进程或 XCTest 成功当作游戏验收。

`acceptance-results.json` 提供每轮计时起点、时间、实际加载路径与 DLL 哈希、截图和日志绝对路径。加载的 x86_64 `d3d11.dll`、`dxgi.dll`、`winemetal.so` 与修复包一致；`.aot` 映射是 Rosetta 对该 Mach-O 的转换缓存，不是第二份 DXMT 源文件。保留的 i386 DLL 未用于该 x86_64 游戏进程。

最终测试驱动成功完成；五次退出清理日志均为已确认取消，没有 Prefix lease 重复释放或退出提交恢复错误。所有五个游戏 PID 和本轮 Wine 临时进程已结束，生产 staging 临时移开的 `Plugins/x86_64/vulkan-1.dll` 已恢复，无 `.bak` 残留。隔离 Prefix、原始资产备份、构建符号与诊断证据保留用于回退/复核，不作为应用资源提交。

先前未完成的序列保留在 `Production/interrupted-series-*`，没有累计其通过次数：包含完整截图观察中断、夹具 600 秒复核超时主动停止，以及修复前的退出清理竞态。首轮曾因后台缩略窗口重启观察计时；后台状态在窗口清单中存在，不能据此认定崩溃，最终只认可重新取得完整角色画面后的连续观察。

本次结论覆盖上述五轮启动与至少 180 秒游戏内稳定性验收。其他游戏、DLSS 开启后的路径、长时间战斗及 FPS 对照未在本轮完成，不将截图 HUD 的瞬时 FPS 当作性能改善结论。

## 证据与回退

本轮根目录：`QAArtifacts/ZZZ-Repair-20261010`。

- `repair-summary.json`：A/B 与反向设备回归结果。
- `poison2-*/log.txt`：无注入对照。
- `confirmed-exception-stack.log`、`probe-selftest.log`：最终异常栈及探针转发验证。
- `complete-patch.diff`、`dxmt-*.log`、`unpatched-build.log`：源码差异和构建记录。
- `acceptance-results.json`、`final-build-evidence.json`：五轮结果与随包/实际加载哈希。
- `Production/round-*/`：生产路径进程、映射、窗口、截图和观察器结果。
- `production-test-5.log`、`cleanup-regression.log`：最终启动/清理序列及清理回归。
- `ProductionAssetsBefore/`：完整原 DXMT 资产备份，可恢复该目录后重建 MiPlay；不要覆盖正在运行的 Wine。

未执行官方 0.80 回退：当前初始化缺陷已被受控对照验证并修复；此时回退只会引入另一组变量。若后续修复版仍失败，再按照用户要求继续定位或评估最终回退。
