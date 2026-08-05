//
//  PersistenceStore.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Service Contract -> PersistenceStore
// Source: Architecture Design -> ADR 009 -> schema, backup, atomic verification

/// Serializes access to the single AppData JSON file.
public actor PersistenceStore {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let baseURL: URL
    private let logWriter: LogWriter?
    private var injectedWriteFailure: String?

    public init(baseURL: URL? = nil, logWriter: LogWriter? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.injectedWriteFailure = nil
        self.logWriter = logWriter

        if let baseURL { self.baseURL = baseURL }
        else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseURL = appSupport.appendingPathComponent("MiPlay", isDirectory: true)
        }
    }

    // MARK: - AppData API

    public func loadAppData() throws -> AppDataLoadResult {
        let url = try allowedURL(for: "AppData")
        guard fileManager.fileExists(atPath: url.path) else {
            recordPersistenceEvent(
                eventName: "persistence.read",
                phase: "read",
                result: "completed",
                messageCode: "persistence.initial_data"
            )
            return AppDataLoadResult(data: AppData(), state: .initialData)
        }

        let rawData: Data
        do { rawData = try Data(contentsOf: url) }
        catch { throw StoreError.readFailed(error.localizedDescription) }

        do {
            if let object = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
               let schemaVersion = object["schemaVersion"] as? Int,
               schemaVersion > AppData.currentSchemaVersion {
                throw StoreError.unsupportedSchema(schemaVersion)
            }
            let decoded = try decoder.decode(AppData.self, from: rawData)
            guard decoded.schemaVersion <= AppData.currentSchemaVersion else {
                throw StoreError.unsupportedSchema(decoded.schemaVersion)
            }
            guard decoded.schemaVersion < AppData.currentSchemaVersion else {
                recordPersistenceEvent(
                    eventName: "persistence.read",
                    phase: "read",
                    result: "completed",
                    messageCode: "persistence.read_completed"
                )
                return AppDataLoadResult(data: decoded, state: .readable)
            }

            // Legacy path records are decoded as migrationRequired by Game. Keep the
            // original file and backup before writing the schema-2 representation.
            try createBackup("AppData")
            var migrated = decoded
            migrated.schemaVersion = AppData.currentSchemaVersion
            do {
                let migratedData = try encode(migrated)
                try atomicWrite(migratedData, to: url, preserveBackup: false)
                let verified = try decodeAppData(at: url)
                recordPersistenceEvent(
                    eventName: "persistence.migration",
                    phase: "verified",
                    result: "completed",
                    messageCode: "persistence.migration_completed"
                )
                return AppDataLoadResult(data: verified, state: .migratedAndVerified)
            } catch let migrationError {
                recordPersistenceEvent(
                    eventName: "persistence.migration",
                    phase: "restore",
                    result: "failed",
                    errorCategory: "migrationFailed",
                    messageCode: "persistence.migration_failed"
                )
                do {
                    try restoreFileFromBackup(url)
                } catch let restoreError {
                    throw StoreError.migrationFailed("迁移失败: \(migrationError.localizedDescription); 原始数据恢复失败: \(restoreError.localizedDescription)")
                }
                throw StoreError.migrationFailed(migrationError.localizedDescription)
            }
        } catch let error as StoreError {
            if case .unsupportedSchema = error { throw error }
            throw error
        } catch {
            let diagnosticPath = try? preserveCorruptFile(at: url)
            recordPersistenceEvent(
                eventName: "persistence.corruption",
                phase: "backup",
                result: "recoveryRequired",
                errorCategory: "persistenceCorrupted",
                messageCode: "persistence.corrupt_preserved"
            )
            let backup = backupURL(for: url)
            if (try? decodeAppData(at: backup)) != nil {
                return AppDataLoadResult(
                    data: nil,
                    state: .restoreAvailable(diagnosticPath: diagnosticPath?.path ?? url.path)
                )
            }
            return AppDataLoadResult(
                data: nil,
                state: .recoveryFailed(diagnosticPath: diagnosticPath?.path)
            )
        }
    }

    public func readAppData() throws -> AppData {
        let result = try loadAppData()
        guard let data = result.data else {
            switch result.state {
            case .restoreAvailable(let path): throw StoreError.recoveryRequired(path)
            case .recoveryFailed(let path): throw StoreError.recoveryRequired(path ?? "AppData")
            default: throw StoreError.recoveryRequired("AppData")
            }
        }
        return data
    }

    public func writeAppData(_ data: AppData) throws {
        if let injectedWriteFailure {
            recordPersistenceEvent(
                eventName: "persistence.write",
                phase: "write",
                result: "failed",
                errorCategory: "writeFailed",
                messageCode: "persistence.write_injected_failure"
            )
            throw StoreError.writeFailed(injectedWriteFailure)
        }
        guard data.schemaVersion == AppData.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(data.schemaVersion)
        }
        let url = try allowedURL(for: "AppData")
        let encoded = try encode(data)
        try atomicWrite(encoded, to: url, preserveBackup: fileManager.fileExists(atPath: url.path))
        do {
            _ = try decodeAppData(at: url)
            recordPersistenceEvent(
                eventName: "persistence.write",
                phase: "verified",
                result: "completed",
                messageCode: "persistence.write_completed"
            )
        } catch {
            // An invalid post-replace read is never committed. Restore the known-good
            // backup before returning the write error.
            if fileManager.fileExists(atPath: backupURL(for: url).path) {
                do {
                    try restoreFileFromBackup(url)
                } catch {
                    throw StoreError.writeFailed("写入后验证失败，且恢复备份失败: \(error.localizedDescription)")
                }
            }
            throw StoreError.writeFailed("写入后重新读取验证失败: \(error.localizedDescription)")
        }
    }

    /// Test and diagnostics seam for exercising commit failure paths without
    /// replacing the real atomic writer.
    public func injectWriteFailure(_ detail: String = "注入的 AppData 写入失败") {
        injectedWriteFailure = detail
    }

    public func setWriteFailure(_ detail: String?) {
        injectedWriteFailure = detail
    }

    public func clearWriteFailure() {
        injectedWriteFailure = nil
    }

    public func appendRecoveryRecord(_ record: RecoveryRecord) throws {
        var data = try readAppData()
        data.recoveryRecords.removeAll { $0.id == record.id }
        data.recoveryRecords.append(record)
        try writeAppData(data)
    }

    /// Writes a recovery guard beside AppData.json. This file is deliberately
    /// independent from the AppData commit path so a failed AppData write does
    /// not erase the only cross-restart protection for an external side effect.
    public func writeRecoveryGuard(_ record: RecoveryRecord) throws {
        let url = try recoveryGuardURL(for: record.id)
        let data: Data
        do { data = try encoder.encode(record) }
        catch { throw StoreError.encodingFailed(error.localizedDescription) }
        try atomicWriteExternal(data, to: url)
        do {
            let verified = try decoder.decode(RecoveryRecord.self, from: Data(contentsOf: url))
            guard verified.id == record.id,
                  verified.kind == record.kind,
                  verified.taskID == record.taskID,
                  verified.gameID == record.gameID,
                  verified.target == record.target,
                  verified.phase == record.phase,
                  verified.detail == record.detail,
                  verified.payload == record.payload,
                  verified.resolvedAt == record.resolvedAt else {
                throw StoreError.writeFailed("恢复保护写入后重读不一致")
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed("恢复保护写入后重读失败: \(error.localizedDescription)")
        }
    }

    /// Reads independent recovery guards without interpreting them as AppData.
    /// A malformed guard is a recovery failure, not an empty list.
    public func readRecoveryGuards() throws -> [RecoveryRecord] {
        guard fileManager.fileExists(atPath: baseURL.path) else { return [] }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("RecoveryGuard.") && $0.pathExtension == "json" }
        } catch {
            throw StoreError.readFailed("读取恢复保护目录失败: \(error.localizedDescription)")
        }
        return try urls.map { url in
            do { return try decoder.decode(RecoveryRecord.self, from: Data(contentsOf: url)) }
            catch { throw StoreError.recoveryRequired("恢复保护损坏: \(url.path): \(error.localizedDescription)") }
        }
    }

    /// Clears a guard only after its business state has been committed and
    /// verified. Missing guards are already converged and therefore idempotent.
    public func clearRecoveryGuard(id: String) throws {
        let url = try recoveryGuardURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do { try fileManager.removeItem(at: url) }
        catch { throw StoreError.writeFailed("清除恢复保护失败: \(error.localizedDescription)") }
    }

    public func resolveRecoveryRecord(id: String) throws {
        var data = try readAppData()
        guard let index = data.recoveryRecords.firstIndex(where: { $0.id == id }) else { return }
        data.recoveryRecords[index].resolvedAt = Date()
        try writeAppData(data)
    }

    public func restoreAppDataFromBackup() throws -> AppData {
        let url = try allowedURL(for: "AppData")
        let backup = backupURL(for: url)
        guard fileManager.fileExists(atPath: backup.path) else { throw StoreError.fileNotFound(backup.path) }
        guard (try? decodeAppData(at: backup)) != nil else {
            throw StoreError.dataCorrupted("AppData.bak 也无法验证")
        }
        try restoreFileFromBackup(url)
        return try decodeAppData(at: url)
    }

    // MARK: - Narrow generic compatibility API

    public func write<T: Codable>(_ value: T, to filename: String) throws {
        let url = try allowedURL(for: filename)
        try ensureDirectoryExists(at: baseURL)
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw StoreError.encodingFailed(error.localizedDescription) }
        try atomicWrite(data, to: url, preserveBackup: fileManager.fileExists(atPath: url.path))
    }

    public func read<T: Codable>(_ type: T.Type, from filename: String) throws -> T {
        let url = try allowedURL(for: filename)
        guard fileManager.fileExists(atPath: url.path) else { throw StoreError.fileNotFound(url.path) }
        do { return try decoder.decode(type, from: Data(contentsOf: url)) }
        catch let error as DecodingError { throw StoreError.decodingFailed(error.localizedDescription) }
        catch { throw StoreError.readFailed(error.localizedDescription) }
    }

    public func readOptional<T: Codable>(_ type: T.Type, from filename: String) throws -> T? {
        guard exists(filename) else { return nil }
        return try read(type, from: filename)
    }

    public func delete(_ filename: String) throws {
        let url = try allowedURL(for: filename)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do { try fileManager.removeItem(at: url) }
        catch { throw StoreError.writeFailed(error.localizedDescription) }
    }

    public func exists(_ filename: String) -> Bool {
        (try? allowedURL(for: filename)).map { fileManager.fileExists(atPath: $0.path) } ?? false
    }

    public func createBackup(_ filename: String) throws {
        let url = try allowedURL(for: filename)
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backup = backupURL(for: url)
        let temporary = baseURL.appendingPathComponent("AppData.\(UUID().uuidString).bak.tmp")
        do {
            try ensureDirectoryExists(at: baseURL)
            try fileManager.copyItem(at: url, to: temporary)
            if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
            try fileManager.moveItem(at: temporary, to: backup)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw StoreError.writeFailed("创建备份失败: \(error.localizedDescription)")
        }
    }

    public func getBaseURL() -> URL { baseURL }

    // MARK: - File primitives

    private func allowedURL(for filename: String) throws -> URL {
        guard filename == "AppData" else {
            throw StoreError.writeFailed("不允许的持久化文件名: \(filename)")
        }
        return baseURL.appendingPathComponent("AppData.json", isDirectory: false)
    }

    private func recoveryGuardURL(for id: String) throws -> URL {
        guard id.isEmpty == false,
              id.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" || $0 == "_" }) else {
            throw StoreError.writeFailed("恢复保护标识无效")
        }
        return baseURL.appendingPathComponent("RecoveryGuard.\(id).json", isDirectory: false)
    }

    private func backupURL(for url: URL) -> URL { url.appendingPathExtension("bak") }

    private func encode(_ value: AppData) throws -> Data {
        do {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(AppData.self, from: data)
            guard decoded.schemaVersion == AppData.currentSchemaVersion else {
                throw StoreError.unsupportedSchema(decoded.schemaVersion)
            }
            return data
        }
        catch let error as StoreError { throw error }
        catch { throw StoreError.encodingFailed(error.localizedDescription) }
    }

    private func decodeAppData(at url: URL) throws -> AppData {
        do {
            let value = try decoder.decode(AppData.self, from: Data(contentsOf: url))
            guard value.schemaVersion == AppData.currentSchemaVersion else {
                throw StoreError.unsupportedSchema(value.schemaVersion)
            }
            return value
        } catch let error as StoreError { throw error }
        catch { throw StoreError.decodingFailed(error.localizedDescription) }
    }

    private func atomicWrite(_ data: Data, to url: URL, preserveBackup: Bool) throws {
        try ensureDirectoryExists(at: baseURL)
        let temporary = baseURL.appendingPathComponent("AppData.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            guard JSONSerialization.isValidJSONObject(try JSONSerialization.jsonObject(with: data)) else {
                throw StoreError.dataCorrupted("编码结果不是有效 JSON")
            }
            if preserveBackup, fileManager.fileExists(atPath: url.path) { try createBackup("AppData") }
            if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temporary) }
            else { try fileManager.moveItem(at: temporary, to: url) }
        } catch let error as StoreError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    private func atomicWriteExternal(_ data: Data, to url: URL) throws {
        try ensureDirectoryExists(at: baseURL)
        let temporary = baseURL.appendingPathComponent("RecoveryGuard.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    private func restoreFileFromBackup(_ url: URL) throws {
        let backup = backupURL(for: url)
        let temporary = baseURL.appendingPathComponent("AppData.\(UUID().uuidString).restore.tmp")
        do {
            try fileManager.copyItem(at: backup, to: temporary)
            if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temporary) }
            else { try fileManager.moveItem(at: temporary, to: url) }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw StoreError.writeFailed("恢复备份失败: \(error.localizedDescription)")
        }
    }

    private func preserveCorruptFile(at url: URL) throws -> URL {
        let diagnostic = baseURL.appendingPathComponent("AppData.corrupt.\(UUID().uuidString).json")
        try ensureDirectoryExists(at: baseURL)
        try fileManager.copyItem(at: url, to: diagnostic)
        return diagnostic
    }

    private func ensureDirectoryExists(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            do { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
            catch { throw StoreError.writeFailed(error.localizedDescription) }
        } else if !isDirectory.boolValue {
            throw StoreError.writeFailed("存储路径不是目录: \(url.path)")
        }
    }

    private func recordPersistenceEvent(
        eventName: String,
        phase: String,
        result: String,
        errorCategory: String = "none",
        messageCode: String
    ) {
        guard let logWriter else { return }
        Task { await logWriter.record(.init(
            level: result == "completed" ? .info : .error,
            module: "PersistenceStore",
            eventName: eventName,
            phase: phase,
            result: result,
            errorCategory: errorCategory,
            messageCode: messageCode
        )) }
    }
}
