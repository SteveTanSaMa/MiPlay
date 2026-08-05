# MiPlay Product Revision 2026-08-03

> **文档状态**：已冻结（Freezed）
> **责任阶段**：Product / Review 后用户验证回溯
> **适用范围**：当前版本产品边界、发布清单和验收口径
> **权限边界**：本文只定义做什么；不定义 Swift、服务协议或实现结构。

## 1. 冻结结论

1. 当前版本只支持 MiPlay 托管的 Wine。系统 Wine、Whisky、CrossOver 或其他本机 Wine 不被检测、展示、导入或复用。
2. Wine 默认来源是官方 GitHub；用户可选择预置可信镜像 allowlist，但不得自由输入 URL。来源失败不能伪造成功，也不能静默回退到外部 Wine 或 allowlist 外来源。
3. `config.ini` 只展示目标游戏可读取的原始 section、key 和 value。不得猜测 `channel`、`cps` 等字段的友好含义，不得把展示值单独升级为版本或完整性结论。
4. 游戏设置按 Game ID 独立保存；全局 Wine 来源选择不等于游戏级设置。多背景组也按 Game ID 独立切换。
5. 完整性校验必须使用非空、与目标游戏及客户端版本对应的 manifest。manifest 不支持、为空、缺失、版本不对应或无法验证时，结果只能是“不支持/无法判定”，不能报告通过。
6. 六项高级配置属于当前版本产品目标，但本轮 Deferred：Retina、Steam patch / Steam 白名单、旧版反作弊文件替换、Metal HUD、左 Command 映射 Control、hosts 屏蔽。Deferred 不得标记为已完成或可应用。
7. 当前轮次的兼容方案发布清单只包含 `CS-01` 修改 Hostname，且仍是有条件可用；其余四项不全部删除，而是按下表分别保留为 Deferred 目标或排除项。

## 2. 状态词义

“当前版本范围”与“本轮实现/发布状态”是两个独立维度：

| 词语 | 产品语义 |
|---|---|
| `In Scope` | 当前版本必须保留该用户问题或能力目标；不代表代码已经完成。 |
| `Published` | 本轮允许进入发布验收清单；必须有真实资源、真实权限、后置验证和回滚证据。 |
| `Deferred` | 目标仍属于当前版本，但本轮不进入 Implementation、用户验收或 Release 通过门槛；不得显示为可应用。 |
| `Out of Scope` | 当前版本不承诺该能力；不得通过相似代码入口或诊断信息重新纳入。 |
| `Applied` / `.applied` | 真实操作完成、后置状态读回验证通过、应用记录提交成功，且保存的应用前状态仍可用于恢复。 |
| `Unavailable` | 资源、适用游戏或权限能力不满足；不得提供可应用语义，也不得创建 `Applied`。 |

用户点击、任务入队、代码入口存在、备份成功、日志成功或目录存在，都不能单独产生 `Applied`。

## 3. 用户反馈与问题追溯

| ID | 输入事实 | Product 决策 | 当前轮次边界 |
|---|---|---|---|
| UV-001 | 主界面视觉仍需用户验证。 | 保留游戏启动和状态总览问题；视觉尺寸、hover 和材质不在 Product 层新增行为。 | 由 UI / Implementation / 用户验证处理，不改变功能范围。 |
| UV-002 | 设置窗口布局仍需用户验证。 | 冻结设置的产品内容为全局来源策略、原始配置展示和按游戏独立设置；窗口布局交给 UX/UI。 | 不以布局代码存在作为产品通过。 |
| UV-003 | 系统 Wine、Whisky、CrossOver 可能缺少项目所需修改。 | 删除本机 Wine 检测功能；只承认 MiPlay 托管 Wine。 | 不得有外部 Wine 诊断入口、状态或 fallback。 |
| UV-004 | GitHub 请求超时，镜像需求仍存在。 | 默认官方 GitHub；预置可信镜像 allowlist 可选；禁止任意 URL。 | 请求超时、空目录、限流、重定向无法验证和不完整下载均为失败/不可用。 |
| UV-005 | 游戏 metadata 的字段、映射和冲突语义未关闭。 | 保留 `config.ini` 原始字段；完整性只接受非空且版本对应 manifest。 | 不猜测 `channel`、`cps`，不把 `game_version` 单独当作完整性真相。 |
| UV-006 | 设置页面结构仍未通过用户验证。 | 冻结全局设置与 Game ID 设置的业务边界，不冻结页面布局。 | UI 未验证不影响本 Product 需求，但不能被静态结构折算为通过。 |
| UV-007 | YAAGL 研究未提供镜像能力。 | 镜像是用户的来源策略需求，不因参考项目没有该能力而否决。 | 只允许产品冻结的镜像 allowlist；不设计任意镜像协议。 |
| UV-008 | 高级游戏配置范围需要重新收敛。 | 六项高级配置纳入当前版本目标，全部标为本轮 Deferred。 | 不进入本轮 Implementation 或 Release 验收；不得标记已完成。 |
| UV-009 | 多背景切换流程需要产品边界。 | 每款游戏可选择自己的有效背景组；切换不串用其他游戏。 | 目标组失败时保留上一有效组并保留失败事实。 |
| UV-010 | Apple 无障碍需要真实运行验证。 | 保留启动、状态、设置和恢复等产品状态；不新增无障碍实现方案。 | VoiceOver、键盘和 AX tree 由 UI / Apple Review / 用户验证关闭。 |
| P1-REV-003 | 重启恢复后的 retry 和 Domain 门禁未关闭。 | 产品上，存在未完成恢复事实时，同一游戏不得被报告为正常可启动。 | 回溯 Implementation；不得用 UI 禁用或测试入口代替恢复闭环。 |
| P1-REV-004 | 五个 stale bookmark 消费者缺完整行为证据。 | 路径授权或写回失败时，不得报告完整性、版本或启动成功。 | 回溯 Implementation；静态调用图不构成产品通过。 |
| P1-UV-003 | 本地 metadata 证据字段和冲突语义缺失。 | 原始配置展示与 manifest 完整性规则冻结，不能被简化为单一版本字段。 | 回溯 Implementation；不改变 Research 事实。 |
| P1-UV-006 | AX tree / VoiceOver / 键盘真实证据缺失。 | 保持为外部验证阻塞，不把静态 modifier 当作通过。 | 继续由 UI / Apple Review 处理。 |
| REV-005 / DOC-REV-001 | Implementation / QA 仍有旧完成口径。 | 本文和更新后的 Product 文档是范围依据；旧下游表述不得覆盖本冻结。 | 责任回溯到 Implementation / QA；Product 不替下游修改旧文档。 |

网络事实也纳入当前边界：GitHub 仓库请求超时；Wine 资产收到 302 后约下载 5.75 MB / 417 MB 即超时。两者都不是通过证据。

## 4. Must / Should / Deferred / Out of Scope

| 优先级 | 能力 | 当前版本范围 | 本轮状态 | 产品验收边界 |
|---|---|---|---|---|
| Must | MiPlay 托管 Wine | In Scope | 未因网络失败而通过 | 只有批准来源取得、验证、托管安装、运行环境和持久记录均完成才可 `WineReady`。 |
| Must | 官方 GitHub + 可信镜像选择 | In Scope | 策略已冻结，真实网络未通过 | 默认官方 GitHub；镜像只能来自 allowlist；不允许任意 URL；失败不得假成功或外部 fallback。 |
| Must | 已安装游戏路径、启动和状态 | In Scope | 用户/真实 Wine 验证未通过 | 面向已安装游戏；官方游戏安装不在本轮。存在恢复事实时不得报告正常启动。 |
| Must | 原始 `config.ini` 展示 | In Scope | 需求已冻结，P1-UV-003 仍待实现关闭 | 保留原始字段和值；不猜测字段映射，不把单字段当版本或完整性结论。 |
| Must | 按游戏独立设置 | In Scope | 需求已冻结 | 读取、保存和失败事实按 Game ID 隔离；不与全局来源选择混同。 |
| Must | 多背景组切换 | In Scope | 需求已冻结，用户验证待完成 | 背景组按 Game ID 隔离；组不可用时保留上一有效组。 |
| Must | 完整性校验 | In Scope | 生产 manifest/真实渠道仍待验证 | 非空且版本对应 manifest 的全部条目通过后才可报告通过；不支持 manifest 不能通过。 |
| Must | `CS-01` 修改 Hostname | In Scope | 本轮发布候选，真实权限和运行证据待完成 | 真实修改、读回验证、应用记录和可恢复原值全部具备才可应用。 |
| Should | 版本检测与更新提示 | In Scope | 保留 | 只提示版本差异，不承担完整游戏更新包下载和安装。 |
| Should | 中文/英文、多语言 | In Scope | 保留 | 当前版本用户可见文案不得出现功能性混用。 |
| Should | 日志导出 | In Scope | 保留 | 导出启动相关日志；不把日志当作功能成功证据。 |
| Deferred | A-01 Retina | In Scope | 本轮 Deferred | 未来真实应用、验证、回滚齐全后才能进入发布清单。 |
| Deferred | A-02 Steam patch / Steam 白名单 | In Scope | 本轮 Deferred | 没有真实 Steam 资源/标识和后置验证时不得展示可应用。 |
| Deferred | A-03 旧版反作弊文件替换 | In Scope | 本轮 Deferred | 没有可随版本交付的真实文件和回滚证据时不得展示可应用。 |
| Deferred | A-04 Metal HUD | In Scope | 本轮 Deferred | 未有真实应用、验证和回滚证据时不得标记完成。 |
| Deferred | A-05 左 Command 映射 Control | In Scope | 本轮 Deferred | 未有真实应用、验证和回滚证据时不得标记完成。 |
| Deferred | A-06 hosts 屏蔽 | In Scope | 本轮 Deferred | 没有真实规则资源、权限和生效验证时不得展示可应用。 |
| Deferred | 官方游戏安装引导 | Future | 本轮不实现 | 继续使用已安装游戏路径；不新增安装器或自动更新功能。 |
| Deferred | 自定义启动参数 | Future | 本轮不实现 | 不提供任意额外启动参数。 |
| Deferred | 帧率解锁 | Future | 本轮不实现 | 不提供游戏级帧率解除。 |
| Deferred | 截图/视频文件夹快捷入口 | Future | 本轮不实现 | 不提供媒体目录快捷入口。 |
| Out of Scope | 本机 Wine 检测、展示、导入、复用 | Out of Scope | 删除 | 任何系统 Wine、Whisky、CrossOver 事实都不形成产品状态。 |
| Out of Scope | 自由输入 Wine URL | Out of Scope | 禁止 | 不提供保存、请求或下载任意 URL 的能力。 |
| Out of Scope | `CS-05 use_legacy_patch` | Out of Scope | 排除 | 用户最新范围没有该额外旧版 DLL 补丁，且资源缺口不能由代码入口补足。 |

## 5. 兼容方案发布清单与验收

### 5.1 五项既有方案的处置

| 方案 | 当前版本产品范围 | 本轮发布清单 | 原因 |
|---|---|---|---|
| `CS-01 modify_hostname` | In Scope | **是，条件可用** | 仍需真实权限、实际修改、读回和回滚证据；不得因代码入口存在而通过。 |
| `CS-02 block_network_anticheat` / hosts 屏蔽 | In Scope，映射 A-06 | **否，Deferred** | 用户要求保留目标，但本轮不实现；资源或权限不足时不可应用。 |
| `CS-03 replace_old_anticheat` | In Scope，映射 A-03 | **否，Deferred** | Review 发现真实旧版资源缺失；目标保留，不展示为可应用。 |
| `CS-04 steam_whitelist` | In Scope，映射 A-02 | **否，Deferred** | Review 发现真实 Steam 标识和配置支持缺失；目标保留，不展示为可应用。 |
| `CS-05 use_legacy_patch` | Out of Scope | **否** | 不是用户最新明确的 Steam patch 或旧反作弊替换目标；不扩大当前版本。 |

因此，五项不全部属于本轮发布清单。缩减理由是“真实资源/权限/后置验证不足”或“没有对应的当前版本用户需求”，由 Product 明确冻结，Implementation 不得自行决定。

### 5.2 发布方案的共同门槛

- 成功：真实目标状态已经改变，后置读取与预期一致，应用前快照已保存，应用记录已提交。
- 失败：资源缺失、适用范围不符、权限未获授、备份失败、写入失败、后置读取不一致或记录提交失败，均不得报告成功。
- 验证：必须检查真实目标状态和应用前快照；代码分支、日志、任务完成或备份成功不能替代验证。
- 回滚：恢复应用前状态并通过对照读取；未完成回滚时不得产生 `Applied`，应保留失败/恢复不完整事实。
- Deferred：没有本轮实现和验收，不创建 `Applied`；“未显示”不等于“已回滚”。

### 5.3 完整性校验门槛

| 情况 | 产品结果 |
|---|---|
| manifest 非空、游戏标识和客户端版本对应、每个必需条目内容通过 | `IntegrityPassed` |
| manifest 存在但任一必需文件缺失或内容不匹配 | `IntegrityFailed` |
| manifest 不支持、为空、缺失、版本不对应或对应关系无法验证 | `IntegrityUnsupported`；不得报告通过 |
| 仅有可执行文件、代码入口、单独 `config.ini` 版本值或 SHA-256 分支 | 不足以形成 `IntegrityPassed` |

## 6. Wine 来源与失败验收矩阵

| 对象 | 成功标准 | 失败/禁止通过 | 恢复语义 |
|---|---|---|---|
| 官方 GitHub | 默认来源，返回 allowlist 范围内、架构匹配且资源身份可验证的版本 | 超时、空目录、限流、重定向无法验证、资源不完整或身份不匹配 | 保留上一有效托管版本；允许重试或改选 allowlist 镜像。 |
| 预置可信镜像 | 用户主动选择 allowlist 中的镜像，并完成同等获取、安装、验证和持久化 | allowlist 外来源或任意 URL 不得请求；失败不得静默使用其他未批准来源 | 保留上一有效选择；新失败资源不得进入可用集合。 |
| MiPlay 托管安装 | 资源验证、安装、运行环境准备、记录提交和重读均完成 | 目录存在、进度完成、`wine --version` 成功或外部 wrapper smoke 不足以通过 | 清理不完整资源；没有有效托管版本时当前游戏为 `NoSelectedRuntime`，已有选中版本但 readiness 失败时为 `SelectedNotReady`。 |
| 本机/第三方 Wine | 无产品能力 | 不检测、不展示、不导入、不复用 | 不改变 MiPlay 状态；不能成为 fallback。 |

## 7. 旧 Product 结论冲突登记

| 旧结论 | 处理 | 新冻结口径 |
|---|---|---|
| 系统 Wine、Whisky、CrossOver 可作为“仅检测信息”。 | **失效并删除** | 完全删除本机 Wine 检测、展示、状态和导入路径。 |
| Wine 只有官方 GitHub，镜像不在产品范围。 | **失效并替换** | 官方 GitHub 是默认来源；预置可信镜像 allowlist 是可选来源；禁止自由 URL。 |
| `CS-01` 与 `CS-02` 是当前发布方案，`CS-03` 至 `CS-05` 全部排除。 | **修订** | 本轮发布清单只有条件 `CS-01`；A-02/A-03/A-06 对应方案保留为当前版本 Deferred；`CS-05` 才是 Out of Scope。 |
| 高级配置属于未来功能或不构成当前版本目标。 | **失效并替换** | 六项高级配置属于当前版本目标，但本轮 Deferred，不能标记完成。 |
| 代码入口或静态解析足以证明能力完成。 | **失效并替换** | 真实资源、权限、后置验证和可回滚状态是发布能力的必要条件。 |
| QA RTM 的旧 Must/Pass 表述可直接作为发布依据。 | **不作为 Product 依据** | Product 本文和 `product-features.md` 的冻结矩阵优先；QA 需回溯同步，不能由本 Product 文档代改。 |

## 8. 下游冻结要求

1. Implementation 只能实现 `Must` 和本轮发布候选 `CS-01`；不得把 Deferred 作为已完成能力，不得加入本机 Wine 检测或任意 URL 输入。
2. UX/UI 可以定义上述产品状态的表达方式，但不得把 Deferred 选项表达成可应用，也不得恢复外部 Wine 诊断入口。
3. Architecture/Research 的技术事实不得反向扩大产品范围；YAAGL 没有镜像能力不构成删除镜像需求的理由。
4. Review、QA 和用户验证只能在满足本文验收门槛后关闭对应问题；静态证据、关闭入口或网络部分下载不能替代真实通过。
