# MiPlay 项目概览

冻结基准：2026-10-12（Asia/Shanghai），`main` / `b5ce2b675529765670470a51193065dd76033adb`。迁移准备只允许知识整理、审查过的可重建缓存清理和验证；常规开发停止。此目录逻辑名称为用户要求的 `docs/migration/`；本机大小写不敏感，既有根目录为 `Docs`，实际路径为 `Docs/migration/`，没有重命名历史目录。

## 定位与所属工程

MiPlay 是原生 macOS 米哈游游戏启动器，提供已有游戏的定位、Wine 环境管理、启动兼容和可恢复进程生命周期，并展示官方版本背景、图标及新闻。它负责用户入口与游戏运行环境的集成，不负责重写游戏或底层渲染器。

所属统一工程工作区的正式名称、范围与协调负责人**待用户确认**。已确定的是仓库继续独立：MiPlay 承担应用与 Wine/DXMT 集成；DXMT/LSFG 底层研发在独立工程。DSH-Studio 与 DSH-Studio-Runtime 是另一条 AI 客户端/运行时链，未发现 MiPlay 的应用依赖，不能因工作区共置就合并架构。

仓库：`https://github.com/SteveTanSaMa/MiPlay`。开发阶段：可运行原型/兼容性稳定化，具备部分实机验证，不是所有功能完成或发布完成。

## 功能边界

- 当前游戏类型为原神、崩坏：星穹铁道、绝区零；三类型有代码不等于三款游戏均已充分实机验证。
- 固定 Wine `wine-crossover-11.0-1-signed`、一个 shared Prefix，定位既有游戏并执行启动预检、兼容 staging、进程监控与恢复。
- 原神/绝区零通过 Steam 兼容存根启动；崩铁通过 Jadeite；相关条件详见 ARCHITECTURE 与 INTEGRATION。
- DXMT 二进制随包、实验性 DLSS/NGX 开关、Retina/HUD 等设置；LSFG 未接入。
- 官方背景/图标/新闻，媒体缓存和转码，任务进度、日志、更新信息查询与完整性校验框架。
- 游戏自动完整安装、Sophon 增量更新、多 Wine 用户选择、五款游戏全面支持不是当前已交付能力。旧产品愿景中的这些目标须与代码/后续 ADR 区分。

## 技术栈与运行要求

Swift、SwiftUI、AppKit、Observation、Swift concurrency actor；Foundation/URLSession、AVFoundation、ImageIO、CryptoKit 等系统框架；C 编写 universal GameLauncher；x86_64 Wine/Windows PE DLL、winemetal Mach-O、Metal，在 Apple Silicon 上涉及 Rosetta。媒体转码调用 FFmpeg，需要检查受控资源与可执行路径。

工程是 Xcode 项目而非 SwiftPM 主工程。应用/测试目标 deployment target 为 macOS 26.0；project 级设置另有 27.0，不可据此把最低部署目标统一改写。应用 Swift **5.0 语言模式**，默认 MainActor；非 UI actor/值类型有显式 nonisolated 边界。应用未启用 App Sandbox，启用 Hardened Runtime。本次验证机器：macOS 27.2 beta / Xcode 27.0（27A5218g）；运行/发布签名兼容性仍需验证。

## 项目入口与目录

| 目录/文件 | 职责 |
|---|---|
| `MiPlay.xcodeproj`、scheme `MiPlay` | 应用和 XCTest 构建配置 |
| `MiPlay/MiPlayApp.swift` | 依赖注入、生命周期、主窗口/Settings 场景 |
| `MiPlay/UI` | 主窗口、设置、组件与 MainActor ViewModel |
| `MiPlay/Domain` | GameRegistry、TaskScheduler、WineVersionManager、LaunchOrchestrator、媒体/性能/方案业务 |
| `MiPlay/Infrastructure` | 文件、持久化、网络、进程、Wine、日志、媒体、图标、新闻 |
| `MiPlayTests` | 临时目录/假运行时回归与显式启用的真实游戏验收入口 |
| `RuntimeAssets`、`MiPlay/Resources/GameLauncher` | 必需运行资源，不能当成临时二进制清理 |
| `Tools/DXMT`、`Tools/GameLauncher` | 可追溯构建与定向设备复现程序 |
| `script/build_and_run.sh`、`.codex/environments/environment.toml` | 开发启动入口，默认会终止 MiPlay，详见 HANDOVER |
| `Docs`、`Agent Prompts` | 产品到发布的历史设计和执行约定 |
| `References` | YAAGL/其他参考；DXMT/LSFG fork 克隆忽略于本仓库 |
| `QAArtifacts`、`build` | 本地证据、运行环境、产物；Git 忽略，但部分必须随迁移保存 |

## 当前状态依据

详细状态见 DEVELOPMENT_STATUS。2026-10-10 曾完成修复版绝区零五次真实角色场景 ≥180 秒验收，未以 XCTest/PID 存活替代画面。之后新增静态审计与会话内恢复修复；**五轮历史结果不能自动证明当前 HEAD 或所有游戏长期稳定**。最新审计纠正了原神“缺少 60 帧上限导致更慢”的假设，记录了保存分辨率与画质配置不一致及仍需核实的补丁后异常线索。

阅读顺序：HANDOVER → DEVELOPMENT_STATUS → ARCHITECTURE → DECISIONS → INTEGRATION → MIGRATION_REPORT。
