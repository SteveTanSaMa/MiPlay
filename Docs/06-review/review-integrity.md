# Pipeline Integrity

> 当前 Review 依据 Product/Architecture 冻结链、源码和当前 62/62 结果；旧 Review 结论不覆盖当前证据。

| Pipeline link | 状态 | 当前证据 |
|---|---|---|
| Product -> managed Wine only | Pass (code boundary) | 无 system Wine/Whisky/CrossOver detection/fallback；`validatedRuntime` 只返回 managed identity |
| Product -> source policy | Conditional External | official GitHub 与空 mirror allowlist；真实 source/API/asset 仍待用户验证 |
| Research -> metadata evidence | Pass | raw config fields、pkg size/MD5、manifest mapping/conflict tests |
| UX -> bookmark failure semantics | Pass | GameLocation scope/writeback/revoked tests；真实 NSOpenPanel 待验证 |
| UX -> WineReady | Pass (code/test) | binary/runtime + game-specific prefix gate；Settings 无 game 不返回 ready |
| UI -> ViewModel -> TaskScheduler | Pass | UI 通过 ViewModel 投影 task progress/terminal/recovery；未发现 UI 直接编排业务副作用 |
| Architecture -> TaskReceipt | Pass | pending commit/read-back 后才返回 receipt；resource lock 和 recovery-held lock 保留 |
| Architecture -> asset errors | **Broken, P1-REV-005** | non-2xx 被拒绝但 status 在 Network->Wine Domain 之间变成 plain string |
| Architecture -> managed staging | Pass | `ManagedStaging`、archive/tree/symlink/cleanup root tests |
| Implementation -> QA/docs | **Broken, P2-05** | QA 冻结文档仍含旧计数/Pass 口径；本目录已同步当前 Review 事实 |
| UI -> Apple runtime | External Blocked | 静态 AX surface 和有限观察存在；无完整 Apple 动态证据 |

## Feature Traceability

| Feature | Implementation | Automated evidence | Remaining boundary |
|---|---|---|---|
| Wine release discovery/download | WineVersionManager/Downloader/Network | catalog, redirect, size, staging and cancellation fixtures | P1-REV-005 asset status; real GitHub |
| Game authorization | GameLocation/GameFileSystemRepository/Registry | stale/revoked/writeback consumers | signed Sandbox + real bookmark |
| Launch lifecycle | ProcessManager/LaunchOrchestrator/Registry | process and persistence recovery tests | real Wine/game |
| Metadata | VersionChecker/FileIntegrityVerifier | config/pkg/manifest conflict tests | source-specific real files |
| Task state | TaskScheduler/ViewModels | receipt, progress, terminal, recovery tests | real UI runtime |
| Background groups/settings | BackgroundMedia/Performance/Settings | per-game and rollback tests | visual/manual verification |
| Logs | LogWriter + critical domain event sites | sanitize/flush/export/rotation tests | legacy coverage cleanup |

