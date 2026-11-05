# 迁移准备报告

日期：2026-10-12（Asia/Shanghai）。本报告基于本地源码、Git、现有文档/QA证据及当前可访问的对话历史；其他仓库仅做限定范围的只读检查，未完整审计，也未更新远端。

## A. 项目基本信息

- 项目：MiPlay，原生 macOS 米哈游游戏启动器。
- 仓库：https://github.com/SteveTanSaMa/MiPlay.git；分支 main。
- 冻结提交：`b5ce2b675529765670470a51193065dd76033adb`。
- 所属工程：计划纳入与 DXMT、LSFG 等协同的工程工作区；正式工程名称、归属和负责人待确认。DSH 两仓库的直接 MiPlay 依赖未发现，不推定其存在。
- 请求路径 docs/migration 在当前不区分大小写的文件系统对应既有 `Docs/migration/`，保留历史 Docs 目录名。

## B. 开发冻结状态

**FROZEN。** 未继续功能开发、修改业务代码、切换 Wine/DXMT、启动游戏、重建用户 Prefix 或调整游戏文件；未 commit、push、fetch、合仓库或改写历史。

冻结前最近提交解决 wineserver 清理失败后的会话内恢复，自动测试覆盖已存在，真实异常恢复尚未验收。原神性能调查、ZZZ 修复充分性与后续异常日志对照、崩铁/DLSS 实机认证仍有缺口，详见 DEVELOPMENT_STATUS。历史 ZZZ 五轮游戏验收有真实截图/进程证据，但不能覆盖最新所有代码、配置和异常场景。

初始未提交内容完整保留：implementation-notes.md 的修改，以及三份 fix-launch-session-recovery / investigation-launch-chain-deep-dive / investigation-launch-chain-perf-audit 报告。原文件 SHA256、副本、工作树与索引补丁、初始状态保存在 `QAArtifacts/MigrationFreeze-20261012/`。原报告时点与当前 Git 不一致之处在交接中注明，不覆盖历史。

恢复建议：新工作区先核对提交、运行时资产和不同日期的实测证据，待工程级指令后再恢复开发。

## C. 文档整理结果

| 文档 | 用途 |
|---|---|
| PROJECT_OVERVIEW.md | 定位、功能边界、技术栈、入口和目录 |
| ARCHITECTURE.md | 模块/数据流、任务/Prefix生命周期、资源与构建 |
| DEVELOPMENT_STATUS.md | 验证范围、冻结任务、未开始项目、技术债务 |
| DECISIONS.md | 方案取舍、历史兼容性与被修正的假设 |
| INTEGRATION.md | 五仓库关系、实际版本差异、待确认接口与风险 |
| HANDOVER.md | 独立可读的接管步骤、验证方法与不可遗漏约定 |
| MIGRATION_REPORT.md | 本次操作及验证的最终记录 |
| CLEANUP_PLAN.md | 删除前的逐项候选清单、理由和保护边界 |

既有历史文档均未改写。交接特别记录：DXMT 补丁版本不是官方0.80；独立 fork HEAD 不等于应用资产版本；崩铁临时 hosts 修改会调用管理员授权，不能因通用 solutions 列表为空误判不存在系统副作用；用户负责游戏点击及 WASD。

## D. 工作区清理结果

删除前检查 Git、路径引用、符号链接、活动构建与文件占用，并形成 CLEANUP_PLAN 和 cleanup-candidates.json。按明确路径逐项清理：根 `.DS_Store` 与 build 下模块/编译/SDK 可重建缓存，共 **33 项，910,813,713 字节**。无候选因不确定性被强行删除。逐项结果在 cleanup-results.json。

保留全部 QAArtifacts、原始素材、References、运行时/Prefix、源码、锁定与配置、历史产品/dSYM/日志/测试结果/索引、中间链接材料、.trace、PerformanceScratch、.commandcode 及无法确认用途的文件。其他仓库和用户 Library 游戏数据未清理。

后续若要删除大型诊断材料、历史构建产品、索引或未知数据，需逐项审查并征求确认。本轮没有执行此类操作。上述字节数是删除总量，验证新产生的 DerivedData 和 xcresult 仍保留，不代表净磁盘减少同等容量。

## E. 当前项目健康状态

本轮在独立 `QAArtifacts/MigrationFreeze-20261012/Validation/DerivedData` 执行：

```sh
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath QAArtifacts/MigrationFreeze-20261012/Validation/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

启动前移除 MIPLAY_ZZZ_ 与 TEST_RUNNER_MIPLAY_ZZZ_ 前缀的真实验收环境开关。**TEST SUCCEEDED，退出码0；163 项测试，2 项跳过，0 失败，测试执行91.334秒。** 两项跳过为真实游戏验收，不启动游戏；临时测试夹具不代替用户环境验收。

本机为 macOS27.2 beta / Xcode27.0，项目当前 Swift5 语言模式。构建和自动测试通过不代表签名、公证、发布或完整 Swift6 测试通过。已有 Swift6 Sendable 测试缺口不在冻结期间修复。

证据：validation-command.json、validation.log、validation-exit.json、Validation/DerivedData/Logs/Test 下 xcresult。DXMT 七件套及 Jadeite manifest 文件哈希检查通过；HEAD 与初始四份文档哈希保持不变。最终完整性结果见 integrity-results.json。

运行时资源保留 `654f547+miplay-fb45156`，Wine 固定 `wine-crossover-11.0-1-signed`；没有执行官方0.80回退。本轮未下载 Wine 或检查实时游戏加载模块。原神帧时间/实际像素对齐、ZZZ 后续异常归属、崩铁/DLSS 实机及最新恢复故障边界均待验证。

## F. 跨项目协作事项

- DXMT：以完整资产 manifest、源码基线/补丁及构建 SDK 为配对单位；不能只升级版本常量或 NV DLL。
- LSFG：组件契约已存在，但 MiPlay 未集成；需协调架构、MoltenVK、签名、用户商业资源授权和发布包。
- DSH-Studio / Runtime：已确认彼此运行时发布联系，未发现 MiPlay 直接依赖；可借鉴签名/catalog管理，不自行形成共享API。
- 其他仓库存在各自未提交修改；迁移必须保留独立仓库和适用约定。正式工程治理、接口负责人、版本发布矩阵待确认。
- 旧 References clone、独立 forks 与应用内资产有不同 HEAD，不自动同步。详见 INTEGRATION 的只读快照与范围说明。

## G. 迁移就绪程度

**READY — 已具备知识与工作区迁移交接条件。** 标准文档齐全，状态和版本可追溯，原始成果/证据保全，有限安全清理完成，冻结版本构建与自动测试通过。READY 只评价本次迁移准备，不表示所有功能、游戏稳定性或发布认证完成。

原始未提交文档和新增迁移文档保持未提交状态，迁移时应连同必要的本地 QA 材料带入；不能只 clone HEAD 就声称完成全部交接。正式工程归属与未来大文件清理需工程级决策，不阻止保全式接管。

## H. 新工作区接管指引

1. 先读 HANDOVER → DEVELOPMENT_STATUS → DECISIONS → ARCHITECTURE → INTEGRATION → PROJECT_OVERVIEW。
2. 核对 main/完整 HEAD、初始四份文档与 QA 保全哈希、RuntimeAssets manifest；登记各独立仓库状态。
3. 优先澄清历史五轮验收与后续异常审计的资产/时间关系，以及原神实际分辨率差异，不沿用已被修正的帧率上限解释。
4. 在隔离测试路径恢复构建；真实游戏测试、系统副作用和账户操作单独遵守授权，键鼠由用户操作。
5. 保持冻结，等待新的工程级指令；不自动提交、推送、清缓存或启动下一阶段开发。
