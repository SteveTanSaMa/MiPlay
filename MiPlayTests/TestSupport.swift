// Source: Implementation maintenance split -> shared fixtures and mocks
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    struct SchedulerFixture {
        let scheduler: TaskScheduler
        let registry: GameRegistry
        let persistence: PersistenceStore
        let wineManager: WineVersionManager
        let logger: LogWriter
    }

    enum TestTimeout: Error {
        case taskDidNotFinish(ScheduledTaskID)
        case archiveCreationFailed
    }

    func makeScheduler(
        games: [Game] = [],
        latestVersions: [GameType: String] = [:],
        integrityManifests: [GameType: FileIntegrityVerifier.Manifest] = [:],
        store: PersistenceStore? = nil,
        networkProvider: NetworkDownloadProvider? = nil
    ) async throws -> SchedulerFixture {
        let persistence: PersistenceStore
        if let store {
            persistence = store
        } else {
            persistence = PersistenceStore(baseURL: try makeTemporaryDirectory())
        }
        if store == nil {
            try await persistence.writeAppData(AppData(games: games))
        } else if games.isEmpty == false {
            var data = try await persistence.readAppData()
            data.games = games
            try await persistence.writeAppData(data)
        }

        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let process = ProcessManager()
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let network = networkProvider ?? NetworkDownloadProvider()
        let wineDownloader = WineVersionDownloader(
            networkProvider: network,
            fileSystemRepository: fileSystem,
            processManager: process,
            logWriter: logger
        )
        let wineManager = WineVersionManager(
            networkProvider: network,
            fileSystemRepository: fileSystem,
            persistenceStore: persistence,
            wineVersionDownloader: wineDownloader,
            logWriter: logger
        )
        let wine = WineRuntimeProvider(processManager: process, fileSystemRepository: fileSystem)
        let verifier = FileIntegrityVerifier(fileSystemRepository: fileSystem, manifests: integrityManifests)
        let registry = GameRegistry(
            persistenceStore: persistence,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: logger
        )
        let preLaunch = PreLaunchValidator(
            fileSystemRepository: fileSystem,
            systemDetector: SystemEnvironmentDetector(),
            wineRuntimeProvider: wine,
            wineVersionManager: wineManager,
            integrityVerifier: verifier
        )
        let performance = PerformanceOptionManager(persistenceStore: persistence, logWriter: logger)
        let launch = LaunchOrchestrator(
            preLaunchValidator: preLaunch,
            wineRuntimeProvider: wine,
            wineVersionManager: wineManager,
            processManager: process,
            performanceOptionManager: performance,
            gameRegistry: registry,
            fileSystemRepository: fileSystem,
            logWriter: logger
        )
        let solution = SolutionEngine(
            fileSystemRepository: fileSystem,
            processManager: process,
            systemDetector: SystemEnvironmentDetector(),
            logWriter: logger
        )
        let versionChecker = VersionChecker(
            fileSystemRepository: fileSystem,
            networkProvider: network,
            logWriter: logger,
            latestVersions: latestVersions,
            integrityManifests: integrityManifests,
            gameRegistry: registry
        )
        let scheduler = TaskScheduler(
            launchOrchestrator: launch,
            solutionEngine: solution,
            gameRegistry: registry,
            integrityVerifier: verifier,
            versionChecker: versionChecker,
            persistenceStore: persistence,
            logWriter: logger,
            wineVersionManager: wineManager
        )
        await registry.initialize()
        return SchedulerFixture(
            scheduler: scheduler,
            registry: registry,
            persistence: persistence,
            wineManager: wineManager,
            logger: logger
        )
    }

    func waitForTask(
        _ id: ScheduledTaskID,
        scheduler: TaskScheduler,
        timeout: TimeInterval = 5
    ) async throws -> ScheduledTask {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = try? await scheduler.taskSnapshot(id: id),
               snapshot.state == .completed || snapshot.state == .failed || snapshot.state == .cancelled {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TestTimeout.taskDidNotFinish(id)
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiPlayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeWineNetwork(
        archive: Data = Data("test archive".utf8),
        metadataDelay: TimeInterval = 0,
        chunkDelay: TimeInterval = 0,
        catalogStatus: Int = 200,
        assetStatus: Int = 200,
        assetURL: String = "https://github.com/yaagl/anime-game-wine/releases/download/wine-devel-9.0/wine-arm64.tar.xz",
        downloadResponseURL: String? = nil
    ) throws -> NetworkDownloadProvider {
        MockURLProtocol.configure { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/releases/tags/wine-devel-9.0") {
                return .init(
                    data: Self.wineReleaseJSON(assetSize: archive.count, assetURL: assetURL),
                    statusCode: catalogStatus,
                    delay: metadataDelay
                )
            }
            if path.hasSuffix("/releases") {
                return .init(
                    data: Self.wineReleasesJSON(assetSize: archive.count, assetURL: assetURL),
                    statusCode: catalogStatus,
                    delay: metadataDelay
                )
            }
            if path.hasSuffix("/releases/download/wine-devel-9.0/wine-arm64.tar.xz") {
                return .init(
                    data: archive,
                    statusCode: assetStatus,
                    chunkDelay: chunkDelay,
                    responseURL: downloadResponseURL.flatMap { URL(string: $0) }
                )
            }
            return .init(data: Data(), statusCode: 404)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return NetworkDownloadProvider(session: URLSession(configuration: configuration))
    }

    func assertWineAssetHTTPFailure(statusCode: Int) async throws {
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(assetStatus: statusCode))
        let versions = try await fixture.wineManager.fetchAvailableVersions()
        guard let version = versions.first else {
            return XCTFail("Expected a catalog fixture before testing asset HTTP \(statusCode)")
        }

        let phases = await collectWinePhases(
            fixture.wineManager.downloadAndInstall(version: version, taskID: UUID())
        )
        let failures = phases.compactMap { phase -> NetworkDownloadProvider.DownloadFailure? in
            guard case .failedWithFailure(let failure) = phase else { return nil }
            return failure
        }
        guard case .http(let actualStatus, _) = failures.first else {
            return XCTFail("Expected typed asset HTTP failure, phases: \(phases)")
        }
        XCTAssertEqual(actualStatus, statusCode)
        XCTAssertFalse(phases.contains { if case .completed = $0 { return true }; return false })

        let logs = try await fixture.logger.exportLogs()
        XCTAssertTrue(logs.contains("\"eventName\":\"wine.asset.download\""))
        XCTAssertTrue(logs.contains("\"statusCode\":\"\(statusCode)\""))
        XCTAssertFalse(logs.contains("networkUnavailable"))
    }

    func makeMockNetwork(response: Data, statusCode: Int = 200) throws -> NetworkDownloadProvider {
        MockURLProtocol.configure { _ in
            .init(data: response, statusCode: statusCode)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return NetworkDownloadProvider(session: URLSession(configuration: configuration))
    }

    func makeDownloadNetwork(response: MockURLProtocol.Response) throws -> NetworkDownloadProvider {
        MockURLProtocol.configure { _ in response }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return NetworkDownloadProvider(session: URLSession(configuration: configuration))
    }

    func makeWineArchive(fillerBytes: Int) throws -> Data {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        var payload = Data("#!/bin/sh\nexit 0\n".utf8)
        payload.append(Data(repeating: 0x5a, count: fillerBytes))
        try payload.write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

        let archiveURL = root.appendingPathComponent("wine.tar.xz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cJf", archiveURL.path, "-C", root.path, "bin"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestTimeout.archiveCreationFailed }
        return try Data(contentsOf: archiveURL)
    }

    static func wineReleaseJSON(
        assetSize: Int,
        assetURL: String = "https://github.com/yaagl/anime-game-wine/releases/download/wine-devel-9.0/wine-arm64.tar.xz"
    ) -> Data {
        Data("""
        {"id":1,"tag_name":"wine-devel-9.0","name":"Test","assets":[{"name":"wine-arm64.tar.xz","browser_download_url":"\(assetURL)","size":\(assetSize)}],"published_at":"2026-08-03T00:00:00Z"}
        """.utf8)
    }

    static func wineReleasesJSON(
        assetSize: Int,
        assetURL: String = "https://github.com/yaagl/anime-game-wine/releases/download/wine-devel-9.0/wine-arm64.tar.xz"
    ) -> Data {
        Data("""
        [{"id":1,"tag_name":"wine-devel-9.0","name":"Test","assets":[{"name":"wine-arm64.tar.xz","browser_download_url":"\(assetURL)","size":\(assetSize)}],"published_at":"2026-08-03T00:00:00Z"}]
        """.utf8)
    }

    static func currentWineReleasesJSON(assetSize: Int) -> Data {
        Data("""
        [
          {"id":11,"tag_name":"wine-crossover-11.0-1-signed","name":"Wine CrossOver 11.0-1 Signed","assets":[{"name":"wine-crossover-11.0-1-osx64-signed.tar.xz","browser_download_url":"https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz","size":\(assetSize)}],"published_at":"2026-08-03T00:00:00Z"},
          {"id":12,"tag_name":"wine-crossover-11.0-1","name":"Wine CrossOver 11.0-1","assets":[{"name":"wine-crossover-11.0-1-osx64.tar.xz","browser_download_url":"https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1/wine-crossover-11.0-1-osx64.tar.xz","size":\(assetSize)}],"published_at":"2026-08-03T00:00:00Z"},
          {"id":13,"tag_name":"wine-11.0-signed","name":"Wine 11.0 Signed","assets":[{"name":"wine-devel-11.0-osx64-signed.tar.xz","browser_download_url":"https://github.com/yaagl/anime-game-wine/releases/download/wine-11.0-signed/wine-devel-11.0-osx64-signed.tar.xz","size":\(assetSize)}],"published_at":"2026-08-03T00:00:00Z"},
          {"id":14,"tag_name":"wine-11.8-signed","name":"Wine 11.8 Signed","assets":[{"name":"wine-devel-11.8-osx64-signed.tar.xz","browser_download_url":"https://github.com/yaagl/anime-game-wine/releases/download/wine-11.8-signed/wine-devel-11.8-osx64-signed.tar.xz","size":\(assetSize)}],"published_at":"2026-08-03T00:00:00Z"}
        ]
        """.utf8)
    }

    static func backgroundResponseJSON() -> Data {
        Data("""
        {"retcode":0,"message":"OK","data":{"game_info_list":[{"game":{"id":"hk4e","biz":"hk4e_cn"},"backgrounds":[{"id":"bg-1","background":{"url":"https://example.com/bg-1.webp"},"video":null,"theme":null,"type":"BACKGROUND_TYPE_STATIC"},{"id":"bg-2","background":{"url":"https://example.com/bg-2.webp"},"video":null,"theme":null,"type":"BACKGROUND_TYPE_STATIC"}]}]}}
        """.utf8)
    }

    func collectWinePhases(
        _ stream: AsyncStream<WineVersionDownloader.DownloadPhase>
    ) async -> [WineVersionDownloader.DownloadPhase] {
        var phases: [WineVersionDownloader.DownloadPhase] = []
        for await phase in stream { phases.append(phase) }
        return phases
    }

    func collectDownloadProgress(
        _ stream: AsyncStream<NetworkDownloadProvider.DownloadProgress>
    ) async -> [NetworkDownloadProvider.DownloadProgress] {
        var progress: [NetworkDownloadProvider.DownloadProgress] = []
        for await item in stream { progress.append(item) }
        return progress
    }
}
nonisolated final class LockedBookmarkCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var refreshed = 0

    func incrementStart() {
        lock.lock()
        starts += 1
        lock.unlock()
    }

    func incrementStop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

    func incrementRefresh() {
        lock.lock()
        refreshed += 1
        lock.unlock()
    }

    func snapshot() -> (starts: Int, stops: Int, refreshed: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (starts, stops, refreshed)
    }
}

nonisolated final class LockedAccessState: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool

    init(isAllowed: Bool) {
        self.allowed = isAllowed
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return allowed
        }
        set {
            lock.lock()
            allowed = newValue
            lock.unlock()
        }
    }
}

final class MockURLProtocol: URLProtocol {
    struct Response {
        let data: Data
        let statusCode: Int
        let delay: TimeInterval
        let chunkDelay: TimeInterval
        let responseURL: URL?
        let responseIsHTTP: Bool
        let sendsResponse: Bool

        init(
            data: Data,
            statusCode: Int = 200,
            delay: TimeInterval = 0,
            chunkDelay: TimeInterval = 0,
            responseURL: URL? = nil,
            responseIsHTTP: Bool = true,
            sendsResponse: Bool = true
        ) {
            self.data = data
            self.statusCode = statusCode
            self.delay = delay
            self.chunkDelay = chunkDelay
            self.responseURL = responseURL
            self.responseIsHTTP = responseIsHTTP
            self.sendsResponse = sendsResponse
        }
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var responseHandler: ((URLRequest) -> Response)?
    private let stopLock = NSLock()
    private var stopped = false

    static func configure(handler: @escaping (URLRequest) -> Response) {
        stateLock.lock()
        responseHandler = handler
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        let response = Self.responseHandler?(request) ?? Response(data: Data(), statusCode: 500)
        Self.stateLock.unlock()
        if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
        guard !isStopped else { return }

        if response.sendsResponse {
            let url = response.responseURL ?? request.url!
            let urlResponse: URLResponse
            if response.responseIsHTTP {
                urlResponse = HTTPURLResponse(
                    url: url,
                    statusCode: response.statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/octet-stream"]
                )!
            } else {
                urlResponse = URLResponse(
                    url: url,
                    mimeType: "application/octet-stream",
                    expectedContentLength: response.data.count,
                    textEncodingName: nil
                )
            }
            client?.urlProtocol(self, didReceive: urlResponse, cacheStoragePolicy: .notAllowed)
        }
        let chunkSize = max(response.data.count / 32, 1)
        var offset = 0
        while offset < response.data.count {
            guard !isStopped else { return }
            let end = min(offset + chunkSize, response.data.count)
            client?.urlProtocol(self, didLoad: response.data.subdata(in: offset..<end))
            offset = end
            if response.chunkDelay > 0 { Thread.sleep(forTimeInterval: response.chunkDelay) }
        }
        guard !isStopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }
}
