# MiPlay Architecture Phase 3 Contracts

> **文档状态**：已被当前修订取代（Superseded）
> **取代文档**：`architecture-revision-2026-08-03.md`
> **原因**：Product/Research/UX/UI 在 2026-08-03 冻结后，Wine 来源、系统 Wine detection、metadata、per-game settings、background group 和 Deferred 能力边界发生了架构修订。

本文件保留为上一阶段的追溯入口，不再是 Implementation 的有效契约。下游必须使用以下当前条款：

| 主题 | 当前有效位置 |
|---|---|
| Managed Wine-only、删除 system Wine detection | `architecture-revision-2026-08-03.md` §1-2、§4、ADR 023-024 |
| API discovery、Release metadata、asset download | Revision §4、ADR 025 |
| `pkg_version`、`config.ini`、manifest 证据 | Revision §5、ADR 026 |
| PerGameSettings、BackgroundGroup | Revision §6、ADR 027 |
| 六项高级配置 Deferred | Revision §6.3、ADR 028 |
| bookmark stale 统一刷新/写回 | Revision §7、`architecture-p1-repair-impact.md` |
| TaskReceipt、Wine 下载互斥/取消、终态提交 | Revision §8、`architecture-task-queue.md` |
| 进程退出、跨重启 Running 恢复 | Revision §8.4、ADR 014/020 |
| Actor 隔离、Domain event、ViewModel projection | Revision §3、`architecture-state-ownership.md`、ADR 001-003/021 |

## 历史处理

Phase 3 期间的旧描述（包括“记录外部 Wine 检测”“批准镜像自动回退”“下载任务同时发现 metadata 和 asset”）不再代表当前设计。它们不能作为兼容实现、诊断 UI 或测试通过口径。若实现仍依赖这些边界，必须回溯到 Architecture，而不是由 Implementation 自行恢复旧行为。
