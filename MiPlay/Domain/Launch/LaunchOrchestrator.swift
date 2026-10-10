//
//  LaunchOrchestrator.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design -> Service Contract -> LaunchOrchestrator
// Source: Architecture Design -> ADR 007 -> running requires process health confirmation

/// Coordinates preflight, Wine prefix preparation, process health confirmation and
/// the committed Game state transition. Process and file objects never escape here.
public actor LaunchOrchestrator {
    public enum LaunchError: Error, LocalizedError, Sendable {
        case validationFailed([PreLaunchValidator.ValidationError])
        case wineEnvironmentError(String)
        case processLaunchFailed(String)
        case processTimeout(String)
        case processExited(exitCode: Int32, signal: Int32? = nil, output: String)
        case gameAlreadyRunning(String)
        case permissionDenied(String)
        case persistenceFailed(String)
        case recoveryRequired(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .validationFailed(let errors): return "启动校验失败: \(errors.map { $0.localizedDescription }.joined(separator: "; "))"
            case .wineEnvironmentError(let detail): return "Wine 环境错误: \(detail)"
            case .processLaunchFailed(let detail): return "进程启动失败: \(detail)"
            case .processTimeout(let detail): return "进程确认超时: \(detail)"
            case .processExited(let code, let signal, let output):
                return GameExitDiagnostic.summary(
                    statusCode: signal ?? code,
                    terminatedBySignal: signal != nil,
                    output: output
                )
            case .gameAlreadyRunning(let name): return "\(name) 已在运行"
            case .permissionDenied(let detail): return "游戏目录权限未确认: \(detail)"
            case .persistenceFailed(let detail): return "启动结果保存失败: \(detail)"
            case .recoveryRequired(let detail): return "启动清理未确认: \(detail)"
            case .cancelled: return "启动已取消，清理已确认"
            }
        }
    }

    public enum LaunchPhase: Sendable, Equatable {
        case validating
        case preparingWine
        case launching
        case confirming
        case completed
        case failed(String)
    }

    public enum LaunchResult: Sendable {
        case success(processId: UUID)
        case failure(LaunchError)
    }

    private let preLaunchValidator: PreLaunchValidator
    private let wineRuntimeProvider: WineRuntimeProvider
    private let wineVersionManager: WineVersionManager
    private let processManager: ProcessManager
    private let performanceOptionManager: PerformanceOptionManager
    private let gameRegistry: GameRegistry
    private let fileSystemRepository: GameFileSystemRepository
    private let logWriter: LogWriter
    private let applicationLauncher: ApplicationLauncher

    /// 一次通过 LaunchServices 启动的具名游戏应用（Dock/强制退出以游戏自身名字注册）。
    private struct ActiveApplication: Sendable {
        let sessionID: UUID
        let pid: pid_t
        let logURL: URL
        let statusURL: URL
    }

    private var currentLaunchProcessID: UUID?
    private var currentGameID: String?
    private var cancellationRequested = false
    private var activeSecurityScopes: [UUID: SecurityScopedAccess] = [:]
    private var activeSharedPrefixLease: SharedWinePrefixLease?
    private var activeManagedRuntime: ManagedWineRuntime?
    private var activeStagedGameFiles: [LaunchCompatibilityEnvironment.StagedGameFile] = []
    private var activeApplication: ActiveApplication?
    private var processMonitorTask: (sessionID: UUID, task: Task<Void, Never>)?

    public init(
        preLaunchValidator: PreLaunchValidator,
        wineRuntimeProvider: WineRuntimeProvider,
        wineVersionManager: WineVersionManager,
        processManager: ProcessManager,
        performanceOptionManager: PerformanceOptionManager,
        gameRegistry: GameRegistry,
        fileSystemRepository: GameFileSystemRepository? = nil,
        logWriter: LogWriter,
        applicationLauncher: ApplicationLauncher = ApplicationLauncher()
    ) {
        self.preLaunchValidator = preLaunchValidator
        self.wineRuntimeProvider = wineRuntimeProvider
        self.wineVersionManager = wineVersionManager
        self.processManager = processManager
        self.performanceOptionManager = performanceOptionManager
        self.gameRegistry = gameRegistry
        self.fileSystemRepository = fileSystemRepository ?? GameFileSystemRepository()
        self.logWriter = logWriter
        self.applicationLauncher = applicationLauncher
        self.activeSharedPrefixLease = nil
        self.activeManagedRuntime = nil
    }

    public func launch(game: Game) async -> LaunchResult {
        guard currentLaunchProcessID == nil, currentGameID == nil else {
            return .failure(.gameAlreadyRunning(game.type.displayName))
        }
        currentGameID = game.id
        cancellationRequested = false
        let operationID = UUID()
        // 启动耗时埋点：各阶段事件带 `durationMs`（从 launch.start 起算），
        // 用于比较优化前后的真实启动开销（日志时间戳只有秒级精度）。
        let launchStartedAt = ContinuousClock.now
        func elapsedMilliseconds() -> String {
            let elapsed = ContinuousClock.now - launchStartedAt
            let milliseconds = elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
            return String(milliseconds)
        }
        defer {
            if currentLaunchProcessID == nil {
                currentGameID = nil
            }
        }

        await logWriter.info("开始启动游戏: \(game.type.displayName)", module: "LaunchOrchestrator")
        await logWriter.record(.init(
            level: .info,
            module: "LaunchOrchestrator",
            eventName: "launch.start",
            operationID: operationID,
            gameID: game.id,
            phase: "validation",
            result: "inProgress",
            messageCode: "launch.started"
        ))

        let validation = await preLaunchValidator.validate(game: game)
        guard validation.isPassed else {
            await logWriter.error("启动校验未通过", module: "LaunchOrchestrator")
            await logWriter.record(.init(
                level: .error,
                module: "LaunchOrchestrator",
                eventName: "launch.preflight",
                operationID: operationID,
                gameID: game.id,
                phase: "validation",
                result: "failed",
                errorCategory: "permissionDenied",
                messageCode: "launch.preflight_failed"
            ))
            return await failLaunch(
                gameID: game.id,
                error: .validationFailed(validation.errors)
            )
        }
        if cancellationRequested { return .failure(.cancelled) }

        guard let location = game.location, location.bookmarkData != nil else {
            return await failLaunch(
                gameID: game.id,
                error: .permissionDenied("没有有效 security-scoped bookmark")
            )
        }

        do {
            try await gameRegistry.transitionGame(id: game.id, to: .launching)
        } catch {
            return .failure(.persistenceFailed(error.localizedDescription))
        }

        do {
            let scopedAccess = try fileSystemRepository.acquireSecurityScopedAccess(location)
            var processID: UUID?
            do {
                // Persist the refreshed bookmark before starting the child. The
                // scope remains held until the process exits or cleanup confirms
                // termination.
                if scopedAccess.resolvedLocation.requiresPersistenceUpdate(from: location) {
                    try await gameRegistry.updateResolvedLocation(
                        id: game.id,
                        location: scopedAccess.resolvedLocation
                    )
                }

                let resolvedURL = scopedAccess.url
                try Task.checkCancellation()
                guard !isCancellationRequested() else { throw LaunchError.cancelled }

                await logWriter.info("准备 Wine 环境: \(game.type.displayName)", module: "LaunchOrchestrator")
                guard let runtime = await wineVersionManager.validatedRuntime() else {
                    throw LaunchError.wineEnvironmentError("没有已验证的 Wine runtime")
                }
                activeManagedRuntime = runtime
                let prefixLease = try await wineVersionManager.acquireSharedPrefixLease()
                activeSharedPrefixLease = prefixLease
                let wineBinary = try await wineRuntimeProvider.load(runtime: runtime).path
                let prefix = try await wineRuntimeProvider.prepareSharedPrefix(
                    runtime: runtime,
                    lease: prefixLease
                ).path

                guard let executablePath = game.type.firstExistingExecutable(at: resolvedURL.path) else {
                    throw LaunchError.processLaunchFailed("未找到游戏可执行文件")
                }

                // Source: Docs/05-implementation/implementation-notes.md
                // -> Launch Compatibility Environment -> staged before spawn.
                let environmentSettings = await wineVersionManager.gameEnvironmentSettings()
                let wantsVendorExtensions = (environmentSettings.dlssCompatibility || game.type == .honkaiStarRail)
                    && GameEnvironmentSettings.supportsDLSSCompatibility
                let staging = LaunchCompatibilityEnvironment.stage(
                    gameType: game.type,
                    gameDirectory: URL(fileURLWithPath: resolvedURL.path, isDirectory: true),
                    prefixURL: URL(fileURLWithPath: prefix, isDirectory: true),
                    runtimeRootURL: runtime.rootURL,
                    enableVendorExtensions: wantsVendorExtensions
                )
                activeStagedGameFiles = staging.stagedGameFiles
                let missingLaunchAssets = LaunchCompatibilityEnvironment.missingRequiredLaunchAssets(for: game.type, staging: staging)
                guard missingLaunchAssets.isEmpty else {
                    throw LaunchError.wineEnvironmentError("启动兼容组件缺失或安装失败: \(missingLaunchAssets.joined(separator: ", "))")
                }
                if game.type == .honkaiStarRail, wantsVendorExtensions, !staging.vendorExtensionsReady {
                    throw LaunchError.wineEnvironmentError("崩铁所需的 NV 扩展组件安装失败")
                }
                if game.type != .genshinImpact {
                    try await GameLaunchPreparation.fixWebview(gameType: game.type, wineBinary: wineBinary, prefix: prefix, processManager: processManager)
                }
                if game.type == .honkaiStarRail, staging.vendorExtensionsReady {
                    try await GameLaunchPreparation.prepareStarRailVendorRegistry(wineBinary: wineBinary, prefix: prefix, processManager: processManager)
                }
                await logWriter.record(.init(
                    level: staging.missingAssetNames.isEmpty ? .info : .warning,
                    module: "LaunchOrchestrator",
                    eventName: "launch.compatibility",
                    operationID: operationID,
                    gameID: game.id,
                    phase: "staged",
                    result: staging.missingAssetNames.isEmpty ? "completed" : "unavailable",
                    errorCategory: staging.missingAssetNames.isEmpty ? "none" : "resourceNotFound",
                    messageCode: "launch.compatibility_staged",
                    fields: [
                        "stagedFileCount": String(staging.stagedFileCount),
                        "missingAssetCount": String(staging.missingAssetNames.count),
                        // 资产来源（bundledRuntimeAssets = 随包资源；干净安装据此确认）
                        "sourceID": staging.assetSource,
                        "durationMs": elapsedMilliseconds()
                    ]
                ))

                if wantsVendorExtensions {
                    await logWriter.record(.init(
                        level: staging.vendorExtensionsReady ? .info : .warning,
                        module: "LaunchOrchestrator",
                        eventName: "launch.nvext",
                        operationID: operationID,
                        gameID: game.id,
                        phase: "prepared",
                        result: staging.vendorExtensionsReady ? "completed" : "unavailable",
                        messageCode: staging.vendorExtensionsReady ? "launch.nvext_prepared" : "launch.nvext_unavailable",
                        fields: ["reasonCode": staging.vendorExtensionsReady ? "assetsReady" : "unsupportedHostOrMissingAssets"]
                    ))
                }

                let invocation = LaunchCompatibilityEnvironment.launchInvocation(
                    gameType: game.type,
                    executablePath: executablePath,
                    prefixURL: URL(fileURLWithPath: prefix, isDirectory: true)
                )
                let options = await performanceOptionManager.getOptionsForLaunch(gameId: game.id)
                let arguments = [invocation.program] + invocation.arguments + options.flatMap { $0.launchArguments ?? [] }
                var environment = [
                    "WINEPREFIX": prefix,
                    "WINEDLLOVERRIDES": "winemenubuilder.exe=d"
                ]
                let server = runtime.rootURL.appendingPathComponent("bin/wineserver")
                if FileManager.default.isExecutableFile(atPath: server.path) {
                    environment["MIPLAY_WAIT_WINESERVER"] = server.path
                }
                for (key, value) in LaunchCompatibilityEnvironment.additionalEnvironment(for: game.type) {
                    environment[key] = value
                }
                // 性能选项的固定环境变量与 `{value}` 模板（如 DXMT 的
                // `d3d11.metalSpatialUpscaleFactor`）统一在此展开。
                for (key, value) in PerformanceOption.launchEnvironment(for: options) {
                    if key == "DXMT_CONFIG", let compatibilityConfig = environment[key] {
                        environment[key] = compatibilityConfig + value
                    } else {
                        environment[key] = value
                    }
                }
                // 应用级游戏运行设置（通用设置页）：Metal HUD 等环境变量在此注入；
                // Retina / 左 Command 通过准备 prefix 时写注册表生效。
                for (key, value) in environmentSettings.environmentVariables {
                    environment[key] = value
                }
                var vendorSettings = environmentSettings
                if game.type == .honkaiStarRail { vendorSettings.dlssCompatibility = true }
                for (key, value) in vendorSettings.vendorExtensionEnvironment(assetsReady: staging.vendorExtensionsReady) {
                    environment[key] = value
                }

                if game.type == .honkaiStarRail {
                    try await GameLaunchPreparation.beginStarRailNetworkWindow(processManager: processManager)
                    try Task.checkCancellation()
                }
                // Xcode 注入的 `MTL_*` / `METAL_*`（Metal API 校验、帧捕获等）
                // 会被 ProcessManager 在建子进程时剔除；这里记录一次剔除事实，
                // 便于从日志判断游戏是否运行在调试环境里。
                let developmentOnlyVariables = ProcessManager.developmentOnlyMetalVariables(
                    in: ProcessInfo.processInfo.environment
                )
                if !developmentOnlyVariables.isEmpty {
                    await logWriter.record(.init(
                        level: .info,
                        module: "LaunchOrchestrator",
                        eventName: "launch.environment",
                        operationID: operationID,
                        gameID: game.id,
                        phase: "sanitized",
                        result: "completed",
                        messageCode: "launch.environment_sanitized",
                        fields: [
                            "reasonCode": "metalDebugVariablesRemoved",
                            "itemCount": String(developmentOnlyVariables.count)
                        ]
                    ))
                }

                await logWriter.info("执行 Wine binary 启动游戏进程", module: "LaunchOrchestrator")
                let supportDirectory = await fileSystemRepository.appSupportDirectory()
                let appBundle = LaunchCompatibilityEnvironment.prepareAppBundle(
                    gameType: game.type,
                    assetRootURL: supportDirectory.appendingPathComponent("RuntimeAssets", isDirectory: true)
                )
                var applicationLaunch: (bundle: LaunchCompatibilityEnvironment.LaunchAppBundle, pid: pid_t)?
                if let appBundle, await isManagedRuntimeLayout(runtime.rootURL) {
                    // 与直接子进程路径共用同一个环境边界（剔除开发调试用的
                    // Metal 变量），再补上 GameLauncher 需要的三个路径。
                    var environmentOverrides = environment
                    environmentOverrides["MIPLAY_LAUNCH_LOG"] = appBundle.logURL.path
                    environmentOverrides["MIPLAY_LAUNCH_STATUS"] = appBundle.statusURL.path
                    environmentOverrides["MIPLAY_LAUNCH_CWD"] = resolvedURL.path
                    let launchEnvironment = ProcessManager.childEnvironment(overrides: environmentOverrides)
                    do {
                        let applicationPid = try await applicationLauncher.launch(
                            bundleURL: appBundle.bundleURL,
                            arguments: [wineBinary] + arguments,
                            environment: launchEnvironment,
                            logURL: appBundle.logURL,
                            statusURL: appBundle.statusURL
                        )
                        applicationLaunch = (appBundle, applicationPid)
                    } catch {
                        // 具名应用启动不可用（仅影响进程命名）：回退到直接子进程路径。
                        await logWriter.warning(
                            "具名应用启动不可用，回退直接子进程启动: \(error.localizedDescription)",
                            module: "LaunchOrchestrator"
                        )
                    }
                }

                if let applicationLaunch {
                    // 具名 bundle + LaunchServices：游戏在 Dock / 强制退出中以
                    // 自身名字注册，而不是归入 MiPlay 名下。
                    let sessionID = UUID()
                    activeApplication = ActiveApplication(
                        sessionID: sessionID,
                        pid: applicationLaunch.pid,
                        logURL: applicationLaunch.bundle.logURL,
                        statusURL: applicationLaunch.bundle.statusURL
                    )
                    await logWriter.record(.init(
                        level: .info,
                        module: "LaunchOrchestrator",
                        eventName: "launch.process",
                        operationID: operationID,
                        gameID: game.id,
                        phase: "processCreated",
                        result: "started",
                        messageCode: "launch.process_created",
                        fields: ["launchMode": "applicationBundle", "durationMs": elapsedMilliseconds()]
                    ))
                    processID = sessionID
                    setCurrentProcess(sessionID)
                    activeSecurityScopes[sessionID] = scopedAccess
                    // LaunchServices 已确认应用在运行；若它在确认后立刻结束，
                    // 由退出事实路径（monitorProcess）提交，不在这里重复判定。
                } else {
                    // The direct ProcessManager fallback retains the same child
                    // lifetime boundary as the named LaunchServices bundle.
                    let helper = Bundle.main.resourceURL?.appendingPathComponent("GameLauncher")
                    let useHelper = environment["MIPLAY_WAIT_WINESERVER"] != nil && helper.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true
                    let launchedProcessID = try await processManager.launch(
                        executablePath: useHelper ? helper!.path : wineBinary,
                        arguments: useHelper ? [wineBinary] + arguments : arguments,
                        environment: environment,
                        workingDirectory: resolvedURL.path,
                        captureOutput: true
                    )
                    await logWriter.record(.init(
                        level: .info,
                        module: "LaunchOrchestrator",
                        eventName: "launch.process",
                        operationID: operationID,
                        gameID: game.id,
                        phase: "processCreated",
                        result: "started",
                        messageCode: "launch.process_created"
                    ))
                    processID = launchedProcessID
                    setCurrentProcess(launchedProcessID)
                    activeSecurityScopes[launchedProcessID] = scopedAccess
                    do {
                        try await processManager.waitUntilRunning(processID: launchedProcessID, timeout: 10)
                    } catch {
                        do {
                            _ = try await processManager.terminateAndWait(
                                processID: launchedProcessID,
                                force: true,
                                timeout: 5
                            )
                            activeSecurityScopes.removeValue(forKey: launchedProcessID)?.stop()
                        } catch {
                            // Keep the scope retained while termination is unconfirmed.
                            throw LaunchError.recoveryRequired(error.localizedDescription)
                        }
                        throw error
                    }
                }
            } catch {
                if let processID, activeSecurityScopes[processID] == nil { scopedAccess.stop() }
                if processID == nil {
                    do {
                        try await releaseSharedPrefixLease()
                    } catch {
                        throw LaunchError.recoveryRequired(
                            "启动准备失败，且共享 prefix lease 释放未确认: \(error.localizedDescription)"
                        )
                    }
                }
                throw error
            }

            guard let processID else {
                throw LaunchError.processLaunchFailed("启动进程标识缺失")
            }

            if cancellationRequested {
                try await cleanup(processID: processID, gameID: game.id)
                return .failure(.cancelled)
            }

            do {
                try await gameRegistry.recordLaunchConfirmed(id: game.id, date: Date())
            } catch {
                do { try await cleanup(processID: processID, gameID: game.id) }
                catch let cleanupError { return .failure(.recoveryRequired(cleanupError.localizedDescription)) }
                return .failure(.persistenceFailed(error.localizedDescription))
            }

            await logWriter.info("已确认游戏进程正在运行: \(game.type.displayName)", module: "LaunchOrchestrator")
            await logWriter.record(.init(
                level: .info,
                module: "LaunchOrchestrator",
                eventName: "launch.process",
                operationID: operationID,
                gameID: game.id,
                phase: "healthConfirmed",
                result: "completed",
                messageCode: "launch.running_confirmed",
                fields: ["launchMode": "applicationBundle", "durationMs": elapsedMilliseconds()]
            ))
            processMonitorTask = (processID, Task { [weak self] in
                await self?.monitorProcess(processID: processID, game: game)
            })
            return .success(processId: processID)
        } catch is CancellationError {
            return await cancelAfterFailure(gameID: game.id)
        } catch let error as LaunchError {
            return await failLaunch(gameID: game.id, error: error)
        } catch let error as ProcessManager.ProcessError {
            switch error {
            case .timeout(let detail): return await failLaunch(gameID: game.id, error: .processTimeout(detail))
            case .exitWithError(let code, let signal, let output):
                return await failLaunch(
                    gameID: game.id,
                    error: .processExited(exitCode: code, signal: signal, output: output)
                )
            case .permissionDenied(let detail): return await failLaunch(gameID: game.id, error: .permissionDenied(detail))
            default: return await failLaunch(gameID: game.id, error: .processLaunchFailed(error.localizedDescription))
            }
        } catch let error as GameFileSystemRepository.FileError {
            return await failLaunch(gameID: game.id, error: .permissionDenied(error.localizedDescription))
        } catch {
            return await failLaunch(gameID: game.id, error: .processLaunchFailed(error.localizedDescription))
        }
    }

    public func cancelLaunch() async {
        cancellationRequested = true
        guard let processID = currentLaunchProcessID else { return }
        do {
            try await cleanup(processID: processID, gameID: currentGameID)
            await logWriter.record(.init(
                level: .warning,
                module: "LaunchOrchestrator",
                eventName: "launch.cancel",
                gameID: currentGameID,
                phase: "cleanup",
                result: "cancelled",
                errorCategory: "userCancelled",
                messageCode: "launch.cancelled",
                fields: ["cleanupVerified": "true"]
            ))
        } catch {
            await logWriter.error("启动取消清理未确认: \(error.localizedDescription)", module: "LaunchOrchestrator")
            await logWriter.record(.init(
                level: .error,
                module: "LaunchOrchestrator",
                eventName: "launch.cancel",
                phase: "cleanup",
                result: "recoveryRequired",
                errorCategory: "cancellationUnconfirmed",
                messageCode: "launch.cancel_cleanup_failed",
                fields: ["cleanupVerified": "false"]
            ))
        }
    }

    private func isCancellationRequested() -> Bool { cancellationRequested }

    private func setCurrentProcess(_ processID: UUID) { currentLaunchProcessID = processID }

    /// 只对 MiPlay 托管目录下的固定 runtime 启用 LaunchServices 启动；
    /// 其他布局保持直接子进程路径。
    private func isManagedRuntimeLayout(_ runtimeRootURL: URL) async -> Bool {
        let versionsDirectory = await wineVersionManager.wineVersionsDirectory()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let expectedRoot = versionsDirectory
            .appendingPathComponent(WineVersionManager.fixedRuntimeTag, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return runtimeRootURL.resolvingSymlinksInPath().standardizedFileURL == expectedRoot
    }

    // MARK: - Lifecycle helpers

    private func cleanup(processID: UUID, gameID: String?) async throws {
        let monitor = processMonitorTask.flatMap { $0.sessionID == processID ? $0.task : nil }
        do {
            if let application = activeApplication, application.sessionID == processID {
                try await applicationLauncher.terminate(pid: application.pid, force: true, timeout: .seconds(8))
                if monitor == nil { activeApplication = nil }
            } else {
                _ = try await processManager.terminateAndWait(processID: processID, force: true, timeout: 8)
            }
        } catch ProcessManager.ProcessError.processNotRunning {
            // The termination handler already finalized the process; this is clean.
        } catch {
            throw LaunchError.recoveryRequired(error.localizedDescription)
        }
        // Once monitoring has started it owns the exit commit and prefix release.
        // Actor reentrancy otherwise lets cancellation and monitorProcess release
        // the same lease while either awaits wineserver shutdown.
        if let monitor {
            await monitor.value
            guard currentLaunchProcessID != processID else {
                throw LaunchError.recoveryRequired("进程已结束，但退出状态或共享 prefix 清理尚未提交")
            }
            if processMonitorTask?.sessionID == processID { processMonitorTask = nil }
            return
        }
        if let gameID {
            guard let currentGame = await gameRegistry.getGame(by: gameID) else {
                throw LaunchError.persistenceFailed("游戏不存在，无法提交清理状态")
            }
            if currentGame.state == .launching || currentGame.state == .running {
                do { try await gameRegistry.transitionGame(id: gameID, to: .installed) }
                catch { throw LaunchError.persistenceFailed(error.localizedDescription) }
            }
        }
        // The process exit and business-state commit are complete. Only now
        // release the scope, shared prefix lease and launch guard.
        activeSecurityScopes.removeValue(forKey: processID)?.stop()
        try await releaseSharedPrefixLease()
        restoreStagedGameFiles()
        currentLaunchProcessID = nil
        currentGameID = nil
    }

    private func restoreStagedGameFiles() {
        LaunchCompatibilityEnvironment.restore(activeStagedGameFiles)
        activeStagedGameFiles = []
    }

    private func releaseSharedPrefixLease() async throws {
        guard let lease = activeSharedPrefixLease else {
            activeManagedRuntime = nil
            return
        }
        do {
            if let runtime = activeManagedRuntime {
                try await wineRuntimeProvider.shutdownSharedPrefix(
                    runtime: runtime,
                    lease: lease
                )
            }
            try await wineRuntimeProvider.releaseSharedPrefixLease(lease)
            activeSharedPrefixLease = nil
            activeManagedRuntime = nil
        } catch {
            throw LaunchError.recoveryRequired("共享 prefix lease 释放失败: \(error.localizedDescription)")
        }
    }

    private func cancelAfterFailure(gameID: String) async -> LaunchResult {
        restoreStagedGameFiles()
        do {
            if let processID = currentLaunchProcessID { try await cleanup(processID: processID, gameID: gameID) }
            else { try await releaseSharedPrefixLease() }
            currentGameID = nil
            return .failure(.cancelled)
        } catch { return .failure(.recoveryRequired(error.localizedDescription)) }
    }

    private func failLaunch(gameID: String, error: LaunchError) async -> LaunchResult {
        restoreStagedGameFiles()
        // An unconfirmed cleanup must keep the launching state as a guard
        // against a second side effect. The process/scope facts remain owned
        // by this orchestrator until a later recovery operation can confirm
        // termination.
        if case .recoveryRequired = error {
            await logWriter.error("启动恢复未确认: \(error.localizedDescription)", module: "LaunchOrchestrator")
            return .failure(error)
        }

        do {
            try await releaseSharedPrefixLease()
        } catch {
            await logWriter.error(
                "启动失败后的共享 prefix lease 释放未确认: \(error.localizedDescription)",
                module: "LaunchOrchestrator"
            )
            return .failure(.recoveryRequired(error.localizedDescription))
        }
        currentLaunchProcessID = nil
        currentGameID = nil
        do {
            if let state = (await gameRegistry.getGame(by: gameID))?.state,
               state == .launching || state == .installed {
                try await gameRegistry.transitionGame(id: gameID, to: .launchFailed)
            }
        } catch {
            await logWriter.error("启动失败事实无法保存: \(error.localizedDescription)", module: "LaunchOrchestrator")
            return .failure(.recoveryRequired(error.localizedDescription))
        }
        do {
            try await gameRegistry.recordLaunchFailure(
                id: gameID,
                detail: error.localizedDescription
            )
        } catch {
            await logWriter.error(
                "启动诊断无法持久化: \(error.localizedDescription)",
                module: "LaunchOrchestrator"
            )
            return .failure(.recoveryRequired(
                "启动失败已确认，但诊断写入未确认: \(error.localizedDescription)"
            ))
        }
        await logWriter.error("启动失败: \(error.localizedDescription)", module: "LaunchOrchestrator")
        await logWriter.record(.init(
            level: .error,
            module: "LaunchOrchestrator",
            eventName: "launch.terminal",
            gameID: gameID,
            phase: "terminal",
            result: "failed",
            errorCategory: "processStartFailed",
            messageCode: "launch.failed"
        ))
        return .failure(error)
    }

    private func monitorProcess(processID: UUID, game: Game) async {
        do {
            let statusCode: Int32
            let terminatedBySignal: Bool
            let output: String
            if let application = activeApplication, application.sessionID == processID {
                let exit = await applicationLauncher.waitForExit(
                    pid: application.pid,
                    logURL: application.logURL,
                    statusURL: application.statusURL
                )
                statusCode = exit.statusCode
                terminatedBySignal = exit.terminatedBySignal
                output = exit.output
                activeApplication = nil
            } else {
                let result = try await processManager.waitForTermination(processID: processID)
                statusCode = result.statusCode
                terminatedBySignal = result.terminatedBySignal
                output = result.output
            }
            // The game process is gone; restore the files staged aside for
            // this launch regardless of how the exit fact is committed.
            restoreStagedGameFiles()
            do {
                try await gameRegistry.commitProcessExit(
                    gameID: game.id,
                    processID: processID,
                    statusCode: statusCode,
                    terminatedBySignal: terminatedBySignal,
                    output: output
                )
                // The business exit fact is committed. Release the scope and
                // lifecycle guard before any diagnostic await so observers
                // never see Installed with an outstanding bookmark lease.
                activeSecurityScopes.removeValue(forKey: processID)?.stop()
                try await releaseSharedPrefixLease()
                if currentLaunchProcessID == processID {
                    currentLaunchProcessID = nil
                    currentGameID = nil
                }
                await logWriter.record(.init(
                    level: statusCode == 0 && !terminatedBySignal ? .info : .warning,
                    module: "LaunchOrchestrator",
                    eventName: "launch.exit",
                    operationID: processID,
                    gameID: game.id,
                    phase: "exitCommitted",
                    result: statusCode == 0 && !terminatedBySignal ? "completed" : "failed",
                    errorCategory: statusCode == 0 && !terminatedBySignal ? "none" : "processExitedAbnormally",
                    messageCode: statusCode == 0 && !terminatedBySignal ? "launch.exit_committed" : "launch.exit_abnormal",
                    fields: ["exitCode": String(statusCode), "signal": terminatedBySignal ? "1" : "0"]
                ))
            } catch {
                let detail = "进程已退出，但游戏状态提交失败: \(error.localizedDescription)"
                do {
                    _ = try await gameRegistry.recordProcessExitRecovery(
                        gameID: game.id,
                        processID: processID,
                        statusCode: statusCode,
                        terminatedBySignal: terminatedBySignal,
                        detail: detail
                    )
                } catch {
                    await logWriter.error("进程退出恢复事实无法保存: \(error.localizedDescription)", module: "LaunchOrchestrator")
                }
                // Keep the lifecycle guard and scoped bookmark until an
                // explicit recovery command commits the target state.
                await logWriter.error(detail, module: "LaunchOrchestrator")
                await logWriter.record(.init(
                    level: .error,
                    module: "LaunchOrchestrator",
                    eventName: "launch.exit",
                    operationID: processID,
                    gameID: game.id,
                    phase: "exitCommit",
                    result: "recoveryRequired",
                    errorCategory: "writeFailed",
                    messageCode: "launch.exit_commit_failed",
                    fields: ["exitCode": String(statusCode)]
                ))
                return
            }
            if statusCode == 0, !terminatedBySignal {
                await logWriter.info("游戏进程正常退出: \(game.type.displayName)", module: "LaunchOrchestrator")
            } else {
                await logWriter.error("游戏进程异常退出: \(game.type.displayName)", module: "LaunchOrchestrator")
            }
        } catch {
            await logWriter.error("游戏退出事实无法确认: \(error.localizedDescription)", module: "LaunchOrchestrator")
        }
    }

    /// Retries an exit-state commit only; it never relaunches the game.
    public func retryProcessExitRecovery(recordID: String) async throws {
        // 启动进行中不得执行恢复：共享 prefix lease 与进程/作用域守卫属于当前启动。
        guard currentLaunchProcessID == nil else {
            throw LaunchError.recoveryRequired("启动进行中，暂缓执行状态恢复")
        }
        try await gameRegistry.retryProcessExitRecovery(recordID: recordID)
        try await releaseSharedPrefixLease()
        if let processID = currentLaunchProcessID {
            activeSecurityScopes.removeValue(forKey: processID)?.stop()
        }
        activeApplication = nil
        currentLaunchProcessID = nil
        currentGameID = nil
    }

}
