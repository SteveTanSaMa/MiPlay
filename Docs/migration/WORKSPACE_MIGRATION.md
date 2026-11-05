# MiPlay App 工作区实际迁移报告

## 1. 迁移信息

- 项目：MiPlay App；本 Agent 仅负责本应用仓库。
- 原路径：`/Users/stevetan/SteveTan/Document/Xcode/MiPlay`。
- 新路径：`/Users/stevetan/SteveTan/Document/Developer/MiPlay/MiPlay App`。
- 迁移日期：2026-10-13，Asia/Shanghai；实际移动约02:27–02:28。
- 方式：同一文件系统 /dev/disk3s1、同一设备号。确认目标为空后 rmdir 空目标，再 mv -n 源目录至目标；没有复制、重克隆或永久兼容链接。
- 冻结分支/HEAD：main / `b5ce2b675529765670470a51193065dd76033adb`；未提交/推送，未恢复功能开发。

## 2. 文件迁移结果

移动前记录168,220个文件条目、35,364,743,430逻辑字节、2,256个符号链接及708份Git跟踪/未忽略文件哈希。原Git文件监视器先停止，迁移后Git在新根正常识别并按原配置恢复监视。

目录 inode 和设备号保持一致，说明整体同文件系统重命名；.git、隐藏文件、权限、原始素材、QA、运行时和未跟踪内容随原目录迁移，无额外嵌套。迁移后逐项原文件哈希检查仅出现下述6份文档的预期改变，符号链接目标全部一致，DXMT/Jadeite资产哈希全部通过。原目录不存在；无目标冲突或应迁未迁的残留。

没有移动兄弟项目、Developer父目录或Forks，也没有清理其他Agent的目录。移前保全记录和移后检查均在 `QAArtifacts/WorkspaceMigration-20261013/`，没有生成完整项目备份。

## 3. 路径修复记录

| 文件 | 原路径/内容 | 新路径/内容 | 原因 |
|---|---|---|---|
| Docs/02-ux/ux-revision-2026-08-03.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/02-ux/ux-runtime-revision-2026-08-05.md | ux-runtime-revision-2026-08-05.md | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/02-ux/ux-edge-cases.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/02-ux/ux-runtime-revision-2026-08-05.md | ux-runtime-revision-2026-08-05.md | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/02-ux/ux-runtime-revision-2026-08-05.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/00-product/product-runtime-revision-2026-08-05.md | ../00-product/product-runtime-revision-2026-08-05.md | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/02-ux/ux-runtime-revision-2026-08-05.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/01-research/research-wine-shared-prefix-2026-08-27.md | ../01-research/research-wine-shared-prefix-2026-08-27.md | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/02-ux/ux-runtime-revision-2026-08-05.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/01-research/research-wine-archive-and-mac-info-2026-08-05.md | ../01-research/research-wine-archive-and-mac-info-2026-08-05.md | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/02-ux/ux-task-analysis.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/02-ux/ux-runtime-revision-2026-08-05.md | ux-runtime-revision-2026-08-05.md | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/02-ux/ux-task-analysis.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/Docs/02-ux/ux-state-flow.md | ux-state-flow.md | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/08-qa/qa-report.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Debug-20260802-final.xcresult | ../../QAArtifacts/Debug-20260802-final.xcresult | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/08-qa/qa-report.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Debug-20260802-final.log | ../../QAArtifacts/Debug-20260802-final.log | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/08-qa/qa-report.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Release-20260802-arm64.xcresult | ../../QAArtifacts/Release-20260802-arm64.xcresult | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/08-qa/qa-report.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Release-20260802-arm64.log | ../../QAArtifacts/Release-20260802-arm64.log | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/08-qa/qa-report.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/QAArtifacts/Release-20260802-final.xcresult | ../../QAArtifacts/Release-20260802-final.xcresult | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/08-qa/qa-report.md | /Users/stevetan/SteveTan/Document/Xcode/MiPlay/MiPlayTests/MiPlayCoreTests.swift | ../../MiPlayTests/MiPlayCoreTests.swift | 保留链接目标，改为相对当前文档的可移植路径 |
| Docs/migration/INTEGRATION.md | 2026-10-12审计布局 | 正式工程布局说明；旧表保留历史快照 | 新增正式工程布局和历史路径说明，保留原审计快照 |

生产源码、Tools、script、测试、Xcode工程及.codex环境配置未发现旧MiPlay/Forks的活动绝对路径，无需修改业务逻辑。build_and_run.sh 已通过脚本位置计算ROOT_DIR；build_patched.py 的源仓库/工具链路径由参数传入，不绑定旧Forks。Xcode workspace使用self引用，无本地SwiftPM路径包需要修复。

## 4. 验证结果

- Git：新根正确；分支、HEAD不变；原 implementation-notes 修改、3份研究报告和迁移文档均保留。新增变动仅文档路径修复/本报告及被忽略的验证证据。
- 原文件完整性、链接目标与资源清单：全部预期通过，详见 before.json / integrity-results.json / path-fixes.json；修改后相对文档链接均找到目标。
- git diff --check 通过。
- 构建与单元测试：新路径下 xcodebuild test 成功，退出码0；163项测试，2项真实游戏测试跳过，0失败；测试执行94.876秒，结束于2026-10-13 02:30:09（Asia/Shanghai）。原始命令、日志与xcresult在 QAArtifacts/WorkspaceMigration-20261013/Validation。
- 真实游戏验收开关已从子进程环境移除，没有启动游戏、下载Wine、重建用户Prefix或改变游戏配置。验证使用新建隔离DerivedData，旧含绝对路径的缓存未复用；未重新下载大型依赖。

## 5. 旧路径复查与未解决事项

1. Docs中的本仓库绝对跳转链接已改为可移植相对链接。INTEGRATION旧表明确标注历史快照，上方新增正式目标布局；旧冻结报告、QA日志/JSON、xcresult、dSYM及其他诊断记录保留原时点路径，不能当新工作区命令使用。
2. 被忽略的旧生成器 `QAArtifacts/MigrationFreeze-20261012/write_migration_docs.py` 含旧审计路径，仅作历史产物，禁止再次运行覆盖现有交接文档。其他QA脚本扫描未发现旧MiPlay/Forks匹配；历史二进制/构建缓存中的路径不作文本替换，按新路径重新构建。
3. 2,256个符号链接中没有指向已移动的MiPlay旧根。Wine用户目录链接仍指向用户Library/home、系统及游戏位置；不修改用户环境。References/YAAGLSWIFTUI/sidecar以及QA历史快照中的同名链接指向旧外部YAAGLSWIFTUI仓库；这不是本次移动导致的MiPlay路径失效，也非应用依赖，保留原状，若后续使用参考仓库需由其维护者确认目标。没有修改参考仓库源码或链接。
4. 项目无根级AGENTS.md/CLAUDE.md/.agents/.claude/.cursor；.codex/environments/environment.toml为相对运行命令，保留自动生成配置。参考仓库自身Agent规则不改写。
5. **需用户在Codex/IDE中将项目根重新选择为新绝对路径，并更新已保存的旧书签、终端cwd或外部自动化。** 本次工具已能以新workdir读写/构建；没有权限或接口证据证明外部应用项目注册已改好，不能声称已完成该项。没有用兼容链接掩盖它。
6. DXMT、LSFG和DSH的正式目标遵从用户映射，由各自Agent迁移；本Agent不确认其迁移验收，也不移动空Forks。当前MiPlay应用不从这些兄弟源码目录动态加载资产。
7. 原神性能、ZZZ后续异常归属、崩铁/DLSS实机、签名/公证和最新故障恢复边界继续保持待验证。详见 DEVELOPMENT_STATUS；本次迁移测试不代替真实游戏认证。

## 6. 最终迁移状态

**SUCCESS：实际移动完成，Git/资产完整性、文档链接及新路径构建/测试关键验证通过。** 外部Codex/IDE项目根登记仍需用户重新选择；历史诊断路径与既有参考链接明确分类保留，不影响应用构建。没有重新认证游戏或发布签名。迁移无关开发保持冻结；新工作区先读 HANDOVER、本文和INTEGRATION，再等待工程级指令。
