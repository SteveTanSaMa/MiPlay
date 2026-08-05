# YAAGL 下载渠道与游戏文件元数据研究报告

> **Agent**：Research Agent
> **日期**：2026-08-03
> **状态**：研究输出；不修改 Product、源码或架构契约
> **研究对象**：`References/YAAGL/` 本地源码快照、已有 Apple 官方本地资料和本机 Xcode macOS SDK

## 1. 目的与证据边界

本报告根据 YAAGL 本地源码核实以下事实：

- GitHub API、GitHub Release asset 和 Wine/运行时资源的真实 URL 链路；
- 中国网络环境下 API 与实际下载之间的可行性差异；
- YAAGL 中硬编码的 GitHub proxy 是否构成稳定、可验证、可回退的镜像来源；
- `pkg_version` 的行格式、字段语义和真实校验算法；
- `config.ini` 的 `channel`、`sub_channel`、`cps`、`game_version`、`sdk_version` 事实，以及 `wpf_version` 是否有本地语义证据；
- Apple 对沙盒外本地配置/游戏目录、文件完整性、网络失败和临时文件处理的约束。

本报告只记录源码事实、平台约束、证据缺口和不可行方案，不把源码中现存行为提升为 MiPlay 的产品决策。YAAGL 的渠道是多个游戏与发行区域的实现，不应直接等同于 MiPlay 当前版本的批准来源或支持范围。

### 1.1 证据等级

1. **S1：YAAGL 本地实现**：`References/YAAGL/src/` 与 `References/YAAGL/sophon_server/`，可直接追溯到文件和行号。
2. **S2：YAAGL 本地协议定义**：`sophon_server/manifest.proto`、`manifest_ldiff.proto`，只说明字段名和注释，不单独证明运行时一定校验每个字段。
3. **S3：Apple 本地官方 SDK/参考资料**：已有 `research-apple-platform-constraints.md` 的 A1-A11 证据。本报告引用的平台结论不使用未经核实的第三方资料；摘要算法的具体语义只引用 YAAGL 源码和本地 manifest 定义。

本机没有中国大陆运营商出口的网络测量结果。因此，“中国网络环境可行性”是基于 YAAGL 的 URL、超时、回退和校验实现做出的条件性判断，不宣称某个当前网络环境下的普遍可达性。

## 2. 结论摘要

| 主题 | YAAGL 源码确认的事实 | 研究结论/限制 |
|---|---|---|
| GitHub API | 启动时在官方 `api.github.com` 和 `https://ghp.3shain.uk/` 之间竞速；API 请求只接受 200/301/302，代理前缀由字符串拼接 | API 可能通过代理工作，但健康检查不验证响应内容，API 没有独立超时或 schema/限速处理 |
| GitHub Release 下载 | updater 使用 `browser_download_url`；Wine 与资源清单也保存 `https://github.com/.../releases/download/...` 直链 | API 代理不会自动代理 asset 下载；直链在中国网络不可达时，当前代码没有有效下载回退 |
| GitHub 镜像 | 本地源码只有一个未签名、未版本固定、未做内容等价验证的 `ghp.3shain.uk` 前缀 | 不能从本地证据认定为稳定或可批准镜像；不得新增未经独立验证的镜像 |
| `pkg_version` | 非空行逐行 `JSON.parse`，字段按 `remoteName`、`md5`、`fileSize` 使用 | 格式是 JSON Lines 风格，不是一个 JSON 数组；真实校验是文件大小 + MD5，不能替换成 SHA-256 而仍声称兼容 |
| Sophon manifest | `FileInfo` 含文件 MD5；`ChunkInfo` 定义 chunk MD5、压缩/解压大小和 xxhash | YAAGL Sophon 实现实际对组装文件做 MD5；本地代码没有发现对 chunk MD5/xxhash 的校验调用 |
| `config.ini` | YAAGL 写入 `[General]`、`game_version`、`channel`、`sub_channel`、`cps`；Sophon 安装模板另写空 `sdk_version` | `game_version` 是版本锚点之一；`channel/sub_channel` 用于发行渠道/区域；`cps` 是发行/来源标识。`wpf_version` 在本地 YAAGL 中没有语义证据 |
| Apple Sandbox | 当前 MiPlay 工程 Debug/Release 为 `ENABLE_USER_SELECTED_FILES = readonly`；既有 Apple 资料要求 security-scoped bookmark 与相应 entitlement | 当前配置不能据此支持在用户选中的外部游戏目录中修复文件或写配置；必须验证最终签名与真实写入能力 |
| Apple 网络失败 | `URLSession` 将 HTTP response 与客户端 error 分开；下载临时文件需在回调中移动/读取，取消可能仍有回调 | HTTP 非 2xx、传输错误、取消、临时文件和后置 digest 验证必须分别建模 |

## 3. YAAGL 的下载渠道

### 3.1 GitHub endpoint 发现

`References/YAAGL/src/github.ts:3` 的 endpoint 列表只有两个候选：

```text
""
"https://ghp.3shain.uk/"
```

探测请求是 `${prefix}https://api.github.com/octocat`（`github.ts:10-18`）。实现细节如下：

- 官方 endpoint 和代理 endpoint 并行发起 `fetch`，最快返回者获选；
- 探测只把 `fetch` 能完成并读出文本视为成功，不检查 HTTP status、正文是否为预期的 GitHub API 响应，也不比较官方与代理正文；
- 单次竞速有 5 秒 timeout，整个探测最多重试 3 次；三次均失败才抛出 `Failed to connect to GitHub`；
- 选定 endpoint 后，`api(path)` 使用相同前缀请求 `https://api.github.com${path}`，仅接受 status 200、301、302 后调用 `.json()`（`github.ts:30-38`）；
- `acceleratedPath(path)` 只是返回 `${fastest}${path}`（`github.ts:41-43`），本地源码没有发现其调用方；
- `api(path)` 没有自己的 timeout、AbortController、重试、rate-limit header 处理或响应 schema 校验。

因此，这个 endpoint 机制是“API URL 前缀竞速”，不是有完整元数据、签名和内容等价验证的镜像协议。

### 3.2 API 与实际 asset 下载是两条链路

YAAGL updater 请求 `GET /repos/3shain/yet-another-anime-game-launcher/releases/latest`（`updater.ts:17-40`），找到按渠道命名的 `.neu` 和 app bundle asset 后，返回它们的 `browser_download_url`（`updater.ts:41-78`）。`downloadProgram` 直接把这些 URL 交给 aria2（`updater.ts:94-149`）。

Wine 分发清单也直接保存 GitHub Release URL（`wine/distro.ts:17-78`），安装时直接将 `wineDistro.remoteUrl` 交给 aria2（`wine/wine-install-program.ts:35-54`）。其他运行时资源同样可见多个直接 URL，例如：

- MoltenVK/DXVK：`downloadable-resource.ts:40-95` 的 `github.com/3Shain/winecx`；
- DXMT：`downloadable-resource.ts:150-203` 的 `github.com/3Shain/dxmt`；
- Jadeite：`downloadable-resource.ts:99-136` 的 Codeberg Release；
- ReShade 与 DLL：`downloadable-resource.ts:208-289` 的上游网站和 Lutris URL。

关键事实是：`acceleratedPath` 未被用于 `browser_download_url` 或 `WineDistribution.remoteUrl`。所以“GitHub API 可以通过代理返回 release JSON”不能推出“GitHub Release asset 可以通过同一代理下载”。

### 3.3 aria2 的真实下载与校验边界

YAAGL 以 URL 和目标路径的 SHA-256 前 8 个十六进制字符生成 aria2 GID（`aria2.ts:36-40`，算法实现为 `utils/helper.ts:26-36`）。该 SHA-256 只用于本地任务标识，不是远程资源内容校验，也不能作为 `pkg_version` 的算法依据。

任务参数包括最多 16 条连接、`continue: false` 和 `allow-overwrite: true`（`aria2.ts:50-57`）。当前封装：

- 仅处理 `paused` 和 `complete`；其他已有状态抛出 FIXME 错误；
- 轮询 `tellStatus`，遇到 `complete` 即结束，没有在封装层检查 HTTP status、内容类型、最终文件 digest 或签名；
- `totalLength == 0` 时跳过一次进度产出，调用方可能得到未知或不完整进度；
- 没有把 Swift/用户取消语义映射到 aria2 RPC 的取消与临时文件清理，因为这是 Neutralino/aria2 代码。

## 4. 中国网络环境与 GitHub 镜像可行性

### 4.1 可行性分层

| 链路 | 依赖 | 基于源码的判断 |
|---|---|---|
| GitHub API 发现 | `api.github.com` 或 `ghp.3shain.uk` 能在 5 秒内返回 | **条件可行**。代理可能改善 API 可达性，但实现没有正文等价、证书绑定、schema 或限速验证 |
| GitHub Release asset 下载 | `browser_download_url`/`remoteUrl` 对 GitHub Release 直链可达 | **条件可行但无中国网络保证**。当前下载层不使用 `acceleratedPath`，API 代理成功不代表资源下载成功 |
| Wine 初始运行时安装 | 至少一个 `github.com/.../releases/download/...` 直链可达 | **在直链受阻时不可行**。本地源码没有另一个已验证 asset 来源或内容等价回退 |
| 游戏文件/版本 API | 米哈游/Hoyoverse 官方 API 或 Sophon 服务 URL 可达 | 与 GitHub 是不同来源；不能用 GitHub 镜像结论替代官方游戏 API 的单独测量 |

“中国网络环境可行”只能表述为上述条件成立时可用。不能仅凭当前机器或 YAAGL 源码断言中国所有网络、运营商、DNS 和代理环境均可达。

### 4.2 现有 `ghp.3shain.uk` 是否可作为稳定镜像

本地源码能证明它是 YAAGL 作者写入的候选 endpoint，但不能证明以下事项：

- 该域名的运营主体、服务协议、可用性 SLA 或长期维护；
- 代理是否逐字节转发 GitHub API 与 Release asset；
- 代理是否会改写 JSON、重定向、缓存旧 release 或替换资源；
- 代理返回的 asset 是否能用上游发布者提供的 digest、签名或透明发布记录验证；
- 代理在证书、DNS、HTTP status、限速、断点和大文件场景下的行为。

当前 endpoint 探测也无法补足这些缺口，因为它只读取 `/octocat` 文本，不做内容固定值、响应头或官方/代理交叉比较。故本报告不把 `ghp.3shain.uk` 认定为稳定、可验证、允许自动回退的来源，也不引入其他第三方镜像域名。

### 4.3 允许失败回退所需的证据门槛

以下是平台和下载失败处理的**验证要求**，不是新增产品决策：

1. 每个候选来源必须有明确的来源身份、资源 ID/版本、目标文件名和发布者提供的内容校验资料；不能只比较 URL 或 HTTP 200。
2. 候选来源下载的 bytes 必须在提交前与同一发布身份的预期 digest/签名核对。算法必须以发布元数据为准；不能用另一种算法替代 YAAGL 已声明的 MD5，也不能凭文件名推断算法。
3. 回退只在首选来源失败且候选来源通过相同响应、大小、digest/签名和归档后置验证时成立；回退失败应保留原错误与候选错误，并清理未完成文件。
4. API endpoint 回退与 asset endpoint 回退必须分别验证。不能把 API 可用当作 asset 可用。
5. 任何未经上述验证的域名，包括当前源码中的 `ghp.3shain.uk`，只能作为待核查候选，不能进入 MiPlay 的批准来源 allowlist。

### 4.4 不可行方案

- **仅把 GitHub API URL 替换为代理**：不能解决 `browser_download_url` 和 Wine Release 直链下载。
- **把 `acceleratedPath` 当作已经实现的下载回退**：本地源码没有调用它，且它只返回字符串，不验证 asset 内容。
- **按响应最快选择任意 mirror**：YAAGL 健康检查不检查 status/正文，最快不等于可信或内容等价。
- **只看下载完成/文件存在**：aria2 封装没有内容 digest/签名校验；不能据此提交 Wine、更新包或修复文件。
- **引入一个未经验证的国内镜像**：违反本任务约束，也无法证明与批准上游的 bytes、版本和发布身份一致。
- **把当前来源直链失败静默降级到系统 Wine/Whisky/CrossOver**：Product 已冻结外部 Wine 仅作检测信息，且来源失败不能改变托管运行时状态。

## 5. `pkg_version` 文件格式与校验语义

### 5.1 本地源码确认的格式

YAAGL 的通用 `clients/mhy/program-check-integrity.ts:15-21` 对 `${gameDir}/pkg_version` 执行：

1. 以文本读取；`readAllLines` 只按 `CRLF` 或 `LF` 切行（`utils/neu.ts:264-270`）；
2. 删除 `trim()` 为空的行；
3. 对每个非空行单独执行 `JSON.parse`；
4. 将结果按以下三个字段读取：

| 字段 | 源码中的使用 | 可确认语义 |
|---|---|---|
| `remoteName` | 与 `gameDir` 拼接为本地文件路径；修复时也拼到 `remoteDir` | 相对游戏目录的远程/本地文件名。源码没有显示完整 schema 校验或路径遍历防护 |
| `fileSize` | 与 `stats(localPath).size` 精确比较 | 期望文件字节数；源码按 JavaScript number 使用 |
| `md5` | 与本地 `md5` 命令输出转小写后比较 | 整个文件的 MD5 十六进制摘要 |

这证明 `pkg_version` 是“每行一个 JSON 对象”的 JSON Lines 风格文本，而不是一个 JSON 数组。当前本地源码没有提供真实样例，因此不能进一步断言字段顺序、转义规则、所有可选字段或生成端格式。

### 5.2 真实校验算法

YAAGL 通用校验先检查文件大小，再调用 `utils/unix.ts:13-16` 的 `md5(path)`，该函数运行 `md5 -q <path>` 并取第一行；随后与 `entry.md5` 做大小写不敏感比较（`program-check-integrity.ts:32-43`）。因此对 `pkg_version` 的真实算法是：

```text
size(local file) == fileSize
AND
lowercase(md5 -q local file) == lowercase(entry.md5)
```

这不是根据记忆推断的 MD5；算法名称、命令和比较路径均由 YAAGL 源码直接给出。`utils/helper.ts:26-36` 的 SHA-256 只用于 aria2 GID，不能替代 `pkg_version.md5`。本报告不以 Apple SDK 提供何种摘要 API 来推导 YAAGL metadata 的算法；实现必须使用元数据声明的算法。

### 5.3 修复路径和边界

- 任一文件缺失、大小不符、MD5 不符或 `stats`/hash 失败都会进入 `toFix`（`program-check-integrity.ts:32-46`）。
- 修复通过 `remoteDir/remoteName` 下载到目标 `localPath`，没有在该函数中先写入独立临时文件并在校验后原子替换（`program-check-integrity.ts:60-74`）。
- `pkg_version` 解析异常会在遍历前直接抛出；本地源码未将损坏 metadata 单独映射为“无法判定”。
- 空 `pkg_version` 会产生零条目；源码仍计算 `(count / entries.length) * 100`，因此不能将空文件解释为完整。
- `hkrpg/index.tsx:324-330` 明确保留 `// FIXME: no pkg_version?`，而部分 HSR/ZZZ 路径使用 `GameAssembly.dll` 存在性作为安装探测（例如 `hkrpg/index.tsx:121-125`）。所以 `pkg_version` 不是所有 YAAGL 游戏/发行渠道的通用存在性证明。

## 6. Sophon manifest 与 `pkg_version` 的区别

HK4E 的 Sophon server 使用另一条基于压缩 chunk 的 manifest 链路。`sophon_server/manifest.proto` 定义：

| 消息/字段 | 注释与类型 |
|---|---|
| `FileInfo.filename` | 相对游戏目录的路径 |
| `FileInfo.flags` | `0` 文件，`64` 目录；其余值源码未观察到 |
| `FileInfo.size` | 整个文件大小 |
| `FileInfo.md5` | 整个文件 MD5 |
| `ChunkInfo.chunk_id` | 压缩 chunk 标识 |
| `ChunkInfo.md5` | 解压后 chunk 数据 MD5 |
| `ChunkInfo.offset` | chunk 写入最终文件的偏移 |
| `ChunkInfo.compressed_size` / `uncompressed_size` | 压缩/解压大小 |
| `ChunkInfo.xxhash` | 压缩 chunk 数据的 xxhash |

但字段定义不等于实现使用。`sophon_api.py:958-1007` 下载 chunk、zstd 解压并按 offset 组装临时文件，之后只用 `hashlib.md5(dstfile.read_bytes())` 对最终文件与 `file_info.md5` 比较；本地源码搜索未发现运行时读取 `chunk.md5` 或 `chunk.xxhash` 的代码。repair 的 reliable 模式也只对最终文件做 MD5（`sophon_api.py:1484-1512`）。

因此：

- `pkg_version.md5`、Sophon `FileInfo.md5` 都是文件级 MD5 事实，但它们来自不同 metadata 通道；
- `ChunkInfo.xxhash` 是协议定义字段，不是 YAAGL 当前已验证的文件完整性结论；
- 不应把 `aria2.ts` 的 GID SHA-256 前缀、Sophon chunk `xxhash` 或 Unity 版本识别用的 MD5 特征值混同为 `pkg_version` 的校验算法。

## 7. `config.ini` 字段语义

### 7.1 YAAGL 实际写入的字段

YAAGL 的 Mhy 安装/更新路径写入相同的 `[General]` 配置形状；BH3 的本地源码证据出现在更新路径，HSR 和 ZZZ 同时出现在安装与更新路径：

```ini
[General]
game_version=<版本>
channel=<数字>
sub_channel=<数字>
cps=<字符串>
```

证据：`mhy/bh3/program-update-game.ts:152-159`、`mhy/hkrpg/program-install-game.ts:64-71`、`mhy/hkrpg/program-update-game.ts:167-174`、`mhy/nap/program-install-game.ts:69-76`、`mhy/nap/program-update-game.ts:146-153`。字段的可确认语义为：

| 字段 | 源码事实 | 语义边界 |
|---|---|---|
| `game_version` | 写入函数参数 `gameVersion`/`updatedGameVersion`；Sophon 安装后取 `getBuild_json["data"]["tag"]` 写回 | 客户端版本字符串。Sophon 用它与 `globalgamemanagers` 版本锚点比较；它不是独立的完整性证明 |
| `channel` | 来自 `Server.channel_id`；当前 Mhy CN/OS 定义通常为 `1`，Bilibili HK4E 由 Sophon 模板使用 `14` | 发行渠道数值。源码证明它是渠道选择字段，不提供所有数字的官方枚举说明 |
| `sub_channel` | 来自 `Server.subchannel_id`；Sophon 对 NAP 使用 `0` 判 OS、`1` 判 CN；HK4E 的 Sophon 还根据可执行文件/插件判断 OS/CN/BB | 区域/子渠道识别字段。不能只凭 `channel=1` 推断区域 |
| `cps` | YAAGL `Server.cps` 写入；Sophon 模板出现 `mihoyo` 和 `bilibili` | 发行/推广来源标识；本地源码没有更详细的官方字段规范 |

Sophon 安装模板还写入 `sdk_version=`（`sophon_api.py:380-395`），而 YAAGL TypeScript 安装/更新模板未写该字段。两条实现不能混成同一个完整 schema。

### 7.2 版本锚点和更新顺序

Sophon 对已安装版本使用两个锚点：

- HK4E 从 `globalgamemanagers` 的二进制内容读取 `MAJOR.MINOR.PATCH`；NAP 走同一类 Unity `globalgamemanagers` 读取逻辑（`sophon_api.py:435-450`）；
- `config.ini` 中用正则读取一个 `game_version=数字.数字.数字`；如果配置版本高于二进制锚点，记录潜在问题并保留较旧的二进制版本；相等或更低时使用配置版本（`sophon_api.py:455-484`）；
- 安装/更新完成后，Sophon 将 `config.ini` 的版本替换为新 build tag（`sophon_api.py:1035-1081`），说明配置版本被当作“最后更新完成后的记录”，而不是唯一事实来源。

YAAGL TypeScript 路径也会在下载/解压后写 `config.ini`，但部分路径在发现已有目录或旧版本时只更新 UI/持久化路径，完整性调用仍有 FIXME 或注释代码。因此存在目录存在、版本值更新和完整性通过三种不同语义，不能相互替代。

### 7.3 `wpf_version` 的证据结论

在本地 `References/YAAGL/` 中对 `wpf_version` 搜索无命中。相近字段只有：

- `sdk_version=`：Sophon 新建 `config.ini` 时写入空值；
- `game_version=`：实际被读取、比较和更新；
- `Audio_<language>_pkg_version`：用于发现已安装语音包名称，不是 `wpf_version`。

因此本报告不能给 `wpf_version` 指定“Windows/Wine/平台框架版本”等含义。MiPlay 不应读取或生成该字段，除非后续取得同一游戏/发行渠道的官方配置规范或真实样本并单独核实。

## 8. Apple 平台约束

### 8.1 本地配置与游戏目录

Apple `NSURL.h` 的 security-scoped bookmark 注释规定：沙盒外资源需要带 security scope 的 bookmark；解析使用 `withSecurityScope`，成功调用 `startAccessingSecurityScopedResource()` 后必须平衡调用 `stopAccessingSecurityScopedResource()`；从 URL 取出的裸 path 不携带 scope。既有报告 A2 已逐条记录这些语义。

对 MiPlay 当前工程，`MiPlay.xcodeproj/project.pbxproj` 的 Debug/Release 都设置 `ENABLE_APP_SANDBOX = YES` 和 `ENABLE_USER_SELECTED_FILES = readonly`。因此：

- 读取用户选中的游戏目录需要 bookmark 恢复和有效 scope；
- 写入 `config.ini`、修复 `pkg_version` 指向的游戏文件或写回目录，需要实际的读写权限验证；当前 `readonly` 设置不能被解释为写入已获授权；
- Wine/Process 子进程继承主应用沙盒，不能借子进程绕过目录权限；
- scope 生命周期必须覆盖读写、校验、替换和启动所需操作，并在完成或失败时释放。

证据：`research-apple-platform-constraints.md:75-117`、`MiPlay.xcodeproj/project.pbxproj:247-250,290-293`、本机 SDK `NSURL.h` 的 Bookmarks and Security Scope 注释。

### 8.2 文件完整性算法的边界

Apple 平台约束这里关注“何时允许提交文件”和“失败时如何处理”，不从平台 API 名称推导 YAAGL metadata 的摘要算法。`pkg_version` 与 Sophon manifest 的算法事实见第 5、6 节和 Y5、Y6；实际实现要求是：

- 既有 `pkg_version` 或 Sophon manifest 的校验必须按其字段声明的 MD5 兼容，不能凭偏好换成 SHA-2/SHA-256；
- 新下载来源的 digest 必须来自批准发布者的元数据或签名，不能由文件名、URL、HTTP 200 或本地重新计算出的未知值“自证”；
- 文件大小、文件摘要、归档结构和最终安装路径分别验证；验证失败的临时文件不得提交为已安装资源；
- 对远程 metadata 解析失败、字段缺失、算法未知或版本不匹配，应报告不可判定/失败，而非猜测算法后继续。

### 8.3 网络失败与临时文件

既有 Apple 约束报告的 A4/A5 证据表明：`URLSession` 的客户端传输 `error` 与 HTTP `response` 分开；服务器非 2xx 不一定进入 `error`；下载成功回调中的临时文件必须在回调返回前读取或移动到永久位置；取消后仍可能存在回调。

将这些约束映射到 YAAGL 事实：

- YAAGL aria2 封装没有在 `doStreamingDownload` 中公开 HTTP status 或最终内容 digest；
- `pkg_version` repair 直接把下载目标设为游戏文件路径，而不是“下载临时文件 → 校验 → 原子替换”；
- Wine/updater 下载完成后立即解压、移动或写入 `wine_state`/`wine_tag`，没有在本地 YAAGL 代码中看到发布者 digest/签名验证；
- 失败、取消、部分写入、解压失败和版本记录提交必须分别处理，不能只以进度完成或目标路径存在判定成功。

### 8.4 Apple 侧可验证实现要求

1. 对游戏目录先恢复 bookmark，确认读写 scope；在同一 scope 内读取 `pkg_version`/`config.ini`、计算声明的 digest、下载到临时路径并完成后置验证。
2. 对 `remoteName` 等相对路径做路径安全检查；拒绝绝对路径、目录穿越和超出已授权游戏根目录的目标。
3. 仅在大小、声明算法的 digest、资源版本、归档内容和目标路径均验证后提交安装/修复状态；临时文件和残留记录失败时清理。
4. 网络层分开记录 DNS/连接/TLS/传输错误、HTTP status、响应格式、用户取消和资源超时；取消要桥接到下载任务并等待清理完成。
5. `config.ini` 更新应是受控的文件替换，保留前一份有效配置或可恢复副本；写入成功不能替代重新读取和版本一致性验证。
6. 当前 Sandbox 配置为只读时，写入路径必须明确返回不可用/失败；不能建议关闭 App Sandbox、Hardened Runtime 或调用任意 sudo 绕过权限。

## 9. 来源证据索引

| 编号 | 本地来源 | 支撑结论 |
|---|---|---|
| Y1 | `References/YAAGL/src/github.ts:3-48` | API endpoint 候选、5 秒竞速、状态处理、代理前缀和未使用的 `acceleratedPath` |
| Y2 | `References/YAAGL/src/updater.ts:17-87,94-150` | GitHub latest release、按 asset 名称选择、`browser_download_url` 直连下载 |
| Y3 | `References/YAAGL/src/wine/distro.ts:17-78`、`References/YAAGL/src/wine/wine-install-program.ts:35-104` | Wine 版本清单、GitHub Release 直链、下载后解压和状态持久化 |
| Y4 | `References/YAAGL/src/aria2.ts:36-64`、`References/YAAGL/src/utils/helper.ts:26-36` | aria2 GID 使用 SHA-256 前缀；下载封装无内容算法校验 |
| Y5 | `References/YAAGL/src/clients/mhy/program-check-integrity.ts:15-74`、`References/YAAGL/src/utils/unix.ts:13-16`、`References/YAAGL/src/utils/neu.ts:264-270` | `pkg_version` JSON Lines、`remoteName/fileSize/md5`、大小 + MD5 校验和修复路径 |
| Y6 | `References/YAAGL/sophon_server/manifest.proto`、`References/YAAGL/sophon_server/manifest_ldiff.proto`、`References/YAAGL/sophon_server/sophon_api.py:914-1010,1468-1512` | Sophon manifest 字段与实际最终文件 MD5 校验；chunk xxhash 未在实现中使用 |
| Y7 | `References/YAAGL/src/clients/mhy/bh3/program-update-game.ts:152-159`、`References/YAAGL/src/clients/mhy/hkrpg/program-install-game.ts:64-71,167-174`、`References/YAAGL/src/clients/mhy/nap/program-install-game.ts:69-76,146-153` | YAAGL 写入 `game_version/channel/sub_channel/cps` |
| Y8 | `References/YAAGL/sophon_server/sophon_api.py:372-484,1035-1081`、`References/YAAGL/sophon_server/tasks.py:11-17` | `config.ini` 模板、渠道识别、版本双锚点与最后更新写回 |
| Y9 | `References/YAAGL/src/clients/mhy/hkrpg/index.tsx:121-125,324-330`、全树 `wpf_version` 搜索无命中 | `pkg_version` 并非所有渠道通用；`wpf_version` 无本地语义证据 |
| A2/A4/A5 | `Docs/01-research/research-apple-platform-constraints.md:75-177` 与报告中的本机 SDK 路径 | security-scoped bookmark、只读/读写目录、HTTP status/error、临时文件和取消约束 |

## 10. 不可行方案与待上游复核

### 10.1 不可行方案

1. 把 `ghp.3shain.uk` 或任意新域名直接加入 MiPlay allowlist，而没有发布身份、bytes 等价、digest/签名和失败回退测试。
2. API 成功但 asset 直链失败时静默报告 Wine/更新包已下载，或静默回退到外部 Wine。
3. 把 `pkg_version` 的 MD5 改写成 SHA-256，或把 aria2 GID 的 SHA-256、Sophon chunk xxhash 当成文件完整性算法。
4. 把 `pkg_version` 存在、`config.ini` 中版本值存在、目标文件存在或下载进度 100% 直接当作游戏完整/安装成功。
5. 在没有 `wpf_version` 官方字段定义或真实样本的情况下按名称猜测其含义并参与版本判断。
6. 在当前 App Sandbox 只读配置下直接修改沙盒外游戏目录，或通过关闭沙盒/Hardened Runtime、任意 sudo、未验证 helper 绕过权限。

### 10.2 上游复核项

- **Architecture/Implementation**：若当前 MiPlay 仍需写入用户选中的游戏目录，必须先解决 `ENABLE_USER_SELECTED_FILES = readonly` 的契约/实现冲突；本报告不修改该配置。
- **Product**：Product 已将 Wine 来源限制为批准的上游；当前 YAAGL 列表包含多个 GitHub owner，不能据此自动扩大 MiPlay allowlist。
- **Implementation/Review**：下载提交前需要显式的来源身份、版本、大小、声明 digest/签名、临时文件和取消清理状态；YAAGL 现有直链/aria2 代码不能作为完成标准。
- **Research/外部验证**：要宣称“中国网络环境可行”，仍需要明确测试环境、时间、DNS/IPv4/IPv6、官方 GitHub API、Release asset、批准 API 和失败回退分别测量；本报告没有把当前机器探测当作中国网络结论。

## 11. 研究结论

YAAGL 的真实语义可以可靠地归纳为：GitHub API 有一个简单前缀代理候选，但 Release/Wine asset 仍主要直连；`pkg_version` 使用每行 JSON 对象和文件级 MD5/大小；Sophon manifest 也以文件 MD5 为主要后置校验；`config.ini` 是渠道与版本记录，其中 `game_version` 是与二进制版本共同使用的更新锚点，`wpf_version` 在本地源码中没有可核实定义。

这些事实足以说明当前 YAAGL 源码不能证明一个稳定的中国镜像下载方案，也不能为 MiPlay 选择未经验证的第三方镜像或猜测算法。Apple 平台侧应将 bookmark/沙盒写入、HTTP 错误、临时文件、取消和声明完整性验证作为独立可观察条件；任何条件缺失都只能进入失败/不可用，而不是伪造成功。
