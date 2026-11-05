// GameRegistryState.swift
// MiPlay

import Foundation

// Source: Architecture Design -> GameRegistry -> business state and facts
extension GameRegistry {
    // MARK: - Business state and facts

    public func transitionGame(id: String, to newState: GameBusinessState) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw RegistrationError.gameNotFound(id) }
        let old = games[index]
        if newState == .launching || newState == .running {
            let pending = await pendingRecoveryRecords(gameID: id)
            if let recovery = pending.first {
                throw RegistrationError.recoveryRequired(
                    "游戏存在未完成恢复事实: \(recovery.detail)"
                )
            }
            guard let location = old.location,
                  location.bookmarkData != nil,
                  location.resolutionState == .resolvable || location.resolutionState == .stale else {
                throw RegistrationError.permissionRequired("游戏目录授权尚未确认")
            }
        }
        let result = try stateMachine.transition(from: old.state, to: newState)
        games[index].state = result
        do { try await persistLibrary() }
        catch { games[index] = old; throw error }
        emit(games[index])
    }

    public func updateLastLaunchDate(id: String, date: Date) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw RegistrationError.gameNotFound(id) }
        let old = games[index]
        games[index].lastLaunchDate = date
        do { try await persistLibrary() }
        catch { games[index] = old; throw error }
        emit(games[index])
    }

    /// Commits the running transition and launch timestamp together. This is the
    /// business commit point used after ProcessManager health confirmation.
    public func recordLaunchConfirmed(id: String, date: Date) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw RegistrationError.gameNotFound(id) }
        let old = games[index]
        let nextState = try stateMachine.transition(from: old.state, to: .running)
        games[index].state = nextState
        games[index].lastLaunchDate = date
        games[index].lastLaunchFailure = nil
        do { try await persistLibrary() }
        catch { games[index] = old; throw error }
        emit(games[index])
    }

    /// Retains a bounded, user-readable launch diagnostic.
    public func recordLaunchFailure(id: String, detail: String) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else {
            throw RegistrationError.gameNotFound(id)
        }
        let old = games[index]
        games[index].lastLaunchFailure = detail
        do {
            try await persistLibrary()
        } catch {
            games[index] = old
            throw error
        }
        emit(games[index])
    }

    public func updateGameVersion(id: String, version: String) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw RegistrationError.gameNotFound(id) }
        let old = games[index]
        games[index].version = version
        do { try await persistLibrary() }
        catch { games[index] = old; throw error }
        emit(games[index])
    }

    /// Commits a version-check result and its evidence as one business write.
    /// A conflict is never promoted to the trusted metadata snapshot.
    public func commitVersionCheck(
        id: String,
        result: VersionChecker.VersionCheckResult
    ) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else {
            throw RegistrationError.gameNotFound(id)
        }
        guard result.outcome == .current || result.outcome == .updateAvailable,
              let currentVersion = result.currentVersion else {
            throw RegistrationError.recoveryRequired("版本证据冲突不能提交为可信状态")
        }
        let old = games[index]
        let metadata = GameMetadata(
            gameID: id,
            latestVersion: result.latestVersion,
            outcome: result.outcome,
            localEvidence: result.localEvidence,
            conflictDetails: result.conflictDetails
        )
        games[index].lastMetadata = metadata
        games[index].metadataFailure = nil
        games[index].version = currentVersion
        if result.updateAvailable,
           games[index].state == .installed || games[index].state == .launchFailed {
            games[index].state = try stateMachine.transition(from: games[index].state, to: .updateAvailable)
        } else if !result.updateAvailable, games[index].state == .updateAvailable {
            games[index].state = try stateMachine.transition(from: games[index].state, to: .installed)
        }
        do {
            try await persistLibrary()
        } catch {
            games[index] = old
            throw error
        }
        emit(games[index])
    }

    /// Keeps the last trusted metadata while recording a durable conflict fact.
    public func recordMetadataFailure(id: String, detail: String) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else {
            throw RegistrationError.gameNotFound(id)
        }
        let old = games[index]
        games[index].metadataFailure = detail
        do {
            let gamesSnapshot = games
            try await persistenceStore.updateAppData { appData in
                appData.games = gamesSnapshot
                appData.recoveryRecords.append(RecoveryRecord(
                    kind: "metadata",
                    gameID: id,
                    phase: "evidenceConflict",
                    detail: detail
                ))
            }
        } catch {
            games[index] = old
            throw RegistrationError.persistenceFailed(error.localizedDescription)
        }
        emit(games[index])
    }

    /// Archives a real integrity result. Unsupported and failed results are facts,
    /// but neither is allowed to promote the Game to a ready state.
    public func updateIntegrity(id: String, result: FileIntegrityVerifier.VerificationResult) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw RegistrationError.gameNotFound(id) }
        let old = games[index]
        games[index].lastIntegrity = IntegritySummary(
            status: result.status.rawValue,
            checkedAt: Date(),
            totalFiles: result.totalFiles,
            verifiedFiles: result.verifiedFiles,
            missingFiles: result.missingFiles,
            corruptedFiles: result.corruptedFiles
        )
        do { try await persistLibrary() }
        catch { games[index] = old; throw error }
        emit(games[index])
    }

    public func addSolutionApplication(id: String, application: SolutionApplication) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw RegistrationError.gameNotFound(id) }
        let old = games[index]
        games[index].solutionApplications.append(application)
        do { try await persistLibrary() }
        catch { games[index] = old; throw error }
        emit(games[index])
    }

    public func updateSolutionApplicationState(id: String, applicationId: String, newState: SolutionApplicationState) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }),
              let applicationIndex = games[index].solutionApplications.firstIndex(where: { $0.id == applicationId }) else {
            throw RegistrationError.gameNotFound(applicationId)
        }
        let old = games[index]
        games[index].solutionApplications[applicationIndex].state = newState
        do { try await persistLibrary() }
        catch { games[index] = old; throw error }
        emit(games[index])
    }

    public func refreshGameState(id: String) async {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        // An interrupted update may temporarily have no executable or an
        // expired bookmark. Preserve its recovery state until the user can
        // renew authorization and the transaction has been restored.
        guard games[index].state != .running, games[index].state != .launching,
              games[index].state != .gameUpdating else { return }
        guard let location = games[index].location else {
            guard games[index].state != .notInstalled else { return }
            let previous = games[index]
            games[index].state = .notInstalled
            do {
                try await persistLibrary()
            } catch {
                games[index] = previous
                await logWriter.error("游戏状态刷新无法持久化: \(error.localizedDescription)", module: "GameRegistry")
                return
            }
            emit(games[index])
            return
        }
        do {
            let gameType = games[index].type
            let access = try fileSystemRepository.acquireSecurityScopedAccess(location)
            defer { access.stop() }
            let resolvedLocation = access.resolvedLocation
            await logWriter.record(.init(
                level: .info,
                module: "GameRegistry",
                eventName: "bookmark.scope",
                gameID: id,
                phase: "scopeStarted",
                result: "inProgress",
                messageCode: "bookmark.scope_started",
                fields: [
                    "scope": location.scope.rawValue,
                    "stale": resolvedLocation.requiresPersistenceUpdate(from: location) ? "true" : "false"
                ]
            ))
            if resolvedLocation.requiresPersistenceUpdate(from: location) {
                do {
                    try await updateResolvedLocation(id: id, location: resolvedLocation)
                } catch {
                    await logWriter.error("stale bookmark 写回失败: \(error.localizedDescription)", module: "GameRegistry")
                    return
                }
            }
            let executableFound = gameType.firstExistingExecutable(at: access.url.path) != nil
            let previous = games[index]
            let stateChanged = (executableFound && games[index].state == .notInstalled) ||
                (!executableFound && games[index].state != .notInstalled)
            if executableFound && games[index].state == .notInstalled {
                games[index].state = .installed
            } else if stateChanged {
                games[index].state = .notInstalled
                games[index].location?.resolutionState = .resolvable
            }
            guard stateChanged else { return }
            do {
                try await persistLibrary()
            } catch {
                games[index] = previous
                await logWriter.error("游戏状态刷新无法持久化: \(error.localizedDescription)", module: "GameRegistry")
                return
            }
            emit(games[index])
            await logWriter.record(.init(
                level: .info,
                module: "GameRegistry",
                eventName: "bookmark.scope",
                gameID: id,
                phase: "scopeUsed",
                result: "completed",
                messageCode: "bookmark.scope_used"
            ))
        } catch {
            let previous = games[index]
            if var unavailable = previous.location {
                unavailable.resolutionState = .accessDenied
                games[index].location = unavailable
                games[index].state = .notInstalled
                do {
                    try await persistLibrary()
                    emit(games[index])
                } catch {
                    games[index] = previous
                    do {
                        try await persistenceStore.appendRecoveryRecord(RecoveryRecord(
                            kind: "bookmarkRefresh",
                            gameID: id,
                            phase: "accessDenied",
                            detail: "游戏目录授权不可用且状态无法持久化: \(error.localizedDescription)"
                        ))
                    } catch {
                        await logWriter.error("授权失效恢复事实无法保存: \(error.localizedDescription)", module: "GameRegistry")
                    }
                }
            }
            await logWriter.warning("游戏路径暂时无法访问，未使用 lastKnownPath 回退: \(error.localizedDescription)", module: "GameRegistry")
            await logWriter.record(.init(
                level: .error,
                module: "GameRegistry",
                eventName: "bookmark.resolve",
                gameID: id,
                phase: "resolve",
                result: "failed",
                errorCategory: "permissionDenied",
                messageCode: "bookmark.access_denied"
            ))
        }
    }

    public func refreshAllGameStates() async {
        for game in games { await refreshGameState(id: game.id) }
    }

    // MARK: - Path checks

    public enum PathValidationResult: Sendable {
        case valid
        case pathNotAccessible(String)
        case executableNotFound(String)
        case gameFilesMissing(String)

        public var description: String {
            switch self {
            case .valid: return "路径有效"
            case .pathNotAccessible(let path): return "路径不可访问: \(path)"
            case .executableNotFound(let path): return "未找到游戏可执行文件: \(path)"
            case .gameFilesMissing(let detail): return "游戏文件缺失: \(detail)"
            }
        }
    }

    internal func validateGamePath(gameType: GameType, path: String) async -> PathValidationResult {
        guard fileSystemRepository.validatePath(path) else { return .pathNotAccessible(path) }
        if gameType.firstExistingExecutable(at: path) != nil { return .valid }
        return .executableNotFound(URL(fileURLWithPath: path).appendingPathComponent(gameType.executableRelativePaths[0]).path)
    }

}
