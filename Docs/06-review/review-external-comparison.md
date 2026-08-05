# External Project Comparison

> 参考项目：`/Users/stevetan/SteveTan/Document/Xcode/AnimeGameWineReleaseFetcher`
> 规则：只读比较。外部项目的用户验证、运行日志和产物不计入 MiPlay 证据，也不复制其代码。

## Evidence

- `Package.swift` 只有一个 executable target，没有 XCTest target 或测试依赖；`swift package dump-package` 已核对。
- README 只说明用户手工运行和下载结果目录，没有可复核的 XCTest、错误场景结果包或真实网络记录。
- 外部项目的实现集中在 `Sources/AnimeGameWineReleaseFetcher/main.swift` 和 `AppModel.swift`；MiPlay 的网络、Domain、TaskScheduler、ViewModel 和日志由自己的代码独立实现。

## Difference Matrix

| 维度 | 外部参考项目 | MiPlay 当前实现 | 可复用结论 |
|---|---|---|---|
| API 发现 | `GET api.github.com/.../releases`，可浏览最近 releases | 先按 managed tag 请求 release API，再按 arm64 `.tar.xz` 筛选 | 可复用 URLSession/Decodable 结构；不能把任意 release 选择带入 MiPlay Product 边界 |
| asset 身份 | 直接使用 `browser_download_url` | `ApprovedAsset` 绑定 source、tag、asset name、架构和 API size | MiPlay 必须保留身份 envelope；外部 URL 不能成为 MiPlay 输入 |
| 302 | URLSession 默认跟随重定向，未限制 host | 记录最终 response URL，并只接受 official asset host 和 GitHub asset hosts | 外部代码只能证明“能跟随”，不能证明来源可信；MiPlay redirect allowlist 保持 |
| HTTP API | API 非 200 抛 `GitHubAPIError.httpStatus` | API 403/404/429 有 Domain 映射，其他为 unavailable | API 与资产必须分别验证；API 200 不代表 asset 可用 |
| HTTP asset | 检查是否 2xx | 基础层拒绝非 2xx，但资产错误变成字符串并统一为 `networkUnavailable` | 需要补 P1-REV-005：资产 403/404/429/5xx 需保留可区分事实 |
| 进度 | `URLSessionDownloadDelegate` 回调到 `AppModel` | Network AsyncStream -> WineVersionDownloader -> TaskScheduler -> Settings/ViewModel | 可复用节流和进度字段；不能绕开 TaskReceipt 或 ViewModel 状态投影 |
| 取消 | AppModel 启动未保留可调用的 download Task；没有 UI 取消链 | session ID、active producer、URLSession task、Scheduler cancel 和 recovery cleanup | MiPlay 的取消和清理边界是项目契约，外部实现不足以替代测试 |
| 清理 | `try?` 删除 staging；允许任意 destination/overwrite | ManagedStaging 约束在 `WineVersions/.staging`，失败可转 recoveryRequired | 外部清理实现不可复用到 Sandbox/托管 Wine |
| 完整性 | 记录 API expected size，完成后只记录 actual size；不比较 hash/size | 比较 expected size；校验 tar traversal、symlink 和 extracted tree | 外部“文件存在/HTTP 200”不能作为完整性通过证据 |
| 存储 | `~/Downloads/AnimeGameWineDownloads`，可覆盖现有文件 | App Support `WineVersions`、`.staging`、安装记录写回并重读 | MiPlay 需要 app-owned root 与持久化提交顺序，不能使用外部任意下载目录 |
| Sandbox/bookmark | 没有 MiPlay bookmark、entitlement 或 scope 处理 | GameLocation/security-scoped access；工程声明 App Sandbox/outgoing network/user-selected read-only | 外部项目无法证明 MiPlay 权限行为 |
| 状态投影 | `@MainActor` AppModel 直接维护 loading/downloading/progress/error | TaskScheduler terminal facts 投影到 Settings/Library ViewModel 和 AX 语义 | 参考其状态字段即可；不能越过 Scheduler 直接消费独立下载流 |
| 日志 | 明文 URL、路径、headers、响应预览、错误和临时文件 | LogWriter actor、allowlist、敏感字段删除、flush/rotation/export | 外部日志覆盖面可作为事件清单参考，但其日志策略不符合 MiPlay 脱敏要求 |

## External Error Review

外部项目具备 API response check、asset HTTP check、progress callback 和 delegate staging，但没有自动化测试 target，取消和错误清理依赖手工路径，且没有最终 host allowlist、实际 size compare 或 MiPlay 的 recovery fact。用户已验证外部项目这一事实只能说明该项目在用户环境中可用，不能关闭 MiPlay 的 P1-REV-005、P1-08、Sandbox 或真实 Wine 门禁。

## Integration Decision

外部项目不需要进入 MiPlay Architecture 回溯。其可复用结论仅限：API/asset 必须分开检查、下载进度应保留、URLSession delegate 可提供最终响应和临时文件。任何采用都必须在 MiPlay 的 `ApprovedAsset`、allowlist、TaskScheduler、managed staging、PersistenceStore 和 LogWriter 契约内重新实现并测试。

