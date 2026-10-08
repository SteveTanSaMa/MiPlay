# UI 交互实施说明（Task 4）

> **文档状态**：活跃（Active）
> **适用范围**：`Docs/03-ui/` 文档约束；不改变业务代码、ViewModel 或状态模型
> **实现状态**：本文件是下游 Implementation 输入；当前 Product/Research 回溯要求重新对齐 Wine UI，SwiftUI 源码不属于本轮 UI 文档修改范围。
> **对照**：`Docs/02-ux/ux-state-flow.md`、`Docs/02-ux/ux-edge-cases.md`、`Docs/01-research/research-ui-patterns.md`、`Docs/01-research/research-apple-platform-constraints.md`、现有 `MiPlay/UI/`
> **Task 4 修正**：主按钮、图标间距、Liquid Glass 融合、窗口居中和完整 Accessibility Tree
> **Product/Research 回溯修订**：2026-08-28。固定 `wine-crossover-11.0-1-signed`、共享 runtime、共享 prefix 覆盖此前 I-4。

## 1. 标准控件边界

| 入口 | 结构要求 | 禁止方式 |
|------|---------|---------|
| 游戏图标 | `Button` 的 action 负责选择该游戏；label 内容承载现有玻璃图标和状态点 | 在图标或外层容器上使用 `onTapGesture` |
| 设置齿轮 | `Button` 的 action 调用现有 `openSettings()`；保留 `⌘,` 的 Settings 场景快捷入口 | 仅给 `Image` 添加 `onTapGesture` |
| 主操作 | 继续使用现有 `PrimaryActionButton`，由传入状态决定 enabled/disabled 和文案 | 在 View 内根据业务事实自行判断动作 |
| 背景组圆点 | 标准 `Button`；默认隐藏，顶部悬停区只触发显示，不注册点击/手势 | 用透明点击层或 `onTapGesture` 完成选择 |
| 统一 Wine 任务 | 一个标准 `Button` 动作槽，按上游提供的任务事实呈现下载并安装、重试或取消 | 添加作用范围 Picker、版本选择、来源选择或删除固定 runtime |
| 此 Mac 行 | 只读 `LabeledContent` 四行；未知值显示“未知” | 用 model identifier、架构或旧缓存拼写机型/芯片/内存 |
| 取消、重试、回滚、确认 | 使用标准 `Button`；破坏性回滚/取消使用系统 role 或确认界面 | 用可点击 `Text`、`Image` 或手势伪造按钮 |

Button 只负责发送当前视图已经获得的动作闭包。UI 不新增状态、不启动任务、不从图标颜色推导业务结论。

## 2. 游戏图标 Button 语义

每个游戏图标是独立的焦点元素，固定命中区域和稳定布局。状态点、选中标识和 hover 视觉属于 Button 的 label 内容，不得成为额外的交互层。

| 语言 | Accessibility label 模板 | Accessibility value 模板 | Accessibility hint 模板 |
|------|--------------------------|---------------------------|--------------------------|
| 中文 | `切换到{游戏名}` | `{选中状态}，{业务状态}` | `选择后显示{游戏名}的背景和可用操作` |
| English | `Select {game name}` | `{selection state}, {business state}` | `Shows this game's background and available actions` |

约束：

- label 必须包含动作和对象，不能只读作“图标”或“按钮”。
- value 只读当前选中态和已知业务态，例如“当前选中，已就绪”；不得把 `pending`、`running` 或 `completed` 转写成成功。
- hint 说明选择后的结果，不重复 label，也不泄露实现细节。
- 状态点不单独进入 VoiceOver 顺序；若状态有关键失败原因，在主操作区或详情视图提供可读文本。
- 中文、英文 label 和 hint 使用本地化资源；游戏名称使用已有显示名资源，不在 View 中拼接不可本地化文本。

## 3. 设置 Button 语义

| 语言 | Accessibility label | Accessibility value | Accessibility hint |
|------|---------------------|---------------------|--------------------|
| 中文 | `设置` | `设置窗口已关闭` 或当前窗口状态 | `打开设置窗口` |
| English | `Settings` | `Settings window closed` 或当前窗口状态 | `Opens the Settings window` |

- 鼠标点击、VoiceOver 激活、聚焦后按 Space/Return 和 `⌘,` 必须调用同一设置入口，不产生多个业务路径。
- `⌘,` 是 Settings 场景级快捷操作；它不能依赖齿轮是否 hover 或是否已获得鼠标焦点。
- 设置窗口打开后，齿轮 Button 保持可访问但不重复打开第二个窗口实例；窗口关闭后主窗口状态保持。

## 4. 键盘与 VoiceOver

### 键盘行为

| 焦点对象 | Space / Return | Escape | 专用快捷键 |
|---------|----------------|--------|------------|
| 游戏图标 Button | 选择该游戏 | 不改变选择 | 无，避免三款游戏争抢全局快捷键 |
| 设置 Button | 打开 Settings | 不改变主窗口 | `⌘,` 打开或聚焦 Settings |
| 背景组圆点 Button | 提交该背景组选择 | 不改变选择 | 方向键在有效组间移动 |
| 统一 Wine 任务 Button | 提交下载并安装、重试或取消动作 | 不改变固定 runtime/prefix 身份 | 无 |
| 主操作 Button | 执行当前状态对应动作 | 不取消任务 | 无 |
| 任务取消 Button | 请求取消 | 关闭可关闭的反馈视图；若清理/回滚中则不可关闭 | 无 |
| 重试 Button | 提交新的重试任务 | 不改变上一条失败事实 | 无 |
| 回滚 Button | 打开确认并开始回滚 | 关闭确认前不执行 | 无 |

- 所有 Button 进入系统键盘焦点顺序；焦点可见性不依赖 hover。
- 顺序遵循窗口阅读顺序：游戏图标（固定顺序）→ 设置 → 主操作；Sheet/详情打开时先进入标题和当前反馈，再进入可操作 Button。
- disabled Button 保留可读的当前事实，但不进入可激活动作；不可取消的回滚阶段不呈现取消控件。

### VoiceOver 行为

- VoiceOver 激活结果与鼠标激活结果一致；不能存在“鼠标可点但辅助技术不可点”的图标入口。
- 任务进度更新使用可读的阶段文本和进度值；只有真实进度存在时才读出百分比。
- 失败反馈按“目标 → 阶段 → 事实 → 当前终态 → 恢复动作”顺序朗读。
- `Applied` 的朗读必须包含“方案已应用并验证，游戏尚未启动”；`RolledBack` 的朗读必须包含“应用未成功，原状态已恢复并确认”。
- 不使用纯颜色表达状态；状态点旁的可访问文本或对应详情必须提供同一事实。

## 5. Hover、focus 与 Liquid Glass

- hover 只提供发现和反馈，不是交互前提；键盘 focus、VoiceOver 激活和鼠标激活必须不依赖 hover。
- 保留现有 Liquid Glass、图标尺寸、16pt 圆角和窗口位置。hover 的亮度/缩放仅作用于 Button label 内的 glyph，不改变玻璃材质、命中区域、布局尺寸或状态点位置。
- 使用系统 Button 的 pressed/focus 行为；不能通过额外的透明手势层拦截 Button 的 hit testing。
- `.help` 或等效 tooltip 使用本地化动作名：游戏图标显示 `切换到{游戏名}` / `Select {game name}`，齿轮显示 `设置` / `Settings`。tooltip 不是 VoiceOver label 的替代品。
- Loading/不可用/回滚视图覆盖交互时，只禁用实际不可用的 Button，保留关闭、重试或重新授权等当前状态允许的动作。

## 6. 任务进度、失败、取消和重试

### 进度

- `TaskProgress.phase` 映射为短阶段标题；`statusText` 映射为说明文本；`progress` 只有在 `0...1` 且业务确实可估算时才渲染确定进度。
- 进程确认、权限读取、后置验证和回滚验证等不可估算阶段使用不定进度，不显示猜测百分比。
- 进度区域同时保留任务类型和目标游戏名称，避免 VoiceOver 或窗口内多个任务同时出现时失去上下文。

### 失败

- 失败视图必须显示具体类别：游戏文件、访问权限、运行环境、进程启动、超时、后置验证或恢复未确认。
- 每个失败状态只显示一个当前最适合的恢复动作。重试条件不满足时显示重新选择、重新授权或查看日志，不显示无效的“重试”。
- 失败结果保留到下一次可信任务结果；不能在窗口刷新、切换游戏或关闭详情时被渲染为默认就绪。

### 取消

- 用户发出取消请求后，按钮立即进入“正在取消/正在清理”反馈，但终态仍由清理或回滚验证决定。
- 方案修改已开始后，取消只能进入不可中断的恢复流程；恢复确认后是 `cancelled + RolledBack`，恢复失败是 `failed + 恢复未确认`。
- 回滚任务开始后隐藏取消按钮，避免文案暗示恢复可以中途停止。

### 重试

- 重试是新的任务提交，按钮激活前必须由状态提供可重试条件。
- 不在 UI 层实现自动重试计数、退避或错误分类；UI 只展示 ViewModel/Domain 提供的恢复动作。
- 重试提交后立即回到 `pending` 文案；不能在点击瞬间显示“已修复”或“已启动”。

## 7. 不可用、权限失败和回滚

| 状态 | 视觉/结构呈现 | 可用控件 | 禁止呈现 |
|------|--------------|---------|---------|
| `Unavailable` | 方案行保留但明确置为不可应用，显示原因 | 重新授权、查看原因、选择其他方案 | 应用按钮可激活、`Applied` |
| 执行前权限失败 | 任务不开始；显示“需要的系统权限未获得” | 重新授权、返回 | `Applying`、文件损坏 |
| 执行中权限失效 | 进入“正在恢复应用前状态”阶段 | 等待；恢复中无取消 | 方案已应用 |
| 回滚已确认 | 显示“方案未应用，应用前状态已恢复并确认” | 稍后重试、选择其他方案 | 绿色成功或游戏已修复 |
| 回滚未确认 | 显示“系统状态暂时无法确认”并保留日志入口 | 重新授权、完成恢复、导出日志 | 再次应用同一方案、取消成功 |

## 8. 英文文案与窗口约束

主窗口固定为 1280 × 688，Settings 固定为 800 × 448。可见按钮使用短文案，详情原因使用正文区域换行；不通过缩小字体或改变窗口尺寸解决溢出。

| 中文 | English | 使用位置 | 长度约束 |
|------|---------|---------|---------|
| 定位游戏 | Locate Game | 主操作 | 保持单行 |
| 启动 | Launch | 主操作 | 保持单行 |
| 更新 | Update | 主操作 | 保持单行 |
| 查看修复方案 | View Fixes | 主操作 | 保持单行；完整解释放详情 |
| 启动中… | Launching… | 主操作/状态 | 保持单行 |
| 更新中… | Updating… | 主操作/状态 | 保持单行 |
| 运行中 | Running | 主操作/状态 | 保持单行 |
| 重试 | Retry | 失败恢复 | 保持单行 |
| 取消 | Cancel | 任务操作 | 保持单行 |
| 设置 | Settings | 齿轮 tooltip/辅助入口 | 保持单行 |
| 应用前状态已恢复 | Previous State Restored | 回滚结果 | 可在详情区域换行 |

可访问 label/hint 不受可见按钮宽度限制，但必须使用简洁、准确、可本地化的句子。英文 UI 不能出现 `Install a Game`、`Success` 或 `Fix Applied` 这类与当前实际状态或当前路径定位流程不一致的预设文案。

## 9. 验收清单

- [ ] 游戏图标和设置齿轮都是标准 `Button` 语义；不存在以 `onTapGesture` 作为入口动作的定义。
- [ ] 每个图标有本地化 accessibility label、value、hint，并能被 VoiceOver 激活。
- [ ] 游戏图标、设置、主操作、取消、重试和回滚均有键盘行为和焦点顺序定义。
- [ ] hover 只改变反馈，不改变命中区域；键盘 focus 不依赖 hover。
- [ ] `pending`、`running`、`failed`、`cancelled`、`completed` 与业务 outcome 分开呈现。
- [ ] 真实进度、失败、取消清理和重试条件可见；没有可信进度时不显示伪百分比。
- [ ] `Unavailable`、权限失败、回滚已确认和回滚未确认均有独立 UI；不存在“方案应用成功”替代状态。
- [ ] 主窗口和 Settings 窗口固定尺寸不因英文文案而改变；长文案在详情区域换行。
- [ ] 文档未把不存在的游戏成功、方案成功或自动修复状态写成 UI 状态。
- [ ] 背景组圆点默认隐藏、hover 区域显示、hover 放大/高亮、离开恢复；键盘 focus 可独立显示并提交。
- [ ] Wine 设置页只显示固定 `wine-crossover-11.0-1-signed`、共享 prefix 和单一任务动作；没有版本列表、作用范围或删除入口。
- [ ] Wine 下载、安装、失败、取消和恢复中的状态使用同一任务区域，不因阶段切换改变布局。
- [ ] 三款游戏的共用 runtime/prefix 是只读事实；没有按游戏 Wine 或 prefix 选择控件，也不把公共就绪写成三款游戏均已启动验证。
- [ ] “此 Mac”显示机型、芯片、内存、macOS 版本四行；未读取时显示“未知”，无推断。

## 10. Task 4 几何实施要求

- 实验和决策记录在 `ui-validation-and-accessibility.md`；实现前必须保留 V0/V1/V2 对照证据。
- `GameIconButton` 的稳定命中框为 `64 × 64pt`，玻璃面板为 `56 × 56pt`，游戏 Button 间距为 `12pt`。
- 选中最大 `1.08`、hover 最大 `1.04` 只作用于 glyph；不得对包含 `.glassEffect` 的整体施加 scale，也不得让 transform 改变 hit testing 或布局。
- `PrimaryActionButton` 最小尺寸为 `220 × 64pt`；按钮 disabled 时只在真实任务进行中显示进度指示，静态 `Running` 不显示伪进度。
- 保留现有 `GlassEffectContainer`、Liquid Glass、16pt 圆角和主窗口固定结构；不添加独立 rail 背景或中心信息卡片。

## 11. Task 4 Settings 居中

- Settings 每次出现/重新打开都相对当前主窗口 frame 居中，公式为主窗口中心减去 Settings 尺寸的一半。
- 居中结果限制在当前屏幕 `visibleFrame`，避免红绿灯区域或屏幕边缘裁切。
- 关闭后再次打开重新计算；不把位置写入业务持久化，不改变 `Settings` Scene、`⌘,` 或单实例契约。
- 这属于 `SettingsWindowScene` 的窗口呈现生命周期，不创建新的业务状态、ViewModel 字段或全局导航抽象。

## 12. 完整 Accessibility Tree 实施

不创建 `AccessibilityTree.swift`。各现有视图提供自己的 accessibility modifiers：

| 现有视图 | Tree 角色 | 必须提供 |
|---------|-----------|---------|
| `BackgroundView` / `BackgroundScene` | 装饰层 | `.accessibilityHidden(true)`；不暴露图片、视频、颜色或渐变 |
| `GameSelectionRailView` | contained navigation group | 固定三个游戏 Button 和一个 Settings Button 的顺序 |
| `GameIconContent` | Button label 的视觉内容 | 状态点不单独聚焦；状态放在 Button value 或详情文本 |
| `SettingsButtonView` | Button | 本地化 label/value/hint，Space/Return 和 `⌘,` 激活同一动作 |
| `PrimaryActionButton` | Button | 当前动作 label、业务/task value、disabled 状态；不把 `completed` 自动读作成功 |
| `TaskFeedbackView` | status group | 目标、任务类型、phase、真实进度/不定进度、当前终态 |
| `ErrorRecoveryView` | status group | 失败阶段、事实、是否有副作用、唯一恢复动作 |
| `Retry` / `Choose Again` / `Reauthorize` | Button | 明确目标的 label、可执行动作和新任务语义 |
| 回滚反馈 | read-only status | 回滚中不可取消；`RolledBack` 读作“方案未应用，应用前状态已恢复并确认” |

### 12.1 启动进度与错误恢复

| 状态 | VoiceOver value | 键盘/动作 |
|------|----------------|-----------|
| `pending` | `已提交，等待执行` | 可取消任务提供 `取消{目标}` |
| `running` | `{阶段}` + 真实百分比，或 `进行中` | 可取消任务提供 Cancel；回滚任务无 Cancel |
| `failed` | 目标、失败阶段、事实和当前终态 | 仅提供有效 Retry、Choose Again、Reauthorize 或日志动作 |
| `cancelled` | `已取消，清理已确认` | 重新提交新任务 |
| `completed` | 具体 outcome，例如 `已确认游戏正在运行` | 不显示或朗读通用成功 |
| 权限失败 | `无法访问所选游戏路径，需要重新授权或重新选择` | Reauthorize/Choose Again |
| `Unavailable` | `兼容方案不可用：{原因}` | 查看原因或选择其他方案 |
| 回滚中 | `正在恢复应用前状态` | 等待，不可取消 |

游戏 Button 的 label/value/hint、焦点顺序、装饰背景隐藏和证据格式见 `ui-validation-and-accessibility.md`。

## 13. 背景组圆点 hover 预览（I-2 冻结）

### 13.1 显示、位置与 hover

| 状态 | UI 规格 |
|---|---|
| 默认 | 圆点容器 `opacity 0`；不参与指针 hit testing；仍保留在键盘焦点顺序与 VoiceOver 树中 |
| 指针进入顶部悬停区 | 圆点容器 `opacity 1`，圆点可被鼠标激活 |
| 指针离开顶部悬停区 | 圆点恢复 `opacity 0`；画面恢复当前选中组，不提交、不写回 |
| 键盘焦点进入任一圆点 | 圆点容器显示，焦点环可见；与鼠标显示使用同一可见状态 |
| 仅 1 个有效组 | 不创建圆点控制，也不制造单项焦点 |

位置规格：

- 悬停区固定高 `40pt`，位于窗口顶部 `0...40pt`，水平居中，宽度为圆点行宽度加两侧 `48pt` 安全余量，最大 `360pt`。
- 圆点行位于 `top: 12pt`；单圆点命中框 `24 × 24pt`；HStack 间距 `10pt`。
- 圆点内容默认直径 `10pt`；hover 放大 `1.2` 并高亮，仅作用于圆点内容，不改变命中框、间距或容器尺寸。
- 圆点区与 GameSelectionRailView、PrimaryActionView 的 frame 不相交；底部操作区顶部 y ≥ `300pt`，垂直净距 ≥ `264pt`。

### 13.2 圆点语义

- 圆点 Button 的 accessibility label 为 `{组名}背景组`；value 为 `当前选中`、`预览中`、`加载中` 或 `加载失败` 中当前结构化事实；hint 为 `离开恢复当前选中组；Return/Space 提交`。
- hover 预览、加载、失败都不改变当前选中组，不写持久化，不删除缓存。
- 预览加载失败时，在当前选中组保持的前提下显示失败事实；重试入口只在 ViewModel/Domain 提供真实动作时出现。

## 14. 统一 Wine runtime 与共享 prefix（Product/Research 回溯，2026-08-28）

Wine 环境 Pane 只表达一个固定运行时产品事实，不提供用户选择模型：

| 区域 | 结构 | 稳定约束 |
|---|---|---|
| 固定 runtime | 只读 `LabeledContent`：`wine-crossover-11.0-1-signed`、MiPlay 托管状态 | min `42pt`；不显示可选版本、不提供来源选择 |
| 共享 prefix | 只读 `LabeledContent`：共享 prefix 状态 | min `42pt`；不显示路径、不提供按游戏 prefix 控件 |
| 三款游戏共用事实 | 只读行或只读三行：原神、星穹铁道、绝区零均使用同一 runtime/prefix | 不显示每款游戏不同 runtime/prefix；不提供选择、解绑或删除 |
| 当前任务 | 固定目标、阶段、真实进度/进度未知、传输、速度、失败/恢复事实 | 区域固定 `122pt`；任务字段不因下载/安装/恢复切换而重排 |
| 任务动作 | 一个标准 Button 动作槽 | 依上游 action 呈现下载并安装、重试或取消；同一位置只出现一个动作 |

### 14.1 交互与可访问性

| 语言 | label | value | hint |
|---|---|---|---|
| 中文 | `统一 Wine 运行环境` | 固定 runtime 状态、共享 prefix 状态、当前任务事实 | `查看统一运行环境状态` |
| English | `Managed Wine runtime` | Fixed runtime state, shared prefix state, current task facts | `View the shared runtime status` |

约束：

- 页面不出现“全局 / 单独”、`Picker`、版本列表、来源选择、外部 Wine、外部 prefix 或删除固定 runtime/prefix 的语义。
- 统一任务按钮的可见文案由上游提供的 action 决定：未形成托管安装事实时为下载并安装，失败或恢复允许时为重试，任务进行中且可取消时为取消；UI 不自行判断条件。
- 下载、安装、共享 prefix 准备和目标游戏启动前置验证必须分开显示。共享 prefix 已就绪不等于三款游戏启动前置均已通过。
- 失败、取消或恢复未确认时，页面保留此前有效的固定 runtime/prefix 事实；不得用部分文件、目录存在或日志内容替代状态。
- 共享 prefix 的资源锁、并发限制和生命周期由 Architecture/Implementation 定义；UI 只展示其结构化投影。

## 15. “此 Mac”信息行（I-5 冻结）

通用 Pane 的“此 Mac”为只读四行：

| 行 | 已确认值 | 未读取/空值 | 读取失败 |
|---|---|---|---|
| 机型 | 系统报告的 machine name | `机型未知` | `无法读取机型` |
| 芯片 | 系统报告的 chip name | `芯片未知` | `无法读取芯片` |
| 内存 | 系统报告的物理内存 | `内存未知` | `无法读取内存` |
| macOS 版本 | 系统报告的产品版本 | `macOS 版本未知` | `无法读取 macOS 版本` |

- 每行使用 `LabeledContent`，行高 min `42pt`；未知或失败字段不显示空值、0、默认值或旧缓存。
- model identifier 与 build number 不作为主层级字段。
- Wine 目标磁盘空间作为独立只读行，失败显示 `无法读取目标磁盘空间`；不并入“此 Mac”主层级，也不作为 runtime/prefix 就绪结论。
- VoiceOver 将“此 Mac”作为只读状态组：label `此 Mac`，value 为四个字段值及各自读取状态；单个字段失败只影响该字段。
