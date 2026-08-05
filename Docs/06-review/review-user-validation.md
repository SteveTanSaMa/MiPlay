# User Validation Checklist

> Review 后暂停。以下项目不能由 build、XCTest fixture、静态 AX modifier 或外部参考项目结果替代。

## MiPlay Runtime and Permissions

- [ ] 使用已签名、启用 App Sandbox 的 MiPlay App；导出最终 entitlements，确认 Team ID、Sandbox、outgoing network 和 user-selected file 权限。
- [ ] 通过 `NSOpenPanel` 选择真实游戏目录，验证 bookmark 创建、重启解析、stale refresh、写回失败、撤销权限和重新授权。
- [ ] 证明完整性、版本检查、预启动和启动在授权 scope 外不可执行；失败时不使用 `lastKnownPath`。
- [ ] 使用真实 managed Wine binary；验证 `wine --version`、`wineboot -u`、`WINEPREFIX`、`drive_c`、DLL override 和真实游戏参数。
- [ ] 验证 ProcessManager 启动、确认 running、正常退出、异常退出、timeout、用户取消和真实清理；检查 AppData 不留下持久 Running。

## GitHub API and Asset

- [ ] 官方 GitHub API 发现成功、空目录、tag 不存在、API 403、429、5xx、超时和无效 JSON 均形成正确用户状态。
- [ ] 对同一 Release asset 单独验证 302、最终 host allowlist、asset 403、404、429、5xx；记录当前 P1-REV-005 修复后的 typed error category。
- [ ] 验证下载进度、取消传播、URLSession 结束、staging 清理、文件大小不匹配、tar traversal、symlink escape、解压失败和 cleanup failure。
- [ ] 验证不请求任意 URL、不请求 allowlist 外镜像、不自动切换未选 source；失败时既有可用 managed Wine 不被清除。
- [ ] 检查生成的 archive、安装目录、installed record 和重读结果；HTTP 200、文件存在或进度完成都不能单独作为安装成功。

## Settings, Background, and UI

- [ ] 验证 Settings `notSelected`、`notDownloaded`、`prefixNotReady`、`error` 和 ready 的投影不互相压平；刷新/取消/失败后 task 状态与 UI 一致。
- [ ] 验证每个 Game ID 的 settings 独立持久化；切换多个背景组后成功写回，失败回滚到上一个 group。
- [ ] 在主窗口与 Settings 窗口分别验证固定尺寸、Settings 相对主窗口居中、多屏边界、hover/focus、主按钮命中区域和视觉对比度。
- [ ] 使用键盘完成游戏选择、背景组、主按钮、Settings、取消、重试和回滚；确认不依赖 hover。
- [ ] 使用 AX Inspector 检查游戏卡片、主按钮、启动进度、错误恢复、取消/重试和 Settings sidebar/detail 的 role/name/value/hint。
- [ ] 开启 VoiceOver，记录真实导航顺序、激活结果、动态 progress/failure/cancel/retry/rollback announcement；保存文字或音频记录。完成后关闭 VoiceOver。

## Logs and Evidence Package

- [ ] 导出 MiPlay 日志，确认 flush barrier、JSONL 可解析、轮转文件合并、sequence 连续、敏感 path/URL/token/bookmark 不出现。
- [ ] 对 API、asset、cancel、cleanup failure、persistence failure、recovery retry、launch exit 和 UI export 各保留一份 event/result 记录。
- [ ] 保存 signed build、entitlements、真实网络记录、最终文件 size/hash（若来源提供）、AppData 前后快照、用户操作步骤和 UI/VoiceOver 记录。
- [ ] 不把 `/Users/stevetan/SteveTan/Document/Xcode/AnimeGameWineReleaseFetcher` 的测试或日志放入 MiPlay 证据包。

## Release Gate

- [ ] Implementation 关闭 P1-REV-005 并补 asset HTTP status XCTest。
- [ ] UI + Apple Review 关闭 P1-08 的真实 Apple 证据阻塞。
- [ ] QA/Implementation 同步 `Docs/08-qa` 的测试计数和 Pending/Pass 口径，关闭 P2-05/DOC-REV-001。
- [ ] Performance、QA、Release 在上述证据完成前保持暂停。

