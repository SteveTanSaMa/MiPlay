# YAAGL 启动策略接入（2026-10-10）

已按 `References/YAAGL` 的 `784dda3` 实现启动策略。此次是代码与组件集成，不是三款游戏实机稳定性验收；没有宣称绝区零此前的 DXMT 异常已解决。

| 游戏 | 启动入口 | 同步 | Timeout Fix | 专用准备 |
| --- | --- | --- | --- | --- |
| 原神 | Wine → Steam 存根 → 游戏 | esync | 1 | Steam 四件套 |
| 绝区零 | Wine → Steam 存根 → 游戏 | msync | 1 | Steam 四件套、WebView 注册表修正 |
| 崩铁 | Wine → Jadeite → 游戏 | msync | 0 | Jadeite 三件套、WebView 修正、NV 扩展、15 秒连接域名屏蔽 |

## 实现

- `LaunchCompatibilityEnvironment` 共用原神与绝区零的 Steam 安装和调用方法；崩铁在 Prefix 的 `drive_c/MiPlay/Jadeite` 中安装 `jadeite.exe`、`game_payload.dll`、`launcher_payload.dll`，按 Windows 路径传递游戏参数。支持路径中有空格。
- `LaunchOrchestrator` 检查所选路径的所有必需组件。缺失或拷贝失败会阻止启动，不能静默回退为已知不兼容的直启。同步变量显式开启一项、关闭另一项，避免继承冲突的 esync/msync 设置。
- 崩铁在 Apple Silicon 上按 YAAGL 的启动要求准备 NVAPI / NGX，启动前写入 NVIDIA / NGX 标识，并设置 60 FPS、vendor `10de`、device `2684`。这项是崩铁的兼容准备，与通用 DLSS 实验开关分别处理；性能选项的 DXMT 配置追加到兼容配置后，保留用户覆盖能力。
- `GameLaunchPreparation` 只删除当前 Prefix 内指定游戏的已知 WebView 渲染值。未存在的注册表键不阻止首次启动，其他进程错误会传播。
- 崩铁启动前通过 macOS 的管理员授权对话框临时追加两个 `globaldp` 域名的 hosts 条目。由于 MiPlay 当前没有区服模型，覆盖国服及国际服两个域名。每行带独立 UUID，后台特权子进程 15 秒后删除本次拥有的条目，保留用户或其他应用的现有条目。拒绝授权或写入失败则启动失败；取消 MiPlay 启动、游戏启动失败或关闭 MiPlay 不会取消独立恢复计时。恢复进程被强制杀死或系统断电仍可能留下注释为 `MiPlay-HSR-<UUID>` 的条目，不能称为所有异常情况下的事务回滚。上游永久 analytics 屏蔽脚本没有执行或加入自动启动。
- `GameLauncher.c` 在启动器正常退出后等待托管 `wineserver -w`，防止 Steam / Jadeite 退出而游戏子进程仍运行时，MiPlay 过早结束会话、释放 Prefix。直接 ProcessManager 回退也使用同一入口。Wine 启动器的非零退出与信号不被等待逻辑掩盖；正常包装器退出码并不等于已经测得游戏子进程最终退出码。

## 随包资产

Jadeite 4.1.0 从 YAAGL 指定的官方地址下载：
`https://codeberg.org/mkrsym1/jadeite/releases/download/v4.1.0/v4.1.0.zip`。
归档 SHA-256 为 `12d4c37b09d3e81640536fd68c2c62913fc4b4a90c0183e4dec845e4934a9858`。MIT 许可证与各文件哈希存放在 `RuntimeAssets/jadeite`。哈希记录用于本轮资产身份和构建验证，不代表独立签名认证或已实现运行时哈希校验。

GameLauncher 已用 `cc -Wall -Wextra -Werror -O2 -arch arm64 -arch x86_64` 重新编译，并更新随包入口。DXMT 的七个 DLL / SO 和构建产物哈希均与此前验收基线一致；没有修改 DXMT 源码、资产或 Wine 版本。

## 验证与边界

- `build/YAAGLLaunchSupport` 的 Xcode Debug 构建通过。
- 启动参数与配置、Jadeite 完整安装与缺件拦截、重复 staging、原神/绝区零共享入口、WebView 值筛选、NV 注册表准备与失败传播、Wine 子进程等待及错误传播、书签生命周期与退出状态测试通过。
- 网络窗口在临时 hosts 文件中验证自动恢复、保留他人同域名条目及带引号路径。管理员授权 AppleScript 只做语法编译，没有执行，没有改 `/etc/hosts`。
- 构建包中 Jadeite 与许可证逐文件哈希匹配 manifest。启动生命周期使用模拟 Wine / 游戏脚本，不执行真实游戏或 Jadeite 注入。
- 首次测试发现 Jadeite 目标目录未创建及旧测试夹具缺少新必需资源，均已修正并复测。相关证据保留在 `QAArtifacts/YAAGLLaunchSupport-20261010`。

仍需人工实机验证：崩铁进入登录及游戏；原神与绝区零的 Steam / Timeout Fix 新路径；绝区零连续五次启动的 40 / 140 秒截图标准。游戏或兼容组件更新也可能改变 Jadeite 适用性。此实现没有修复已定位线索中的 DXMT 成员初始化顺序问题。
