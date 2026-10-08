# MiPlay Architecture Phase 3 Contracts

> **文档状态**：已被当前修订取代（Superseded）
> **取代文档**：`architecture-revision-2026-08-03.md`（历史基线）；当前规范见 2026-08-28 Architecture 回溯文档。
> **原因**：Product/Research/UX/UI 在 2026-08-27 至 2026-08-28 重新冻结了单一固定 Wine、单一共享 prefix、简化 setup、schema 4 迁移和共享 prefix lease。

本文件保留为上一阶段的追溯入口，不再是 Implementation 的有效契约。下游必须使用以下当前条款：

| 主题 | 当前有效位置 |
|---|---|
| 固定 Managed Wine、删除 system Wine detection | `architecture-domain-model.md` §4、`architecture-service-contracts.md` §7-8、ADR 037-039 |
| 固定 catalog entry、WineRuntimeSetup | `architecture-service-contracts.md` §7、`architecture-task-queue.md` §1/§3/§8、ADR 040 |
| `pkg_version`、`config.ini`、manifest 证据 | `architecture-service-contracts.md` §5、ADR 026 |
| PerGameSettings、BackgroundGroup | `architecture-domain-model.md` §2.4、ADR 027 |
| 六项高级配置 Deferred | `architecture-domain-model.md` §5.1、ADR 028 |
| bookmark stale 统一刷新/写回 | `architecture-communication.md` §5、`architecture-p1-repair-impact.md` |
| TaskReceipt、runtime/prefix 互斥/取消、终态提交 | `architecture-task-queue.md` §1-8、ADR 039-040/042 |
| 进程退出、跨重启 Running 恢复 | `architecture-service-contracts.md` §6.2、ADR 014/020 |
| Actor 隔离、Domain event、ViewModel projection | `architecture-communication.md` §1-2/§9、`architecture-state-ownership.md`、ADR 001-003/021 |

## 历史处理

Phase 3 期间的旧描述（包括“记录外部 Wine 检测”“批准镜像自动回退”“下载任务同时发现 metadata 和 asset”）不再代表当前设计。它们不能作为兼容实现、诊断 UI 或测试通过口径。若实现仍依赖这些边界，必须回溯到 Architecture，而不是由 Implementation 自行恢复旧行为。
