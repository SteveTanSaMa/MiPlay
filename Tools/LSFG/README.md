# LSFG integration

**Status: initial integration complete; experimental and still under debugging.**
Real-game throughput remains under investigation, and rapid camera movement
at 4x can still produce visible distortion. The direct Metal compute backend
is not connected to production game presentation.

Normal MiPlay builds use the checked-in `RuntimeAssets/lsfg` snapshot and do
not require sibling repositories. Its manifest identifies local modifications;
those changes have not yet been published to the independent LSFG repository,
so the remote commit alone cannot reproduce this exact binary snapshot.

MiPlay uses the sibling `MiPlay LSFG` fork of
<https://github.com/namo-2938/lsfg-metal>. Wine remains x86_64 under Rosetta;
the MiPlay UI remains Apple Silicon native. DXMT is unchanged.

## Rebuild and package the component

1. In the LSFG fork, run `Scripts/package-miplay.sh`.
2. In MiPlay App, run `python3 Tools/LSFG/stage_resources.py`. A fresh checkout
   can supply the official MoltenVK 1.4.2 universal dylib and its license using
   `--driver /absolute/path/libMoltenVK.dylib --driver-license /absolute/path/LICENSE`;
   the script checks the pinned driver hash before packaging.
3. Build MiPlay normally. `RuntimeAssets/lsfg` is copied into its resources.

The component manifest verifies the shim, preflight tools and a separate,
pinned MoltenVK 1.4.2 generator. The package excludes `lsfg-vk.dll` and all
derived commercial shader output. Import a user's own DLL through game settings.
Imported packages live under MiPlay Application Support, keyed by SHA-256; the
selection changes atomically and old packages remain valid for active sessions.

## Launch contract

- `PerGameSettings.lsfg` defaults off, including older saved libraries.
- Pending per-game settings writes are completed before the launch reads its
  configuration, including an immediate launch after switching the option off.
- Frame selection uses `adaptive`: the multiplier is a cap and the target FPS
  is a slot-budget reference, not a physical refresh-rate change or hard FPS
  limiter. Auto uses the upstream main-screen maximum refresh estimate.
  Synchronized LSFG presentation remains enabled independently of game VSync;
  unsynchronized bursts discarded substantially more generated drawables in
  the real Wine/DXMT A/B fixture. Existing user quality preferences are retained.
- Off removes inherited `LSFGM_*`, `MIPLAY_LSFG_*` and `DYLD_*` injection.
- LaunchServices overlays environment values. A filtered Swift dictionary alone
  cannot remove Xcode's inherited Metal validation. ApplicationLauncher always
  sends an explicit `MIPLAY_ALLOWED_RUNTIME_VARIABLES` list (including empty).
  GameLauncher unsets unlisted Metal/dyld/LSFG keys before reading the LSFG relay
  or forking Wine, then removes the list itself. Explicit HUD and the validated
  LSFG plan survive; direct ProcessManager launches use a complete filtered
  environment and discard any inherited allowlist.
- Enabled launches verify component and shader bytes and run a fresh bounded
  shader/GPU preflight before spawning Wine. A failed preflight is reported;
  it does not silently claim the requested frame generation is active.
- The universal GameLauncher receives `MIPLAY_LSFG_LIBRARY`. Only its Wine
  child sets `DYLD_INSERT_LIBRARIES`, just before `execv`. The parent launcher
  and the `wineserver -w` waiter are not injected. Direct Wine fallback uses
  the same plan with direct injection.
- LaunchServices can return the registered Wine child's PID. A per-session
  token/PID/process-group handshake identifies the supervising GameLauncher;
  it starts Wine only after MiPlay accepts that receipt. Exit tracking and
  termination therefore cover the helper and its Wine session, and a failed
  handshake cannot silently leave a second game running during fallback.
- `LSFGM_MOLTENVK` forwards Wine Vulkan queries to its existing driver;
  `LSFGM_GENERATOR_MOLTENVK` selects the private generation driver. Wine's
  game driver is not replaced. The user's selected game locale is preserved
  through the existing managed Wine locale policy.
- Session logs are under `MiPlay/LSFG/Logs`. `prepared` means preflight passed
  and generation was requested. `LSFGM_METAL_STATS` reports separate submitted
  and valid presentation callbacks; only positive `generated_displayed` is
  evidence of generated frame presentation. Neither counter measures physical
  scanout or input-to-photon latency.
- `LSFGM_LATENCY=1` records queue/worker/drawable/presentation batch p50/p95.
  The packaged component attaches its submission timestamp after GPU-copy
  confirmation, so that wait is correctly charged to worker time. These are
  presentation diagnostics, not measurements of game input latency.
  `drawable_request_display`, `acquire_wait` and `pre_enqueue` additionally
  cover the nextDrawable hook before enqueue, so moving backpressure earlier
  cannot masquerade as lower full-chain latency. Acquisition failures that
  fall back to a native drawable are outside these samples.
  `producer_wait`, `prior_copy_wait` and `copy_wait` split out CPU waits for
  renderer readiness, the previous source fence, and this source's accumulated
  copy completions. Each output retains its own snapshot. These are components
  of worker time, not additional latency or shader GPU execution durations.

## Synthetic Wine + DXMT test

Run `python3 Tools/LSFG/test_wine.py --help` for resource overrides. The default
matrix covers direct/helper entry and off/2x. It compiles a small D3D11 moving
square fixture, clones Wine into `/tmp`, prepares a new prefix and copies the
current bundled DXMT into that clone. It never starts a real game. Source
frames, loaded bridge identity, generated presentation callbacks and dumped
intermediate pixels are checked independently. The watchdog terminates only
the test's own process group and explicitly selected private prefix.
Use `--modes all` to include 3x/4x, or `--performance --flow-scale 0.5`
to exercise reduced-cost generation. Keep separate output roots when retaining
results: rerunning a case clears its prior logs and diagnostic images.

Normal XCTest coverage uses fake resources and tool runners. Real GPU/Wine
acceptance is opt-in; ordinary project tests do not inject the user's games.
The `testLiveLSFGWineDXMTLaunchServices` XCTest additionally exercises the
production NSWorkspace entry using the marked synthetic root prepared above:

```sh
TEST_RUNNER_MIPLAY_LSFG_FIXTURE_ROOT=/tmp/MiPlay-LSFG-Wine-test \
TEST_RUNNER_MIPLAY_LSFG_SHADER_DLL='/absolute/path/to/lsfg-vk.dll' \
xcodebuild test -project MiPlay.xcodeproj -scheme MiPlay \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:MiPlayTests/MiPlayCoreTests/testLiveLSFGWineDXMTLaunchServices
```

Presentation acceptance needs a visible desktop/window. The opt-in XCTest
requests the synthetic fixture's temporary foreground/topmost mode so the
test host cannot cover it; the production launcher does not force game windows
to stay on top. A submitted drawable
with zero `presentedTime` is counted as invalid, never as a displayed frame.
These small synthetic tests do not establish game stability, visual quality
across all scenes, input latency, or performance at game resolution.

## Direct Metal work

The current production component computes through a private Vulkan device.
The fork now contains a feature-gated `native-metal` validation prototype. It
reuses the shader resource parser and Signature schedule and translates SPIR-V
with pinned SPIRV-Cross. The final 2026-11-05 native CLI produced byte-identical
RGBA output against Vulkan in 21 fixed-input SDR 2x comparisons, including
317x179 and 1920x1080. Five static-input checks still fail their stricter
source-drift thresholds identically in both backends; that baseline issue is
retained in the reports, not counted as a new backend difference.
It is not connected to the game's presentation worker/IOSurface lifetime and
is not included in MiPlay's default runtime component. See the fork's
`Docs/native-metal-prototype-2026-11-05.md` for commands and remaining gates.
MetalFrame's local research is architectural evidence, not an interchangeable
source release or a substitute for output/performance validation.

## Integration acceptance (2026-11-05)

On this Apple Silicon host, using an isolated Wine 11.0-1 clone and current
bundled DXMT:

- Direct Wine and universal helper: off/2x passed source-frame completion,
  loaded DXMT identity, presentation callbacks and intermediate-pixel checks.
- Helper: off/2x/3x/4x and 2x performance mode with 50% flow passed.
- Production NSWorkspace entry: off/2x passed after the helper-PID handshake
  fix. The enabled case completed 240 source frames and recorded 237 original
  and 238 generated valid display callbacks at its last sample.
- Final MiPlay regression suite: 329 tests, 322 passed and 7 opt-in tests
  skipped, zero failures. The cancellation fixture waits for its child readiness
  marker before testing cancellation of a running child; an earlier cancellation
  is allowed to prevent that child from executing at all.

Evidence roots are `/tmp/MiPlay-LSFG-Wine-matrix-fixed-20261105`,
`/tmp/MiPlay-LSFG-Wine-multipliers-20261105`, and
`/tmp/MiPlay-LSFG-Wine-performance-20261105`. The final NSWorkspace result is
`/tmp/MiPlay-LSFG-LaunchServices-Visible.xcresult`.
The complete project result is `/tmp/MiPlay-LSFG-Final-Verified.xcresult`.
Actual Genshin/Star Rail/ZZZ sessions have not been certified with LSFG by this
synthetic acceptance run.

## Real-game feedback and pacing correction (2026-11-05)

Subsequent user Genshin tests at 3456x2234, quality mode, 100% flow and auto
refresh reported off ~40 FPS, 2x ~50 and 4x ~55 on Metal HUD, with extra latency
and 4x distortion. The three session logs confirm source samples near 24–26
FPS at 2x and 14 FPS at 4x; generated presentation callbacks were mostly valid.
This is a source-rate/latency problem, not evidence that the multiplier failed
to request its intermediate frames. The logs did not yet contain latency
measurements, and these were not controlled same-scene benchmarks.

Changes after this feedback:

- Use adaptive selection instead of fixed multiplier slots. Name the settings
  “倍率上限” and “目标帧率”, and document independent LSFG display synchronization.
- Fix a Pacer boundary: 40-source/60-target with a 2x cap formerly rounded the
  ratio 1.5 to the cap and always selected 2 slots. Caps 2/3/4 now preserve
  fractional budgets below the cap; integer snapping and true saturation remain.
- Enable accurate latency diagnostics. Copy-completion waiting belongs to
  worker time, not time after submitting a presentation.
- Keep synchronized presentation. Merely disabling it is not a validated
  general low-latency solution: the high-resolution synthetic case had only
  108 valid generated callbacks from 168 submissions with it disabled.

An isolated 640x360 Wine/DXMT test with a 40 FPS source limit, target 60 and cap
4 compared steady-state samples. Fixed synchronized presentation sustained
about 29–30 source FPS and generated enqueue-to-display p50 ~82.6 ms; adaptive
with synchronization sustained ~39 source FPS and p50 ~31.7 ms. These are
generated-frame presentation metrics, not input-to-photon latency. The first
fixed run included cold compilation; its overall FPS is excluded from this
comparison, and a warm fixed repeat confirmed the steady-state result.

After the cap fix, the 3456x2234/40-source/60-target/cap2 fixtures passed in both
quality and performance + 50% flow modes, with mixed one/two-slot output rather
than locking to two. Default Rust tests are 44/44, Clippy passes, and the four
targeted MiPlay tests (including the real NSWorkspace off/on synthetic entry)
pass. Packaged shim SHA256:
`6d3b6309bf980655bdaf8857b2a307c48134de50c1becc5ae108d12525663a8f`.

Evidence: `/tmp/MiPlay-LSFG-Wine-pacing-20261105/*-results.json`, individual
named case folders, and `/tmp/MiPlay-LSFG-Pacing-Final.xcresult`.
The final `final-budget-quality`/`final-budget-performance` cases contain the
cap fix; earlier cases retain their tested component hashes. Runtime/prefix
clones were reused sequentially, never concurrently, and case evidence was
preserved after each run. No production game/prefix or saved user settings were
modified. Genshin performance and distortion still require a new real-game
comparison; adaptive scheduling does not guarantee lower GPU cost in every
scene, and performance mode/less flow resolution trade detail for computation.

## Full-quality queue investigation (2026-11-05)

The subsequent Genshin session `D9994F91-96FB-47BC-9F71-D7BD47C8178F`
confirmed adaptive 2x, 3456x2234, 100% flow and performance mode **off**. The
last stable 43 windows had 24–28 source FPS (median 26). Counter differences
within that segment show 2579/2580 valid original callbacks and 2520/2520 valid
generated callbacks. Generated enqueue-to-display batch p50 was 99–108 ms,
queue 54–62 ms and worker 35–39 ms. Worker includes producer readiness and
copy-completion waits; it is not a measurement of shader GPU execution time.
The later saved performance-mode preference was on, which does not change an
already running process. User feedback rules out 50% flow as an acceptable
quality tradeoff for this investigation.

Added diagnostic `--max-frames-in-flight 2|3` to the Wine harness and
`LSFGM_MAX_FRAMES_IN_FLIGHT` to the source proxy pool. The component defaults to
3 and MiPlay does not set this diagnostic override. Six isolated tests kept
3456x2234, fixed 2x, 100% flow, performance off and synchronized presentation.
Fixed pacing keeps generation work identical rather than introducing adaptive
probe frames. Each group ran capacities 3, 2, then 3 again with warmed caches.
All six passed presentation/pixel checks without pool exhaustion or fallback.

| Source limit | Capacity | Measured source FPS | Generated request→display, last batch p50 |
| --- | --- | --- | --- |
| 40 | 3, initial / repeat | 37.95 / 38.78 | 41.70 / 42.89 ms |
| 40 | 2 | 38.17 | 65.52 ms |
| 120 (pressure) | 3, initial / repeat | 45.44 / 44.84 | 74.25 / 74.33 ms |
| 120 (pressure) | 2 | 38.40 | 65.73 ms |

Capacity 2 is **not enabled by default**: it worsened full-chain delay at the
40 FPS limit, and traded about 15% source throughput for ~8 ms less delay under
pressure. It also has a compatibility risk for clients acquiring three
drawables before committing. These synthetic results are not Genshin FPS or
input-to-photon measurements. Full 100% flow remains unchanged.

Evidence: `/tmp/MiPlay-LSFG-queue-audit-20261105.json`,
`/tmp/MiPlay-LSFG-D9994F91-audit-20261105.json`, and the six `queue*-results.json`
/ `pressure120-queue*-results.json` reports under the existing pacing root.
The queue comparison used candidate shim SHA256
`b36de0863bc27995106590201319df63b569a84e9c6e98c8b17d44c51c46c6a2`.

The final component adds the three cumulative CPU-wait diagnostics described
above, without changing scheduling. SHA256:
`8c4db27d0c73039a2276c5237aefbc9f2c3dd1ea5d784249386e3ee273683673`.
Default Rust tests pass 49/49 and Clippy passes. Both 3456x2234 synthetic
quality and performance runs pass at 100% flow with the default capacity 3;
their reports are `final-waits-quality-results.json` and
`final-waits-performance-results.json`. All acquisition and worker-wait fields
are present. Four targeted MiPlay tests, including the production NSWorkspace
off/on synthetic launch, pass in `/tmp/MiPlay-LSFG-Latency-Verified.xcresult`.
These checks validate diagnostics and integration, not a real-game performance
gain. No game files, production prefix or saved user preferences were changed.

## Xcode validation inherited through LaunchServices (2026-11-05)

The next three real Genshin sessions (`2B2F8DC9`, `454CF9FB`, `B800E1E1`)
all used performance mode and a 2x cap. Their last steady source rates were
about 21–23 FPS. Moving from 100% to 25% flow lowered copy-completion waiting,
while producer-completion waiting increased; total worker batch p50 remained
about 42–45 ms. These were different sessions/scenes, not a controlled A/B.
The same process also had much faster source-frame intervals earlier, so the
logs do not demonstrate a process-wide 45 FPS cap. Target 240 in these logs is
the configured output budget, not evidence of a 240 Hz physical display.

All real-game logs used `MTLDebugCommandBuffer`, including the previous runs.
The running Xcode-launched MiPlay had `MTL_DEBUG_LAYER=1`. A minimal native
NSWorkspace fixture reproduced the bug: values omitted from the supplied
environment still appeared in the child. Earlier synthetic runs had used a
clean parent and ordinary `AGXG13XFamilyCommandBuffer`, missing this boundary.

The fix enforces the prepared controlled-variable list inside GameLauncher,
after LaunchServices has constructed the actual environment and before Wine
starts. It does not disable MiPlay's own debugging or change game settings,
frame caps, LSFG quality or GPU synchronization. The preparation log now says
`launch.environment_sanitization_prepared`; it no longer claims that filtering
a dictionary proves the game is running without the Metal debug layer.

Real NSWorkspace before/after native probes passed both HUD-off and HUD-on:
the old helper inherited validation in both cases; the fixed helper removed
validation and preserved only the explicitly requested HUD. Evidence is under
`/tmp/MiPlay-LSFG-env-probe-20261105`. The live Wine test now intentionally
pollutes its parent, checks selected variables inside the D3D11 executable,
and rejects `MTLDebugCommandBuffer` while still requiring valid generated-frame
callbacks. Game FPS improvement requires a new real-game comparison with the
fixed launcher; it is not established by these environment checks.

Final validation: 14 selected tests passed, including the polluted-parent
NSWorkspace → helper → Wine → DXMT off/on run. Wine reported both validation
variables unset, HUD unset when off and `1` when explicitly enabled. The LSFG
hook used `AGXG13XFamilyCommandBuffer`, with valid generated callbacks. Result:
`/tmp/MiPlay-LSFG-Environment-Verified.xcresult`; detailed live evidence:
`/tmp/MiPlay-LSFG-Wine-matrix-fixed-20261105/launchservices-05DE3938-9EA2-43F5-936F-F1DBC1EEEA47`.
The universal helper passed strict signature verification; SHA256:
`7ab5845d652954270201653c9fa5e9297233c20482ea22c659d17f2834c0ec4c`.
The user clarified that the purported 4x change may have been the target FPS;
the recorded tests were 2x with targets 120/240, so no new 4x conclusion is made.

## Bounded adaptive probes after non-debug game tests (2026-11-05)

The rebuilt game's `D27E70FA`, `A4E35E75` and `70981C83` sessions all hook
`AGXG13XFamilyCommandBuffer`; the last session genuinely uses a 4x cap. The user
reported lower HUD FPS while stationary and higher FPS during movement, and
also switched to another macOS Space during parts of the tests. There are no
camera/visibility markers in those game logs, so all-zero display intervals
cannot be labeled as a stationary-scene performance problem.

There is a separate, concrete scheduling problem. In `D27E70FA`, source
5280→6000 has 720 valid original callbacks, zero generated submissions, and
source windows near 19–21 FPS, despite a target of 120. Other long one-slot
runs occur at 27–37 source FPS. The old pacer could remain in its original-only
measurement probe forever when drawable backpressure prevented it from
collecting four trusted samples. A stale fast-scene estimate could also remain
unchanged through a slower scene under persistent blocking.

The pacer now exits a probe within eight source samples, including invalid
samples in that budget. It keeps the early trusted-median path; otherwise it
uses valid observed intervals from probe positions 4–8, or preserves the old
estimate if none exist. It then applies the normal fractional/integer budget
and cap; it does not force the maximum multiplier. New 60-source-frame stats
include probe position, observed/trusted sample counts, estimate and recovery
counters. GPU completion guards and frame-resource lifetime are unchanged.

A controlled synthetic pressure case (3456x2234, quality mode, 100% flow,
source limit 120, target budget 240, cap 2, 480 source frames) reproduced the
old failure: the previous packaged component submitted zero generated frames
and failed the existing interpolation/presentation acceptance. The candidate
recovered seven probes using observed cadence and reported 369 generated
submissions, 368 valid callbacks and one pending at its final snapshot. This
proves generation resumed, not a performance gain: restoring generation adds
GPU work and this artificial target does not represent the panel refresh rate.

Evidence under `/tmp/MiPlay-LSFG-Wine-pacing-20261105`:
`before-probe-pressure-results.json`, `bounded-probe-pressure-results.json`,
`bounded-probe-2x-results.json` and `bounded-probe-4x-results.json`. The candidate
SHA256 is `df3f397f9169b21d4a4c47b291407cc55ca7c4e306f7691a8c7eca8e7b478bde`;
packaged shim SHA256 is
`cc864d84bee7c8774e9d57e14ec56a78bf1f5e2412d4bc2a355e2b76d737d884`.
Rust tests pass 57/57, including closed-loop and persistent-untrusted cases;
Clippy passes and high-resolution 2x/4x synthetic checks pass.
The four selected MiPlay tests, including the polluted-parent production
NSWorkspace off/on launch, pass with the final package in
`/tmp/MiPlay-LSFG-Bounded-Probe-Verified.xcresult`.

The fixture also supports `--motion-profile phases --frames 960` for
moving/static/moving/one-pixel-input phases with the same draw calls. Initial
trials had inconsistent visible output, including zero callbacks after motion
resumed; the Wine foreground flag alone does not establish macOS Space
visibility. Their general rendering checks passed, but they do not establish a
controlled static-versus-motion conclusion or automatic static-frame deduplication.

Remaining limits: the 19 FPS original-only game segment still spent about
41–45 ms waiting for the producer CB, which includes GPU queue/execution and
resource waits rather than just shader execution. The 4x session contains a
healthy interval with 357 generated submissions for 120 source frames (356
valid, one pending). Timestamp, history-index and resource-order review found
no obvious 4x wiring error, but presented callbacks do not prove pixel quality.
Fast-camera distortion remains unresolved; the existing 2x pixel oracle does
not certify the three 4x interpolation slots.
