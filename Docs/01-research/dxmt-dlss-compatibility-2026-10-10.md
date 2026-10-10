# DXMT DLSS 兼容接入

## 研究结论

DXMT 的 NGX 实现把 D3D11 游戏的 DLSS Super Resolution 调用转换为 MetalFX 时间缩放。游戏必须原生调用该接口，并提供颜色、深度、运动矢量及抖动信息；启动器无法凭开关给不支持的游戏添加这些输入。质量/平衡/性能等档位由游戏传入，MiPlay 不改写游戏图形配置。

本次范围是 Super Resolution / 时间缩放，不包含 DLSS 帧生成、光线重建或强制启用 D3D12。也不能将其当成之前原神 30 FPS 性能问题的已确认修复。

依据：[DXMT Vendor Extensions](https://github.com/3Shain/dxmt/wiki/Vendor-Extensions)，以及本地 `654f547` 的 `src/nvngx/nvngx.cpp`、`src/dxgi/dxgi.cpp`。核对已部署版本对应源码，不只查看 fork 最新 HEAD。

### 部署要求

- Apple Silicon；实际 MetalFX 时间缩放能力由 DXMT 创建功能时检查。
- `nvapi64.dll` 与 `nvngx.dll` 在 Wine 的 `lib/wine/x86_64-windows` 和 Prefix 的 `drive_c/windows/system32` 两处部署。
- 每次启动显式设置 `DXMT_ENABLE_NVEXT`。DXMT 自行设置/删除 NVIDIA 扩展发现所需的注册表值，无需 MiPlay 再手工写一套注册表。
- 某些游戏还存在 NGX 签名校验问题。这属于游戏与 Wine 兼容性的额外条件，开关与 DLL 部署成功不能证明游戏必然可用。本次不复制游戏内 DLL、不执行签名绕过。

## MiPlay 实现

通用设置新增「DLSS 兼容（实验性）」开关，默认关闭，非原生 arm64 构建禁用。开启仅表示准备扩展接口；游戏内仍需自行选择 DLSS。游戏不显示该选项时，不自动切换后端或补丁。

`GameEnvironmentSettings` 新增持久化字段 `dlssCompatibility`，对旧版本已存在的设置对象也可兼容解码；缺失字段回落 false。开关下次游戏启动生效。

启动时，先按当前设置进行按需 staging，确认所需资产存在且复制没有报告失败，再注入 `DXMT_ENABLE_NVEXT=1`；关闭、宿主不支持或 staging 失败时显式注入 `0`，防止继承环境意外开启。新增 `launch.nvext_prepared` / `launch.nvext_unavailable` 日志。这些事件表示部署准备结果，**不是游戏已成功使用 DLSS 的证明**。

NVAPI/NGX 采用项目当前 `654f547` 渲染资源对应的本地 YAAGL dxmt 分发目录：五件套与现有 MiPlay 资源逐文件哈希相同，两项 vendor DLL 在 YAAGL 与 YAAGL ZZZ 资产目录中一致。它们与托管 Wine 内置的 vendor DLL 不同，因此启用时需同时更新运行时和 Prefix，避免仅复制一次留下旧版本。资源来源和全部七个文件的哈希写在 `RuntimeAssets/dxmt/ASSET_MANIFEST.json`；此清单用于追溯，本次未接入通用的运行时哈希校验系统。

首次覆盖保留 Wine vendor DLL 的 `.bak`。扩展开关关闭后 DLL 保留在目录内，启动环境为 0，DXMT 关闭扩展并清理其发现值；不在退出时替换 DLL。本次研发没有写入用户已安装运行时、Prefix 或游戏目录，仅新增项目分发资产。没有更新当前 DXMT 五件套或 Wine 版本。

## 验证与使用

自动测试覆盖：旧设置对象迁移、开关往返保存、未部署时环境为 0、禁用状态不替换现有 vendor 文件、启用状态替换两个位置的旧文件并保留原件、缺失 NGX 资产时不报告就绪。测试仅使用临时目录中的模拟资产；它不能证明真实 NGX ABI 或游戏支持情况。

验证结果：Debug 构建成功；6 个目标测试通过（2 个新增用例、设置用例、3 个既有启动兼容用例），0 失败。构建产物中的全部七个 DLL/桥接文件逐项匹配资源哈希清单。结果位于 `build/DLSSCompatibility/Logs/Test/Test-MiPlay-2026.10.10_03-15-47-+0800.xcresult`。

实机验证应选择游戏内已提供 DLSS 且以 DirectX 11 运行的游戏：

1. 在 MiPlay 通用设置开启兼容，再重新启动游戏。
2. 确认启动日志有 `launch.nvext_prepared`；若 unavailable，先排查宿主与随包资源。
3. 游戏内选择 DLSS「质量」，在固定场景观察画面与 GPU 时间；再选择「性能」比较。确认主渲染模块和 NGX 实际加载，必要时收集 `nvngx.log` / `nvapi.log` / `dxgi.log`。
4. 若无游戏内 DLSS 选项、加载失败或画面异常，关闭兼容并重启，保留日志；不要用交换链空间放大替代并称为 DLSS。

这些测试尚未在游戏内执行。此前稳定性问题和性能调查保持独立，实际收益须通过同场景对照确认。
