# Current Capability Table

| Capability | Status | Evidence | Limitation |
|---|---|---|---|
| Process lifecycle | Code/Test Pass | actor, output drain, timeout, cancel, termination and 62/62 tests | no real Wine/game |
| Process exit persistence recovery | Closed | recovery record, restart reconcile, durable guard, retry tests | real forced exit pending |
| Security-scoped bookmarks | Code/Test Pass | stale refresh, paired scope, revoked access, writeback failure tests | signed Sandbox/real bookmark pending |
| Raw path authorization | Closed for production game/Wine boundary | public Game APIs require GameLocation; path seams internal/managed | app-owned media cache raw seam remains separate |
| Wine source policy | Conditional External | official GitHub, empty mirror allowlist, no arbitrary URL | real network pending |
| Wine release API discovery | Code/Test Pass | typed API 403/404/429 mapping, asset identity validation | no real API result |
| Wine asset download | Conditional | progress, response, redirect, expected size, cleanup | P1-REV-005 asset status typing/tests |
| WineReady | Code/Test Pass | managed binary/version + per-game `drive_c` gate | real Wine/wineboot pending |
| Wine extraction/delete safety | Code/Test Pass | managed staging, traversal/symlink/tree and delete root guard | signed Sandbox pending |
| TaskReceipt/resource lock | Code/Test Pass | durable receipt, `wineRuntime` conflict, recovery lock | real UI pending |
| Settings readiness projection | Closed for code/test | no flattening of notSelected/notDownloaded/prefix/error | real runtime states pending |
| Metadata evidence | Code/Test Pass | config raw fields; pkg size/MD5/manifest mapping/conflict | real game files pending |
| Per-game settings/background | Code/Test Pass | persistence isolation and failed switch rollback | manual visual pending |
| Structured logging | Conditional | actor, allowlist, sanitization, flush, rotation, export, 111 record sites | 50 legacy calls lose details |
| Accessibility | Partial/External Blocked | static AX labels/values/hints and task projection | P1-08 real Apple evidence |
| Entitlements | Conditional | sandbox/outgoing network/read-only selected files flags | no signed entitlements validation |

