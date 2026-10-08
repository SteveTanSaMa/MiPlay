# 调研：DXMT 的 MetalFX 空间缩放接口（2026-10-05）

> 背景：用户提出"给项目加上 MetalFX 缩放，在尽量不降低画质的前提下减少渲染像素、提高帧率"，怀疑 DXMT 已留接口。本调研基于 **DXMT 源码浅克隆（`References/dxmt`，master）** 与官方文档，未修改任何代码。

> **状态更新（2026-10-07）：该功能已搁置。** 用户决定暂时不暴露此功能：设置界面不再展示开关，`PerformanceOption.isSuspended = true` 保证它不参与启动（代码、参数校验、环境模板全部保留）。恢复条件与落地形态见本文末"后续要落地的形态"一节；实施记录见 `Docs/05-implementation/implementation-notes.md` → "2026-10-07 启动链路修复（对照最新 YAAGL）+ MetalFX 搁置"。

## 结论速览

DXMT **已内置**该能力，无需改 DXMT 代码，MiPlay 只需在启动环境里加开关与系数：

| 项目 | 值 |
|---|---|
| 开关 | 环境变量 `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`（默认关闭，显式开启） |
| 系数 | 配置项 `d3d11.metalSpatialUpscaleFactor`，取值 **1.0–2.0**，默认 2.0 |
| 传递方式 | `DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=1.5;"`（分号分隔）或 `DXMT_CONFIG_FILE=<path>` |
| 本机支持 | ✅ 本机（Apple M1 Pro）`MTLFXSpatialScalerDescriptor.supportsDevice == true`（temporal 亦为 true） |
| 我们的构建 | ✅ 当前 `RuntimeAssets/dxmt`（v0.80）已含 `DXMT_METALFX_SPATIAL_SWAPCHAIN` 与 `d3d11.metalSpatialUpscaleFactor` 字符串 |

## 实现机制（源码定位）

- `src/d3d11/d3d11_swapchain.cpp`
  - 按设备能力在运行时选择模板实例：`if (pDevice->GetMTLDevice().supportsFXSpatialScaler()) new MTLD3D11SwapChain<true>`，否则 `<false>`（不支持时自动降级，无副作用）。
  - `scale_factor = max(config("d3d11.metalSpatialUpscaleFactor", 2), 1.0)`；`ResizeBuffers` 时创建 `upscaled_backbuffer = 源尺寸 × scale_factor`，并用 `SpatialScaler`（MetalFX）在 Present 前放大；绘制尺寸 = `desc_.Width/Height × scale_factor`。
- `src/winemetal/unix/winemetal_unix.c`：`_MTLDevice_newSpatialScaler` 构造 `MTLFXSpatialScalerDescriptor`（`input/outputWidth/Height`、色彩格式），`supportsDevice:` 做能力检测；另有 **temporal scaler**（含深度纹理）桥接，供 NVNGX/DLSS 路径（`src/nvngx/nvngx.cpp`）使用。
- `docs/CUSTOMIZATION.md` 与仓库根 `dxmt.conf`：官方文档化的开关与取值范围（"To get 1440p from 1080p you need a factor of 1.33"）。

## 关键语义（决定怎么用）

- **它不改变游戏自身的渲染分辨率**：游戏仍按其交换链尺寸渲染，DXMT 在 Present 时把画面放大 `factor` 倍。因此：
  - 想"减少渲染像素"必须**把游戏内分辨率/渲染精度调低**，再用系数把最终输出补到屏幕原生分辨率；
   - 系数应满足：`游戏输出画布 × factor ≈ 屏幕设备像素`。例：游戏 1280×720 + factor 2 → 2560×1440；游戏 1920×1080 + factor 1.33 → 2560×1440。
   - 若游戏已按原生（背板）分辨率渲染再把 factor 设为 2，会放大到 2× 原生（浪费显存/带宽、无收益）。
- **⚠️ 2026-10-06 实测校正（见下文"实测校正"节）：系数不会改变渲染像素数量，也不会改变窗口在屏幕上的大小。要"低分辨率渲染 + 放大到全屏原生"，必须让 Win32 交换链小于屏幕设备像素，即 `RetinaMode=n`。**
- 画质：MetalFX 空间放大显著优于双线性/合成器缩放；但 **UI 文本同样会被放大**，细字会略微变软（空间型无时域信息，不能像 temporal 那样恢复细节）。
- 附加发现：`d3d11.preferredMaxFrameRate` 为 Metal 侧的帧率节流（须为刷新率因数），与后续"解锁/限制帧率"功能相关。

## 集成方案（供后续实施，当前不改代码）

> **2026-10-06 更新：已按方案 B 落地，见 `Docs/05-implementation/implementation-notes.md` → "2026-10-06 实施（用户选定方案 B）"。关键补充：`LaunchOrchestrator` 当时只应用 `environmentVariables`、未应用 `valueEnvironmentVariables`，方案 B 的系数实际下发不到 DXMT（已修复）。**

1. 走既有**性能选项**机制（`PerformanceOptionManager`，现已支持每游戏开关与启动环境变量注入）：
   - 方案 A（零核心改动）：提供固定档位选项——`MetalFX 空间缩放 2×`（env：开关 + `metalSpatialUpscaleFactor=2.0`）、`1.5×`、`1.33×`；默认关闭。
   - 方案 B（更灵活）：一个选项 + 自定义系数，启动时把系数拼接进 `DXMT_CONFIG`（需要启动环境装配支持"按选项值生成环境变量"，小改动）。
2. 默认值建议 **关闭**：需要与游戏内分辨率配合，盲开可能造成"放大超过屏幕"的浪费。
3. 验证计划（等 runtime 就绪后）：
   - 游戏内设为 1280×720 左右 + `DXMT_METALFX_SPATIAL_SWAPCHAIN=1` + factor 2 → 用 Metal HUD 对比开/关帧率（预期 GPU 瓶颈场景提升明显），并肉眼检查 UI 文本锐度与整体画质；
   - 检查 DXMT 日志中的 scaler 创建与无报错；确认不支持 MetalFX 的机器自动降级（模板 <false>）无异常。
4. 相关 GitHub 讨论：#71（DLSS 帧生成/光线重建 → Metal 4 特性，维护者表示会做；与本接口不同，本接口=空间放大，已可用）；#91（MetalFX 编译条件修复）。

## 实测校正（2026-10-06，用户实测 + 源码复核）

**用户观察**：显示器 3000×1500、游戏窗口分辨率 2000×1000、系数 1.5 时，Metal HUD 显示 3000×1500，但**窗口大小不变**；再切全屏（Cmd+Enter）后 HUD 显示 4500×2250。

**源码依据**（`References/dxmt`）：
- `d3d11_swapchain.cpp:519-534`：`upscaled_backbuffer_ = 交换链尺寸 × scale_factor`，MetalFX 输入 = 交换链、输出 = 交换链 × factor。
- `dxmt_presenter.cpp:21`：`layer_props_.contents_scale *= scale_factor`；`winemetal_unix.c:_MetalLayer_setProps` 设置 `layer.drawableSize = 指针尺寸`、`layer.contentsScale`。
- 图层在屏幕上的显示尺寸 = **窗口客户区（frame）**，与 drawable 无关；drawable 只决定画布分辨率。

**结论（修正前文表述）**：
1. **系数只作用于 Present 阶段的输出画布**：`drawable = 游戏交换链尺寸 × factor`，**不改变游戏渲染的像素数量，也不改变窗口在屏幕上的大小**。
2. 系数与屏幕的关系应为：`窗口 Win32 尺寸 × factor = 窗口在屏幕上的设备像素`。
   - **`RetinaMode=y`（本项目当前设置，`WineRuntimeProvider.applyManagedDisplaySettings` 每次启动都写）**：Win32 尺寸 = 屏幕设备像素 → 正确的系数是 **1.0（即关闭）**；任何 >1 都是**超采样**（画布大于屏幕、合成器再缩回），画质微增、性能下降。
   - **`RetinaMode=n`**：Win32 尺寸 = 屏幕"点"尺寸（Retina 下 = 设备像素 ÷ 2）→ 系数 **2.0** 时 drawable = 屏幕设备像素，**1:1 无二次缩放**，且游戏只渲染 1/4 像素 ← 这才是"低分辨率渲染 + MetalFX 放大到全屏原生"的正确组合。
3. 系数 < 2.0（RetinaMode=n 时）：**渲染像素数量不变**（仍由交换链决定），只是输出画布变小、由合成器再做一次双线性放大（略软，且多一次缩放）→ **没有理由用 1.5，直接用 2.0**。
4. 用户例子的对应解释：RetinaMode=y 下 2000×1000 的窗口 → drawable 3000×1500（HUD 显示的是 drawable，非窗口/游戏分辨率）；切全屏后 Win32 变为 3000×1500 → drawable 4500×2250（超采样）。

**因此，后续要落地的形态**：每游戏一个"MetalFX 缩放"模式开关，开启时同时 (a) 把该次启动的 `RetinaMode` 写为 `n`（`applyManagedDisplaySettings` 已是每次启动写入，改为按选项取值即可），(b) 下发 `DXMT_METALFX_SPATIAL_SWAPCHAIN=1` 与系数 2.0（或后续自动取 `NSScreen.backingScaleFactor`）。默认关闭（保持原生最高画质）。

## 复现与参考

- 源码：`References/dxmt`（`git clone --depth 1 https://github.com/3Shain/dxmt.git`）
- 本机支持探针：`MTLFXSpatialScalerDescriptor.supportsDevice(MTLCreateSystemDefaultDevice()!)`
- 官方文档：`docs/CUSTOMIZATION.md` → "MetalFX Spatial Upscaling for Swapchain"
