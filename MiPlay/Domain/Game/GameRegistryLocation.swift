// GameRegistryLocation.swift
// MiPlay

import Foundation

// Source: Architecture Design -> GameRegistry -> authorized location commands
extension GameRegistry {
    // MARK: - Location commands

    /// Legacy path entry point. A naked path is never treated as authorization.
    @discardableResult
    internal func addGame(type gameType: GameType, installPath: String?) async throws -> Game {
        guard getGame(by: gameType) == nil else { throw RegistrationError.gameAlreadyExists(gameType) }
        let game = Game(
            id: gameType.rawValue,
            type: gameType,
            location: installPath.map { GameLocation.migrationRequired(gameID: gameType.rawValue, path: $0) },
            state: .notInstalled,
            version: nil,
            lastLaunchDate: nil,
            solutionApplications: []
        )
        games.append(game)
        do { try await persistLibrary() }
        catch { games.removeAll { $0.id == game.id }; throw error }
        emit(game)
        return game
    }

    /// Commits a user-selected URL only after bookmark creation and scoped validation.
    @discardableResult
    public func locateGame(type gameType: GameType, selectedURL: URL) async throws -> Game {
        let gameID = gameType.rawValue
        guard let index = games.firstIndex(where: { $0.type == gameType }) else {
            throw RegistrationError.gameNotFound(gameID)
        }

        var isDirectory: ObjCBool = false
        let isExisting = FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory)
        guard isExisting else { throw RegistrationError.invalidPath(selectedURL.path) }
        let directoryURL = isDirectory.boolValue ? selectedURL : selectedURL.deletingLastPathComponent()
        let location: GameLocation
        do {
            location = try fileSystemRepository.makeGameLocation(gameID: gameID, for: directoryURL)
        } catch {
            throw RegistrationError.permissionRequired(error.localizedDescription)
        }

        let validation: (PathValidationResult, GameLocation)
        do {
            validation = try await fileSystemRepository.withSecurityScopedAccess(location) { resolvedURL, resolvedLocation in
                let found = gameType.executableRelativePaths.contains { relativePath in
                    FileManager.default.fileExists(atPath: resolvedURL.appendingPathComponent(relativePath).path)
                }
                if found { return (.valid, resolvedLocation) }
                let first = resolvedURL.appendingPathComponent(gameType.executableRelativePaths[0]).path
                return (.executableNotFound(first), resolvedLocation)
            }
        } catch {
            throw RegistrationError.permissionRequired(error.localizedDescription)
        }

        guard case .valid = validation.0 else {
            throw RegistrationError.invalidPath(validation.0.description)
        }

        let previous = games[index]
        var updated = previous
        updated.location = validation.1
        updated.state = .installed
        games[index] = updated
        do {
            try await persistLibrary()
        } catch {
            games[index] = previous
            throw error
        }
        emit(updated)
        await logWriter.info("游戏路径和授权已保存: \(gameType.displayName)", module: "GameRegistry")
        return updated
    }

    /// Persists the bookmark and path returned by a scoped resolution. This is
    /// required after a stale bookmark is refreshed; the original bookmark is
    /// never silently retained as the long-term authorization fact.
    public func updateResolvedLocation(id: String, location: GameLocation) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else {
            throw RegistrationError.gameNotFound(id)
        }
        guard location.gameID == id, location.bookmarkData != nil else {
            throw RegistrationError.permissionRequired("解析后的授权凭据无效")
        }
        let previous = games[index]
        games[index].location = location
        do {
            try await persistLibrary()
        } catch {
            games[index] = previous
            let detail = "stale bookmark 刷新写回失败: \(error.localizedDescription)"
            await logWriter.record(.init(
                level: .error,
                module: "GameRegistry",
                eventName: "bookmark.writeback",
                operationID: UUID(),
                gameID: id,
                phase: "writeback",
                result: "recoveryRequired",
                errorCategory: "writeFailed",
                messageCode: "bookmark.writeback_failed",
                fields: ["stale": "true"]
            ))
            do {
                try await persistenceStore.appendRecoveryRecord(RecoveryRecord(
                    kind: "bookmarkRefresh",
                    gameID: id,
                    target: location.lastKnownPath,
                    phase: "bookmarkWrite",
                    detail: detail
                ))
            } catch {
                await logWriter.error("bookmark recovery 事实也无法保存: \(error.localizedDescription)", module: "GameRegistry")
            }
            throw RegistrationError.recoveryRequired(detail)
        }
        emit(games[index])
        await logWriter.record(.init(
            level: .info,
            module: "GameRegistry",
            eventName: "bookmark.writeback",
            gameID: id,
            phase: "writeback",
            result: "completed",
            messageCode: "bookmark.writeback_completed",
            fields: ["stale": "true"]
        ))
    }

    /// Commits the fact that a launched process exited. This is deliberately
    /// separate from the ProcessManager exit callback and is idempotent.
    public func commitProcessExit(
        gameID: String,
        processID: UUID,
        statusCode: Int32,
        terminatedBySignal: Bool
    ) async throws {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else {
            throw RegistrationError.gameNotFound(gameID)
        }
        let target: GameBusinessState = statusCode == 0 && !terminatedBySignal ? .installed : .launchFailed
        let old = games[index]
        if old.state != target {
            games[index].state = try stateMachine.transition(from: old.state, to: target)
        }
        do {
            try await persistLibrary()
        } catch {
            games[index] = old
            throw RegistrationError.persistenceFailed(error.localizedDescription)
        }
        emit(games[index])
    }

    /// Stores a durable process-exit recovery fact without changing the
    /// business state. It is safe to call repeatedly for one process session.
    @discardableResult
    public func recordProcessExitRecovery(
        gameID: String,
        processID: UUID,
        statusCode: Int32,
        terminatedBySignal: Bool,
        detail: String
    ) async throws -> RecoveryRecord {
        let target = statusCode == 0 && !terminatedBySignal ? GameBusinessState.installed : .launchFailed
        let record = RecoveryRecord(
            kind: "processExit",
            gameID: gameID,
            target: target.rawValue,
            phase: "exitStateCommit",
            detail: detail,
            payload: [
                "processID": processID.uuidString,
                "statusCode": String(statusCode),
                "terminatedBySignal": String(terminatedBySignal)
            ]
        )
        do {
            var data = try await persistenceStore.readAppData()
            if let existing = data.recoveryRecords.first(where: {
                $0.kind == "processExit" && $0.payload["processID"] == processID.uuidString && $0.resolvedAt == nil
            }) {
                return existing
            }
            data.recoveryRecords.append(record)
            try await persistenceStore.writeAppData(data)
        } catch {
            // Keep a retryable in-process fact when the store itself is down.
            // The process/scope guard remains owned by LaunchOrchestrator until
            // a later retry commits both the game state and this fact.
            inMemoryRecoveryRecords[record.id] = record
            do {
                try await persistenceStore.writeRecoveryGuard(record)
            } catch {
                await logWriter.error(
                    "进程退出恢复保护也无法持久化: \(error.localizedDescription)",
                    module: "GameRegistry"
                )
            }
            throw RegistrationError.recoveryRequired(
                "进程退出恢复事实无法持久化 (\(record.id)): \(error.localizedDescription)"
            )
        }
        return record
    }

    /// Retries only the durable exit-state commit. It never starts a process.
    public func retryProcessExitRecovery(recordID: String) async throws {
        let record: RecoveryRecord
        if let memoryRecord = inMemoryRecoveryRecords[recordID] {
            record = memoryRecord
        } else {
            let data = try await persistenceStore.readAppData()
            if let durable = data.recoveryRecords.first(where: {
                $0.id == recordID &&
                ($0.kind == "processExit" || $0.kind == "restartReconciliation") &&
                $0.resolvedAt == nil
            }) {
                record = durable
            } else if let guardRecord = try await persistenceStore.readRecoveryGuards().first(where: {
                $0.id == recordID &&
                ($0.kind == "processExit" || $0.kind == "restartReconciliation") &&
                $0.resolvedAt == nil
            }) {
                record = guardRecord
            } else {
                throw RegistrationError.recoveryRequired("退出恢复事实不存在或已处理")
            }
        }

        guard record.kind == "processExit" || record.kind == "restartReconciliation" else {
            throw RegistrationError.recoveryRequired("恢复事实类型不支持退出状态重试")
        }
        try await commitProcessExitRecovery(record)
    }

    public func pendingRecoveryRecords(gameID: String? = nil) async -> [RecoveryRecord] {
        let durable: [RecoveryRecord]
        let guards: [RecoveryRecord]
        do {
            durable = try await persistenceStore.readAppData().recoveryRecords
            guards = try await persistenceStore.readRecoveryGuards()
        } catch {
            // A read failure is itself a protection condition. Returning an
            // empty list here would allow a new side effect to race recovery.
            let diagnostic = RecoveryRecord(
                kind: "persistenceRecovery",
                gameID: gameID,
                phase: "readRecovery",
                detail: "无法读取恢复保护事实: \(error.localizedDescription)"
            )
            return [diagnostic]
        }
        let all = durable + guards + inMemoryRecoveryRecords.values
        var unique: [String: RecoveryRecord] = [:]
        for record in all where record.resolvedAt == nil {
            unique[record.id] = record
        }
        return unique.values
            .filter { gameID == nil || $0.gameID == gameID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Reconciles process state at the restart boundary. A Process reference is
    /// intentionally not persisted, so a Running/Launching game cannot be
    /// treated as still active after a new process starts. The conservative
    /// outcome is LaunchFailed and a durable recovery record; no relaunch is
    /// attempted here.
    internal func reconcileInterruptedLaunches() async throws -> [RecoveryRecord] {
        var data = try await persistenceStore.readAppData()
        let durableGuards = try await persistenceStore.readRecoveryGuards()
        let originalGames = games
        var changed = false
        var recoveries: [RecoveryRecord] = []

        for index in games.indices {
            guard games[index].state == .running || games[index].state == .launching else { continue }

            if let existing = (data.recoveryRecords + durableGuards).first(where: {
                $0.resolvedAt == nil && $0.gameID == games[index].id &&
                    ($0.kind == "processExit" || $0.kind == "restartReconciliation")
            }) {
                recoveries.append(existing)
                continue
            }

            let oldState = games[index].state
            games[index].state = try stateMachine.transition(from: oldState, to: .launchFailed)
            let record = RecoveryRecord(
                kind: "restartReconciliation",
                gameID: games[index].id,
                target: GameBusinessState.launchFailed.rawValue,
                phase: "restartReconciliation",
                detail: "应用重启后无法验证旧游戏进程，已保守标记为启动失败",
                payload: [
                    "reason": "interruptedAfterRestart",
                    "previousState": oldState.rawValue
                ]
            )
            data.recoveryRecords.append(record)
            recoveries.append(record)
            changed = true
        }

        guard changed else { return recoveries }
        data.games = games
        do {
            try await persistenceStore.writeAppData(data)
        } catch {
            games = originalGames
            for record in recoveries {
                do {
                    try await persistenceStore.writeRecoveryGuard(record)
                } catch {
                    inMemoryRecoveryRecords[record.id] = record
                    await logWriter.error(
                        "重启恢复保护无法持久化: \(error.localizedDescription)",
                        module: "GameRegistry"
                    )
                }
            }
            await logWriter.error(
                "重启恢复事实无法写入 AppData，已保留独立恢复保护: \(error.localizedDescription)",
                module: "GameRegistry"
            )
        }
        return recoveries
    }

    internal func commitProcessExitRecovery(_ record: RecoveryRecord) async throws {
        guard let gameID = record.gameID,
              let targetRaw = record.target,
              let target = GameBusinessState(rawValue: targetRaw),
              let gameIndex = games.firstIndex(where: { $0.id == gameID }) else {
            throw RegistrationError.recoveryRequired("退出恢复事实缺少有效游戏目标")
        }
        let old = games[gameIndex]
        if old.state != target {
            games[gameIndex].state = try stateMachine.transition(from: old.state, to: target)
        }
        var data = try await persistenceStore.readAppData()
        data.games = games
        if let recordIndex = data.recoveryRecords.firstIndex(where: { $0.id == record.id }) {
            data.recoveryRecords[recordIndex].resolvedAt = Date()
        } else {
            var completedRecord = record
            completedRecord.resolvedAt = Date()
            data.recoveryRecords.append(completedRecord)
        }
        do {
            try await persistenceStore.writeAppData(data)
        } catch {
            games[gameIndex] = old
            throw RegistrationError.recoveryRequired("退出状态重试写入失败: \(error.localizedDescription)")
        }

        do {
            let verified = try await persistenceStore.readAppData()
            guard verified.games.first(where: { $0.id == gameID })?.state == target else {
                throw RegistrationError.recoveryRequired("退出状态重试后重读状态不一致")
            }
            if let recordIndex = verified.recoveryRecords.firstIndex(where: { $0.id == record.id }),
               verified.recoveryRecords[recordIndex].resolvedAt == nil {
                throw RegistrationError.recoveryRequired("退出恢复记录重试后仍未解决")
            }
            try await persistenceStore.clearRecoveryGuard(id: record.id)
        } catch let error as RegistrationError {
            throw error
        } catch {
            throw RegistrationError.recoveryRequired("退出恢复保护清除失败: \(error.localizedDescription)")
        }
        inMemoryRecoveryRecords.removeValue(forKey: record.id)
        games[gameIndex] = (try await persistenceStore.readAppData()).games.first(where: { $0.id == gameID }) ?? games[gameIndex]
        emit(games[gameIndex])
    }

    /// Legacy path update. It records migrationRequired and deliberately does not install the game.
    internal func updateGamePath(id: String, newPath: String) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw RegistrationError.gameNotFound(id) }
        let previous = games[index]
        games[index].location = GameLocation.migrationRequired(gameID: id, path: newPath)
        games[index].state = .notInstalled
        do { try await persistLibrary() }
        catch { games[index] = previous; throw error }
        emit(games[index])
    }

    public func removeGame(id: String) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw RegistrationError.gameNotFound(id) }
        let removed = games.remove(at: index)
        do { try await persistLibrary() }
        catch { games.insert(removed, at: index); throw error }
        await logWriter.info("游戏已移除: \(removed.type.displayName)", module: "GameRegistry")
    }

}
