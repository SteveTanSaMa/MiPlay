# UI 优化方案与实施记录

本记录保留首轮方案与证据；当前实现以 [2026-10-09 原生 UI 审查](ui-native-review-2026-10-09.md) 为准。

日期：2026-10-08。负责人：Codex。状态：实现完成，Debug 构建与最终全量回归通过；静态截图已检查，实际辅助技术和交互验收待执行。

## 目标与授权

用户授权自主制定并实施 UI 优化，可跳过既有阶段工作流，最终按项目文档归属记录改动。本轮使用 SwiftUI Patterns、Liquid Glass、Build/Run/Debug skill，保留沉浸背景、官方游戏图标、原生黑色玻璃、固定窗口尺寸及既有业务操作。

工作区已有大量未提交更改，且验证期间其他更改仍在更新。仅把本轮明确修改的四个既有 UI 文件和一个新增文件计入实施范围，不把全量 Git diff 当作本轮成果。未提交 Git。

## 方案与决策

| 问题 | 方案 | 落地 |
|---|---|---|
| 启动阶段文字直接叠在主题上，可读性随背景变化 | 仅任务期间出现的局部内容面板 | `MainTaskFeedbackView`，300pt 宽、16pt padding、16pt 圆角，深色 regularMaterial |
| 仅短提示无法判断恢复原因 | 显示真实恢复详情与明确重试动作 | detail 最多三行；help 与 accessibility 保留全文；已解决记录隐藏 |
| 彩色描边同时承担业务状态与选择 | 独立表达当前选择 | 左侧 3 × 20pt 白色短条；业务颜色描边保留；Button 添加 isSelected trait |
| 主操作依赖文字，快速扫视缺少动作线索 | 按已有 action 映射系统符号 | 定位 folder.badge.plus、启动 play.fill、更新 arrow.down.circle；禁用状态不新增符号 |
| 设置六项平铺，详情缺少位置提示 | 导航分组与稳定页面标题 | 应用 / 游戏 / 关于；title2 标题、一行范围说明、原生 grouped Form |
| 动画对减少动态效果设置响应不足 | 读取系统 accessibilityReduceMotion | 图标保持原尺寸，关闭自定义 hover/spring 动画及主场景 crossfade |
| icon URL 消失时仍保留旧图片 | 每次 URL 变化重新赋值，包括 nil | 读取失败清除图像，回到 SF Symbol 与原生玻璃 |

任务面板属于内容层，使用 regularMaterial 提高文字可读性；主按钮和设置入口保留 `.glassEffect(.clear.tint(.black.opacity(0.18)))`。没有全屏新增遮罩或主题暗化。减少透明度时，任务面板使用不透明深色底。

百分比直接显示已有真实 progress，未知进度显示 spinner，不生成插值或虚构进度。进度与恢复可同时展示，中间用 Divider 分隔；两者都不存在时不生成面板。

设置仍是 800 × 448pt，侧栏 240pt、详情 560pt；主窗口仍为 1280 × 688pt。主按钮仍为 220 × 64pt，游戏图标仍为 56pt、命中区域 64pt、行间距 12pt。设置页面 `.id(selectedItem)` 让不同游戏的表单与本地参数草稿具有独立身份，切换后从对应模型重新创建。

## 文件归属

| 文件 | 本轮改动 |
|---|---|
| `UI/MainWindow/MainWindowScene.swift` | 抽出任务反馈，响应减少动态效果 |
| `UI/MainWindow/MainTaskFeedbackView.swift` | 新增局部任务内容面板，保留原有 retry 回调 |
| `UI/MainWindow/GameSelectionRailView.swift` | 选中短条、选择 trait、区域标签、减少动态效果、图标 fallback 修复 |
| `UI/Components/PrimaryActionButton.swift` | 按 PrimaryAction 映射装饰性系统符号 |
| `UI/SettingsWindow/SettingsWindowScene.swift` | 原生 List 分组、详情标题与范围说明、页面 identity |

本轮没有修改 ViewModel、Domain、Infrastructure、持久化 schema 或 XCTest。窗口 main/key 管理和启动准备白色遮罩沿用既有实现。

本轮代码增量单独保存于 `QAArtifacts/UI-Optimization-20261008/changes.patch`，以开始编辑时的工作区快照为基线。

## 验证与证据

- Debug arm64 build：成功，`build.log`。
- 最终全量 XCTest：136 tests / 0 failures，`tests-final.log`。
- 首次筛选误使用文件名作为测试类名，执行 0 项（`tests.log`），不作为通过证据。
- 首次全量执行 136 项，两处测试共 5 条断言失败（`tests-all.log`）；复查时对应测试已由其他工作区改动更新。本轮未改测试，针对两处复跑 2 tests / 0 failures（`tests-repeat.log`），然后全量复跑通过。
- 原生 SwiftUI 独立静态预览直接编译生产视图和依赖；临时 FileSystem/Persistence 目录，未调用主应用启动初始化、环境准备、游戏下载或游戏启动。
- `controls.png`：浅/深高频背景、确定进度、恢复详情、可用及禁用按钮、选中标记。
- `settings-light.png` / `settings-dark.png`：通用页与分组导航；四个运行开关首屏完整，后续表单仍可滚动。
- `genshin.png` / `genshin-busy.png`：已有缓存主题与官方 icon，分别展示空闲操作和启动任务期间的布局。
- 预览源、编译日志和截图位于 `QAArtifacts/UI-Optimization-20261008/`，复现方式见其中 README。

静态截图可确认当前样式、文本和几何布局，不能确认真实应用的点击、Tab/Space/Return/Escape、VoiceOver、滚动、视频播放或系统辅助功能切换。上述实际验收仍待执行，不将单元测试等同 UI 自动化验收。

## 文档同步

已更新 UX 信息模型、UI 组件树、窗口导航、状态映射、无障碍验证、实现记录与 QA 报告。早期修订记录保留为历史，当前实现以本文件与生产代码为准。
