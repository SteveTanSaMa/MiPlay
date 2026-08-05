// BackgroundMediaServiceModes.swift
// MiPlay

@preconcurrency import Foundation

// Source: Architecture Design -> Service Contract -> BackgroundMediaService
// Media mode selection, remote loading, and presentation.
extension BackgroundMediaService {
    // MARK: - Mode Management

    public func getBackgroundMode(for gameId: String) -> BackgroundMode {
        return backgroundModes[gameId] ?? .dynamic
    }

    /// Returns only groups backed by an actual image or video URL from the
    /// selected API response. The source identity is kept with each group.
    public func getBackgroundGroups(for gameId: String) async throws -> [BackgroundGroup] {
        let entries = try await fetchGameBackgrounds()
        guard let backgrounds = findBackgrounds(in: entries, for: gameId) else {
            throw BackgroundError.unavailable("未找到游戏素材信息")
        }
        let groups = backgrounds.compactMap { background -> BackgroundGroup? in
            let imageURL = background.background?.url.flatMap(URL.init(string:))
            let videoURL = background.video?.url.flatMap(URL.init(string:))
            let themeURL = background.theme?.url.flatMap(URL.init(string:))
            guard imageURL != nil || videoURL != nil else { return nil }
            return BackgroundGroup(
                groupID: background.id,
                gameID: gameId,
                sourceID: "hoyoPlay",
                version: background.id,
                type: background.type,
                backgroundURL: imageURL,
                videoURL: videoURL,
                themeURL: themeURL
            )
        }
        backgroundGroups[gameId] = groups
        return groups
    }

    public func getSelectedBackgroundGroupID(for gameId: String) -> String? {
        selectedBackgroundGroupIDs[gameId] ?? lastCachedBackgroundIds[gameId]
    }

    /// Loads the complete target group first. Selection is written only after
    /// rendering is ready and AppData round-trips the new group ID.
    public func selectBackgroundGroup(for gameId: String, groupID: String) async throws {
        let operationID = UUID()
        await logWriter.record(.init(
            level: .info,
            module: "BackgroundMediaService",
            eventName: "background.group.select",
            operationID: operationID,
            gameID: gameId,
            phase: "load",
            result: "inProgress",
            messageCode: "background.group.select_started"
        ))
        let groups = try await getBackgroundGroups(for: gameId)
        guard groups.contains(where: { $0.groupID == groupID }) else {
            throw BackgroundError.unavailable(groupID)
        }
        let oldSelection = selectedBackgroundGroupIDs[gameId]
        let oldState = mediaStates[gameId]
        selectedBackgroundGroupIDs[gameId] = groupID
        backgroundGroupErrors.removeValue(forKey: gameId)
        await loadMedia(for: gameId)
        guard case .ready = mediaStates[gameId] else {
            selectedBackgroundGroupIDs[gameId] = oldSelection
            if let oldState { mediaStates[gameId] = oldState }
            let detail = "目标背景组未达到可渲染门槛，已保留上一组"
            backgroundGroupErrors[gameId] = detail
            throw BackgroundError.unavailable(detail)
        }
        do {
            var appData = try await persistenceStore.readAppData()
            appData.backgroundGroupSelections[gameId] = groupID
            var settings = appData.perGameSettings[gameId] ?? PerGameSettings(gameID: gameId)
            settings.selectedBackgroundGroupID = groupID
            settings.lastFailure = nil
            appData.perGameSettings[gameId] = settings
            try await persistenceStore.writeAppData(appData)
            let verified = try await persistenceStore.readAppData()
            guard verified.backgroundGroupSelections[gameId] == groupID,
                  verified.perGameSettings[gameId]?.selectedBackgroundGroupID == groupID else {
                throw BackgroundError.persistenceFailed("选择写回后重读不一致")
            }
            await logWriter.record(.init(
                level: .info,
                module: "BackgroundMediaService",
                eventName: "background.group.select",
                operationID: operationID,
                gameID: gameId,
                phase: "commit",
                result: "completed",
                messageCode: "background.group.select_completed"
            ))
        } catch {
            selectedBackgroundGroupIDs[gameId] = oldSelection
            if let oldState { mediaStates[gameId] = oldState }
            let detail = error.localizedDescription
            backgroundGroupErrors[gameId] = detail
            await logWriter.record(.init(
                level: .error,
                module: "BackgroundMediaService",
                eventName: "background.group.select",
                operationID: operationID,
                gameID: gameId,
                phase: "rollback",
                result: "failed",
                errorCategory: "writeFailed",
                messageCode: "background.group.select_rolled_back"
            ))
            throw error is BackgroundError ? error : BackgroundError.persistenceFailed(detail)
        }
    }

    /// 设置背景模式
    public func setBackgroundMode(for gameId: String, mode: BackgroundMode, customPath: String? = nil) async {
        backgroundModes[gameId] = mode
        if mode == .custom, let path = customPath {
            customImagePaths[gameId] = path
        } else {
            customImagePaths.removeValue(forKey: gameId)
        }
        do {
            var appData = try await persistenceStore.readAppData()
            appData.backgroundModes = backgroundModes.mapValues { $0.rawValue }
            appData.customImagePaths = customImagePaths
            try await persistenceStore.writeAppData(appData)
        } catch {
            await logWriter.error("背景设置持久化失败: \(error.localizedDescription)", module: "BackgroundMediaService")
        }
        await loadMedia(for: gameId)
    }

    // MARK: - Media Loading

    /// 加载指定游戏的背景素材
    public func loadMedia(for gameId: String) async {
        let operationID = UUID()
        await logWriter.record(.init(
            level: .info,
            module: "BackgroundMediaService",
            eventName: "background.load",
            operationID: operationID,
            gameID: gameId,
            phase: "started",
            result: "inProgress",
            messageCode: "background.load_started"
        ))
        mediaStates[gameId] = .loading

        let mode = backgroundModes[gameId] ?? .dynamic

        // Source: ADR 019 — content-addressable 缓存策略
        // 非 custom 模式：检查 background.id 是否匹配已缓存版本
        if mode != .custom {
            do {
                let entries = try await fetchGameBackgrounds()
                if let backgrounds = findBackgrounds(in: entries, for: gameId),
                   let currentBgId = resolveCurrentBackgroundId(from: backgrounds, for: mode, gameId: gameId) {
                    let cachedId = lastCachedBackgroundIds[gameId]
                    if cachedId == currentBgId {
                        // 同一背景 ID — 检查缓存文件是否完整
                        if await allCacheFilesExist(for: gameId, backgroundId: currentBgId) {
                            await presentLoadedMedia(for: gameId, backgroundId: currentBgId)
                            return
                        }
                    } else if let oldId = cachedId {
                        // 背景已更换 — 清除旧缓存
                        _ = try? await mediaCacheManager.clearCache(forGameId: gameId, backgroundId: oldId)
                        await logWriter.info("清除旧背景缓存: \(gameId)/\(oldId)", module: "BackgroundMediaService")
                    }
                }
            } catch {
                await logWriter.warning("API 请求失败，尝试重新下载: \(error.localizedDescription)", module: "BackgroundMediaService")
            }
        }

        switch mode {
        case .dynamic:
            await loadDynamicMedia(for: gameId)
        case .static:
            await loadStaticMedia(for: gameId)
        case .custom:
            await loadCustomMedia(for: gameId)
        }
    }

    /// 从 HoyoPlay API 获取素材信息（5 分钟内复用缓存）
    internal func fetchGameBackgrounds() async throws -> [HoyoPlayGameEntry] {
        if let entries = cachedEntries, let ts = cacheTimestamp, Date().timeIntervalSince(ts) < 300 {
            return entries
        }
        await logWriter.record(.init(
            level: .info,
            module: "BackgroundMediaService",
            eventName: "background.api",
            phase: "request",
            result: "inProgress",
            messageCode: "background.api_started"
        ))
        let response: HoyoPlayResponse = try await networkProvider.request(
            HoyoPlayResponse.self,
            from: hoyoPlayURL
        )
        await logWriter.record(.init(
            level: .info,
            module: "BackgroundMediaService",
            eventName: "background.api",
            phase: "response",
            result: "completed",
            messageCode: "background.api_completed",
            fields: ["itemCount": String(response.data.gameInfoList.count)]
        ))
        cachedEntries = response.data.gameInfoList
        cacheTimestamp = Date()
        return response.data.gameInfoList
    }

    /// 在 API 返回中找到匹配游戏的素材条目
    internal func findBackgrounds(in entries: [HoyoPlayGameEntry], for gameId: String) -> [HoyoPlayBackground]? {
        guard let biz = gameKeyMap[gameId] else { return nil }
        return entries.first { $0.game.biz == biz }?.backgrounds
    }

    // MARK: - Dynamic Mode（视频背景 + theme 叠加）

    internal func loadDynamicMedia(for gameId: String) async {
        do {
            let entries = try await fetchGameBackgrounds()
            guard let backgrounds = findBackgrounds(in: entries, for: gameId) else {
                mediaStates[gameId] = .failed("未找到游戏素材信息")
                return
            }

            // 优先找 BACKGROUND_TYPE_VIDEO 且 video.url 非空
            let preferredID = selectedBackgroundGroupIDs[gameId]
            guard let videoBg = backgrounds.first(where: {
                $0.id == preferredID && $0.type == "BACKGROUND_TYPE_VIDEO" && ($0.video?.url ?? "").isEmpty == false
            }) ?? backgrounds.first(where: {
                $0.type == "BACKGROUND_TYPE_VIDEO" && ($0.video?.url ?? "").isEmpty == false
            }) else {
                // 无视频素材 → 降级到静态模式
                await loadBackgroundFromAPI(backgrounds: backgrounds, gameId: gameId)
                return
            }

            let bgId = videoBg.id

            // Source: ADR 019 — content-addressable 缓存
            // 检查同一 backgroundId 的缓存是否完整
            if await hasSubCache(for: gameId, backgroundId: bgId, type: .video, ext: "mp4"),
               await hasSubCache(for: gameId, backgroundId: bgId, type: .background, ext: "png") {
                await presentLoadedMedia(for: gameId, backgroundId: bgId)
                return
            }

            // === 下载背景图 (background.webp → .png) ===
            // Source: ADR 019 — 空 URL 跳过
            if let bgURLStr = videoBg.background?.url, !bgURLStr.isEmpty,
               let bgURL = URL(string: bgURLStr) {
                let bgWebpDest = await cacheURL(gameId: gameId, backgroundId: bgId, type: .background, ext: "webp").path
                await downloadFile(from: bgURL, to: bgWebpDest)
                if FileManager.default.fileExists(atPath: bgWebpDest) {
                    let bgPngDest = await cacheURL(gameId: gameId, backgroundId: bgId, type: .background, ext: "png").path
                    _ = try? await mediaTranscoder.transcodeWebPToPNG(inputPath: bgWebpDest, outputPath: bgPngDest)
                    _ = try? FileManager.default.removeItem(atPath: bgWebpDest)
                }
            }

            // === 下载视频 (video.webm → .mp4) ===
            // Source: ADR 019 — 空 URL 跳过
            if let videoURLStr = videoBg.video?.url, !videoURLStr.isEmpty,
               let videoURL = URL(string: videoURLStr) {
                let webmDest = await cacheURL(gameId: gameId, backgroundId: bgId, type: .video, ext: "webm").path
                await downloadFile(from: videoURL, to: webmDest)
                if FileManager.default.fileExists(atPath: webmDest) {
                    let mp4Dest = await cacheURL(gameId: gameId, backgroundId: bgId, type: .video, ext: "mp4").path
                    _ = try? await mediaTranscoder.transcodeWebMToMP4(inputPath: webmDest, outputPath: mp4Dest)
                    _ = try? FileManager.default.removeItem(atPath: webmDest)
                }
            }

            // === 下载 theme 装饰图 (theme.webp → .png) ===
            await downloadAndTranscodeTheme(from: videoBg, gameId: gameId, backgroundId: bgId)

            // === 展示结果 ===
            await presentLoadedMedia(for: gameId, backgroundId: bgId)

        } catch {
            await logWriter.error("HoyoPlay API 请求失败: \(error.localizedDescription)", module: "BackgroundMediaService")
            mediaStates[gameId] = .failed("API 不可用")
        }
    }

    // MARK: - Static Mode（仅背景图）

    internal func loadStaticMedia(for gameId: String) async {
        do {
            let entries = try await fetchGameBackgrounds()
            guard let backgrounds = findBackgrounds(in: entries, for: gameId) else {
                mediaStates[gameId] = .failed("未找到游戏素材信息")
                return
            }

            await loadBackgroundFromAPI(backgrounds: backgrounds, gameId: gameId)

        } catch {
            await logWriter.error("HoyoPlay API 请求失败: \(error.localizedDescription)", module: "BackgroundMediaService")
            mediaStates[gameId] = .failed("API 不可用")
        }
    }

    // MARK: - Unified API Loading

    /// 从 API backgrounds 中加载背景图（.webp → .png），同时异步加载 theme
    internal func loadBackgroundFromAPI(backgrounds: [HoyoPlayBackground], gameId: String) async {
        // 找第一个有背景图的条目（忽略 type）
        let preferredID = selectedBackgroundGroupIDs[gameId]
        guard let bgEntry = backgrounds.first(where: {
                  $0.id == preferredID && ($0.background?.url ?? "").isEmpty == false
              }) ?? backgrounds.first(where: { ($0.background?.url ?? "").isEmpty == false }),
              let bgURLStr = bgEntry.background?.url,
              let bgURL = URL(string: bgURLStr) else {
            mediaStates[gameId] = .failed("无可用背景素材")
            return
        }

        let bgId = bgEntry.id

        // Source: ADR 019 — content-addressable 缓存检查
        if await hasSubCache(for: gameId, backgroundId: bgId, type: .background, ext: "png") {
            await presentLoadedMedia(for: gameId, backgroundId: bgId)
            return
        }

        // 异步加载 theme
        Task { await downloadAndTranscodeTheme(from: bgEntry, gameId: gameId, backgroundId: bgId) }

        // 下载 background.webp → 转码 → .png
        // Source: ADR 019 — 空 URL 跳过
        let webpDest = await cacheURL(gameId: gameId, backgroundId: bgId, type: .background, ext: "webp").path
        await downloadFile(from: bgURL, to: webpDest)

        if FileManager.default.fileExists(atPath: webpDest) {
            let pngDest = await cacheURL(gameId: gameId, backgroundId: bgId, type: .background, ext: "png").path
            _ = try? await mediaTranscoder.transcodeWebPToPNG(inputPath: webpDest, outputPath: pngDest)
            _ = try? FileManager.default.removeItem(atPath: webpDest)
        }

        await presentLoadedMedia(for: gameId, backgroundId: bgId)
    }

    // MARK: - Custom Mode

    internal func loadCustomMedia(for gameId: String) async {
        guard let customPath = customImagePaths[gameId],
              FileManager.default.fileExists(atPath: customPath) else {
            mediaStates[gameId] = .failed("自定义图片路径无效")
            return
        }
        mediaStates[gameId] = .ready(localPath: customPath, isVideo: false)
    }

    // MARK: - Helpers

    /// 下载文件到指定路径
    internal func downloadFile(from url: URL, to destPath: String) async {
        let stream = await networkProvider.download(from: url, to: destPath)
        for await _ in stream {}
    }
    internal func downloadAndTranscodeTheme(from bg: HoyoPlayBackground, gameId: String, backgroundId: String) async {
        // Source: ADR 019 — 空 URL 跳过
        guard let urlStr = bg.theme?.url, !urlStr.isEmpty,
              let url = URL(string: urlStr) else { return }

        if await hasSubCache(for: gameId, backgroundId: backgroundId, type: .theme, ext: "png") {
            themeImagePaths[gameId] = await cacheURL(gameId: gameId, backgroundId: backgroundId, type: .theme, ext: "png").path
            return
        }

        let webpDest = await cacheURL(gameId: gameId, backgroundId: backgroundId, type: .theme, ext: "webp").path
        await downloadFile(from: url, to: webpDest)

        if FileManager.default.fileExists(atPath: webpDest) {
            let pngDest = await cacheURL(gameId: gameId, backgroundId: backgroundId, type: .theme, ext: "png").path
            _ = try? await mediaTranscoder.transcodeWebPToPNG(inputPath: webpDest, outputPath: pngDest)
            _ = try? FileManager.default.removeItem(atPath: webpDest)
            if await hasSubCache(for: gameId, backgroundId: backgroundId, type: .theme, ext: "png") {
                themeImagePaths[gameId] = pngDest
                await logWriter.debug("Theme 图已缓存: \(gameId)/\(backgroundId)", module: "BackgroundMediaService")
            }
        }
    }

    /// 检查 theme 缓存（从缓存读取，不触发网络请求）
    /// Source: ADR 019 — 接受 backgroundId，使用子目录缓存
    internal func tryLoadThemeFromCache(for gameId: String, backgroundId: String) async {
        if await hasSubCache(for: gameId, backgroundId: backgroundId, type: .theme, ext: "png") {
            themeImagePaths[gameId] = await cacheURL(gameId: gameId, backgroundId: backgroundId, type: .theme, ext: "png").path
        }
    }

    /// 展示已加载的媒体（优先视频 mp4，降级背景 png）
    /// Source: ADR 019 — 接受 backgroundId，使用子目录缓存，成功后持久化
    internal func presentLoadedMedia(for gameId: String, backgroundId: String? = nil) async {
        guard let bgId = backgroundId else {
            // 降级：无 backgroundId 时尝试旧版扁平缓存
            let mp4Key = cacheKey(gameId: gameId, type: .video, ext: "mp4")
            let bgKey = cacheKey(gameId: gameId, type: .background, ext: "png")
            if await mediaCacheManager.hasCachedFile(for: mp4Key) {
                mediaStates[gameId] = .ready(localPath: await mediaCacheManager.cachedFileURL(for: mp4Key).path, isVideo: true)
            } else if await mediaCacheManager.hasCachedFile(for: bgKey) {
                mediaStates[gameId] = .ready(localPath: await mediaCacheManager.cachedFileURL(for: bgKey).path, isVideo: false)
            } else {
                mediaStates[gameId] = .failed("所有素材加载失败")
            }
            return
        }

        let mp4Sub = await cacheURL(gameId: gameId, backgroundId: bgId, type: .video, ext: "mp4")
        let bgSub = await cacheURL(gameId: gameId, backgroundId: bgId, type: .background, ext: "png")

        if FileManager.default.fileExists(atPath: mp4Sub.path) {
            mediaStates[gameId] = .ready(localPath: mp4Sub.path, isVideo: true)
            await tryLoadThemeFromCache(for: gameId, backgroundId: bgId)
        } else if FileManager.default.fileExists(atPath: bgSub.path) {
            mediaStates[gameId] = .ready(localPath: bgSub.path, isVideo: false)
            await tryLoadThemeFromCache(for: gameId, backgroundId: bgId)
        } else {
            mediaStates[gameId] = .failed("所有素材加载失败")
            return
        }

        // 持久化 lastCachedBackgroundId
        lastCachedBackgroundIds[gameId] = bgId
        do {
            var appData = try await persistenceStore.readAppData()
            appData.lastCachedBackgroundIds[gameId] = bgId
            try await persistenceStore.writeAppData(appData)
        } catch {
            await logWriter.warning("背景 ID 持久化失败: \(error.localizedDescription)", module: "BackgroundMediaService")
        }
    }

}
