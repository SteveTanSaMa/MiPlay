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

private actor LSFGToolInvocationRecorder {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval
    }
    private var calls: [Call] = []
    func record(_ executable: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) {
        calls.append(Call(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
    }
    func snapshot() -> [Call] { calls }
}

@MainActor extension MiPlayCoreTests {
    private func lsfgMachOHeader(fileType: UInt32, arm64: Bool = false) -> Data {
        var bytes = Data(repeating: 0, count: 32)
        func write(_ value: UInt32, at offset: Int) {
            for shift in 0..<4 { bytes[offset + shift] = UInt8((value >> (shift * 8)) & 255) }
        }
        write(0xfeedfacf, at: 0)
        write(arm64 ? 0x0100000c : 0x01000007, at: 4)
        write(fileType, at: 12)
        return bytes
    }

    /// These are structural fixtures, never GPU libraries or runnable programs.
    private func makeLSFGComponentFixture(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in LSFGResources.componentFiles {
            let url = root.appendingPathComponent(name)
            try lsfgMachOHeader(fileType: name.hasSuffix(".dylib") ? 6 : 2).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try writeLSFGFixtureManifest(at: root)
    }

    private func writeLSFGFixtureManifest(at root: URL) throws {
        var hashes: [String: String] = [:]
        for name in LSFGResources.componentFiles {
            hashes[name] = LSFGResources.digest(try Data(contentsOf: root.appendingPathComponent(name)))
        }
        try JSONEncoder().encode(LSFGResources.Manifest(schema: 1, sha256: hashes))
            .write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }

    @discardableResult
    private func writeLSFGFixtureShader(_ bytes: Data, support: URL) throws -> URL {
        let hash = LSFGResources.digest(bytes)
        let root = support.appendingPathComponent("LSFG")
        let directory = root.appendingPathComponent("Shaders/\(hash)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shader = directory.appendingPathComponent("lsfg-vk.dll")
        try bytes.write(to: shader)
        try JSONEncoder().encode(["sha256": hash]).write(to: root.appendingPathComponent("shader.json"))
        return shader
    }

    func testApplicationLaunchServicesEnvironmentRelaysOnlyPreparedRuntimeKeys() throws {
        let polluted = ["PATH": "/usr/bin", "WINEPREFIX": "/fixture/prefix", "LANG": "zh_CN.UTF-8",
                        "MTL_DEBUG_LAYER": "1", "METAL_DEVICE_WRAPPER_TYPE": "1",
                        "DYLD_INSERT_LIBRARIES": "/old/injection.dylib", "LSFGM_MULTIPLIER": "4",
                        "MIPLAY_LSFG_LIBRARY": "/old/relay.dylib", "DISABLE_LSFGM": "1"]
        let off = try ApplicationLauncher.launchServicesEnvironment(ProcessManager.filteredChildEnvironment(base: polluted))
        XCTAssertEqual(off[ApplicationLauncher.runtimeVariableAllowlistKey], "", "Even LSFG/HUD off must override an inherited marker")
        XCTAssertEqual(off["WINEPREFIX"], "/fixture/prefix")
        XCTAssertNil(off["MTL_DEBUG_LAYER"])
        XCTAssertNil(off["MIPLAY_LSFG_LIBRARY"])

        let prepared = ["MTL_HUD_ENABLED": "1", "LSFGM_METAL": "1", "LSFGM_MULTIPLIER": "2",
                        "MIPLAY_LSFG_LIBRARY": "/verified/lsfg.dylib", "DYLD_TEST_EXPLICIT_VALUE": "kept",
                        "LANG": "zh_CN.UTF-8", "WINEPREFIX": "/fixture/prefix",
                        ApplicationLauncher.runtimeVariableAllowlistKey: "MTL_DEBUG_LAYER"]
        let configured = try ApplicationLauncher.launchServicesEnvironment(prepared)
        XCTAssertEqual(configured[ApplicationLauncher.runtimeVariableAllowlistKey],
                       "DYLD_TEST_EXPLICIT_VALUE,LSFGM_METAL,LSFGM_MULTIPLIER,MIPLAY_LSFG_LIBRARY,MTL_HUD_ENABLED")
        for (key, value) in prepared where key != ApplicationLauncher.runtimeVariableAllowlistKey {
            XCTAssertEqual(configured[key], value)
        }
        for invalid in ["MTL_BAD,LSFGM_MULTIPLIER", "MTL_BAD=VALUE", "LSFGM_BAD\nKEY", "DYLD_BAD\0KEY", "METAL_非法",
                        "MIPLAY_LSFG_" + String(repeating: "A", count: 256)] {
            XCTAssertThrowsError(try ApplicationLauncher.launchServicesEnvironment([invalid: "1"]), invalid)
        }
        let oversized = Dictionary(uniqueKeysWithValues: (0..<2000).map { ("MTL_LONG_TEST_KEY_\($0)", "1") })
        XCTAssertThrowsError(try ApplicationLauncher.launchServicesEnvironment(oversized))
    }

    /// A native fixture avoids /bin/sh's own DYLD sanitization hiding bugs in
    /// GameLauncher. It reads only named variables and never loads Metal/GPU.
    private func makeLSFGRuntimeEnvironmentProbe(at root: URL) async throws -> URL {
        let source = root.appendingPathComponent("environment-probe.c")
        let executable = root.appendingPathComponent("environment-probe")
        try #"""
        #include <stdio.h>
        #include <stdlib.h>
        int main(int argc, char **argv) {
            for (int index = 1; index < argc; ++index) {
                const char *value = getenv(argv[index]);
                printf("%s=%s\n", argv[index], value ? value : "<unset>");
            }
            return 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        _ = try await ProcessManager().launchAndWait(
            executablePath: "/usr/bin/cc", arguments: ["-O0", "-o", executable.path, source.path], timeout: 30
        )
        return executable
    }

    func testGameLauncherRemovesInheritedRuntimeVariablesAndPreservesExplicitHUDAndLSFG() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try XCTUnwrap(Bundle.main.url(forResource: "GameLauncher", withExtension: nil))
        let probe = try await makeLSFGRuntimeEnvironmentProbe(at: root)
        let polluted = ["MTL_DEBUG_LAYER": "1", "MTL_HUD_ENABLED": "stale", "METAL_DEVICE_WRAPPER_TYPE": "1",
                        "DYLD_INSERT_LIBRARIES": "", "DYLD_LIBRARY_PATH": "/unused/inherited/path",
                        "DYLD_TEST_RUNTIME_VALUE": "stale", "LSFGM_METAL": "1", "LSFGM_MULTIPLIER": "4",
                        "LSFGM_TARGET_FPS": "240", "LSFGM_METAL_DUMP": "/old/dump",
                        "MIPLAY_LSFG_LIBRARY": "/missing/inherited-library.dylib", "MIPLAY_LSFG_TEST": "stale",
                        "DISABLE_LSFGM": "1", "ORDINARY_MTL_DEBUG_LAYER": "ordinary"]
        let ordinary = ["WINEPREFIX": "/fixture/prefix", "LANG": "zh_CN.UTF-8"]
        let explicit = ["MTL_HUD_ENABLED": "1", "LSFGM_METAL": "1", "LSFGM_MULTIPLIER": "2",
                        "MIPLAY_LSFG_TEST": "planned", "DYLD_TEST_RUNTIME_VALUE": "explicit"]
        let names = polluted.keys.sorted() + [ApplicationLauncher.runtimeVariableAllowlistKey, "WINEPREFIX", "LANG"]
        let process = ProcessManager()
        for enabled in [false, true] {
            let prepared = ordinary.merging(enabled ? explicit : [:]) { _, value in value }
            let launch = try ApplicationLauncher.launchServicesEnvironment(prepared)
            // Supply pollution as explicit ProcessManager overrides to model
            // LaunchServices overlaying it after Swift's first filtering pass.
            let actualEnvironment = polluted.merging(launch) { _, value in value }
            let output = try await process.launchAndWait(
                executablePath: helper.path, arguments: [probe.path] + names,
                environment: actualEnvironment, timeout: 5
            )
            let observed = Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line -> (String, String)? in
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            })
            for key in polluted.keys where key != "ORDINARY_MTL_DEBUG_LAYER" {
                XCTAssertEqual(observed[key], enabled ? explicit[key] ?? "<unset>" : "<unset>", "\(key), enabled=\(enabled)")
            }
            XCTAssertEqual(observed[ApplicationLauncher.runtimeVariableAllowlistKey], "<unset>")
            XCTAssertEqual(observed["ORDINARY_MTL_DEBUG_LAYER"], "ordinary")
            XCTAssertEqual(observed["WINEPREFIX"], ordinary["WINEPREFIX"])
            XCTAssertEqual(observed["LANG"], ordinary["LANG"])
        }

        let direct = try await process.launchAndWait(
            executablePath: helper.path, arguments: [probe.path, "MTL_DEBUG_LAYER", "LSFGM_MULTIPLIER"],
            environment: ["MTL_DEBUG_LAYER": "1", "LSFGM_MULTIPLIER": "4"], timeout: 5
        )
        XCTAssertTrue(direct.contains("MTL_DEBUG_LAYER=1\n"), "No-marker direct helper calls retain their established behavior")
        XCTAssertTrue(direct.contains("LSFGM_MULTIPLIER=4\n"))
    }

    func testGameLauncherRejectsMalformedRuntimeAllowlistAndKeepsExplicitRelayValidation() async throws {
        let helper = try XCTUnwrap(Bundle.main.url(forResource: "GameLauncher", withExtension: nil))
        let process = ProcessManager()
        for invalid in ["PATH", "MTL_HUD_ENABLED,,LSFGM_MULTIPLIER", ",MTL_HUD_ENABLED", "MTL_HUD_ENABLED,",
                        "MTL_HUD_ENABLED\nLSFGM_MULTIPLIER", "LSFGM_METAL=1", String(repeating: "A", count: 16385)] {
            do {
                _ = try await process.launchAndWait(
                    executablePath: helper.path, arguments: ["/bin/echo", "child-must-not-start"],
                    environment: [ApplicationLauncher.runtimeVariableAllowlistKey: invalid], timeout: 5
                )
                XCTFail("Invalid runtime allowlist must prevent child launch")
            } catch ProcessManager.ProcessError.exitWithError(let code, _, let output) {
                XCTAssertEqual(code, 78)
                XCTAssertTrue(output.contains("invalid explicit runtime environment allowlist"))
                XCTAssertFalse(output.contains("child-must-not-start"))
            }
        }
        let explicitRelay = try ApplicationLauncher.launchServicesEnvironment(["MIPLAY_LSFG_LIBRARY": "/missing/explicit-library.dylib"])
        do {
            _ = try await process.launchAndWait(
                executablePath: helper.path, arguments: ["/bin/echo", "child-must-not-start"],
                environment: explicitRelay, timeout: 5
            )
            XCTFail("An explicitly retained LSFG relay still requires a valid thin x86_64 library and target")
        } catch ProcessManager.ProcessError.exitWithError(let code, _, let output) {
            XCTAssertEqual(code, 78)
            XCTAssertTrue(output.contains("invalid LSFG relay"))
            XCTAssertFalse(output.contains("child-must-not-start"))
        }
    }

    func testLSFGDisabledPreparationDoesNotReadResourcesOrCreateDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("does-not-exist")
        let result = try await LSFGLaunchEnvironment.prepare(
            settings: LSFGSettings(enabled: false, multiplier: 99, flowScale: .nan),
            wine: absent.appendingPathComponent("wine"), support: absent,
            session: UUID(), components: absent.appendingPathComponent("components"), processManager: ProcessManager()
        )
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testLSFGLaunchEnvironmentsSeparateHelperAndWineAndRemoveInheritedInjection() {
        let root = URL(fileURLWithPath: "/fixture/LSFG")
        let component = LSFGResources.Component(
            library: root.appendingPathComponent("liblsfg_metal.dylib"),
            driver: root.appendingPathComponent("libMoltenVK.generator.dylib"),
            preflight: root.appendingPathComponent("preflight"), shaderCheck: root.appendingPathComponent("shader-check"),
            identity: "fixture"
        )
        let gameDriver = URL(fileURLWithPath: "/fixture/runtime/lib/libMoltenVK.dylib")
        let plan = LSFGLaunchEnvironment.Plan(component: component, shader: root.appendingPathComponent("lsfg-vk.dll"),
                                             gameDriver: gameDriver,
                                             settings: LSFGSettings(enabled: true, multiplier: 3, flowScale: 0.5,
                                                                    performanceMode: true, targetFPS: 120),
                                             cache: root.appendingPathComponent("Cache"), log: root.appendingPathComponent("session.log"))
        let inherited = ["PATH": "/usr/bin", "WINEPREFIX": "/fixture/prefix", "LANG": "zh_CN.UTF-8",
                         "DYLD_INSERT_LIBRARIES": "/unexpected.dylib", "DYLD_LIBRARY_PATH": "/unexpected",
                         "LSFGM_MULTIPLIER": "4", "LSFGM_METAL_DUMP": "/unexpected-dump", "LSFGM_TARGET_FPS": "999",
                         "MIPLAY_LSFG_LIBRARY": "/unexpected-relay.dylib", "DISABLE_LSFGM": "1",
                         "MTL_DEBUG_LAYER": "1", "METAL_DEVICE_WRAPPER_TYPE": "1", "MTL_HUD_ENABLED": "1"]
        let clean = ProcessManager.filteredChildEnvironment(base: inherited)
        XCTAssertEqual(clean, ["PATH": "/usr/bin", "WINEPREFIX": "/fixture/prefix", "LANG": "zh_CN.UTF-8"])
        let helper = plan.applying(to: ["MTL_HUD_ENABLED": "1", "WINEPREFIX": "/fixture/prefix"], entry: .universalLauncher)
        XCTAssertNil(helper["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(helper["MIPLAY_LSFG_LIBRARY"], component.library.path)
        XCTAssertEqual(helper["LSFGM_GENERATOR_MOLTENVK"], component.driver.path)
        XCTAssertEqual(helper["LSFGM_MOLTENVK"], gameDriver.path, "Wine initialization still forwards Vulkan through the game's original driver")
        XCTAssertNotEqual(helper["LSFGM_MOLTENVK"], helper["LSFGM_GENERATOR_MOLTENVK"], "Game driver must not be replaced by the private generator driver")
        XCTAssertEqual(helper["LSFGM_MULTIPLIER"], "3")
        XCTAssertEqual(helper["LSFGM_FLOW_SCALE"], "0.5")
        XCTAssertEqual(helper["LSFGM_PERFORMANCE_MODE"], "1")
        XCTAssertEqual(helper["LSFGM_TARGET_FPS"], "120")
        XCTAssertEqual(helper["LSFGM_PACING_MODE"], "adaptive", "Target FPS must participate in frame selection")
        XCTAssertEqual(helper["LSFGM_OVERRIDE_PRESENT_MODE"], "1", "Current frame generation needs synchronized presentation to avoid burst overwrites")
        XCTAssertEqual(helper["LSFGM_LATENCY"], "1", "Record queue, worker and presentation latency for real-game diagnosis")
        let effective = ProcessManager.filteredChildEnvironment(base: inherited, overrides: helper)
        XCTAssertEqual(effective["MTL_HUD_ENABLED"], "1", "Explicit HUD setting survives inherited debug sanitization")
        XCTAssertNil(effective["MTL_DEBUG_LAYER"])
        XCTAssertNil(effective["LSFGM_METAL_DUMP"])
        XCTAssertNil(effective["DYLD_LIBRARY_PATH"])
        XCTAssertNil(effective["DISABLE_LSFGM"])
        let direct = plan.applying(to: inherited, entry: .directWine)
        XCTAssertEqual(direct["DYLD_INSERT_LIBRARIES"], component.library.path)
        XCTAssertNil(direct["MIPLAY_LSFG_LIBRARY"])
        XCTAssertNil(direct["LSFGM_METAL_DUMP"])
        XCTAssertNil(direct["DYLD_LIBRARY_PATH"])
        let automatic = LSFGLaunchEnvironment.Plan(component: component, shader: plan.shader, gameDriver: gameDriver,
                                                  settings: LSFGSettings(enabled: true), cache: plan.cache, log: plan.log)
        XCTAssertNil(automatic.applying(to: inherited, entry: .directWine)["LSFGM_TARGET_FPS"])
    }

    func testLSFGComponentValidationRejectsChangedBytesWrongArchitectureAndNonExecutableTools() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLSFGComponentFixture(at: root)
        XCTAssertNoThrow(try LSFGResources.validatedComponent(at: root))
        let library = root.appendingPathComponent("liblsfg_metal.dylib")
        try Data("changed component".utf8).write(to: library)
        XCTAssertThrowsError(try LSFGResources.validatedComponent(at: root))
        try lsfgMachOHeader(fileType: 6, arm64: true).write(to: library)
        try writeLSFGFixtureManifest(at: root)
        XCTAssertThrowsError(try LSFGResources.validatedComponent(at: root), "Matching hash does not make an arm64 library loadable in Wine")
        try makeLSFGComponentFixture(at: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("preflight").path)
        XCTAssertThrowsError(try LSFGResources.validatedComponent(at: root))
    }

    func testLSFGShaderSelectionRejectsTamperingAndFailedImportPreservesPreviousPackage() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support"), components = root.appendingPathComponent("Components")
        try makeLSFGComponentFixture(at: components)
        let original = Data("existing private shader resource fixture".utf8)
        let selected = try writeLSFGFixtureShader(original, support: support)
        let selection = support.appendingPathComponent("LSFG/shader.json")
        let selectionBytes = try Data(contentsOf: selection)
        XCTAssertEqual(try LSFGResources.selectedShader(in: support), selected)
        let empty = root.appendingPathComponent("empty.dll")
        try Data().write(to: empty)
        do {
            try await LSFGResources.importShaderPackage(from: empty, into: support, components: components)
            XCTFail("Empty package should be rejected before a checker is launched")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: selection), selectionBytes)
        XCTAssertEqual(try Data(contentsOf: selected), original)
        XCTAssertEqual(try LSFGResources.selectedShader(in: support), selected)
        try Data("tampered".utf8).write(to: selected)
        XCTAssertThrowsError(try LSFGResources.selectedShader(in: support))
        try JSONEncoder().encode(["sha256": String(repeating: "../", count: 22)])
            .write(to: selection)
        XCTAssertThrowsError(try LSFGResources.selectedShader(in: support))
    }

    func testLSFGImportValidatesStagedBytesAndKeepsOldSelectionOnCheckerFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support"), components = root.appendingPathComponent("Components")
        try makeLSFGComponentFixture(at: components)
        let oldBytes = Data("prior shader package".utf8)
        let oldShader = try writeLSFGFixtureShader(oldBytes, support: support)
        let source = root.appendingPathComponent("user-supplied.dll")
        let candidateBytes = Data("new shader package fixture".utf8)
        try candidateBytes.write(to: source)
        let recorder = LSFGToolInvocationRecorder()
        try await LSFGResources.importShaderPackage(from: source, into: support, components: components,
            toolRunner: { executable, arguments, environment, timeout in
                await recorder.record(executable, arguments, environment, timeout)
                guard arguments.count == 1,
                      try Data(contentsOf: URL(fileURLWithPath: arguments[0])) == candidateBytes else {
                    throw LSFGResources.Failure.invalidShader
                }
                return "Shader image-view checks passed: 2048 bindings across quality, performance, fp16 and hdr\n"
            })
        let calls = await recorder.snapshot()
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.executable, components.appendingPathComponent("shader-check").path)
        XCTAssertEqual(call.timeout, 30)
        XCTAssertTrue(call.environment.isEmpty, "Resource checker receives no game injection variables")
        XCTAssertNotEqual(call.arguments.first, source.path, "Check the staged immutable bytes, not a user file that can change")
        let selected = try LSFGResources.selectedShader(in: support)
        XCTAssertNotEqual(selected, oldShader)
        XCTAssertEqual(try Data(contentsOf: selected), candidateBytes)
        XCTAssertEqual(try Data(contentsOf: oldShader), oldBytes, "A running game may still hold the previous package path")
        let selection = support.appendingPathComponent("LSFG/shader.json")
        let selectionBytes = try Data(contentsOf: selection)
        try Data("broken replacement".utf8).write(to: source)
        do {
            try await LSFGResources.importShaderPackage(from: source, into: support, components: components,
                                                       toolRunner: { _, _, _, _ in "invalid shader resource" })
            XCTFail("A checker without the success receipt cannot replace the selected package")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: selection), selectionBytes)
        XCTAssertEqual(try LSFGResources.selectedShader(in: support), selected)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("LSFG").path)
            .contains(where: { $0.hasPrefix("Import-") }))

        do {
            try await LSFGResources.importShaderPackage(from: source, into: support, components: components,
                                                       toolRunner: { _, _, _, _ in throw CancellationError() })
            XCTFail("Cancelled validation must not install a package")
        } catch is CancellationError {} catch { XCTFail("Cancellation should remain cancellation, got \(error)") }
        XCTAssertEqual(try Data(contentsOf: selection), selectionBytes)
    }

    func testLSFGPreparationRequiresFreshCompletePreflightForExactLaunchResources() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support"), components = root.appendingPathComponent("Components")
        try makeLSFGComponentFixture(at: components)
        let shader = try writeLSFGFixtureShader(Data("private shader fixture".utf8), support: support)
        let wine = root.appendingPathComponent("runtime/bin/wine")
        let gameDriver = root.appendingPathComponent("runtime/lib/libMoltenVK.dylib")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gameDriver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lsfgMachOHeader(fileType: 2).write(to: wine)
        try Data("game Vulkan driver fixture; never dynamically loaded".utf8).write(to: gameDriver)
        let recorder = LSFGToolInvocationRecorder()
        let checked: LSFGResources.ToolRunner = { executable, arguments, environment, timeout in
            await recorder.record(executable, arguments, environment, timeout)
            return "LSFGM_PREFLIGHT v=1 check=warmup status=ok\nLSFGM_PREFLIGHT v=1 status=ok scope=shaders_and_driver version=fixture\n"
        }
        for _ in 0..<2 {
            let result = try await LSFGLaunchEnvironment.prepare(settings: LSFGSettings(enabled: true), wine: wine,
                support: support, session: UUID(), components: components, processManager: ProcessManager(), toolRunner: checked)
            let plan = try XCTUnwrap(result)
            XCTAssertEqual(plan.shader, shader)
            XCTAssertEqual(plan.component.driver, components.appendingPathComponent("libMoltenVK.generator.dylib"))
            XCTAssertEqual(plan.gameDriver, gameDriver)
        }
        let calls = await recorder.snapshot()
        XCTAssertEqual(calls.count, 2, "A prior passing receipt must not skip the next launch's GPU preflight")
        for call in calls {
            XCTAssertEqual(call.executable, components.appendingPathComponent("preflight").path)
            XCTAssertEqual(call.arguments, ["--dll", shader.path, "--driver", components.appendingPathComponent("libMoltenVK.generator.dylib").path, "--warmup"])
            XCTAssertEqual(call.environment, ["XDG_CACHE_HOME": support.appendingPathComponent("LSFG/Cache").path])
            XCTAssertEqual(call.timeout, 60)
        }
        do {
            _ = try await LSFGLaunchEnvironment.prepare(settings: LSFGSettings(enabled: true), wine: wine,
                support: support, session: UUID(), components: components, processManager: ProcessManager(),
                toolRunner: { _, _, _, _ in "LSFGM_PREFLIGHT v=1 check=warmup status=ok\n" })
            XCTFail("A partial success message must not produce a prepared launch plan")
        } catch let error as LSFGResources.Failure {
            guard case .preflight = error else { return XCTFail("Expected preflight failure, got \(error)") }
        }
        do {
            _ = try await LSFGLaunchEnvironment.prepare(settings: LSFGSettings(enabled: true), wine: wine,
                support: support, session: UUID(), components: components, processManager: ProcessManager(),
                toolRunner: { _, _, _, _ in throw CancellationError() })
            XCTFail("Cancelled preflight must not produce a plan")
        } catch is CancellationError {} catch { XCTFail("Cancellation should remain cancellation, got \(error)") }
    }

    /// Explicit opt-in acceptance for the production LaunchServices → universal
    /// GameLauncher → x86_64 Wine → DXMT chain. It runs only the synthetic
    /// executable prepared by Tools/LSFG/test_wine.py, never a located game.
    func testLiveLSFGWineDXMTLaunchServices() async throws {
        let environment = ProcessInfo.processInfo.environment
        func option(_ name: String) -> String? {
            environment[name] ?? environment["TEST_RUNNER_" + name]
        }
        guard let rootPath = option("MIPLAY_LSFG_FIXTURE_ROOT"), !rootPath.isEmpty else {
            throw XCTSkip("Opt in with TEST_RUNNER_MIPLAY_LSFG_FIXTURE_ROOT and TEST_RUNNER_MIPLAY_LSFG_SHADER_DLL")
        }
        let fixtureRoot = URL(fileURLWithPath: rootPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let tmpRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        func contained(_ url: URL, in root: URL) -> Bool {
            url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/")
        }
        guard contained(fixtureRoot, in: tmpRoot),
              FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent(".miplay-lsfg-synthetic-wine-root").path) else {
            return XCTFail("Only a marked synthetic fixture directory under /tmp is accepted")
        }
        let runtime = fixtureRoot.appendingPathComponent("runtime")
        let wine = runtime.appendingPathComponent("bin/wine")
        let server = runtime.appendingPathComponent("bin/wineserver")
        let prefix = fixtureRoot.appendingPathComponent("prefix")
        let executable = fixtureRoot.appendingPathComponent("d3d11_present_fixture.exe")
        guard [runtime, wine, server, prefix, executable].allSatisfy({ contained($0, in: fixtureRoot) }),
              FileManager.default.isExecutableFile(atPath: wine.path),
              FileManager.default.isExecutableFile(atPath: server.path),
              FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c").path),
              FileManager.default.fileExists(atPath: executable.path) else {
            return XCTFail("Synthetic runtime/prefix/executable is missing or escaped its fixture root")
        }
        let shaderPath = try XCTUnwrap(option("MIPLAY_LSFG_SHADER_DLL"), "Supply the user's own shader package for this opt-in test")
        // NSWorkspace overlays its environment on the caller's environment.
        // Removing these keys from our dictionary alone must not count as
        // evidence that Wine is clean. Exercise the actual contaminated path.
        let diagnosticKeys = ["MTL_DEBUG_LAYER", "METAL_DEVICE_WRAPPER_TYPE", "MTL_HUD_ENABLED"]
        let previousDiagnosticValues = diagnosticKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        }
        for key in diagnosticKeys { setenv(key, "1", 1) }
        defer {
            for (key, value) in previousDiagnosticValues {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let sessionRoot = fixtureRoot.appendingPathComponent("launchservices-\(UUID().uuidString)", isDirectory: true)
        let support = sessionRoot.appendingPathComponent("Support", isDirectory: true)
        let temporary = sessionRoot.appendingPathComponent("Temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        print("LSFG_LAUNCHSERVICES_EVIDENCE \(sessionRoot.path)")
        try await LSFGResources.importShaderPackage(from: URL(fileURLWithPath: shaderPath), into: support,
                                                    components: LSFGResources.componentDirectory)
        let bundle = try XCTUnwrap(LaunchCompatibilityEnvironment.prepareAppBundle(
            gameType: .genshinImpact, assetRootURL: support.appendingPathComponent("RuntimeAssets")))
        let launcher = ApplicationLauncher(), processManager = ProcessManager()
        let base = ManagedWineLocale.environment(adding: [
            "WINEPREFIX": prefix.path, "WINEARCH": "win64", "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "WINEDEBUG": "fixme-all,err-unwind", "TMPDIR": temporary.path + "/",
            "XDG_CACHE_HOME": sessionRoot.appendingPathComponent("Cache").path,
            "XDG_CONFIG_HOME": sessionRoot.appendingPathComponent("Config").path
        ])
        var activePID: pid_t?
        do {
            for enabled in [false, true] {
                let caseName = enabled ? "2x" : "off"
                let plan = try await LSFGLaunchEnvironment.prepare(settings: LSFGSettings(enabled: enabled, targetFPS: 60),
                    wine: wine, support: support, session: UUID(), processManager: processManager)
                var overrides = plan?.applying(to: base, entry: .universalLauncher) ?? LSFGLaunchEnvironment.removingInjection(from: base)
                overrides["MIPLAY_LAUNCH_CWD"] = sessionRoot.path
                overrides["MIPLAY_LAUNCH_LOG"] = bundle.logURL.path
                overrides["MIPLAY_LAUNCH_STATUS"] = bundle.statusURL.path
                overrides["MIPLAY_WAIT_WINESERVER"] = server.path
                // Off must not inherit the host's HUD. On explicitly requests
                // it, verifying that the user's HUD survives the same cleanup.
                overrides["MTL_HUD_ENABLED"] = enabled ? "1" : nil
                let pid = try await launcher.launch(bundleURL: bundle.bundleURL,
                    arguments: [wine.path, executable.path, "240", "30", "foreground"],
                    environment: ProcessManager.childEnvironment(overrides: overrides),
                    logURL: bundle.logURL, statusURL: bundle.statusURL)
                activePID = pid
                print("LSFG_LAUNCHSERVICES_PID case=\(caseName) pid=\(pid)")
                try "\(pid)\n".write(to: sessionRoot.appendingPathComponent("\(caseName).pid"), atomically: true, encoding: .utf8)
                let deadline = ContinuousClock.now + .seconds(90)
                while launcher.isRunning(pid: pid), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard !launcher.isRunning(pid: pid) else {
                    throw NSError(domain: "MiPlayLSFGFixture", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Synthetic LaunchServices fixture timed out (\(caseName))"])
                }
                activePID = nil
                let result = launcher.exitResult(logURL: bundle.logURL, statusURL: bundle.statusURL)
                print("LSFG_LAUNCHSERVICES_EXIT case=\(caseName) pid=\(pid) status=\(result.statusCode)")
                try result.output.write(to: sessionRoot.appendingPathComponent("\(caseName)-launch.log"), atomically: true, encoding: .utf8)
                XCTAssertEqual(result.statusCode, 0, result.output)
                XCTAssertFalse(result.terminatedBySignal, result.output)
                XCTAssertTrue(result.output.contains("FIXTURE_DONE presented=240"), "Synthetic DXMT fixture did not finish: \(result.output)")
                XCTAssertTrue(result.output.contains("FIXTURE_ENV MTL_DEBUG_LAYER=<unset>"), result.output)
                XCTAssertTrue(result.output.contains("FIXTURE_ENV METAL_DEVICE_WRAPPER_TYPE=<unset>"), result.output)
                XCTAssertTrue(result.output.contains("FIXTURE_ENV MTL_HUD_ENABLED=\(enabled ? "1" : "<unset>")"), result.output)
                if let plan {
                    let log = try String(contentsOf: plan.log, encoding: .utf8)
                    try log.write(to: sessionRoot.appendingPathComponent("2x-lsfg.log"), atomically: true, encoding: .utf8)
                    func maximum(_ key: String) throws -> Int {
                        let expression = try NSRegularExpression(pattern: "\\b\(key)=(\\d+)")
                        return expression.matches(in: log, range: NSRange(log.startIndex..., in: log))
                            .compactMap { Range($0.range(at: 1), in: log).flatMap { Int(log[$0]) } }.max() ?? 0
                    }
                    XCTAssertTrue(log.contains("state=active"), log)
                    XCTAssertGreaterThan(try maximum("original_displayed"), 0, log)
                    XCTAssertGreaterThan(try maximum("generated_displayed"), 0, log)
                    XCTAssertFalse(log.contains("state=quarantined"), log)
                    XCTAssertFalse(log.contains("MTLDebugCommandBuffer"), "Wine inherited Metal API validation: \(log)")
                } else {
                    XCTAssertFalse(result.output.contains("LSFGM_METAL_STATS"), "Disabled launch unexpectedly loaded LSFG")
                }
                // This server belongs exclusively to the marked synthetic prefix.
                do {
                    _ = try await processManager.launchAndWait(executablePath: server.path, arguments: ["-k"], environment: base, timeout: 15)
                } catch let ProcessManager.ProcessError.exitWithError(code, signal, _) where code == 1 && signal == nil {
                    // The helper waited for this prefix's server to exit. Wine's
                    // -k reports 1 when there is no remaining server to stop.
                }
            }
        } catch {
            if let pid = activePID { try? await launcher.terminate(pid: pid, force: true) }
            _ = try? await processManager.launchAndWait(executablePath: server.path, arguments: ["-k"], environment: base, timeout: 15)
            throw error
        }
    }

    func testManagedWineLocaleOverridesInheritedDeveloperLocale() {
        let inherited = ["LANG": "C.UTF-8", "LC_ALL": "en_US.UTF-8", "LC_CTYPE": "C.UTF-8",
                         "LC_MESSAGES": "en_US.UTF-8", "LANGUAGE": "en_US:en", "PATH": "/usr/bin"]
        let environment = ProcessManager.filteredChildEnvironment(
            base: inherited,
            overrides: ManagedWineLocale.environment(adding: ["WINEPREFIX": "/test/prefix", "DXMT_CONFIG": "test"])
        )
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES"] {
            XCTAssertEqual(environment[key], "zh_CN.UTF-8")
        }
        XCTAssertEqual(environment["LANGUAGE"], "zh_CN:zh")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["WINEPREFIX"], "/test/prefix")
        XCTAssertEqual(environment["DXMT_CONFIG"], "test")
        XCTAssertEqual(ManagedWineLocale.environment(adding: inherited)["LC_ALL"], "zh_CN.UTF-8")
    }

    /// The executable is a shell fixture in a unique temporary directory. It
    /// records Wine requests without running Wine or changing a real prefix.
    func testManagedWineLocaleCoversPrefixPreparationAndPreservesGamePreferences() async throws {
        for alreadyPrepared in [false, true] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runtimeRoot = root.appendingPathComponent("WineVersions")
                .appendingPathComponent(WineVersionManager.fixedRuntimeTag)
            let bin = runtimeRoot.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let prefix = root.appendingPathComponent("WinePrefixes/shared")
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            if alreadyPrepared {
                try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
            }
            let preferences = Data("""
            WINE REGISTRY Version 2
            [Software\\\\miHoYo\\\\\\x539f\\x795e]
            "GENERAL_DATA_h2389025596"=hex:7b,22,64,65,76,69,63,65,4c,61,6e,67,75,61,67,65,54,79,70,65,22,3a,31,2c,22,64,65,76,69,63,65,56,6f,69,63,65,4c,61,6e,67,75,61,67,65,54,79,70,65,22,3a,31,7d,00
            "unrelated_setting"="preserve"
            """.utf8)
            let registry = prefix.appendingPathComponent("user.reg")
            if alreadyPrepared { try preferences.write(to: registry) }
            let record = root.appendingPathComponent("commands")
            let wine = bin.appendingPathComponent("wine")
            try """
            #!/bin/sh
            printf '%s|%s|%s|%s|%s|%s|%s\\n' "$*" "$LANG" "$LC_ALL" "$LC_CTYPE" "$LC_MESSAGES" "$LANGUAGE" "$WINEPREFIX" >> \(GameLaunchPreparation.shellQuote(record.path))
            case "$1" in
              --version) printf 'wine-fixture\\n' ;;
              wineboot) /bin/mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices" ;;
            esac
            """.write(to: wine, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
            let provider = WineRuntimeProvider(processManager: ProcessManager(), fileSystemRepository: GameFileSystemRepository(appSupportDirectory: root))
            let runtime = ManagedWineRuntime(tagName: WineVersionManager.fixedRuntimeTag, rootURL: runtimeRoot)
            let prepared = try await provider.prepareSharedPrefix(runtime: runtime)
            XCTAssertEqual(prepared.path, prefix.path)
            let calls = try String(contentsOf: record, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
            XCTAssertTrue(calls.contains { $0.hasPrefix("reg add HKCU\\Software\\Wine\\Mac Driver") })
            XCTAssertEqual(calls.contains { $0.hasPrefix("wineboot ") }, !alreadyPrepared)
            for call in calls {
                let fields = call.components(separatedBy: "|")
                XCTAssertEqual(Array(fields[1...5]), ["zh_CN.UTF-8", "zh_CN.UTF-8", "zh_CN.UTF-8", "zh_CN.UTF-8", "zh_CN:zh"])
                XCTAssertFalse(fields[0].contains("GENERAL_DATA"))
                XCTAssertFalse(fields[0].contains("Control Panel"))
            }
            if alreadyPrepared { XCTAssertEqual(try Data(contentsOf: registry), preferences) }
        }
    }

    func testHomeInstallAllowsNewDirectoryAfterInterruptionAndBlocksActiveTasks() {
        let type = GameType.zenlessZoneZero
        var game = Game(id: type.rawValue, type: type, location: nil, state: .notInstalled,
                        version: nil, lastLaunchDate: nil, solutionApplications: [])
        var task = ScheduledTask(type: .gameInstall, gameId: game.id, context: [
            "installBookmark": Data([1]).base64EncodedString(), "installPath": "/previous-directory"
        ])
        for state in [ScheduledTaskState.failed, .cancelled] {
            task.state = state
            XCTAssertTrue(GameDownloadPresentation.canResume(task, for: game))
            XCTAssertTrue(LibraryViewModel.canStartInstall(game: game, task: task, isSubmitting: false, hasRecovery: false),
                          "用户可选择新目录，原任务仍可继续")
        }
        for state in [ScheduledTaskState.pending, .running] {
            task.state = state
            XCTAssertFalse(LibraryViewModel.canStartInstall(game: game, task: task, isSubmitting: false, hasRecovery: false))
        }
        XCTAssertFalse(LibraryViewModel.canStartInstall(game: game, task: nil, isSubmitting: true, hasRecovery: false))
        XCTAssertFalse(LibraryViewModel.canStartInstall(game: game, task: nil, isSubmitting: false, hasRecovery: true))
        game.state = .installed
        XCTAssertFalse(LibraryViewModel.canStartInstall(game: game, task: nil, isSubmitting: false, hasRecovery: false))
        XCTAssertTrue(LibraryViewModel.canStartInstall(game: nil, task: nil, isSubmitting: false, hasRecovery: false),
                      "旧游戏库中缺失的游戏也可安装")
    }

    func testMissingOrRemovedGameCanBeRegisteredForHomeActionsWithoutChangingOtherGames() async throws {
        let existing = Game(id: GameType.genshinImpact.rawValue, type: .genshinImpact, location: nil,
                            state: .notInstalled, version: "existing-version", lastLaunchDate: nil, solutionApplications: [])
        let fixture = try await makeScheduler(games: [existing])
        let model = LibraryViewModel(gameRegistry: fixture.registry, launchOrchestrator: fixture.launchOrchestrator,
                                     persistenceStore: fixture.persistence, taskScheduler: fixture.scheduler,
                                     logWriter: fixture.logger)
        await model.refreshGames()
        XCTAssertTrue(model.canInstallGame(for: GameType.zenlessZoneZero.rawValue))
        XCTAssertFalse(model.canInstallGame(for: "unknown-game"))
        model.selectGame(id: GameType.zenlessZoneZero.rawValue)
        await model.refreshGames()
        XCTAssertNil(model.selectedGame)
        XCTAssertEqual(model.selectedGameId, GameType.zenlessZoneZero.rawValue,
                       "刷新游戏库时必须保留缺失游戏的选择")

        let created = try await model.ensureGameRegistered(type: .zenlessZoneZero)
        XCTAssertEqual(created.state, .notInstalled)
        XCTAssertEqual(created.type, .zenlessZoneZero)
        let data = try await fixture.persistence.readAppData()
        XCTAssertEqual(data.games.first(where: { $0.type == .genshinImpact })?.version, "existing-version")
        XCTAssertEqual(data.games.filter { $0.type == .zenlessZoneZero }.count, 1)

        try await fixture.registry.removeGame(id: created.id)
        await model.refreshGames()
        XCTAssertTrue(model.canInstallGame(for: created.id))
        let recreated = try await model.ensureGameRegistered(type: .zenlessZoneZero)
        XCTAssertEqual(recreated.id, created.id)
        let afterRecreation = try await fixture.persistence.readAppData()
        XCTAssertEqual(afterRecreation.games.first(where: { $0.type == .genshinImpact })?.version, "existing-version")
    }

    func testRecoveryOnlyTaskDoesNotPretendToBeDownloadOrRequireVersion() {
        let type = GameType.zenlessZoneZero
        let location = GameLocation(gameID: type.rawValue, bookmarkData: Data([1]), lastKnownPath: "/game", scope: .readWrite, resolutionState: .resolvable)
        var game = Game(id: type.rawValue, type: type, location: location, state: .gameUpdating, version: nil, lastLaunchDate: nil, solutionApplications: [])
        var task = ScheduledTask(type: .gameUpdate, gameId: game.id, context: ["recoveryOnly": "true"])
        task.state = .failed
        XCTAssertFalse(GameDownloadPresentation.canResume(task, for: game))
        task.state = .completed
        task.outcome = "gameRecovered"
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        game.state = .installed
        XCTAssertTrue(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        task.outcome = "gameUpdated"
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: game))
    }

    func testBuiltInLaunchProfilesRequireExplicitPerGameCompatibility() {
        let genshin = LaunchCompatibilityEnvironment.profile(for: .genshinImpact)
        XCTAssertEqual(genshin.route, .steamStub)
        XCTAssertTrue(genshin.stagesGameDriver)
        XCTAssertFalse(genshin.cleansWebviewRegistry)
        XCTAssertFalse(genshin.requiresVendorExtensions)
        XCTAssertFalse(genshin.usesStarRailVendorRegistry)
        XCTAssertFalse(genshin.usesStarRailNetworkWindow)

        let starRail = LaunchCompatibilityEnvironment.profile(for: .honkaiStarRail)
        XCTAssertEqual(starRail.route, .jadeite)
        XCTAssertFalse(starRail.stagesGameDriver)
        XCTAssertTrue(starRail.cleansWebviewRegistry)
        XCTAssertTrue(starRail.requiresVendorExtensions)
        XCTAssertTrue(starRail.usesStarRailVendorRegistry)
        XCTAssertTrue(starRail.usesStarRailNetworkWindow)

        let zenless = LaunchCompatibilityEnvironment.profile(for: .zenlessZoneZero)
        XCTAssertEqual(zenless.route, .steamStub)
        XCTAssertTrue(zenless.stagesGameDriver)
        XCTAssertTrue(zenless.cleansWebviewRegistry)
        XCTAssertFalse(zenless.requiresVendorExtensions)
        XCTAssertFalse(zenless.usesStarRailVendorRegistry)
        XCTAssertFalse(zenless.usesStarRailNetworkWindow)
    }

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
        XCTAssertEqual(enabled.vendorExtensionEnvironment(assetsReady: true)["DXMT_ENABLE_NVEXT"], "1")
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
            "MIPLAY_ALLOWED_RUNTIME_VARIABLES": "MTL_DEBUG_LAYER",
            "HOME": "/Users/tester",
        ]
        let filtered = ProcessManager.filteredChildEnvironment(base: base)
        XCTAssertNil(filtered["MTL_DEBUG_LAYER"])
        XCTAssertNil(filtered["METAL_DEVICE_WRAPPER_TYPE"])
        XCTAssertNil(filtered["MTL_CAPTURE_ENABLED"])
        XCTAssertNil(filtered[ApplicationLauncher.runtimeVariableAllowlistKey])
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

    func testStartupChecksLocatedGameEvenWhenLegacyPreferenceWasDisabled() async throws {
        let key = "gameUpdateNotificationsEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("YuanShen.exe"))
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))
        let location = try GameFileSystemRepository().makeGameLocation(
            gameID: GameType.genshinImpact.rawValue, for: directory
        )
        let game = Game(id: GameType.genshinImpact.rawValue, type: .genshinImpact,
                        location: location, state: .installed, version: nil,
                        lastLaunchDate: nil, solutionApplications: [])
        let fixture = try await makeScheduler(games: [game], latestVersions: [.genshinImpact: "1.3.0"])
        let viewModel = LibraryViewModel(
            gameRegistry: fixture.registry,
            launchOrchestrator: fixture.launchOrchestrator,
            backgroundMediaService: nil,
            persistenceStore: fixture.persistence,
            taskScheduler: fixture.scheduler,
            logWriter: fixture.logger
        )

        await viewModel.initialize()
        let tasks = await fixture.scheduler.allTaskSnapshots()
        let check = try XCTUnwrap(tasks.first { $0.type == .versionCheck && $0.gameId == game.id })
        let result = try await waitForTask(check.id, scheduler: fixture.scheduler)
        XCTAssertEqual(result.state, .completed)
    }

    func testWinePreparationRateLimitFailureHasReadableMessage() {
        let detail = "Wine 来源 officialGitHub 的 API 访问被拒绝: forbidden; response={\"message\":\"API rate limit exceeded for 192.0.2.1\"}; rateLimitRemaining=0; rateLimitReset=1793609721"
        let message = WinePreparationFailurePresentation.message(detail)
        XCTAssertTrue(message.contains("GitHub 请求次数已达上限"))
        XCTAssertTrue(message.contains("稍后重试"))
        XCTAssertFalse(message.contains("192.0.2.1"))
        XCTAssertEqual(WinePreparationFailurePresentation.message("磁盘空间不足"), "磁盘空间不足")
        XCTAssertTrue(WinePreparationFailurePresentation.message("forbidden; rateLimitRemaining=0").contains("已达上限"))
    }

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
