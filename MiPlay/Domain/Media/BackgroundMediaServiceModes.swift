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

    /// 设置背景模式
    public func setBackgroundMode(for gameId: String, mode: BackgroundMode, customPath: String? = nil) async {
        backgroundModes[gameId] = mode
        if mode == .custom, let path = customPath {
            customImagePaths[gameId] = path
        } else {
            customImagePaths.removeValue(forKey: gameId)
        }
        let modesSnapshot = backgroundModes.mapValues { $0.rawValue }
        let customPathsSnapshot = customImagePaths
        do {
            try await persistenceStore.updateAppData { appData in
                appData.backgroundModes = modesSnapshot
                appData.customImagePaths = customPathsSnapshot
            }
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
        // 非 custom 模式：先计算 API 背景集合指纹，仅在集合内容变化时按
        // diff 清理；缓存按组目录保留。
        if mode != .custom {
            do {
                let entries = try await fetchGameBackgrounds()
                if let backgrounds = findBackgrounds(in: entries, for: gameId) {
                    let fingerprint = collectionFingerprint(
                        from: backgrounds,
                        sourceID: backgroundSourceID
                    )
                    if let persisted = await loadPersistedCollectionFingerprint(for: gameId),
                       persisted != fingerprint {
                        await pruneCacheForCollectionChange(
                            gameId: gameId,
                            currentBackgrounds: backgrounds,
                            persisted: persisted
                        )
                    }
                    await persistCollectionFingerprint(fingerprint, for: gameId)

                    if let currentBgId = resolveCurrentBackgroundId(from: backgrounds),
                       await allCacheFilesExist(for: gameId, backgroundId: currentBgId) {
                        await presentLoadedMedia(for: gameId, backgroundId: currentBgId)
                        return
                    }
                }
            } catch {
                await logWriter.warning(
                    "API 请求失败，保留现有缓存与指纹: \(error.localizedDescription)",
                    module: "BackgroundMediaService"
                )
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

            // 用户指令（2026-10-05）：固定使用 API 解析到的第一个背景资源，
            // 不再提供背景组切换。首个条目有可播放视频时走视频管线，
            // 否则展示其静态背景图。
            guard let current = backgrounds.first(where: {
                ($0.background?.url ?? "").isEmpty == false || ($0.video?.url ?? "").isEmpty == false
            }) else {
                await loadBackgroundFromAPI(backgrounds: backgrounds, gameId: gameId)
                return
            }
            guard current.type == "BACKGROUND_TYPE_VIDEO",
                  (current.video?.url ?? "").isEmpty == false else {
                // 首个条目无视频素材 → 使用其背景图
                await loadBackgroundFromAPI(backgrounds: backgrounds, gameId: gameId)
                return
            }

            let videoBg = current
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
        // 固定使用第一个有背景图的条目（忽略 type）
        guard let bgEntry = backgrounds.first(where: { ($0.background?.url ?? "").isEmpty == false }),
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

        // Keep theme loading inside the scheduled operation so the task does
        // not report completion while a detached media write is still active.
        await downloadAndTranscodeTheme(from: bgEntry, gameId: gameId, backgroundId: bgId)

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

    /// 下载文件到指定路径。预览等可取消流程会向底层 URLSession 传播取消。
    internal func downloadFile(from url: URL, to destPath: String) async {
        let network = networkProvider
        let sessionID = UUID()
        let stream = await network.download(from: url, to: destPath, sessionID: sessionID)
        await withTaskCancellationHandler {
            for await _ in stream {
                if Task.isCancelled { break }
            }
        } onCancel: {
            Task { await network.cancelDownload(sessionID: sessionID) }
        }
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

        if FileManager.default.fileExists(atPath: bgSub.path) {
            backgroundStillImagePaths[gameId] = bgSub.path
        }

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
            try await persistenceStore.updateAppData { appData in
                appData.lastCachedBackgroundIds[gameId] = bgId
            }
        } catch {
            await logWriter.warning("背景 ID 持久化失败: \(error.localizedDescription)", module: "BackgroundMediaService")
        }
    }

}
