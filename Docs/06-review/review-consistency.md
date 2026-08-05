# Cross-Layer Consistency Review

| Contract | Current result | Issue/backtrace |
|---|---|---|
| Product managed Wine -> Runtime manager | Consistent | system detection/fallback absent; Deferred not counted as defect |
| Product source allowlist -> catalog/downloader | Mostly consistent | official source and mirror empty; real network pending; P1-UV-002 |
| Source asset -> HTTP/Domain error | Inconsistent | asset status erased to string; P1-REV-005 -> Implementation |
| Product metadata evidence -> VersionChecker | Consistent | raw config retained, pkg mapping/size/MD5 and conflict semantics tested |
| GameLocation -> five bookmark consumers | Consistent | stale/writeback/revoked semantics tested; real permission pending |
| WineReady -> Settings/PreLaunch | Consistent | no game context is prefixNotReady; launch uses same managed runtime |
| TaskReceipt -> persistence/event projection | Consistent | persist/read-back before actor state/event; recovery prevents false success |
| Wine staging -> cleanup | Consistent | managed root, symlink, traversal and idempotent cleanup tests |
| Per-game settings/background -> persistence | Consistent | isolation and failed group switch rollback tests |
| UI -> Accessibility tree | Static consistent | dynamic Apple runtime evidence absent; P1-08 |
| Implementation/QA docs -> current evidence | Inconsistent | old QA counters/Pass wording; P2-05/DOC-REV-001 |

## Responsibility Boundaries

- UI invokes ViewModel actions; TaskScheduler owns task execution and terminal facts.
- Domain owns status/error mapping; Infrastructure owns URLSession, file I/O, Process and logging primitives.
- `BackgroundMediaService` uses an internal raw destination path only for MiPlay-owned media cache. This is distinct from user-selected game authorization and does not close or reopen P1-02.
- Compatibility helper/XPC is Deferred and intentionally fails before side effects; it is not an Implementation defect.

