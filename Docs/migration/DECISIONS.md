# 决策与历史背景

证据优先顺序：当前 Git/源码与有身份的运行证据 → 明确用户约定 → 对应版本历史设计；出现冲突必须列出时点和验证局限，保留旧文档。

| 决策 | 选择与理由 | 替代/限制/调整空间 | 依据 |
|---|---|---|---|
| 仓库独立、工程上下文协同 | MiPlay 保留原生启动器职责，DXMT/LSFG 独立研发；统一工作区不合仓库 | 正式工程命名、负责人及产物发布契约待确认 | 用户2026-10-12冻结指令、References/README |
| Domain actor / UI MainActor | 状态事实由领域持有，UI snapshot/event 投影；避免不受控跨线程业务写入 | 当前编译为 Swift5，非所有默认隔离都自然正确；Swift6测试仍欠缺 | ADR002/003、源码及最新恢复报告 |
| 固定 Wine + 单 shared Prefix | 不继承用户任意旧 Wine 或旧 per-game prefix；runtime/prefix成对验证和恢复 | 共享状态会限制并发；多 Wine是旧愿景而非现产品开关 | ADR037–042、BuiltInWineVersions、schema4 |
| Bookmark授权而非裸路径 | 迁移不以 lastKnownPath 静默重新授权；scope覆盖会话 | 测试宿主身份不同要自己的bookmark；不能复制书签就声称另一机器可运行 | ADR004、GameLocation、生产验收fixture |
| 启动结果与恢复事实 | request/receipt/outcome、进程健康确认、退出提交与恢复分离 | 包装进程健康确认不足以证明实际游戏；人工场景验收仍必要 | ADR007/008/009、用户严格验收标准 |
| Steam与Jadeite按游戏配置 | 原神/ZZZ共享Steam存根与timeout；崩铁Jadeite、供应商扩展，msync/esync按profile | 曾试原神直启/云参数，历史内核驱动失败；不能将三游戏全部开关合并 | yaagl-launch-profiles、LaunchCompatibilityEnvironment |
| DXMT确定性初始化修复 | base654f547 + upstream fb451568，device_声明和初始化先于助手；完整重建七件套、版本/哈希固定 | 官方0.80仅为最后替代计划，未执行；patch不是官方0.80。独立DXMTfork现HEAD不自动替换当前资产 | 7e12d77、Tools/DXMT、ASSET_MANIFEST、旧→新→旧→新设备回归 |
| 清理唯一所有者与会话内恢复 | monitor提交退出和释放lease，主动取消等待；b5ce2b6区分session在途/进程已退出，先清lease再消费恢复事实 | 不确认进程退出时不强行放行恢复；未知进程状态仍应fail closed | 7e12d77、b5ce2b6、SchedulerRecoveryTests |
| 不把单次存活当稳定 | 连续5次，确认真实PID和角色画面后≥180秒，独立启动、截图/日志/响应；失败归零 | 登录、Steam/Wine存活、XCTest通过都不足；后续补丁后异常线索不能被旧验收抹去 | zzz-initialization-repair报告与QA acceptance-results |
| 图形环境过滤保持精确 | 剔除继承Metal validation变量；DYLD污染按证据实验 | 未证明DYLD_LIBRARY_PATH或NVAPI/NGX是唯一根因；关闭NVEXT仍可能遇核心D3D缺陷 | ProcessManager、隔离矩阵、DYLD A/B记录 |
| MetalFX空间缩放搁置、DLSS实验 | 当前空间缩放项不进入正常启动；DLSS原生游戏接口可映射NGX/MetalFX时间缩放 | DLSS不是帧生成，也不是LSFG；质量由游戏选，AppleSilicon限制，开关实机兼容未充分测 | research-dxmt-metalfx、DLSS文档、PerformanceOptionManager |
| Liquid Glass保留 | 设置key输入与主窗口main外观分离，保留系统玻璃 | NSVisualEffectView.active稳定但用户拒绝视觉替代；未提交修订记录像素探针，勿回退为旧“未解决”结论 | AppDelegate、implementation-notes当前修改、WindowFocusGlass QA |
| 新闻作为附加功能 | 官方HoYoPlay接口，游戏身份校验，缓存先行失败降级，旧请求不覆盖；原生Link | 暂为国服简中；第三方Mingora是研究参考，不复制其业务实现、没有服务端 | Docs/GameNews、News代码与测试 |
| 视频CRF14而非极端无损 | 保留源1080p/帧率，veryslow和质量标记；Wine/素材准备并行减少串行等待 | 历史CRF0体积大，CRF18画质偏低；不能恢复源压缩损失或承诺所有机器性能 | Docs/VideoQuality、MediaTranscoder |
| 系统修改不默认开放 | publishedSolutions为空，没签名helper就不广告危险动作 | 历史方案定义保留研究；不自动写hosts/hostname、关闭SIP或降低安全策略 | ADR005、BuiltInSolutions、用户环境保护约定 |

## 必须保留的冲突/信息缺口

- 第一阶段性能审计曾把“缺preferredMaxFrameRate=60”列P0；第二阶段源码推导认为不能解释平均FPS更低，应以第二阶段修正结论为准，E1不直接变成修复任务。
- 五轮ZZZ验收是修复版本的真实历史成功；后续文档引用单次补丁后崩溃但没有完整游戏栈/新的受控实验。需要核验日志是否同一加载资产/会话，不能把任一文档当作全局稳定或全局失败证明。
- `fix-launch-session-recovery`报告有“未提交”历史字样，但HEAD b5ce2b6已含生产和测试改动；报告需要交接后审核提交，不自动覆盖原稿。
- 历史设计可能列5款游戏、详情窗口、游戏下载/更新或多Wine；实际代码有3类型和受限支持任务，计划不能写成实现。

系统修改边界还存在实现例外：崩铁 `GameLaunchPreparation.beginStarRailNetworkWindow` 走带管理员授权提示的osascript、短时hosts两行标记清理，未使用历史ADR要求的签名helper。该差异必须由工程级审查，迁移不修复/执行。

冻结本身是新约定：本轮不开展任何候选修复/接入，不merge仓库、不更换Wine/DXMT、不重建Prefix、不清游戏缓存、不提交/推送。新工作区须收到工程级继续指令才恢复开发。
