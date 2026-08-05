# Review Decision Validation

> 日期：2026-08-04。Apple/签名结论只描述证据边界，不把静态代码或 unsigned build 写成运行通过。

| Decision | Evidence | Status |
|---|---|---|
| MiPlay uses managed Wine only | `BuiltInWineVersions`, `WineVersionManager.validatedRuntime`, static scan | Accepted in code; real runtime pending |
| No system Wine fallback | no detector/path/fallback production code | Accepted in code |
| Official GitHub and mirror allowlist | official source; `approvedMirrorSources=[]`; URL/tag/arch/redirect validation | Code accepted; real source failure pending |
| No arbitrary asset URL | `ApprovedAsset` internal and revalidation | Accepted in code/test |
| Asset errors preserve business semantics | API typed status yes; asset typed status no | **Rejected: P1-REV-005** |
| TaskReceipt requires durable pending fact | `TaskScheduler.commit` persist/read-back before receipt | Accepted in code/test |
| Terminal state publication order | commit then actor update then committed event; recovery marker on failure | Accepted in code/test |
| WineReady means game prefix ready | `checkReadiness(for:)`, Settings `prefixNotReady` | Accepted in code/test; real Wine pending |
| Restart Running is conservative | recovery facts/guard/retry | Accepted in code/test; real forced exit pending |
| Metadata is evidence, not inferred truth | raw config and pkg fields retained; conflict blocks result | Accepted in code/test |
| Entitlements minimal and usable | project flags only; adhoc unsigned artifact | Conditional; signed build pending |
| AX/VoiceOver dynamic behavior is verified | static semantics only; no Apple evidence package | External Blocked P1-08 |
| Deferred helper is available | no helper/XPC target and code fails before side effects | Deferred, not a defect |

