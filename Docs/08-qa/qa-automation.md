# 自动化测试方案

> 状态：2026-08-02 执行版

## 当前测试 target

工程已有 `MiPlayTests` XCTest target，测试源为 `MiPlayTests/MiPlayCoreTests.swift`。本轮没有新增第三方依赖，也没有修改生产业务代码。当前没有 `MiPlayUITests`，因此 UI 运行时检查必须由手工或后续 XCUITest target 承担。

## 可复现命令

```sh
# Debug
xcodebuild test \
  -project MiPlay.xcodeproj \
  -scheme MiPlay \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -enableCodeCoverage YES \
  -resultBundlePath QAArtifacts/Debug-20260802-final.xcresult \
  2>&1 | tee QAArtifacts/Debug-20260802-final.log

# Release：Release target 必须启用 XCTest 的 testability
xcodebuild test \
  -project MiPlay.xcodeproj \
  -scheme MiPlay \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -enableCodeCoverage YES \
  ENABLE_TESTABILITY=YES \
  -resultBundlePath QAArtifacts/Release-20260802-arm64.xcresult \
  2>&1 | tee QAArtifacts/Release-20260802-arm64.log

# 摘要
xcrun xcresulttool get test-results summary \
  --path QAArtifacts/Debug-20260802-final.xcresult
xcrun xcresulttool get test-results summary \
  --path QAArtifacts/Release-20260802-arm64.xcresult
```

## 本轮结果

| 配置 | 架构 | 总数 | Pass | Fail | Skip | 结果包 |
|---|---|---:|---:|---:|---:|---|
| Debug | arm64 | 30 | 30 | 0 | 0 | `QAArtifacts/Debug-20260802-final.xcresult` |
| Release | arm64 | 30 | 30 | 0 | 0 | `QAArtifacts/Release-20260802-arm64.xcresult` |

Release 未指定 testability 的第一次结果也保留为失败诊断包：`QAArtifacts/Release-20260802-final.xcresult`。它失败于 `@testable import MiPlay` 的编译阶段，不是测试断言失败。

## 测试隔离

- 外网：不访问；远端版本由 fixture 注入。
- 文件系统：独立 temporary directory；损坏、备份和写入失败均由 fixture 构造。
- Process：只运行确定性的 `/bin/sh` 命令验证 ProcessManager contract；不运行 Wine/游戏。
- Wine/系统权限：缺失 binary 的失败路径自动化；真实 binary、prefix、security-scoped bookmark、helper 权限必须单独集成/手工执行。

## CI 建议

CI 必须固定 `platform=macOS,arch=arm64`，上传两个 `.xcresult` 和对应日志；Release 使用 `ENABLE_TESTABILITY=YES`。若改动 UI、Wine、网络或沙箱行为，必须追加手工 Smoke，并把截图/录屏路径写入 QA report。

## 自动化边界

当前结果能证明核心状态、数据、任务和 ProcessManager contract；不能证明真实 Wine 启动、系统权限、网络 API、VoiceOver 朗读、键盘导航、窗口布局、视觉 fallback 或性能预算。
