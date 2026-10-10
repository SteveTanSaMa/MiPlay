// Source: 用户反馈（2026-10-06）— 启动耗时 / 强制退出菜单命名 / 随机退出 / 图标
//
// 覆盖本轮修复中最容易回归的纯逻辑：
// - 搁置的性能选项（MetalFX 空间缩放）不再进入启动环境；
// - RetinaMode 注册表探测（跳过重复 `wine reg add`）；
// - 传给游戏的环境不再包含 Xcode 注入的 Metal 调试变量；
// - 原神直启 + 云平台参数（强制退出菜单只出现游戏自身）；
// - staging 跳过未变化的重复拷贝；
// - 官方图标的区服判定。
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testYAAGLGameLaunchProfilesKeepGameSpecificSynchronization() {
        for game in [GameType.genshinImpact, .zenlessZoneZero] {
            XCTAssertTrue(LaunchCompatibilityEnvironment.usesSteamCompatibilityStub(for: game))
            XCTAssertEqual(LaunchCompatibilityEnvironment.additionalEnvironment(for: game)["WINE_ENABLE_TIMEOUT_FIX"], "1")
        }
        XCTAssertFalse(LaunchCompatibilityEnvironment.usesSteamCompatibilityStub(for: .honkaiStarRail))
        XCTAssertEqual(LaunchCompatibilityEnvironment.additionalEnvironment(for: .genshinImpact)["WINEMSYNC"], "0")
        XCTAssertEqual(LaunchCompatibilityEnvironment.additionalEnvironment(for: .zenlessZoneZero)["WINEESYNC"], "0")
        XCTAssertEqual(LaunchCompatibilityEnvironment.additionalEnvironment(for: .honkaiStarRail)["WINE_ENABLE_TIMEOUT_FIX"], "0")
    }

    func testJadeiteStagingRequiresAllPayloadsAndPreservesGameFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets")
        let prefix = root.appendingPathComponent("prefix")
        let game = root.appendingPathComponent("Star Rail")
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("jadeite"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("game".utf8).write(to: game.appendingPathComponent("StarRail.exe"))
        for name in LaunchCompatibilityEnvironment.jadeiteFileNames {
            try Data(name.utf8).write(to: assets.appendingPathComponent("jadeite/\(name)"))
        }
        let stage = LaunchCompatibilityEnvironment.stage(gameType: .honkaiStarRail, gameDirectory: game, prefixURL: prefix, runtimeRootURL: root.appendingPathComponent("wine"), assetRootURL: assets)
        XCTAssertTrue(LaunchCompatibilityEnvironment.missingRequiredLaunchAssets(for: .honkaiStarRail, staging: stage).isEmpty)
        for name in LaunchCompatibilityEnvironment.jadeiteFileNames {
            XCTAssertEqual(try Data(contentsOf: LaunchCompatibilityEnvironment.jadeiteDirectory(prefixURL: prefix).appendingPathComponent(name)), Data(name.utf8))
        }
        XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent("StarRail.exe")), Data("game".utf8))
        try FileManager.default.removeItem(at: assets.appendingPathComponent("jadeite/game_payload.dll"))
        let incomplete = LaunchCompatibilityEnvironment.stage(gameType: .honkaiStarRail, gameDirectory: game, prefixURL: prefix, runtimeRootURL: root.appendingPathComponent("wine"), assetRootURL: assets)
        XCTAssertEqual(LaunchCompatibilityEnvironment.missingRequiredLaunchAssets(for: .honkaiStarRail, staging: incomplete), ["game_payload.dll"])
    }

    func testWebviewRepairSelectsOnlyKnownRegistryValues() {
        let output = """
        HKEY_CURRENT_USER\\Software\\miHoYo\\绝区零
            OtherValue REG_SZ keep
            MIHOYOSDK_WEBVIEW_RENDER_METHOD_h1573598267 REG_BINARY 49535200
            HOYO_WEBVIEW_RENDER_METHOD_ABTEST_1_test REG_BINARY 1234
        """
        XCTAssertEqual(GameLaunchPreparation.webviewValues(in: output), ["MIHOYOSDK_WEBVIEW_RENDER_METHOD_h1573598267", "HOYO_WEBVIEW_RENDER_METHOD_ABTEST_1_test"])
        XCTAssertTrue(GameLaunchPreparation.webviewRegistryKeys(for: .genshinImpact).isEmpty)
        XCTAssertEqual(GameLaunchPreparation.webviewRegistryKeys(for: .honkaiStarRail).count, 2)
    }

    func testStarRailNetworkWindowRestoresOnlyOwnedLinesWithoutSystemHosts() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hosts = root.appendingPathComponent("hosts fixture's file")
        let original = "127.0.0.1 localhost\n0.0.0.0 globaldp-prod-cn01.bhsr.com # someone else\n"
        try original.write(to: hosts, atomically: true, encoding: .utf8)
        let script = GameLaunchPreparation.networkWindowScript(hostsPath: hosts.path, token: "TEST", duration: 0.3)
        let manager = ProcessManager()
        _ = try await manager.launchAndWait(executablePath: "/bin/sh", arguments: ["-c", script], timeout: 5)
        XCTAssertTrue(try String(contentsOf: hosts, encoding: .utf8).contains("MiPlay-HSR-TEST"))
        try await Task.sleep(for: .milliseconds(700))
        let restored = try String(contentsOf: hosts, encoding: .utf8)
        XCTAssertFalse(restored.contains("MiPlay-HSR-TEST"))
        XCTAssertTrue(restored.contains(original))
    }

    func testStarRailAuthorizationScriptCompilesWithoutExecutingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("authorize.applescript")
        try GameLaunchPreparation.networkAuthorizationScript(token: UUID().uuidString).write(to: source, atomically: true, encoding: .utf8)
        _ = try await ProcessManager().launchAndWait(executablePath: "/usr/bin/osacompile", arguments: ["-o", root.appendingPathComponent("compiled.scpt").path, source.path], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("compiled.scpt").path))
    }

    func testStarRailVendorRegistryPreparationUsesManagedPrefixAndPropagatesFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fake-wine")
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$@" >> "$WINEPREFIX/registry-calls"
        [ ! -f "$WINEPREFIX/fail" ]
        """#
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let manager = ProcessManager()
        try await GameLaunchPreparation.prepareStarRailVendorRegistry(wineBinary: binary.path, prefix: root.path, processManager: manager)
        let calls = try String(contentsOf: root.appendingPathComponent("registry-calls"), encoding: .utf8)
        XCTAssertTrue(calls.contains("NGXCore"))
        XCTAssertTrue(calls.contains("C:\\Windows\\System32"))
        XCTAssertEqual(calls.components(separatedBy: "REG_BINARY").count - 1, 2)
        try Data().write(to: root.appendingPathComponent("fail"))
        do {
            try await GameLaunchPreparation.prepareStarRailVendorRegistry(wineBinary: binary.path, prefix: root.path, processManager: manager)
            XCTFail("Registry preparation failures must block launch")
        } catch ProcessManager.ProcessError.exitWithError(let code, _, _) {
            XCTAssertEqual(code, 1)
        }
    }

    func testGameLauncherWaitsForWineChildrenAndPreservesLauncherFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("GameLauncher"))
        let wine = root.appendingPathComponent("wine")
        let server = root.appendingPathComponent("wineserver")
        let marker = root.appendingPathComponent("waited")
        let status = root.appendingPathComponent("status")
        try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nsleep 0.3\nprintf '%s' \"$1\" > \(GameLaunchPreparation.shellQuote(marker.path))\n".write(to: server, atomically: true, encoding: .utf8)
        for file in [wine, server] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let process = ProcessManager()
        _ = try await process.launchAndWait(executablePath: helper.path, arguments: [wine.path, "fake-game"], environment: ["MIPLAY_WAIT_WINESERVER": server.path, "MIPLAY_LAUNCH_STATUS": status.path], timeout: 5)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "-w")
        XCTAssertEqual(try String(contentsOf: status, encoding: .utf8), "exit:0\n")
        try FileManager.default.removeItem(at: marker)
        try "#!/bin/sh\nexit 7\n".write(to: wine, atomically: true, encoding: .utf8)
        do {
            _ = try await process.launchAndWait(executablePath: helper.path, arguments: [wine.path, "fake-game"], environment: ["MIPLAY_WAIT_WINESERVER": server.path, "MIPLAY_LAUNCH_STATUS": status.path], timeout: 5)
            XCTFail("Launcher failure must propagate")
        } catch ProcessManager.ProcessError.exitWithError(let code, _, _) { XCTAssertEqual(code, 7) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: status, encoding: .utf8), "exit:7\n")
    }

    // MARK: - 搁置的 MetalFX 选项

    func testSuspendedMetalFXOptionNeverReachesLaunchEnvironment() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let manager = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository(appSupportDirectory: baseURL))
        )

        // 模拟历史状态：AppData 里 MetalFX 仍是启用 + 自定义系数（实测现场
        // 就是 isEnabled = true / value = 1.5）。
        var data = AppData()
        data.performanceOptions = [
            GameType.genshinImpact.rawValue: [
                PerformanceOptionDTO(id: "metalfx_spatial_upscale", isEnabled: true, value: "1.5"),
                PerformanceOptionDTO(id: "metal_hud", isEnabled: true, value: nil),
            ]
        ]
        try await store.writeAppData(data)
        await manager.loadOptions()

        let options = manager.getOptionsForLaunch(gameId: GameType.genshinImpact.rawValue)
        XCTAssertFalse(
            options.contains { $0.id == "metalfx_spatial_upscale" },
            "搁置的 MetalFX 选项不得进入启动清单"
        )
        XCTAssertFalse(
            options.contains { $0.id == "metal_hud" },
            "Metal HUD 已按用户指令移到「通用设置」，同样不进入每游戏启动清单"
        )
        XCTAssertTrue(options.isEmpty, "搁置选项不得进入启动清单，实际: \(options.map(\.id))")

        let environment = PerformanceOption.launchEnvironment(for: options)
        XCTAssertNil(environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"])
        XCTAssertNil(environment["DXMT_CONFIG"])
        XCTAssertNil(environment["MTL_HUD_ENABLED"])

        // HUD 改由应用级设置下发（通用设置页）。
        XCTAssertEqual(
            GameEnvironmentSettings(metalHUD: true).environmentVariables["MTL_HUD_ENABLED"],
            "1"
        )

        // 选项定义本身保留（代码不删），只是不再暴露/生效。
        let definition = try XCTUnwrap(
            PerformanceOptionManager.defaultOptions.first { $0.id == "metalfx_spatial_upscale" }
        )
        XCTAssertTrue(definition.isSuspended)
        XCTAssertTrue(definition.requiresValue)
        XCTAssertEqual(definition.launchEnvironment()["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=2;")
    }

    // MARK: - Mac Driver 注册表探测

    func testMacDriverRegistryProbeAvoidsRedundantWineInvocation() throws {
        let prefixURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: prefixURL) }

        // 没有 user.reg：需要写入。
        XCTAssertNil(WineRuntimeProvider.macDriverValue(forKey: "RetinaMode", atPrefixPath: prefixURL.path))

        let registryURL = prefixURL.appendingPathComponent("user.reg")
        try """
        WINE REGISTRY Version 2
        ;; All keys relative to \\User\\S-1-5-21

        [Software\\\\Wine\\\\Mac Driver] 1791227607
        #time=1dd54fd99aab4c6
        "LeftCommandIsCtrl"="n"
        "RetinaMode"="y"

        [Volatile Environment] 1791227586
        "APPDATA"="C:\\\\users\\\\crossover\\\\AppData\\\\Roaming"
        """.write(to: registryURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            WineRuntimeProvider.macDriverValue(forKey: "RetinaMode", atPrefixPath: prefixURL.path),
            "y"
        )
        XCTAssertEqual(
            WineRuntimeProvider.macDriverValue(forKey: "LeftCommandIsCtrl", atPrefixPath: prefixURL.path),
            "n"
        )

        // 值不同（RetinaMode=n）时仍需写入。
        try """
        WINE REGISTRY Version 2
        [Software\\\\Wine\\\\Mac Driver] 1791227607
        "RetinaMode"="n"
        """.write(to: registryURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            WineRuntimeProvider.macDriverValue(forKey: "RetinaMode", atPrefixPath: prefixURL.path),
            "n"
        )

        // 同名值出现在别的注册表节里不算数。
        try """
        WINE REGISTRY Version 2
        [Software\\\\Wine\\\\Other] 1
        "RetinaMode"="y"
        """.write(to: registryURL, atomically: true, encoding: .utf8)
        XCTAssertNil(WineRuntimeProvider.macDriverValue(forKey: "RetinaMode", atPrefixPath: prefixURL.path))
    }

    // MARK: - 游戏运行设置（通用设置页）

    func testDLSSSettingsMigrationAndFailClosedEnvironment() throws {
        let legacy = Data(#"{"metalHUD":true,"fpsUnlock":false,"retinaMode":false,"leftCommandIsCtrl":true}"#.utf8)
        let settings = try JSONDecoder().decode(GameEnvironmentSettings.self, from: legacy)
        XCTAssertFalse(settings.dlssCompatibility)
        XCTAssertTrue(settings.metalHUD)
        XCTAssertFalse(settings.retinaMode)
        XCTAssertTrue(settings.leftCommandIsCtrl)
        XCTAssertEqual(settings.vendorExtensionEnvironment(assetsReady: true)["DXMT_ENABLE_NVEXT"], "0")

        let enabled = GameEnvironmentSettings(dlssCompatibility: true)
        XCTAssertEqual(enabled.vendorExtensionEnvironment(assetsReady: false)["DXMT_ENABLE_NVEXT"], "0")
        XCTAssertEqual(
            enabled.vendorExtensionEnvironment(assetsReady: true)["DXMT_ENABLE_NVEXT"],
            GameEnvironmentSettings.supportsDLSSCompatibility ? "1" : "0"
        )
        XCTAssertEqual(try JSONDecoder().decode(GameEnvironmentSettings.self, from: JSONEncoder().encode(enabled)), enabled)
    }

    func testVendorExtensionsReplaceStaleCopiesOnlyWhenRequested() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets")
        let runtime = root.appendingPathComponent("runtime")
        let prefix = root.appendingPathComponent("prefix")
        let game = root.appendingPathComponent("game")
        let windows = runtime.appendingPathComponent("lib/wine/x86_64-windows")
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        for directory in [assets.appendingPathComponent("dxmt"), windows, runtime.appendingPathComponent("lib/wine/x86_64-unix"), system32, game] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll", "winemetal.so", "nvapi64.dll", "nvngx.dll"] {
            try Data("bundled-\(name)".utf8).write(to: assets.appendingPathComponent("dxmt/\(name)"))
        }
        for name in ["nvapi64.dll", "nvngx.dll"] {
            try Data("original-runtime".utf8).write(to: windows.appendingPathComponent(name))
            try Data("stale-prefix".utf8).write(to: system32.appendingPathComponent(name))
        }
        let disabled = LaunchCompatibilityEnvironment.stage(gameType: .honkaiStarRail, gameDirectory: game, prefixURL: prefix, runtimeRootURL: runtime, assetRootURL: assets)
        XCTAssertFalse(disabled.vendorExtensionsReady)
        XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent("nvngx.dll")), Data("stale-prefix".utf8))
        let enabled = LaunchCompatibilityEnvironment.stage(gameType: .honkaiStarRail, gameDirectory: game, prefixURL: prefix, runtimeRootURL: runtime, assetRootURL: assets, enableVendorExtensions: true)
        XCTAssertTrue(enabled.vendorExtensionsReady)
        for name in ["nvapi64.dll", "nvngx.dll"] {
            XCTAssertEqual(try Data(contentsOf: windows.appendingPathComponent(name)), Data("bundled-\(name)".utf8))
            XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent(name)), Data("bundled-\(name)".utf8))
            XCTAssertEqual(try Data(contentsOf: windows.appendingPathComponent(name + ".bak")), Data("original-runtime".utf8))
        }
        try FileManager.default.removeItem(at: assets.appendingPathComponent("dxmt/nvngx.dll"))
        let missing = LaunchCompatibilityEnvironment.stage(gameType: .honkaiStarRail, gameDirectory: game, prefixURL: prefix, runtimeRootURL: runtime, assetRootURL: assets, enableVendorExtensions: true)
        XCTAssertFalse(missing.vendorExtensionsReady)
        XCTAssertTrue(missing.missingAssetNames.contains("nvngx.dll"))
    }

    func testGameEnvironmentSettingsRegistryAndEnvironmentValues() {
        XCTAssertEqual(
            GameEnvironmentSettings(retinaMode: true, leftCommandIsCtrl: false).registryValues,
            ["RetinaMode": "y", "LeftCommandIsCtrl": "n"]
        )
        XCTAssertEqual(
            GameEnvironmentSettings(retinaMode: false, leftCommandIsCtrl: true).registryValues,
            ["RetinaMode": "n", "LeftCommandIsCtrl": "y"]
        )
        // 默认保持 MiPlay 既有行为：Retina 开、左 Command 不映射、HUD 关（YAAGL 的 Retina 默认相反）。
        XCTAssertEqual(GameEnvironmentSettings().registryValues, ["RetinaMode": "y", "LeftCommandIsCtrl": "n"])
        XCTAssertEqual(GameEnvironmentSettings().environmentVariables, [:])

        // Metal HUD 通过启动环境变量下发；只开 HUD，使用系统默认面板
        // （用户指令：不再覆盖 ELEMENTS/SCALE 成最小尺寸纯 FPS）。
        XCTAssertEqual(
            GameEnvironmentSettings(metalHUD: true).environmentVariables,
            ["MTL_HUD_ENABLED": "1"]
        )

        // AppData 往返保留设置。
        let settings = GameEnvironmentSettings(metalHUD: true, fpsUnlock: true, retinaMode: false, leftCommandIsCtrl: true)
        let data = AppData(gameEnvironmentSettings: settings)
        let decoded = try? JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded?.gameEnvironmentSettings, settings)
        // 旧 AppData（无该字段）解码为默认值。
        let legacy = try? JSONDecoder().decode(AppData.self, from: Data(#"{"schemaVersion":4,"games":[]}"#.utf8))
        XCTAssertEqual(legacy?.gameEnvironmentSettings, GameEnvironmentSettings())
    }

    // MARK: - 子进程环境过滤

    func testChildEnvironmentFiltersMetalDebugVariablesAndKeepsExplicitOverrides() {
        let base: [String: String] = [
            "PATH": "/usr/bin",
            "MTL_DEBUG_LAYER": "1",
            "METAL_DEVICE_WRAPPER_TYPE": "1",
            "MTL_CAPTURE_ENABLED": "1",
            "HOME": "/Users/tester",
        ]
        let filtered = ProcessManager.filteredChildEnvironment(base: base)
        XCTAssertNil(filtered["MTL_DEBUG_LAYER"])
        XCTAssertNil(filtered["METAL_DEVICE_WRAPPER_TYPE"])
        XCTAssertNil(filtered["MTL_CAPTURE_ENABLED"])
        XCTAssertEqual(filtered["PATH"], "/usr/bin")
        XCTAssertEqual(filtered["HOME"], "/Users/tester")

        // 显式覆盖值（我们自己的 HUD 选项）在过滤之后合并，不被打掉。
        let withHUD = ProcessManager.filteredChildEnvironment(
            base: base,
            overrides: ["MTL_HUD_ENABLED": "1", "WINEPREFIX": "/tmp/prefix"]
        )
        XCTAssertEqual(withHUD["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(withHUD["WINEPREFIX"], "/tmp/prefix")
        XCTAssertNil(withHUD["MTL_DEBUG_LAYER"])

        XCTAssertEqual(
            Set(ProcessManager.developmentOnlyMetalVariables(in: base)),
            ["MTL_DEBUG_LAYER", "METAL_DEVICE_WRAPPER_TYPE", "MTL_CAPTURE_ENABLED"]
        )
    }

    // MARK: - 原神启动调用

    func testGenshinLaunchInvocationUsesSteamStubAndFallsBackToDirectCloudArguments() throws {
        let prefixURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: prefixURL) }
        let executablePath = "/tmp/game/YuanShen.exe"

        // 现状（国服 7.1.0 实测）：直启会被 HoYoKProtect 内核驱动挡住
        // （WDFLDR.SYS 缺失 → initDriver Failed），必须走 Steam 兼容存根。
        XCTAssertTrue(LaunchCompatibilityEnvironment.usesSteamCompatibilityStub)

        let steamURL = prefixURL.appendingPathComponent("drive_c/windows/system32/steam.exe")
        try FileManager.default.createDirectory(
            at: steamURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: steamURL)

        let staged = LaunchCompatibilityEnvironment.launchInvocation(
            gameType: .genshinImpact,
            executablePath: executablePath,
            prefixURL: prefixURL
        )
        XCTAssertEqual(staged.program, "C:\\windows\\system32\\steam.exe")
        XCTAssertEqual(staged.arguments, ["Z:\\tmp\\game\\YuanShen.exe"])

        // 存根缺失时回退到直启 + 云平台参数（对照 YAAGL hk4e 的 config.bat）；
        // 上游修复 WDFLDR 后可以切回这条路，强制退出菜单就只剩一个「原神」条目。
        let barePrefix = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: barePrefix) }
        let direct = LaunchCompatibilityEnvironment.launchInvocation(
            gameType: .genshinImpact,
            executablePath: executablePath,
            prefixURL: barePrefix
        )
        XCTAssertEqual(direct.program, executablePath)
        XCTAssertEqual(
            direct.arguments,
            ["-platform_type", "CLOUD_THIRD_PARTY_PC", "-is_cloud", "1"]
        )

        // 绝区零共用 Steam 兼容入口；崩铁保持独立的 Jadeite 路径。
        let zzz = LaunchCompatibilityEnvironment.launchInvocation(
            gameType: .zenlessZoneZero,
            executablePath: "/tmp/game/ZenlessZoneZero.exe",
            prefixURL: prefixURL
        )
        XCTAssertEqual(zzz.program, "C:\\windows\\system32\\steam.exe")
        XCTAssertEqual(zzz.arguments, ["Z:\\tmp\\game\\ZenlessZoneZero.exe"])
        let hsr = LaunchCompatibilityEnvironment.launchInvocation(gameType: .honkaiStarRail, executablePath: "/tmp/Star Rail/StarRail.exe", prefixURL: prefixURL)
        XCTAssertTrue(hsr.program.hasSuffix("\\MiPlay\\Jadeite\\jadeite.exe"))
        XCTAssertEqual(hsr.arguments, ["Z:\\tmp\\Star Rail\\StarRail.exe"])
    }

    // MARK: - staging 跳过未变化拷贝

    func testStagingSkipsUnchangedCopiesOnSecondPass() async throws {
        let gameDirectory = try makeTemporaryDirectory()
        let prefixURL = try makeTemporaryDirectory()
        let runtimeURL = try makeTemporaryDirectory()
        let assetRootURL = try makeTemporaryDirectory()
        defer {
            for url in [gameDirectory, prefixURL, runtimeURL, assetRootURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: prefixURL.appendingPathComponent("drive_c/windows/system32"),
            withIntermediateDirectories: true
        )
        for name in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll", "winemetal.so"] {
            try fileManager.createDirectory(
                at: runtimeURL.appendingPathComponent("lib/wine/x86_64-windows"),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: runtimeURL.appendingPathComponent("lib/wine/x86_64-unix"),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: assetRootURL.appendingPathComponent("dxmt"),
                withIntermediateDirectories: true
            )
            try Data("stub".utf8).write(to: assetRootURL.appendingPathComponent("dxmt/\(name)"))
            try Data("pristine".utf8).write(
                to: runtimeURL.appendingPathComponent("lib/wine/x86_64-windows/\(name)")
            )
        }
        try Data("driver".utf8).write(to: gameDirectory.appendingPathComponent("HoYoKProtect.sys"))

        try fileManager.createDirectory(at: prefixURL.appendingPathComponent("drive_c/windows/syswow64"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assetRootURL.appendingPathComponent("protonextras"), withIntermediateDirectories: true)
        for name in ["steam64.exe", "steam32.exe", "lsteamclient64.dll", "lsteamclient32.dll"] {
            try Data(name.utf8).write(to: assetRootURL.appendingPathComponent("protonextras/\(name)"))
        }

        let first = LaunchCompatibilityEnvironment.stage(
            gameType: .zenlessZoneZero,
            gameDirectory: gameDirectory,
            prefixURL: prefixURL,
            runtimeRootURL: runtimeURL,
            assetRootURL: assetRootURL
        )
        XCTAssertGreaterThan(first.stagedFileCount, 0, "首次 staging 需要落盘")
        XCTAssertTrue(first.missingAssetNames.isEmpty)

        let second = LaunchCompatibilityEnvironment.stage(
            gameType: .zenlessZoneZero,
            gameDirectory: gameDirectory,
            prefixURL: prefixURL,
            runtimeRootURL: runtimeURL,
            assetRootURL: assetRootURL
        )
        XCTAssertEqual(second.stagedFileCount, 0, "内容未变化时不应重复拷贝")
        XCTAssertTrue(second.missingAssetNames.isEmpty)

        // 源被替换后必须重新拷贝。
        try Data("driver-v2".utf8).write(to: gameDirectory.appendingPathComponent("HoYoKProtect.sys"))
        let third = LaunchCompatibilityEnvironment.stage(
            gameType: .zenlessZoneZero,
            gameDirectory: gameDirectory,
            prefixURL: prefixURL,
            runtimeRootURL: runtimeURL,
            assetRootURL: assetRootURL
        )
        XCTAssertEqual(third.stagedFileCount, 1, "只有变化的文件被重新拷贝")
    }

    // MARK: - 图标区服判定

    func testGameIconRegionResolutionFollowsInstallConfig() throws {
        let installURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: installURL) }

        try "[General]\nuapc={\"hk4e_cn\":{\"uapc\":\"\"}}\n".write(
            to: installURL.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            GameIconProvider.region(for: .genshinImpact, installPath: installURL.path),
            .china
        )

        try "[General]\nuapc={\"nap_global\":{\"uapc\":\"\"}}\n".write(
            to: installURL.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            GameIconProvider.region(for: .zenlessZoneZero, installPath: installURL.path),
            .global
        )

        // 没有 config.ini 时按国服可执行文件名回退（原神国服是 YuanShen.exe）。
        let fallbackURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fallbackURL) }
        try Data().write(to: fallbackURL.appendingPathComponent("YuanShen.exe"))
        XCTAssertEqual(
            GameIconProvider.region(for: .genshinImpact, installPath: fallbackURL.path),
            .china
        )
        XCTAssertEqual(
            Set(GameIconProvider.candidateBizIDs(for: .honkaiStarRail)),
            ["hkrpg_cn", "hkrpg_global"]
        )
    }

    // MARK: - 资产来源解析（随包资源优先）

    func testAssetSourceResolutionPrefersBundledAssetsAndFallsBackToAppSupport() throws {
        let bundled = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: appSupport)
        }
        let fileManager = FileManager.default

        func writeDXMTMarker(into root: URL) throws {
            try fileManager.createDirectory(
                at: root.appendingPathComponent("dxmt"),
                withIntermediateDirectories: true
            )
            try Data("dll".utf8).write(to: root.appendingPathComponent("dxmt/d3d11.dll"))
        }

        // 两处都没有可用资产 → 无解（调用方回退到 App Support 路径继续报缺失资产）。
        XCTAssertNil(LaunchCompatibilityEnvironment.resolveAssetSourceRoot(
            candidates: [bundled, appSupport],
            fileManager: fileManager
        ))

        // 只有 App Support 有 → 用 App Support（历史安装/手工替换）。
        try writeDXMTMarker(into: appSupport)
        XCTAssertEqual(
            LaunchCompatibilityEnvironment.resolveAssetSourceRoot(
                candidates: [bundled, appSupport],
                fileManager: fileManager
            ),
            appSupport
        )

        // 随包资源存在 → 优先随包（删掉 App Support 后的干净安装走这条）。
        try writeDXMTMarker(into: bundled)
        XCTAssertEqual(
            LaunchCompatibilityEnvironment.resolveAssetSourceRoot(
                candidates: [bundled, appSupport],
                fileManager: fileManager
            ),
            bundled
        )

        // 只有目录、没有 dxmt/d3d11.dll 的候选不算可用。
        let emptyRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        try fileManager.createDirectory(
            at: emptyRoot.appendingPathComponent("dxmt"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            LaunchCompatibilityEnvironment.resolveAssetSourceRoot(
                candidates: [emptyRoot, appSupport],
                fileManager: fileManager
            ),
            appSupport
        )
    }

    // MARK: - 启动准备阶段（全屏遮罩）

    func testStartupPreparationOverlayCoversMainWindowFromFirstFrame() async throws {
        let fixture = try await makeScheduler()
        let viewModel = LibraryViewModel(
            gameRegistry: fixture.registry,
            launchOrchestrator: fixture.launchOrchestrator,
            // 不注入媒体服务：本用例只验证阶段与遮罩，避免真实下载/转码拖慢测试。
            backgroundMediaService: nil,
            persistenceStore: fixture.persistence,
            taskScheduler: fixture.scheduler,
            logWriter: fixture.logger
        )

        // 首帧（initialize 之前）：阶段初值即"准备 Wine"，遮罩必须已经覆盖主页。
        // 这正是旧实现在冷启动时缺失的行为（旧条件依赖 backgroundMediaState 快照，
        // 需要切换游戏才会刷新出遮罩）。
        XCTAssertEqual(viewModel.startupPhase, .preparingWine)
        XCTAssertTrue(viewModel.isStartupPreparationVisible)

        await viewModel.initialize()

        // 两个阶段依次跑完后进入 ready，遮罩关闭。
        XCTAssertEqual(viewModel.startupPhase, .ready)
        XCTAssertFalse(viewModel.isStartupPreparationVisible)
        XCTAssertNil(viewModel.startupDetail)
    }

    func testStartupMediaFinishesWhileWineIsStillPreparingAndWineFailureKeepsOverlay() async throws {
        let fixture = try await makeScheduler(
            networkProvider: makeWineNetwork(metadataDelay: 3, catalogStatus: 403)
        )
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("background.png")
        try Data("local background".utf8).write(to: image)
        try await fixture.persistence.updateAppData { data in
            for game in GameType.allCases {
                data.backgroundModes[game.rawValue] = BackgroundMediaService.BackgroundMode.custom.rawValue
                data.customImagePaths[game.rawValue] = image.path
            }
        }
        let viewModel = LibraryViewModel(
            gameRegistry: fixture.registry,
            launchOrchestrator: fixture.launchOrchestrator,
            backgroundMediaService: fixture.backgroundMediaService,
            persistenceStore: fixture.persistence,
            taskScheduler: fixture.scheduler,
            logWriter: fixture.logger,
            wineVersionManager: fixture.wineManager
        )
        let initialization = Task { await viewModel.initialize() }
        let deadline = ContinuousClock.now + .seconds(5)
        var overlapped = false
        while ContinuousClock.now < deadline {
            let tasks = await fixture.scheduler.allTaskSnapshots()
            let mediaFinished = tasks.filter { $0.type == .backgroundMediaLoad && $0.state == .completed }.count == GameType.allCases.count
            let wineRunning = tasks.contains { $0.type == .wineRuntimeSetup && $0.state == .running }
            if mediaFinished && wineRunning {
                overlapped = true
                break
            }
            if viewModel.isInitialized { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(overlapped, "素材应在 Wine 尚未完成时准备完毕")
        XCTAssertEqual(viewModel.startupPhase, .preparingWine)
        XCTAssertTrue(viewModel.isStartupPreparationVisible)
        await initialization.value
        XCTAssertNotNil(viewModel.startupFailure)
        XCTAssertTrue(viewModel.isStartupPreparationVisible, "素材已完成也不能放行失败的 Wine 环境")
    }

    func testStartupWaitsForRemainingMediaWhenWineFinishesFirst() async throws {
        MockURLProtocol.configure { _ in
            .init(data: Data(), statusCode: 404, delay: 0.5)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let fixture = try await makeScheduler(
            networkProvider: NetworkDownloadProvider(session: URLSession(configuration: configuration))
        )
        let viewModel = LibraryViewModel(
            gameRegistry: fixture.registry,
            launchOrchestrator: fixture.launchOrchestrator,
            backgroundMediaService: fixture.backgroundMediaService,
            persistenceStore: fixture.persistence,
            taskScheduler: fixture.scheduler,
            logWriter: fixture.logger
        )
        // 无 Wine 依赖模拟 Wine 即时就绪；素材请求仍在网络等待中。
        let initialization = Task { await viewModel.initialize() }
        let deadline = ContinuousClock.now + .seconds(3)
        while viewModel.startupPhase == .preparingWine, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(viewModel.startupPhase, .preparingMedia)
        XCTAssertTrue(viewModel.isStartupPreparationVisible)
        let running = await fixture.scheduler.allTaskSnapshots()
        XCTAssertTrue(running.contains { $0.type == .backgroundMediaLoad && $0.state == .running })
        await initialization.value
        XCTAssertEqual(viewModel.startupPhase, .ready)
        XCTAssertFalse(viewModel.isStartupPreparationVisible)
        let finished = await fixture.scheduler.allTaskSnapshots()
        XCTAssertFalse(finished.contains {
            $0.type == .backgroundMediaLoad && ($0.state == .pending || $0.state == .running)
        })
    }

    func testGameEnvironmentTogglesApplySynchronouslyAndPersist() async throws {
        let fixture = try await makeScheduler()
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )
        await viewModel.loadSettings()

        // 默认：HUD/超帧率关、Retina 开、左 Command 不映射（保持 MiPlay 既有行为）。
        XCTAssertEqual(
            viewModel.gameEnvironmentSettings,
            GameEnvironmentSettings(metalHUD: false, fpsUnlock: false, retinaMode: true, leftCommandIsCtrl: false)
        )

        // 四个开关同步生效（Toggle 不回弹）。
        viewModel.applyMetalHUD(true)
        XCTAssertTrue(viewModel.gameEnvironmentSettings.metalHUD)
        viewModel.applyFPSUnlock(true)
        XCTAssertTrue(viewModel.gameEnvironmentSettings.fpsUnlock)
        viewModel.applyRetinaMode(false)
        XCTAssertFalse(viewModel.gameEnvironmentSettings.retinaMode)
        viewModel.applyLeftCommandIsCtrl(true)
        XCTAssertTrue(viewModel.gameEnvironmentSettings.leftCommandIsCtrl)

        // 后台持久化落到 AppData；注册表写入发生在下次准备 prefix / 启动游戏时，
        // HUD 环境变量在下次启动游戏时注入。
        let expected = GameEnvironmentSettings(
            metalHUD: true,
            fpsUnlock: true,
            retinaMode: false,
            leftCommandIsCtrl: true
        )
        let deadline = Date().addingTimeInterval(3)
        var persisted = GameEnvironmentSettings()
        while Date() < deadline {
            persisted = try await fixture.persistence.readAppData().gameEnvironmentSettings
            if persisted == expected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            persisted,
            expected,
            "开关状态必须持久化，否则下次启动游戏时不会生效"
        )
    }

    /// 隔离诊断：下载器必须持续产出进度（不是只有首尾两个值）。
    /// 进度来源为 `URLSessionTask.countOfBytesReceived` 轮询（见
    /// `NetworkDownloadProvider.download` 注释：KVO 只有首尾几个值）。
    func testNetworkDownloadProviderEmitsContinuousProgress() async throws {
        let payload = Data(repeating: 0x5a, count: 512 * 1024)
        let provider = try makeDownloadNetwork(
            response: MockURLProtocol.Response(data: payload, chunkDelay: 0.02)
        )
        let destination = try makeTemporaryDirectory().appendingPathComponent("payload.bin")
        var values: [Double] = []
        var transfers: [String] = []
        let stream = await provider.download(
            from: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/x/wine.tar.xz")!,
            to: destination.path
        )
        for await progress in stream {
            values.append(progress.fractionCompleted)
            transfers.append("\(progress.bytesReceived)/\(progress.totalBytes)")
        }
        XCTAssertGreaterThanOrEqual(
            Set(values).count,
            3,
            "下载必须持续上报进度，实际: \(values)；字节: \(Set(transfers).sorted())"
        )
    }

    // MARK: - 启动准备的进度传播

    /// 回归：Wine 阶段的下载/解压进度必须持续传到 `startupProgress`
    /// （用户实测：进度条一直停在 5%，解压阶段也不动）。
    func testStartupWinePhasePublishesContinuousProgress() async throws {
        // 24MB filler：让解压阶段有可观察的持续时间（小归档会瞬间完成）。
        let archive = try makeWineArchive(fillerBytes: 24 * 1024 * 1024)
        let fixture = try await makeScheduler(
            networkProvider: makeWineNetwork(archive: archive, chunkDelay: 0.02)
        )
        let viewModel = LibraryViewModel(
            gameRegistry: fixture.registry,
            launchOrchestrator: fixture.launchOrchestrator,
            backgroundMediaService: nil,
            persistenceStore: fixture.persistence,
            taskScheduler: fixture.scheduler,
            logWriter: fixture.logger,
            wineVersionManager: fixture.wineManager
        )

        let run = Task { await viewModel.initialize() }

        // 采样启动准备进度：应出现多个不同的中间值（下载 0→1、解压 0→1）。
        var samples: [Double] = []
        var details: Set<String> = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let progress = viewModel.startupProgress { samples.append(progress) }
            if let detail = viewModel.startupDetail { details.insert(detail) }
            if viewModel.startupPhase == .ready || viewModel.startupFailure != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await run.value

        XCTAssertEqual(viewModel.startupPhase, .ready, "启动准备应完成；失败原因: \(viewModel.startupFailure ?? "无")")
        let distinctIntermediates = Set(samples.filter { $0 > 0 && $0 < 1 })
        XCTAssertGreaterThanOrEqual(
            distinctIntermediates.count,
            2,
            "下载/解压过程中必须发布多个不同的中间进度值，实际: \(samples)"
        )
        XCTAssertTrue(
            details.contains { $0.contains("下载") },
            "下载阶段说明文字缺失，实际: \(details)"
        )
        XCTAssertTrue(
            details.contains { $0.contains("解压") },
            "解压阶段说明文字缺失，实际: \(details)"
        )
    }

    // MARK: - bundle 组装：图标挂载

    func testPrepareAppBundleAttachesCachedIcon() throws {
        let assetRootURL = try makeTemporaryDirectory()
        let launcherRootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: assetRootURL)
            try? FileManager.default.removeItem(at: launcherRootURL)
        }
        let launcherURL = launcherRootURL.appendingPathComponent("GameLauncher")
        try Data("launcher-binary".utf8).write(to: launcherURL)

        // 图标缓存存在（由 GameIconProvider 生成）→ bundle 必须带上 CFBundleIconFile。
        let iconURL = LaunchCompatibilityEnvironment.iconCacheURL(
            for: .genshinImpact,
            assetRootURL: assetRootURL
        )
        try FileManager.default.createDirectory(
            at: iconURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("icns-bytes".utf8).write(to: iconURL)

        let bundle = try XCTUnwrap(LaunchCompatibilityEnvironment.prepareAppBundle(
            gameType: .genshinImpact,
            assetRootURL: assetRootURL,
            launcherResourceURL: launcherURL
        ))
        let bundleIconURL = bundle.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleIconURL.path))
        XCTAssertEqual(try Data(contentsOf: bundleIconURL), Data("icns-bytes".utf8))

        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: bundle.bundleURL.appendingPathComponent("Contents/Info.plist"))
        )
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["CFBundleName"] as? String, "原神")

        // 二次组装是幂等的（入口程序与图标都未变化，不应破坏现有 bundle）。
        let second = try XCTUnwrap(LaunchCompatibilityEnvironment.prepareAppBundle(
            gameType: .genshinImpact,
            assetRootURL: assetRootURL,
            launcherResourceURL: launcherURL
        ))
        XCTAssertEqual(second.bundleURL, bundle.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleIconURL.path))

        // 没有图标缓存时不写 CFBundleIconFile（保持无图标形态，下次启动重试）。
        let emptyAssetRootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: emptyAssetRootURL) }
        let withoutIcon = try XCTUnwrap(LaunchCompatibilityEnvironment.prepareAppBundle(
            gameType: .zenlessZoneZero,
            assetRootURL: emptyAssetRootURL,
            launcherResourceURL: launcherURL
        ))
        let noIconPlist = try XCTUnwrap(
            NSDictionary(contentsOf: withoutIcon.bundleURL.appendingPathComponent("Contents/Info.plist"))
        )
        XCTAssertNil(noIconPlist["CFBundleIconFile"])
    }

    // MARK: - runtime 探针缓存

    func testRuntimeVerificationProbeRunsOncePerBinaryFingerprint() async throws {
        let versionsRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: versionsRoot) }
        let counterURL = try makeTemporaryDirectory().appendingPathComponent("probe-count")
        defer { try? FileManager.default.removeItem(at: counterURL.deletingLastPathComponent()) }

        let runtimeRoot = versionsRoot
            .appendingPathComponent("WineVersions", isDirectory: true)
            .appendingPathComponent(WineVersionManager.fixedRuntimeTag, isDirectory: true)
        let binURL = runtimeRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let wineURL = binURL.appendingPathComponent("wine")
        try """
        #!/bin/sh
        echo probe >> "\(counterURL.path)"
        echo wine-11.0
        """.write(to: wineURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineURL.path)

        let provider = WineRuntimeProvider(
            processManager: ProcessManager(),
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        )
        let runtime = ManagedWineRuntime(tagName: WineVersionManager.fixedRuntimeTag, rootURL: runtimeRoot)

        _ = try await provider.load(runtime: runtime)
        _ = try await provider.load(runtime: runtime)
        _ = try await provider.load(runtime: runtime)
        XCTAssertEqual(probeCount(at: counterURL), 1, "同一 binary（路径+大小+修改时间）只探针一次")

        // binary 被替换（修改时间变化）后必须重新探针。
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: wineURL.path
        )
        _ = try await provider.load(runtime: runtime)
        XCTAssertEqual(probeCount(at: counterURL), 2)
    }

    private func probeCount(at url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return content.split(whereSeparator: \.isNewline).count
    }

    // MARK: - 侧栏官方游戏图标

    /// 侧栏图标只取本地缓存：存在才进入 `gameIconURLs`，缺失时由视图回退到 SF Symbol。
    func testCachedGameIconURLsListsOnlyExistingIcons() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiPlayIconTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("GameIcons", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(
            LibraryViewModel.cachedGameIconURLs(assetRootURL: root).isEmpty,
            "空缓存目录不应产生任何图标"
        )

        let target = LaunchCompatibilityEnvironment.iconCacheURL(
            for: .genshinImpact,
            assetRootURL: root
        )
        try Data("stub-icns".utf8).write(to: target)

        let urls = LibraryViewModel.cachedGameIconURLs(assetRootURL: root)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[.genshinImpact], target)
        XCTAssertNil(urls[.zenlessZoneZero])
    }
}
