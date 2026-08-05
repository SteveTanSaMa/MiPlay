# Review Issue Backtrace

> 当前 Review 的唯一修改范围是 Review 文档。每个开放项回溯到最早责任 Agent；Review 不代替上游修复。

| ID | 严重度 | 状态 | 最早责任 Agent | 证据 | 回溯动作 |
|---|---|---|---|---|---|
| P1-REV-003 | P1 | Closed | Implementation | exit commit failure、restart reconcile、durable guard、idempotent retry tests | 保持当前实现；真实进程/权限交给 User Validation |
| P1-REV-004 | P1 | Closed | Implementation | stale refresh/writeback/revoked access across integrity/version/refresh/preflight/launch tests | 保持当前实现；真实 bookmark 交给 User Validation |
| P1-02 | P1 | Closed | Implementation | production GameLocation boundary；raw seams internal；managed runtime/extraction identity | 不回溯 Architecture；签名 Sandbox 仅作外部验证 |
| P1-04 | P1 | Closed | Implementation | manager readiness、prefix `drive_c` gate、Settings projection、focused test | 不将 `preparePrefix` 的真实 Wine 缺失写成代码缺陷 |
| P1-07 | P1 | Closed | Implementation | managed staging root、symlink/traversal rejection、cleanup guard and tests | 不允许任意 cleanup；签名 Sandbox 仍待用户验证 |
| P1-REV-005 | P1 | Open | Implementation | asset non-2xx becomes plain string and then `networkUnavailable`; no asset 403/404/429/5xx test | Preserve typed HTTP status through asset path, map Domain error categories, add status matrix and cleanup assertions |
| P1-08 | P1 | External Blocked | UI + Apple Review | static semantics only; no signed App, AX Inspector, VoiceOver navigation/audio or dynamic task trace | User Validation: real AX tree, VoiceOver, keyboard and progress/failure/cancel/retry/rollback |
| P1-UV-002 | P1 | Conditional External | Research -> Architecture -> Implementation | official source/allowlist code and MockURLProtocol fixtures; no real API/asset result bundle | User Validation: real API, 302 asset, 403/404/429/5xx, timeout and artifact inspection |
| P2-01 | P2 | Conditional | Architecture -> Implementation | project capability flags; adhoc unsigned result | Signed build, entitlements dump and Sandbox read/write test |
| P2-02 | P2 | Closed | Implementation | Debug/Release 62/62 and cancellation cleanup/recovery tests | Repeat in signed distribution environment |
| P2-03 | P2 | Closed | Implementation | `.notSelected`, `.notDownloaded`, `.prefixNotReady`, `.error` retained and tested | Real runtime state smoke only |
| P2-04 | P2 | Conditional | UI | fixed button/rail/Settings geometry and semantic code | User screenshot, focus/hover, multi-screen and localization verification |
| P2-LOG-001 | P2 | Conditional | Implementation | 111 structured record call sites; 50 legacy calls intentionally discard prose, so some lower-value detail is unavailable | Convert remaining business terminal paths to stable structured events; re-scan sensitive fields |
| P2-05 / DOC-REV-001 | P2 | Open | Implementation / QA | `Docs/08-qa` still contains historical 30/30 or old Pass wording; Review does not overwrite frozen input | QA/Implementation sync current 62/62 and Pending/external boundaries |

## Architecture Backtrace Decision

本轮不回溯 Architecture。P1-REV-005 违反的是现有错误映射契约的实现，而不是新增来源、TaskReceipt、状态或权限契约。只有修复需要改变 Domain Task outcome、来源政策或公开层边界时，才重新进入 Architecture 审查。

