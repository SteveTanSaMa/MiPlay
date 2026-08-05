# Review Metrics

> 统计口径：2026-08-04 当前工作区和 `/tmp/MiPlayReview-*` 结果包。

## Verification Metrics

| Metric | Result | Evidence |
|---|---:|---|
| P0 open | 0 | current static/test review |
| Debug arm64 build | 1/1 | `/tmp/MiPlayReview-Debug-build.log` |
| Release arm64 build | 1/1 | `/tmp/MiPlayReview-Release-build.log` |
| Debug XCTest | 62/62 | `/tmp/MiPlayReview-Debug.xcresult` |
| Release XCTest | 62/62 | `/tmp/MiPlayReview-Release.xcresult` |
| UI test targets | 0 | `xcodebuild -list` |
| signed entitlement evidence | 0 | build used `CODE_SIGNING_ALLOWED=NO`; adhoc artifact |
| real Wine/game launch evidence | 0 | resource not available |
| full Apple AX/VoiceOver dynamic evidence | 0 | no AX Inspector/global VoiceOver record |
| structured log call sites | 111 | static `rg` scan |
| legacy log call sites | 50 | static `rg` scan |

## Issue Counts

| Classification | Count |
|---|---:|
| P0 | 0 |
| P1 closed in code/test | 8 |
| P1 open implementation | 1 |
| P1 external blocked/conditional | 3 |
| P2 closed | 2 |
| P2 conditional | 3 |
| P2 open/document | 1 |

这些计数不把外部项目用户验证、静态 Accessibility 或 unsigned build 折算为 MiPlay 运行通过，也不把 Deferred 能力计为缺陷。

