//
//  PreLaunchValidator.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Service Contract → PreLaunchValidator
// Source: UX Design → UX Principle 1 → 启动就绪前置校验

/// 启动前校验器。在启动请求执行前，全面检查所有前置条件是否满足。
public actor PreLaunchValidator {
    public enum ValidationError: Error, LocalizedError, Sendable {
        case gameFileMissing(gameName: String, path: String)
        case executableNotFound(gameName: String, path: String)
        case wineNotReady(gameName: String)
        case diskSpaceInsufficient(gameName: String, needed: UInt64, available: UInt64)
        case systemVersionIncompatible(required: String, current: String)
        case invalidFileState(gameName: String, detail: String)
        case permissionDenied(gameName: String, detail: String)
        case integrityUnsupported(gameName: String, detail: String)

        public var errorDescription: String? {
            switch self {
            case .gameFileMissing(let name, let path):
                return "\(name) 文件缺失: \(path)"
            case .executableNotFound(let name, let path):
                return "\(name) 可执行文件未找到: \(path)"
            case .wineNotReady(let name):
                return "Wine 未就绪，无法启动 \(name)"
            case .diskSpaceInsufficient(let name, let needed, let available):
                let neededStr = ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)
                let availableStr = ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)
                return "磁盘空间不足: \(name)需要 \(neededStr)，可用 \(availableStr)"
            case .systemVersionIncompatible(let required, let current):
                return "系统版本不兼容: 需要 \(required), 当前为 \(current)"
            case .invalidFileState(let name, let detail):
                return "\(name) 文件状态异常: \(detail)"
            case .permissionDenied(let name, let detail):
                return "\(name) 权限未确认: \(detail)"
            case .integrityUnsupported(let name, let detail):
                return "\(name) 无法确认完整性: \(detail)"
            }
        }
    }

    /// 校验结果
    public enum ValidationResult: Sendable {
        case passed(warnings: [ValidationError] = [])
        case failed(errors: [ValidationError])

        public var isPassed: Bool {
            if case .passed = self { return true }
            return false
        }

        public var errors: [ValidationError] {
            if case .failed(let errs) = self { return errs }
            return []
        }

        /// Non-blocking facts that the caller should surface without treating
        /// the validation as a positive integrity assertion.
        public var warnings: [ValidationError] {
            if case .passed(let warnings) = self { return warnings }
            return []
        }
    }

    private let fileSystemRepository: GameFileSystemRepository
    private let systemDetector: SystemEnvironmentDetector
    private let wineRuntimeProvider: WineRuntimeProvider
    private let wineVersionManager: WineVersionManager
    private let integrityVerifier: FileIntegrityVerifier?
    private let gameRegistry: GameRegistry?
    private let logWriter: LogWriter?

    public init(
        fileSystemRepository: GameFileSystemRepository,
        systemDetector: SystemEnvironmentDetector,
        wineRuntimeProvider: WineRuntimeProvider,
        wineVersionManager: WineVersionManager,
        integrityVerifier: FileIntegrityVerifier? = nil,
        gameRegistry: GameRegistry? = nil,
        logWriter: LogWriter? = nil
    ) {
        self.fileSystemRepository = fileSystemRepository
        self.systemDetector = systemDetector
        self.wineRuntimeProvider = wineRuntimeProvider
        self.wineVersionManager = wineVersionManager
        self.integrityVerifier = integrityVerifier
        self.gameRegistry = gameRegistry
        self.logWriter = logWriter
    }

    // MARK: - Validation

    /// 执行启动前校验
    /// - Parameter game: 要启动的游戏
    /// - Returns: 校验结果
    public func validate(game: Game) async -> ValidationResult {
        var errors: [ValidationError] = []
        let displayName = game.type.displayName
        let operationID = UUID()
        await logWriter?.record(.init(
            level: .info,
            module: "PreLaunchValidator",
            eventName: "launch.preflight",
            operationID: operationID,
            gameID: game.id,
            phase: "started",
            result: "inProgress",
            messageCode: "launch.preflight_started"
        ))
        let relativePaths = game.type.executableRelativePaths
        let minimumDiskSpaceRequired = game.type.launchDiskSpaceRequired

        // 1. 系统版本校验
        if !systemDetector.meetsMinimumRequirement() {
            errors.append(.systemVersionIncompatible(
                required: "macOS 26+",
                current: systemDetector.getOSVersion()
            ))
        }

        // 2. 游戏文件存在性校验。 All path checks and disk checks remain
        // inside the same security-scoped lease.
        guard let location = game.location, location.bookmarkData != nil else {
            errors.append(.permissionDenied(gameName: displayName, detail: "没有有效 security-scoped bookmark"))
            return .failed(errors: errors)
        }

        let scopedValidation: (FileIntegrityVerifier.VerificationResult?, UInt64)
        do {
            scopedValidation = try await fileSystemRepository.withSecurityScopedAccess(location) { resolvedURL, resolvedLocation in
                if FileManager.default.fileExists(atPath: resolvedURL.appendingPathComponent(SophonInstaller.transactionDirectoryName).path) {
                    throw ValidationError.invalidFileState(gameName: displayName, detail: "游戏存在未完成的下载事务，请先恢复更新")
                }
                if resolvedLocation.requiresPersistenceUpdate(from: location) {
                    guard let gameRegistry else {
                        throw ValidationError.permissionDenied(gameName: displayName, detail: "stale bookmark 刷新后缺少持久化边界")
                    }
                    do {
                        try await gameRegistry.updateResolvedLocation(id: game.id, location: resolvedLocation)
                    } catch {
                        throw ValidationError.permissionDenied(gameName: displayName, detail: "stale bookmark 写回失败: \(error.localizedDescription)")
                    }
                }
                let executableFound = game.type.firstExistingExecutable(at: resolvedURL.path) != nil
                guard executableFound else {
                    let firstPath = resolvedURL.appendingPathComponent(relativePaths[0]).path
                    throw ValidationError.executableNotFound(gameName: displayName, path: firstPath)
                }
                let integrity: FileIntegrityVerifier.VerificationResult?
                if let integrityVerifier {
                    integrity = try await integrityVerifier.verify(
                        gameType: game.type,
                        installPath: resolvedURL.path,
                        expectedVersion: game.version
                    )
                } else {
                    integrity = nil
                }
                let (free, _) = try systemDetector.getDiskSpace(at: resolvedURL.path)
                return (integrity, free)
            }
        } catch let error as ValidationError {
            errors.append(error)
            return .failed(errors: errors)
        } catch {
            errors.append(.permissionDenied(gameName: displayName, detail: error.localizedDescription))
            return .failed(errors: errors)
        }

        var warnings: [ValidationError] = []
        if let integrity = scopedValidation.0 {
            switch integrity.status {
            case .passed:
                break
            case .unsupported:
                // A release manifest is not shipped yet. Keep this as an
                // explicit warning so existing, user-owned installations can
                // launch without claiming IntegrityPassed.
                warnings.append(.integrityUnsupported(
                    gameName: displayName,
                    detail: integrity.errors.joined(separator: "; ")
                ))
            case .failed, .cancelled:
                errors.append(.invalidFileState(
                    gameName: displayName,
                    detail: integrity.errors.isEmpty ? "完整性校验未通过" : integrity.errors.joined(separator: "; ")
                ))
            }
        } else {
            warnings.append(.integrityUnsupported(
                gameName: displayName,
                detail: "完整性校验器未配置"
            ))
        }

        // Source: Architecture Design -> ADR 037-042 -> fixed runtime/shared prefix
        // Readiness is a side-effect-free public pair check. Prefix creation is
        // owned by WineRuntimeSetup; launch only reuses the validated pair under
        // its exclusive lease.
        if await wineVersionManager.validatedRuntime(for: game.id) == nil {
            errors.append(.wineNotReady(gameName: displayName))
        }

        // 5. Disk space was measured while the bookmark lease was active.
        // This is a launch guard, not a game download/patch capacity check.
        if scopedValidation.1 < minimumDiskSpaceRequired {
            errors.append(.diskSpaceInsufficient(
                gameName: displayName,
                needed: minimumDiskSpaceRequired,
                available: scopedValidation.1
            ))
        }

        if errors.isEmpty {
            await logWriter?.record(.init(
                level: .info,
                module: "PreLaunchValidator",
                eventName: "launch.preflight",
                operationID: operationID,
                gameID: game.id,
                phase: "completed",
                result: "completed",
                messageCode: warnings.isEmpty ? "launch.preflight_passed" : "launch.preflight_passed_with_warnings",
                fields: ["warningCount": String(warnings.count)]
            ))
            return .passed(warnings: warnings)
        }
        await logWriter?.record(.init(
            level: .error,
            module: "PreLaunchValidator",
            eventName: "launch.preflight",
            operationID: operationID,
            gameID: game.id,
            phase: "completed",
            result: "failed",
            errorCategory: errors.contains { error in
                if case .permissionDenied = error { return true }
                return false
            } ? "permissionDenied" : "integrityUnsupported",
            messageCode: "launch.preflight_failed"
        ))
        return .failed(errors: errors)
    }
}
