# 跨仓库关系与工程协调

本次只读检查 MiPlay、其他仓库 README/部分集成契约、Git HEAD/remote/status。未审计其他项目全部代码、测试或产物；对这些仓库的 dirty 状态仅记录，不改写/提交。共置工作区不等于共享协议。

## 正式工作区布局（2026-10-13 用户指令）

工程根为 `/Users/stevetan/SteveTan/Document/Developer`。MiPlay App 已迁入 `MiPlay/MiPlay App`；DXMT、LSFG 的正式目标为兄弟目录 `MiPlay DXMT`、`MiPlay LSFG`，由各自负责的 Agent 迁移，本 Agent 不移动或修改它们。DSH 两项目正式目标为 `DSH Studio/DSH Studio App` 与 `DSH Studio/DSH Studio Runtime`。旧 Forks 分类废止；下表保留迁移前历史快照，不是当前路径指引。

构建脚本 `Tools/DXMT/build_patched.py` 的 `--source-repo` 应显式传入 `../MiPlay DXMT`；该参数不固定旧 Forks 路径，也不自动采用兄弟仓库当前HEAD。LSFG尚无应用依赖，不能因目录相邻视为已集成。

## 核查矩阵（2026-10-12，历史快照）

| 仓库 | 本地路径 / HEAD | 与MiPlay关系 | 证据/限制 |
|---|---|---|---|
| MiPlay | 当前根；b5ce2b675529765670470a51193065dd76033adb | 应用、Wine管理与游戏集成 | 当前代码/测试/资源是权威 |
| DXMT | `/Users/stevetan/SteveTan/Document/Developer/Forks/DXMT`；05833a54ee4f8a1d3e92e579b92c2fd6494d17f2；dirty | **已验证运行时/构建依赖**，MiPlay随包DXMT/NGX/winemetal | 独立fork当前HEAD不是MiPlay当前资产基线；未评估其全部dirty修改 |
| LSFG | `/Users/stevetan/SteveTan/Document/Developer/Forks/LSFG`；1eeafad68ed4962f5003bc5fc791e4311c621198；dirty | **已验证规划契约，尚未应用接入** | README及Docs/MiPlay-Metal-integration明确MiPlay未接入；未运行预检/真实游戏 |
| DSH-Studio | `/Users/stevetan/SteveTan/Document/Xcode/DSH Studio`；dde66262b2bd0a658d0fa4f8a136f41c1d87fbcb；dirty | **未发现直接应用依赖** | README为DeepSeek Harness Swift外壳；MiPlay源/配置未发现DSH接口，工程级协作角色待确认 |
| DSH-Studio-Runtime | `/Users/stevetan/SteveTan/Document/Xcode/DSH Studio Runtime`；7451b685e1b618380043c6ec34b12f4d08bf3cdb；dirty | **未发现MiPlay依赖**；DSH自身已验证发布关系 | README由官方Harness+Node/pnpm构建不可变artifact、Ed25519 catalog供DSH消费；不是Wine runtime |

ignored参考克隆是另一组身份：`References/dxmt`=e94c312f5c054263acf261cfa109edf13e757587，`References/lsfg`=07647495e85fea78ac30a8499867c51306fee150，均clean。不能把旧参考checkout当独立工程的当前代码。复克隆SSH说明见 References/README；本次不fetch/pull任何仓库。

## DXMT现有产物契约

MiPlay版本 `654f547+miplay-fb45156`，base `654f547ffab4e0c395ee368aad52bb4586b04576`，fix `fb4515681daefb789a4d0f403c4bdbca88f3b3de`，来源3Shain/dxmt；不是官方0.80，也不声称来自上表独立fork最新HEAD。

- 组件：d3d10core.dll、d3d11.dll、dxgi.dll、winemetal.dll、winemetal.so、nvapi64.dll、nvngx.dll。清单SHA256与可追溯补丁保留于RuntimeAssets/dxmt、Tools/DXMT。
- Windows PE x86_64与Unix Mach-O桥接成套构建。Winemetal ABI/对象handle/Metal设备生命周期是版本耦合点；只换d3d11或只改版本常量不能证明安全集成。
- runtime lib/wine/x86_64-windows和x86_64-unix staging；Prefix保留Wine builtin D3D桩，winemetal及opt-in供应商文件有自己的部署路径，旧副本会影响加载。
- DLL架构/哈希、运行日志与进程文件映射须同时记录；声明版本、下载runtime、安装文件、真正加载模块分开确认。
- 构建用Wine SDK v8.16与实际运行Wine11.0不同；LLVM静态库、LLVM-MinGW和Metal工具链路径由参数提供，不把本机绝对路径写入生产代码。

## LSFG未来协调点（未实施）

独立LSFG契约规定 `dist/miplay/lsfg/{liblsfg_metal.dylib,preflight,shader-check,LICENSE,INTEGRATION.md,component.json}`；x86_64组件带版本、commit、工具链和SHA256。商业Lossless Scaling DLL不随组件发布，用户购买/自行导入，MiPlay需bookmark/权限与错误反馈设计。

契约要求Metal路径真实MoltenVK驱动>=1.4.2以及特定Metal/Vulkan扩展、单GPU/队列条件；其文档记述此前MiPlay本机runtime为1.4.1，**本轮没有重新加载驱动确认当前值**。尚不能据此擅自升级Wine或覆盖驱动。

universal GameLauncher可能作为arm64入口，不能直接把x86_64 DYLD_INSERT_LIBRARIES注入它。独立契约建议MiPlay私有中转变量，在child exec x86_64 Wine之前合并注入；禁止注入MiPlay自身、wine --version、Prefix/reg操作。Steam再拉起的真实游戏进程也需确认变量/模块继承。当前 MiPlay没有这套接口或LSFG注入。

还需协调Hardened Runtime/Library Validation、发布签名、post-link strip限制（LSFG契约明确当前包不可再strip）、回退和失败不阻断普通游戏路径。预检/合成通过不等于3款真实游戏兼容。

## 外部共享资源与跨仓库风险

- MiPlay与YAAGL可能操作同一个既有游戏目录，游戏内设置、shader/cache、Vulkan loader移开/恢复会相互影响；各自Prefix/资产不同，不能仅凭同Wine标签假定等价。
- MiPlay使用sharedPrefix、wineserver、运行时文件；多个游戏及外部启动器并发需单独策略，内部lease不是跨程序锁。
- 五轮证据与登录过的隔离Prefix在本地QA，迁移只保全；不能自动成为发布资源，也不能上传凭据。
- DSH两仓库之间已有catalog/manifest/签名/版本规范；MiPlay无该协议消费者，若未来借鉴需设计独立版本/信任边界，不能复用DSH签名密钥或格式而不声明。

## 新工程需统一协调

1. 明确工作区名称、仓库负责人、只读参考与产物来源，避免一个仓库静默覆盖另一个的dirty修改。
2. 固定DXMT/LSFG源码→构建→artifact→MiPlaymanifest的版本映射和升级验收；保持可恢复旧七件套。
3. 跨工程异常归属：MiPlay启动/状态问题 vs DXMT生命周期/Metal问题 vs Wine/Rosetta/驱动问题，先拿到实际模块身份再派工。
4. 统一实验定义与证据命名，性能变量对齐、真实PID/窗口/响应、每次单变量、失败归零。
5. 依赖许可证、用户商业资源、签名/公证与回滚责任，及诊断环境保留/迁移策略。
6. DSH与MiPlay业务/API联系仍待确认；本轮不设计虚构RPC、共享数据库或仓库合并方案。
