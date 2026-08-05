# GameInformationView 用户体验设计

> **文档状态**：已弃用（Deprecated）
> **弃用原因**：UX-32 — config 版本号不可靠，移除 GameInformationView 全功能
> **替代方案**：主窗口不再展示游戏 Logo、状态文字、版本号、上次启动时间。兼容方案与性能选项由 game-detail 详情窗口管理，其他应用配置由 Settings Scene 管理。
> **保留记录原因**：若未来恢复该视图功能，此文档可作为设计参考复用。
> **原生效时间**：2026-07-28
> **弃用时间**：2026-07-29

## 当前结论

GameInformationView 已从主窗口信息架构中移除，不再承担任何用户流程或状态反馈职责。主窗口中心不显示游戏 Logo、游戏名称、状态文字、版本号、上次启动时间、失败原因或进度信息。后续文档不得将该区域描述为仍然存在。

当前主窗口只保留以下用户入口：

- Game Rail：切换三款游戏，并显示状态圆点。
- Game Rail 齿轮或 `⌘,`：打开 Settings Scene。
- PrimaryActionButton：根据当前游戏状态执行定位、启动、安装、更新，或在 LaunchFailed 状态打开 game-detail 详情窗口。

兼容方案与性能选项位于 game-detail 详情窗口；该视图不新增替代的信息展示区。
