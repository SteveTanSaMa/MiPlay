//
//  LaunchCompatibilityEnvironment.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/10/5.
//

import Foundation

// Source: Architecture Design -> Service Contract -> LaunchOrchestrator
// Source: Docs/05-implementation/implementation-notes.md -> Launch Compatibility Environment

/// Launch-time compatibility staging for the fixed managed Wine runtime and
/// the shared prefix. The supported games require these staged facts before
/// the game process starts:
///
/// 1. The game-provided anti-cheat driver file must exist in the shared prefix
///    so the game's driver load attempt resolves against the prefix copy.
/// 2. The DXMT renderer layer must replace the managed runtime's D3D frontend;
///    pristine build files are preserved as `.bak` on the first patch.
/// 3. The game-bundled Vulkan runtime loader must be moved aside while the
///    DXMT renderer is active, and restored after the process exits.
/// 4. Genshin Impact is launched through the staged Steam compatibility stub,
///    which keeps the game off the kernel-driver anti-cheat path that
///    terminates it under Wine.
///
/// Every step is idempotent and best-effort; missing runtime assets are
/// reported to the caller instead of blocking the launch.
enum LaunchCompatibilityEnvironment {
    /// Facts about one staging pass for structured launch diagnostics.
    struct StagingResult: Sendable, Equatable {
        var stagedFileCount: Int
        var missingAssetNames: [String]
        var stagedGameFiles: [StagedGameFile]
        /// 本次 staging 使用的资产来源标识（`bundledRuntimeAssets` / `appSupportRuntimeAssets`）。
        var assetSource: String

        nonisolated init(
            stagedFileCount: Int,
            missingAssetNames: [String],
            stagedGameFiles: [StagedGameFile],
            assetSource: String
        ) {
            self.stagedFileCount = stagedFileCount
            self.missingAssetNames = missingAssetNames
            self.stagedGameFiles = stagedGameFiles
            self.assetSource = assetSource
        }
    }

    /// A game file that is moved aside for the launch and restored after the
    /// game process exits.
    struct StagedGameFile: Sendable, Equatable {
        var originalURL: URL
        var backupURL: URL

        nonisolated init(originalURL: URL, backupURL: URL) {
            self.originalURL = originalURL
            self.backupURL = backupURL
        }
    }

    /// The program the managed Wine binary executes for this game, with the
    /// arguments that follow the Wine binary itself.
    struct LaunchInvocation: Sendable, Equatable {
        var program: String
        var arguments: [String]

        nonisolated init(program: String, arguments: [String]) {
            self.program = program
            self.arguments = arguments
        }
    }

    /// A named `.app` bundle launched through LaunchServices so the game
    /// process chain registers under the game's own name in the Dock and the
    /// Force Quit window. The GameLauncher entry writes the game's output and
    /// exit status to the two files below.
    struct LaunchAppBundle: Sendable, Equatable {
        var bundleURL: URL
        var logURL: URL
        var statusURL: URL
    }

    nonisolated private static let rendererFileNames = ["d3d10core.dll", "d3d11.dll", "dxgi.dll"]

    // MARK: - Asset locations

    /// 运行期**可写**资源根目录（App Support）。图标缓存等生成物写在这里，
    /// 删除 App Support 后会被重新生成。
    nonisolated static func defaultAssetRootURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MiPlay/RuntimeAssets", isDirectory: true)
    }

    /// 随包资源根目录：项目根的 `RuntimeAssets/`（DXMT 渲染层、Steam 兼容存根；
    /// 以文件夹引用加入 app target，保留目录结构复制到
    /// `MiPlay.app/Contents/Resources/RuntimeAssets`）。
    /// 这些资产 MiPlay 目前不会自行下载，必须随包分发，删除 App Support 后仍能从零启动。
    nonisolated static func bundledAssetRootURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("RuntimeAssets", isDirectory: true)
    }

    /// staging 读取的资产来源：按顺序取第一个含 `dxmt/d3d11.dll` 的候选目录
    /// （随包资源优先，App Support 运行期目录作为历史位置/手工替换的回退）。
    nonisolated static func resolvedAssetSourceRootURL(fileManager: FileManager = .default) -> URL {
        let candidates = [bundledAssetRootURL(), defaultAssetRootURL()].compactMap { $0 }
        return resolveAssetSourceRoot(candidates: candidates, fileManager: fileManager)
            ?? defaultAssetRootURL()
    }

    /// 纯函数形式（可测试）：返回第一个含 `dxmt/d3d11.dll` 的候选目录。
    nonisolated static func resolveAssetSourceRoot(candidates: [URL], fileManager: FileManager) -> URL? {
        candidates.first { candidate in
            fileManager.fileExists(
                atPath: candidate.appendingPathComponent("dxmt/d3d11.dll").path
            )
        }
    }

    /// 资产来源标识（写进启动日志，用于确认干净安装走的是随包资源还是运行期资源）。
    nonisolated static func assetSourceIdentifier(for assetRootURL: URL) -> String {
        if let bundled = bundledAssetRootURL(), assetRootURL == bundled {
            return "bundledRuntimeAssets"
        }
        return "appSupportRuntimeAssets"
    }

    /// 官方游戏图标的缓存位置（`GameIconProvider` 下载并转换，bundle 组装时读取）。
    /// 始终落在可写的 App Support 目录，不会写进应用包。
    nonisolated static func iconCacheURL(for gameType: GameType, assetRootURL: URL = defaultAssetRootURL()) -> URL {
        assetRootURL
            .appendingPathComponent("GameIcons", isDirectory: true)
            .appendingPathComponent("\(gameType.rawValue).icns", isDirectory: false)
    }

    // MARK: - Staging

    nonisolated static func stage(
        gameType: GameType,
        gameDirectory: URL,
        prefixURL: URL,
        runtimeRootURL: URL,
        assetRootURL: URL = resolvedAssetSourceRootURL(),
        fileManager: FileManager = .default
    ) -> StagingResult {
        var stagedFileCount = 0
        var missingAssetNames: [String] = []
        var stagedGameFiles: [StagedGameFile] = []

        let system32URL = prefixURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        let syswow64URL = prefixURL.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        let windowsRuntimeLibURL = runtimeRootURL.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
        let unixRuntimeLibURL = runtimeRootURL.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        let dxmtURL = assetRootURL.appendingPathComponent("dxmt", isDirectory: true)

        // 1. Anti-cheat driver file provided by the game installation.
        let driverSourceURL = gameDirectory.appendingPathComponent("HoYoKProtect.sys")
        switch copyOutcome(from: driverSourceURL, to: system32URL.appendingPathComponent("HoYoKProtect.sys"), fileManager: fileManager) {
        case .copied:
            stagedFileCount += 1
        case .unchanged:
            break
        case .sourceMissing:
            missingAssetNames.append("HoYoKProtect.sys")
        }

        // 2. DXMT renderer frontend. The prefix keeps the pristine build copy
        // while the managed runtime receives the DXMT files.
        for name in rendererFileNames {
            let assetURL = dxmtURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: assetURL.path) else {
                missingAssetNames.append(name)
                continue
            }
            let runtimeFileURL = windowsRuntimeLibURL.appendingPathComponent(name)
            let backupURL = URL(fileURLWithPath: runtimeFileURL.path + ".bak")
            if !fileManager.fileExists(atPath: backupURL.path),
               fileManager.fileExists(atPath: runtimeFileURL.path) {
                try? fileManager.copyItem(at: runtimeFileURL, to: backupURL)
            }
            if copyOutcome(from: backupURL, to: system32URL.appendingPathComponent(name), fileManager: fileManager) == .copied {
                stagedFileCount += 1
            }
            if copyOutcome(from: assetURL, to: runtimeFileURL, fileManager: fileManager) == .copied {
                stagedFileCount += 1
            }
        }

        // 3. winemetal bridge (PE side in the runtime and prefix, unix side in
        // the runtime lib directory).
        let winemetalFiles: [(assetName: String, destination: URL, backupOriginal: Bool)] = [
            ("winemetal.dll", windowsRuntimeLibURL.appendingPathComponent("winemetal.dll"), true),
            ("winemetal.dll", system32URL.appendingPathComponent("winemetal.dll"), false),
            ("winemetal.so", unixRuntimeLibURL.appendingPathComponent("winemetal.so"), true),
        ]
        for file in winemetalFiles {
            let assetURL = dxmtURL.appendingPathComponent(file.assetName)
            guard fileManager.fileExists(atPath: assetURL.path) else {
                missingAssetNames.append(file.assetName)
                continue
            }
            if file.backupOriginal {
                let backupURL = URL(fileURLWithPath: file.destination.path + ".bak")
                if !fileManager.fileExists(atPath: backupURL.path),
                   fileManager.fileExists(atPath: file.destination.path) {
                    try? fileManager.copyItem(at: file.destination, to: backupURL)
                }
            }
            if copyOutcome(from: assetURL, to: file.destination, fileManager: fileManager) == .copied {
                stagedFileCount += 1
            }
        }

        // 4. Prefix-level stubs that the verified runtime layout expects next
        // to the renderer frontend.
        for name in ["nvapi64.dll", "nvngx.dll"] {
            let destinationURL = system32URL.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            if copyOutcome(from: windowsRuntimeLibURL.appendingPathComponent(name), to: destinationURL, fileManager: fileManager) == .copied {
                stagedFileCount += 1
            }
        }

        // 5. The game-bundled Vulkan runtime loader conflicts with the DXMT
        // renderer; it is moved aside for the launch and restored on exit.
        if let relativePath = bundledVulkanRelativePath(for: gameType) {
            let vulkanURL = gameDirectory.appendingPathComponent(relativePath)
            let backupURL = URL(fileURLWithPath: vulkanURL.path + ".bak")
            if fileManager.fileExists(atPath: vulkanURL.path) {
                try? fileManager.removeItem(at: backupURL)
                if (try? fileManager.moveItem(at: vulkanURL, to: backupURL)) != nil {
                    stagedGameFiles.append(StagedGameFile(originalURL: vulkanURL, backupURL: backupURL))
                    stagedFileCount += 1
                }
            } else if fileManager.fileExists(atPath: backupURL.path) {
                stagedGameFiles.append(StagedGameFile(originalURL: vulkanURL, backupURL: backupURL))
            }
        }

        // 6. Steam compatibility stub used by Genshin Impact. Only staged when
        // the Steam launch path is selected (see `usesSteamCompatibilityStub`);
        // the current direct-launch path does not read these files.
        if gameType == .genshinImpact, usesSteamCompatibilityStub {
            let protonextrasURL = assetRootURL.appendingPathComponent("protonextras", isDirectory: true)
            let steamFiles: [(assetName: String, destination: URL)] = [
                ("steam64.exe", system32URL.appendingPathComponent("steam.exe")),
                ("steam32.exe", syswow64URL.appendingPathComponent("steam.exe")),
                ("lsteamclient64.dll", system32URL.appendingPathComponent("lsteamclient.dll")),
                ("lsteamclient32.dll", syswow64URL.appendingPathComponent("lsteamclient.dll")),
            ]
            for file in steamFiles {
                let assetURL = protonextrasURL.appendingPathComponent(file.assetName)
                guard fileManager.fileExists(atPath: assetURL.path) else {
                    missingAssetNames.append(file.assetName)
                    continue
                }
                if copyOutcome(from: assetURL, to: file.destination, fileManager: fileManager) == .copied {
                    stagedFileCount += 1
                }
            }
        }

        let uniqueMissingAssetNames = missingAssetNames.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        }
        return StagingResult(
            stagedFileCount: stagedFileCount,
            missingAssetNames: uniqueMissingAssetNames,
            stagedGameFiles: stagedGameFiles,
            assetSource: assetSourceIdentifier(for: assetRootURL)
        )
    }

    /// Best-effort restore of the game files staged aside for the launch.
    nonisolated static func restore(
        _ stagedGameFiles: [StagedGameFile],
        fileManager: FileManager = .default
    ) {
        for file in stagedGameFiles {
            guard !fileManager.fileExists(atPath: file.originalURL.path),
                  fileManager.fileExists(atPath: file.backupURL.path) else { continue }
            try? fileManager.moveItem(at: file.backupURL, to: file.originalURL)
        }
    }

    // MARK: - Named app bundle（Dock / 强制退出中的游戏身份）

    /// Creates or refreshes the per-game `.app` bundle used for the
    /// LaunchServices launch. The bundle carries the game's display name and a
    /// GameLauncher entry (shipped in Resources) that execs the managed Wine
    /// runtime. Every write is idempotent; a missing launcher resource or a
    /// failed write returns nil and the caller falls back to the direct spawn.
    nonisolated static func prepareAppBundle(
        gameType: GameType,
        assetRootURL: URL = defaultAssetRootURL(),
        launcherResourceURL: URL? = Bundle.main.url(forResource: "GameLauncher", withExtension: nil),
        fileManager: FileManager = .default
    ) -> LaunchAppBundle? {
        guard let launcherResourceURL,
              fileManager.fileExists(atPath: launcherResourceURL.path) else { return nil }

        let executableName = gameType.rawValue
        let launchRootURL = assetRootURL.deletingLastPathComponent()
            .appendingPathComponent("LaunchApps", isDirectory: true)
        let bundleURL = launchRootURL.appendingPathComponent("\(executableName).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        do {
            try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

            let executableURL = macOSURL.appendingPathComponent(executableName)
            // 每次启动都会重建 bundle；入口程序没变（大小 + 修改时间一致）时不重复拷贝。
            if !isSameFileIdentity(launcherResourceURL, executableURL, fileManager: fileManager) {
                try? fileManager.removeItem(at: executableURL)
                try fileManager.copyItem(at: launcherResourceURL, to: executableURL)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )

            let infoPlist: [String: Any] = [
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": gameType.displayName,
                "CFBundleDisplayName": gameType.displayName,
                "CFBundleExecutable": executableName,
                "CFBundleIdentifier": "dev.miplay.game.\(executableName)",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSApplicationCategoryType": "public.app-category.games",
            ]
            var plist = infoPlist
            // 官方图标（若有缓存）：由 `GameIconProvider` 从 HoYoPlay API 获取并
            // 转成 .icns，这里只负责把它挂进 bundle。
            let iconName = "AppIcon"
            let bundleIconURL = resourcesURL.appendingPathComponent("\(iconName).icns")
            let cachedIconURL = iconCacheURL(for: gameType, assetRootURL: assetRootURL)
            if fileManager.fileExists(atPath: cachedIconURL.path) {
                plist["CFBundleIconFile"] = iconName
                if !isSameFileIdentity(cachedIconURL, bundleIconURL, fileManager: fileManager) {
                    try? fileManager.removeItem(at: bundleIconURL)
                    try? fileManager.copyItem(at: cachedIconURL, to: bundleIconURL)
                }
            } else {
                plist["CFBundleIconFile"] = nil
            }
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            let plistURL = contentsURL.appendingPathComponent("Info.plist")
            if (try? Data(contentsOf: plistURL)) != plistData {
                try plistData.write(to: plistURL, options: .atomic)
            }

            return LaunchAppBundle(
                bundleURL: bundleURL,
                logURL: resourcesURL.appendingPathComponent("launch.log"),
                statusURL: resourcesURL.appendingPathComponent("launch.status")
            )
        } catch {
            return nil
        }
    }

    // MARK: - Launch resolution

    /// The Wine program and following arguments for the staged environment.
    ///
    /// 原神有两条启动路径（对照 YAAGL 的 `config.steamPatch` 分支），本机实测
    /// （2026-10-07，国服 7.1.0 + CrossOver 11 runtime）：
    /// - **Steam 兼容存根（当前，`usesSteamCompatibilityStub == true`）**：
    ///   `wine C:\windows\system32\steam.exe <exe>`。存根让游戏不再走内核驱动路径，
    ///   实测启动正常（671 行日志、无 `WDFLDR`/`ZwLoadDriver` 报错、游戏保持运行）。
    ///   代价：存根会再拉起游戏进程，强制退出菜单里因此有两个条目
    ///   （"原神" = LaunchServices 启动的 bundle；"wine" = 实际游戏进程，
    ///   `lsappinfo` 显示其可执行文件为 `<runtime>/lib/wine/x86_64-unix/wine`）。
    ///   这是抗作弊绕行带来的固有结果：游戏进程不是 LS 启动的进程。
    /// - **直启 + 云平台参数**（`usesSteamCompatibilityStub == false`，对照 YAAGL
    ///   `clients/mhy/hk4e/program-launch-game.ts` 的 `config.bat`）：`-platform_type
    ///   CLOUD_THIRD_PARTY_PC -is_cloud 1`。实测 7.1.0 国服下**失败**：
    ///   `err:module:import_dll Library WDFLDR.SYS ... not found` →
    ///   `ZwLoadDriver failed c0000142` → `initDriver Failed: Error [4,1114,0]`，
    ///   退出码 5。Wine 无法提供 WDFLDR（WineHQ bug 49193），YAAGL 同样如此
    ///   （yaagl issue #763）。保留代码以便上游修复后切回；切回后游戏进程就是
    ///   LS 启动的进程，强制退出菜单只剩一个「原神」条目。
    ///
    /// 其它游戏直接启动可执行文件。
    nonisolated static func launchInvocation(
        gameType: GameType,
        executablePath: String,
        prefixURL: URL,
        fileManager: FileManager = .default
    ) -> LaunchInvocation {
        let steamStubURL = prefixURL.appendingPathComponent("drive_c/windows/system32/steam.exe")
        if gameType == .genshinImpact,
           usesSteamCompatibilityStub,
           fileManager.fileExists(atPath: steamStubURL.path) {
            return LaunchInvocation(
                program: "C:\\windows\\system32\\steam.exe",
                arguments: [windowsPath(for: executablePath)]
            )
        }
        return LaunchInvocation(
            program: executablePath,
            arguments: cloudLaunchArguments(for: gameType)
        )
    }

    /// 选择原神是否经 Steam 兼容存根启动。
    /// `true`（当前）：存根路径，7.1.0 国服实测可启动；强制退出菜单多一个 "wine" 条目。
    /// `false`：直启 + 云平台参数；当前版本会被 HoYoKProtect 内核驱动加载失败挡住。
    /// 存根资产（`protonextras/`）只在 `true` 时 staging。
    nonisolated static let usesSteamCompatibilityStub = true

    /// 直启需要的附加参数（目前只有原神使用；对照 YAAGL 的 `config.bat`）。
    nonisolated private static func cloudLaunchArguments(for gameType: GameType) -> [String] {
        switch gameType {
        case .genshinImpact: return ["-platform_type", "CLOUD_THIRD_PARTY_PC", "-is_cloud", "1"]
        case .honkaiStarRail, .zenlessZoneZero: return []
        }
    }

    /// Environment facts that belong to the launch compatibility boundary
    /// rather than to a user option.
    nonisolated static func additionalEnvironment(for gameType: GameType) -> [String: String] {
        let videoDecodeRank = "atdec:MAX,avdec_h264:MAX"
        switch gameType {
        case .genshinImpact:
            return [
                "WINEESYNC": "1",
                "GST_PLUGIN_FEATURE_RANK": videoDecodeRank,
            ]
        case .honkaiStarRail, .zenlessZoneZero:
            return [
                "WINEMSYNC": "1",
                "GST_PLUGIN_FEATURE_RANK": videoDecodeRank,
            ]
        }
    }

    // MARK: - Private

    nonisolated private static func bundledVulkanRelativePath(for gameType: GameType) -> String? {
        switch gameType {
        case .genshinImpact: return "YuanShen_Data/Plugins/vulkan-1.dll"
        case .honkaiStarRail: return "StarRail_Data/Plugins/x86_64/vulkan-1.dll"
        case .zenlessZoneZero: return "ZenlessZoneZero_Data/Plugins/x86_64/vulkan-1.dll"
        }
    }

    nonisolated private static func windowsPath(for unixPath: String) -> String {
        "Z:" + unixPath.replacingOccurrences(of: "/", with: "\\")
    }

    /// 一次 staging 拷贝的结果。区分"源缺失"与"目标已是最新"，调用方才能既
    /// 正确统计缺失资产、又跳过没有变化的重复拷贝。
    ///
    /// `nonisolated`：本类型只在 `nonisolated` 的 static 辅助函数里使用，
    /// 必须连同 `Equatable` 一致性一起脱离 MainActor 隔离，否则 Swift 6 语言模式下
    /// 会报 "main actor-isolated conformance ... cannot be used in nonisolated context"。
    nonisolated private enum CopyOutcome: Equatable {
        case copied
        case unchanged
        case sourceMissing
    }

    /// 覆盖拷贝，但目标与源内容一致（大小 + 修改时间相同，`copyItem` 会保留
    /// 源修改时间）时跳过。DXMT/存根资产在每次启动都会被 staging 一次，跳过
    /// 未变化的拷贝可省下整段磁盘写入。
    nonisolated private static func copyOutcome(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager) -> CopyOutcome {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return .sourceMissing }
        if isSameFileIdentity(sourceURL, destinationURL, fileManager: fileManager) { return .unchanged }
        try? fileManager.removeItem(at: destinationURL)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return .copied
        } catch {
            return .sourceMissing
        }
    }

    /// 源与目标的（大小 + 修改时间）一致即视为同一版本文件。
    nonisolated private static func isSameFileIdentity(_ firstURL: URL, _ secondURL: URL, fileManager: FileManager) -> Bool {
        guard let first = try? fileManager.attributesOfItem(atPath: firstURL.path),
              let second = try? fileManager.attributesOfItem(atPath: secondURL.path),
              let firstSize = first[.size] as? UInt64,
              let secondSize = second[.size] as? UInt64,
              let firstDate = first[.modificationDate] as? Date,
              let secondDate = second[.modificationDate] as? Date else { return false }
        return firstSize == secondSize && abs(firstDate.timeIntervalSince(secondDate)) < 1
    }
}
