# Research 修订报告: Wine 归档结构与 macOS 设备信息

日期: 2026-08-05  
范围: Wine 归档结构、当前和参考实现的路径假设、Mac 硬件信息、macOS 版本、磁盘容量。  
限制: 本文件只记录研究事实、代码证据、Apple 本地 SDK/man page 证据和待验证项，不修改源码、Product、UX、UI 或 Architecture 文档。

## 1. 结论摘要

1. 本地用户归档 `wine-devel-11.8-osx64-signed.tar.xz` 的顶层目录是 `wine/`。实际 Wine binary 是 `wine/bin/wine`，不是归档根下的 `bin/wine`。归档中未发现 `wine64`，但发现 `wineboot`、`winecfg` 和 `wineserver`。
2. 当前 MiPlay 用 `tar -xJf ... -C <staging>` 解压且没有 `--strip-components`。因此本地归档解压后实际路径是 `<staging>/wine/bin/wine`。当前 `extractArchive` 在返回前检查 `<staging>/bin/wine`，会直接把该归档判定为“解压后未找到 wine 可执行文件”。这是当前安装失败的已证实路径不匹配，不是仅凭 UI 状态推断的原因。
3. 当前 Wine 版本管理器、readiness、已安装版本扫描和 runtime provider 都固定检查 `<版本根>/bin/wine`。即使绕过下载阶段检查，实际保留顶层目录的归档仍不能通过后续验证。
4. 旧版 MiPlay 同样调用 `tar -xJf` 且保留顶层目录；旧版 `WineManager` 没有在安装后验证 `bin/wine`，所以“旧版本正常”不能从代码直接证明。旧版后续 `wine64` 路径也与当前本地归档不匹配。
5. YAAGL 的事实是：运行时根目录预期包含 `wine/`，binary 选择为先尝试 `./wine/bin/wine64`，失败后回退 `./wine/bin/wine`。它的 `tar_extract_directory` 支持显式 `--strip-components`，但该函数本身不证明所有 Wine 归档都应被 strip。
6. `MacBookPro18,1` 是 `hw.model` 的机器型号标识，不是芯片名称。当前本机的独立实证是 `hw.model=MacBookPro18,1`、`machdep.cpu.brand_string=Apple M1 Pro`、`system_profiler` 的 `machine_name=MacBook Pro` 和 `chip_type=Apple M1 Pro`。本地 Apple 工具没有在这次输出中给出“16 英寸”字段，因此不能只凭 `MacBookPro18,1` 推导营销名称。
7. `ProcessInfo.operatingSystemVersion` 是数字版本结构，`sw_vers --productVersion` 是用户可见的产品版本，`sw_vers --buildVersion` 或 `kern.osversion` 是构建号。当前本机的实证为 `27.0` 和 `26A5388g`。当前源码把数字版本格式化为 `27.0.0`，这解释了 UI 与 `sw_vers` 的差异。
8. 当前磁盘检测失败有一个直接的代码路径：`SettingsViewModel` 把 `NSHomeDirectory()` 作为普通字符串传给检测器，检测器随后无条件调用 `startAccessingSecurityScopedResource()`；Apple SDK 说明 security scope 来自用户选择或 security-scoped bookmark，字符串路径不会携带该 scope。当前 guard 失败时不会进入 resource-value 或 FileManager fallback，因此很可能直接显示“检测失败”。

## 2. 本地归档实证

### 2.1 对象和命令

归档路径:

`/Users/stevetan/Downloads/AnimeGameWineDownloads/wine-devel-11.8-osx64-signed.tar.xz`

执行的检查:

```sh
stat -f '%N %z bytes' \
  /Users/stevetan/Downloads/AnimeGameWineDownloads/wine-devel-11.8-osx64-signed.tar.xz
file /Users/stevetan/Downloads/AnimeGameWineDownloads/wine-devel-11.8-osx64-signed.tar.xz
shasum -a 256 \
  /Users/stevetan/Downloads/AnimeGameWineDownloads/wine-devel-11.8-osx64-signed.tar.xz
tar -tJf wine-devel-11.8-osx64-signed.tar.xz
tar -tvJf wine-devel-11.8-osx64-signed.tar.xz
```

结果:

| 项目 | 结果 | 证据性质 |
| --- | --- | --- |
| 文件类型 | XZ compressed tar，checksum CRC64 | 本地 `file` 输出 |
| 大小 | `417187260` bytes，约 398 MiB | 本地 `stat` 输出 |
| SHA-256 | `42430b7e8398642d7121e7cbac0aa03ce7312b4500e4ddf7eb75a7c8f2407a9c` | 本地 `shasum -a 256` 输出；仅是该文件摘要，不是 pkg_version 语义 |
| 归档条目数 | `12105` | 本地 `tar -tJf` 输出计数 |
| 顶层目录 | `wine` | 本地 `tar -tJf` 输出 |
| `wine/bin/wine` | 存在，归档权限 `-rwxr-xr-x` | 本地 `tar -tvJf` 输出 |
| `wine/bin/wine64` | 未发现 | 对完整 listing 的精确路径查询 |
| `wine/bin/wineboot` | 存在 | 本地 `tar -tvJf` 输出 |
| `wine/bin/winecfg` | 存在 | 本地 `tar -tvJf` 输出 |
| `wine/bin/wineserver` | 存在 | 本地 `tar -tvJf` 输出 |
| `wine/prefix` | 未发现 | 对完整 listing 的前缀查询 |

归档前几项为 `wine/`、`wine/bin/`、`wine/lib/`、`wine/share/` 等。当前实证没有发现一个可作为游戏专属 prefix 的 `prefix/` 顶层或 `wine/prefix/` 目录；Wine prefix 是否在之后创建属于运行时流程，不应从本归档推断。

### 2.2 真实路径矩阵

| 查找相对路径 | 本地归档结果 | 说明 |
| --- | --- | --- |
| `bin/wine` | 不存在 | 只有在解压时去除 `wine/` 顶层目录才会得到该路径 |
| `wine/bin/wine` | 存在 | 本地归档的可执行 Wine binary |
| `wine/bin/wine64` | 不存在 | 不能假定旧版或其他发行包一定提供它 |
| `wine/bin/wineboot` | 存在 | 同一归档中的辅助 binary |
| `wine/bin/winecfg` | 存在 | 同一归档中的辅助 binary |
| `wine/bin/wineserver` | 存在 | 同一归档中的辅助 binary |
| `prefix` / `wine/prefix` | 未发现 | 不能把 prefix 当作归档内固定资源 |

这份矩阵只对上述本地文件负责。其他 release、签名变体、架构变体或镜像返回的归档必须重新执行 listing 和 binary 检查。

## 3. 当前 MiPlay 解压与失败路径

### 3.1 当前解压命令

`MiPlay/Infrastructure/Wine/WineVersionDownloaderExtraction.swift:77-96` 依次执行:

- `tar -tJf <archive>` 读取列表。
- `tar -tvJf <archive>` 检查详细条目和符号链接。
- `tar -xJf <archive> -C <staging>` 解压。
- `validateExtractedTree` 检查解压后的符号链接边界。

该调用没有 `--strip-components=1`，也没有把归档内部的 `wine/` 子目录移动或重命名。因此对本地归档，解压结果应为:

```text
<staging>/wine/bin/wine
<staging>/wine/bin/wineboot
<staging>/wine/bin/winecfg
<staging>/wine/bin/wineserver
```

### 3.2 已证实的失败点

`MiPlay/Infrastructure/Wine/WineVersionDownloaderExtraction.swift:186-208` 使用:

```text
<staging>/bin/wine
```

检查解压结果。对本地归档该路径不存在，代码随后清理 staging 并抛出“解压后未找到 wine 可执行文件”。由于该检查位于归档删除和成功返回之前，失败可发生在 `WineVersionManager` 看到完成事件以前。

即使该检查被绕过，以下路径仍然使用同一假设:

| 当前位置 | 路径假设 | 影响 |
| --- | --- | --- |
| `MiPlay/Domain/Runtime/WineVersionManagerDownload.swift:37-45` | 已存在版本为 `<version>/bin/wine` | 重复安装判定不能识别 `<version>/wine/bin/wine` |
| `MiPlay/Domain/Runtime/WineVersionManagerDownload.swift:102-104` | staging 为 `<staging>/bin/wine` | 安装前再次失败 |
| `MiPlay/Domain/Runtime/WineVersionManagerDownload.swift:250-252` | `wineBinaryFor(root)` 返回 `root/bin/wine` | 管理器公共内部路径事实不匹配 |
| `MiPlay/Domain/Runtime/WineVersionManagerReadiness.swift:30-33` | 版本根下为 `bin/wine` | readiness 报告 binary 不存在 |
| `MiPlay/Domain/Runtime/WineVersionManagerReadiness.swift:121-124` | 选中版本根下为 `bin/wine` | selected runtime 不能就绪 |
| `MiPlay/Domain/Runtime/WineVersionManagerInstalled.swift:20-23` | 已安装扫描检查 `bin/wine` | 实际已解压目录不会进入已安装列表 |
| `MiPlay/Domain/Runtime/WineVersionManagerInstalled.swift:50-55` | 提交安装前检查 `bin/wine` | 安装记录不能提交 |
| `MiPlay/Domain/Runtime/WineVersionModels.swift:72-74` | `ManagedWineRuntime.binaryURL` 为 `root/bin/wine` | runtime provider 使用同一错误路径 |
| `MiPlay/Infrastructure/Wine/WineRuntimeProvider.swift:67-76` | binary URL 必须存在且可执行 | 启动前 gate 仍会失败 |

### 3.3 结论边界

已确认的是“本地归档结构”和“当前路径假设互相不一致”。以下事项仍需后续阶段验证:

- 目标产品契约应采用保留顶层目录，还是在受控解压时 strip 顶层目录。
- 所有被批准 Wine 版本是否都采用相同顶层目录。
- binary 路径统一后，动态库、`share`、`lib` 和 Wine prefix 的相对查找是否仍与 runtime provider 的工作目录一致。
- 归档 binary 在真实签名 App、App Sandbox 和 Hardened Runtime 下的启动结果。

研究不能仅凭这一个归档决定未来所有版本的内部布局，也不能把“改成 `wine/bin/wine`”直接当作 Architecture 或 Implementation 决策。

## 4. 参考实现对比

### 4.1 旧版 MiPlay

证据:

- `References/MiPlay/Wine/WineDownloader.swift:54-71` 使用 `/usr/bin/tar` 的 `-xJf <archive> -C <destination>`，没有 `--strip-components`，所以同样保留归档顶层 `wine/`。
- `References/MiPlay/Wine/WineManager.swift:61-85` 先创建 `<Versions>/<version>`，再把归档解压到该目录。安装函数没有检查 `<target>/bin/wine` 或 `<target>/wine/bin/wine`，只在完成后刷新目录列表。
- `References/MiPlay/Wine/WineManager.swift:36-55` 的 installed scan 只确认版本项是目录，并没有确认 Wine binary。
- `References/MiPlay/Wine/WineVersion.swift:64-129` 通过 GitHub Releases API 取得资产，保存 `asset.size` 和可选 `sha256` 元数据；这与归档内部路径是两个独立问题。
- `References/MiPlay/Wine/WinePrefix.swift:49-91`、`References/MiPlay/Launcher/GameLauncher.swift:99-100` 和 `References/MiPlay/Launcher/LaunchService.swift:177` 使用 `bin/wine64`，而本地归档没有 `wine64`。

因此旧版代码的可复用事实是“调用 tar 可展开该类归档，并把顶层目录保留在目标目录内”；不可直接复用的部分是“把版本根当成 binary 根”和“固定使用 wine64”。旧版本没有提供“安装成功且可启动”的充分代码证据，用户反馈的“旧版本正常”仍应通过可重复运行测试确认。

### 4.2 YAAGL

`References/YAAGL/src/wine/wine.ts:172-180` 的 `getCorrectWineBinary()`:

1. 先检查 `./wine/bin/wine64`。
2. 检查失败后返回 `./wine/bin/wine`。

这证明 YAAGL 的运行时工作目录预期包含 `wine/` 顶层目录，并且新 Wine/WoW64 包可能只有 `bin/wine`。它没有证明 MiPlay 的 staging 目录必须采用相同的工作目录，也没有证明所有包都没有 `wine64`。

`References/YAAGL/src/utils/neu.ts:104-123` 的 `tar_extract_directory()` 支持传入目录并使用 `--strip-components=<目录深度>`。这是一种可参考的解压能力，但调用方必须知道要 strip 的确切目录；对未知归档不能无条件删除第一层。

### 4.3 AnimeGameWineReleaseFetcher

外部项目 `/Users/stevetan/SteveTan/Document/Xcode/AnimeGameWineReleaseFetcher` 是 Release 浏览和资产下载工具，不是 Wine 安装器:

- `Sources/AnimeGameWineReleaseFetcher/main.swift:129-190` 调用 `https://api.github.com/repos/yaagl/anime-game-wine/releases` 并只接受 HTTP 200 的 JSON。
- `main.swift:397-467` 使用资产的 `browser_download_url`，使用 `URLSessionDownloadDelegate`，记录进度，检查最终 HTTP 是否为 2xx，把临时下载文件移到目标路径，失败时删除 staging 文件。
- `main.swift:293-305` 接受 URLSession 提供的 HTTP redirect；这能证明该工具观察并继续 302 链路，但不等于 MiPlay 的 allowlist 已验证了重定向目标。
- `main.swift:308-318` 只记录 `didResumeAtOffset` 回调。下载入口每次新建 `downloadTask`，源码没有持久化 resume data 或恢复任务的流程，因此不能把它称为完整的断点续传实现。
- `main.swift:415-419` 记录 API 给出的 expected size，但 `main.swift:451-467` 没有把实际文件大小与 expected size 做强制比较，也没有摘要校验。
- 仓库没有找到解压 Wine 归档的实现。其 README 说明下载文件存放在 `~/Downloads/AnimeGameWineDownloads/`，本地同名目录中的归档就是本报告检查对象。

该工具可作为 HTTP 302、非 2xx、临时文件和下载进度的参考证据，不能直接作为 MiPlay 的安装路径、归档完整性或 Sandbox 方案。

### 4.4 对比表

| 维度 | 当前 MiPlay | 旧版 MiPlay | YAAGL | AnimeGameWineReleaseFetcher |
| --- | --- | --- | --- | --- |
| 解压命令 | `/usr/bin/tar -xJf`，保留顶层 | `/usr/bin/tar -xJf`，保留顶层 | 提供普通解压和显式 strip helper | 无解压实现 |
| 本地 Wine 路径假设 | `<root>/bin/wine` | 目录扫描不验证，后续多处 `<root>/bin/wine64` | `./wine/bin/wine64` 回退 `./wine/bin/wine` | 不适用 |
| 归档路径事实 | 本地归档为 `wine/bin/wine` | 对相同 tar 命令也会保留 `wine/` | 运行时代码预期 `wine/` | 不适用 |
| HTTP 状态 | 当前 provider 有独立 failure 分类，需以当前源码测试为准 | 无进度 overload 的 `download` 检查 200；带进度 overload 未见状态检查 | 不适用 | API 只接受 200，资产接受 2xx |
| 302 | 由 URLSession 链路处理，当前 allowlist 还需按 redirect host 验证 | 未见独立 redirect policy | 不适用 | delegate 明确接受 redirect request |
| 临时文件 | 当前 staging 受托管目录边界约束，失败/取消清理由当前流程处理 | URLSession 临时文件直接移动，失败清理不完整 | 不适用 | 独立 `.download` staging，失败删除 |
| 摘要/大小 | 当前合同应以批准元数据和当前校验实现为准 | 版本元数据保存 size/可选 sha256；下载层未统一强制 | 不适用 | 记录 API size，未强制比较或摘要验证 |
| 安装结论 | 由 binary、权限、持久化和 readiness 共同决定 | 目录存在即可刷新，未充分证明可运行 | 只提供 Wine 运行时路径辅助 | 只证明下载完成，不证明可安装 |

## 5. Apple 硬件信息证据

### 5.1 本机实证

执行:

```sh
system_profiler -json SPHardwareDataType
sw_vers
sysctl -n hw.model
sysctl -n machdep.cpu.brand_string
sysctl -n hw.optional.arm64
sysctl -n kern.osversion
```

关键输出:

```text
machine_name: MacBook Pro
machine_model: MacBookPro18,1
chip_type: Apple M1 Pro
physical_memory: 16 GB

ProductName: macOS
ProductVersion: 27.0
BuildVersion: 26A5388g

hw.model: MacBookPro18,1
machdep.cpu.brand_string: Apple M1 Pro
hw.optional.arm64: 1
kern.osversion: 26A5388g
```

`system_profiler` 的完整输出还包含序列号、平台 UUID 等识别信息。用户信息界面和诊断导出不应默认展示或记录这些字段；`-detailLevel mini` 的 Apple man page 说明该级别不包含 personal information，但它是否提供所需硬件字段仍需在目标系统验证。

### 5.2 字段含义矩阵

| 目标显示 | 有证据的来源 | 已确认语义 | 不能直接推断 |
| --- | --- | --- | --- |
| 用户可读机型名称 | `system_profiler SPHardwareDataType` 的 `machine_name`；本机为 `MacBook Pro` | Apple 工具返回的机器名称 | 不能从 `hw.model` 字符串自行拼出“16 英寸”或营销后缀 |
| model identifier | `sysctl hw.model`；本机为 `MacBookPro18,1`；`system_profiler` 的 `machine_model` 同值 | 机器型号标识；man 3 `sysctl` 将 `hw.model` 描述为 machine model | 不是 chip model，也不是显示器尺寸 |
| 芯片名称 | 本机 `system_profiler` 的 `chip_type` 和 `machdep.cpu.brand_string` 都为 `Apple M1 Pro` | 本机实证的芯片字符串 | 不应把 `hw.model` 作为 Apple Silicon 芯片名；跨机型字符串可用性需验证 |
| Apple Silicon 判断 | 本机 `hw.optional.arm64=1` | 本机 selector 返回已启用 arm64 | selector 失败、虚拟机和未来硬件的错误处理需要测试 |
| macOS 用户版本 | `sw_vers --productVersion`；`ProcessInfo.operatingSystemVersion` | 产品版本或数字版本结构 | 不应把 build number 当成用户版本 |
| macOS build | `sw_vers --buildVersion`；`kern.osversion` | 本机为 `26A5388g` | 不应把 build number 展示为 `27.0` |

### 5.3 Apple 本地 SDK 和工具依据

以下均为本机 Xcode 27 macOS SDK 或 Apple 随系统提供的 man page，不是第三方资料:

- `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSProcessInfo.h:227-233` 规定 `operatingSystemVersionString` 适合用户显示、且不适合解析；`operatingSystemVersion` 提供数字版本结构。
- 同一 `NSProcessInfo.h:235-248` 说明 `processorCount` 和 `physicalMemory` 的返回内容。
- `/usr/share/man/man1/sw_vers.1` 的 DESCRIPTION 说明 `ProductVersion` 是产品版本，`BuildVersion` 是 macOS build system 生成的具体修订号。
- `/usr/share/man/man8/system_profiler.8` 说明该工具报告硬件和软件配置，可输出 JSON；`-detailLevel mini` 是不含 personal information 的级别。
- `man 3 sysctl` 说明 `sysctlbyname` 接受 ASCII selector；该页的 selector 表把 `hw.model` 列为 `char[]`，定义为 machine model，并把 `kern.osversion` 列为 `char[]`。
- `.../MacOSX27.0.sdk/usr/include/sys/sysctl.h:626-642` 说明硬件 selector 的类型规则以及 memory/CPU selector；`sysctlbyname` 的声明在同文件 `:801-806`。

### 5.4 对当前源码的事实核对

`MiPlay/Infrastructure/System/SystemEnvironmentDetector.swift` 当前行为:

- `:55-60` 使用 `ProcessInfo.operatingSystemVersion`，并总是拼出 major/minor/patch，因此当前 `27.0` 可能显示为 `27.0.0`。
- `:63-72` 通过 `kern.osversion` 读取 build number。
- `:83-105` 先读取 `machdep.cpu.brand_string`，但在 Apple Silicon 分支改为返回 `hw.model`。这会把 `MacBookPro18,1` 放到 `chipModel` 字段，是当前 Mac 信息显示错误的直接代码证据。
- `SystemInfo` 在 `:30-38` 只有 `chipModel`，没有独立的 marketing model 或 model identifier 字段。因此当前模型与芯片在数据结构层面也没有被区分。

实现阶段至少应以独立字段承载 machine name、model identifier、chip name、OS product version 和 build number；具体 API 组合、显示格式和跨硬件 fallback 属于后续阶段决策。

## 6. Apple 磁盘容量证据

### 6.1 本机卷实证

```text
diskutil info /:
Volume Name: Macintosh HD
Disk Size: 994.7 GB
Container Free Space: 23.8 GB

df -H /:
Size 995G, Used 12G, Avail 24G
```

本机根卷可读到约 24 GB available。这个命令结果证明卷有容量数据，不证明每个 App Sandbox 调用路径都能读取它。

### 6.2 Foundation API 语义

- `.../Foundation.framework/Headers/NSURL.h:543-552` 说明 volume resource value 可以从任意 file system URL 请求，并给出 total capacity 与 available capacity。
- `NSURL.h:628-640` 定义 `NSURLVolumeAvailableCapacityForImportantUsageKey`。它包含可通过清理非必要/缓存资源释放的容量，适用于用户明确请求或应用功能需要的可替代资源；该值不能被当作不可替代资源的绝对保证。
- `NSURL.h:642-651` 定义 opportunistic usage 容量，语义与用户主动请求的 Wine 下载不同，不能混用而不记录理由。
- `.../Foundation.framework/Headers/NSFileManager.h:339-347` 说明 `attributesOfFileSystemForPath:error:` 接收 mounted file system 中任意路径，并返回该卷的 attributes。
- `NSFileManager.h:1319-1328` 定义 `.systemSize` 为由 `statfs()` 得到的 file system size，`.systemFreeSize` 为由 `statfs()` 得到的 free space。

因此，面向 Wine 下载/解压的检测事实可以有两类来源:

1. 目标 `WineVersions` 或其父目录 URL 的 `volumeAvailableCapacityForImportantUsageKey` 和 `volumeTotalCapacityKey`。
2. 同一目标路径的 `attributesOfFileSystemForPath`，使用 `.systemFreeSize` 和 `.systemSize` 作为兼容 fallback。

两种来源都描述目标路径所在卷，不应固定假设 `/` 一定等于最终 App Support 所在卷。容量也会在检查后变化，预检查不能替代真实写入失败处理。

### 6.3 当前“检测失败”的代码链

`MiPlay/UI/ViewModels/SettingsViewModel.swift:236-242` 调用:

```text
systemDetector.getDiskSpace(at: NSHomeDirectory())
```

`MiPlay/Infrastructure/System/SystemEnvironmentDetector.swift:139-163` 随后:

1. 用字符串路径构造 `URL`。
2. 无条件调用 `url.startAccessingSecurityScopedResource()`。
3. 返回 `false` 就抛出 `pathNotReachable`。
4. 只有 resource values 抛错时才进入 `FileManager` fallback；第 2 步失败不会进入 fallback。

Apple SDK 的 `NSURL.h:86-103` 说明 security-scoped URL 来自 security-scoped bookmark 等授权来源，且从 security-scoped URL 取得的 string path 不携带 scope。`NSURL.h:909-925` 说明 `startAccessingSecurityScopedResource` 的返回值表示访问请求是否成功；`NSURL.h:927-940` 要求成功后平衡调用 stop。

据此，当前失败的适用解释是:

- `NSHomeDirectory()` 是普通路径，不是从用户选择 URL 或 bookmark 恢复得到的 security-scoped URL。
- 对 App 自有 Application Support 路径，检测器不应把普通 URL 当成外部用户目录的 security scope；对外部用户选择的目录，则应在有效 bookmark scope 内检测。
- 该问题是当前“显示检测失败”的高可信根因，但仍应在真实签名、App Sandbox 的运行产物中通过日志和 API 返回值确认，因为沙盒容器位置和签名 entitlement 会影响最终行为。

## 7. 可验证实现要求（供后续阶段）

以下是可测试要求，不是本 Research Agent 的源码修改:

### 7.1 Wine 归档

- 对每个批准资产在安装前执行 listing，并记录顶层目录、目标 binary、是否存在 `wine64`、archive size 和摘要。
- 不能仅检查一个硬编码路径。应在批准的归档布局契约中明确是保留顶层还是 strip，并测试至少一个带顶层目录和一个布局不同的拒绝样本。
- 在成功安装前验证真实 `wine` binary 存在、可执行，并使用同一 binary 执行 `--version`；同时验证 Wine 依赖的相对目录工作方式。
- 若 archive 不含 `wine64`，运行时必须使用已验证的 `bin/wine` fallback；不能由旧版代码的 `wine64` 假设覆盖该事实。
- 安装失败、取消和验证失败必须清理 staging；清理失败要保留 recovery fact，不能只报告下载成功。

### 7.2 Mac 信息

- 分别测试 Apple Silicon、Intel（若产品仍支持）和 API 查询失败时的字段 fallback。
- UI 中分别显示或标识 machine name、model identifier、chip name、OS product version 和 build number；不把任一字段复用为另一个字段。
- 不从 `MacBookPro18,1` 通过未经验证的本地映射硬编码“16 英寸”。如果产品必须显示尺寸，需要一份可验证的模型映射来源和失效策略。
- 对 `system_profiler` 或诊断数据采取最小字段原则，排除序列号、平台 UUID、UDID 等不必要的设备标识。

### 7.3 磁盘容量

- 对 MiPlay App Support/WineVersions 目标 URL 读取 volume resource values；对失败情况使用同一目标卷的 FileManager attributes fallback。
- 普通 app-owned URL 不要无条件要求 security-scoped access；外部用户目录才在 bookmark resolution 和 active scope 生命周期内访问。
- 测试真实签名 App、App Sandbox、容器内 Application Support、不同卷的目标目录、卷不可用和容量不足。
- 容量检查只作为提示或前置风险判断，必须保留真实 create/write/move/decompression 失败处理。
- 核对当前 `SystemEnvironmentDetector.hasSufficientDiskSpace` 的实际安全系数。其注释写 `1.5`，代码 `:166-170` 实际使用 `2x`，这是实现契约不一致，不能在研究报告中替用户选择一个数值。

## 8. 证据索引

### MiPlay 当前源码

- `MiPlay/Infrastructure/Wine/WineVersionDownloaderExtraction.swift:77-208`
- `MiPlay/Domain/Runtime/WineVersionManagerDownload.swift:37-110,250-275`
- `MiPlay/Domain/Runtime/WineVersionManagerReadiness.swift:21-45,112-124`
- `MiPlay/Domain/Runtime/WineVersionManagerInstalled.swift:8-55`
- `MiPlay/Domain/Runtime/WineVersionModels.swift:60-74`
- `MiPlay/Infrastructure/Wine/WineRuntimeProvider.swift:67-84`
- `MiPlay/Infrastructure/System/SystemEnvironmentDetector.swift:30-38,55-169`
- `MiPlay/UI/ViewModels/SettingsViewModel.swift:224-242`

### 本地参考代码

- `References/MiPlay/Wine/WineDownloader.swift:54-90`
- `References/MiPlay/Wine/WineManager.swift:36-85`
- `References/MiPlay/Wine/WineVersion.swift:64-129`
- `References/MiPlay/Downloads/DownloadManager.swift:33-92,96-158`
- `References/YAAGL/src/wine/wine.ts:172-180`
- `References/YAAGL/src/utils/neu.ts:104-123`
- `/Users/stevetan/SteveTan/Document/Xcode/AnimeGameWineReleaseFetcher/Sources/AnimeGameWineReleaseFetcher/main.swift:129-190,216-387,397-467`

### Apple 本地资料

- `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSURL.h:86-103,543-552,628-651,835-852,909-940`
- `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSFileManager.h:339-347,1319-1328`
- `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSProcessInfo.h:227-248`
- `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/usr/include/sys/sysctl.h:626-642,801-806`
- `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/share/man/man3/sysctl.3`，通过 `man 3 sysctl` 查阅
- `/usr/share/man/man1/sw_vers.1`，通过 `man 1 sw_vers` 查阅
- `/usr/share/man/man8/system_profiler.8`，通过 `man 8 system_profiler` 查阅

## 9. 研究状态

| 结论 | 状态 |
| --- | --- |
| 本地归档顶层和 Wine binary 路径 | 已确认，基于本地归档 listing |
| 当前安装失败的路径不匹配 | 已确认，基于归档 listing 和当前源码控制流 |
| 所有未来 Wine 归档都使用相同布局 | 待验证 |
| 旧版“正常”可以直接复制 | 未确认，代码不足以证明 |
| `hw.model` 是 chip name | 否，已排除 |
| `MacBookPro18,1` 对应 16 英寸营销名称 | 未确认，不可从本地证据推断 |
| 当前本机芯片字符串 | 已确认，本机实证为 Apple M1 Pro |
| `27.0` 与 `26A5388g` 的字段区分 | 已确认 |
| 目标卷存在容量信息 | 已确认，本机命令约 24 GB available |
| 当前“检测失败”的 security-scope 代码路径 | 高可信根因，需真实签名 App 复测 |
