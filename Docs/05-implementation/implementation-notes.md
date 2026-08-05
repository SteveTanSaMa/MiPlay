# MiPlay Implementation Notes

> Implementation Agent report for the frozen architecture contracts.
> Source: Architecture Design -> implementation traceability

## Phase 6 Closure Status

| Issue | Current implementation and evidence | Boundary |
|---|---|---|
| P1-REV-003 | `GameRegistry` writes an independent `RecoveryGuard.<id>.json` when the AppData commit cannot be made, detects it after restart, blocks a new launch, and retries idempotently. A guard-only retry now appends a resolved recovery record to AppData, verifies the state and record after reread, and clears the guard last. | If both AppData and the independent guard location are genuinely unavailable, the process cannot create a durable fact; the app retains an in-memory recovery result and reports `recoveryRequired`. It never claims convergence. |
| P1-REV-004 | `GameLocation` is the only Domain resolution result. Stale refresh, scope start/stop pairing, writeback success, writeback failure, and no-`lastKnownPath` fallback are covered across Registry, integrity, version, preflight, and launch paths with injected resolver fixtures. Consumers do not publish a result until refreshed authorization is committed. | Resolver fixtures verify the contract without manufacturing platform bookmark bytes. A real stale bookmark requires a user-selected security-scoped URL. |
| P1-UV-003 | `pkg_version` is parsed as JSON Lines and all approved `remoteName`, `fileSize`, and `md5` fields are retained in `LocalEvidence`; `[General]` reads only the approved `config.ini` fields. Manifest, channel, local-version, remote-version, and unmapped-pkg evidence conflicts return `versionEvidenceConflict` without publishing a current/update result. | `pkg_version` and `config.ini` remain evidence, not an integrity or official-version substitute. No approved pkg-to-manifest mapping is present, so an unmapped pkg source is deliberately non-successful. |
| P1-02 | Production Domain callers use `GameLocation` and keep its security-scoped lease active. Path-only infrastructure seams are `internal` and are limited to tests/migration; no bare path is an authorization credential. | A real user-selected bookmark and signed Sandbox runtime still require user validation. |
| P1-04 | Wine readiness requires a managed installed record, approved source, executable binary, readable runtime, and a game-specific prefix with `drive_c`; Settings without a game context remains non-ready. | Prefix creation and real Wine execution require the external Wine artifact and a user-selected game. |
| P1-07 | `ManagedStaging` permits only canonical children of `WineVersions/.staging`; archive traversal, symlink escape, and cleanup escape are rejected. Cancellation and failure cleanup are idempotent across concurrent owners and preserve `recoveryRequired` for real failures. | Filesystem fixtures cover boundaries; a signed Sandbox build is still required for distribution validation. |
| P2-02 | Debug and Release arm64 cancellation matrix passes. URLSession cancellation, extraction cancellation, managed staging cleanup, and `cleanupVerified` are now deterministic; an actual cleanup failure remains `recoveryRequired`. | Tests use mock URLSession and temporary managed staging, not a real Release-signed network run. |
| P2-03 | Settings preserves `.notSelected`, `.notDownloaded`, `.prefixNotReady`, and `.error` instead of flattening readiness to `.notInstalled`; task events retain failed/cancelled/recovery states. | Real runtime and prefix states remain unavailable until a managed Wine artifact and game are supplied. |
| P2-05 | This document reports the current 68-test Debug/Release result and separates unsigned build evidence from distribution signing evidence. | Review, QA, and Release agents must retain their own frozen status and external validation gates. |
| P1-REV-005 | Release asset HTTP failures retain typed 403/404/429/5xx semantics from URLSession through Wine download phases and Scheduler terminal errors. API metadata errors remain API-specific; asset failures cannot publish an installed result. | Mock HTTP fixtures cover asset 403, 404, 429, 503, API/asset separation, secure status logging, and Scheduler failed persistence. Real GitHub responses remain external validation. |
| P2-06 | The project still sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for the application configurations. This implementation pass does not change the frozen architecture concurrency semantics. | Architecture review is required before changing the default isolation setting; no implementation-only reinterpretation is claimed. |

The current implementation closes the code-level P1 findings above. This is not a release approval: the user-validation and external-resource gates remain separate.

## Full Source File Split

This maintenance pass changes file organization only. Public symbols, actor isolation,
dependency injection, task state transitions, error/log semantics, persistence behavior,
and UI behavior remain unchanged. Cross-file implementation helpers are module-internal
where Swift requires a same-file `private` member to be shared by an extension; no new
external API was introduced.

| Original file | Before | Resulting responsibility files |
|---|---:|---|
| `Infrastructure/Wine/WineVersionDownloader.swift` | 1388 | `WineVersionDownloader.swift` (contract/catalog), `WineVersionDownloaderDownload.swift` (transfer/progress), `WineVersionDownloaderExtraction.swift` (cancel/extract), `WineVersionDownloaderFlow.swift` (lifecycle), `WineVersionDownloaderValidation.swift` (allowlist/staging cleanup); max 480 lines. |
| `Domain/Runtime/WineVersionManager.swift` | 1133 | `WineVersionManager.swift` (state/init), `WineVersionManagerCatalog.swift` (catalog/source), `WineVersionManagerReadiness.swift` (runtime/prefix gate), `WineVersionManagerInstalled.swift` (installed records), `WineVersionManagerDownload.swift` (download/recovery), `WineVersionModels.swift` (public models); max 328 lines. |
| `Domain/Game/GameRegistry.swift` | 1051 | `GameRegistry.swift` (actor/init), `GameRegistryLocation.swift` (authorized locations), `GameRegistryState.swift` (business facts), `GameRegistryModels.swift` (domain values); max 404 lines. |
| `Domain/Media/BackgroundMediaService.swift` | 817 | `BackgroundMediaService.swift` (state/init), `BackgroundMediaServiceModes.swift` (mode/loading), `BackgroundMediaServiceCache.swift` (cache), `BackgroundMediaModels.swift` (HoyoPlay contracts); max 449 lines. |
| `Domain/TaskScheduler/TaskScheduler.swift` | 803 | `TaskScheduler.swift` (actor/init), `TaskSchedulerScheduling.swift` (queue/execution), `TaskSchedulerPersistence.swift` (resources/commit/recovery), with existing `TaskSchedulerModels.swift`; max 377 lines for the actor file. |
| `Infrastructure/Process/ProcessManager.swift` | 653 | `ProcessManager.swift` (launch/contracts), `ProcessManagerWaiting.swift` (wait/termination requests), `ProcessManagerCompletion.swift` (completion/output); max 296 lines. |
| `Domain/Update/VersionChecker.swift` | 617 | `VersionChecker.swift` (authorized evidence comparison), `VersionCheckerModels.swift` (evidence/result contracts); max 455 lines. |
| `Infrastructure/Log/LogWriter.swift` | 566 | `LogWriter.swift` (actor storage/flush/export), `LogWriterModels.swift` (event/receipt/error contracts); max 479 lines. |
| `UI/ViewModels/LibraryViewModel.swift` | 543 | `LibraryViewModel.swift` (state/actions), `LibraryViewModelModels.swift` (action/progress contracts), `LibraryViewModelPresentation.swift` (derived overlay state); max 498 lines. |
| `UI/ViewModels/SettingsViewModel.swift` | 520 | `SettingsViewModel.swift` (settings/task projection), `SettingsViewModelModels.swift` (Wine/about contracts); max 478 lines. |
| `Infrastructure/Persistence/PersistenceStore.swift` | 504 | `PersistenceStore.swift` (JSON/atomic recovery), `PersistenceStoreModels.swift` (load/recovery/error contracts); max 459 lines. |
| `MiPlayTests/MiPlayCoreTests.swift` | 2651 | `ProcessAndLoggingTests.swift`, `PersistenceMetadataTests.swift`, `WineNetworkTests.swift`, `GameDomainTests.swift`, `SchedulerRecoveryTests.swift`, `BookmarkLaunchTests.swift`, `WineSchedulerTests.swift`, `UIReadinessTests.swift`, and `TestSupport.swift`; max 431 lines. `MiPlayCoreTests.swift` remains the 4-line XCTest discovery anchor. |

All files under `MiPlay/**/*.swift` and `MiPlayTests/**/*.swift` were recounted with
`wc -l`; the maximum is 498 and no file exceeds 500 lines. The MiPlay target uses
`PBXFileSystemSynchronizedRootGroup`, so production split files are automatic members.
The explicit MiPlayTests target now has PBXFileReference, PBXBuildFile, group-child, and
Sources-phase entries for all nine added test files. `xcodebuild -list` reports both
`MiPlay` and `MiPlayTests` targets.

## Implemented P0/P1 Paths

| Area | Implemented behavior |
|---|---|
| ProcessManager | Actor-owned process table, one completion path, concurrent stdout/stderr collection, timeout termination, SIGKILL fallback, cancellation, and termination confirmation. |
| Wine launch | `Process.executableURL` is the selected Wine binary; the game executable is an argument. `WINEPREFIX` and DLL override environment values are injected. `wineboot -u` is verified by checking `drive_c`. |
| Scoped authorization | User-selected directories are represented by security-scoped bookmarks. Stale bookmarks are refreshed. Launch keeps the scope alive until process exit or confirmed cleanup. Legacy path-only records remain `migrationRequired` and are never used as authorization. |
| Launch state | `Launching` is committed before side effects, `Running` and launch time are committed only after `waitUntilRunning`, and persistence or cleanup failures return explicit failure/recovery results. |
| Integrity | Versioned JSON manifests are loaded from `IntegrityManifests` or injected test fixtures. The manifest game and version must match the known game fact, and every manifest entry is hashed. Missing or unverifiable manifest returns `IntegrityUnsupported`; file existence alone never passes. |
| Version check | Local version is read from the authorized install directory and compared with an injected or configured remote manifest. Missing remote configuration is an explicit error. No update is performed. |
| Task scheduling | Launch, integrity, version, solution apply, and solution revert call their Domain services. Resource conflicts remain `pending`; only invalid requests are rejected. Task phase, outcome, errors, recovery, start/end times and progress are persisted and emitted through streams. |
| Wine task lifecycle | Wine downloads use one `TaskReceipt` and the `wineRuntime` resource key. A download, install, and persistence commit are separate facts. URLSession, extraction, cancellation, staging cleanup, interrupted-task recovery, and retry/recovery-required states are propagated through Scheduler events. Settings consumes the same event and progress streams. |
| Task recovery | Pending/running records from a previous process are converted to interrupted failures and the repaired result is written back. If that write fails, a `recoveryRequired` event is emitted. No side-effect task is replayed automatically. |
| Exit and bookmark recovery | Process termination is recorded separately from the final game state. Registry/persistence failures retain a retryable recovery fact and never leave an unexplained `Running` projection. Every domain location consumer resolves the bookmark through `GameLocation`; stale bookmark refreshes are written back immediately, while write failure or revoked authorization returns an explicit migration/recovery state. |
| UI contract | Game and Settings entries are standard `Button` controls with stable `64pt` hit frames, fixed `56pt` glass, `12pt` rail spacing, glyph-only hover/selection transforms, a fixed `220 x 64pt` primary action, task/recovery accessibility semantics, and Settings-window centering clamped to `visibleFrame`. |
| AppData | Schema checking, legacy migration, `.bak` creation, corruption diagnostics, backup restore, atomic replacement and post-write decode verification are implemented. Corrupt input is copied to a unique diagnostic file and is never replaced with defaults. |
| ViewModels | Library and detail view models consume ordered scheduler events. Progress is optional and reflects real phases; no fixed percentage is used. |
| Structured diagnostics | `LogWriter` is the single structured event boundary. App initialization, bookmark/scope/writeback, Wine catalog/API/HTTP/download/cancel/verify/extract/cleanup/readiness, scheduler receipt/resource/recovery, process lifecycle, metadata evidence, persistence and background-media transitions carry operation/task/game context. Events are sanitized before OSLog, memory, file flush and export. Flush retains uncommitted batches on failure; export flushes first and returns only redacted JSONL. |
| XCTest | `MiPlayTests` covers process output/exit/timeout/cancellation, duplicate waiter rejection, AppData corruption/backup/migration, manifest verification/version matching, version comparison, metadata evidence conflicts, Wine receipt/resource conflict, API 403/429, asset 403/404/429/5xx, non-HTTP and missing download responses, asset allowlist and unapproved redirect rejection, cancellation and staging cleanup, interrupted-task recovery, process-exit recovery after persistence failure, Wine persistence-failure retry, per-game settings isolation, and background-group selection rollback. |

## Intentional Runtime Refusals

These are explicit capability failures, not success stubs:

1. The repository has no production `IntegrityManifests/*.json`; real game launch and integrity verification therefore return `IntegrityUnsupported`.
2. The repository has no signed system-modification helper/XPC service and no trusted replacement DLL resources. Published compatibility solutions remain visible for diagnostics, but `SolutionEngine` refuses before side effects and never returns `Applied`.
3. No production remote version manifest URL is configured. Version checks fail with `apiUnavailable` unless a configured manifest or test fixture is supplied.
4. A real Wine distribution and real game installation were not available for this verification run. The process chain is wired for them, but no game launch is claimed successful without those resources.
5. No system Wine, Whisky, CrossOver installation, or user-supplied runtime path is detected, imported, selected, or used. Only a MiPlay-managed Wine artifact that passes the source and installation gates can be used; no unapproved GitHub mirror is an implicit fallback.

## Task 4 Logging Evidence

- Wine download and install events now retain the approved `wineTag` through download, response, verification, extraction, cancellation and installation commit.
- Cancellation publishes `cancelled` only after cleanup is confirmed. A cleanup failure publishes `recoveryRequired` with `cancellationUnconfirmed` and `cleanupVerified=false`; the manager applies the same rule to staging and final-install cleanup.
- Disk preflight, missing HTTP response, rejected redirect, integrity cleanup, archive cleanup and extraction cleanup failures each have a structured terminal event. Sensitive paths and URLs remain outside event fields and are redacted by the LogWriter boundary.
- Legacy logging calls are retained only as compatibility shims: their localized message/details are discarded before the event reaches OSLog, memory, file flush or export. Critical download, extraction, background API and media-transcode paths use stable structured message codes instead of interpolated paths or URLs.
- Log rotation strictly retains `miplay.log` plus three backups. Flush failures keep the uncommitted actor batch for retry; the failure fixture verifies that a directory write failure cannot silently discard the batch.
- [`log-export-sample.jsonl`](./log-export-sample.jsonl) is a safe export example. It contains no token, bookmark data, user path, command, stdout/stderr or query-bearing URL.

## Known Platform Limits

- The application uses App Sandbox with user-selected read-only file access. A game directory must be selected by the user and represented by a valid bookmark. Stale refresh and persistence write-back are covered by injected resolver fixtures; consumers are gated on the committed location.
- Path-based infrastructure entry points used by tests and legacy migration are module-internal. Production Domain callers resolve `GameLocation` and keep its scope active before passing a derived path to infrastructure; a bare path is not a user authorization credential.
- System paths such as `/etc/hosts` and `/etc/hostname` are outside the game bookmark. They are not modified from the app process.
- Applying system-level compatibility changes requires a signed, reviewed helper with a narrow protocol and user approval. Adding one is an Architecture/Infrastructure change, not an implementation fallback.
- Manifest and trusted patch assets must come from the release resource pipeline. They must not be fabricated from the current executable or downloaded without an integrity contract.

## Verification

Executed on the local arm64 Mac with Xcode 27 beta and macOS deployment target 26:

```text
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -sdk macosx -configuration Debug -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
** BUILD SUCCEEDED **

xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -sdk macosx -configuration Release -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
** BUILD SUCCEEDED **

xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
Executed 68 tests, with 0 failures
** TEST SUCCEEDED **

xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Release -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
Executed 68 tests, with 0 failures
** TEST SUCCEEDED **

The focused Phase 6 tests include restart recovery after AppData failure, guard-only retry, stale bookmark refresh/writeback failure, revoked-access and reauthorization state transitions, scope pairing, manifest/config/pkg evidence conflicts, Wine API and asset HTTP error separation (403/404/429/5xx), Wine cancellation/cleanup, managed staging traversal and symlink rejection, non-HTTP and missing download responses, unapproved redirect rejection, prefix readiness, Settings readiness projection, structured log sanitization/legacy-text isolation/flush retry/export/rotation and the Wine-binary launch fixture. No Swift 6 correctness warnings were emitted; the Release build still reports the platform `CC_MD5` deprecation described below.
```

The Swift implementation has no Swift 6 correctness warnings. The Release build emits the platform SDK deprecation warning for CommonCrypto `CC_MD5`; MD5 remains required here because `pkg_version` declares MD5 and the value is treated only as source evidence, while the integrity manifest path uses SHA-256. Xcode may also print environment/toolchain messages from AppIntents and system services during tests. A real Wine/game launch remains unverified because the required external resources are absent; it is deliberately reported as unavailable rather than downgraded to a false success.

The Release verification above is an unsigned arm64 build/test run. No distribution signature, notarization, or production Sandbox entitlement validation is claimed. The project contains no incoming-network or Bluetooth entitlement; the network capability used by the product remains limited to outgoing URLSession requests. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` remains an Architecture follow-up, not a hidden implementation change.

## Traceability

- `ProcessManager.swift`: Architecture Service Contract / ADR 003.
- `GameFileSystemRepository.swift`, `GameLocation.swift`: bookmark communication / ADR 004.
- `LaunchOrchestrator.swift`: launch confirmation / ADR 007.
- `TaskScheduler.swift`: task queue / ADR 008.
- `PersistenceStore.swift`, `AppData.swift`: recovery and atomic persistence / ADR 009.
- `SolutionEngine.swift`: backup/apply/rollback boundary / ADR 010.
- `FileIntegrityVerifier.swift`: manifest-based integrity result contract.
- `VersionChecker.swift`: VersionCheck task contract.
- `MiPlayTests/ProcessAndLoggingTests.swift`, `PersistenceMetadataTests.swift`, `WineNetworkTests.swift`, `GameDomainTests.swift`, `SchedulerRecoveryTests.swift`, `BookmarkLaunchTests.swift`, `WineSchedulerTests.swift`, `UIReadinessTests.swift`, and `TestSupport.swift`: split XCTest coverage and shared fixtures; `MiPlayCoreTests.swift` remains the XCTest discovery anchor.
