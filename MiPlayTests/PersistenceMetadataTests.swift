// Source: Implementation maintenance split -> persistence, integrity, metadata, and version evidence
import XCTest
import Darwin
import CryptoKit
@testable import MiPlay

private enum SophonUpdateFixture {
    nonisolated static func number(_ n: UInt64) -> Data {
        var n = n, result = Data()
        while n >= 128 { result.append(UInt8(n & 127) | 128); n >>= 7 }
        result.append(UInt8(n)); return result
    }
    nonisolated static func field(_ n: UInt64, _ value: Data) -> Data { number(n * 8 + 2) + number(UInt64(value.count)) + value }
    nonisolated static func integer(_ n: UInt64, _ value: UInt64) -> Data { number(n * 8) + number(value) }
    nonisolated static func string(_ n: UInt64, _ value: String) -> Data { field(n, Data(value.utf8)) }
    nonisolated static func zstd(_ data: Data) -> Data {
        var frame = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8((UInt32(data.count) >> shift) & 255)) }
        let header = UInt32(data.count) * 8 + 1
        for shift in stride(from: 0, to: 24, by: 8) { frame.append(UInt8((header >> shift) & 255)) }
        return frame + data
    }
    nonisolated static func make(old: Data, new: Data, corruptPatch: Bool, rawNewFile: Bool = false) throws -> (responses: [String: Data], patch: Data) {
        let patch = rawNewFile ? new : Data(base64Encoded: "SERJRkYxMyYAkACQAAIIAAIAAAAFAAAAhTwFBYo/L39BQkNERQ==")!
        var servedPatch = patch
        if corruptPatch { servedPatch[servedPatch.count - 1] ^= 1 }
        let oldHash = SophonMetadataClient.md5(old), newHash = SophonMetadataClient.md5(new)
        let targetPath = rawNewFile ? "new-resource.bin" : "YuanShen.exe"
        let compressedChunk = zstd(new)
        let chunk = string(1, "chunk") + string(2, newHash) + integer(3, 0)
            + integer(4, UInt64(compressedChunk.count)) + integer(5, UInt64(new.count))
        let full = field(1, string(1, targetPath) + field(2, chunk) + integer(4, UInt64(new.count)) + string(5, newHash))
        let patchInfo = string(1, "patch-object") + string(2, "1.0.0") + integer(4, UInt64(patch.count))
            + integer(6, 0) + integer(7, UInt64(patch.count))
            + (rawNewFile ? Data() : string(8, "YuanShen.exe") + integer(9, UInt64(old.count)) + string(10, oldHash))
        let patchFile = string(1, targetPath) + integer(2, UInt64(new.count)) + string(3, newHash)
            + field(4, string(1, "1.0.0") + field(2, patchInfo))
        let diff = field(1, patchFile), empty = Data()
        let prefix = "https://fixture.test/resources"
        func descriptor(_ id: String, _ field: String, _ type: String) -> [String: Any] {
            ["category_id": id, "matching_field": field, "type": type, "scenarios": ["CATEGORY_SCENARIO_FULL"]]
        }
        let descriptors = [descriptor("game-id", "game", "CATEGORY_TYPE_RESOURCE"), descriptor("audio-id", "zh-cn", "CATEGORY_TYPE_AUDIO")]
        func branch(_ name: String, _ version: String) -> [String: Any] {
            ["branch": name, "tag": version, "package_id": "fixture", "password": "fixture", "diff_tags": ["1.0.0"], "categories": descriptors]
        }
        func branches(_ promoted: Bool) throws -> Data {
            let record: [String: Any] = ["game": ["id": "1Z8W5NHUQb", "biz": "hk4e_cn"],
                "main": branch("main", promoted ? "2.0.0" : "1.0.0"),
                "pre_download": branch("predownload", "2.0.0")]
            return try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["game_branches": [record]]])
        }
        func info(_ id: String, _ field: String, _ name: String, _ data: Data, patch: Bool) -> [String: Any] {
            var result: [String: Any] = ["category_id": id, "matching_field": field,
                "manifest": ["id": name, "checksum": SophonMetadataClient.md5(data), "uncompressed_size": String(data.count), "compressed_size": String(zstd(data).count)],
                "manifest_download": ["encryption": 0, "compression": 1, "url_prefix": prefix, "url_suffix": ""]]
            result[patch ? "diff_download" : "chunk_download"] = ["encryption": 0, "compression": patch ? 0 : 1, "url_prefix": prefix, "url_suffix": ""]
            return result
        }
        let fullInfo = [info("game-id", "game", "full", full, patch: false), info("audio-id", "zh-cn", "audio-full", empty, patch: false)]
        let diffInfo = [info("game-id", "game", "diff", diff, patch: true), info("audio-id", "zh-cn", "audio-diff", empty, patch: true)]
        let build = try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["tag": "2.0.0", "manifests": fullInfo]])
        let patchBuild = try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["tag": "2.0.0", "manifests": diffInfo]])
        return (["branches-pre": try branches(false), "branches-main": try branches(true), "getBuild": build,
                 "getPatchBuild": patchBuild, "full": zstd(full), "audio-full": zstd(empty),
                 "diff": zstd(diff), "audio-diff": zstd(empty), "chunk": compressedChunk], servedPatch)
    }

    /// Multiple targets deliberately use the same valid HDIFF13 fixture, but
    /// their old source paths form a chain or cycle. Replacing a source too
    /// early will force a FULL request and is observable in the tests below.
    nonisolated static func graph(old: Data, new: Data, originalByTarget: [String: String]) throws -> (responses: [String: Data], patch: Data) {
        var fixture = try make(old: old, new: new, corruptPatch: false)
        let onePatch = fixture.patch
        let hash = SophonMetadataClient.md5(new)
        var full = Data(), diff = Data(), object = Data()
        let objectSize = onePatch.count * originalByTarget.count
        for path in originalByTarget.keys.sorted() {
            let chunk = string(1, "chunk") + string(2, hash) + integer(3, 0)
                + integer(4, UInt64(zstd(new).count)) + integer(5, UInt64(new.count))
            full.append(field(1, string(1, path) + field(2, chunk) + integer(4, UInt64(new.count)) + string(5, hash)))
            let patchInfo = string(1, "patch-object") + string(2, "1.0.0") + integer(4, UInt64(objectSize))
                + integer(6, UInt64(object.count)) + integer(7, UInt64(onePatch.count))
                + string(8, originalByTarget[path]!) + integer(9, UInt64(old.count)) + string(10, SophonMetadataClient.md5(old))
            diff.append(field(1, string(1, path) + integer(2, UInt64(new.count)) + string(3, hash)
                + field(4, string(1, "1.0.0") + field(2, patchInfo))))
            object.append(onePatch)
        }
        func updateManifest(in response: Data, contents: Data) throws -> Data {
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            var data = try XCTUnwrap(envelope["data"] as? [String: Any])
            var manifests = try XCTUnwrap(data["manifests"] as? [[String: Any]])
            var manifest = try XCTUnwrap(manifests[0]["manifest"] as? [String: Any])
            manifest["checksum"] = SophonMetadataClient.md5(contents)
            manifest["uncompressed_size"] = String(contents.count)
            manifest["compressed_size"] = String(zstd(contents).count)
            manifests[0]["manifest"] = manifest
            data["manifests"] = manifests
            envelope["data"] = data
            return try JSONSerialization.data(withJSONObject: envelope)
        }
        fixture.responses["getBuild"] = try updateManifest(in: fixture.responses["getBuild"]!, contents: full)
        fixture.responses["getPatchBuild"] = try updateManifest(in: fixture.responses["getPatchBuild"]!, contents: diff)
        fixture.responses["full"] = zstd(full)
        fixture.responses["diff"] = zstd(diff)
        return (fixture.responses, object)
    }
}

private final class SophonUpdateFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Data] = [:]
    nonisolated(unsafe) private static var patch = Data()
    nonisolated(unsafe) private static var promoted = false
    nonisolated(unsafe) private static var seen: [String] = []
    nonisolated(unsafe) private static var failures: Set<String> = []
    nonisolated static func configure(_ values: [String: Data], patch: Data) {
        lock.lock(); defer { lock.unlock() }
        responses = values; self.patch = patch; promoted = false; seen = []; failures = []
    }
    nonisolated static func fail(_ names: Set<String>) { lock.lock(); defer { lock.unlock() }; failures = names }
    nonisolated static func promoteMain() { lock.lock(); defer { lock.unlock() }; promoted = true }
    nonisolated static func clearRequests() { lock.lock(); defer { lock.unlock() }; seen = [] }
    nonisolated static func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let name = url.lastPathComponent
        Self.lock.lock()
        Self.seen.append(name)
        let data = name == "patch-object" ? Self.patch : Self.responses[name == "getGameBranches" ? (Self.promoted ? "branches-main" : "branches-pre") : name]
        let shouldFail = Self.failures.contains(name)
        Self.lock.unlock()
        if shouldFail { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        guard let data else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        let isPatch = name == "patch-object"
        let headers = isPatch ? ["Content-Range": "bytes 0-\(data.count - 1)/\(data.count)", "Content-Length": String(data.count)] : ["Content-Length": String(data.count)]
        let response = HTTPURLResponse(url: url, statusCode: isPatch ? 206 : 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor SophonUpdateProgressRecorder {
    private var values: [SophonProgress] = []
    func record(_ value: SophonProgress) { values.append(value) }
    func snapshot() -> [SophonProgress] { values }
}

private actor LSFGPersistenceTestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func isReleased() -> Bool { released }
}

@MainActor extension MiPlayCoreTests {
    func testLSFGDefaultsMigrateAndSettingsValidate() throws {
        let legacy = Data(#"{"gameID":"GenshinImpact","metadataDisplayEnabled":false,"lastFailure":"existing"}"#.utf8)
        let decoded = try JSONDecoder().decode(PerGameSettings.self, from: legacy)
        XCTAssertEqual(decoded.lsfg, LSFGSettings())
        XCTAssertFalse(decoded.lsfg.enabled)
        XCTAssertFalse(decoded.metadataDisplayEnabled)
        XCTAssertEqual(decoded.lastFailure, "existing")
        let sparse = try JSONDecoder().decode(LSFGSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertEqual(sparse, LSFGSettings(enabled: true))

        let requested = LSFGSettings(enabled: true, multiplier: 3, flowScale: 0.5, performanceMode: true, targetFPS: 120)
        var updated = decoded
        updated.lsfg = requested
        XCTAssertEqual(try JSONDecoder().decode(PerGameSettings.self, from: JSONEncoder().encode(updated)), updated)
        XCTAssertEqual(try requested.validated(), requested)
        for invalid in [LSFGSettings(multiplier: 1), LSFGSettings(multiplier: 5),
                        LSFGSettings(flowScale: .nan), LSFGSettings(flowScale: .infinity),
                        LSFGSettings(flowScale: 0.2), LSFGSettings(flowScale: 1.1),
                        LSFGSettings(targetFPS: 0), LSFGSettings(targetFPS: 1001)] {
            XCTAssertThrowsError(try invalid.validated())
        }
    }

    func testLSFGSettingsSerializeRapidEditsAndPreserveOtherGameFacts() async throws {
        let fixture = try await makeScheduler()
        let genshin = GameType.genshinImpact.rawValue, zzz = GameType.zenlessZoneZero.rawValue
        try await fixture.persistence.updateAppData { data in
            data.perGameSettings[genshin] = PerGameSettings(gameID: genshin, metadataDisplayEnabled: false,
                                                          compatibilityCapabilityStatus: ["compatibility": "verified"],
                                                          lastFailure: "preserve diagnostic")
            data.lastSelectedGame = zzz
        }
        let model = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(), wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(persistenceStore: fixture.persistence, logWriter: fixture.logger)
        )
        await model.loadLSFGSettings()
        model.applyLSFGSettingsChange(for: genshin) { $0.enabled = true }
        XCTAssertTrue(model.lsfgSettings(for: genshin).enabled)
        model.applyLSFGSettingsChange(for: genshin) { $0.multiplier = 3 }
        model.applyLSFGSettingsChange(for: genshin) { $0.flowScale = 0.5; $0.targetFPS = 120 }
        model.applyLSFGSettingsChange(for: zzz) { $0.performanceMode = true }
        await model.waitForLSFGSettingsSave()

        let saved = try await fixture.persistence.readAppData()
        XCTAssertEqual(saved.perGameSettings[genshin]?.lsfg,
                       LSFGSettings(enabled: true, multiplier: 3, flowScale: 0.5, targetFPS: 120))
        XCTAssertEqual(saved.perGameSettings[zzz]?.lsfg, LSFGSettings(performanceMode: true))
        XCTAssertEqual(saved.perGameSettings[genshin]?.metadataDisplayEnabled, false)
        XCTAssertEqual(saved.perGameSettings[genshin]?.compatibilityCapabilityStatus, ["compatibility": "verified"])
        XCTAssertEqual(saved.perGameSettings[genshin]?.lastFailure, "preserve diagnostic")
        XCTAssertEqual(saved.lastSelectedGame, zzz)

        await fixture.persistence.injectWriteFailure("LSFG fixture failure")
        model.applyLSFGSettingsChange(for: genshin) { $0.multiplier = 4 }
        await model.waitForLSFGSettingsSave()
        XCTAssertEqual(model.lsfgSettings(for: genshin), saved.perGameSettings[genshin]?.lsfg)
        XCTAssertNotNil(model.errorMessage)
        await fixture.persistence.clearWriteFailure()
        model.clearError()
        model.applyLSFGSettingsChange(for: genshin) { $0.flowScale = .nan }
        XCTAssertEqual(model.lsfgSettings(for: genshin), saved.perGameSettings[genshin]?.lsfg)
        XCTAssertNotNil(model.errorMessage)

        // A malformed enabled request must not lock the user out of turning
        // LSFG off and starting the game with the normal renderer.
        try await fixture.persistence.updateAppData { data in
            data.perGameSettings[genshin]?.lsfg = LSFGSettings(enabled: true, multiplier: 99)
        }
        await model.loadLSFGSettings()
        model.clearError()
        model.applyLSFGSettingsChange(for: genshin) { $0.enabled = false }
        await model.waitForLSFGSettingsSave()
        XCTAssertEqual(model.lsfgSettings(for: genshin), LSFGSettings())
        let repaired = try await fixture.persistence.readAppData()
        XCTAssertEqual(repaired.perGameSettings[genshin]?.lsfg, LSFGSettings())
        XCTAssertEqual(repaired.perGameSettings[genshin]?.lastFailure, "preserve diagnostic")
        XCTAssertNil(model.errorMessage)
    }

    func testLSFGLaunchReadsLatestQueuedSettingAndDoesNotWaitForOtherStoresOrGames() async throws {
        let fixture = try await makeScheduler()
        let other = try await makeScheduler()
        let gameID = GameType.genshinImpact.rawValue
        try await fixture.persistence.updateAppData { data in
            data.perGameSettings[gameID] = PerGameSettings(gameID: gameID, lsfg: LSFGSettings(enabled: true))
        }
        let model = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(), wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(persistenceStore: fixture.persistence, logWriter: fixture.logger)
        )
        await model.loadLSFGSettings()
        let gate = LSFGPersistenceTestGate()
        LSFGSettingsPersistence.enqueue(store: fixture.persistence, gameID: gameID) { await gate.wait() }
        model.applyLSFGSettingsChange(for: gameID) { $0.enabled = false }
        model.applyLSFGSettingsChange(for: gameID) { $0.enabled = true }
        model.applyLSFGSettingsChange(for: gameID) { $0.enabled = false }
        XCTAssertFalse(model.lsfgSettings(for: gameID).enabled)
        let launchRead = Task { try await fixture.wineManager.lsfgSettings(for: gameID) }

        // Bound this regression even if the implementation accidentally waits
        // globally: the assertions below then fail instead of hanging XCTest.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            await gate.release()
        }
        defer {
            watchdog.cancel()
            Task { await gate.release() }
        }
        let unrelatedStore = try await other.wineManager.lsfgSettings(for: gameID)
        let unrelatedGame = try await fixture.wineManager.lsfgSettings(for: GameType.zenlessZoneZero.rawValue)
        let releasedBeforeExplicitSignal = await gate.isReleased()
        XCTAssertFalse(releasedBeforeExplicitSignal, "A pending edit must not block another PersistenceStore or another game")
        XCTAssertEqual(unrelatedStore, LSFGSettings())
        XCTAssertEqual(unrelatedGame, LSFGSettings())
        await gate.release()
        watchdog.cancel()

        // No waitForLSFGSettingsSave() here: the same getter used by launch
        // must wait for all queued edits and observe the final disabled value.
        let launchSettings = try await launchRead.value
        XCTAssertFalse(launchSettings.enabled)
        let saved = try await fixture.persistence.readAppData()
        XCTAssertEqual(saved.perGameSettings[gameID]?.lsfg, launchSettings)
        XCTAssertNil(model.errorMessage)
    }

    func testLegacyLibraryCatalogMigrationPreservesExistingAndRemovedGames() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersistenceStore(baseURL: base)
        let location = GameLocation(gameID: "legacy-id", bookmarkData: Data([1, 2, 3]),
                                    lastKnownPath: "/existing/game", scope: .readWrite,
                                    resolutionState: .resolvable)
        let existing = Game(id: "legacy-id", type: .genshinImpact, location: location,
                            state: .installed, version: "1.2.3", lastLaunchFailure: "old failure",
                            lastLaunchDate: Date(timeIntervalSince1970: 1000), solutionApplications: [])
        try await store.writeAppData(AppData(games: [existing], backgroundModes: [existing.id: "Static"],
                                             lastSelectedGame: existing.id))
        let fixture = try await makeScheduler(store: store)
        let snapshot = await fixture.registry.currentSnapshot()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertEqual(snapshot.games.map(\.id), [existing.id], "Missing legacy games may have been removed intentionally")
        let migrated = try await store.readAppData()
        XCTAssertEqual(migrated.knownBuiltInGameTypes, GameType.allCases.map(\.rawValue))
        XCTAssertEqual(migrated.games.first?.location, location)
        XCTAssertEqual(migrated.games.first?.state, .installed)
        XCTAssertEqual(migrated.games.first?.version, "1.2.3")
        XCTAssertEqual(migrated.games.first?.lastLaunchFailure, "old failure")
        XCTAssertEqual(migrated.games.first?.lastLaunchDate, existing.lastLaunchDate)
        XCTAssertEqual(migrated.lastSelectedGame, existing.id)
        XCTAssertEqual(migrated.backgroundModes[existing.id], "Static")

        let before = try Data(contentsOf: base.appendingPathComponent("AppData.json"))
        await store.injectWriteFailure("unexpected second migration")
        await fixture.registry.initialize()
        let again = await fixture.registry.currentSnapshot()
        XCTAssertEqual(again.state, .loaded, "A completed migration must not write again")
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("AppData.json")), before)
    }

    func testCatalogMigrationOnlyAddsNewlyIntroducedGameAndRemembersRemoval() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersistenceStore(baseURL: base)
        let existing = Game(id: "legacy-id", type: .genshinImpact, location: nil,
                            state: .launchFailed, version: "1.0", lastLaunchDate: nil, solutionApplications: [])
        // ZZZ was already known and deliberately removed; Star Rail represents
        // a game introduced after this snapshot. Unknown prior values survive.
        let known = [GameType.genshinImpact.rawValue, GameType.zenlessZoneZero.rawValue, "future-unknown"]
        try await store.writeAppData(AppData(games: [existing], knownBuiltInGameTypes: known))
        let fixture = try await makeScheduler(store: store)
        let snapshot = await fixture.registry.currentSnapshot()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertEqual(snapshot.games.map(\.id), [existing.id, GameType.honkaiStarRail.rawValue])
        XCTAssertEqual(snapshot.games.last?.state, .notInstalled)
        XCTAssertNil(snapshot.games.last?.location)
        let first = try await store.readAppData()
        XCTAssertEqual(first.knownBuiltInGameTypes, known + [GameType.honkaiStarRail.rawValue])
        XCTAssertEqual(first.games.first?.state, .launchFailed)
        XCTAssertEqual(first.games.first?.version, "1.0")

        try await fixture.registry.removeGame(id: GameType.honkaiStarRail.rawValue)
        await fixture.registry.initialize()
        let afterRemoval = await fixture.registry.currentSnapshot()
        XCTAssertEqual(afterRemoval.state, .loaded)
        XCTAssertEqual(afterRemoval.games.map(\.id), [existing.id], "A deliberately removed game must stay removed after restart")
    }

    func testCatalogMigrationDistinguishesFreshInstallFromPersistedEmptyLibrary() async throws {
        let fresh = try await makeScheduler()
        let freshSnapshot = await fresh.registry.currentSnapshot()
        XCTAssertEqual(freshSnapshot.games.map(\.type), GameType.allCases)
        let freshData = try await fresh.persistence.readAppData()
        XCTAssertEqual(freshData.knownBuiltInGameTypes, GameType.allCases.map(\.rawValue))

        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersistenceStore(baseURL: base)
        // Other services may create an empty untracked AppData first.
        try await store.writeAppData(AppData(games: []))
        let oldEmpty = try await makeScheduler(store: store)
        let oldSnapshot = await oldEmpty.registry.currentSnapshot()
        XCTAssertEqual(oldSnapshot.games.map(\.type), GameType.allCases)
        let oldData = try await store.readAppData()
        XCTAssertEqual(oldData.knownBuiltInGameTypes, GameType.allCases.map(\.rawValue))

        for game in oldSnapshot.games { try await oldEmpty.registry.removeGame(id: game.id) }
        await oldEmpty.registry.initialize()
        let cleared = await oldEmpty.registry.currentSnapshot()
        XCTAssertTrue(cleared.games.isEmpty, "A tracked empty library reflects user removal")
    }

    func testCatalogMigrationRejectsIDCollisionAndPreservesOriginalData() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersistenceStore(baseURL: base)
        let occupied = Game(id: GameType.honkaiStarRail.rawValue, type: .genshinImpact, location: nil,
                            state: .notInstalled, version: "keep", lastLaunchDate: nil, solutionApplications: [])
        try await store.writeAppData(AppData(games: [occupied], knownBuiltInGameTypes: [GameType.genshinImpact.rawValue]))
        let dataURL = base.appendingPathComponent("AppData.json")
        let before = try Data(contentsOf: dataURL)
        let fixture = try await makeScheduler(store: store)
        let snapshot = await fixture.registry.currentSnapshot()
        guard case .recoveryRequired = snapshot.state else { return XCTFail("A conflicting new ID must require recovery") }
        XCTAssertEqual(try Data(contentsOf: dataURL), before, "Collision must not rewrite user data")
    }

    func testCatalogMigrationWriteFailureCanRetryWithoutChangingOriginalData() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersistenceStore(baseURL: base)
        let existing = Game(id: GameType.genshinImpact.rawValue, type: .genshinImpact, location: nil,
                            state: .notInstalled, version: "keep", lastLaunchDate: nil, solutionApplications: [])
        try await store.writeAppData(AppData(games: [existing], knownBuiltInGameTypes: [GameType.genshinImpact.rawValue]))
        let dataURL = base.appendingPathComponent("AppData.json")
        let before = try Data(contentsOf: dataURL)
        await store.injectWriteFailure("test migration failure")
        let fixture = try await makeScheduler(store: store)
        let failed = await fixture.registry.currentSnapshot()
        guard case .loadingFailed = failed.state else { return XCTFail("A failed write must not report a loaded catalog") }
        XCTAssertEqual(try Data(contentsOf: dataURL), before)
        await store.setWriteFailure(nil)
        await fixture.registry.initialize()
        let recovered = await fixture.registry.currentSnapshot()
        XCTAssertEqual(recovered.state, .loaded)
        XCTAssertEqual(recovered.games.map(\.type), GameType.allCases)
        let recoveredData = try await store.readAppData()
        XCTAssertEqual(recoveredData.games.first?.version, "keep")
    }

    func testSophonPatchNetworkFailureDoesNotSilentlyDownloadFullAndCanRetry() async throws {
        for scenario in ["metadata", "predownload", "update"] {
            let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let game = base.appendingPathComponent("game", isDirectory: true)
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            let old = Data((0..<2048).map { UInt8($0 % 256) })
            var updated = old
            updated.replaceSubrange(700..<705, with: Array("ABCDE".utf8))
            let expected = updated
            let executable = game.appendingPathComponent("YuanShen.exe")
            try old.write(to: executable)
            let config = "[General]\ngame_version=1.0.0\nchannel=1\nsub_channel=1\ncps=mihoyo\n"
            let configURL = game.appendingPathComponent("config.ini")
            try Data(config.utf8).write(to: configURL)
            let fixture = try SophonUpdateFixture.make(old: old, new: expected, corruptPatch: false)
            SophonUpdateFixtureProtocol.configure(fixture.responses, patch: fixture.patch)
            if scenario == "update" { SophonUpdateFixtureProtocol.promoteMain() }
            SophonUpdateFixtureProtocol.fail([scenario == "metadata" ? "getPatchBuild" : "patch-object"])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SophonUpdateFixtureProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let installer = SophonInstaller(session: session)
            do {
                if scenario == "update" {
                    _ = try await installer.run(game: .genshinImpact, destination: game, mode: .update) { _ in }
                } else {
                    _ = try await installer.preDownload(game: .genshinImpact, destination: game, expectedVersion: "2.0.0") { _ in }
                }
                XCTFail("Network failure must be reported: \(scenario)")
            } catch { }
            XCTAssertFalse(SophonUpdateFixtureProtocol.requests().contains("chunk"), scenario)
            XCTAssertEqual(try Data(contentsOf: executable), old, scenario)
            XCTAssertEqual(try Data(contentsOf: configURL), Data(config.utf8), scenario)
            SophonUpdateFixtureProtocol.fail([])
            SophonUpdateFixtureProtocol.clearRequests()
            if scenario == "update" {
                _ = try await installer.run(game: .genshinImpact, destination: game, mode: .update) { _ in }
                XCTAssertEqual(try Data(contentsOf: executable), expected)
                try await installer.finalizeCommittedUpdate(destination: game, game: .genshinImpact)
            } else {
                _ = try await installer.preDownload(game: .genshinImpact, destination: game, expectedVersion: "2.0.0") { _ in }
                XCTAssertEqual(try Data(contentsOf: executable), old)
            }
            XCTAssertTrue(SophonUpdateFixtureProtocol.requests().contains("patch-object"), scenario)
            XCTAssertFalse(SophonUpdateFixtureProtocol.requests().contains("chunk"), scenario)
        }
    }

    func testSophonInstallRejectsFIFOReceiptWithoutBlocking() async throws {
        let game = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: game) }
        try SophonResumeCache.ensureOwnedRoot(destination: game, game: .genshinImpact)
        let receipt = game.appendingPathComponent(SophonInstaller.resumeDirectoryName).appendingPathComponent("committed-install.json")
        XCTAssertEqual(mkfifo(receipt.path, mode_t(0o600)), 0)
        do {
            _ = try await SophonInstaller().run(game: .genshinImpact, destination: game, mode: .install) { _ in }
            XCTFail("A FIFO is not a valid install receipt")
        } catch { }
    }

    func testSophonCorruptFullCacheUsesPatchInsteadOfRedownloadingFull() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let game = base.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let old = Data((0..<2048).map { UInt8($0 % 256) })
        var expected = old
        expected.replaceSubrange(700..<705, with: Array("ABCDE".utf8))
        var invalidSource = old
        invalidSource[1] ^= 1
        let executable = game.appendingPathComponent("YuanShen.exe")
        try invalidSource.write(to: executable)
        try Data("[General]\ngame_version=1.0.0\nchannel=1\nsub_channel=1\ncps=mihoyo\n".utf8)
            .write(to: game.appendingPathComponent("config.ini"))
        let fixture = try SophonUpdateFixture.make(old: old, new: expected, corruptPatch: false)
        SophonUpdateFixtureProtocol.configure(fixture.responses, patch: fixture.patch)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SophonUpdateFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let installer = SophonInstaller(session: session)
        _ = try await installer.preDownload(game: .genshinImpact, destination: game, expectedVersion: "2.0.0") { _ in }
        XCTAssertTrue(SophonUpdateFixtureProtocol.requests().contains("chunk"))
        // When every FULL chunk is already verified, the patch service may be
        // unavailable without preventing the cached resources being reused.
        SophonUpdateFixtureProtocol.clearRequests()
        SophonUpdateFixtureProtocol.fail(["getPatchBuild"])
        _ = try await installer.preDownload(game: .genshinImpact, destination: game, expectedVersion: "2.0.0") { _ in }
        XCTAssertFalse(SophonUpdateFixtureProtocol.requests().contains("getPatchBuild"))
        XCTAssertFalse(SophonUpdateFixtureProtocol.requests().contains("chunk"))
        SophonUpdateFixtureProtocol.fail([])
        let root = game.appendingPathComponent(SophonInstaller.resumeDirectoryName)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let paths = enumerator.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "data" }
        let dataURL = try XCTUnwrap(paths.first)
        var damaged = try Data(contentsOf: dataURL)
        damaged[0] ^= 1
        try damaged.write(to: dataURL)
        try old.write(to: executable)
        SophonUpdateFixtureProtocol.clearRequests()
        _ = try await installer.preDownload(game: .genshinImpact, destination: game, expectedVersion: "2.0.0") { _ in }
        XCTAssertTrue(SophonUpdateFixtureProtocol.requests().contains("patch-object"))
        XCTAssertFalse(SophonUpdateFixtureProtocol.requests().contains("chunk"))
        XCTAssertEqual(try Data(contentsOf: executable), old)
    }

    func testOptInOfficialSophonPatchSampleAgainstInstalledSource() async throws {
        guard ProcessInfo.processInfo.environment["MIPLAY_SOPHON_LIVE_SAMPLE"] == "1" else {
            throw XCTSkip("Set MIPLAY_SOPHON_LIVE_SAMPLE=1 to run the official read-only sample")
        }
        let appData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MiPlay/AppData.json")
        let rootObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: appData)) as? [String: Any])
        let games = try XCTUnwrap(rootObject["games"] as? [[String: Any]])
        let game = try XCTUnwrap(games.first { $0["type"] as? String == "GenshinImpact" })
        let sourceVersion = try XCTUnwrap(game["version"] as? String)
        let location = try XCTUnwrap(game["location"] as? [String: Any])
        let encoded = try XCTUnwrap(location["bookmarkData"] as? String)
        let bookmark = try XCTUnwrap(Data(base64Encoded: encoded))
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw XCTSkip("The game bookmark needs renewal") }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let metadata = SophonMetadataClient()
        let availableBuild = try await metadata.fetchPreDownloadBuild(for: .genshinImpact)
        let build = try XCTUnwrap(availableBuild)
        guard build.diffTags.contains(sourceVersion) else { throw XCTSkip("No direct patch for installed version") }
        let patches = try await SophonPatchClient().fetch(build: build, from: sourceVersion)
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var selected: (SophonPatchFile, SophonPatchCategory, URL)?
        for category in patches {
            guard let fullCategory = build.categories.first(where: { $0.id == category.id }) else { continue }
            let full = try await metadata.downloadManifest(fullCategory)
            let byPath = Dictionary(uniqueKeysWithValues: full.map { ($0.path.lowercased(), $0) })
            for patch in category.files.sorted(by: { $0.objectSize < $1.objectSize }) {
                guard patch.length <= 1024 * 1024,
                      patch.size <= 20 * 1024 * 1024, patch.originalSize <= 20 * 1024 * 1024,
                      let path = patch.originalPath, let originalHash = patch.originalMD5,
                      let target = byPath[patch.path.lowercased()], target.size == patch.size,
                      target.md5.lowercased() == patch.md5.lowercased(), SophonPatchClient.safePath(path) else { continue }
                var source = canonicalRoot
                var safe = true
                for component in path.split(separator: "/") {
                    source.appendPathComponent(String(component))
                    var info = stat()
                    if lstat(source.path, &info) != 0 || (info.st_mode & S_IFMT) == S_IFLNK { safe = false; break }
                }
                guard safe, let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
                      (attrs[.size] as? NSNumber)?.uint64Value == patch.originalSize,
                      let reader = try? StreamingFileHasher<Insecure.MD5>(path: source.path) else { continue }
                let hash = try reader.hash().digest
                reader.close()
                if hash == originalHash { selected = (patch, category, source); break }
            }
            if selected != nil { break }
        }
        guard let (entry, category, source) = selected else { throw XCTSkip("No small patch has a matching installed source") }
        let url = try XCTUnwrap(URL(string: category.prefix.appendingPathComponent(entry.objectID).absoluteString + category.suffix))
        var request = URLRequest(url: url)
        request.setValue("bytes=\(entry.offset)-\(entry.offset + entry.length - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        guard http.statusCode == 206, http.url?.host == url.host,
              http.value(forHTTPHeaderField: "Content-Range")?.lowercased() ==
                "bytes \(entry.offset)-\(entry.offset + entry.length - 1)/\(entry.objectSize)" else {
            throw SophonProtocolError.invalidResponse("官方未返回预期的有限范围")
        }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < Int(entry.length) else { throw SophonProtocolError.corrupt("官方样本范围超出限制") }
            bytes.append(byte)
        }
        XCTAssertEqual(bytes.count, Int(entry.length))
        let temporary = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let diff = temporary.appendingPathComponent("patch")
        let result = temporary.appendingPathComponent("result")
        try bytes.write(to: diff)
        let applied = try await SophonInstaller().stagePatch(source: source, diff: diff, output: result, entry: entry, diffOffset: 0)
        XCTAssertTrue(applied, "The official sample must produce the FULL manifest's verified target")
        if applied { XCTAssertEqual(try Data(contentsOf: result).count, Int(entry.size)) }
        print("Official Sophon sample: patch=\(entry.length) bytes, object=\(entry.objectSize) bytes, output=\(entry.size) bytes; target MD5 verified")
    }

    func testSophonIncrementalPatchDependenciesAndCycleResumeUseOldSourcesUntilLastConsumer() async throws {
        for cycle in [false, true] {
            let game = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: game) }
            let old = Data((0..<2048).map { UInt8($0 % 256) })
            var updated = old
            updated.replaceSubrange(700..<705, with: Array("ABCDE".utf8))
            let expected = updated
            for path in ["YuanShen.exe", "A.bin", "B.bin"] { try old.write(to: game.appendingPathComponent(path)) }
            let config = Data("[General]\ngame_version=1.0.0\nchannel=1\nsub_channel=1\ncps=mihoyo\n".utf8)
            try config.write(to: game.appendingPathComponent("config.ini"))
            let dependencies = ["A.bin": "B.bin", "B.bin": cycle ? "A.bin" : "YuanShen.exe"]
            let fixture = try SophonUpdateFixture.graph(old: old, new: expected, originalByTarget: dependencies)
            SophonUpdateFixtureProtocol.configure(fixture.responses, patch: fixture.patch)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SophonUpdateFixtureProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let first = SophonInstaller(session: session)
            _ = try await first.preDownload(game: .genshinImpact, destination: game, expectedVersion: "2.0.0") { _ in }
            SophonUpdateFixtureProtocol.promoteMain()
            SophonUpdateFixtureProtocol.clearRequests()
            let firstRun = Task {
                try await first.run(game: .genshinImpact, destination: game, mode: .update) { progress in
                    guard progress.message.hasPrefix("已安装 ") else { return }
                    let installed = ["A.bin", "B.bin"].filter { (try? Data(contentsOf: game.appendingPathComponent($0))) == expected }
                    if installed.count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do { _ = try await firstRun.value; XCTFail("Expected a pause after the first dependency consumer") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            let firstRequests = SophonUpdateFixtureProtocol.requests()
            XCTAssertFalse(firstRequests.contains("patch-object"), "The first batch should use predownloaded data")
            XCTAssertFalse(firstRequests.contains("chunk"), "A valid dependency must not fall back to FULL")
            XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent("config.ini")), config)
            SophonUpdateFixtureProtocol.clearRequests()
            let retry = SophonInstaller(session: session)
            let recovered = try await retry.recover(destination: game, game: .genshinImpact)
            XCTAssertNil(recovered)
            _ = try await retry.run(game: .genshinImpact, destination: game, mode: .update) { _ in }
            XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent("A.bin")), expected)
            XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent("B.bin")), expected)
            XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent("YuanShen.exe")), old,
                           "An unchanged source outside the update targets must be preserved")
            let resumedRequests = SophonUpdateFixtureProtocol.requests()
            XCTAssertFalse(resumedRequests.contains("patch-object"), "A shared patch segment cannot be cleaned before its last consumer")
            XCTAssertFalse(resumedRequests.contains("chunk"), "Cycle recovery must retain the exact old source, not download FULL")
            try await retry.finalizeCommittedUpdate(destination: game, game: .genshinImpact)
            let pending = await retry.hasPendingTransaction(destination: game)
            XCTAssertFalse(pending)
        }
    }

    func testSophonPatchPredownloadReusesCacheAndUpdateFallsBackWhenNeeded() async throws {
        for scenario in ["reuse", "bad-source", "bad-patch", "raw", "raw-corrupt"] {
            let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let game = base.appendingPathComponent("game", isDirectory: true)
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            let old = Data((0..<2048).map { UInt8($0 % 256) })
            var expected = old
            expected.replaceSubrange(700..<705, with: Array("ABCDE".utf8))
            var installed = old
            if scenario == "bad-source" { installed[1] ^= 1 }
            let executable = game.appendingPathComponent("YuanShen.exe")
            let target = game.appendingPathComponent(scenario.hasPrefix("raw") ? "new-resource.bin" : "YuanShen.exe")
            try installed.write(to: executable)
            let configURL = game.appendingPathComponent("config.ini")
            let config = "[General]\ngame_version=1.0.0\nchannel=1\nsub_channel=1\ncps=mihoyo\n"
            try Data(config.utf8).write(to: configURL)
            let fixture = try SophonUpdateFixture.make(old: old, new: expected,
                                                        corruptPatch: scenario == "bad-patch" || scenario == "raw-corrupt",
                                                        rawNewFile: scenario == "raw" || scenario == "raw-corrupt")
            SophonUpdateFixtureProtocol.configure(fixture.responses, patch: fixture.patch)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SophonUpdateFixtureProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let installer = SophonInstaller(session: session)
            let progress = SophonUpdateProgressRecorder()
            _ = try await installer.preDownload(game: .genshinImpact, destination: game, expectedVersion: "2.0.0") { await progress.record($0) }
            XCTAssertEqual(try Data(contentsOf: executable), installed, scenario)
            if scenario.hasPrefix("raw") { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
            XCTAssertEqual(try Data(contentsOf: configURL), Data(config.utf8), scenario)
            let preRequests = SophonUpdateFixtureProtocol.requests()
            if scenario == "bad-source" {
                XCTAssertTrue(preRequests.contains("chunk"))
                XCTAssertFalse(preRequests.contains("patch-object"))
            } else {
                XCTAssertTrue(preRequests.contains("patch-object"))
                XCTAssertFalse(preRequests.contains("chunk"))
                let updates = await progress.snapshot()
                XCTAssertTrue(updates.contains { $0.message.contains("差分资源") && $0.bytesCompleted == Int64(fixture.patch.count) && $0.bytesTotal == Int64(fixture.patch.count) },
                              "Patch progress must report actual selected bytes")
            }
            let fullBytes = Int64(try XCTUnwrap(fixture.responses["chunk"]).count)
            let preExpected = scenario == "bad-source" ? fullBytes : Int64(fixture.patch.count)
            let preEvents = await progress.snapshot()
            let preFinal = try XCTUnwrap(preEvents.last)
            XCTAssertEqual(preFinal.bytesCompleted, preExpected, scenario)
            XCTAssertEqual(preFinal.bytesTotal, preExpected, scenario)
            SophonUpdateFixtureProtocol.promoteMain()
            SophonUpdateFixtureProtocol.clearRequests()
            let updateProgress = SophonUpdateProgressRecorder()
            _ = try await installer.run(game: .genshinImpact, destination: game, mode: .update) { await updateProgress.record($0) }
            XCTAssertEqual(try Data(contentsOf: target), expected, scenario)
            if scenario.hasPrefix("raw") { XCTAssertEqual(try Data(contentsOf: executable), installed, scenario) }
            XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("game_version=2.0.0"))
            let updateRequests = SophonUpdateFixtureProtocol.requests()
            XCTAssertFalse(updateRequests.contains("patch-object"), "A pre-downloaded patch must be reused")
            if scenario == "bad-patch" || scenario == "raw-corrupt" { XCTAssertTrue(updateRequests.contains("chunk")) }
            else { XCTAssertFalse(updateRequests.contains("chunk")) }
            let updateEvents = await updateProgress.snapshot()
            let updateFinal = try XCTUnwrap(updateEvents.last)
            XCTAssertEqual(updateFinal.message, ScheduledTask.sophonCommitPhaseDescription, scenario)
            XCTAssertEqual(updateFinal.fractionCompleted, 0.99, "Registration must finish before displaying completion")
            XCTAssertNil(updateFinal.bytesTotal, "Final installation progress must not invent a cross-batch download total")
            if scenario == "bad-patch" || scenario == "raw-corrupt" {
                XCTAssertTrue(updateEvents.contains { $0.message.contains("完整资源") && $0.bytesTotal == fullBytes && $0.bytesCompleted == fullBytes })
            }
            try await installer.finalizeCommittedUpdate(destination: game, game: .genshinImpact)
            if scenario == "reuse" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent(SophonInstaller.resumeDirectoryName).path),
                               "Successfully committed patch cache should be removed")
            }
        }
    }

    func testUpdatePatchStagesVerifiedResultAndFallsBackSafely() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldURL = dir.appendingPathComponent("old")
        let diffURL = dir.appendingPathComponent("diff")
        let output = dir.appendingPathComponent("staged")
        let old = Data((0..<2048).map { UInt8($0 % 256) })
        var expected = old
        expected.replaceSubrange(700..<705, with: Array("ABCDE".utf8))
        let patch = try XCTUnwrap(Data(base64Encoded: "SERJRkYxMyYAkACQAAIIAAIAAAAFAAAAhTwFBYo/L39BQkNERQ=="))
        try old.write(to: oldURL)
        try (Data([1, 2, 3]) + patch).write(to: diffURL)
        let installer = SophonInstaller()
        func entry(sourceHash: String, targetHash: String, length: UInt64) -> SophonPatchFile {
            SophonPatchFile(path: "game.bin", size: UInt64(expected.count), md5: targetHash,
                            objectID: "object", objectSize: UInt64(patch.count + 3), offset: 3, length: length,
                            originalPath: "game.bin", originalSize: UInt64(old.count), originalMD5: sourceHash)
        }
        let sourceHash = SophonMetadataClient.md5(old), targetHash = SophonMetadataClient.md5(expected)
        do {
            _ = try await installer.stagePatch(source: oldURL, diff: dir.appendingPathComponent("missing"), output: output,
                entry: entry(sourceHash: sourceHash, targetHash: targetHash, length: UInt64(patch.count)))
            XCTFail("An unavailable patch file is an I/O failure, not an incompatible patch")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ENOENT)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let wrongSource = try await installer.stagePatch(source: oldURL, diff: diffURL, output: output,
            entry: entry(sourceHash: String(repeating: "0", count: 32), targetHash: targetHash, length: UInt64(patch.count)))
        XCTAssertFalse(wrongSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let wrongTarget = try await installer.stagePatch(source: oldURL, diff: diffURL, output: output,
            entry: entry(sourceHash: sourceHash, targetHash: String(repeating: "0", count: 32), length: UInt64(patch.count)))
        XCTAssertFalse(wrongTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let truncated = try await installer.stagePatch(source: oldURL, diff: diffURL, output: output,
            entry: entry(sourceHash: sourceHash, targetHash: targetHash, length: UInt64(patch.count - 1)))
        XCTAssertFalse(truncated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let applied = try await installer.stagePatch(source: oldURL, diff: diffURL, output: output,
            entry: entry(sourceHash: sourceHash, targetHash: targetHash, length: UInt64(patch.count)))
        XCTAssertTrue(applied)
        XCTAssertEqual(try Data(contentsOf: output), expected)
        XCTAssertEqual(try Data(contentsOf: oldURL), old)
    }

    func testNewFileRawPatchAcceptsOnlyVerifiedBoundedContents() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("empty")
        let patch = dir.appendingPathComponent("patch")
        let output = dir.appendingPathComponent("result")
        let target = Data((0..<(1024 * 1024 + 17)).map { UInt8($0 % 251) })
        try Data().write(to: source)
        try (Data([1, 2, 3]) + target + Data([4, 5])).write(to: patch)
        let installer = SophonInstaller()
        func entry(size: UInt64, length: UInt64, hash: String, sourcePath: String? = nil) -> SophonPatchFile {
            SophonPatchFile(path: "new.bin", size: size, md5: hash, objectID: "object",
                            objectSize: UInt64(target.count + 5), offset: 3, length: length,
                            originalPath: sourcePath, originalSize: 0, originalMD5: nil)
        }
        let hash = SophonMetadataClient.md5(target), count = UInt64(target.count)
        let wrongHash = try await installer.stagePatch(source: source, diff: patch, output: output,
            entry: entry(size: count, length: count, hash: String(repeating: "0", count: 32)))
        XCTAssertFalse(wrongHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let wrongLength = try await installer.stagePatch(source: source, diff: patch, output: output,
            entry: entry(size: count, length: count - 1, hash: hash))
        XCTAssertFalse(wrongLength)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let missingRange = try await installer.stagePatch(source: source, diff: patch, output: output,
            entry: entry(size: count, length: count, hash: hash), diffOffset: 6)
        XCTAssertFalse(missingRange)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let claimedSource = try await installer.stagePatch(source: source, diff: patch, output: output,
            entry: entry(size: count, length: count, hash: hash, sourcePath: "old.bin"))
        XCTAssertFalse(claimedSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let valid = try await installer.stagePatch(source: source, diff: patch, output: output,
            entry: entry(size: count, length: count, hash: hash))
        XCTAssertTrue(valid)
        XCTAssertEqual(try Data(contentsOf: output), target)
    }

    func testHDiffAppliesOnlyBoundedSliceToSeparateEmptyOutput() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldURL = dir.appendingPathComponent("old")
        let diffURL = dir.appendingPathComponent("diff")
        let outURL = dir.appendingPathComponent("out")
        let old = Data((0..<2048).map { UInt8($0 % 256) })
        var expected = old
        expected.replaceSubrange(700..<705, with: Array("ABCDE".utf8))
        // Generated independently by upstream hdiffz 5.1.3 with no compression.
        let patch = try XCTUnwrap(Data(base64Encoded: "SERJRkYxMyYAkACQAAIIAAIAAAAFAAAAhTwFBYo/L39BQkNERQ=="))
        try old.write(to: oldURL)
        try (Data([0x01, 0x02, 0x03]) + patch + Data([0x04])).write(to: diffURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: outURL.path, contents: Data()))
        let oldFD = Darwin.open(oldURL.path, O_RDONLY)
        let diffFD = Darwin.open(diffURL.path, O_RDONLY)
        let outFD = Darwin.open(outURL.path, O_RDWR)
        defer { Darwin.close(oldFD); Darwin.close(diffFD); Darwin.close(outFD) }
        XCTAssertGreaterThanOrEqual(min(oldFD, diffFD, outFD), 0)

        XCTAssertThrowsError(try SophonHDiff.apply(oldFD: oldFD, diffFD: diffFD, outputFD: outFD,
                                                   offset: 3, length: UInt64(patch.count - 1), oldSize: 2048, newSize: 2048))
        XCTAssertThrowsError(try SophonHDiff.apply(oldFD: oldFD, diffFD: diffFD, outputFD: outFD,
                                                   offset: UInt64.max, length: 10, oldSize: 2048, newSize: 2048))
        XCTAssertThrowsError(try SophonHDiff.apply(oldFD: oldFD, diffFD: diffFD, outputFD: oldFD,
                                                   offset: 3, length: UInt64(patch.count), oldSize: 2048, newSize: 2048))
        XCTAssertThrowsError(try SophonHDiff.apply(oldFD: oldFD, diffFD: diffFD, outputFD: outFD,
                                                   offset: 3, length: UInt64(patch.count), oldSize: 2047, newSize: 2048))
        // Failed decoding is allowed to leave partial output; reset the owned fixture.
        XCTAssertEqual(ftruncate(outFD, 0), 0)
        try SophonHDiff.apply(oldFD: oldFD, diffFD: diffFD, outputFD: outFD,
                              offset: 3, length: UInt64(patch.count), oldSize: 2048, newSize: 2048)
        XCTAssertEqual(try Data(contentsOf: outURL), expected)
        XCTAssertEqual(try Data(contentsOf: oldURL), old)
        XCTAssertThrowsError(try SophonHDiff.apply(oldFD: oldFD, diffFD: diffFD, outputFD: outFD,
                                                   offset: 3, length: UInt64(patch.count), oldSize: 2048, newSize: 2048))
    }

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

    func testSchema2MigratesToSchema4AndDropsLegacyWineSelection() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let schema2 = """
        {"schemaVersion":2,"games":[],"selectedWineVersion":"wine-devel-9.0","installedWineVersions":["wine-devel-9.0"]}
        """
        try Data(schema2.utf8).write(to: baseURL.appendingPathComponent("AppData.json"))

        let result = try await store.loadAppData()

        XCTAssertEqual(result.data?.schemaVersion, AppData.currentSchemaVersion)
        XCTAssertNil(result.data?.selectedWineVersion)
        XCTAssertTrue(result.data?.installedWineVersions.isEmpty == true)
        XCTAssertNil(result.data?.selectedWineSource)
        XCTAssertNil(result.data?.perGameSettings[GameType.genshinImpact.rawValue]?.wineVersionOverride)

        let reread = try await store.loadAppData()
        guard case .readable = reread.state else {
            return XCTFail("Canonical schema 4 data should not be migrated again: \(reread.state)")
        }
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

        XCTAssertEqual(result.outcome, .current)
        XCTAssertEqual(result.currentVersion, "1.2.3")
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
        XCTAssertTrue(result.conflictDetails.isEmpty)
    }

    func testVersionCheckSkipsFullPkgValidationWithoutManifest() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))
        // 条目指向不存在的文件：只要执行逐文件校验就必然产生校验错误
        try Data(
            "{\"remoteName\":\"data/missing.bin\",\"fileSize\":12,\"md5\":\"0123456789abcdef0123456789abcdef\"}\n".utf8
        ).write(to: baseURL.appendingPathComponent("pkg_version"))
        let repository = GameFileSystemRepository()
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.3"]
        )

        let result = try await checker.checkVersion(for: .genshinImpact, installPath: baseURL.path)

        XCTAssertEqual(result.outcome, .current)
        XCTAssertEqual(result.localEvidence.pkgVersionEntries.count, 1)
        XCTAssertTrue(result.localEvidence.pkgVersionValidationErrors.isEmpty)
        XCTAssertEqual(result.localEvidence.fileVerificationPerformed, false)
    }

    func testVersionCheckPerformsFullPkgValidationOnExplicitRequest() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))
        // 条目指向不存在的文件：显式请求完整校验时必然产生校验错误
        try Data(
            "{\"remoteName\":\"data/missing.bin\",\"fileSize\":12,\"md5\":\"0123456789abcdef0123456789abcdef\"}\n".utf8
        ).write(to: baseURL.appendingPathComponent("pkg_version"))
        let repository = GameFileSystemRepository()
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.3"]
        )

        let result = try await checker.checkVersion(
            for: .genshinImpact,
            installPath: baseURL.path,
            fileVerification: true
        )

        XCTAssertEqual(result.outcome, .current)
        XCTAssertFalse(result.localEvidence.pkgVersionValidationErrors.isEmpty)
        XCTAssertEqual(result.localEvidence.fileVerificationPerformed, true)
    }

    func testFileVerificationReportsByteProgressAcrossLargeAndMissingFiles() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=1.2.3\nchannel=1\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))
        let data = Data(repeating: 0x42, count: 4 * 1024 * 1024)
        try data.write(to: baseURL.appendingPathComponent("large.bin"))
        let repository = GameFileSystemRepository()
        let md5 = await repository.calculateMD5(of: data)
        let entries = """
        {"remoteName":"large.bin","fileSize":\(data.count),"md5":"\(md5)"}
        {"remoteName":"missing.bin","fileSize":1048576,"md5":"00000000000000000000000000000000"}
        """
        try Data(entries.utf8).write(to: baseURL.appendingPathComponent("pkg_version"))
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.3"]
        )
        let samples = VerificationProgressSamples()
        let result = try await checker.checkVersion(
            for: .genshinImpact, installPath: baseURL.path, fileVerification: true
        ) { progress in await samples.append(progress) }
        let values = await samples.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.contains { $0 > 0 && $0 < 0.8 }, "Large files must report progress before completion")
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        XCTAssertEqual(result.localEvidence.pkgVersionValidationErrors.count, 1)
    }

    func testFileVerificationRejectsMissingManifest() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=1.2.3\nchannel=1\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))
        let repository = GameFileSystemRepository()
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.3"]
        )
        do {
            _ = try await checker.checkVersion(for: .genshinImpact, installPath: baseURL.path, fileVerification: true)
            XCTFail("Missing file list must not be reported as a successful verification")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pkg_version"))
        }
    }

    func testVersionCheckKeepsFullPkgValidationWhenManifestExists() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))
        try Data(
            "{\"remoteName\":\"data/missing.bin\",\"fileSize\":12,\"md5\":\"0123456789abcdef0123456789abcdef\"}\n".utf8
        ).write(to: baseURL.appendingPathComponent("pkg_version"))
        let repository = GameFileSystemRepository()
        let manifest = FileIntegrityVerifier.Manifest(
            gameID: GameType.genshinImpact.rawValue,
            version: "1.2.3",
            channel: "1",
            files: ["data/missing.bin": String(repeating: "0", count: 64)]
        )
        let checker = VersionChecker(
            fileSystemRepository: repository,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: repository),
            latestVersions: [.genshinImpact: "1.2.3"],
            integrityManifests: [.genshinImpact: manifest]
        )

        let result = try await checker.checkVersion(for: .genshinImpact, installPath: baseURL.path)

        XCTAssertEqual(result.outcome, .versionEvidenceConflict)
        XCTAssertFalse(result.localEvidence.pkgVersionValidationErrors.isEmpty)
    }

    func testVersionCheckerReadsOfficialHoyoPlayBranchesResponse() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try Data("[General]\ngame_version=6.9.0\nchannel=1\nsub_channel=1\ncps=mihoyo\n".utf8)
            .write(to: baseURL.appendingPathComponent("config.ini"))

        let branches = Data("""
        {
          "retcode": 0,
          "message": "OK",
          "data": {
            "game_branches": [
              {
                "game": {"id": "1Z8W5NHUQb", "biz": "hk4e_cn"},
                "main": {"tag": "7.0.0"}
              },
              {
                "game": {"id": "x6znKlJ0xK", "biz": "nap_cn"},
                "main": {"tag": "3.2.0"}
              }
            ]
          }
        }
        """.utf8)
        let network = try makeMockNetwork(response: branches)
        let checker = VersionChecker(
            fileSystemRepository: GameFileSystemRepository(),
            networkProvider: network,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository()),
            remoteManifestURL: VersionChecker.defaultRemoteManifestURL
        )

        let result = try await checker.checkVersion(
            for: .genshinImpact,
            installPath: baseURL.path
        )

        XCTAssertEqual(result.outcome, .updateAvailable)
        XCTAssertEqual(result.currentVersion, "6.9.0")
        XCTAssertEqual(result.latestVersion, "7.0.0")
        XCTAssertTrue(result.updateAvailable)
        XCTAssertEqual(result.localEvidence.channel, "1")
    }

    func testCommittedVersionCheckUpdatesAndClearsBusinessUpdateState() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let store = PersistenceStore(baseURL: baseURL)
        let gameID = GameType.genshinImpact.rawValue
        let game = Game(
            id: gameID,
            type: .genshinImpact,
            location: nil,
            state: .launchFailed,
            version: nil,
            lastLaunchDate: nil,
            solutionApplications: []
        )
        try await store.writeAppData(AppData(games: [game]))
        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: LogWriter(fileSystemRepository: fileSystem)
        )
        await registry.initialize()

        let evidence = VersionChecker.LocalEvidence(
            gameVersion: "1.0.0",
            channel: "1",
            subChannel: "1",
            cps: "mihoyo",
            sdkVersion: nil
        )
        try await registry.commitVersionCheck(
            id: gameID,
            result: .init(
                outcome: .updateAvailable,
                currentVersion: "1.0.0",
                latestVersion: "2.0.0",
                updateAvailable: true,
                localEvidence: evidence
            )
        )
        let updatedGame = await registry.getGame(by: gameID)
        XCTAssertEqual(updatedGame?.state, .updateAvailable)

        try await registry.commitVersionCheck(
            id: gameID,
            result: .init(
                outcome: .current,
                currentVersion: "2.0.0",
                latestVersion: "2.0.0",
                updateAvailable: false,
                localEvidence: evidence
            )
        )
        let currentGame = await registry.getGame(by: gameID)
        XCTAssertEqual(currentGame?.state, .installed)
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

private actor VerificationProgressSamples {
    private(set) var values: [Double] = []
    func append(_ value: Double) { values.append(value) }
}
