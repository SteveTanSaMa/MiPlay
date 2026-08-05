import Foundation

/// Client for the Sophon Python backend server.
/// Handles game install/repair/update operations via HTTP and WebSocket.
/// Replaces YAAGL's `sophon.ts`.
final class SophonService {

    // MARK: - Types

    struct InstallOptions: Codable {
        let gameDir: String
        let gameType: String
        let tempDir: String
        let installRelType: String
    }

    struct UpdateOptions: Codable {
        let gameDir: String
        let gameType: String
        let tempDir: String
        let predownload: Bool
    }

    struct RepairOptions: Codable {
        let gameDir: String
        let gameType: String
        let tempDir: String
        let repairMode: String
    }

    struct TaskResponse: Codable {
        let taskId: String
        let status: String
        let message: String?
    }

    struct TaskStatus: Codable {
        let taskId: String
        let status: String
        let progress: Double?
        let error: String?
    }

    struct OnlineGameInfo: Codable {
        let gameType: String
        let version: String
        let installSize: Int
        let updatableVersions: [String]
        let releaseType: String
        let preDownload: Bool
        let preDownloadVersion: String?
        let error: String?
    }

    // MARK: - Errors

    enum SophonError: LocalizedError {
        case serverNotRunning
        case taskFailed(String)
        case connectionFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .serverNotRunning: return "Sophon server is not running"
            case .taskFailed(let msg): return "Sophon task failed: \(msg)"
            case .connectionFailed(let msg): return "Sophon connection failed: \(msg)"
            case .invalidResponse: return "Invalid response from Sophon server"
            }
        }
    }

    // MARK: - Configuration

    let host: String
    let port: Int
    private let session: URLSession
    private let decoder: JSONDecoder

    private var baseURL: String { "http://\(host):\(port)" }
    private var wsBaseURL: String { "ws://\(host):\(port)" }

    // MARK: - Initialization

    init(host: String = "127.0.0.1", port: Int = 6969) {
        self.host = host
        self.port = port
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    // MARK: - Health Check

    func healthCheck() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Game Operations

    /// Start a game installation.
    func startInstallation(options: InstallOptions) async throws -> String {
        let data = try JSONEncoder().encode(options)
        let response: TaskResponse = try await post(path: "/api/install", body: data)
        return response.taskId
    }

    /// Start a game repair.
    func startRepair(options: RepairOptions) async throws -> String {
        let data = try JSONEncoder().encode(options)
        let response: TaskResponse = try await post(path: "/api/repair", body: data)
        return response.taskId
    }

    /// Start a game update.
    func startUpdate(options: UpdateOptions) async throws -> String {
        let data = try JSONEncoder().encode(options)
        let response: TaskResponse = try await post(path: "/api/update", body: data)
        return response.taskId
    }

    /// Get online game information.
    func getLatestOnlineGameInfo(relType: String, gameType: String) async throws -> OnlineGameInfo {
        guard var components = URLComponents(string: "\(baseURL)/api/game/online_info") else {
            throw SophonError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "reltype", value: relType),
            URLQueryItem(name: "game", value: gameType)
        ]
        guard let url = components.url else { throw SophonError.invalidResponse }

        let (data, _) = try await session.data(from: url)
        return try decoder.decode(OnlineGameInfo.self, from: data)
    }

    /// Cancel a running task.
    func cancelOperation(taskId: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/tasks/\(taskId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, _) = try await session.data(for: request)
    }

    /// Stream operation progress via WebSocket.
    func streamOperationProgress(taskId: String) -> AsyncThrowingStream<SophonProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let url = URL(string: "\(wsBaseURL)/ws/\(taskId)") else {
                continuation.finish(throwing: SophonError.invalidResponse)
                return
            }

            let task = session.webSocketTask(with: url)
            task.resume()

            func receive() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8),
                               let event = try? JSONDecoder().decode(SophonProgressEvent.self, from: data) {
                                continuation.yield(event)
                                if event.type == "completed" {
                                    continuation.finish()
                                    task.cancel()
                                    return
                                } else if event.type == "error" {
                                    continuation.finish(throwing: SophonError.taskFailed(event.error ?? "Unknown error"))
                                    task.cancel()
                                    return
                                }
                            }
                        case .data(let data):
                            if let event = try? JSONDecoder().decode(SophonProgressEvent.self, from: data) {
                                continuation.yield(event)
                            }
                        @unknown default:
                            break
                        }
                        receive()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                        task.cancel()
                    }
                }
            }

            receive()

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Lifecycle

    /// Start the Sophon server as a subprocess.
    /// Tries the compiled binary first, then falls back to the Python launcher script.
    func startServer(terminateWithPID: Int32? = nil) throws -> Process {
        guard let resources = Bundle.main.resourceURL else {
            throw SophonError.serverNotRunning
        }

        // Try compiled binary first, then launcher script
        let binaryURL = resources.appendingPathComponent("sophon-server")
        let launcherURL = resources.appendingPathComponent("sophon-server-launcher.sh")
        let serverURL = FileManager.default.fileExists(atPath: binaryURL.path) ? binaryURL : launcherURL

        guard FileManager.default.fileExists(atPath: serverURL.path) else {
            throw SophonError.serverNotRunning
        }

        let process = Process()
        process.executableURL = serverURL
        process.arguments = ["--port", "\(port)"]

        if let pid = terminateWithPID {
            var args = process.arguments ?? []
            args.append("--terminate-with-pid")
            args.append("\(pid)")
            process.arguments = args
        }

        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    // MARK: - Internal

    private func post<T: Decodable>(path: String, body: Data) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw SophonError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SophonError.connectionFailed("HTTP error")
        }

        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Sophon Progress Event

/// Progress event from the Sophon server WebSocket protocol.
nonisolated struct SophonProgressEvent: Codable, Sendable {
    let type: String
    let taskId: String?
    let filename: String?
    let progressPercent: Double?
    let totalBytes: Int64?
    let downloadedBytes: Int64?
    let downloadSpeed: Double?
    let error: String?
    let fileSize: Int64?

    enum CodingKeys: String, CodingKey, Sendable {
        case type, taskId, filename, error, fileSize
        case progressPercent = "progress_percent"
        case totalBytes = "total_bytes"
        case downloadedBytes = "downloaded_bytes"
        case downloadSpeed = "download_speed"
    }
}
