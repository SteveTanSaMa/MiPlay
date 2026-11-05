# 清理候选清单

冻结日期：2026-10-12。执行前 Git 状态与原始四份未提交文档已保存在 `QAArtifacts/MigrationFreeze-20261012`。

仅以下逐项列出的路径允许自动清理：均未被 Git 跟踪、非符号链接，可由 Finder 或下一次 Xcode 构建重建；后续会检查项目脚本/配置没有运行依赖、没有活动构建使用这些缓存，再按清单执行。

| 路径 | 字节 | 理由 | 可重建 |
|---|---:|---|---|
| `.DS_Store` | 26628 | Finder display metadata | 是 |
| `build/DLSSCompatibility/SDKStatCaches.noindex` | 15274032 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/DLSSCompatibility/SDKExplicitPrecompiledModules` | 84251464 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/DLSSCompatibility/ModuleCache.noindex` | 14308773 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/DLSSCompatibility/CompilationCache.noindex` | 16736 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZNativeAcceptance/SDKStatCaches.noindex` | 15274032 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZNativeAcceptance/SDKExplicitPrecompiledModules` | 84253336 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZNativeAcceptance/ModuleCache.noindex` | 14310948 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZNativeAcceptance/CompilationCache.noindex` | 16736 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZRepair/SDKStatCaches.noindex` | 15274032 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZRepair/SDKExplicitPrecompiledModules` | 84244688 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZRepair/ModuleCache.noindex` | 14299068 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZRepair/CompilationCache.noindex` | 16736 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZFreshAcceptance/SDKStatCaches.noindex` | 15274032 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZFreshAcceptance/SDKExplicitPrecompiledModules` | 84251896 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZFreshAcceptance/ModuleCache.noindex` | 14309974 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZFreshAcceptance/CompilationCache.noindex` | 16736 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/YAAGLLaunchSupport/SDKStatCaches.noindex` | 15274032 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/YAAGLLaunchSupport/SDKExplicitPrecompiledModules` | 84251904 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/YAAGLLaunchSupport/ModuleCache.noindex` | 14309503 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/YAAGLLaunchSupport/CompilationCache.noindex` | 16736 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/RemainingChanges/SDKStatCaches.noindex` | 15274032 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/RemainingChanges/SDKExplicitPrecompiledModules` | 84250528 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/RemainingChanges/ModuleCache.noindex` | 14308068 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/RemainingChanges/CompilationCache.noindex` | 16736 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZIsolatedDiagnostics/SDKStatCaches.noindex` | 15274032 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZIsolatedDiagnostics/SDKExplicitPrecompiledModules` | 84255256 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZIsolatedDiagnostics/ModuleCache.noindex` | 14313883 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/ZZZIsolatedDiagnostics/CompilationCache.noindex` | 16736 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/GameNews/SDKStatCaches.noindex` | 15274032 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/GameNews/SDKExplicitPrecompiledModules` | 84243816 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/GameNews/ModuleCache.noindex` | 14297836 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |
| `build/GameNews/CompilationCache.noindex` | 16736 | Xcode regenerable compiler/SDK cache; excludes products, symbols, index and logs | 是 |

## 保留清单

- 所有源代码、配置、运行资源、依赖记录、References 克隆。
- 初始四份未提交文档及修改，原文不改写；并保存副本和 SHA256。
- QAArtifacts 全部约 26 GB：包含运行时/Prefix、备份、账号登录状态、异常栈、五轮截图、原 DLL 和完整编译符号，具有不可替代诊断价值。
- build 的产品、dSYM/中间链接对象、Logs/TestResults、Index.noindex，以及根目录 `.trace`：迁移时保留历史证据，未逐项确认价值，不自动删除。
- `.commandcode`、用户 Xcode 配置、PerformanceScratch、无法判断用途的数据。
- 其他四个仓库及用户 Library/Application Support 下的所有游戏、运行时、缓存、Prefix。

## 结果

已按本清单完成33项删除，共910,813,713字节；构建与163项测试通过（2跳过、0失败）。逐项操作见QAArtifacts/MigrationFreeze-20261012/cleanup-results.json，完整结果见 MIGRATION_REPORT.md。此清单不是删除未知文件的授权，不执行 git clean/reset 或大范围目录删除。
