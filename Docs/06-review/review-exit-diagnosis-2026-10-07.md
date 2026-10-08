# 退出诊断修正与交接

日期：2026-10-07。负责人：Codex。用户问题：游戏闪退和手动强制退出都显示反作弊组件不兼容。

## 原因

1. GameRegistry 和 LaunchOrchestrator 各有一套基于文件名的诊断；只要输出含 HoYoKProtect.sys 或 WDFLDR.sys 就宣称反作弊不兼容，没有考虑退出信号。
2. GameLauncher 将输出追加到固定 launch.log；新启动前未清空日志和旧 launch.status，历史错误或历史状态可能污染本次判断。
3. ApplicationLauncher 将缺失/损坏的状态文件映射为 statusCode=0、terminatedBySignal=true，虚构了 signal:0。
4. 直接子进程在启动确认阶段返回的 ProcessError 含 signal，但 LaunchOrchestrator 之前忽略了此字段。

## 当前修正

- 新增 GameExitDiagnostic，统一两条退出诊断路径。
- SIGKILL 优先显示被强制终止，保留“无法确认发起方”；SIGTERM/SIGINT 显示收到终止信号；SIGABRT/SIGSEGV 等显示崩溃类信号，不从日志文件名反推因果。
- 没有有效状态时使用 -1/false 表达未知，显示无法区分闪退与外部强制退出。exit:0 才是已确认的正常退出。
- 非零普通退出码只有在本次同一条日志同时出现驱动名、加载上下文和失败证据时，显示“本次日志显示反作弊驱动加载失败，可能存在 Wine 兼容问题”。普通 Wine err 行不再被命名为兼容性原因。
- LaunchServices 打开应用前重置本次日志并移除旧状态；重置失败走现有启动失败/直接子进程回退路径，不沿用旧事实。
- 直接子进程的 signal 传入同一个诊断器；正常退出清除旧 lastLaunchFailure。
- 不修改 GameBusinessState、AppData schema 或游戏兼容参数。无法确认的异常退出仍使用 launchFailed 状态，但展示准确的证据类别，不冒充用户正常退出。

## 判断边界

当前进程观察能记录退出码和终止信号，不能可靠获知系统“强制退出”操作的发起方。
即使是 SIGKILL，也不能直接标为“用户主动退出”；也可能是其他进程或系统终止。
若用户杀掉 GameLauncher 本身而非其 Wine 子进程，它可能来不及写状态，正确结论为未知。
Wine 可能将子游戏的异常转换为普通退出码；Steam 存根路径还有孙进程，因此也不能仅凭退出码数字百分百识别实际游戏的崩溃原因。
若后续增加应用内“停止游戏”操作，应单独记录用户请求意图；如要更强的崩溃证据，可关联进程身份与系统崩溃报告。这些不属于本次实现。

依据：[Apple waitpid 状态文档](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/waitpid.2.html)、[Apple 信号文档](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/sigaction.2.html)。

## 验证

本轮新增 5 个测试，并扩展现有 Registry 退出提交测试。6 个针对性测试全部通过：
- 缺失/无效状态不制造信号。
- 下一次启动不沿用旧日志或状态。
- 文件名、普通错误和 exit(137) 不构成反作弊或 SIGKILL 证据。
- 真实 /bin/sh 子进程收到 SIGKILL 后不被判为反作弊问题。
- 运行实际随包 GameLauncher，验证其被杀子进程的 signal:9 状态与本次日志。
- Registry 持久化链路覆盖驱动加载错误、强制终止、崩溃类信号、未知状态及正常退出清除旧诊断。

全量测试在前 4 个新增测试加入后执行：124 tests，2 failures。失败为：
`testPendingProcessExitRecoveryCommitsAutomaticallyThroughViewModel`（期望 installed、实际 launchFailed），以及
`testWineSchedulerReturnsOneReceiptAndRejectsResourceConflict`（任务终态写回重读不一致）。
单独复测二者：Wine 用例通过，退出恢复用例仍失败。旧实现记录已提及退出恢复用例的时序问题；本轮未修改该恢复链路，未声称它已修复或全量测试通过。
最后增加实际 GameLauncher 测试后，只运行上述 6 个针对性测试，没有再次跑全量。
未启动任何真实游戏；测试使用临时目录和短命令。未使用 computer use。

## 交接

本轮修改 GameExitDiagnostic.swift、GameRegistryLocation.swift、LaunchOrchestrator.swift、ApplicationLauncher.swift，以及两个现有测试文件。
Tools/GameLauncher/GameLauncher.c 和随包二进制未修改。保留此前 UI 修改及全部工作区遗留修改，未提交 Git。
下一步可先处理退出恢复用例对应的状态覆盖问题，再进行用户实机游戏退出验证。
