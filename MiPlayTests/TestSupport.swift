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
        let backgroundMediaService: BackgroundMediaService
        let launchOrchestrator: LaunchOrchestrator
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
        let wine = WineRuntimeProvider(processManager: process, fileSystemRepository: fileSystem)
        let wineManager = WineVersionManager(
            networkProvider: network,
            fileSystemRepository: fileSystem,
            persistenceStore: persistence,
            wineVersionDownloader: wineDownloader,
            logWriter: logger,
            wineRuntimeProvider: wine
        )
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
        let backgroundMediaService = BackgroundMediaService(
            mediaTranscoder: MediaTranscoder(processManager: process, logWriter: logger),
            mediaCacheManager: MediaCacheManager(baseURL: try makeTemporaryDirectory()),
            networkProvider: network,
            persistenceStore: persistence,
            logWriter: logger
        )
        let scheduler = TaskScheduler(
            launchOrchestrator: launch,
            solutionEngine: solution,
            gameRegistry: registry,
            integrityVerifier: verifier,
            versionChecker: versionChecker,
            persistenceStore: persistence,
            logWriter: logger,
            wineVersionManager: wineManager,
            backgroundMediaService: backgroundMediaService
        )
        await registry.initialize()
        return SchedulerFixture(
            scheduler: scheduler,
            registry: registry,
            persistence: persistence,
            wineManager: wineManager,
            logger: logger,
            backgroundMediaService: backgroundMediaService,
            launchOrchestrator: launch
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
        assetURL: String = "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz",
        downloadResponseURL: String? = nil
    ) throws -> NetworkDownloadProvider {
        MockURLProtocol.configure { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/releases/tags/\(WineVersionManager.fixedRuntimeTag)") {
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
            if path.hasSuffix("/releases/download/\(WineVersionManager.fixedRuntimeTag)/wine-crossover-11.0-1-osx64-signed.tar.xz") {
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
        let script = """
        #!/bin/sh
        case \"$1\" in
            --version) echo 'wine-crossover-11.0-1-signed' ;;
            wineboot) /bin/mkdir -p \"$WINEPREFIX/drive_c\" \"$WINEPREFIX/dosdevices\" ;;
        esac
        """
        try Data(script.utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

        let filler = root.appendingPathComponent("payload.bin")
        try Data(repeating: 0x5a, count: fillerBytes).write(to: filler)

        let archiveURL = root.appendingPathComponent("wine.tar.xz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cJf", archiveURL.path, "-C", root.path, "bin", "payload.bin"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestTimeout.archiveCreationFailed }
        return try Data(contentsOf: archiveURL)
    }

    func makeFixedWineRuntimePair(
        appSupport: URL,
        createPrefix: Bool = true
    ) throws -> (runtime: ManagedWineRuntimeRecord, prefix: SharedWinePrefixRecord) {
        let runtimeRoot = appSupport
            .appendingPathComponent("WineVersions", isDirectory: true)
            .appendingPathComponent(WineVersionManager.fixedRuntimeTag, isDirectory: true)
        let binaryDirectory = runtimeRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let binary = binaryDirectory.appendingPathComponent("wine")
        if !FileManager.default.fileExists(atPath: binary.path) {
            try FileManager.default.createSymbolicLink(
                at: binary,
                withDestinationURL: URL(fileURLWithPath: "/bin/sh")
            )
        }

        let prefixURL = appSupport
            .appendingPathComponent("WinePrefixes", isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
        if createPrefix {
            try FileManager.default.createDirectory(
                at: prefixURL.appendingPathComponent("drive_c", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: prefixURL.appendingPathComponent("dosdevices", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let runtime = ManagedWineRuntimeRecord(
            identity: WineVersionManager.fixedRuntimeTag,
            sourceID: BuiltInWineVersions.officialSource.sourceID,
            assetName: "wine-crossover-11.0-1-osx64-signed.tar.xz",
            rootPath: runtimeRoot.path,
            binaryPath: binary.path,
            state: "installed"
        )
        let prefix = SharedWinePrefixRecord(
            identity: WineVersionManager.sharedPrefixIdentity,
            relativePath: "WinePrefixes/shared",
            absolutePath: prefixURL.path,
            runtimeIdentity: WineVersionManager.fixedRuntimeTag,
            state: "ready"
        )
        return (runtime, prefix)
    }

    /// `nonisolated`：被 MockURLProtocol 的 `@Sendable` 响应闭包调用（后台队列）。
    nonisolated static func wineReleaseJSON(
        assetSize: Int,
        assetURL: String = "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz"
    ) -> Data {
        Data("""
        {"id":1,"tag_name":"wine-crossover-11.0-1-signed","name":"Wine CrossOver 11.0-1 Signed","assets":[{"name":"wine-crossover-11.0-1-osx64-signed.tar.xz","browser_download_url":"\(assetURL)","size":\(assetSize)}],"published_at":"2026-08-03T00:00:00Z"}
        """.utf8)
    }

    /// `nonisolated`：被 MockURLProtocol 的 `@Sendable` 响应闭包调用（后台队列）。
    nonisolated static func wineReleasesJSON(
        assetSize: Int,
        assetURL: String = "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz"
    ) -> Data {
        Data("""
        [{"id":1,"tag_name":"wine-crossover-11.0-1-signed","name":"Wine CrossOver 11.0-1 Signed","assets":[{"name":"wine-crossover-11.0-1-osx64-signed.tar.xz","browser_download_url":"\(assetURL)","size":\(assetSize)}],"published_at":"2026-08-03T00:00:00Z"}]
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
        backgroundResponseJSON(groupIDs: ["bg-1", "bg-2"])
    }

    /// hk4e_cn response whose first entry is a still-image group followed by a
    /// playable video group, used to verify first-parsed-resource resolution.
    static func mixedBackgroundResponseJSON() -> Data {
        Data("""
        {"retcode":0,"message":"OK","data":{"game_info_list":[{"game":{"id":"hk4e","biz":"hk4e_cn"},"backgrounds":[
        {"id":"bg-still","background":{"url":"https://example.com/bg-still.webp"},"video":null,"theme":null,"type":"BACKGROUND_TYPE_STATIC"},
        {"id":"bg-video","background":{"url":"https://example.com/bg-video.webp"},"video":{"url":"https://example.com/bg-video.webm"},"theme":null,"type":"BACKGROUND_TYPE_VIDEO"}
        ]}]}}
        """.utf8)
    }

    static func backgroundResponseJSON(
        groupIDs: [String],
        resourceURLs: [String: String] = [:]
    ) -> Data {
        let groups = groupIDs.map { id -> String in
            let backgroundURL = resourceURLs[id] ?? "https://example.com/\(id).webp"
            return """
            {"id":"\(id)","background":{"url":"\(backgroundURL)"},"video":null,"theme":null,"type":"BACKGROUND_TYPE_STATIC"}
            """
        }.joined(separator: ",")
        return Data("""
        {"retcode":0,"message":"OK","data":{"game_info_list":[{"game":{"id":"hk4e","biz":"hk4e_cn"},"backgrounds":[\(groups)]}]}}
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
    struct Response: Sendable {
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
    nonisolated(unsafe) private static var responseHandler: (@Sendable (URLRequest) -> Response)?
    private let stopLock = NSLock()
    private var stopped = false

    /// `@Sendable` 是必需的：`startLoading()` 由 CFNetwork 在后台队列（
    /// `com.apple.CFNetwork.CustomProtocols`）调用，而在 `@MainActor` 测试扩展里写的
    /// 闭包字面量默认带 MainActor 隔离。把它接到 `@Sendable` 参数上会取消该推断，
    /// 否则 Swift 6 运行时的 "Incorrect actor executor assumption" 检查会直接 trap
    /// （表现为整个测试 session 崩溃重启）。
    static func configure(handler: @escaping @Sendable (URLRequest) -> Response) {
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

        // 异步交付：真实网络的数据是随时间陆续到达的。此前在 `startLoading` 里
        // 同步发完全部数据，URLSession 的字节级进度（`didWriteData`）会滞后到
        // 传输结束之后，测试观察不到持续进度——与用户实测"进度停在 5%"是同一现象。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
            guard !self.isStopped else { return }

            if response.sendsResponse {
                let url = response.responseURL ?? self.request.url!
                let urlResponse: URLResponse
                if response.responseIsHTTP {
                    urlResponse = HTTPURLResponse(
                        url: url,
                        statusCode: response.statusCode,
                        httpVersion: nil,
                        // 带上 Content-Length：否则 URLSession 不知道预期长度，
                        // 下载任务的字节级进度（didWriteData）不会持续上报。
                        headerFields: [
                            "Content-Type": "application/octet-stream",
                            "Content-Length": String(response.data.count),
                        ]
                    )!
                } else {
                    urlResponse = URLResponse(
                        url: url,
                        mimeType: "application/octet-stream",
                        expectedContentLength: response.data.count,
                        textEncodingName: nil
                    )
                }
                self.client?.urlProtocol(self, didReceive: urlResponse, cacheStoragePolicy: .notAllowed)
            }
            let chunkSize = max(response.data.count / 32, 1)
            var offset = 0
            while offset < response.data.count {
                guard !self.isStopped else { return }
                let end = min(offset + chunkSize, response.data.count)
                self.client?.urlProtocol(self, didLoad: response.data.subdata(in: offset..<end))
                offset = end
                if response.chunkDelay > 0 { Thread.sleep(forTimeInterval: response.chunkDelay) }
            }
            guard !self.isStopped else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
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

/// 跨并发域记录一次性事实的小盒子。
///
/// `withObservationTracking(_:onChange:)` 的 `onChange` 闭包是 `@Sendable`：
/// Swift 6 语言模式下不能直接捕获并改写外部 `var`（会报
/// "mutation of captured var in concurrently-executing code"）。
/// 测试用这个加锁盒子记录"观察者已失效"，语义不变且线程安全。
final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func mark() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
