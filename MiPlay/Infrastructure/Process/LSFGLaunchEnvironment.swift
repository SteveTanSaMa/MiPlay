import Foundation

nonisolated enum LSFGLaunchEnvironment {
    enum Entry { case directWine, universalLauncher }

    struct Plan: Sendable {
        let component: LSFGResources.Component
        let shader: URL
        let gameDriver: URL
        let settings: LSFGSettings
        let cache: URL
        let log: URL

        func applying(to base: [String: String], entry: Entry) -> [String: String] {
            var result = LSFGLaunchEnvironment.removingInjection(from: base)
            result[entry == .directWine ? "DYLD_INSERT_LIBRARIES" : "MIPLAY_LSFG_LIBRARY"] = component.library.path
            result["LSFGM_METAL"] = "1"
            result["LSFGM_ENV"] = "1"
            result["LSFGM_MULTIPLIER"] = String(settings.multiplier)
            result["LSFGM_FLOW_SCALE"] = String(settings.flowScale)
            result["LSFGM_PERFORMANCE_MODE"] = settings.performanceMode ? "1" : "0"
            // Treat the multiplier as a cap; fixed mode ignores TARGET_FPS and
            // always generates every slot, even when it exceeds display demand.
            result["LSFGM_PACING_MODE"] = "adaptive"
            // The current worker relies on synchronized presentation to space
            // generated frames. Unsynchronized submission can overwrite them
            // in bursts; keep this independent from the game's own VSync.
            result["LSFGM_OVERRIDE_PRESENT_MODE"] = "1"
            if let fps = settings.targetFPS { result["LSFGM_TARGET_FPS"] = String(fps) }
            result["LSFGM_DLL_PATH"] = shader.path
            // Wine can query Vulkan even when the game renders through DXMT.
            // Forward those calls to Wine's own driver, keeping the newer
            // private compute driver independent from the game's graphics stack.
            result["LSFGM_MOLTENVK"] = gameDriver.path
            result["LSFGM_GENERATOR_MOLTENVK"] = component.driver.path
            result["LSFGM_STATS"] = "1"
            result["LSFGM_LATENCY"] = "1"
            result["LSFGM_LOG_FILE"] = log.path
            result["XDG_CACHE_HOME"] = cache.path
            return result
        }
    }

    static func removingInjection(from environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !key.hasPrefix("LSFGM_") && !key.hasPrefix("MIPLAY_LSFG_") &&
                !key.hasPrefix("DYLD_") && key != "DISABLE_LSFGM"
        }
    }

    /// Disabled is a no-I/O path. Preflight uses exactly the shader and driver
    /// that the subsequent Wine child receives, on every enabled launch.
    static func prepare(settings: LSFGSettings, wine: URL, support: URL,
                        session: UUID, components: URL = LSFGResources.componentDirectory,
                        processManager: ProcessManager,
                        toolRunner: LSFGResources.ToolRunner? = nil) async throws -> Plan? {
        guard settings.enabled else { return nil }
        _ = try settings.validated()
        try LSFGResources.requireX86MachO(wine, fileType: 2)
        let component = try LSFGResources.validatedComponent(at: components)
        let shader = try LSFGResources.selectedShader(in: support)
        let gameDriver = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/libMoltenVK.dylib")
        guard FileManager.default.fileExists(atPath: gameDriver.path) else {
            throw LSFGResources.Failure.invalidComponent("Wine MoltenVK 驱动缺失")
        }
        let root = support.appendingPathComponent("LSFG", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        for url in [cache, logs] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let log = logs.appendingPathComponent("\(session.uuidString).log")
        do {
            let arguments = ["--dll", shader.path, "--driver", component.driver.path, "--warmup"]
            let environment = ["XDG_CACHE_HOME": cache.path]
            let output: String
            if let toolRunner {
                output = try await toolRunner(component.preflight.path, arguments, environment, 60)
            } else {
                output = try await processManager.launchAndWait(
                    executablePath: component.preflight.path, arguments: arguments,
                    environment: environment, timeout: 60)
            }
            try output.write(to: logs.appendingPathComponent("\(session.uuidString)-preflight.log"), atomically: true, encoding: .utf8)
            guard output.contains("check=warmup status=ok"), output.contains("status=ok scope=shaders_and_driver") else {
                throw LSFGResources.Failure.preflight("未收到完整的 GPU 预检结果")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let ProcessManager.ProcessError.exitWithError(_, _, output) {
            try? output.write(to: logs.appendingPathComponent("\(session.uuidString)-preflight.log"), atomically: true, encoding: .utf8)
            let reason = output.split(whereSeparator: \.isNewline)
                .last(where: { $0.contains("LSFGM_PREFLIGHT") && $0.contains("status=error") })
                .map(String.init) ?? "预检进程异常退出，请查看 LSFG 日志。"
            throw LSFGResources.Failure.preflight(reason)
        }
        catch let failure as LSFGResources.Failure { throw failure }
        catch {
            throw LSFGResources.Failure.preflight(error.localizedDescription)
        }
        try Task.checkCancellation()
        return Plan(component: component, shader: shader, gameDriver: gameDriver,
                    settings: settings, cache: cache, log: log)
    }
}

extension WineVersionManager {
    func lsfgSettings(for gameID: String) async throws -> LSFGSettings {
        await LSFGSettingsPersistence.flush(store: persistenceStore, gameID: gameID)
        try Task.checkCancellation()
        return try await persistenceStore.readAppData().perGameSettings[gameID]?.lsfg ?? LSFGSettings()
    }
}
