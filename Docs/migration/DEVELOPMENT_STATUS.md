# 当前开发状态（冻结）

日期：2026-10-12；基准 `b5ce2b675529765670470a51193065dd76033adb`。常规开发停止；本任务不提交/推送。最新状态按源码和可读取证据解释，旧报告的“未提交”不覆盖 Git 已提交事实。

## 已完成且有验证依据

| 功能/修复 | 依据 | 验证范围 |
|---|---|---|
| 固定 Wine + shared Prefix、授权/状态/调度/恢复框架 | 源码及 ADR037–042、测试 | 临时目录/假运行时自动化；不等于任意游戏环境通过 |
| 原神/ZZZ Steam 启动、timeout、各游戏同步配置 | LaunchCompatibilityEnvironment、YAAGL profile 文档 | 代码/自动化及历史实机；当前游戏内性能等价未证实 |
| DXMT device_ 初始化修复、七件套重建 | 7e12d77、patch、manifest、旧→新→旧→新设备回归 | 确定初始化缺陷被修；2026-10-10 五轮 ZZZ 181.5/183.4/182.8/183.3/183.2 秒实机画面，证据在 QAArtifacts/ZZZ-Repair-20261010 |
| 退出监控/取消重复释放 lease 修复 | 7e12d77、回归、五轮重启 | 当时生产链路；非所有关闭失败情况都已覆盖 |
| wineserver 清理失败后会话内恢复 | b5ce2b6、SchedulerRecoveryTests、fix-launch-session-recovery 报告 | 假 Wine/Prefix 异常注入与重启；历史报告全量163/0失败/2跳过；本次结果见 MIGRATION_REPORT |
| 官方游戏新闻、缓存/轮播/分类/设置 | ee04690、Docs/GameNews.md、GameNewsTests | 官方接口历史检查、UI人工与单元测试；未来接口变化待维护 |
| 视频高质量转码、质量缓存标记、准备并行 | ee04690、Docs/VideoQuality.md | 历史完整源视频对比/解码及自动化；无性能提升普遍承诺 |
| Liquid Glass 主窗口与设置 key/main 分工 | 当前 AppDelegate、初始未提交 implementation-notes 修订 | 历史像素探针记录；该修订保留，迁移不重复 UI 实验 |

## 已实现但未充分验证

- 崩铁 Jadeite+NV 扩展/注册表、WebView 及管理员授权的短暂 hosts 屏蔽处理：有代码、资产来源哈希和临时测试；**未完成真实崩铁游戏验收**。
- DLSS/NGX Super Resolution 实验开关：Apple Silicon 条件、opt-in 部署和环境；不支持帧生成，本轮没有三游戏 DLSS 开启实机认证。
- 最新 b5ce2b6 的真实 wineserver 故障恢复与快速重启：本次只跑自动化，不故意破坏用户 Prefix。
- 游戏完整性校验框架有实现；不将缺失生产 manifest 的提示降级或测试 manifest 当成全面游戏文件认证。
- 打包签名/公证/升级配对、不同硬件与系统版本、长时间游戏、辅助功能全面检查均未本轮验证。

## 正在进行 → 冻结

| 任务 | 当前进度/文件 | 阻塞/信息缺口 | 恢复后的下一步 |
|---|---|---|---|
| 原神相对 YAAGL 的性能差异调查 | 两份未提交 launch-chain audit；静态分析和旧注册表对照 | 未执行人工 E1–E5；实际帧时间/分辨率/模块链未对齐 | 先核对保存分辨率（报告3456×2234 vs1728×1117）、渲染精度、MotionBlur，受控现场采集；CPU瓶颈未确立 |
| ZZZ 补丁充分性/剩余异常 | 五轮验收报告与后续审计并存，后者引用单次补丁后异常、无完整游戏栈 | 身份、时序、加载哈希与会话归属需追溯；不能凭异常对象名断定另一根因 | 核对真实日志与 manifest；若复现，在隔离环境做定向异常栈/生命周期诊断 |
| 会话内恢复修复交接 | 生产与测试已 b5ce2b6 提交；报告开头还写“未提交”，尾部/历史状态待对照 | 报告时点落后 Git；真实故障未测 | 新工作区先复核当前实现/测试，批准后再针对故障边界实机验证 |
| 文档一致性整理 | implementation-notes 的焦点修订 + 3份新报告未提交 | 历史记录与现状态混合 | 保持原文，交接后决定审核与提交；本轮不覆盖、不仓促修完 |

## 尚未开始/未交付

- LSFG 对 MiPlay 的接入；独立 fork 已写组件契约，不等于 MiPlay 已加载/注入。
- Sophon 增量更新和完整游戏安装器、五款游戏全面覆盖、多 Wine 产品选择。
- 统一工程协调负责人、工作区正式名称和成员目录/发布责任的确认。
- 把 DSH Runtime 的签名/更新实现复用于 MiPlay：仅可能经验借鉴，没有已批准接口或共享代码方案。

## 已知问题与技术债务

1. 游戏性能比较变量不受控：最新第二阶段审计削弱“少60帧上限导致更慢”假设；历史画质配置不同；需真实场景验证。
2. 修复过确定的 DXMT 初始化缺陷，不证明没有独立 device handle 复用/跨线程问题；残留异常线索为待核实证据。
3. Xcode DYLD 路径继承存在；未证实其因果影响，不能无差别清除所有 DYLD_*。
4. LLDB/Rosetta attach/run 阻塞、系统与工具链 beta；已有独立程序也失败记录，不关闭 SIP 或放宽系统策略。
5. 共享 Prefix/wineserver 与游戏文件 staging 是全局状态，跨启动器并发可能互相影响；lease 保护 MiPlay 内部，不保证 YAAGL 并发互斥。
6. staging 的拷贝快捷判断 size+mtime 与发布身份/哈希验证不是一回事；新工作区应保留资产清单与实际加载链的区分。
7. Swift 6 完整测试目标尚未迁移，LaunchOptimizationTests 有 Sendable 捕获问题；源码语言模式仍 Swift 5。
8. `script/build_and_run.sh` 默认 pkill MiPlay 并使用 build/GameNews 目录；冻结验证绕开 kill/自动运行步骤，未来工具改造需另行授权。
9. 崩铁网络兼容当前走osascript管理员授权并修改hosts的短窗口；与历史ADR签名helper目标有差异，实机授权/异常退出恢复尚待验证。新工作区不得因通用publishedSolutions为空就漏掉此副作用。
10. 发布策略、外部组件许可证、Code Signing/Library Validation 与商业 LSFG 用户资源均需协调，不复制密钥或游戏数据进 Git。

## 初始未提交成果保全

- `Docs/05-implementation/implementation-notes.md`（修改）
- `Docs/01-research/fix-launch-session-recovery-2026-10-10.md`（未跟踪）
- `Docs/01-research/investigation-launch-chain-deep-dive-2026-10-10.md`（未跟踪）
- `Docs/01-research/investigation-launch-chain-perf-audit-2026-10-10.md`（未跟踪）

副本、binary diff、初始 status 与 SHA256：`QAArtifacts/MigrationFreeze-20261012/`。新迁移文档也暂未提交；不能把“存在未提交文档”解释为成果丢失或要求自动 commit。
