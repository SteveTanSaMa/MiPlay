# 绝区零：隔离 DLL 与启动入口对照

本轮完成独立运行环境安装、三组对照、真实 Wine 启动进程参数/环境读取和 LLDB 异常断点尝试。**没有证明闪退已修复，也没有获得异常调用栈。**

## 环境与控制变量

- 重新编译到 `build/ZZZIsolatedDiagnostics`，使用此前重新下载且校验通过的官方 Wine 归档，生产解压与初始化代码安装到 `QAArtifacts/ZZZ-Isolated-Matrix-20261010/FreshSupport`。
- 游戏安装继续复用现有文件。原 MiPlay / YAAGL 安装及 Prefix 未替换；没有清理其缓存。
- 从全新 Wine 安装中提取原始 NVAPI / NGX，SHA-256 前缀分别为 `206693df4a1c1cb1`、`756eb5cf9b082572`，与 YAAGL ZZZ 的原始文件匹配；对照中同时覆盖隔离 runtime 和 Prefix 的对应位置。
- 每组恢复同一份初始化后的 Prefix 快照，再做相同的生产 DXMT / Steam staging。DXMT 核心资源保持不变，NVEXT 始终为 0。第三组只切换到 DXMT 配套 NVAPI / NGX 文件。
- Steam、Timeout Fix、msync、Retina、HUD 保持开启；按 YAAGL 对齐 `WINEDEBUG`、空 DLL overrides、DXMT 日志路径与不存在的配置文件路径。直接组仍保留同一个 GameLauncher 生命周期入口，仅移除 LaunchServices。因此它是父进程/LaunchServices 对照，不是逐字复制 YAAGL 的 `unixExec2`。
- 系统 Metal 缓存、游戏文件缓存、Wine runtime 路径及测试顺序仍可能影响结果。每组仅一次，不足以估计故障概率。

## 三组结果

| 对照 | 40 秒 | 140 秒 | 日志 |
| --- | --- | --- | --- |
| Wine 原始 NV DLL + LaunchServices | 包装进程存活 | 包装进程存活 | 未出现本轮管线异常 |
| Wine 原始 NV DLL + 直接 GameLauncher | 已退出 | 未继续检查 | 同一 `newComputePipelineStateWithDescriptor…` 异常，接收对象 `NSIndirectTaggedPointerString` |
| DXMT 配套 NV DLL + LaunchServices，NVEXT=0 | 包装进程存活 | 包装进程存活 | 未出现本轮管线异常 |

截图观察器取得了屏幕图片，但至少第一组 40 秒图片是前台桌面，并非游戏窗口，不能据此认定画面验收通过。进程存活也不等于游戏正在渲染。尝试通过 Window ID 获取背景窗口时，所选窗口已不可获取，没有形成可验证的窗口截图证据。因此两组存活结果只用于有限的启动诊断，不能计入五连截图验收。

第二组在已换回原始 NV DLL、NVEXT=0、Steam / Timeout Fix 已设置的情况下复现。这直接反对“扩展 DLL 是唯一必要原因”或“换回 DLL 就一定消除崩溃”的结论。第三组没有失败也不能反过来证明扩展 DLL 永远安全。

LaunchServices 与直接入口存在单次结果差异，但尚不能认定前者更稳定。随机 Objective-C 对象接收 Metal 方法，与此前发现的 DXMT 未初始化 `device_` 缺陷仍高度吻合；需要栈或稳定的重复对照确定实际故障位置。

## 参数与实际环境证据

每组保存 `run-N-launch.json`，包含提交给启动 API 的 Wine argv、工作目录及 Wine / DXMT / Metal / DYLD 关键变量，其他继承环境中的秘密不记录。

实际 Wine 启动进程 `process-10818.json` 确认：

```text
wine C:\windows\system32\steam.exe Z:\…\ZenlessZoneZero.exe
DXMT_ENABLE_NVEXT=0
WINE_ENABLE_TIMEOUT_FIX=1
WINEMSYNC=1
WINEESYNC=0
WINEDLLOVERRIDES=
WINEDEBUG=fixme-all,err-unwind,+timestamp
WINEPREFIX=<隔离 Prefix>
```

另有 `process-9786.json` 记录直接 GameLauncher 参数及环境。观察器最初使用的 `ps comm` 被截断，修正为完整 argv 后取得这些记录；没有为第一组补造实际进程环境快照。Wine 创建的游戏进程后来改写了 argv/environ 表示，`ps -E` 不能完整读取游戏进程的环境，因此实际 Wine 父进程环境不应写成游戏内部全部变量已证实。

还发现实际 Wine 启动进程保留 Xcode 的 `DYLD_LIBRARY_PATH`、`DYLD_FRAMEWORK_PATH`。现有过滤仅移除了 Metal 开发变量。该事实是后续环境对照候选，不代表已经证明加载了 Xcode 的替代图形库或因此崩溃。记录的内存映射可用于进一步核查。

## 异常栈采集结果与限制

普通对照不附加调试器，避免暂停或调试影响其结果。随后独立调试 Prefix 尝试附加游戏 PID，并在 `objc_exception_throw` 设断点，计划收集线程栈、寄存器、镜像列表。

首次调试夹具没有复制 Steam 组件，在真正游戏启动前失败；修正后又发现 Wine 游戏进程不向 `ps -E` 暴露 Prefix。之后通过其映射的隔离 Wine 文件验证目标身份，再尝试附加 PID 15892。

LLDB 停留在 `process attach --pid 15892`，其子进程是 `/Library/Apple/usr/libexec/oah/debugserver`。75 秒等待及后续中断未返回有效 attach 状态，断点命令尚未执行，没有线程栈。结束本次 LLDB 和仅属于本轮的 Rosetta debugserver 后，清理隔离游戏。原因尚未确定，不能无证据归因于权限、SIP 或 Wine 某个具体缺陷，也没有更改安全策略、签名或运行时。

原始调试文件中的超时提示不能作为“75 秒没有游戏异常”的证据：调试器根本没有完成附加。普通对照的失败日志是真实崩溃证据，尚不是符号化异常栈。

## 清理和后续

- DXMT 七件套项目文件哈希未改变。临时移开的游戏 Vulkan 文件已恢复，常规 `.bak` 与独立调试备份均没有遗留。隔离游戏、Wine 与本轮 debugserver 已结束；未终止用户已有的 Xcode debugserver。
- 诊断 XCTest 显示通过，只表示安装/记录/清理程序跑完；其中第二组游戏启动明确失败，不能把这个测试结果当作游戏稳定性通过。
- 仅改动显式启用的测试诊断入口，默认测试仍不会自动启动游戏，没有据此改变产品启动配置。

优先后续：单独比较去掉 Xcode `DYLD_*` 的普通启动环境；排查 Rosetta attach 阻塞，再获取真实异常栈。若要认定某个启动入口有效，仍需原先的连续五次 40 / 140 秒游戏窗口画面标准。无需继续无差别重装或清除原环境。

全部证据位于 `QAArtifacts/ZZZ-Isolated-Matrix-20261010`：三个 launch JSON、普通日志与截图、实际进程 JSON / vmmap、原始 NV DLL、Prefix 快照、LLDB 命令与输出、两次准备失败记录、`cleanup-verification.json`。这些包含较大的本地运行环境，不应作为应用资产发布。
