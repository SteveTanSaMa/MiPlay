//
//  WineRuntimeProvider.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Service Contract -> WineRuntimeProvider
// Source: Architecture Design -> ADR 006 -> fixed Wine executable and prefix

/// Executes a selected Wine binary and prepares an application-owned prefix.
/// Version selection remains the responsibility of WineVersionManager.
public actor WineRuntimeProvider {
    public struct PreparedPrefix: Sendable, Equatable {
        public let url: URL

        internal init(url: URL) {
            self.url = url
        }

        public var path: String { url.path }
    }

    public enum WineError: Error, LocalizedError, Sendable {
        case wineNotInstalled
        case prefixCreationFailed(String)
        case environmentNotReady(String)
        case wineBinaryNotFound(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .wineNotInstalled: return "Wine 运行时未安装"
            case .prefixCreationFailed(let detail): return "Wine 前缀创建失败: \(detail)"
            case .environmentNotReady(let detail): return "Wine 环境未就绪: \(detail)"
            case .wineBinaryNotFound(let path): return "Wine 二进制文件未找到: \(path)"
            case .cancelled: return "Wine 环境准备已取消"
            }
        }
    }

    private let processManager: ProcessManager
    private let fileSystemRepository: GameFileSystemRepository
    private let logWriter: LogWriter?

    public init(
        processManager: ProcessManager,
        fileSystemRepository: GameFileSystemRepository,
        logWriter: LogWriter? = nil
    ) {
        self.processManager = processManager
        self.fileSystemRepository = fileSystemRepository
        self.logWriter = logWriter
    }

    /// Loads only a runtime identity produced by WineVersionManager.
    internal func load(runtime: ManagedWineRuntime) async throws -> URL {
        await logWriter?.record(.init(
            level: .info,
            module: "WineRuntimeProvider",
            eventName: "wine.runtime.readiness",
            wineTag: runtime.tagName,
            phase: "binaryCheck",
            result: "inProgress",
            messageCode: "wine.runtime.check_started"
        ))
        let runtimeRoot = runtime.rootURL.resolvingSymlinksInPath().standardizedFileURL
        let wineBinaryURL = runtime.binaryURL
        guard runtimeRoot.path.hasSuffix("/WineVersions/\(runtime.tagName)"),
              wineBinaryURL.deletingLastPathComponent().deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL == runtimeRoot,
              FileManager.default.fileExists(atPath: wineBinaryURL.path) else {
            throw WineError.wineBinaryNotFound(wineBinaryURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: wineBinaryURL.path) else {
            throw WineError.environmentNotReady("Wine binary 不可执行")
        }
        do {
            let output = try await processManager.launchAndWait(
                executablePath: wineBinaryURL.path,
                arguments: ["--version"],
                timeout: 10
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw WineError.environmentNotReady("Wine 版本检测无输出") }
            await logWriter?.record(.init(
                level: .info,
                module: "WineRuntimeProvider",
                eventName: "wine.runtime.readiness",
                wineTag: runtime.tagName,
                phase: "binaryCheck",
                result: "completed",
                messageCode: "wine.runtime.ready"
            ))
            return wineBinaryURL
        } catch let error as WineError { throw error }
        catch is CancellationError { throw WineError.cancelled }
        catch { throw WineError.environmentNotReady(error.localizedDescription) }
    }

    /// Legacy test/migration seam. Production code must use `load(runtime:)`.
    internal func load(runtimePath: String) async throws -> String {
        let runtimeURL = URL(fileURLWithPath: runtimePath)
        let binaryURL = runtimeURL.lastPathComponent == "wine"
            ? runtimeURL
            : runtimeURL.appendingPathComponent("wine")
        let runtime = ManagedWineRuntime(
            tagName: runtimeURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            rootURL: binaryURL.deletingLastPathComponent().deletingLastPathComponent()
        )
        return try await load(runtime: runtime).path
    }

    /// Runs `wine wineboot -u` with the same binary that will launch the game.
    internal func preparePrefix(for gameID: String, runtime: ManagedWineRuntime) async throws -> PreparedPrefix {
        await logWriter?.record(.init(
            level: .info,
            module: "WineRuntimeProvider",
            eventName: "wine.prefix.readiness",
            gameID: gameID,
            wineTag: runtime.tagName,
            phase: "prepare",
            result: "inProgress",
            messageCode: "wine.prefix.prepare_started"
        ))
        try Task.checkCancellation()
        let wineBinary = try await load(runtime: runtime).path
        let prefixRoot = await fileSystemRepository.winePrefixDirectory()
        let prefixURL = prefixRoot.appendingPathComponent(gameID, isDirectory: true)
        let prefixPath = prefixURL.path
        let alreadyReady = FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent("drive_c").path)
        if alreadyReady {
            await logWriter?.record(.init(
                level: .info,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                gameID: gameID,
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "completed",
                messageCode: "wine.prefix.ready"
            ))
            return PreparedPrefix(url: prefixURL)
        }

        let prefixExistedBefore = FileManager.default.fileExists(atPath: prefixPath)
        do {
            try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)
            let environment = [
                "WINEPREFIX": prefixPath,
                "WINEDLLOVERRIDES": "winemenubuilder.exe=d"
            ]
            _ = try await processManager.launchAndWait(
                executablePath: wineBinary,
                arguments: ["wineboot", "-u"],
                environment: environment,
                workingDirectory: prefixPath,
                timeout: 60
            )
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent("drive_c").path) else {
                throw WineError.prefixCreationFailed("wineboot 完成但 drive_c 未生成")
            }
            await logWriter?.record(.init(
                level: .info,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                gameID: gameID,
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "completed",
                messageCode: "wine.prefix.ready"
            ))
            return PreparedPrefix(url: prefixURL)
        } catch is CancellationError {
            await logWriter?.record(.init(
                level: .warning,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                gameID: gameID,
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "cancelled",
                errorCategory: "userCancelled",
                messageCode: "wine.prefix.cancelled"
            ))
            if !prefixExistedBefore {
                do { try FileManager.default.removeItem(at: prefixURL) }
                catch { throw WineError.prefixCreationFailed("准备已取消，未完成前缀清理失败: \(error.localizedDescription)") }
            }
            throw WineError.cancelled
        } catch let error as WineError {
            await logWriter?.record(.init(
                level: .error,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                gameID: gameID,
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "failed",
                errorCategory: "processStartFailed",
                messageCode: "wine.prefix.failed"
            ))
            let originalDetail = error.localizedDescription
            if !prefixExistedBefore {
                do { try FileManager.default.removeItem(at: prefixURL) }
                catch { throw WineError.prefixCreationFailed("\(originalDetail); 未完成前缀清理失败: \(error.localizedDescription)") }
            }
            throw error
        } catch {
            await logWriter?.record(.init(
                level: .error,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                gameID: gameID,
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "failed",
                errorCategory: "processStartFailed",
                messageCode: "wine.prefix.failed"
            ))
            let originalDetail = error.localizedDescription
            if !prefixExistedBefore {
                do { try FileManager.default.removeItem(at: prefixURL) }
                catch { throw WineError.prefixCreationFailed("\(originalDetail); 未完成前缀清理失败: \(error.localizedDescription)") }
            }
            throw WineError.prefixCreationFailed(originalDetail)
        }
    }

    /// Legacy test/migration seam. Production code must use the managed runtime
    /// overload above.
    internal func preparePrefix(for gameID: String, runtimePath: String) async throws -> String {
        let runtimeURL = URL(fileURLWithPath: runtimePath)
        let binaryURL = runtimeURL.lastPathComponent == "wine"
            ? runtimeURL
            : runtimeURL.appendingPathComponent("wine")
        let runtime = ManagedWineRuntime(
            tagName: runtimeURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            rootURL: binaryURL.deletingLastPathComponent().deletingLastPathComponent()
        )
        return try await preparePrefix(for: gameID, runtime: runtime).path
    }

    internal func isPrefixReady(for gameID: String) async -> Bool {
        let root = await fileSystemRepository.winePrefixDirectory()
        let prefix = root.appendingPathComponent(gameID, isDirectory: true)
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPrefix = prefix.resolvingSymlinksInPath().standardizedFileURL
        let driveC = canonicalPrefix.appendingPathComponent("drive_c", isDirectory: true)
        return canonicalPrefix.path.hasPrefix(canonicalRoot.path + "/") &&
            FileManager.default.fileExists(atPath: driveC.path, isDirectory: nil)
    }

    internal func getPrefixPath(for gameID: String) async -> String {
        let root = await fileSystemRepository.winePrefixDirectory()
        return root.appendingPathComponent(gameID, isDirectory: true).path
    }
}
