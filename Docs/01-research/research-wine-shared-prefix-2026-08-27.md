# Research 报告: 固定 Wine 与共享 prefix 技术事实

日期: 2026-08-27
范围: `wine-crossover-11.0-1-signed` 的共享运行时约束、Wine prefix 初始化、`wineboot`/`wineserver` 行为、并发与污染风险，以及 YAAGL 参考实现。
角色边界: 本文件只整理已观察到的代码、上游源码和本地运行结果；不替 Product、UX、UI、Architecture 或 Implementation 做方案决策。
适用性边界: 目标 release 的结论只适用于该 release tag 和该 release asset。其他 Wine 版本、其他签名变体、其他架构或其他镜像必须重新研究。

## 1. 当前研究输入

用户在 2026-08-27 明确冻结以下硬约束:

- 当前统一使用 `wine-crossover-11.0-1-signed`。
- 原神、星穹铁道、绝区零共用一个 Wine runtime。
- 三款游戏共用一个 MiPlay 管理的 Wine prefix。
- 移除按游戏选择 Wine 的产品路径。
- 简化 Wine 下载、安装与设置流程。

这组要求覆盖此前 I-4 的“全局 / 单独 Wine 版本”设计。本报告不把旧选择模型、旧多版本目录或旧按游戏 prefix 规则作为当前产品事实。

## 2. Wine prefix 的可验证事实

### 2.1 prefix 不是 Wine 归档内的固定 binary 目录

Wine runtime 归档提供 executable、动态库和资源；prefix 是由 Wine 根据配置目录创建或更新的运行时状态目录。Wine 上游 `wineboot` 源码中的 `update_wineprefix()` 读取配置目录并更新 `wine.inf`，命令行帮助将 `-u` 定义为更新 Wine prefix 目录，`-i` 定义为首次 Wine 实例初始化。

证据:

- Wine 上游 `programs/wineboot/wineboot.c` 的 `update_wineprefix()`、`get_wine_inf_path()` 和 usage 文本。
- `References/YAAGLSWIFTUI/Services/WineService.swift:256-301`：安装归档后单独执行 prefix 初始化和 Wine 配置。
- 当前 MiPlay `MiPlay/Infrastructure/Wine/WineRuntimeProvider.swift:114-173`：使用同一 Wine binary 执行 `wineboot -u`，随后检查 `drive_c`。

因此，下载或解压完成不能单独推出 prefix 已准备完成，也不能把归档中的 `wine/` 目录当作 prefix。

### 2.2 `WINEPREFIX` 是调用级运行时输入

YAAGL 在 `createWine(options:)` 中接收一个 prefix 路径，并在每次 Wine 执行环境中设置 `WINEPREFIX`。其 `exec`、`exec2` 和 `waitUntilServerOff` 共用该环境；`wineserver -w` 也使用相同的 `WINEPREFIX`。

证据:

- `References/YAAGL/src/wine/wine.ts:18-80`：`prefix` 参数和 `WINEPREFIX` 环境变量。
- `References/YAAGL/src/wine/wine.ts:66-70`：使用同一 prefix 等待 wineserver 结束。
- 当前 MiPlay `MiPlay/Domain/Launch/LaunchOrchestrator.swift:167-194`：启动时把 prefix 注入 `WINEPREFIX`。

这说明共享 prefix 的身份必须由上游域层固定并传给 prefix 初始化、readiness 和游戏启动的全部调用。它不说明具体共享目录名称；目录名称属于后续 Architecture / Implementation 契约。

### 2.3 `wineserver` 存在共享状态协调边界

Wine 上游 `dlls/ntdll/unix/server.c` 定义了 server socket 和 lock 文件，并在建立配置目录后根据该目录的设备号和 inode 初始化 server directory。源代码随后在该目录中连接或启动 server，并检查 socket、owner 和权限。

证据:

- Wine 上游 `dlls/ntdll/unix/server.c:90-93`：`socket`、`lock` 和 server directory。
- 同文件 `:1301-1355`：由配置目录的 `st_dev`/`st_ino` 初始化 server directory，并创建 `dosdevices`、`drive_c`。
- 同文件 `:1403-1468`：连接或启动 server，并检查 server directory 和 socket 的 owner/权限。

由此可记录的事实是：多个调用指向同一 prefix 时，会进入同一 prefix 相关的 Wine server 协调范围；多个调用不能被假设为完全独立。该源码片段不证明所有游戏操作都必须串行，也不证明任意两个游戏可以同时稳定运行。

## 3. 共享 prefix 的状态范围与风险

以下是共享 prefix 由目录语义带来的待验证风险，不是已经证明的游戏兼容性结论。

### 3.1 共享状态

三款游戏若使用同一个 `WINEPREFIX`，它们将共同面对同一个 prefix 状态，包括 Wine 初始化生成的 Windows 目录结构、`drive_c`、`dosdevices`、注册表状态、用户目录和 Wine server 协调状态。游戏 executable 目录仍然可以位于各自的已授权游戏目录；游戏目录授权与 App Support 下的 prefix 不是同一权限事实。

### 3.2 并发风险

- 同时执行 `wineboot`、注册表导入、DLL 覆盖、兼容方案写入或其他 prefix 修改操作时，多个操作可能写入同一 prefix 状态。
- 一个游戏运行时，另一个游戏或设置流程若修改同一 prefix，结果可能受调用顺序和 Wine server 状态影响。
- 单纯使用 Swift actor 只能串行化该 actor 自身的方法；它不能自动阻止已经启动的外部 Wine 子进程之间共享 prefix。
- `wineserver -w` 表达的是等待 server 结束的同步点，不是跨所有 MiPlay 任务的完整互斥协议。

这些风险要求后续 Architecture / Implementation 明确共享 prefix 的资源锁、启动与修复的生命周期，以及允许或禁止的游戏并发；Research 不选择其中一种策略。

### 3.3 污染风险

- 一款游戏或兼容方案写入的注册表、DLL 覆盖、Windows 组件或用户目录状态可能被另一款游戏观察到。
- 以 prefix 为目标的恢复或删除操作影响三款游戏，不能沿用“只恢复当前 Game ID prefix”的旧假设。
- 共享 prefix 失败时，单款游戏的 readiness 不应掩盖共享 prefix 的整体失效。

“可能被观察到”是共享目录和共同运行时状态的风险描述，不是对三款游戏实际行为的兼容性判断。目标 release 与三款真实游戏的交叉启动、方案应用和恢复仍需真实验证。

### 3.4 恢复风险

已观察到的状态关系如下:

```text
固定 Wine asset
    -> 托管 Wine 安装
        -> 共享 prefix 初始化 / 更新
            -> 共享 prefix readiness
                -> 目标游戏启动前置验证
                    -> 游戏进程
```

共享 prefix 初始化失败、取消清理失败、运行中 prefix 损坏或恢复记录未收敛时，不能把另一款游戏的 prefix 或系统 Wine 作为 fallback。恢复动作对共享 prefix 具有全局影响；恢复期间必须考虑三款游戏的活动进程、待处理任务和持久化事实。具体锁和恢复协议交由 Architecture 回溯设计。

## 4. 当前 MiPlay 的直接冲突

当前源码仍是旧模型，以下只是代码事实:

| 位置 | 当前行为 | 与新硬约束的关系 |
|---|---|---|
| `MiPlay/Infrastructure/FileSystem/GameFileSystemRepository.swift:415-419` | 返回 `Application Support/MiPlay/WinePrefixes` 目录 | 目录本身可以作为共享根，但当前调用方继续追加 Game ID |
| `MiPlay/Infrastructure/Wine/WineRuntimeProvider.swift:127-129` | prefix 路径为 `WinePrefixes/<gameID>` | 直接实现了按游戏独立 prefix |
| `MiPlay/Infrastructure/Wine/WineRuntimeProvider.swift:244-256` | readiness 和路径查询都接收 `gameID` 并追加该 ID | 共享 prefix 的单一身份尚未形成 |
| `MiPlay/Domain/Runtime/WineVersionManager.swift:102-105,146-153` | 恢复全局 selected version、source 和 per-game override | 仍保留旧多版本、来源选择和按游戏 Wine 覆盖状态 |
| `MiPlay/Domain/Launch/PreLaunchValidator.swift:183-190` | 按当前游戏调用 prefix 准备 | 调用入口仍是 game-scoped prefix |
| `MiPlay/Domain/Launch/LaunchOrchestrator.swift:164-180` | 按当前游戏解析 runtime 并准备对应 prefix | Wine/prefix 身份未收敛为三款游戏共用的固定身份 |

上述冲突属于 Product / Research 回溯后的下游待处理输入。本报告不直接修改这些实现。

## 5. YAAGL 参考实现的可复用事实

### 5.1 单一 prefix 参数贯穿 Wine 调用

YAAGL `createWine` 不为每个游戏自动生成 prefix；它接收调用方传入的 `prefix`，并把同一值用于 Wine 命令、`cmd`、`exec2`、`wineserver -w` 和环境变量。这可复用为“prefix 身份必须贯穿所有 Wine 调用”的事实参考。

### 5.2 安装阶段在 Wine 归档之后初始化 prefix

`References/YAAGLSWIFTUI/Services/WineService.swift:256-301` 的顺序是:

1. 解压归档到托管安装目录。
2. 找到 Wine binary。
3. 清除提取文件的 quarantine 属性。
4. 设置初始化环境。
5. 执行 `wineboot -i`。
6. 等待 wineserver。
7. 执行 `winecfg` 配置。

这是 YAAGL 的实现顺序事实，不是 MiPlay 当前产品流程或兼容性证明。该实现也使用 `wine_prefix` 作为单一 prefix 目录名（`WineService.swift:27,43-44`）。

### 5.3 binary 选择事实

`References/YAAGL/src/wine/wine.ts:172-180` 先检查 `./wine/bin/wine64`，失败后使用 `./wine/bin/wine`。这只证明 YAAGL 支持在其工作目录下对两种 binary 名称进行 fallback；不能覆盖目标 release 归档的本地 listing，也不能把 `wine64` 假设带入 MiPlay。

### 5.4 不可复用的推断

YAAGL 代码没有证明:

- 三款米哈游游戏在同一个 prefix 中都兼容。
- `wine-crossover-11.0-1-signed` 与 YAAGL 参考实现使用完全相同的动态库或目录布局。
- `wineboot -i` 或 `wineboot -u` 在真实签名 MiPlay、App Sandbox 和目标游戏上都能成功。
- 共享 prefix 可以不加资源锁地并发启动或并发修改。

## 6. 后续阶段必须验证的事实

以下项目是验证清单，不是本 Research Agent 的设计决策:

- 用目标 release 的实际 binary 执行 `--version`，确认 executable 身份、工作目录和动态库相对查找。
- 用同一 binary 设置固定共享 `WINEPREFIX` 执行 `wineboot`，确认初始化、`drive_c`、`dosdevices`、注册表和 wineserver 收敛。
- 重复初始化、取消、进程异常退出和 prefix 部分损坏后，确认恢复与清理事实。
- 在三款游戏之间验证启动顺序、重复启动、同时启动请求、运行中切换和共享 prefix 修改冲突。
- 验证兼容方案写入、后置验证、回滚和恢复不会把一款游戏的结果错误发布为另外两款游戏的 readiness。
- 验证 App Sandbox、用户选择游戏目录的 security-scoped bookmark 与 App Support 共享 prefix 的权限边界互不替代。
- 对新的 Wine release 或归档布局重新执行归档 listing、摘要和 binary 路径验证。

## 7. 证据索引

### 用户与 Product 输入

- 2026-08-27 用户指令：统一固定 Wine、共享 runtime、共享 prefix、移除按游戏 Wine 选择、简化流程。
- `Docs/00-product/product-features.md`：固定 Wine 与共享 prefix 的产品范围记录。

### MiPlay 当前源码

- `MiPlay/Infrastructure/Wine/WineRuntimeProvider.swift:114-173,244-256`
- `MiPlay/Infrastructure/FileSystem/GameFileSystemRepository.swift:415-419`
- `MiPlay/Domain/Runtime/WineVersionManager.swift:102-153`
- `MiPlay/Domain/Launch/PreLaunchValidator.swift:183-190`
- `MiPlay/Domain/Launch/LaunchOrchestrator.swift:164-194`

### YAAGL 参考代码

- `References/YAAGL/src/wine/wine.ts:18-80,156-180`
- `References/YAAGLSWIFTUI/Services/WineService.swift:27,43-44,238-301`

### Wine 上游源码

- `programs/wineboot/wineboot.c`：`update_wineprefix()`、`-i` 和 `-u` usage。
- `dlls/ntdll/unix/server.c`：server directory、socket、lock、prefix 目录初始化和连接检查。
