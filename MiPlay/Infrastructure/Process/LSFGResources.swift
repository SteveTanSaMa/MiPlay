import Foundation
import CryptoKit

/// Code ships with MiPlay; the user supplies the commercial shader package.
/// Imported packages are immutable and content-addressed so replacing the user's
/// selection cannot invalidate a running game's shader path.
nonisolated enum LSFGResources {
    /// Narrow test seam for external validators; production callers use
    /// ProcessManager, which sanitizes inherited injection and enforces timeouts.
    typealias ToolRunner = @Sendable (String, [String], [String: String], TimeInterval) async throws -> String

    struct Component: Sendable {
        let library: URL
        let driver: URL
        let preflight: URL
        let shaderCheck: URL
        let identity: String
    }

    struct Manifest: Codable, Sendable {
        let schema: Int
        let sha256: [String: String]
    }

    enum Failure: Error, LocalizedError {
        case unavailable, invalidComponent(String), invalidShader, missingShader, preflight(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "LSFG 组件尚未安装，请使用包含插帧组件的 MiPlay 构建。"
            case .invalidComponent(let file): return "LSFG 组件校验失败：\(file)"
            case .invalidShader: return "请选择 Lossless Scaling 的 lsfg-vk.dll；该文件未通过 shader 资源检查。"
            case .missingShader: return "请先在游戏设置中导入自己的 lsfg-vk.dll。"
            case .preflight(let reason): return "LSFG GPU 预检未通过：\(reason)"
            }
        }
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiPlay", isDirectory: true)
    }

    static var componentDirectory: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("RuntimeAssets/lsfg", isDirectory: true)
    }

    static let componentFiles = ["liblsfg_metal.dylib", "libMoltenVK.generator.dylib", "preflight", "shader-check"]

    /// Presence only. Every enabled launch verifies bytes and runs a fresh GPU preflight.
    static var isInstalled: Bool {
        (["manifest.json"] + componentFiles).allSatisfy {
            FileManager.default.fileExists(atPath: componentDirectory.appendingPathComponent($0).path)
        }
    }

    static var shaderPackageURL: URL {
        (try? selectedShader(in: supportDirectory))
            ?? supportDirectory.appendingPathComponent("LSFG/lsfg-vk.dll")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validatedComponent(at root: URL = componentDirectory) throws -> Component {
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes), manifest.schema == 1 else {
            throw Failure.unavailable
        }
        for name in componentFiles {
            guard let expected = manifest.sha256[name], expected.count == 64,
                  let data = try? Data(contentsOf: root.appendingPathComponent(name), options: .mappedIfSafe),
                  digest(data) == expected else { throw Failure.invalidComponent(name) }
        }
        let library = root.appendingPathComponent("liblsfg_metal.dylib")
        try requireX86MachO(library, fileType: 6)
        let preflight = root.appendingPathComponent("preflight")
        let checker = root.appendingPathComponent("shader-check")
        for tool in [preflight, checker] {
            try requireX86MachO(tool, fileType: 2)
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw Failure.invalidComponent(tool.lastPathComponent)
            }
        }
        guard !library.path.contains(":") else { throw Failure.invalidComponent("插帧库路径包含冒号") }
        return Component(library: library, driver: root.appendingPathComponent("libMoltenVK.generator.dylib"),
                         preflight: preflight, shaderCheck: checker, identity: digest(bytes))
    }

    static func requireX86MachO(_ url: URL, fileType: UInt32) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.invalidComponent(url.lastPathComponent) }
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 32), data.count == 32,
              Array(data[0..<4]) == [0xcf, 0xfa, 0xed, 0xfe],
              Array(data[4..<8]) == [7, 0, 0, 1],
              Array(data[12..<16]) == [UInt8(fileType), 0, 0, 0] else {
            throw Failure.invalidComponent("\(url.lastPathComponent) 需要 x86_64 Mach-O")
        }
    }

    static func selectedShader(in support: URL) throws -> URL {
        let root = support.appendingPathComponent("LSFG", isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("shader.json")),
              let selection = try? JSONDecoder().decode([String: String].self, from: data),
              let hash = selection["sha256"], hash.count == 64,
              hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw Failure.missingShader }
        let url = root.appendingPathComponent("Shaders/\(hash)/lsfg-vk.dll")
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe), digest(bytes) == hash else {
            throw Failure.invalidShader
        }
        return url
    }

    static func importShaderPackage(from source: URL) async throws {
        try await importShaderPackage(from: source, into: supportDirectory, components: componentDirectory)
    }

    static func importShaderPackage(from source: URL, into support: URL, components: URL,
                                    toolRunner: ToolRunner? = nil) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let component = try validatedComponent(at: components)
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize,
              (1...32 * 1024 * 1024).contains(size) else { throw Failure.invalidShader }
        let bytes = try Data(contentsOf: source)
        let hash = digest(bytes)
        let root = support.appendingPathComponent("LSFG", isDirectory: true)
        let staging = root.appendingPathComponent("Import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("lsfg-vk.dll")
        try bytes.write(to: candidate, options: .atomic)
        do {
            let output: String
            if let toolRunner {
                output = try await toolRunner(component.shaderCheck.path, [candidate.path], [:], 30)
            } else {
                output = try await ProcessManager().launchAndWait(executablePath: component.shaderCheck.path,
                                                                 arguments: [candidate.path], timeout: 30)
            }
            guard output.contains("Shader image-view checks passed: 2048 bindings") else { throw Failure.invalidShader }
        } catch is CancellationError { throw CancellationError() }
        catch { throw Failure.invalidShader }
        try Task.checkCancellation()
        let destination = root.appendingPathComponent("Shaders/\(hash)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let final = destination.appendingPathComponent("lsfg-vk.dll")
        // Atomic write also repairs a corrupt prior copy of this exact hash.
        if (try? Data(contentsOf: final)) != bytes { try bytes.write(to: final, options: .atomic) }
        try JSONEncoder().encode(["sha256": hash]).write(to: root.appendingPathComponent("shader.json"), options: .atomic)
    }
}
