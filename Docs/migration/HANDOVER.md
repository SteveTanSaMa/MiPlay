> 2026-10-13 更新：应用仓库已实际迁入 `Developer/MiPlay/MiPlay App`。先读 [WORKSPACE_MIGRATION](WORKSPACE_MIGRATION.md) 获取新根、路径修复与最新验证；本文件其余内容保留冻结时交接背景。

# MiPlay 开发交接

**冻结于2026-10-12（Asia/Shanghai）**。本文件可独立引导新AI对话；常规开发禁止自行恢复，先等待新的工程级指令。冻结基准 main / `b5ce2b675529765670470a51193065dd76033adb`；此交接包与原有4份文档改动暂未commit或push。

## 1. 这是什么项目

MiPlay是原生macOS米哈游启动器，负责已有游戏定位、单一Wine+sharedPrefix管理、DXMT与各游戏启动兼容、退出/恢复、官方背景/图标/新闻。独立仓库不与DSH业务合并；正式所属工程名称、成员与协调负责人待确认。3款游戏有代码，非5款全面交付；完整安装/Sophon更新未实现。

## 2. 当前进度与最近工作

先读 DEVELOPMENT_STATUS 和 DECISIONS。最近链路：原神相对YAAGL约30vs50FPS的性能调查 → ZZZ Metal异常修复（DXMT成员初始化） → 真实5次≥180秒验收 → 退出cleanup重复lease释放修复 → 最新b5ce2b6会话内恢复修复。

历史五轮的真实角色画面/PID/响应结果可信，但当前 HEAD新增恢复代码，且后续只读审计有残留异常线索，不能把那次成功当成整个工程永不崩溃。新audit还确认保存分辨率/画质不等价，削弱最初60帧上限假设。继续前请核对版本、文件哈希、实际加载链和报告时点。

## 3. 未完成成果与绝不能遗漏

- 初始修改 `Docs/05-implementation/implementation-notes.md`；3份未跟踪launch-chain audit/会话恢复报告，路径见 DEVELOPMENT_STATUS，均已保全副本/哈希。
- b5ce2b6已提交恢复代码和5项回归；报告仍有旧“未提交”段落，Git权威，不覆盖历史稿。
- QAArtifacts约26GB，不是普通垃圾：原始DLL备份、已登录隔离Prefix、下载档、完整符号、异常栈、失败试验、5轮画面与运行证据。Gitclone不会带走，迁移需单独保全访问受控资料。
- 崩铁启动有osascript管理员授权/临时hosts副作用；未做真实崩铁认证，冻结不触发。旧系统方案列表为空不代表该路径没有系统修改。
- 当前DXMT本地构建版 `654f547+miplay-fb45156`，未执行官方0.80回退；独立DXMTfork已更先进，但未经集成验证不可换随包资产。
- LSFG独立组件契约已存在，MiPlay未接入；不得声称已支持帧生成。
- 用户原游戏、MiPlay/YAAGL Library数据、运行时、Prefix、shader缓存与系统安全设置不改。
- 用户最新操作约定：**不要自动点击/WASD，由用户操作，只定时截图与记录**。早期原生事件许可已被后续指令收紧，不能沿用旧许可。

## 4. 已确定开发约定

- UI/MainActor展示，Domain actor持有事实，receipt/outcome/恢复记录分离；AppData schema4。
- 固定Wine tag、single sharedPrefix、成对身份/升级/回滚，bookmark不以裸路径替代。
- 原神/ZZZ Steam+timeout，崩铁Jadeite/NV，同步选项按游戏profile；DLSS实验不等于LSFG帧生成。
- 最小生产变更、受控隔离实验；先证据再根因，别把随机NSString接收selector当唯一证明。
- 游戏验收要求连续5次独立启动，真实游戏PID+有效角色画面后计≥180秒，开始/中间/结束截图+进程/环境/日志+操作响应；任一真正验收失败归零，不能用Steam/Wine存活、登录或XCTest冒充。
- 工程根本轮无发现适用AGENTS.md；独立仓库有自己的约定，操作前读该仓库文件，不把MiPlay权限推广到其它仓库。Agent Prompts是旧分工参考，不自动授权新多agent或常规开发。

## 5. 恢复开发前的只读检查

```sh
git status --short --untracked-files=all
git log -5 --oneline
git diff -- Docs/05-implementation/implementation-notes.md
xcodebuild -version
```

确认 migration/七份标准文档+清理清单、本地QA证据可读、当前HEAD是否变化；查看RuntimeAssets/dxmt和jadeite清单、Tools/DXMT补丁/重建工具。不要fetch/pull就假定旧References克隆最新；独立工程与参考clone身份见 INTEGRATION。

不要默认执行 `script/build_and_run.sh`：其默认pkill会终止已有MiPlay，再运行app并可能自动下载/准备环境。冻结期仅构建/假环境测试；真实启动由用户下一阶段明确指令开启。

## 6. 如何验证/恢复环境

本机证据路径是机器特定信息，不可硬编码进业务代码。新机器先clone MiPlay，保留源码+资源+schema数据，安装Xcode与相应macOS；必要时Rosetta；检查FFmpeg/Wine依赖、资源架构和签名。独立DXMT重建依赖LLVM15静态库、LLVM-MinGW、Wine编译SDK/Meson/Ninja/Metal工具；这些不随MiPlay源码库自动具备。Wine下载tag/来源allowlist见BuiltInWineVersions，下载/Prefix初始化属下一阶段，冻结不执行。

构建/自动化（不调用游戏验收）：

```sh
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay \
  -derivedDataPath build/MigrationValidation CODE_SIGNING_ALLOWED=NO build-for-testing
env -u MIPLAY_ZZZ_ACCEPTANCE_ROOT -u MIPLAY_ZZZ_PRODUCTION_ROOT \
  -u TEST_RUNNER_MIPLAY_ZZZ_ACCEPTANCE_ROOT -u TEST_RUNNER_MIPLAY_ZZZ_PRODUCTION_ROOT \
  xcodebuild -project MiPlay.xcodeproj -scheme MiPlay \
  -derivedDataPath build/MigrationValidation CODE_SIGNING_ALLOWED=NO test-without-building
```

应用构建通过≠签名发布成功。自动测试的真实游戏2项按设计跳过，不能把全量绿灯当游戏稳定。全套Swift6测试已有Sendable捕获缺口，继续沿当前Swift5语言模式验证；不为冻结检查修业务代码。

授权真实运行后先用Finder/open启动已构建app，避免Xcode环境成为未知变量；游戏定位确认bookmark与配对runtime/Prefix，不重建用户Prefix。原神需用户进入同场景；ZZZ需用户登录/进入/操作。记录当前实际加载DLL路径+SHA256、Wine版本、Prefix、argv、白名单环境、窗口ID、截图和frame-time；原生screencapture有历史明确许可，键鼠由用户。

## 7. 原计划下一步（冻结，不执行）

1. 对齐审计、五轮证据和最新代码时点；审核未提交文档，澄清残留异常是否来自同一补丁/同一模块链。
2. 原神先对齐实际像素数/Retina/渲染精度/VSync/FPS/画质，再采集帧时间与实际同步/模块，不预设CPU瓶颈。
3. 若ZZZ可复现，使用隔离环境和定向异常栈/生命周期诊断；LLDB/Rosetta阻塞就使用替代证据，不关SIP、不吞异常。
4. 对b5ce2b6做获批的真实恢复/快速重启验证；先保全旧pair，不主动制造用户环境损坏。
5. 崩铁与DLSS分别实机认证后，才讨论LSFG/驱动/签名接入；发布和最终资源清理最后执行。

## 新工作区接管建议

- 先读本文件和 MIGRATION_REPORT，再读 DEVELOPMENT_STATUS、DECISIONS、ARCHITECTURE、INTEGRATION。
- 将MiPlay、DXMT、LSFG和DSH两仓库登记为独立根，核对各自Git状态和适用约定；正式工程归属由用户确认。
- 带入未提交文档与必要QA证据，检查保全哈希，不上传账号、Prefix或签名密钥。
- 第一项工作应是核对当前代码/资产/报告的版本关系，列出需要人工验证的问题，随后等待工程级恢复指令。
- 不自行继续开发、换运行时、清缓存、合仓库、commit/push或自动操作游戏。
