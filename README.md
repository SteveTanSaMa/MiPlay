# MiPlay

面向 Apple Silicon Mac 的米哈游游戏启动器，使用 Wine 与 DXMT 运行 Windows 游戏。当前配置面向原神、崩坏：星穹铁道、绝区零国服；不支持 Intel Mac。应用部署目标为 macOS 26.0。

## 当前功能

- 游戏定位、托管 Wine 环境、启动与退出状态恢复。
- Sophon 下载、版本更新、预下载、断点续传和带进度的完整性检查。
- 正式更新按文件分批安装，保留中断进度并释放不再需要的旧源，降低临时磁盘占用。
- 游戏新闻和背景素材；优先选择含视频的背景组，无视频时回退第一组。历史背景缓存默认关闭，可按游戏单独开启。
- 按游戏管理运行选项，以及统一的主界面和设置页。

原神、绝区零已有实机运行反馈；这不代表所有功能和游戏均已完成验收。分批更新的真实峰值空间和下次正式更新仍需实测，详见 [Sophon 分批更新与中断续装](Docs/05-implementation/sophon-incremental-update.md)。

## 插帧状态：初步完成，仍在调试

MiPlay 已接入实验性 LSFG Wine＋DXMT 插帧，包含按游戏设置、资源导入、启动前 GPU 预检及运行诊断。默认关闭，需要用户自行导入所持有的 `lsfg-vk.dll`；本仓库不包含该 DLL 或商业着色器。

目前仍在定位真实游戏的帧率瓶颈，4× 快速转动视角时的画面畸变尚未解决。倍率表示上限，不保证实际帧率按倍数增长。直接 Metal 计算后端尚未接入正式运行链路。

仓库随附当前验证过的运行组件快照及其哈希；组件清单记录了本地修改状态，独立 LSFG 仓库的对应改动尚未发布，不能仅凭其远端提交重建相同快照。详见 [LSFG 接入与验证记录](Tools/LSFG/README.md)。DXMT 和 LSFG 的底层开发分别保留在独立仓库。

## 构建与测试

使用 Xcode 打开 `MiPlay.xcodeproj`，选择 MiPlay scheme 和自己的 Signing Team。正常构建直接使用 `RuntimeAssets` 中的组件，不要求检出 DXMT 或 LSFG 的兄弟仓库。

```sh
xcodebuild -project MiPlay.xcodeproj -scheme MiPlay \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Local build

xcodebuild -project MiPlay.xcodeproj -scheme MiPlay \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Local \
  -parallel-testing-enabled NO test
```

也可用 `./script/build_and_run.sh` 构建并启动应用。普通测试使用隔离数据，真实游戏和 GPU 验收需另行运行。

新增游戏的内部扩展方式见 [支持新游戏](Docs/05-implementation/adding-supported-game.md)。参考项目及第三方组件各自的许可证保留在对应目录。
