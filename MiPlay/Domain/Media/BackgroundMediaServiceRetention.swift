// BackgroundMediaServiceRetention.swift
// MiPlay

@preconcurrency import Foundation

extension BackgroundMediaService {
    /// Settings can change while games are already displayed. Reuse the API
    /// response already in memory to start or stop retention without another
    /// foreground load or network metadata request.
    public func retentionSettingDidChange(forGameID gameID: String? = nil) {
        guard retainOutdatedBackgrounds else {
            if let gameID { cancelRetainedBackgrounds(forGameID: gameID) }
            else { cancelRetainedBackgrounds() }
            return
        }
        if let gameID {
            guard retainsOutdatedBackgrounds(for: gameID) else {
                cancelRetainedBackgrounds(forGameID: gameID)
                return
            }
            guard let entries = cachedEntries, let generation = backgroundLoadGenerations[gameID],
                  let backgrounds = findBackgrounds(in: entries, for: gameID) else { return }
            scheduleRetainedBackgrounds(backgrounds, for: gameID, generation: generation)
            return
        }
        guard let entries = cachedEntries else { return }
        for (gameId, generation) in backgroundLoadGenerations {
            guard retainsOutdatedBackgrounds(for: gameId) else {
                cancelRetainedBackgrounds(forGameID: gameId)
                continue
            }
            guard let backgrounds = findBackgrounds(in: entries, for: gameId) else { continue }
            scheduleRetainedBackgrounds(backgrounds, for: gameId, generation: generation)
        }
    }

    /// Cancel outstanding archival downloads without deleting saved assets.
    public func cancelRetainedBackgrounds() {
        for task in backgroundRetentionTasks.values { task.cancel() }
        backgroundRetentionTasks.removeAll()
        backgroundRetentionTokens.removeAll()
    }

    /// A game's preference must never interrupt another game's cache work.
    public func cancelRetainedBackgrounds(forGameID gameID: String) {
        backgroundRetentionTasks.removeValue(forKey: gameID)?.cancel()
        backgroundRetentionTokens.removeValue(forKey: gameID)
    }

    internal func scheduleRetainedBackgrounds(_ backgrounds: [HoyoPlayBackground],
                                               for gameId: String, generation: UUID) {
        guard shouldContinueRetention(for: gameId, generation: generation) else { return }
        backgroundRetentionTasks.removeValue(forKey: gameId)?.cancel()
        let token = UUID()
        backgroundRetentionTokens[gameId] = token
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.retainReturnedBackgrounds(backgrounds, for: gameId, generation: generation)
            if self.backgroundRetentionTokens[gameId] == token {
                self.backgroundRetentionTasks.removeValue(forKey: gameId)
                self.backgroundRetentionTokens.removeValue(forKey: gameId)
            }
        }
        backgroundRetentionTasks[gameId] = task
    }

    /// Allows callers such as deterministic integration tests to await work
    /// that deliberately does not delay presentation of the selected group.
    internal func waitForRetainedBackgrounds(for gameId: String) async {
        await backgroundRetentionTasks[gameId]?.value
    }

    /// Retain the exact API resources without changing the selected group's
    /// published media or theme. Converted presentation files remain separate.
    internal func retainReturnedBackgrounds(_ backgrounds: [HoyoPlayBackground],
                                            for gameId: String, generation: UUID) async {
        var processed = Set<String>()
        for background in backgrounds {
            guard shouldContinueRetention(for: gameId, generation: generation) else { return }
            guard processed.insert(background.id).inserted else { continue }
            let fingerprint = backgroundGroupFingerprint(background)
            do {
                let stored = await loadGroupFingerprint(for: gameId, backgroundId: background.id)
                guard shouldContinueRetention(for: gameId, generation: generation) else { return }
                if let stored, stored != fingerprint { continue }
                if stored == nil { try await persistGroupFingerprint(fingerprint, for: gameId) }
            } catch {
                await logWriter.warning("无法保存背景组身份: \(gameId)/\(background.id)", module: "BackgroundMediaService")
                continue
            }

            let assets: [(AssetType, String?, String)] = [
                (.background, background.background?.url, "webp"),
                (.video, background.video?.url, "webm"),
                (.theme, background.theme?.url, "webp"),
                (.icon, background.icon?.url, "webp"),
                (.iconHover, background.icon?.hoverURL, "webp")
            ]
            for (type, source, ext) in assets {
                guard shouldContinueRetention(for: gameId, generation: generation) else { return }
                guard let source, !source.isEmpty, let url = URL(string: source) else { continue }
                if await hasSubCache(for: gameId, backgroundId: background.id, type: type, ext: ext) { continue }

                // Download away from the cache group: a newer load can archive
                // that group while this request is in flight. Publish only if
                // both the load and the group's identity are still current.
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("miplay-background-\(UUID().uuidString)")
                await downloadFile(from: url, to: temporary.path)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard shouldContinueRetention(for: gameId, generation: generation) else { return }
                guard await loadGroupFingerprint(for: gameId, backgroundId: background.id) == fingerprint else { return }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { continue }

                let destination = await cacheURL(gameId: gameId, backgroundId: background.id, type: type, ext: ext)
                do {
                    // Another concurrent load may have completed the same
                    // asset; keep that result instead of replacing it.
                    if await hasSubCache(for: gameId, backgroundId: background.id, type: type, ext: ext) { continue }
                    guard shouldContinueRetention(for: gameId, generation: generation),
                          await loadGroupFingerprint(for: gameId, backgroundId: background.id) == fingerprint else { return }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch {
                    await logWriter.warning("背景素材缓存失败: \(gameId)/\(background.id)/\(type.rawValue)", module: "BackgroundMediaService")
                }
            }
        }
    }

    private func shouldContinueRetention(for gameId: String, generation: UUID) -> Bool {
        !Task.isCancelled && retainsOutdatedBackgrounds(for: gameId) && backgroundLoadGenerations[gameId] == generation
    }
}
