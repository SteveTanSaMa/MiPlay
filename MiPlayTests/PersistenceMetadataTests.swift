// Source: Implementation maintenance split -> persistence, integrity, metadata, and version evidence
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testPersistencePreservesCorruptDataAndRestoresBackup() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)

        try await store.writeAppData(AppData())
        try await store.writeAppData(AppData(lastSelectedGame: GameType.genshinImpact.rawValue))
        let appDataURL = baseURL.appendingPathComponent("AppData.json")
        try Data("not json".utf8).write(to: appDataURL, options: [.atomic])

        let result = try await store.loadAppData()
        XCTAssertNil(result.data)
        guard case .restoreAvailable(let diagnosticPath) = result.state else {
            return XCTFail("Expected backup recovery state, got \(result.state)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: appDataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticPath))

        let restored = try await store.restoreAppDataFromBackup()
        XCTAssertEqual(restored.lastSelectedGame, nil)
        XCTAssertEqual(restored.schemaVersion, AppData.currentSchemaVersion)
    }

    func testPersistenceMigratesLegacySchemaWithoutDroppingPathRecord() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let legacy = "{\"schemaVersion\":1,\"games\":[],\"lastSelectedGame\":\"legacy\"}"
        try Data(legacy.utf8).write(to: baseURL.appendingPathComponent("AppData.json"))

        let result = try await store.loadAppData()

        XCTAssertEqual(result.data?.schemaVersion, AppData.currentSchemaVersion)
        XCTAssertEqual(result.data?.lastSelectedGame, "legacy")
        guard case .migratedAndVerified = result.state else {
            return XCTFail("Expected verified migration, got \(result.state)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseURL.appendingPathComponent("AppData.json.bak").path))
    }

    func testIntegrityVerifierUsesManifestHash() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let fileURL = baseURL.appendingPathComponent("game.bin")
        try Data("hello".utf8).write(to: fileURL)
        let repository = GameFileSystemRepository()
        let manifest = FileIntegrityVerifier.Manifest(
            gameID: GameType.genshinImpact.rawValue,
            files: ["game.bin": "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"]
        )
        let verifier = FileIntegrityVerifier(fileSystemRepository: repository, manifests: [.genshinImpact: manifest])

        let passed = try await verifier.verify(gameType: .genshinImpact, installPath: baseURL.path)
        XCTAssertEqual(passed.status, .passed)
        XCTAssertEqual(passed.verifiedFiles, 1)

        try Data("changed".utf8).write(to: fileURL, options: [.atomic])
        let failed = try await verifier.verify(gameType: .genshinImpact, installPath: baseURL.path)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.corruptedFiles, ["game.bin"])
    }

    func testIntegrityVerifierDistinguishesMissingAndUnsupportedManifest() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let repository = GameFileSystemRepository()
        let verifier = FileIntegrityVerifier(fileSystemRepository: repository)

        let unsupported = try await verifier.verify(gameType: .genshinImpact, installPath: baseURL.path)
        XCTAssertEqual(unsupported.status, .unsupported)
        XCTAssertFalse(unsupported.passed)

        let manifest = FileIntegrityVerifier.Manifest(
            gameID: GameType.genshinImpact.rawValue,
            files: ["missing.bin": String(repeating: "0", count: 64)]
        )
        let manifestVerifier = FileIntegrityVerifier(fileSystemRepository: repository, manifests: [.genshinImpact: manifest])
        let missing = try await manifestVerifier.verify(gameType: .genshinImpact, installPath: baseURL.path)
        XCTAssertEqual(missing.status, .failed)
        XCTAssertEqual(missing.missingFiles, ["missing.bin"])
    }

    func testIntegrityVerifierRejectsManifestForUnknownOrDifferentVersion() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let repository = GameFileSystemRepository()
        let manifest = FileIntegrityVerifier.Manifest(
            gameID: GameType.genshinImpact.rawValue,
            version: "2.0.0",
            files: ["game.bin": String(repeating: "0", count: 64)]
        )
        let verifier = FileIntegrityVerifier(fileSystemRepository: repository, manifests: [.genshinImpact: manifest])

        let unknown = try await verifier.verify(gameType: .genshinImpact, installPath: baseURL.path)
        XCTAssertEqual(unknown.status, .unsupported)

        let different = try await verifier.verify(
            gameType: .genshinImpact,
            installPath: baseURL.path,
            expectedVersion: "1.0.0"
        )
        XCTAssertEqual(different.status, .unsupported)
    }

    func testVersionCheckerComparesLocalAndInjectedRemoteManifest() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let repository = GameFileSystemRepository()
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))
        let payload = Data("versioned game evidence".utf8)
        let dataURL = baseURL.appendingPathComponent("data/file.bin")
        try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: dataURL)
        let md5 = await repository.calculateMD5(of: payload)
        let sha256 = await repository.calculateSHA256(of: payload)
        try Data("{\"remoteName\":\"data/file.bin\",\"fileSize\":\(payload.count),\"md5\":\"\(md5)\"}\n".utf8)
            .write(to: baseURL.appendingPathComponent("pkg_version"))
        let logger = LogWriter(fileSystemRepository: repository)
        let manifest = FileIntegrityVerifier.Manifest(
            gameID: GameType.genshinImpact.rawValue,
            version: "1.2.3",
            channel: "1",
            subChannel: "0",
            files: ["data/file.bin": sha256],
            fileSizes: ["data/file.bin": Int64(payload.count)]
        )
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: logger,
            latestVersions: [.genshinImpact: "1.3.0"],
            integrityManifests: [.genshinImpact: manifest]
        )

        let result = try await checker.checkVersion(for: .genshinImpact, installPath: baseURL.path)

        XCTAssertEqual(result.outcome, .versionEvidenceConflict)
        XCTAssertNil(result.currentVersion)
        XCTAssertEqual(result.latestVersion, "1.3.0")
        XCTAssertFalse(result.updateAvailable)
    }

    func testVersionCheckerRetainsPkgEvidenceAndBlocksUnmappedVersionSuccess() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data(
            "[General]\ngame_version=1.2.3\nchannel=14\nsub_channel=0\ncps=bilibili\nsdk_version=\nwpf_version=must-not-be-read\n".utf8
        ).write(to: baseURL.appendingPathComponent("config.ini"))
        try Data(
            "{\"remoteName\":\"data/file.bin\",\"fileSize\":12,\"md5\":\"0123456789abcdef0123456789abcdef\"}\n"
                .utf8
        ).write(to: baseURL.appendingPathComponent("pkg_version"))

        let repository = GameFileSystemRepository()
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.3"]
        )
        let result = try await checker.checkVersion(for: .genshinImpact, installPath: baseURL.path)

        XCTAssertEqual(result.outcome, .versionEvidenceConflict)
        XCTAssertNil(result.currentVersion)
        XCTAssertFalse(result.updateAvailable)
        XCTAssertEqual(result.localEvidence.gameVersion, "1.2.3")
        XCTAssertEqual(result.localEvidence.channel, "14")
        XCTAssertEqual(result.localEvidence.subChannel, "0")
        XCTAssertEqual(result.localEvidence.cps, "bilibili")
        XCTAssertEqual(result.localEvidence.sdkVersion, "")
        XCTAssertEqual(result.localEvidence.pkgVersionEntries.count, 1)
        XCTAssertEqual(result.localEvidence.pkgVersionEntries.first?.remoteName, "data/file.bin")
        XCTAssertEqual(result.localEvidence.pkgVersionEntries.first?.fileSize, 12)
        XCTAssertEqual(result.localEvidence.pkgVersionMapping, .unmapped)
        XCTAssertTrue(result.conflictDetails.contains { $0.contains("pkg_version") })
    }

    func testVersionCheckerPublishesCurrentOnlyForMappedAndLocallyVerifiedPkgEvidence() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))
        let payload = Data("verified pkg evidence".utf8)
        let payloadURL = baseURL.appendingPathComponent("data/file.bin")
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: payloadURL)

        let repository = GameFileSystemRepository()
        let md5 = await repository.calculateMD5(of: payload)
        let sha256 = await repository.calculateSHA256(of: payload)
        try Data("{\"remoteName\":\"data/file.bin\",\"fileSize\":\(payload.count),\"md5\":\"\(md5)\"}\n".utf8)
            .write(to: baseURL.appendingPathComponent("pkg_version"))
        let manifest = FileIntegrityVerifier.Manifest(
            gameID: GameType.genshinImpact.rawValue,
            version: "1.2.3",
            channel: "1",
            subChannel: "0",
            files: ["data/file.bin": sha256],
            fileSizes: ["data/file.bin": Int64(payload.count)]
        )
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.3"],
            integrityManifests: [.genshinImpact: manifest]
        )

        let result = try await checker.checkVersion(for: .genshinImpact, installPath: baseURL.path)

        XCTAssertEqual(result.outcome, .current)
        XCTAssertEqual(result.currentVersion, "1.2.3")
        XCTAssertEqual(result.latestVersion, "1.2.3")
        XCTAssertFalse(result.updateAvailable)
        XCTAssertEqual(result.localEvidence.pkgVersionMapping, .mapped)
        XCTAssertTrue(result.localEvidence.pkgVersionValidationErrors.isEmpty)
    }

    func testVersionCheckerTreatsMissingChannelAsConflictWhenManifestRequiresIt() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=1.2.3\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))
        let repository = GameFileSystemRepository()
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.3"],
            integrityManifests: [.genshinImpact: .init(
                gameID: GameType.genshinImpact.rawValue,
                version: "1.2.3",
                channel: "1",
                files: ["YuanShen.exe": String(repeating: "0", count: 64)]
            )]
        )

        let result = try await checker.checkVersion(for: .genshinImpact, installPath: baseURL.path)

        XCTAssertEqual(result.outcome, .versionEvidenceConflict)
        XCTAssertNil(result.currentVersion)
        XCTAssertTrue(result.conflictDetails.contains { $0.contains("channel 缺失") })
    }

    func testVersionCheckerRejectsManifestAndChannelConflictWithoutPublishingVersion() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=1.2.3\nchannel=14\nsub_channel=0\ncps=test\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))

        let repository = GameFileSystemRepository()
        let manifest = FileIntegrityVerifier.Manifest(
            gameID: GameType.genshinImpact.rawValue,
            version: "1.2.4",
            channel: "1",
            subChannel: "0",
            files: ["YuanShen.exe": String(repeating: "0", count: 64)]
        )
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.4"],
            integrityManifests: [.genshinImpact: manifest]
        )

        let result = try await checker.checkVersion(for: .genshinImpact, installPath: baseURL.path)
        XCTAssertEqual(result.outcome, .versionEvidenceConflict)
        XCTAssertNil(result.currentVersion)
        XCTAssertFalse(result.updateAvailable)
        XCTAssertTrue(result.conflictDetails.contains { $0.contains("game_version") })
        XCTAssertTrue(result.conflictDetails.contains { $0.contains("channel") })
    }

}
