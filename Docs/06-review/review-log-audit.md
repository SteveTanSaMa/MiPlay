# Logging Coverage Audit

> 日期：2026-08-04；审查 LogWriter、生产调用点、测试和导出边界。

## Security and Reliability

| 检查 | 证据 | 结论 |
|---|---|---|
| Actor isolation | `MiPlay/Infrastructure/Log/LogWriter.swift:120-222` | 日志序列、pending batch 和 rotation 状态由 actor 串行化 |
| Field allowlist | `LogWriter.swift:130-165,508-520` | 未批准字段丢弃；path/url/token/bookmark/environment/stdout/stderr 等敏感字段不进入事件 |
| Text sanitization | `LogWriter.swift:466-505` | identifier、Wine tag、reasonCode 和错误类别受约束，URL/token/path 文本被脱敏 |
| Legacy compatibility | `LogWriter.swift:224-256` | `info/warning/error/debug` 不保存自由文本，固定为 `legacy.message`；防泄露有效，但会丢失诊断细节 |
| Automatic flush | `record` 达到 50 个 pending events 后异步 flush | 有阈值；自动 flush 失败保留 batch |
| Flush durability | `flush` 原子写、rotation、read-back event ID 验证 | 失败不丢 pending batch，调用方可重试 |
| Export barrier | `exportLogs` 先 `flush(reason: "export")`，再读当前和轮转文件、重新 sanitize | 导出不返回 App Support 路径或未脱敏 fallback |
| Tests | `testStructuredLogFlushExportAndSanitization`、legacy suppression、flush retry、sequence/rotation/export | Debug/Release 均通过 |

## Business Event Coverage

静态扫描结果：MiPlay 当前有 **111** 个 `record` 调用点和 **50** 个 legacy convenience call 点。关键业务链已有结构化 terminal 事件：

- `ProcessManager`：创建、启动失败、timeout、termination observed。
- `GameRegistry` / `LaunchOrchestrator`：bookmark scope、stale writeback、launch terminal、process exit commit/recovery。
- `TaskScheduler`：accepted、running、phase、terminal、persistence recovery、log export。
- `WineVersionDownloader` / `WineVersionManager`：catalog request/response、asset download、redirect、verify、extract、cancel、cleanup、install/delete、readiness。
- `VersionChecker` / `FileIntegrityVerifier` / `WineRuntimeProvider`：metadata evidence、manifest、runtime/prefix readiness。

剩余风险是 BackgroundMedia、部分 Registry/Launch/VersionManager 的 legacy message 仍在调用点构造 `localizedDescription`，但 LogWriter 有意不持久化它们。结果是安全性通过、低层诊断细节不完整。登记为 **P2-LOG-001，回溯 Implementation**，不把日志存在误判为业务流程通过。

## Sensitive Data Scan

- 未发现结构化 `fields` 把完整 path、URL、token、bookmark、environment、stdout 或 stderr 作为允许字段写入。
- 测试明确验证 token、私有路径和 legacy free text 不出现在 pending/exported log。
- 生产 OSLog 只输出固定 event/message code、ID、phase、result、error category 和允许的摘要字段。
- 外部 `AnimeGameWineReleaseFetcher` 不满足该要求：其 README 和 `main.swift` 明确记录 request URL、headers、response body preview、redirect URL、destination path 和临时文件路径。该项目日志不能迁移到 MiPlay。

## Log Gate

日志安全、flush、rotation、export 和结构化序列化可视为 code/test closed；业务事件覆盖仍是条件项。P1-REV-005 的资产 HTTP status 缺口也必须在 Wine terminal event 中修复后重新审计。

