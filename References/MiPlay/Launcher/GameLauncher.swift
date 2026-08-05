//
//  GameLauncher.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor GameLauncher {
    enum LaunchError: LocalizedError {
        case gameNotInstalled
        case wineNotConfigured
        case prefixNotInitialized
        case executableNotFound(String)
        case processFailed(String)
        case scriptCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .gameNotInstalled: return "游戏未安装"
            case .wineNotConfigured: return "Wine 未配置"
            case .prefixNotInitialized: return "Wine Prefix 未初始化"
            case .executableNotFound(let path): return "游戏可执行文件未找到: \(path)"
            case .processFailed(let detail): return "进程启动失败: \(detail)"
            case .scriptCreationFailed(let detail): return "启动脚本创建失败: \(detail)"
            }
        }
    }

    private let gameManager: GameManager
    private var activeProcess: Process?

    var isGameRunning: Bool { activeProcess?.isRunning ?? false }

    init(gameManager: GameManager) {
        self.gameManager = gameManager
    }

    // MARK: - Launch（异步，不阻塞调用方）

    func launchGame(
        type: GameType,
        configuration: LaunchConfiguration,
        wineConfig: WineConfig,
        prefixPath: String
    ) async throws {
        guard !wineConfig.localPath.isEmpty else {
            throw LaunchError.wineNotConfigured
        }

        let fileManager = FileManager.default
        let gameDir = configuration.gameDir
        guard fileManager.fileExists(atPath: gameDir) else {
            throw LaunchError.executableNotFound("游戏目录不存在: \(gameDir)")
        }

        guard let gameExecutable = gameExecutablePath(for: type, gameDir: gameDir) else {
            throw LaunchError.gameNotInstalled
        }

        // 1. 生成启动脚本
        let scriptPath = try await createLaunchScript(
            gameDir: gameDir,
            gameExecutable: gameExecutable,
            winePrefix: prefixPath,
            wineConfig: wineConfig
        )

        // 2. 环境变量
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixPath
        env["WINEARCH"] = "win64"
        env["WINEDEBUG"] = "fixme-all,err-unwind,+timestamp"
        env["PATH"] = "\(wineConfig.localPath)/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        if configuration.dxmtEnabled {
            env["DXMT_LOG_LEVEL"] = configuration.dxmtLogLevel.rawValue
            env["WINEESYNC"] = "1"
            if !configuration.enableShaderCache {
                env["DXMT_SHADER_CACHE"] = "0"
            }
        }
        if configuration.enableMetalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }
        if configuration.enableTimeoutFix {
            env["WINE_ENABLE_TIMEOUT_FIX"] = "1"
        }
        if configuration.proxyEnabled, let proxyHost = configuration.proxyHost {
            env["HTTP_PROXY"] = proxyHost
            env["HTTPS_PROXY"] = proxyHost
        }
        for (key, value) in configuration.environmentVariables {
            env[key] = value
        }

        // 3. 启动进程
        let wineBin = "\(wineConfig.localPath)/bin/wine64"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: wineBin)
        process.arguments = ["cmd", "/c", scriptPath]
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: gameDir)

        // 日志
        let logDir = fileManager.temporaryDirectory.appendingPathComponent("MiPlay/Logs", isDirectory: true)
        try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("game_\(type.rawValue)_\(Int(Date().timeIntervalSince1970)).log")
        fileManager.createFile(atPath: logFile.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: logFile)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { try? outputHandle.write(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { try? outputHandle.write(data) }
        }

        self.activeProcess = process
        try process.run()

        Logger.shared.info("游戏 \(type.displayName) 已启动 (PID: \(process.processIdentifier))")

        // 4. 异步等待进程退出（不阻塞 actor）
        let pid = process.processIdentifier
        let terminationStatus = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            // 使用 DispatchQueue 在后台线程等待，不阻塞当前 actor
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }

        // 5. 进程退出后清理
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? outputHandle.close()
        try? fileManager.removeItem(atPath: scriptPath)
        self.activeProcess = nil

        if terminationStatus != 0 {
            Logger.shared.warning("游戏 \(type.displayName) 退出，状态码: \(terminationStatus)")
        } else {
            Logger.shared.info("游戏 \(type.displayName) 正常退出")
        }
    }

    // MARK: - 启动脚本

    private func createLaunchScript(
        gameDir: String,
        gameExecutable: String,
        winePrefix: String,
        wineConfig: WineConfig
    ) async throws -> String {
        let scriptContent = buildLaunchScriptContent(
            gameDir: gameDir,
            gameExecutable: gameExecutable,
            winePrefix: winePrefix
        )

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiPlay")
            .appendingPathComponent("launch_\(UUID().uuidString).bat")

        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

        var attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        var permissions = attributes[.posixPermissions] as? Int ?? 0o644
        permissions |= 0o111
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: scriptURL.path)

        return scriptURL.path
    }

    private func buildLaunchScriptContent(
        gameDir: String,
        gameExecutable: String,
        winePrefix: String
    ) -> String {
        return """
        @echo off
        cd /d "\(winePath(from: gameDir))"
        "\(winePath(from: gameExecutable))"
        """
    }

    // MARK: - Helpers

    private func winePath(from absPath: String) -> String {
        "Z:" + absPath.replacingOccurrences(of: "/", with: "\\")
    }

    private func gameExecutablePath(for type: GameType, gameDir: String) -> String? {
        switch type {
        case .genshinImpact:
            return "\(gameDir)/Genshin Impact Game/GenshinImpact.exe"
        case .starRail:
            return "\(gameDir)/StarRail.exe"
        case .zenlessZoneZero:
            return "\(gameDir)/ZenlessZoneZero.exe"
        }
    }

    // MARK: - Process Control

    func terminateGame() {
        activeProcess?.terminate()
        activeProcess = nil
    }
}
