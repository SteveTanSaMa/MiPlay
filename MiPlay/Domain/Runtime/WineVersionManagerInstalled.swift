// WineVersionManagerInstalled.swift
// MiPlay

import Foundation

// Source: Architecture Design -> WineVersionManager -> installed runtime records
extension WineVersionManager {
    public func getInstalledVersions() async -> [WineVersionInfo] {
        let versionsDir = await wineVersionsDirectory()
        var installed: [WineVersionInfo] = []

        guard FileManager.default.fileExists(atPath: versionsDir.path) else { return installed }

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: versionsDir.path)
            for item in contents {
                guard Self.managedWineTags.contains(item), installedVersionTags.contains(item) else { continue }
                let itemPath = versionsDir.appendingPathComponent(item, isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL
                let wineBinPath = itemPath.appendingPathComponent("bin/wine").path
                guard itemPath.path.hasPrefix(versionsDir.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
                      FileManager.default.isExecutableFile(atPath: wineBinPath) else { continue }
                if FileManager.default.fileExists(atPath: wineBinPath) {
                    installed.append(WineVersionInfo(
                        id: item,
                        tagName: item,
                        name: item,
                        downloadURL: URL(string: "about:blank")!,
                        fileSize: 0,
                        publishedAt: Date(),
                        isDownloaded: true,
                        isSelected: selectedVersionTag == item
                    ))
                }
            }
        } catch {
            Task { await logWriter.error("获取已安装版本列表失败: \(error)", module: "WineVersionManager") }
        }

        return installed
    }

    /// 标记版本为已安装（下载+解压完成后调用）
    public func markVersionInstalled(tagName: String) async throws {
        guard Self.managedWineTags.contains(tagName) else {
            throw VersionManagerError.versionNotFound(tagName)
        }
        let versionsDir = await wineVersionsDirectory()
        let finalURL = versionsDir.appendingPathComponent(tagName, isDirectory: true)
        let canonicalRoot = versionsDir.resolvingSymlinksInPath().standardizedFileURL
        let canonicalVersion = finalURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalVersion.path.hasPrefix(canonicalRoot.path + "/"),
              FileManager.default.isExecutableFile(atPath: canonicalVersion.appendingPathComponent("bin/wine").path) else {
            throw VersionManagerError.extractionFailed("Wine binary 未通过安装验证")
        }
        var appData = try await persistenceStore.readAppData()
        var candidate = Set(appData.installedWineVersions)
        candidate.insert(tagName)
        appData.installedWineVersions = candidate.sorted()
        try await persistenceStore.writeAppData(appData)
        let committed = try await persistenceStore.readAppData()
        guard committed.installedWineVersions.contains(tagName) else {
            throw VersionManagerError.persistenceFailed("安装记录写入后重读未包含 \(tagName)")
        }
        installedVersionTags = Set(committed.installedWineVersions)
        await logWriter.record(.init(
            level: .info,
            module: "WineVersionManager",
            eventName: "wine.install.commit",
            wineTag: tagName,
            phase: "installedRecord",
            result: "completed",
            messageCode: "wine.install_record_committed",
            fields: ["persistence": "verified"]
        ))
    }

    /// 删除指定版本
    public func deleteVersion(tagName: String) async throws {
        guard Self.managedWineTags.contains(tagName), BuiltInWineVersions.source(for: tagName) != nil else {
            throw VersionManagerError.versionNotFound(tagName)
        }
        guard !activeDownloadTags.values.contains(tagName) else {
            throw VersionManagerError.recoveryRequired("Wine 版本正在使用或下载中，不能删除")
        }

        var appData = try await persistenceStore.readAppData()
        guard appData.installedWineVersions.contains(tagName) else {
            throw VersionManagerError.versionNotFound("未找到已安装记录: \(tagName)")
        }
        guard appData.selectedWineVersion != tagName, selectedVersionTag != tagName else {
            throw VersionManagerError.recoveryRequired("当前选中的 Wine 版本不能删除")
        }
        if appData.recoveryRecords.contains(where: {
            $0.kind == "wineInstall" && $0.target == tagName && $0.resolvedAt == nil
        }) {
            throw VersionManagerError.recoveryRequired("Wine 版本存在未完成恢复事实")
        }

        let destDir = await wineVersionsDirectory()
        let canonicalBase = destDir.resolvingSymlinksInPath().standardizedFileURL
        let versionURL = destDir.appendingPathComponent(tagName, isDirectory: true)
        let canonicalVersion = versionURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalVersion.path.hasPrefix(canonicalBase.path + "/") else {
            throw VersionManagerError.sourceInvalid("Wine 删除路径不在托管目录内")
        }

        let deletingURL = canonicalBase.appendingPathComponent(".deleting", isDirectory: true)
        try FileManager.default.createDirectory(at: deletingURL, withIntermediateDirectories: true)
        let archiveURL = deletingURL.appendingPathComponent("\(tagName)-\(UUID().uuidString)", isDirectory: true)
        var movedForDelete = false
        if FileManager.default.fileExists(atPath: canonicalVersion.path) {
            try FileManager.default.moveItem(at: canonicalVersion, to: archiveURL)
            movedForDelete = true
        }

        appData.installedWineVersions.removeAll { $0 == tagName }
        do {
            try await persistenceStore.writeAppData(appData)
            let verified = try await persistenceStore.readAppData()
            guard !verified.installedWineVersions.contains(tagName) else {
                throw VersionManagerError.persistenceFailed("Wine 删除记录写回后仍存在")
            }
        } catch {
            if movedForDelete {
                do { try FileManager.default.moveItem(at: archiveURL, to: canonicalVersion) }
                catch let restoreError {
                    let detail = "Wine 删除记录写入失败: \(error.localizedDescription); 原目录恢复失败: \(restoreError.localizedDescription)"
                    let recoveryError = await recordRecovery(RecoveryRecord(
                        kind: "wineDelete",
                        target: tagName,
                        phase: "deletePersistence",
                        detail: detail,
                        payload: ["archivePath": archiveURL.path, "finalPath": canonicalVersion.path]
                    ))
                    throw VersionManagerError.recoveryRequired(recoveryError.map { "\(detail); \($0)" } ?? detail)
                }
            }
            throw error
        }

        if movedForDelete {
            do { try FileManager.default.removeItem(at: archiveURL) }
            catch {
                let detail = "Wine 删除记录已提交，但临时目录清理失败: \(error.localizedDescription)"
                let recoveryError = await recordRecovery(RecoveryRecord(
                    kind: "wineDelete",
                    target: tagName,
                    phase: "deleteCleanup",
                    detail: detail,
                    payload: ["archivePath": archiveURL.path]
                ))
                throw VersionManagerError.recoveryRequired(recoveryError.map { "\(detail); \($0)" } ?? detail)
            }
        }
        installedVersionTags.remove(tagName)
        await logWriter.info("Wine 版本已删除: \(tagName)", module: "WineVersionManager")
        await logWriter.record(.init(
            level: .info,
            module: "WineVersionManager",
            eventName: "wine.delete",
            wineTag: tagName,
            phase: "completed",
            result: "completed",
            messageCode: "wine.delete_completed",
            fields: ["persistence": "verified", "cleanupVerified": "true"]
        ))
    }

}
