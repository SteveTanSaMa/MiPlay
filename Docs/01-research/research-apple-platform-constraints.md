# Apple 平台约束补充报告

> **Agent**：Research Agent
> **日期**：2026-08-02
> **状态**：研究输出；不修改 Product、源码或架构契约
> **适用平台**：macOS 26+、Apple Silicon、App Sandbox、Hardened Runtime

## 1. 目的与证据范围

本报告核实 MiPlay 当前 P0/P1/P2 问题涉及的 Apple 平台约束，覆盖：

- Foundation `Process` 的终止回调、标准输出/错误管道和超时；
- App Sandbox 下的 security-scoped bookmark、用户选择的游戏目录写入和 privileged helper；
- `URLSession` 的 HTTP 响应、临时下载文件和取消；
- Swift concurrency 的任务取消与外部任务清理；
- macOS 无障碍、按钮、键盘操作、自定义控件；
- String Catalog 与运行时本地化。

本报告只记录平台事实、适用条件、限制和可验证的实现要求，不决定产品范围、UI 方案或架构实现方式。已有 Architecture ADR 的内容只在“平台复核”栏目中指出是否需要上游复核。

证据优先级如下：

1. 本机 Xcode macOS SDK 的 Apple API 头文件注释。SDK 路径由 `xcrun --show-sdk-path` 得到；本机当前路径为 `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`。
2. `References/Apple/apple-liquid-glass-docs/` 中收集的 Apple Developer Documentation。该目录的 `00-README.md` 记录来源为 Apple Developer Documentation，收集日期为 2026-07-13。
3. Apple 官方 Landmarks 参考工程中的 SwiftUI、无障碍和 String Catalog 用法。
4. 本机 Xcode SDK 的 `_Concurrency.swiftinterface` 公共 API 声明，用于核对 `Task` 取消状态、取消检查和取消处理器；Foundation `NSProgress.h` 用于核对可取消工作必须由调用方实现实际取消。

本地 Apple References 没有单独保存完整的 App Sandbox Design Guide 或 Swift concurrency 文档；Foundation 和 ServiceManagement SDK 头文件包含对应 Apple 官方文档链接及关键语义。本报告不以第三方网络资料补充这些缺口。

## 2. P0/P1/P2 对照

下表只标出平台约束与问题的交集，不改变问题严重性或归属。

| 问题 | 级别 | 直接相关的平台约束 | 必须能验证的结果 |
|---|---:|---|---|
| F-001 Wine 下载状态未接入 UI | P0 | 下载进度、临时文件生命周期、取消传播、可访问的取消按钮 | 下载、完成、失败、取消四种结果均能到达 ViewModel/UI；取消后没有半成品被标记为已安装 |
| F-002 下载失败静默吞错 | P1 | URLSession 将客户端传输错误与服务器 HTTP 错误分开交付 | 非 2xx、网络错误和取消不会被当作成功或普通流结束 |
| F-003 GitHub API 限速 | P1 | HTTP status/header 必须由调用方检查；429 等服务语义不由 URLSession 自动变成 Swift error | 记录 status code、相关 headers 和可重试状态；GitHub 限速本身是服务约束，不在 Apple 证据中推导 |
| F-004 下载速度为 0 | P2 | 下载进度回调只提供字节计数和 expected bytes；expected bytes 可能未知 | 速度由连续字节计数和时间计算，未知总大小时不伪造确定百分比 |
| F-005 磁盘空间检查 fallback | P2 | 下载文件先落在临时位置，成功后才移动；取消/失败要清理临时文件 | 临时文件、目标文件和解压目录的状态可区分；空间不足不产生“已完成” |
| P1-011 兼容方案入口断链 | P1 | 标准 Button、键盘可达性、VoiceOver 标签、动态本地化 | 入口可由键盘触发；图标按钮有本地化的 accessibility label；不同语言不混用 |
| P2-013 `/etc/hosts` / hostname Helper | P2 | 沙盒子进程继承父沙盒；需要不同 entitlement 的 helper 应走 XPC；SMJobBless 已被当前 SDK 标为弃用 | Helper 安装、签名、授权拒绝、XPC 失败和回滚均有明确结果；不能用沙盒绕过或任意 sudo |
| P2-014/P2-015 macOS 控件与尺寸 | P2 | 标准控件有平台行为；自定义控件必须补齐 accessibility 和键盘行为 | 视觉自定义不改变控件角色、值、动作和键盘路径 |

## 3. Process 与 stdout/stderr 管道

### 3.1 适用条件与事实

Foundation 的 `NSTask`（Swift 名称为 `Process`）用于启动并监控子进程。Apple SDK 注释明确说明：

- 子进程的工作目录、环境变量、标准输入、标准输出和标准错误在启动前设置；启动后不能修改环境；同一个实例只能运行一次。
- `standardOutput` 和 `standardError` 可以分别连接到 `Pipe`。当设置为 `Pipe` 时，系统会在当前任务一侧自动关闭对应的写端；不应自行传入错误的 pipe handle，否则自动关闭语义不成立。
- `terminationHandler` 在进程完成后被调用，可结合 `terminationStatus` 和 `terminationReason` 判定正常退出或信号终止。
- `terminationStatus` 只能在进程不再运行时读取。`waitUntilExit` 会阻塞当前执行路径，且不保证返回时 termination handler 已执行完。
- 在 App Sandbox 中，使用 `Process` 创建的子进程继承父应用的沙盒。Apple SDK 注释建议需要不同 sandbox entitlement 的 helper 使用 XPC Service。

来源：[A1] `NSTask.h` 的 `NSTask` 总览、`standardOutput`/`standardError`、`terminate`、终止状态和 `terminationHandler` 注释（约第 20-30、60-79、91-137 行）。

### 3.2 平台限制

1. `Process` 没有内置的“整个任务超时”属性。超时必须由调用方通过异步等待和取消/终止逻辑实现。
2. `waitUntilExit` 不是取消机制；在主线程或 actor 的同步执行路径中等待会阻塞该路径。
3. `terminationHandler` 与 `waitUntilExit` 存在完成顺序约束：不能用“`waitUntilExit` 返回”推断 handler 中的状态发布已经完成。
4. `terminate()` 发送 `SIGTERM`，且 Apple 注释说明目标进程可能忽略该信号。因此超时/取消不能只调用 `terminate()` 后立即报告完成，必须等待进程确实不再运行并记录未能终止的失败。
5. stdout 和 stderr 是两个独立的输出通道。若实现只读取其中一个，或者在等待进程退出后才顺序读取管道，必须通过高输出量测试排除子进程阻塞风险；这是管道使用的实现验证项，不可由普通短命令测试替代。

### 3.3 可验证的实现要求

- 在 `run()` 前设置 `executableURL`、参数数组、环境、工作目录，以及独立的 stdout/stderr pipe；参数以数组传递，不依赖 shell 拼接或字符串转义。
- 启动前安装唯一的 termination handler；handler 只收集退出状态并向 Domain/TaskScheduler 发布结果，不直接更新 SwiftUI 状态。
- stdout 与 stderr 必须并行持续消费到 EOF；保存截断策略和最大日志大小，避免无限制地将进程输出保存在内存中。
- 结果模型至少区分：启动失败、正常退出、非零退出、信号终止、超时、用户取消和管道读取失败。读取 `terminationStatus` 前先确认 `isRunning == false`。
- timeout 由结构化异步任务实现；触发后发送终止请求，等待 handler/退出确认，关闭 pipe 读取任务，再决定清理和结果映射。
- 验证用例必须包含：持续输出 stdout、持续输出 stderr、同时输出两者、非零退出、信号终止、超时忽略 `SIGTERM`、取消与退出同时发生。

## 4. Security-scoped bookmark 与游戏目录

### 4.1 适用条件与事实

用户通过 `fileImporter`/文件面板选择应用沙盒外的游戏目录时，URL 只在获得相应的 security scope 后可用于该目录。Apple Foundation 头文件说明：

- bookmark 是对文件或目录的持久引用，通常可跨应用重启、系统重启以及资源移动/改名后解析到当前位置。
- App Sandbox 应使用带 security scope 的 bookmark 保存用户授予应用的资源访问意图；解析时要使用 `withSecurityScope`，并启用对应 entitlement。
- `startAccessingSecurityScopedResource()` 返回 `true` 后，必须调用匹配的 `stopAccessingSecurityScopedResource()`；长期不释放会泄漏内核资源，最终影响应用再次向沙盒添加文件系统位置的能力。
- 从 security-scoped URL 提取出的 `path` 字符串不带 security scope。把该字符串保存下来，不能替代保存 bookmark data。
- 创建时 `withSecurityScope` 可提供读写 scope；`securityScopeAllowOnlyReadAccess` 只提供只读 scope。游戏定位、完整性校验和兼容方案写入分别需要按实际操作选择读写能力。
- 解析返回 `isStale == true` 时，应使用返回的 URL 重新创建 bookmark 并替换持久化副本；无法解析通常表示资源不存在或所在卷不能挂载，应回到用户重新选择路径的流程。

来源：[A2] `NSURL.h` 的 “Bookmarks and Security Scope” 与 “Working with Bookmarks” 注释（约第 78-103、744-852 行）。该处同时链接 Apple 的 File System Programming Guide、App Sandbox Design Guide 和 entitlement 文档。

### 4.2 游戏目录写入的限制

- App Sandbox 容器内的 MiPlay 数据、Wine 运行时、下载临时文件可以由应用直接管理；用户选中的容器外游戏目录必须使用用户选择的读写 entitlement 和 security-scoped URL。
- 用户对某个游戏目录的授权只表示对该资源的授权，不等于任意路径写入、root 权限或对 `/etc/hosts` 等系统资源的授权。
- 不能用绝对路径字符串作为长期权限凭据，也不能在 bookmark 已失效时继续尝试写入。
- 由 `Process` 启动 Wine 或游戏时，子进程继承父应用沙盒；实际能否访问用户选择的目录必须用签名后的构建产物验证，不能仅凭主进程曾成功调用 `startAccessing...` 推断。

### 4.2.1 当前工程 capability 基线

以下是 `MiPlay.xcodeproj/project.pbxproj` 中 Debug 和 Release target 的当前设置。它们是构建输入，不等同于已经核验过的最终签名；发布验证必须对签名后的 app 运行 `codesign --display --verbose=4` 和 `codesign -d --entitlements :-`。

| Xcode build setting | 当前值 | 与本任务的约束 | 可验证要求 |
|---|---|---|---|
| `ENABLE_APP_SANDBOX` | `YES` | 预期生成 `com.apple.security.app-sandbox`；沙盒仍是主应用和其 `Process` 子进程的权限边界 | Debug/Release 签名产物均检查最终 entitlements；签名产物中不得以未签名或关闭 sandbox 的配置替代验证 |
| `ENABLE_USER_SELECTED_FILES` | `readonly` | 预期生成 `com.apple.security.files.user-selected.read-only`；当前工程不能把“用户选择了目录”当作游戏安装、补丁或兼容方案写入授权。需要写入时，必须重新核对 Xcode 生成的 `com.apple.security.files.user-selected.read-write` 与 bookmark 的读写 scope。仅有只读能力时只能执行实际允许的读取操作 | 用真实签名产物和临时测试目录分别验证读、创建、替换、删除；写入失败必须映射为权限错误，不得标记安装/方案成功 |
| `ENABLE_OUTGOING_NETWORK_CONNECTIONS` | `YES` | 下载依赖最终签名中的网络客户端能力；该设置不改变 HTTP status、临时文件或取消语义 | 检查最终 entitlements，并用非 2xx、断网、取消和临时文件清理用例验证 |
| `ENABLE_HARDENED_RUNTIME` | `YES` | Hardened Runtime 与 App Sandbox 是独立的签名/权限边界；打开它不能替代用户选择文件授权或 privileged helper 的签名与注册验证 | 对分发签名产物检查 runtime 选项、entitlements、helper/XPC 的签名链和 notarization 结果 |

`NSURL.h` 明确要求使用 security-scoped bookmark 时启用相应 entitlements，并将读写 scope 作为 bookmark 创建选项分别处理。[A2] 因此，本表中的 `readonly` 是当前工程的风险/验证事实，不是将其改成 `read-write` 的实现决策；是否改变构建配置应由上游契约和实现阶段另行决定。

### 4.3 可验证的实现要求

- 持久化每款游戏目录的 bookmark `Data`，同时保存版本/用途元数据；不以裸 path 作为唯一持久化值。
- 恢复流程必须是：解析 bookmark（`withSecurityScope`）→ 处理 `isStale` 并更新 bookmark → `startAccessing...` → 在 scope 生命周期内完成文件操作/启动 → `defer stopAccessing...`。
- 访问失败、解析失败、bookmark stale 且更新失败、目录被删除、用户撤销权限都映射为不可用或需重新定位，不得显示为已就绪。
- 对目录执行写入前验证真实可写性；对完整性校验可按需要使用只读 scope。测试必须覆盖移动目录、重命名目录、删除目录、重启应用、用户拒绝选择和用户撤销权限。
- 兼容方案改变游戏目录文件时，备份、修改、后置验证和回滚都必须在同一有效 scope 内完成；scope 失效时不得把备份成功当作应用成功。

## 5. Privileged Helper、App Sandbox 与 Hardened Runtime

### 5.1 适用条件与事实

MiPlay 的游戏目录访问和系统级兼容方案是两类不同权限问题：前者是用户选择的资源访问，后者可能触及系统保护路径或系统配置。Apple SDK 给出以下约束：

- 沙盒子进程继承主应用沙盒；如果 helper 需要不同 entitlement，不能把任意命令交给 `Process`，应使用 XPC Service/独立 helper 边界。[A1]
- 当前 macOS SDK 的 `SMAppService` 用于控制位于应用 bundle 内的 helper。应用必须代码签名；包含 LaunchDaemon 的应用必须 notarize。
- `SMAppService.daemon(plistName:)` 对应位于 `Contents/Library/LaunchDaemons` 的 daemon。注册后 LaunchDaemon 需要管理员在 System Settings 批准，状态可能为未注册、已启用、需要批准或未找到。
- 更新 LaunchAgent/LaunchDaemon 的 plist 或 executable 后必须重新注册，否则可能无法启动；helper 的签名、安装位置和 bundle 关系必须作为发布产物的一部分验证。
- SDK 中的 `SMJobBless` 注释明确写明其已在 macOS 13.0 起弃用，替代方案是 `SMAppService`。若仍有代码或 ADR 使用 `SMJobBless`，必须由 Architecture Agent 重新核对当前契约，不能把它称为当前 SDK 推荐方案。

来源：[A3] `SMAppService.h`（约第 41-66、111-131、133-172 行）和 `ServiceManagement.h`（约第 191-256 行）。

### 5.2 Hardened Runtime 下的限制

- Hardened Runtime 不会把 App Sandbox 变成可绕过的权限边界；签名、entitlement、helper 注册和 XPC 身份验证仍然有效。
- 不得通过关闭 Sandbox/Hardened Runtime、调用任意 `sudo`、写入宽泛 sudoers 规则、注入未签名代码或把任意 shell 命令暴露给 helper 来解决权限问题。
- Helper 的权限必须和业务操作匹配，接口只接受固定操作和已验证参数；主应用只传递结构化请求，不传任意命令字符串。
- 系统修改的成功条件仍是“真实读回验证 + 原始状态可恢复”，不是 helper 安装成功、XPC 调用返回或备份成功。

### 5.3 可验证的实现要求

- 对需要更高权限的 `modify_hostname`、`block_network` 等操作验证：helper target、签名链、bundle 内位置、注册/批准状态、XPC 连接身份和失败回滚。
- 对主应用、XPC service、privileged daemon 分别检查实际签名和最终 entitlements；Debug 构建成功不能替代 Hardened Runtime 分发验证。
- 模拟用户拒绝管理员批准、helper 未注册、版本不匹配、签名错误、XPC 超时、helper 崩溃和主应用退出。每种情况都必须返回 `Unavailable`/`Failed`，不能报告 `Applied`。
- 对 `/etc/hosts` 等系统文件，验证原文件备份、最小范围变更、写入后读回和回滚后读回；不要把游戏目录的 security scope 用于系统级修改。

## 6. HTTP 下载、响应、临时文件与取消

### 6.1 HTTP 响应语义

`URLSession` 的下载 completion/delegate 同时交付 `location`、`response` 和 `error`。Apple SDK 特别说明：

- 下载任务把响应直接写入临时文件；成功回调中必须读取或把文件移动到应用沙盒容器内的永久位置，回调返回后临时文件会被删除。
- 客户端传输错误通过 `error` 交付；服务器端 HTTP 错误不一定通过 `error` 交付，必须检查 task 的 `response`，并对 `HTTPURLResponse.statusCode` 做业务判断。
- `URLSessionTask.cancel()` 立即将任务标记为取消；随后 delegate 会收到 `NSURLErrorCancelled`，但取消确认前仍可能有 delegate 回调。
- `cancelByProducingResumeData` 可提供稍后恢复所需的 resume data；恢复只适用于 HTTP/HTTPS GET，且服务器支持 byte-range 并返回 ETag 或 Last-Modified 时才有条件成功。
- `timeoutIntervalForRequest` 是等待新增数据的请求级超时，收到数据会重置；`timeoutIntervalForResource` 是整个资源传输的最大时长。两者含义不同，不能用一个字段代替另一个。

来源：[A4] `NSURLSession.h` 的下载任务、任务取消、HTTP response、timeout 和 download delegate 注释（约第 603-649、653-670、787-804、913-942、1315-1340、1853-1876 行）；[A5] `NSURLResponse.h`/`NSHTTPURLResponse` 的 `statusCode`、headers 和 header 查询注释。

### 6.2 可验证的实现要求

- API 元数据请求和归档下载分别定义响应校验：校验 URL scheme、响应类型、status code、Content-Length/expected bytes（若存在）以及 JSON/归档格式；不能只看 `error == nil`。
- 成功回调中立即将 temporary `location` 移动到应用容器或当前有效 security scope 内的目标文件，随后再做大小/hash/归档验证。移动应使用唯一临时文件名，避免把不完整文件覆盖成已安装版本。
- 对 2xx 以外的响应保留 status code 和必要 headers；对 3xx 是否允许跳转、4xx、5xx、429、响应体不是预期格式分别形成可观察错误。GitHub 的具体限速数字不从 Apple 文档推导。
- 配置请求超时和资源超时，并把超时和用户取消区分；长归档不应使用过短的请求超时误判，连接无数据和整体传输过久也不应混成同一错误。
- 取消时选择“可恢复”或“彻底清理”语义：若保存 resume data，必须原子保存并记录对应 URL/ETag 等上下文；若不可恢复或用户要求放弃，则删除临时文件、resume data 和未完成安装目录。
- `URLSession` 的进度 expected bytes 可能未知；未知时使用不确定进度，不能由“最后收到一次回调”或固定字节 fallback 伪造完成。
- 当前工程的 Xcode build settings 已启用 App Sandbox、Hardened Runtime 和 outgoing network connection（`MiPlay.xcodeproj/project.pbxproj:247-250,290-293`）。Release 构建仍需检查最终签名后的 entitlements 和实际网络行为。

## 7. Swift Task cancellation 与外部任务

### 7.1 平台事实与边界

本机 `_Concurrency.swiftinterface` 暴露了 `Task.isCancelled`、`Task.checkCancellation()` 和 `withTaskCancellationHandler(operation:onCancel:)`；它们分别提供取消状态、显式检查和取消时执行处理器的 API。Foundation 又分别暴露 `Process.terminate()`、`URLSessionTask.cancel()`、下载任务的 resume-data 取消接口，以及 security-scoped URL 的 `stopAccessing...`。这些 API 没有声明一个会自动把 Swift `Task` 取消绑定到上述外部资源的共同生命周期，因此取消桥接层必须显式观察取消并调用对应资源 API。[A1][A2][A4][A10]

这意味着，Swift `Task` 的取消状态本身不能证明外部资源已经完成清理。Foundation 的 `NSProgress.h` 也明确规定，可取消工作由调用方负责实际取消，可以设置 cancellation handler 或轮询取消状态。[A11]

因此，`Task.isCancelled` 或 `CancellationError` 只能表示 Swift 任务的取消状态，不能单独证明：

- 子进程已经退出；
- URLSession 连接已经停止并完成 delegate 回调；
- security scope 已释放；
- 临时文件和部分写入已清理；
- 兼容方案已经回滚。

### 7.2 可验证的实现要求

- 在每个可取消的 Domain 操作中定义取消边界：开始前、每个长时间 `await` 后、写入/替换前和后置验证前检查取消。
- 使用 cancellation handler 将 Swift Task 的取消桥接到对应外部资源：Process 发送 terminate 并等待退出；URLSession 调用 cancel 或产生 resume data；pipe reader 停止并关闭；security-scoped URL 调用 stop。
- 所有 continuation/stream 只允许一次完成；取消、网络完成、进程退出同时发生时，结果必须稳定地归类为成功、失败或取消之一，不得重复 resume 或把取消覆盖成成功。
- 下载取消、安装取消和兼容方案取消的清理语义分别记录。对已发生系统变更的方案，取消必须进入回滚/恢复流程；回滚未完成时只能是失败或恢复不完整，不得是 `Applied`。
- 验证用例必须覆盖取消发生在：任务排队、网络连接中、下载写盘中、Process 启动前、Process 运行中、备份后修改前、修改后验证前、回滚中以及完成回调竞态时。

## 8. macOS 无障碍、Button 与键盘操作

### 8.1 Apple 参考中的事实

Apple Liquid Glass 文档说明标准 Button、Slider、Toggle、Picker 等控件会自动采用系统外观；Apple Landmarks 参考工程使用 `.buttonStyle(.glass)`，并对图像元素设置 `.accessibilityLabel(...)`。Apple SDK 的 AppKit `NSButton` 定义了按钮标题、`keyEquivalent`、修饰键和 `performKeyEquivalent`；AppKit accessibility protocol 要求按钮提供 label 和 press action，自定义可访问元素需要暴露 role、label、value 和动作。

AppKit 还暴露了系统的辅助功能显示选项，包括增加对比度、无障碍显示下不只依赖颜色、减少透明度和减少动态效果。自定义 Liquid Glass 控件不能假设透明、颜色或 hover 是唯一的状态表达。

来源：[A6] `References/Apple/apple-liquid-glass-docs/02-Adopting-Liquid-Glass-Guide.md:9-9,51-82` 和 `04-SwiftUI-API-Reference.md` 的控件/按钮 API；[A7] `References/LandmarksBuildingAnAppWithLiquidGlass/Views/Badges/BadgesView.swift:43,71`；[A8] 本机 SDK `NSButton.h` 的 “Handling Keyboard Events” 和 `NSAccessibilityProtocols.h` 的 `NSAccessibilityButton`/`NSAccessibility` 定义。

### 8.2 可验证的实现要求

- 能触发动作的元素使用 SwiftUI `Button` 或 AppKit `NSButton`，不要只给 `Image`/`onTapGesture` 添加点击行为。
- 图标按钮必须有可本地化的 accessibility label；按钮的禁用态、进行中态、进度值和错误结果必须通过 accessibility value/状态可读。
- 自定义控件必须明确 role、label、value 和 action；自定义绘制的 hover/press 外观不能替代可访问的语义。
- 主操作、取消、回滚和确认操作必须存在稳定键盘路径。SwiftUI SDK 提供 `keyboardShortcut`；AppKit 路径可使用 `keyEquivalent`/`performKeyEquivalent`。验证默认按钮、取消键、重复触发保护和焦点移动。
- 运行 VoiceOver、键盘全流程和辅助功能显示设置验证：增加对比度、减少透明度、减少动态效果、区分颜色关闭时，状态与操作仍可理解。

## 9. String Catalog 与运行时本地化

### 9.1 本地 Apple 参考事实

Apple Landmarks 参考工程使用 `.xcstrings` String Catalog，并以 `LocalizedStringResource`、`String(localized:)`、`Text(..., comment:)` 携带稳定文案和翻译上下文；Catalog 包含 `sourceLanguage`、localizations、translation state 和 plural variations。该工程还将本地化资源作为模型展示值在使用处解析，而不是把一个固定语言的展示字符串写入领域数据。

来源：[A9] `References/LandmarksBuildingAnAppWithLiquidGlass/Resources/Localizable.xcstrings:2-2`；`References/LandmarksBuildingAnAppWithLiquidGlass/Views/Landmarks Split View/NavigationOptions.swift:29-33`；`References/LandmarksBuildingAnAppWithLiquidGlass/Model/Landmark.swift:16-18,44-45,69-69`；`References/LandmarksBuildingAnAppWithLiquidGlass/Resources/LandmarkData.xcstrings` 的注释、localizations 和 variations。

### 9.2 可验证的实现要求

- 所有用户可见文本，包括 Process/URLSession/权限/取消/回滚错误、按钮 label、进度 phase、状态 badge 和 accessibility label，都必须进入 String Catalog 或使用 `LocalizedStringResource`/`String(localized:)` 等本地化 API；不要在 Domain 保存已翻译文本。
- 本地化字符串在展示层或状态投影层按当前语言解析；不要缓存中文/英文最终结果后跨语言复用。用户切换语言后，相关 ViewModel/UI 必须重新投影，或明确要求重启应用才能应用，并覆盖此状态。
- 插值、数量、速度、文件大小、剩余时间和 plural 语义使用带格式参数的本地化条目，不通过拼接多个已翻译片段生成句子。
- 每个条目提供给翻译者的 comment/context；对同一 key 的中文与英文都进行完整性检查，避免 UI 混用硬编码字符串和 Catalog 字符串。
- UI 本地化验证至少覆盖中文、英文、长文案、缺失翻译 fallback、数字/单位、复数、错误状态、VoiceOver 读取和键盘快捷键提示。

## 10. 证据索引

| 编号 | 本地 Apple 官方证据 | 覆盖结论 |
|---|---|---|
| A1 | `$(xcrun --show-sdk-path)/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSTask.h`：`NSTask` 总览、pipes、termination、sandbox child process | Process 一次性运行、pipe 端、termination handler、终止状态、子进程沙盒继承 |
| A2 | `$(xcrun --show-sdk-path)/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSURL.h`：Bookmarks and Security Scope、bookmark creation/resolution | security-scoped bookmark、读写 scope、start/stop、path 丢失 scope、stale 处理 |
| A3 | `$(xcrun --show-sdk-path)/System/Library/Frameworks/ServiceManagement.framework/Versions/A/Headers/SMAppService.h` 与 `ServiceManagement.h` | helper 签名、notarization、LaunchDaemon approval、重新注册、SMJobBless 弃用 |
| A4 | `$(xcrun --show-sdk-path)/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSURLSession.h` | HTTP 下载、临时文件、response/error 分离、取消、resume data、timeout |
| A5 | `$(xcrun --show-sdk-path)/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSURLResponse.h` | HTTP status code、headers、header 查询 |
| A6 | `References/Apple/apple-liquid-glass-docs/02-Adopting-Liquid-Glass-Guide.md`、`04-SwiftUI-API-Reference.md` | 标准控件、Button、Liquid Glass 控件 API |
| A7 | `References/LandmarksBuildingAnAppWithLiquidGlass/Views/Badges/BadgesView.swift` | Apple 参考工程的 `.buttonStyle(.glass)` 与 `.accessibilityLabel` 用法 |
| A8 | `$(xcrun --show-sdk-path)/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSButton.h`、`NSAccessibilityProtocols.h`、`NSAccessibility.h` | Button keyboard equivalent、accessibility role/label/value/action、显示辅助功能选项 |
| A9 | `References/LandmarksBuildingAnAppWithLiquidGlass/Resources/Localizable.xcstrings` 及相关 Swift 模型/视图 | String Catalog、LocalizedStringResource、运行时 String(localized:)、comments、plural/localization state |
| A10 | `$(xcrun --show-sdk-path)/usr/lib/swift/_Concurrency.swiftmodule/arm64e-apple-macos.swiftinterface`：`Task.isCancelled`、`Task.checkCancellation()`、`withTaskCancellationHandler(operation:onCancel:)` | Swift Task 的取消状态、显式检查和取消处理器 API；与 Foundation 外部资源取消 API 的边界 |
| A11 | `$(xcrun --show-sdk-path)/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSProgress.h`：`cancellable`、`cancellationHandler`、`cancel` 注释 | 可取消工作必须由调用方执行实际取消和清理 |

## 11. 上游复核项

以下内容属于平台事实与既有契约的冲突检查，按冻结原则应回溯到 Architecture Agent，不在本 Research 输出中修改：

1. `Docs/04-architecture/architecture-adr.md` ADR-015 将 `SMJobBless` 描述为 macOS 26+ 推荐方案；当前 Apple SDK 注释将 `SMJobBless` 标为 macOS 13.0 起弃用并指向 `SMAppService`。
2. 现有工程/文档若只保存游戏 path、只使用短时 `startAccessing...`，或把子进程启动成功当作目录权限成功，需补齐 bookmark 与实际子进程访问验证。
3. 现有下载契约若仅以 `error == nil`、stream `finish()` 或 progress `1.0` 判定成功，需补齐 HTTP response、临时文件移动、取消和后置完整性验证。

这些复核项不构成绕过 Sandbox 或 Hardened Runtime 的建议，也不改变 Product 的 Deferred/Won't 边界。
