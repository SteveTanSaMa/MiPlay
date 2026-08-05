# Review 后用户验证研究修订报告

> **Agent**：Research Agent
> **日期**：2026-08-03
> **状态**：Research 修订输出；不修改 Product、UX、UI、Architecture 或源码
> **回溯输入**：Review `Major Revision`、用户网络验证结果、当前冻结 Product/UX 文档
> **研究对象**：`References/YAAGL/` 本地源码快照与现有 `Docs/01-research/` 研究报告

## 1. 目的与证据边界

本报告补充 Review 后仍未关闭的研究问题：

- GitHub API、Release asset、镜像 API 和镜像 asset 是否为独立链路；
- 预置可信镜像 allowlist 的准入门槛，以及当前已知候选的验证状态；
- YAAGL 对原神、星穹铁道、绝区零六项高级配置的真实适用性；
- 多背景资源是否存在可复用的数据模型；
- `pkg_version`、`config.ini` 与 `wpf_version` 的已确认事实；
- YAAGL 代码可作为行为参考的部分，以及不能直接复用的部分。

本报告区分三类内容：

1. **源码事实**：能由 `References/YAAGL/` 文件和行号直接确认；
2. **验证要求**：为了批准来源或报告成功所需的检查，不是新增 Product 决策；
3. **待验证/不可推断**：当前源码、当前机器网络或用户测试没有证明的结论。

当前产品决策作为冻结上下文处理：只使用 MiPlay 托管 Wine；默认官方 GitHub；允许预置可信镜像 allowlist；禁止自由输入 URL；`config.ini` 暂时展示原始字段；六项高级配置属于当前版本目标，但可以暂缓实现。本文不回写这些决策。

## 2. 用户验证结果与可推断范围

以下是本轮用户提供的网络观察，不是中国网络环境的普遍结论：

| 测试对象 | 观察 | 可以确认 | 不能确认 |
|---|---|---|---|
| GitHub 仓库/API 请求 | 请求超时 | 当前测试环境下该请求没有在测试窗口内完成 | 不能证明所有地区、运营商、DNS、IPv4/IPv6 或代理环境均不可达 |
| GitHub Release asset | 返回 HTTP 302 | 资产请求进入了重定向链路 | 302 不等于最终文件已下载，也不证明重定向后的 host 可持续下载 |
| Wine 大文件 | 约 `5.75 MB / 417 MB` 后超时，未完成 | 当前尝试没有形成完整 Wine artifact | 不能计算完整文件摘要，不能进入 `WineReady`，也不能据此判断所有用户下载均失败 |
| YAAGL 镜像 asset | 本轮没有完成独立验证 | 无 | 不能把镜像 API 可用、或 GitHub API 可用，推导为镜像 asset 可用 |

因此当前网络结果的业务结论是：一次下载失败或超时只能进入来源/网络失败路径；不能静默使用外部 Wine、将部分文件标记为已安装，或扩大镜像 allowlist。

## 3. GitHub/API/asset 与镜像链路

### 3.1 YAAGL 的实际链路

`References/YAAGL/src/github.ts:3-48` 的 endpoint 列表只有：

```text
""
"https://ghp.3shain.uk/"
```

YAAGL 在 `${prefix}https://api.github.com/octocat` 上并行竞速，最快返回者被选中；探测读取文本但不检查 HTTP status、正文固定值或官方/代理正文等价性（`References/YAAGL/src/github.ts:5-22`）。选中的 prefix 随后用于 `https://api.github.com${path}`，API 只接受 200、301、302 并调用 `.json()`（`References/YAAGL/src/github.ts:30-38`）。

Release 与资产是另一条链路：

- updater 从 GitHub latest release 的资产列表读取 `browser_download_url`，然后将该 URL 直接交给 aria2（`References/YAAGL/src/updater.ts:38-78,94-150`）；
- Wine 分发清单直接保存 `github.com/.../releases/download/...` URL，安装程序将 `remoteUrl` 直接交给 aria2（`References/YAAGL/src/wine/distro.ts:17-78`、`References/YAAGL/src/wine/wine-install-program.ts:35-54`）；
- `acceleratedPath(path)` 只返回 `${fastest}${path}`，本地源码搜索没有发现其被用于 Release asset 或 Wine 下载（`References/YAAGL/src/github.ts:41-47`）。

结论：API prefix、Release metadata、Release asset、Wine asset 必须分别验证。API 返回 release JSON 不能证明 `browser_download_url` 可下载；asset 返回 302 也不能证明最终 bytes 已完整取得。

### 3.2 GitHub API 403 的可能原因与验证方法

当前 YAAGL 代码不能解释 403 的具体原因。`References/YAAGL/src/github.ts:31-38` 只将 status/statusText/URL 放入错误，不读取响应正文、限流相关 header、身份信息或代理诊断信息；因此下列是**需要验证的原因类别**，不是本轮网络测试结论：

| 可能类别 | 需要观察的证据 | 不应直接推断 |
|---|---|---|
| GitHub API 限流或滥用防护 | 响应正文、限流相关响应头、重置时间、请求频率和是否只影响 API | 不能把一次 403 直接解释为仓库不存在 |
| 认证、仓库可见性或权限策略 | 同一 URL 在相同身份/无身份请求下的 status、正文和资源可见性 | 不能因为 403 就要求用户输入 token；当前 Product 没有凭据管理范围 |
| 代理自身拒绝或改写 | 官方 API 与 `ghp.3shain.uk` 的最终 URL、status、正文、响应头和 request identity 对比 | 不能把代理返回的 403 当作 GitHub 官方 403 |
| 重定向后的 host 或网络中间层策略 | API 请求链路每一跳、TLS/连接错误、最终 host 和相同请求的重复结果 | 不能把 asset 的 302 或下载超时当作 API 403 的原因 |

对未来验证，必须至少分别记录：官方 API 和每个预置镜像 API 的请求 URL、最终 URL、status、响应正文摘要、响应头中可用的限流/请求标识、重试次数和耗时；同时对同一版本的 Release asset 记录 302 的 `Location`、最终 status、最终 host、Content-Length/实际 bytes、取消/超时位置和完整性结果。当前 YAAGL 的 endpoint 健康检查不足以完成这些记录。

### 3.3 镜像来源验证矩阵

本表只列出源码中已经出现的候选或官方来源；没有引入新的第三方域名。

| 来源 | 覆盖范围 | 本地证据/用户证据 | 当前状态 | 是否可进入可信镜像 allowlist |
|---|---|---|---|---|
| 官方 `api.github.com` + GitHub Release asset | API 与 Release asset | YAAGL updater、Wine 清单和用户的 API timeout/asset 302/大文件超时 | **默认官方来源；本轮网络验证未通过**。来源身份明确，但完整下载和后置校验尚未完成 | 官方来源由 Product 设为默认；一次失败不改变默认身份，也不产生 `WineReady` |
| `https://ghp.3shain.uk/` | YAAGL 代码只把它作为 API prefix 候选 | `References/YAAGL/src/github.ts:3-18`；没有独立 asset 调用或 bytes 等价证据 | **待验证候选，不是可信镜像** | 否 |
| 其他镜像域名 | 未在本地 YAAGL 证据中出现 | 无批准身份、无资源映射、无 asset 测试 | **未评估/不可列入候选** | 否 |

“预置 allowlist”可以为空或只包含已满足准入条件的条目；它不等价于“把现有候选自动批准”。截至本报告，除 Product 指定的官方来源外，没有第三方镜像达到可信状态。

### 3.4 镜像 allowlist 的准入标准

以下是 Research 对镜像条目的证据门槛，不是对 Product 或 Architecture 的实现改动：

1. **身份固定**：记录上游 owner/repository、Release tag 或版本、asset name、目标架构和镜像 URL 的明确映射；禁止只记录展示名称。
2. **API 独立验证**：镜像 API 的正文 schema、release id/tag、asset name 和来源身份与官方结果一致；不能只看 HTTP 200 或响应速度。
3. **asset 独立验证**：使用同一版本/asset 在官方和镜像路径分别测试；跟随 302 后记录最终 host、status、大小、断点/Range 行为和完整传输结果。
4. **内容验证**：下载完成后使用批准发布者提供的同一算法 digest、签名或等价的可信内容证明；不能用 URL、文件名、HTTP 200 或本地临时计算出的未知摘要自证。
5. **提交前置验证**：归档结构、目标路径、架构、安装后路径和版本身份都通过后，才能将副本提交为 MiPlay 托管 Wine。
6. **失败回退**：主来源失败时只尝试已批准且独立验证过的镜像；镜像失败时保留两侧错误并清理部分文件。不能静默回退到任意 URL 或系统 Wine。
7. **变更复核**：Release tag、asset name、bytes、签名/摘要策略或镜像重定向关系变化时，条目回到待验证，不因历史成功自动永久可信。

## 4. YAAGL 六项高级配置适用性矩阵

### 4.1 总体矩阵

三款游戏按 YAAGL 客户端分为：原神 `hk4e`、星穹铁道 `hkrpg`、绝区零 `nap`。矩阵中的“源码挂载”只表示本地代码存在配置入口或启动分支，不表示 MiPlay 当前版本已经实现、资源可用、权限可用或 Product 已允许发布。

| 高级配置 | 原神 | 星穹铁道 | 绝区零 | YAAGL 事实与限制 |
|---|---|---|---|---|
| A-01 Retina | 源码挂载 | 源码挂载 | 源码挂载 | 全局设置保存 `config_retina`；三个游戏启动前调用 `wine.setProps(config)`，由 Wine Mac Driver 写 `RetinaMode=y/n` |
| A-02 Steam patch / 白名单启动 | 源码挂载 | 未挂载 | 源码挂载 | 原神和绝区零各自有 `steam-patch.tsx` 与 `steam.exe` 启动分支；星穹铁道没有对应配置入口或分支 |
| A-03 旧版反作弊文件替换 | 无可发布资源证据 | 无可发布资源证据 | 无可发布资源证据 | 三个客户端都有 patch 开关/共享 patch pipeline 的部分入口，但当前 server definition 没有可验证的旧版反作弊替换资源；原神/绝区零 `patched` 内容主要是注释，星穹铁道 `patched: []` |
| A-04 Metal HUD | 源码挂载 | 源码挂载 | 源码挂载 | 全局设置保存 `config_metalHud`；三个启动程序将 `MTL_HUD_ENABLED=1` 或空值传给 Wine 进程 |
| A-05 左 Command 映射 Control | 源码挂载 | 源码挂载 | 源码挂载 | 全局设置保存 `left_cmd`；共享 `wine.setProps` 将 Wine Mac Driver 的 `LeftCommandIsCtrl` 写为 `y/n` |
| A-06 hosts 屏蔽 | 源码挂载 | 源码挂载 | 源码挂载 | 三个启动程序都有 `blockNet` 分支，按渠道选择 block URL，使用 `osascript`/administrator privileges 写入并延时删除 `/etc/hosts` 临时段 |

Product 当前将 A-01 至 A-06 定义为当前版本目标、但本轮可以 Deferred 实现（`Docs/00-product/product-features.md:28-42`）。因此“源码挂载”不能被 UX、Implementation 或 Release 写成“当前已实现”。

### 4.2 配置键与运行时作用

这些 YAAGL 设置不是游戏 `config.ini` 字段，而是 YAAGL 自身的本地键值或启动过程输入：

| 功能 | YAAGL 本地键/输入 | 作用位置 | 已确认边界 |
|---|---|---|---|
| Retina | `config_retina` | `References/YAAGL/src/config/retina.tsx:20-36`；`References/YAAGL/src/wine/wine.ts:119-137` | 修改 Wine prefix 中的 Wine Mac Driver registry；不是游戏内部 Retina 配置 |
| 左 Command | `left_cmd` | `References/YAAGL/src/config/left-cmd.tsx:20-36`；`References/YAAGL/src/wine/wine.ts:119-137` | 修改 Wine Mac Driver registry；不是 macOS 全局键盘映射 |
| Metal HUD | `config_metalHud` | `References/YAAGL/src/config/metal-hud.tsx:20-36`；`References/YAAGL/src/clients/mhy/hk4e/program-launch-game.ts:166-194`、`References/YAAGL/src/clients/mhy/hkrpg/program-launch-game.ts:90-118`、`References/YAAGL/src/clients/mhy/nap/program-launch-game.ts:96-124` | 通过 `MTL_HUD_ENABLED` 环境变量传给 Wine 进程；YAAGL 源码没有在此处证明 HUD 实际显示 |
| Steam patch | `config_steam_patch` | 原神/绝区零配置与启动分支 | 选择 `C:\windows\system32\steam.exe` 作为启动入口；不等于真实 Steam App ID、登录或白名单已验证 |
| patch 开关 | `config_patch_off` | `References/YAAGL/src/clients/mhy/patch.ts:35-64,127-170` | 关闭 `server.patched/removed/added` 处理的一部分；仍会执行其他 Wine/DXMT 资源处理，不能等同于“旧反作弊已替换” |
| hosts 屏蔽 | `config_block_net` | 三款 `program-launch-game.ts` 的 `/etc/hosts` 脚本分支 | 依赖管理员权限、固定 block URL、临时写入和延时清理；当前代码没有提供 MiPlay 所需的完整权限/后置验证契约 |

### 4.3 旧反作弊、patch 与 Product 资源边界

当前 Product 已冻结：

- `CS-02 block_network_anticheat`：三款游戏，发布但条件可用；必须具备真实 hosts 规则、备份、写入后验证和回滚；
- `CS-03 replace_old_anticheat`：三款游戏，不发布；缺少真实可随应用发布的旧版反作弊资源；
- `CS-04 steam_whitelist`：原神，不发布；缺少真实 Steam 应用标识和配置交互支持；
- `CS-05 use_legacy_patch`：绝区零，不发布；缺少真实旧版 DLL 资源。

对应 Product 证据为 `Docs/00-product/product-features.md:83-99`。YAAGL 中 `patchProgram` 的存在、`.bak` 备份/恢复路径、注释掉的 `patched` 条目或 `patchOff` UI，都不能替代这些资源与验证条件。

## 5. 多背景资源模型

### 5.1 YAAGL 已有模型

YAAGL 在 `References/YAAGL/src/clients/mhy/launcher-info.ts:122-164` 定义了可复用的事实模型：

```text
HoyoConnectGameBackground
  id
  background: { url, link }
  icon: { url, hover_url, link }
  video: { url, size }
  theme: { url, link }
  type: BACKGROUND_TYPE_UNSPECIFIED | BACKGROUND_TYPE_VIDEO
```

接口返回的是某个游戏的 `backgrounds: HoyoConnectGameBackground[]` 数组。`References/YAAGL/src/clients/mhy/hyp-connect.ts:22-49` 读取 `server.adv_url`，按视频类型优先排序后只返回 `sortedBackgrounds[0]`。原神、星穹铁道和绝区零都在创建客户端时拆出背景图、视频、theme 和类型（分别见 `References/YAAGL/src/clients/mhy/hk4e/index.tsx:72-104`、`References/YAAGL/src/clients/mhy/hkrpg/index.tsx:61-81`、`References/YAAGL/src/clients/mhy/nap/index.tsx:73-94`）。

### 5.2 对 MiPlay 的可复用程度

| 组成 | 研究结论 |
|---|---|
| 字段形状 | **可参考**。`id`、图像/视频/theme URL、类型和资源尺寸可作为远程背景记录的事实来源 |
| 三款游戏适用 | **已确认**。三个 YAAGL Mhy client 都调用同一 `getLatestAdvInfo` 链路 |
| 多组选择 | **不能直接复用**。YAAGL 对数组排序后只取一项，没有用户选择、当前组持久化或切换失败保留上一组的状态 |
| 资源验证 | **不能直接复用**。源码展示 `url` 并调用 `waitImageReady`，没有形成 MiPlay 需要的资源身份、完整下载、摘要/缓存提交协议 |
| 离线/过期 fallback | **未确认**。本地源码未提供多组缓存淘汰、版本过期和当前有效组的完整语义 |

因此，YAAGL 的 `HoyoConnectGameBackground` 是一个可复用的**参考数据形状**，不是可直接复制的 MiPlay Domain 模型或多背景切换状态机。Product 已要求每款游戏支持多个背景组且目标组不可用时保留上一有效组（`Docs/00-product/product-features.md:20-24,64-73`）；这一行为超出 YAAGL 当前实现。

## 6. Metadata 事实摘要

### 6.1 `pkg_version`

既有研究报告已由 `References/YAAGL/src/clients/mhy/program-check-integrity.ts:15-74`、`References/YAAGL/src/utils/unix.ts:13-16` 和 `References/YAAGL/src/utils/neu.ts:264-270` 确认：

- 文本按换行拆分；空白行丢弃；非空行逐条 `JSON.parse`，是 JSON Lines 风格，不是 JSON 数组；
- 使用字段 `remoteName`、`fileSize`、`md5`；
- 校验为 `stats(localPath).size == fileSize` 且 `md5 -q localPath` 与 `md5` 大小写不敏感相等；
- aria2 GID 的 SHA-256 前缀只用于任务标识；Sophon `ChunkInfo.xxhash` 也不是 `pkg_version` 校验算法；
- 修复下载在当前函数中直接以游戏文件路径作为目标，没有先完成独立临时文件校验再原子替换。

因此 `pkg_version` 只能作为与目标游戏、安装位置和版本语义关联后的本地证据，不能单独证明完整性、官方最新或渠道可信。与现有报告一致，不凭记忆把 MD5 改成 SHA-2/SHA-256。

### 6.2 `config.ini`

YAAGL 和 Sophon 的本地源码确认以下字段：

| 字段 | 已确认事实 | 展示边界 |
|---|---|---|
| `game_version` | YAAGL 安装/更新模板写入版本参数；Sophon 从 build tag 写回，并与 `globalgamemanagers` 版本共同作为版本锚点 | 展示原始值；不能把它单独当作文件完整性证明 |
| `channel` | 来自 `Server.channel_id`；Sophon 模板出现 `1` 与 Bilibili HK4E 的 `14` | 展示原始数字；本地源码不提供完整官方枚举 |
| `sub_channel` | 来自 `Server.subchannel_id`；Sophon 使用它参与 CN/OS 识别 | 展示原始数字；不能只由 `channel` 推断地区 |
| `cps` | YAAGL 写入 `Server.cps`；Sophon 模板有 `mihoyo`、`bilibili` | 展示原始字符串；不把名称自动升级成可信来源证明 |
| `sdk_version` | Sophon 安装模板写入空字段；YAAGL TypeScript 模板未写 | 可显示实际存在的原始值；不猜测空值语义 |
| `wpf_version` | 在本地 `References/YAAGL/` 搜索无命中 | 暂无可靠语义；不读取、不生成、不参与版本判断 |

证据：`References/YAAGL/src/clients/mhy/hkrpg/program-install-game.ts:64-76`、`References/YAAGL/src/clients/mhy/hkrpg/program-update-game.ts:140-152`、`References/YAAGL/src/clients/mhy/nap/program-install-game.ts:64-76`、`References/YAAGL/src/clients/mhy/nap/program-update-game.ts:140-152` 的写入逻辑，另有 `References/YAAGL/sophon_server/sophon_api.py:372-484,1028-1081`、`References/YAAGL/sophon_server/tasks.py:11-17`。Product 已冻结 `config.ini` 原始字段展示（`Docs/00-product/product-features.md:20-25,64-70`），因此 Research 不提出友好字段映射。

## 7. YAAGL 可参考与不可直接复用

### 7.1 可以参考的事实

| 主题 | 可以参考 | 证据 |
|---|---|---|
| 按游戏配置分组 | 全局配置与每个 channel client 的 `createConfig` 分离；原神/星穹铁道/绝区零分别挂载自己的配置入口 | `References/YAAGL/src/config/index.tsx:40-78`；`References/YAAGL/src/clients/mhy/hk4e/index.tsx`、`References/YAAGL/src/clients/mhy/hkrpg/index.tsx`、`References/YAAGL/src/clients/mhy/nap/index.tsx` 的 `createConfig` |
| Wine Mac Driver 设置 | 通过 Wine prefix 内 registry 设置 Retina 与左 Command | `References/YAAGL/src/wine/wine.ts:119-137` |
| Metal HUD 传递 | 通过启动环境变量传递 `MTL_HUD_ENABLED` | `References/YAAGL/src/clients/mhy/hk4e/program-launch-game.ts:166-194`、`References/YAAGL/src/clients/mhy/hkrpg/program-launch-game.ts:90-118`、`References/YAAGL/src/clients/mhy/nap/program-launch-game.ts:96-124` |
| per-channel 资源选择 | 通过 server id 选择 block URL、游戏可执行文件和渠道版本 | `References/YAAGL/src/clients/mhy/hk4e/program-launch-game.ts`、`References/YAAGL/src/clients/mhy/hkrpg/program-launch-game.ts`、`References/YAAGL/src/clients/mhy/nap/program-launch-game.ts`；`References/YAAGL/src/clients/hk4ecn.ts`、`References/YAAGL/src/clients/hkrpgcn.ts`、`References/YAAGL/src/clients/napcn.ts` |
| 背景数据形状 | 背景图、视频、theme、icon 和类型字段 | `References/YAAGL/src/clients/mhy/launcher-info.ts:122-164` |
| patch 恢复意图 | 运行前备份、运行后恢复，并保留 `patched` 状态键 | `References/YAAGL/src/clients/mhy/patch.ts:29-170` |

### 7.2 不能直接复用的代码或语义

1. **Neutralino/aria2/JavaScript 实现不能直接移入 Swift**：下载状态不公开完整 HTTP/摘要验证，取消和临时文件提交也不满足 MiPlay 的 Swift Task/Domain 约束。
2. **`sudo`/`osascript` hosts 脚本不能直接复用**：YAAGL 的 per-game 分支会直接写 `/etc/hosts`，使用管理员权限并以固定 sleep 后删除；这不提供 App Sandbox、helper 签名、XPC 身份、原文件备份和读回验证。Apple 边界见 `research-apple-platform-constraints.md:119-145`。
3. **`server.patched`、注释资源和 `.bak` 路径不能当作旧反作弊资源**：当前快照没有可随 MiPlay 发布并通过摘要验证的旧版反作弊/旧 DLL artifact。Product 已将 CS-03 至 CS-05 排除在当前发布清单之外。
4. **Steam patch 不能当作 Steam 白名单完成**：YAAGL 只提供 `steam.exe` 启动分支和 sidecar Steam DLL 处理；源码没有证明真实 Steam App ID、配置交互、登录或白名单成功。
5. **`config.ini` 不能作为六项高级配置的存储协议**：高级配置使用 YAAGL 本地键值；游戏 `config.ini` 只按已确认字段展示原始内容。
6. **`HoyoConnectGameBackground` 不能直接当作 MiPlay 多背景状态**：缺少组选择、持久化、缓存完整性、失败保留上一组和清理语义。

## 8. 旧版与当前下载链路对比

### 8.1 链路事实对比

旧版四个文件不是一条一致的下载实现：`WineVersionProvider` 先访问 GitHub Release API，`WineDownloader` 和 `DownloadManager` 的普通路径再直接消费 `WineVersion.downloadURL`；`WineManager` 有进度回调时会切换到另一条 delegate 下载路径（`References/MiPlay/Wine/WineVersion.swift:48-131`、`References/MiPlay/Wine/WineManager.swift:61-85`）。因此“旧版直接下载 Release”只能描述 asset 下载阶段，不能描述版本发现阶段。

| 检查项 | 旧版事实 | 当前事实 | 研究结论 |
|---|---|---|---|
| API 与资产 | `WineVersionProvider` 请求 `api.github.com/.../releases`，从 API 的 `browser_download_url` 构造 `WineVersion`；下载器收到该 URL 后不再请求 API | `WineVersionManager`/`WineVersionDownloader` 通过 API 获取 Release，再筛选托管 tag、arm64 `.tar.xz` 和 asset size；下载阶段消费 `browserDownloadURL` | API 版本发现与 asset 传输在两版都已经是两个阶段；不能把直接 asset URL 等同于绕过来源审核 |
| 是否固定 Release URL | 旧版四个目标文件没有固定的 Release asset URL；URL 来自 API 返回的 asset 字段 | 当前也没有把固定 asset URL 写入 `WineVersionDownloader`；仓库和允许 tag 在代码中固定，asset URL 仍来自 API | “固定 URL 旧版正常”不是当前代码或旧版四文件可确认的事实 |
| 302 | `URLSession.shared.download`/`downloadTask` 未实现 redirect delegate 或最终 host 校验，依赖 Foundation 默认重定向；普通路径随后检查最终响应是否为 200 | `NetworkDownloadProvider` 同样未实现 redirect delegate；默认 session 跟随重定向，完成回调检查最终响应是否为 2xx | 302 在本地可控测试中可成功跟随，但两版都没有显式的重定向安全策略或 `Location` 记录 |
| HTTP 状态码 | `WineDownloader.downloadWine` 和 `DownloadManager.download` 检查 `statusCode == 200`；`downloadWithProgress` 的 delegate 成功分支没有检查 HTTP response，403 也可进入成功路径 | `NetworkDownloadProvider.download` 对完成回调检查 200...299；API `request`/`requestData` 也拒绝非 2xx | 当前版修复了旧版进度路径的状态码缺口，但应继续保留明确的最终响应错误语义 |
| API 403 错误层级 | 旧版 `WineVersionProvider` 对版本 API 只接受 200，失败统一包装为 `fetchFailed`，没有 403 专用状态 | 当前底层 `NetworkDownloadProvider` 保留 `httpError(statusCode: 403, ...)`；但 `WineVersionDownloader` 和 `WineVersionManager` 只对 429 做专门分支，403 会被上层包装为通用 `apiUnavailable` | 底层状态码存在不等于用户层已有明确 API 403 状态；这是后续 Architecture/Implementation 的待验证契约 |
| 断点续传 | 没有 `resumeData`、`downloadTask(withResumeData:)`、`cancel(byProducingResumeData:)`、HTTP `Range` 或 `If-Range` | 没有上述 API；取消只取消活动 `URLSessionDownloadTask`，再次下载会新建任务 | 两版都不支持可恢复的断点续传；`DownloadStatus.paused` 只是旧版数据结构状态，不是实现 |
| 临时文件与失败清理 | URLSession 临时文件先由 delegate 复制到另一个临时 URL，再移动到目标；失败路径没有统一应用级临时文件清理。`WineManager` 在下载前创建版本目录，归档只在解压成功后 `try?` 删除，解压/安装失败没有对应回滚 | `NetworkDownloadProvider` 使用 URLSession 临时 URL，移动到 staging 归档后做大小检查；`WineVersionDownloader`/`WineVersionManager` 对取消、下载失败、解压失败和 staging 目录做清理，并记录清理失败 | 当前版具备更完整的失败与 staging 事实，但没有因为旧版有临时文件路径就获得断点能力 |
| 代理与系统网络配置 | 下载使用 `URLSession.shared` 或默认 `URLSession`，四个目标文件没有下载代理配置；旧版 `HTTP_PROXY`/`HTTPS_PROXY` 只在游戏启动环境中设置（`References/MiPlay/Launcher/GameLauncher.swift:84-96`） | `NetworkDownloadProvider` 使用 `URLSessionConfiguration.default`，设置请求/资源超时、`waitsForConnectivity` 和通用 headers；没有应用层代理 URL 或自定义 proxy 配置 | 两版都没有证明“下载使用了 MiPlay 代理”；默认 URLSession 的系统网络行为不能被写成特定镜像或代理保证 |
| 文件大小 | 旧版 `WineVersion.fileSize` 保存 API asset size，但 `WineDownloader`/`DownloadManager` 下载签名没有 expected size 参数；安装流程未比较归档大小 | 当前 API 传递 asset size，下载完成后比较实际文件大小和 expected size，失败时删除错误文件 | 当前版有可验证的大小门禁；旧版字段存在不等于下载校验执行 |
| 摘要 | 旧版 `WineVersion` 解析可选 `sha256`，`WineDownloader` 有独立 `verifyChecksum`；`WineManager.installWine` 没有调用它，安装也没有把 digest 传入下载器 | 当前 Wine metadata 模型只保留 asset name、URL 和 size；`GameFileSystemRepository` 有 SHA-256 工具，但 `WineVersionDownloader` 下载流程没有调用它 | 旧版不能据代码证明实际完成摘要校验；当前 Wine 链路也不能据代码证明摘要校验，不能将 SHA-256 写成已实现验收项 |
| 归档内容 | 旧版只调用 `tar -xJf` 并等待退出，没有检查 `bin/wine`，也没有解压超时或失败目录清理 | 当前通过 `ProcessManager` 调用 `tar -xJf`，有 120 秒超时、取消/失败清理，并检查 `bin/wine` 和执行权限 | 当前归档结果门禁比旧版完整；仍不能把“tar 解压成功”扩展为发布者签名或摘要验证 |
| 取消 | 旧版带进度路径可调用 `cancelDownload(url:)`，delegate 将取消映射为 `.cancelled`；普通 `download(from:)` 没有暴露同等会话取消接口 | 当前以 session ID 关联任务，取消 producer 和 URLSession task，并清理 staging/归档；清理失败产生 `recoveryRequired` | 当前取消语义更完整；旧版取消结果可复现，但不是可恢复下载 |

### 8.2 可复用事实与不可直接复用部分

| 分类 | 研究结论 |
|---|---|
| 可复用事实 | 可信 Release metadata 可以先解析 `browser_download_url`，再把 asset 下载作为独立传输阶段；Foundation `URLSessionDownloadTask` 可以提供临时文件和进度回调；完成后移动到应用管理目录是可复用的基础模式 |
| 可复用事实 | 302 的实际行为必须用最终响应和最终 URL 验证；本地测试证明默认 URLSession 能跟随普通 302，但这不验证镜像身份、跨 host 许可或大文件可持续传输 |
| 不可直接复用 | 旧版 `downloadWithProgress` 的成功分支不能复用：它忽略 HTTP response，实测 403 仍写入目标文件 |
| 不可直接复用 | 旧版 `verifyChecksum`、`WineVersion.sha256` 和 `DownloadStatus.paused` 不能当作已完成的摘要或断点能力；代码没有把它们接入安装门禁 |
| 不可直接复用 | 旧版普通 URLSession、动态 API 返回 URL 和游戏启动代理环境不能直接转化为 MiPlay 的镜像 allowlist、来源身份或下载代理契约 |
| 不可直接复用 | 旧版在解压失败时没有清理版本目录和归档，且 `Process.waitUntilExit()` 没有超时；不能作为当前 Sandbox、取消和失败恢复实现模板 |

### 8.3 旧版下载功能可重复验证

验证在本机 macOS arm64、Swift 6.4、Xcode 27 环境完成；没有访问 GitHub。临时 HTTP 服务只监听 `127.0.0.1:18765`：`/redirect` 返回 `302 Location: /payload`，`/payload` 返回固定 `106496` bytes，`/status/403` 返回 HTTP 403。旧版 harness 编译成功，但 Swift 报告了两个未使用项 warning（`progressHandler` capture 和 `flatMap` 返回值）；这些 warning 不改变以下 HTTP 结果。

| 实验 | 重复步骤 | 结果 |
|---|---|---|
| 旧版普通下载 + 302 | 编译 `References/MiPlay/Downloads/DownloadManager.swift` 与临时 harness，调用 `DownloadManager.download` 访问 `/redirect` | `SUCCESS bytes=106496`；目标文件存在。证明默认 URLSession 在该环境跟随 302 并拿到最终 200 |
| 旧版普通下载 + 403 | 同一 harness 调用 `/status/403` | `DownloadError`，`网络错误: HTTP 状态码错误`；目标文件不存在 |
| 旧版进度下载 + 403 | 编译同一旧版 `DownloadManager.swift`，调用 `downloadWithProgress` 访问 `/status/403` | 进度报告 `1.0`，随后 `UNEXPECTED success`；目标文件存在。证明该旧版路径没有状态码门禁 |
| 旧版进度下载取消 | 调用 `downloadWithProgress` 访问慢速 `/payload`，5 ms 后调用 `cancelDownload(url:)` | `DownloadError`，`下载已取消`；目标文件不存在。证明取消可触发，但没有 resume data |
| 当前实现对照 | 编译当前 `NetworkDownloadProvider.swift` 与临时 harness，分别访问 `/redirect`、`/status/403`，并以错误 expected size `1` 访问 `/payload` | 302 成功；403 报告 `HTTP 403: forbidden` 且目标不存在；大小不匹配报告错误并删除目标文件 |

以上是本地可控响应的可重复结果，不是 GitHub Release 或中国网络环境的成功证明。静态搜索也没有发现旧版或当前版的 `resumeData`、`Range`、`If-Range`、`downloadTask(withResumeData:)` 或 `cancel(byProducingResumeData:)`。当前报告保留此前结论：GitHub API timeout、asset 302 和大文件超时不能推广为所有用户网络结论。

### 8.4 给后续 Architecture 的事实约束

1. API 版本发现与 Release asset 下载应保持独立验证；可以研究固定 asset URL 的传输路径，但不能跳过来源身份、tag、asset name、架构、大小和摘要/签名门禁。
2. 旧版 302 结果只能证明 Foundation 默认重定向在测试环境可用；allowlist 仍需分别记录最终 host、状态码、内容长度、完成传输和失败回退。
3. 当前任务取消、临时 staging、文件大小校验、归档内容门禁、App Sandbox 和失败清理语义必须保留；旧版不具备的断点续传不能被隐式补写成已支持能力。
4. 当前底层网络层能携带 API 403，但 Wine 上层目前只对 429 特殊处理；Implementation 的 API 403 测试必须验证最终用户可见错误，而不能只验证底层 `NetworkError`。

## 9. Review 回溯结论与未关闭项

| Issue | Research 修订结论 | 仍需回溯/验证 |
|---|---|---|
| REV-003 / P1-REV-003 启动恢复门禁 | 本报告不修改启动恢复；只确认 hosts、patch 和 Wine 失败均不能被源码入口替代成功门槛 | Implementation / Review 需要验证恢复后状态、残留和启动阻断 |
| REV-004 / P1-REV-004 Bookmark 消费者完整覆盖 | 本报告沿用 Apple bookmark 与外部目录权限约束，不修改消费者 | Implementation 需要完成消费者审计和用户验证 |
| UV-003 / P1-UV-003 Wine 产品边界 | 官方 GitHub 默认、预置可信镜像内部回退、禁止自由 URL、禁止外部 Wine 均与源码研究一致 | Architecture / Implementation 需要把来源身份和 WineReady 门禁落地 |
| UV-004 GitHub API / 镜像 | API 与 asset 独立；`ghp.3shain.uk` 尚未达到可信镜像准入；当前网络测试不能推广 | Research 外部测试、Architecture / Implementation fallback |
| UV-005 游戏 metadata | `pkg_version` JSONL + size/MD5；`config.ini` 原始字段；`wpf_version` 无语义证据 | UX / Architecture / Implementation 保持证据分离 |
| UV-006 / P1-UV-006 设置页面结构 | 六项配置按游戏适用性已形成事实矩阵；不把源码入口等同于完成 | UX / UI 决定分组和状态表达，不能新增未验证语义 |
| UV-008 高级游戏配置范围 | A-01 至 A-06 均为当前目标但可 Deferred；A-03/CS-03、Steam 白名单和旧版 patch 仍受资源边界限制 | Product 冻结范围；Implementation 按资源和权限门禁执行 |
| DOC-REV-001 文档完成口径 | 本报告明确“源码挂载”“产品目标”“可发布”“用户验证通过”四者不同 | Implementation / QA / Release 不得用 YAAGL 代码存在替代验收 |

## 10. 证据索引

| 编号 | 本地来源 | 支撑结论 |
|---|---|---|
| G1 | `References/YAAGL/src/github.ts:3-48` | API endpoint、健康检查、status 处理、`acceleratedPath` 未形成 asset 回退 |
| G2 | `References/YAAGL/src/updater.ts:38-78,94-150`、`References/YAAGL/src/wine/distro.ts:17-78`、`References/YAAGL/src/wine/wine-install-program.ts:35-54` | GitHub Release/Wine asset 直链与 API 分离 |
| G3 | `References/YAAGL/src/aria2.ts:36-64`、`References/YAAGL/src/utils/helper.ts:26-36` | GID SHA-256 仅为任务标识；下载封装不做内容校验 |
| F1 | `References/YAAGL/src/config/retina.tsx:13-62`、`References/YAAGL/src/config/left-cmd.tsx:13-62`、`References/YAAGL/src/wine/wine.ts:119-137` | Retina、左 Command 的本地键和 Wine registry 作用 |
| F2 | `References/YAAGL/src/config/metal-hud.tsx:13-62`、`References/YAAGL/src/clients/mhy/hk4e/program-launch-game.ts:166-194`、`References/YAAGL/src/clients/mhy/hkrpg/program-launch-game.ts:90-118`、`References/YAAGL/src/clients/mhy/nap/program-launch-game.ts:96-124` | Metal HUD 三款游戏启动环境变量 |
| F3 | `References/YAAGL/src/clients/mhy/hk4e/config/steam-patch.tsx:7-64`、`References/YAAGL/src/clients/mhy/hk4e/program-launch-game.ts:166-170`、`References/YAAGL/src/clients/mhy/nap/config/steam-patch.tsx:7-64`、`References/YAAGL/src/clients/mhy/nap/program-launch-game.ts:96-100` | Steam patch 仅原神/绝区零挂载；星穹铁道无对应入口 |
| F4 | `References/YAAGL/src/clients/mhy/patch.ts:29-170`、`References/YAAGL/src/clients/hk4ecn.ts:38-65`、`References/YAAGL/src/clients/hkrpgcn.ts:21-36`、`References/YAAGL/src/clients/napcn.ts:26-51` | shared patch pipeline、备份/恢复与当前 server resource 边界 |
| F5 | `References/YAAGL/src/clients/mhy/hk4e/config/block-net.tsx:7-65`、`References/YAAGL/src/clients/mhy/hk4e/program-launch-game.ts:133-164`、`References/YAAGL/src/clients/mhy/hkrpg/config/block-net.tsx:7-65`、`References/YAAGL/src/clients/mhy/hkrpg/program-launch-game.ts:56-88`、`References/YAAGL/src/clients/mhy/nap/config/block-net.tsx:7-65`、`References/YAAGL/src/clients/mhy/nap/program-launch-game.ts:62-94` | hosts 屏蔽配置和 per-game administrator script |
| B1 | `References/YAAGL/src/clients/mhy/launcher-info.ts:122-164`、`References/YAAGL/src/clients/mhy/hyp-connect.ts:22-49` | 多背景数组模型、视频优先排序、只返回一项 |
| M1 | `References/YAAGL/src/clients/mhy/program-check-integrity.ts:15-74`、`References/YAAGL/src/utils/unix.ts:13-16`、`References/YAAGL/src/utils/neu.ts:264-270` | `pkg_version` JSONL、字段和 size/MD5 校验 |
| M2 | `References/YAAGL/sophon_server/manifest.proto`、`References/YAAGL/sophon_server/sophon_api.py:958-1007,1484-1512` | Sophon 文件级 MD5 与 chunk 字段实际使用差异 |
| C1 | `References/YAAGL/sophon_server/sophon_api.py:372-484,1028-1081`、`References/YAAGL/sophon_server/tasks.py:11-17`、`References/YAAGL/src/clients/mhy/hkrpg/program-install-game.ts:64-76`、`References/YAAGL/src/clients/mhy/hkrpg/program-update-game.ts:140-152`、`References/YAAGL/src/clients/mhy/nap/program-install-game.ts:64-76`、`References/YAAGL/src/clients/mhy/nap/program-update-game.ts:140-152` | `config.ini` 模板、版本双锚点和更新写回 |
| P1 | `Docs/00-product/product-features.md:28-42,83-99,136-172` | 六项高级配置的当前目标/Deferred 状态、兼容方案发布清单、托管 Wine 与镜像规则 |
| A1 | `Docs/01-research/research-apple-platform-constraints.md:91-169` | 外部目录 bookmark、App Sandbox、hosts/helper、HTTP 临时文件与错误边界 |
| U1 | 本轮用户验证输入：GitHub timeout、asset 302、5.75 MB/417 MB 超时 | 当前测试环境观察；不推广为所有网络环境结论 |
| D1 | `References/MiPlay/Wine/WineVersion.swift:48-131` | 旧版 API 版本发现、asset URL/size/sha256 元数据和下载 URL 形成 |
| D2 | `References/MiPlay/Wine/WineDownloader.swift:33-90`、`References/MiPlay/Wine/WineManager.swift:61-85` | 旧版普通下载、SHA-256 辅助函数、解压和安装清理边界 |
| D3 | `References/MiPlay/Downloads/DownloadManager.swift:33-91,96-156` | 旧版普通/进度下载、HTTP 状态处理差异、取消和 delegate 临时文件 |
| D4 | `References/MiPlay/Downloads/DownloadTask.swift:10-49` | 旧版下载状态数据结构没有暂停/恢复执行逻辑 |
| D5 | `MiPlay/Infrastructure/Network/NetworkDownloadProvider.swift:74-248,254-327` | 当前 URLSession 配置、2xx 状态、大小校验、取消和 API 错误 |
| D6 | `MiPlay/Infrastructure/Wine/WineVersionDownloader.swift:105-146,343-430,438-551`、`MiPlay/Domain/Runtime/WineVersionManager.swift:180-240,442-610` | 当前 API/asset 分离、staging、归档检查、取消和失败清理 |
| D7 | `MiPlay/Infrastructure/Network/GitHubModels.swift:29-45`、`MiPlay/Infrastructure/FileSystem/GameFileSystemRepository.swift:350-367` | 当前 Wine asset 模型的 size 字段与独立 SHA-256 工具；下载流程未调用摘要工具 |
| D8 | 本轮本地 HTTP 复现：旧版 302/403/取消、当前版 302/403/大小不匹配 | 可重复验证结果；不替代 GitHub 资产或中国网络实测 |

## 11. 最终研究结论

1. **镜像**：当前证据只支持“官方 GitHub 默认 + 预置可信镜像可作为内部回退”这一产品形状；没有任何第三方镜像完成 API/asset/bytes/失败回退验证，因此 `ghp.3shain.uk` 仍是未批准候选，不能进入可信 allowlist。
2. **YAAGL 功能**：Retina、Metal HUD、左 Command 和 hosts 配置在三款游戏有源码挂载；Steam patch 只有原神和绝区零有启动分支；旧版反作弊/旧版 patch 缺少可发布资源证据。
3. **多背景**：YAAGL 有可参考的背景数组数据形状，但当前只选一项，不实现 MiPlay 要求的多组选择、持久化和失败保留。
4. **Metadata**：`pkg_version` 的真实校验仍是 size + MD5；`config.ini` 只展示已确认的原始 key/value；`wpf_version` 不可推断。
5. **旧版下载**：旧版 API 发现后直连 asset；普通路径可跟随 302，但带进度路径会把 403 当成功；旧版没有断点续传，SHA-256 也没有接入安装门禁。
6. **当前下载**：当前版保留 API/asset 分离并增加 2xx、文件大小、归档内容、取消和 staging 清理，但当前 Wine 链路仍没有摘要校验或断点续传。
7. **复用边界**：可参考数据形状、按游戏配置挂载和 Wine 环境变量；不能直接复用 YAAGL 的 shell/sudo、Neutralino/aria2、未验证下载、注释资源、Steam 分支或背景选择逻辑，也不能直接复用旧版进度下载路径。

本报告未修改 Product、UX、UI、Architecture 或源码；未将当前机器网络结果推广为中国网络结论；未把任何新增第三方域名列为可信来源。
