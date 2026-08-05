# 质量门禁与风险矩阵

> 状态：2026-08-02 执行版

## 风险矩阵

| 风险 | 分类 | 可能性 | 影响 | 缓解/当前证据 | 状态 |
|---|---|---:|---:|---|---|
| 进程 timeout/取消导致悬挂或 double resume | [Func] | 中 | 高 | TC-PROC-004~006 | 已覆盖 |
| AppData 损坏导致数据丢失 | [Func] | 中 | 高 | 备份、恢复、迁移测试 | 已覆盖 |
| bookmark stale/access denied 误报安装 | [Comp] | 中 | 高 | 迁移前状态测试；真实授权待测 | 部分覆盖 |
| manifest 路径逃逸或错误文件被接受 | [Func] | 低 | 高 | hash、缺失、版本、逃逸测试 | 已覆盖 |
| TaskScheduler 失败后状态不一致 | [Reg] | 中 | 高 | 进度、失败、恢复、持久化测试 | 已覆盖 |
| helper/Wine 需要真实系统权限 | [Comp] | 中 | 高 | 缺失能力先失败；真实权限待测 | Pending |
| UI/VoiceOver/键盘行为回归 | [Acc]/[UI] | 中 | 中 | 语义契约；无 UI screenshot | Pending |
| Release 配置无法编译测试 module | [Reg] | 已发生 | 中 | arm64 destination + `ENABLE_TESTABILITY=YES` | 已解释 |
| 外网/API 行为与 fixture 不一致 | [Func] | 中 | 中 | 网络替身；保留真实集成套件 | Pending |

## 门禁状态

| Gate | 条件 | 当前状态 | 依据 |
|---|---|---|---|
| Gate 1: Design Complete | 需求映射到 UX/UI/Architecture | Pass（文档映射） | `qa-rtm.md`；未实现项保留 Pending |
| Gate 2: Implementation Complete | 测试 target 可执行；P0 自动化 100% | Pass（自动化范围） | 25/25 P0；30/30 总体 |
| Gate 3: Regression Pass | Smoke + P0/P1 regression 全通过 | Partial | 自动化 P0/P1 通过；UI/Wine Smoke Pending |
| Gate 4: Performance Pass | Cold launch、memory、P99 达标 | Not Ready | 本轮无性能 trace |
| Gate 5: Release Ready | P0/P1=0、coverage 达标、Smoke/Perf 全过 | Not Ready | UI/Wine/Perf/coverage 门禁未完成 |

## 通过标准

- P0 自动化通过率必须为 100%；本轮为 `25/25`。
- P1 自动化通过率至少 95%；本轮为 `5/5`。
- 任何未执行的真实集成或手工项目不能折算为通过。
- Release 不能因为自动化通过就直接标记 Release Ready。
- `.xcresult`、日志和失败诊断必须保留。

## 缺陷记录

本轮没有自动化 P0/P1 assertion failure。Release 初次尝试因 Release app module 未带 `-enable-testing` 而在测试编译前失败，已通过明确的 arm64 destination 和 `ENABLE_TESTABILITY=YES` 重跑；该事件保留在 `Release-20260802-final.*`，成功结果在 `Release-20260802-arm64.*`。
