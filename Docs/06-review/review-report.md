# MiPlay Review Report

> 日期：2026-08-04
> 范围：MiPlay 当前源码、工程配置、XCTest 结果、Review/Apple 证据，以及只读参考项目 `AnimeGameWineReleaseFetcher`。
> 规则：本报告只更新 `Docs/06-review/`，不修改业务代码、外部参考项目或 Product/Research/UX/UI/Architecture/Implementation/QA 冻结输入。

## 判定

**Major Revision。** P0=0；P1-REV-003、P1-REV-004、P1-02、P1-04、P1-07 有当前代码和测试关闭证据。P1-REV-005（资产 HTTP 状态语义和测试缺口）重新开放；P1-08 仍为 External Blocked，不能用静态 SwiftUI 语义或 unsigned build 关闭。Performance、QA、Release 继续暂停。

P1-REV-005 不是把构建失败误判为功能失败：MiPlay 会拒绝所有非 2xx 资产响应，但 `NetworkDownloadProvider.download` 只通过字符串错误传播，`WineVersionDownloader` 又统一记录为 `networkUnavailable`。因此 403、404、429 和 5xx 在 Domain/UI 层无法保持不同恢复语义，且没有资产状态码专门测试。

## 证据边界

| 检查项 | 当前证据 | 结论 |
|---|---|---|
| 工程入口 | `xcodebuild -list`：`MiPlay`、`MiPlayTests`；无 UI Test、Helper/XPC target | XCTest 入口存在，UI 自动化缺失 |
| Debug arm64 build | `/tmp/MiPlayReview-Debug-build.log`；`BUILD SUCCEEDED` | 仅编译通过；命令使用 `CODE_SIGNING_ALLOWED=NO` |
| Release arm64 build | `/tmp/MiPlayReview-Release-build.log`；`BUILD SUCCEEDED` | 仅编译通过；有 `CC_MD5` SDK deprecation warning |
| Debug XCTest | `/tmp/MiPlayReview-Debug.xcresult`；62/62 passed | Domain/Infrastructure contract 通过 |
| Release XCTest | `/tmp/MiPlayReview-Release.xcresult`；62/62 passed | 当前 fixture 回归通过 |
| 签名/权限 | 产物为 adhoc/linker-signed，TeamIdentifier 未设置；无分发签名/公证 | 不能证明最终 Sandbox、bookmark 或 entitlement 运行时行为 |
| 真实 Wine/game | 没有受管 Wine binary、真实 prefix、真实游戏和真实 GitHub asset 记录 | 不声明运行时成功 |
| Apple UI | 有静态 AX 语义和有限 UI 观察；无 AX Inspector、VoiceOver 全局导航/音频 transcript、动态任务记录 | P1-08 External Blocked |

## 当前 Issue 摘要

| 状态 | Issue |
|---|---|
| P0=0 | 跨层断链、未授权外部路径、错误把 Deferred 当完成，均未发现当前 P0 |
| P1 Closed | P1-REV-003、P1-REV-004、P1-01、P1-02、P1-03、P1-04、P1-05、P1-07 |
| P1 Open | P1-REV-005：资产 403/404/429/5xx 类型化传播和专门测试 |
| P1 External Blocked | P1-08：真实 Apple AX/VoiceOver/键盘/动态状态验证 |
| P1 Conditional External | P1-UV-002：真实 GitHub API、302 asset、网络失败和下载产物验证 |
| P2 Closed | P2-02 取消/清理/恢复；P2-03 Settings readiness 状态投影 |
| P2 Conditional | P2-01 entitlement；P2-04 主界面视觉与 Settings 窗口；P2-LOG-001 日志业务覆盖 |
| P2 Open | P2-05 Implementation/QA 历史文档不同步 |

## 关键复核

### Wine 和 GitHub

- `BuiltInWineVersions` 只声明官方 GitHub source；`approvedMirrorSources` 是空 allowlist。生产路径没有 system Wine、Whisky 或 CrossOver 检测/fallback。
- `fetchReleaseAsset` 先请求 tag API，再筛选 arm64 `.tar.xz`；`ApprovedAsset` 重新验证 source、tag、host、path、架构和 asset name。下载流程检查最终响应 URL 的允许 host。
- 下载阶段有进度、取消、 expected size、归档条目/符号链接/解压树校验和 managed staging cleanup。当前缺口仅是资产 HTTP 状态在 Domain 层被字符串化并统一归类，见 P1-REV-005。
- Wine 归档生产路径只使用 `WineVersions/.staging` 的 `ManagedStaging`；内部迁移测试 seam 也重新构造该身份，不能把任意目录交给清理。

### 权限、WineReady 和状态

- 游戏完整性、版本检查、预启动和启动调用 `GameFileSystemRepository.acquireSecurityScopedAccess`；stale bookmark 刷新必须写回成功，失败不使用 `lastKnownPath`。
- `WineVersionManager.checkReadiness(for:)` 要求 managed runtime 和 game-specific `drive_c`；没有游戏上下文的 Settings 检查返回 `prefixNotReady`，不伪造全局 WineReady。
- `TaskScheduler.commit` 先 PersistenceStore 写入并重读校验，再更新 actor 状态并发布 committed event。取消清理失败发布 recoveryRequired，持久化失败保留 recovery-held resource lock。

### 视觉和 Accessibility

- 主按钮固定 `220x64`，游戏 rail 命中区域固定 `64x64`，Settings 固定 `800x448` 并有窗口生命周期居中代码。
- 游戏按钮、主按钮、背景组、进度、恢复操作均有 label/value/hint 或 combine/contain 语义；装饰背景隐藏于 AX tree。
- 这些是代码和有限观察证据，不是 Apple 运行通过。真实 launch progress、failure、cancel、retry、rollback 的动态 AX 更新仍需用户验证。

## 回溯结论

1. P1-REV-005 回溯到 Implementation；现有 Architecture 已规定底层 HTTP/来源失败需映射到可区分的 Domain reason，不需要 Review 自行改架构。
2. P1-08 回溯到 UI + Apple Review/用户验证；静态代码没有越权，但缺真实签名 App 运行证据。
3. P2-05 回溯到 Implementation / QA；Review 不覆盖上游冻结文档中的历史陈述。
4. 外部参考项目不触发 Architecture 回溯。它只能提供 GitHub API、progress 和 URLSession delegate 的参考，不满足 MiPlay 的 Sandbox、bookmark、TaskScheduler、managed Wine 或日志契约。
