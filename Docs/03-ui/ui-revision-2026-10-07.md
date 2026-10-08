# UI 优化计划与交接：黑色液态玻璃

日期：2026-10-07。负责人：Codex。状态：第二轮通透度调整完成，待用户评价视觉效果。

## 第二轮：增加通透度（当前方案）

用户反馈第一版不够“透”，缺少 Liquid Glass 的意味。本轮移除 0.55 黑色固定底色，将 `.regular.tint(.black)` 改为 `.clear.tint(.black.opacity(0.18))`。
保留轻烟黑染色、原生折射与交互；面板投影从 0.25/8pt/3pt 降为 0.18/6pt/2pt。
文字与 glyph 添加局部 1pt 阴影来辅助辨认，选中边框、禁用语义和辅助功能 fallback 保留。
比较了 clear 玻璃配 0.12 底色和完全移除底色的截图后，选择后者；减少厚重感优先于第一版固定深色面板的对比策略。
第一轮参数和证据保留在下文作为历史；生产实现以本节为准。

本轮验证采用同一原生静态预览，新增截图 `*-translucent.png`，不覆盖第一版截图。
只修改材质参数和局部前景阴影，执行 Debug arm64 build；120 项测试结果属于上一轮，本轮没有重复全量测试。
未使用 computer use、未启动游戏或修改应用数据。静态截图不代表真实交互、视频或无障碍实测。

## 目标与执行计划

用户反馈白色液态玻璃可识别度偏低，允许尝试黑色；尽量不用 computer use，允许截图。
本轮从视觉实现进入，沿用既有主窗口结构、任务语义和标准 Button。

| 步骤 | 内容 | 状态 |
|---|---|---|
| 1 | 核对材质、前景色、选中和禁用状态 | 完成；白字遇浅色玻璃对比不足，原先禁用按钮整体 opacity 为 0.35 |
| 2 | 试做局部黑色玻璃，统一游戏栏、设置入口和主按钮 | 完成；保留原生玻璃，增加黑色局部底色、白色前景与细描边 |
| 3 | 强化选中状态和禁用状态 | 完成；选中边框独立绘制，状态点保留业务颜色和辅助文本；禁用面板不再整体淡出 |
| 4 | 截图、构建与回归验证 | 完成；浅/深背景状态对照与三款缓存主题截图已检查；Debug arm64 120 tests / 0 failures |
| 5 | 用户评价实际观感，再微调参数 | 待用户评价；优先调底色浓度、边框、高光，不扩大功能范围 |

验收重点：浅色和深色背景均能辨识操作文字、设置图标与游戏选择状态；启动中和正在运行的文本可辨；控件尺寸和命中区域保留。

## 第一轮实现决策（材质参数已由第二轮覆盖）

- `DarkGlassSurface.swift` 是三个主窗口控件共用的局部 ViewModifier。截图显示单独黑 tint 仍被浅色背景冲淡，因此常规路径先添加 0.55 黑色局部底色，再使用 `.regular.tint(.black)`，保留原生玻璃折射、高光和交互效果。
- 主按钮前景为白色，移除整块 `.opacity(0.35)`。禁用事实仍由 `.disabled` 和原有状态文案表达，保留系统禁用反馈。
- 游戏选中边框为 1.5pt、0.9 白色；普通边框为 0.75pt、0.2 白色。边框与状态点位于 GlassEffectContainer 外，避免材质合成覆盖。装饰层不参与点击和 VoiceOver。
- 描边容器已有 12pt spacing；设置入口额外 padding 为 4pt，合计对齐真实入口的 16pt 顶距。
- 减少透明度时使用不透明深色底，提高对比度时普通边框提升到 0.55。只在浮动控件局部设置 dark 环境。
- 保留主窗口 1280×688、主按钮 220×64、玻璃图标 56×56、命中区域 64×64、16pt 圆角及 glyph-only 缩放。
- 设置窗口继续跟随系统外观。原先白色加载遮罩按既有用户要求保留。业务逻辑与主窗口诊断区域未调整。

## 验证与边界

`QAArtifacts/UI-BlackGlass-20261007/` 保存修改前后截图、三款主题截图和静态预览源。
预览直接编译生产 Button、Rail、BackgroundView 和 BackgroundScene，使用隔离模型桩及本机已有主题图片，不运行 MiPlay 初始化、网络下载或游戏启动。
截图由独立 AppKit 窗口和 `screencapture -l` 获取；未使用 computer use 或鼠标/键盘自动操作。

本轮已检查静态材质、状态和布局。尚未实测真实应用的点击、键盘焦点、VoiceOver、视频背景和系统辅助功能设置。
减少透明度与提高对比度路径通过编译，但未切换系统设置验证，不宣称已完成无障碍验收。
最后一次全量测试：120 tests / 0 failures；其后仅修正设置描边的 12pt 对齐误差，已重新截图和完成 Debug 构建。
测试仍报告此前 WineNetworkTests 的并发捕获警告；本轮未修改该路径。

复现静态预览（项目根目录）：

```sh
xcrun swiftc -parse-as-library \
  QAArtifacts/UI-BlackGlass-20261007/Preview.swift \
  MiPlay/Domain/Game/GameConstants.swift \
  MiPlay/UI/ViewModels/LibraryViewModelModels.swift \
  MiPlay/UI/Components/DarkGlassSurface.swift \
  MiPlay/UI/Components/PrimaryActionButton.swift \
  MiPlay/UI/MainWindow/GameSelectionRailView.swift \
  MiPlay/UI/Components/BackgroundScene.swift \
  MiPlay/UI/MainWindow/BackgroundView.swift \
  -o /tmp/miplay-ui-preview
/tmp/miplay-ui-preview /tmp/miplay-controls.png
# 可选：传入已有主题背景图片和游戏 ID。
# /tmp/miplay-ui-preview /tmp/miplay-theme.png /absolute/path/background.png GenshinImpact
```

## 轮流协作交接

本轮未提交 Git。项目已有大量遗留未提交更改，接手者不应将全量 diff 当作本轮产出。
本轮生产代码仅新增 DarkGlassSurface.swift，修改 PrimaryActionButton.swift 与 GameSelectionRailView.swift。
下一步优先结合用户反馈微调此小目标。主窗口任务诊断文字的背景对比度可作为后续独立小目标。
