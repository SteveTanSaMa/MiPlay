# Apple Code Review Dimension

> 日期：2026-08-04；本维度检查 Apple 规范相关代码和证据边界，不把静态代码、adhoc/unsigned build 或 contract XCTest 当作 Apple runtime Pass。

## Code Review Result

- App Sandbox、Hardened Runtime、outgoing network 和 read-only user-selected files 在 `MiPlay.xcodeproj/project.pbxproj:304-383` 有配置；没有 Helper/XPC target，也没有额外的系统资源权限。
- GameLocation 在消费者 operation 期间持有 security-scoped lease，stale bookmark 写回成功后才发布结果。该代码契约通过，但真实签名 Sandbox 和真实 NSOpenPanel bookmark 仍未验证。
- UI 使用标准 Button 和 SwiftUI accessibility label/value/hint；装饰背景 `.accessibilityHidden(true)`；任务 progress、failure recovery、background group 和 Settings 有静态语义投影。
- 真实 Apple gate 仍未关闭：没有 signed App、AX Inspector dump、VoiceOver 全局导航/音频 transcript、完整键盘路径或可定位真实 game task fixture。P1-08 保持 External Blocked。
- P1-02/P1-07 是代码边界问题，当前已有 managed/internal 约束；不能再交由 Apple 手工测试替代，也不能因 external project 能下载而关闭。

## Accessibility Scope

静态检查覆盖游戏卡片、主按钮、设置入口、背景组、启动 progress、恢复操作、兼容方案任务和 Settings 控件的 label/value/hint/contain/combine 语义。它不能证明：

1. VoiceOver 实际朗读顺序和动态 announcement。
2. 键盘 Tab/方向键/Return/Space/`⌘,` 的完整焦点路径。
3. progress -> failure -> cancel -> retry/rollback 的真实状态更新没有重复、丢失或遮挡。
4. Liquid Glass、hover、focus、对比度和 reduce motion 在真实窗口/多屏环境下满足视觉规范。

## Apple Evidence Gate

P1-08 的责任链为 UI + Apple Review/User Validation。必须保存签名 artifact、AX Inspector/VoiceOver/keyboard 记录和动态任务步骤；现有 62/62 XCTest 只关闭语义 contract，不关闭 Apple runtime gate。

