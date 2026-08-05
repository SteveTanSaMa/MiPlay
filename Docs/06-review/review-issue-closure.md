# Issue Closure Matrix

> 日期：2026-08-04；状态只表示当前 Review 证据，不继承旧 `review-conclusion.md`。

| ID | 严重度 | 状态 | 代码证据 | 测试/运行证据 | Owner / 下一步 |
|---|---|---|---|---|---|
| P1-REV-003 | P1 | Closed | 退出提交失败进入 recovery fact；重启把未确认 Running 转为保守失败；guard retry 不重启 | `MiPlayCoreTests.swift:1136-1383`，Debug/Release 62/62 | User Validation 复测真实进程 |
| P1-REV-004 | P1 | Closed | stale refresh 统一写回；scope 在 operation 期间保持，失败不回退 lastKnownPath | `MiPlayCoreTests.swift:1385-1715` 覆盖五类消费者 | User Validation 真实 stale bookmark |
| P1-02 | P1 | Closed | 游戏 public API 接受 `Game`/`GameLocation`；裸 path 入口 internal；Wine/extract seam 需 managed identity | migration、bookmark、managed staging tests | 保持边界；Signed Sandbox 外部验证 |
| P1-04 | P1 | Closed | Runtime binary + managed record + game-specific prefix `drive_c` 才 ready；Settings 无 game 不返回 ready | `testWineReadinessRequiresGameSpecificPrefixBeforeWineReady` | User Validation 真实 Wine/wineboot |
| P1-07 | P1 | Closed | canonical `.staging` root、archive boundary、symlink/tree/cleanup checks | staging outside/symlink/archive tests | Signed Sandbox cleanup smoke |
| P1-REV-005 | P1 | Open | asset non-2xx `DownloadProgress.error` 是 String；Wine phase/error/log 映射为 `networkUnavailable` | 没有 asset 403/404/429/5xx tests；只有 catalog statuses | Implementation：类型化 status、补 test matrix、确认 cleanup/recovery |
| P1-08 | P1 | External Blocked | static labels/values/hints 和 task projection 存在 | 无 signed App、AX Inspector、VoiceOver global trace 或动态状态证据 | UI + Apple Review/User Validation |
| P1-UV-001 | P1 | Closed (code boundary) | 未发现 system Wine/Whisky/CrossOver detection/fallback；只有 managed tags | static scan + managed runtime tests | 不把 Deferred/外部 Wine 当缺陷 |
| P1-UV-002 | P1 | Conditional External | official GitHub source，mirror allowlist 空；无任意 URL | MockURLProtocol catalog/redirect/size fixtures；无真实 network bundle | User Validation 真实 API/asset/302/失败场景 |
| P1-UV-003 | P1 | Closed | raw config fields、pkg size/MD5、manifest mapping/conflict semantics | `MiPlayCoreTests.swift:431-561` | 不新增未证实字段含义 |
| P1-UV-006 | P1 | External Blocked | game card/progress/error recovery 有静态 AX tree projection | 无动态 VoiceOver/keyboard/AX runtime evidence | UI + Apple Review/User Validation |
| P2-01 | P2 | Conditional | `ENABLE_APP_SANDBOX=YES`、outgoing network、read-only user-selected files；其他资源权限关闭 | adhoc build only | Signed entitlements dump and runtime permission test |
| P2-02 | P2 | Closed | cancellation waits through URLSession/producer/cleanup；failure preserves recoveryRequired | Debug/Release 62/62; focused cancellation test | Repeat under signed/real network |
| P2-03 | P2 | Closed | Settings preserves readiness error variants; task event projection preserves failed/cancelled/recovery | `testSettingsWineStatusPreservesReadinessSemantics` plus manager gate test | Real Wine state smoke |
| P2-04 | P2 | Conditional | Primary button 220x64, rail 64x64, Settings 800x448, centering positioner | static/limited UI observation; no full screenshot matrix | UI User Validation |
| P2-LOG-001 | P2 | Conditional | 111 structured record sites; 50 legacy sites redact by discarding prose but lose diagnostics | Log sanitize/flush/rotation/export tests pass | Implementation convert remaining terminal events |
| P2-05 / DOC-REV-001 | P2 | Open | current Review docs are synchronized; upstream QA still has old counters/Pass language | `Docs/08-qa/*` remains frozen historical input | Implementation/QA sync docs before Release |

## Gate Result

P0=0。P1-REV-005 prevents an overall Pass. P1-08 and P1-UV-002 are explicit external conditions, not hidden passes. Deferred compatibility helper and system-level modification helper are not defects because they are outside the current Product scope and are intentionally rejected before side effects.

