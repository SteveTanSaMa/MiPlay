# MiPlay UI 回溯：Wine 设置稳定布局与运行验证

日期：2026-08-05  
责任阶段：UI Agent  
回溯问题：`DL-001`、`DL-003`、`INFO-001`、`INFO-002`、`INFO-003`、`INFO-004`

## 1. 范围与边界

本次 UI 修改依据以下冻结产出：

- `Docs/02-ux/ux-runtime-revision-2026-08-05.md`
- `Docs/01-research/research-wine-archive-and-mac-info-2026-08-05.md`
- `Docs/03-ui/ui-state-mapping.md`
- `Docs/03-ui/ui-window-navigation.md`

本次只修改设置窗口 UI 和 UI 验证资料，不改变 Domain、Infrastructure、Persistence、下载状态来源或 Wine 安装逻辑。UI 不把下载完成、文件存在、解压目录存在或进度达到 100% 显示为安装成功或 `WineReady`。

涉及源码：

- `MiPlay/UI/SettingsWindow/SettingsWineView.swift`
- `MiPlay/UI/SettingsWindow/SettingsAppViews.swift`
- `MiPlay/UI/SettingsWindow/SettingsWindowScene.swift`（固定列宽和相对主窗口定位已由前序 UI 修改保留）

## 2. 抽动原因与实验

### 2.1 原因假设

下载任务原来把阶段、字节量、速度、取消动作和错误内容作为条件视图插入或移除；同一 Wine 版本行的操作列也在“下载、转圈、使用/删除、当前使用”之间改变内容宽度。高频进度事件因此可能同时触发：

1. 任务区域高度变化；
2. `Form` 重新计算 Section 行高；
3. 版本行操作列重新测量；
4. Liquid Glass 材料重新计算边界，造成用户看到的快速抽动或融合。

这不是通过删除错误状态来解决的。错误、取消和恢复事实仍然显示。

### 2.2 实验与结果

| 实验 | 观察 | 决策 |
|---|---|---|
| A：逐项切换动态文本，观察任务区域和版本列表 | 进度、阶段、速度值来自同一任务，但状态子视图会重建 | 保留状态驱动内容，固定父区域和字段位置 |
| B：下载中同时显示真实进度和未知速度 | `ProgressView` 的数值更新不需要改变宽度；未知值如果被移除会改变行结构 | 保留“进度未知/速度未知/大小未知”占位值 |
| C：下载、取消、错误状态切换 | 终态不应挤掉目标和当前任务标题 | 固定 `当前任务` 区域为 `122pt`，终态复用同一内容区域 |
| D：操作列切换 Download/Busy/Use/Delete/Current | 文案和按钮数量不同会改变右侧测量结果 | Wine 行高度 `48pt`，右侧操作列固定 `136pt` |
| E：高频进度更新时保留 SwiftUI 默认事务 | 进度事件可能带来隐式布局动画 | 任务区域使用 `transaction.animation = nil`；数值仍更新，错误仍显示 |

实测下载中截图的窗口像素尺寸均为 `800 × 480`（包括标题栏），设置内容区保持同一窗口边界。运行时 AX 树连续读到同一任务区域，只更新目标状态、阶段、进度和传输值；未观察到 Section 被替换或错误覆盖其他控件。

## 3. 稳定布局契约

| 区域/字段 | 稳定约束 | 动态内容规则 |
|---|---:|---|
| Settings 窗口 | `800 × 448pt` 内容尺寸 | 打开时相对主窗口中心定位，重新打开重新计算 |
| Sidebar | `min/ideal/max = 240pt` | 分隔线不可拖动到消失 |
| Detail | `min/ideal/max = 560pt` | 内容在 Detail 内滚动，不改变列宽 |
| 当前任务区域 | `122pt` | idle、pending、running、completed、failed、cancelled、recovery 共用区域 |
| 进度指示器 | `220 × 16pt` | 真实估算用确定进度，否则显示 indeterminate |
| 目标/状态行 | `20pt` 高，状态列 `72pt` | 版本标签最多一行，中间截断 |
| 阶段行 | `22pt` 高 | 阶段值最多一行，尾部截断；不创建新行 |
| 传输行 | `18pt` 高，速度列 `84pt` | 真实字节/速度显示真实值，否则显示未知占位 |
| 取消按钮 | `24pt` 高 | 只在 pending/running 出现；父区域仍保持固定高度 |
| Wine 版本行 | `48pt` 高 | 名称一行，tag 中间截断 |
| Wine 操作列 | `136pt` | Download、Busy、Use/Delete、Current 在同一列内切换 |

动态文案不会以硬编码的最长字符串作为唯一依据；尺寸约束、单行截断和未知占位共同保证窗口不跳动。Liquid Glass 材料和设置窗口导航契约保持不变。

## 4. UI 状态映射

| 真实状态 | 任务区呈现 | 允许的结论/动作 |
|---|---|---|
| 无任务 | `暂无 Wine 下载或安装任务` | 不显示成功状态 |
| `pending` | 目标 + `等待中` + indeterminate/占位字段 | 可取消；不改变已安装版本和当前运行时 |
| `running` 下载 | 目标 + `进行中` + 真实阶段、真实进度（若有）、字节和速度（若有） | 可取消；不显示已安装或 `WineReady` |
| `running` 安装/验证 | 目标 + `进行中` + 安装/验证阶段；无真实下载数据时显示未知 | 等待或按上游规则取消；不进入已安装列表 |
| `completed` 且 `outcome = wineInstalled` | 任务完成事实；当前运行时由独立状态行重读 | 只在安装事实重读后显示已安装；不自动显示选中或游戏就绪 |
| `completed` 但缺少安装结果 | `任务已完成，但安装结果未确认` | 保留错误/恢复事实；不显示成功 |
| `failed` | `失败` 或 `需要恢复` + 原因 | 错误不会覆盖其他控件；旧的有效版本保持不变 |
| `cancelled` 且 `cleanupVerified` | `已取消` + `下载已取消，临时资源清理已确认` | 可再次选择可用版本；不显示安装成功 |
| `cancelled` 但清理未确认 | `需要恢复` + recovery 原因 | 不允许 UI 自行创建重试任务；先由上游恢复事实 |
| Wine 目录查询中 | 可用版本 Section 内稳定显示 `正在获取版本` | 不把查询中当作空列表 |
| Wine 目录失败/不可用 | 保留错误原因和“版本目录不可用”状态 | 不把 403、网络失败或无效目录改写成空列表 |

### 4.1 当前运行时、可用版本、已安装版本

Wine 环境页明确分成四个 Section：

1. `当前运行时`：托管 Wine 的安装与就绪事实、来源和重新检测入口；不展示任意系统 `wine` 路径。
2. `当前任务`：下载、安装、验证、取消、失败和恢复中的目标及进展。
3. `已安装版本`：MiPlay 管理范围内可重读的本地安装事实。
4. `可用版本`：批准来源目录返回的可获取版本；目录结果不覆盖本地已安装事实。

`当前运行时` 在全局 Settings 中只表达托管运行时事实；具体 Game ID 的 prefix/readiness 仍由 per-game 设置和启动前置流程表达，不能用全局状态冒充某款游戏已就绪。

### 4.2 此 Mac

`此 Mac` 移到通用设置，作为只读信息组展示：

- `机型标识`：当前数据源返回的 model identifier，例如 `MacBookPro18,1`；不称为芯片名称，也不推导 16 英寸营销名称。
- `macOS 版本`：当前数据源返回的产品版本。
- `磁盘空间`：面向 Wine 管理目标卷的可读结果；检测失败显示 `无法读取目标磁盘空间`，不把空值或 0 显示成剩余空间。

`INFO-003` 的真实机型名称和芯片字段仍需 Research/Infrastructure 修复数据源；UI 已停止把 model identifier 命名为“芯片”。`INFO-004` 的检测失败也不能由 UI 猜测或替换为根卷空间。

## 5. 运行时 Accessibility 证据

使用刚构建的 `/tmp/MiPlayDerivedData/Build/Products/Debug/MiPlay.app` 读取实际 AX 树，结果如下：

| 控件/状态 | 运行时语义 |
|---|---|
| Settings splitter | `disabled`，值 `240`；sidebar 不可拖到消失 |
| 当前任务 | `Description: Wine 当前任务`，Details 包含目标、状态、阶段、进度、传输量和速度 |
| 下载进度 | `Description: 下载进度`，Value 为真实比例，Details 为百分比 |
| 传输信息 | 独立状态对象，Details 为字节量和速度；未知值明确读为未知/Zero KB/s，不虚构速度 |
| 取消 | `Description: 取消 Wine 下载`，Hint 为停止下载并清理临时资源 |
| 下载版本 | `Description: 下载 {版本名}`，Hint 明确下载完成不代表选中或游戏就绪 |
| 当前运行时 | 安装与就绪值、托管来源和重新检测按钮均可读 |
| 此 Mac | `机型标识`、`macOS 版本`、`磁盘空间` 为同一只读状态组；失败值明确为无法读取目标磁盘空间 |

VoiceOver/键盘可达性要求：所有 `Button` 使用 Return/Space，sidebar 行使用方向键选择；取消按钮只在任务可取消时存在并保持标准 Button 语义。高频速度采样作为状态 value 更新，不新增逐采样 announcement。重试和恢复动作只有在 ViewModel/Domain 提供真实 action 后才能出现；本轮不创建假的按钮。

## 6. 截图验证矩阵

截图均为 macOS 运行时截图，设置窗口内容尺寸为 `800 × 448pt`，图片包含标题栏所以像素尺寸为 `800 × 480`。

| 场景 | 证据 | 结果 |
|---|---|---|
| 主窗口正常/hover/高对比度/Reduce Motion | `validation-artifacts/main-normal.jpg`、`main-hover-focus.jpg`、`main-increase-contrast.jpg`、`main-reduce-motion.jpg` | 前序 UI/P1-08 运行验证资料；本轮未改变主窗口结构 |
| 通用 Settings 与 Mac 信息 | `validation-artifacts/settings-general-mac-info-latest.jpg` | “此 Mac”独立分组；真实未知/失败值没有被伪造 |
| Wine 任务 idle | `validation-artifacts/settings-wine-cancelled-full-latest.jpg` 的任务区域仍占固定高度 | 终态区域不消失 |
| Wine 下载中 | `validation-artifacts/settings-wine-progress-full.jpg` | 目标、阶段、进度、传输量、速度和取消控件在固定区域内；动态值未改变主区域边界 |
| Wine 取消且清理确认 | `validation-artifacts/settings-wine-cancelled-full-latest.jpg` | 只更新为已取消事实，不显示安装成功 |
| Wine 失败/恢复 | `validation-artifacts/settings-wine-recovery.jpg` | 错误原因可见；旧版本保持不变；恢复状态不冒充成功 |
| 安装中/安装成功 | 无截图 | 本次真实下载在下载阶段取消；当前归档可执行文件验证问题使 UI 不得伪造 `wineInstalled`。状态映射已定义，需上游修复后补运行证据 |
| 重试 | 无截图 | 当前 SettingsViewModel 没有 Wine 任务重试/恢复 action；本轮明确不凭 UI 增加业务动作，回溯到 Architecture/Implementation |
| Settings 重新打开 | `settings-general-mac-info-latest.jpg`、`settings-wine-progress-full.jpg` | 重新打开后列宽和内容尺寸保持；定位逻辑由 `SettingsWindowPositioner` 相对主窗口居中 |

## 7. 结论

- `DL-001`：UI 修复完成。下载动态字段不再决定 Section 尺寸，操作列和任务区固定，进度更新关闭局部隐式布局动画。
- `INFO-001`、`INFO-002`：UI 结构完成。当前运行时、当前任务、已安装版本和可用版本分层显示。
- `INFO-003`、`INFO-004`：UI 不再扩大错误。当前 model identifier 和磁盘检测失败如实展示，真实机型/芯片和目标卷检测仍回溯 Research/Infrastructure。
- `DL-003`：UI 不显示不存在的成功状态；归档路径和 Wine 可执行文件验证继续由 Research/Implementation 负责。
- 安装成功与任务重试的运行证据暂不宣称完成，原因是当前上游状态/action 尚未提供可验证条件。

