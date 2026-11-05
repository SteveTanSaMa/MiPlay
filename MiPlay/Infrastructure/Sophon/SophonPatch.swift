import Foundation
import CryptoKit

/// Metadata for one target file. A nil original hash denotes a newly added file.
nonisolated struct SophonPatchFile: Sendable, Equatable, Codable {
    let path: String
    let size: UInt64
    let md5: String
    let objectID: String
    let objectSize: UInt64
    let offset: UInt64
    let length: UInt64
    let originalPath: String?
    let originalSize: UInt64
    let originalMD5: String?
}

nonisolated struct SophonPatchCategory: Sendable {
    let id: String
    let prefix: URL
    let suffix: String
    let files: [SophonPatchFile]
}

/// Fetches only official descriptors and manifests; branch credentials are never persisted.
nonisolated struct SophonPatchClient: Sendable {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func fetch(build: SophonBuild, from version: String) async throws -> [SophonPatchCategory] {
        guard build.diffTags.contains(version), version != build.version else {
            throw SophonProtocolError.unsupported("官方未提供此版本的直接差分")
        }
        var components = URLComponents(string: "https://api-takumi.mihoyo.com/downloader/sophon_chunk/api/getPatchBuild")!
        components.queryItems = [URLQueryItem(name: "branch", value: build.branch), URLQueryItem(name: "package_id", value: build.packageID), URLQueryItem(name: "password", value: build.password)]
        guard let url = components.url else { throw SophonProtocolError.invalidResponse("无效的差分元数据地址") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let transport = SophonBoundedTransport(configuration: session.configuration)
        defer { transport.invalidate() }
        let (data, response) = try await transport.fetch(request, limit: 8 * 1024 * 1024)
        guard (200..<300).contains(response.statusCode),
              response.url?.scheme == "https", response.url?.host == url.host,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["retcode"] as? Int == 0, let payload = json["data"] as? [String: Any],
              payload["tag"] as? String == build.version,
              let entries = payload["manifests"] as? [[String: Any]] else {
            throw SophonProtocolError.invalidResponse("官方差分元数据无效")
        }
        var result: [SophonPatchCategory] = []
        for category in build.categories {
            let matches = entries.filter { $0["category_id"] as? String == category.categoryID }
            guard matches.count == 1, let entry = matches.first,
                  entry["matching_field"] as? String == category.id,
                  let manifest = entry["manifest"] as? [String: Any],
                  let name = manifest["id"] as? String, Self.safeComponent(name),
                  let checksum = manifest["checksum"] as? String, Self.isMD5(checksum),
                  let size = Self.integer(manifest["uncompressed_size"]), size <= 512 * 1024 * 1024,
                  let compressedSize = Self.integer(manifest["compressed_size"]), compressedSize <= 512 * 1024 * 1024,
                  let manifestDownload = entry["manifest_download"] as? [String: Any],
                  Self.integer(manifestDownload["encryption"]) == 0, Self.integer(manifestDownload["compression"]) == 1,
                  let prefixText = manifestDownload["url_prefix"] as? String,
                  let manifestPrefix = Self.safePrefix(prefixText),
                  let patchDownload = entry["diff_download"] as? [String: Any],
                  Self.integer(patchDownload["encryption"]) == 0, Self.integer(patchDownload["compression"]) == 0,
                  let patchPrefixText = patchDownload["url_prefix"] as? String,
                  let patchPrefix = Self.safePrefix(patchPrefixText) else {
                throw SophonProtocolError.invalidResponse("官方差分分类无效")
            }
            let manifestSuffix = manifestDownload["url_suffix"] as? String ?? ""
            let suffix = patchDownload["url_suffix"] as? String ?? ""
            guard Self.safeSuffix(manifestSuffix), Self.safeSuffix(suffix),
                  let manifestURL = URL(string: manifestPrefix.appendingPathComponent(name).absoluteString + manifestSuffix) else {
                throw SophonProtocolError.invalidResponse("差分地址无效")
            }
            let (compressed, response) = try await transport.fetch(URLRequest(url: manifestURL), limit: Int(compressedSize))
            guard (200..<300).contains(response.statusCode),
                  response.url?.scheme == "https", response.url?.host == manifestURL.host,
                  compressed.count == Int(compressedSize) else {
                throw SophonProtocolError.invalidResponse("无法获取差分清单")
            }
            let decoded = try SophonZstd.decompress(compressed, expectedSize: Int(size))
            guard Insecure.MD5.hash(data: decoded).map({ String(format: "%02x", $0) }).joined() == checksum.lowercased() else {
                throw SophonProtocolError.corrupt("差分清单校验失败")
            }
            result.append(SophonPatchCategory(id: category.id, prefix: patchPrefix, suffix: suffix,
                                               files: try SophonPatchDecoder.decode(decoded, version: version)))
        }
        return result
    }

    static func integer(_ value: Any?) -> UInt64? {
        if let s = value as? String { return UInt64(s) }
        if let n = value as? Int, n >= 0 { return UInt64(n) }
        return nil
    }
    static func isMD5(_ s: String) -> Bool {
        s.utf8.count == 32 && s.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0") && !value.contains("%")
    }
    static func safePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safeComponent(String($0)) } &&
        ![".miplay-sophon-download", ".miplay-sophon-transaction"].contains(path.split(separator: "/").first?.lowercased() ?? "")
    }
    static func safePrefix(_ text: String) -> URL? {
        guard let c = URLComponents(string: text), c.scheme == "https", c.host != nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, let url = c.url else { return nil }
        return url
    }
    static func safeSuffix(_ text: String) -> Bool {
        text.isEmpty || (text.hasPrefix("?") && !text.contains("#") && !text.contains("\r") && !text.contains("\n"))
    }
}

/// Decodes the public protobuf wire format without linking a protobuf runtime.
nonisolated enum SophonPatchDecoder {
    static func decode(_ data: Data, version: String) throws -> [SophonPatchFile] {
        var reader = PatchReader(data), files: [SophonPatchFile] = [], paths = Set<String>(), objects: [String: UInt64] = [:]
        while !reader.end {
            let (field, wire) = try reader.key()
            guard field == 1 && wire == 2 else { try reader.skip(wire); continue }
            var f = PatchReader(try reader.bytes()), path = "", hash = "", size: UInt64 = 0, selected: PatchFields?
            while !f.end {
                let (n, w) = try f.key()
                switch (n, w) {
                case (1, 2): path = try f.string()
                case (2, 0): size = try f.varint()
                case (3, 2): hash = try f.string()
                case (4, 2):
                    var p = PatchReader(try f.bytes()), key = "", info = Data()
                    while !p.end {
                        let (n, w) = try p.key()
                        if n == 1 && w == 2 { key = try p.string() }
                        else if n == 2 && w == 2 { info = try p.bytes() }
                        else { try p.skip(w) }
                    }
                    if key == version {
                        guard selected == nil else { throw SophonProtocolError.corrupt("重复差分版本") }
                        selected = try PatchFields.decode(info)
                    }
                default: try f.skip(w)
                }
            }
            guard let p = selected else { continue }
            guard SophonPatchClient.safePath(path), paths.insert(path.lowercased()).inserted,
                  SophonPatchClient.isMD5(hash), size <= UInt64(Int64.max),
                  SophonPatchClient.safeComponent(p.id), p.size > 0, p.size <= UInt64(Int64.max),
                  p.length > 0, p.offset <= p.size, p.length <= p.size - p.offset,
                  p.tag == version,
                  (p.originalPath.isEmpty ? p.originalHash.isEmpty && p.originalSize == 0 :
                    SophonPatchClient.safePath(p.originalPath) && SophonPatchClient.isMD5(p.originalHash)),
                  objects[p.id] == nil || objects[p.id] == p.size else {
                throw SophonProtocolError.corrupt("差分清单包含不安全或不一致的条目")
            }
            objects[p.id] = p.size
            files.append(SophonPatchFile(path: path, size: size, md5: hash.lowercased(), objectID: p.id,
                objectSize: p.size, offset: p.offset, length: p.length,
                originalPath: p.originalPath.isEmpty ? nil : p.originalPath, originalSize: p.originalSize,
                originalMD5: p.originalHash.isEmpty ? nil : p.originalHash.lowercased()))
        }
        return files
    }
    private struct PatchFields {
        var id = "", tag = "", originalPath = "", originalHash = ""
        var size: UInt64 = 0, offset: UInt64 = 0, length: UInt64 = 0, originalSize: UInt64 = 0
        static func decode(_ data: Data) throws -> PatchFields {
            var r = PatchReader(data), p = PatchFields()
            while !r.end {
                let (n,w) = try r.key()
                switch (n,w) {
                case (1,2): p.id = try r.string()
                case (2,2): p.tag = try r.string()
                case (4,0): p.size = try r.varint()
                case (6,0): p.offset = try r.varint()
                case (7,0): p.length = try r.varint()
                case (8,2): p.originalPath = try r.string()
                case (9,0): p.originalSize = try r.varint()
                case (10,2): p.originalHash = try r.string()
                default: try r.skip(w)
                }
            }
            return p
        }
    }
}

nonisolated private struct PatchReader {
    let data: Data
    var index = 0
    init(_ data: Data) { self.data = data }
    var end: Bool { index == data.count }
    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<10 {
            guard index < data.count else { throw SophonProtocolError.corrupt("protobuf 截断") }
            let byte = data[data.startIndex + index]; index += 1
            guard i != 9 || byte <= 1 else { throw SophonProtocolError.corrupt("protobuf 整数溢出") }
            value |= UInt64(byte & 127) << (i * 7)
            if byte & 128 == 0 { return value }
        }
        throw SophonProtocolError.corrupt("protobuf 整数无效")
    }
    mutating func key() throws -> (Int, Int) {
        let v = try varint()
        guard v >> 3 > 0, v >> 3 <= UInt64(Int.max) else { throw SophonProtocolError.corrupt("protobuf 字段无效") }
        return (Int(v >> 3), Int(v & 7))
    }
    mutating func bytes() throws -> Data {
        let count = try varint()
        guard count <= UInt64(data.count - index) else { throw SophonProtocolError.corrupt("protobuf 内容截断") }
        defer { index += Int(count) }
        return data.subdata(in: index..<(index + Int(count)))
    }
    mutating func string() throws -> String {
        guard let value = String(data: try bytes(), encoding: .utf8) else { throw SophonProtocolError.corrupt("protobuf 文本无效") }
        return value
    }
    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 2: _ = try bytes()
        case 1, 5:
            let count = wire == 1 ? 8 : 4
            guard count <= data.count - index else { throw SophonProtocolError.corrupt("protobuf 内容截断") }
            index += count
        default: throw SophonProtocolError.corrupt("protobuf wire type 无效")
        }
    }
}
