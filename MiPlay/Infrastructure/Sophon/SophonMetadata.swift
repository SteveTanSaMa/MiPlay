import Foundation
import CryptoKit

nonisolated public struct SophonCategory: Sendable {
    public let id: String
    public let categoryID: String
    public let manifestURL: URL
    public let manifestSize: Int
    public let manifestMD5: String
    public let chunkPrefix: URL
    public let chunkSuffix: String
}

nonisolated public struct SophonBuild: Sendable {
    public let version: String
    public let categories: [SophonCategory]
    let game: GameType
    let branch: String
    let packageID: String
    let password: String
    let diffTags: [String]
}

/// Read-only official mainland metadata; never persists or logs branch credentials.
nonisolated public struct SophonMetadataClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func fetchBuild(for game: GameType, audioLanguages: Set<String> = ["zh-cn"]) async throws -> SophonBuild {
        guard let build = try await fetchBuild(for: game, audioLanguages: audioLanguages, preDownload: false) else {
            throw SophonProtocolError.invalidResponse("未找到完整的国服游戏分支")
        }
        return build
    }

    /// Checks only the lightweight branch endpoint. Network and malformed
    /// metadata failures remain distinguishable from an absent pre-download.
    public func fetchPreDownloadVersion(for game: GameType) async throws -> String? {
        guard game.definition.contentCapabilities.sophonPredownload else { return nil }
        let branches = try await fetchBranches(for: game)
        guard let branch = try preDownloadBranch(in: branches) else { return nil }
        return branch["tag"] as? String
    }

    public func fetchPreDownloadBuild(for game: GameType, audioLanguages: Set<String> = ["zh-cn"]) async throws -> SophonBuild? {
        guard game.definition.contentCapabilities.sophonPredownload else { return nil }
        return try await fetchBuild(for: game, audioLanguages: audioLanguages, preDownload: true)
    }

    private func fetchBranches(for game: GameType) async throws -> [String: Any] {
        let gameID = game.definition.mainlandGameID
        var branchesURL = URLComponents(string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getGameBranches")!
        branchesURL.queryItems = [URLQueryItem(name: "launcher_id", value: "jGHBHlcOq1"), URLQueryItem(name: "game_ids[]", value: gameID)]
        let response = try await getJSON(try require(branchesURL.url, "无效的分支 URL"))
        let data = try dictionary(response["data"], "缺少分支数据")
        guard let records = data["game_branches"] as? [[String: Any]], records.count == 1,
              let returnedGame = records[0]["game"] as? [String: Any],
              returnedGame["id"] as? String == gameID else {
            throw SophonProtocolError.invalidResponse("未找到完整的国服游戏分支")
        }
        return records[0]
    }

    private func preDownloadBranch(in branches: [String: Any]) throws -> [String: Any]? {
        guard let main = branches["main"] as? [String: Any], main["branch"] as? String == "main",
              let mainVersion = main["tag"] as? String, !mainVersion.isEmpty else {
            throw SophonProtocolError.invalidResponse("正式游戏分支无效")
        }
        guard let value = branches["pre_download"], !(value is NSNull) else { return nil }
        guard let branch = value as? [String: Any], branch["branch"] as? String == "predownload",
              let tag = branch["tag"] as? String, !tag.isEmpty else {
            throw SophonProtocolError.invalidResponse("预下载分支无效")
        }
        return try Self.compareVersions(tag, mainVersion) == .orderedDescending ? branch : nil
    }

    static func compareVersions(_ lhs: String, _ rhs: String) throws -> ComparisonResult {
        func components(_ value: String) -> [UInt64]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 8,
                  parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
            let numbers = parts.compactMap { UInt64($0) }
            return numbers.count == parts.count ? numbers : nil
        }
        guard let lhsParts = components(lhs), let rhsParts = components(rhs) else {
            throw SophonProtocolError.invalidResponse("游戏分支版本号无效")
        }
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let a = index < lhsParts.count ? lhsParts[index] : 0
            let b = index < rhsParts.count ? rhsParts[index] : 0
            if a > b { return .orderedDescending }
            if a < b { return .orderedAscending }
        }
        return .orderedSame
    }

    private func fetchBuild(for game: GameType, audioLanguages: Set<String>, preDownload: Bool) async throws -> SophonBuild? {
        let branches = try await fetchBranches(for: game)
        let branch: [String: Any]
        if preDownload {
            guard let selected = try preDownloadBranch(in: branches) else { return nil }
            branch = selected
        } else {
            guard let selected = branches["main"] as? [String: Any] else {
                throw SophonProtocolError.invalidResponse("未找到完整的国服游戏分支")
            }
            branch = selected
        }
        guard let branchName = branch["branch"] as? String, branchName == (preDownload ? "predownload" : "main"),
              let branchVersion = branch["tag"] as? String, !branchVersion.isEmpty,
              let packageID = branch["package_id"] as? String,
              let password = branch["password"] as? String,
              let descriptors = branch["categories"] as? [[String: Any]] else {
            throw SophonProtocolError.invalidResponse("未找到完整的国服游戏分支")
        }
        // FULL resource categories include all of ZZZ's numeric resource groups.
        // Include the explicitly selected voice packs while preserving all FULL resources.
        let selected = descriptors.filter { category in
            guard let field = category["matching_field"] as? String,
                  let type = category["type"] as? String,
                  let scenarios = category["scenarios"] as? [String],
                  scenarios.contains("CATEGORY_SCENARIO_FULL") else { return false }
            return type == "CATEGORY_TYPE_RESOURCE" || (type == "CATEGORY_TYPE_AUDIO" && audioLanguages.contains(field))
        }
        guard selected.contains(where: { $0["matching_field"] as? String == "game" }) else {
            throw SophonProtocolError.invalidResponse("缺少游戏主要资源分类")
        }
        for language in audioLanguages {
            guard selected.contains(where: { $0["type"] as? String == "CATEGORY_TYPE_AUDIO" && $0["matching_field"] as? String == language }) else {
                throw SophonProtocolError.invalidResponse("缺少已选择的语音分类：\(language)")
            }
        }
        var buildURL = URLComponents(string: "https://api-takumi.mihoyo.com/downloader/sophon_chunk/api/getBuild")!
        buildURL.queryItems = [URLQueryItem(name: "branch", value: branchName), URLQueryItem(name: "package_id", value: packageID), URLQueryItem(name: "password", value: password)]
        let buildResponse = try await getJSON(try require(buildURL.url, "无效的构建 URL"))
        let buildData = try dictionary(buildResponse["data"], "缺少构建数据")
        guard let version = buildData["tag"] as? String, version == branchVersion,
              let manifests = buildData["manifests"] as? [[String: Any]] else {
            throw SophonProtocolError.invalidResponse("缺少游戏清单")
        }
        var categories: [SophonCategory] = []
        var fields = Set<String>()
        for descriptor in selected {
            guard let field = descriptor["matching_field"] as? String,
                  let categoryID = descriptor["category_id"] as? String,
                  fields.insert(categoryID).inserted else {
                throw SophonProtocolError.invalidResponse("重复或无效的资源分类")
            }
            let matches = manifests.filter { $0["category_id"] as? String == categoryID }
            guard matches.count == 1, let m = matches.first,
                  m["matching_field"] as? String == field,
                  let manifest = m["manifest"] as? [String: Any],
                  let manifestID = manifest["id"] as? String, !manifestID.isEmpty,
                  let md5 = manifest["checksum"] as? String,
                  let size = Self.integer(manifest["uncompressed_size"]), size <= 512 * 1024 * 1024,
                  let download = m["manifest_download"] as? [String: Any],
                  let chunks = m["chunk_download"] as? [String: Any],
                  let manifestPrefix = download["url_prefix"] as? String,
                  let chunkPrefix = chunks["url_prefix"] as? String else {
                throw SophonProtocolError.invalidResponse("资源分类 \(field) 的清单不完整")
            }
            guard Self.integer(download["encryption"]) == 0, Self.integer(chunks["encryption"]) == 0,
                  Self.integer(download["compression"]) == 1, Self.integer(chunks["compression"]) == 1 else {
                throw SophonProtocolError.unsupported("资源分类 \(field) 的压缩或加密方式不受支持")
            }
            guard !manifestID.contains("/"), !manifestID.contains("\\"), manifestID != ".", manifestID != "..",
                  let manifestBase = URL(string: manifestPrefix), manifestBase.scheme == "https", manifestBase.host != nil,
                  let chunkBase = URL(string: chunkPrefix), chunkBase.scheme == "https", chunkBase.host != nil else {
                throw SophonProtocolError.invalidResponse("资源下载地址无效")
            }
            let suffix = download["url_suffix"] as? String ?? ""
            let chunkSuffix = chunks["url_suffix"] as? String ?? ""
            guard Self.validSuffix(suffix), Self.validSuffix(chunkSuffix) else {
                throw SophonProtocolError.invalidResponse("资源下载地址后缀无效")
            }
            let manifestURL = try require(URL(string: manifestBase.appendingPathComponent(manifestID).absoluteString + suffix), "无效的清单 URL")
            categories.append(SophonCategory(id: field, categoryID: categoryID, manifestURL: manifestURL, manifestSize: size,
                                             manifestMD5: md5.lowercased(), chunkPrefix: chunkBase,
                                             chunkSuffix: chunkSuffix))
        }
        return SophonBuild(version: version, categories: categories, game: game, branch: branchName,
                           packageID: packageID, password: password,
                           diffTags: branch["diff_tags"] as? [String] ?? [])
    }

    /// Official diff manifests enumerate removals for supported source tags.
    /// Actual changes are still downloaded as full chunks, not binary patches.
    public func fetchDeletions(for build: SophonBuild, from installedVersion: String) async throws -> [SophonDeletedFile] {
        if installedVersion == build.version { return [] }
        guard build.diffTags.contains(installedVersion) else {
            return try await historicalFiles(for: build, installedVersion: installedVersion)
        }
        var components = URLComponents(string: "https://api-takumi.mihoyo.com/downloader/sophon_chunk/api/getPatchBuild")!
        components.queryItems = [URLQueryItem(name: "branch", value: build.branch), URLQueryItem(name: "package_id", value: build.packageID), URLQueryItem(name: "password", value: build.password)]
        var request = URLRequest(url: try require(components.url, "无效的差分清单 URL"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url?.scheme == "https",
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["retcode"] as? Int == 0,
              let payload = json["data"] as? [String: Any], payload["tag"] as? String == build.version,
              let manifests = payload["manifests"] as? [[String: Any]] else {
            throw SophonProtocolError.invalidResponse("未能获取官方差分清单")
        }
        var deletions: [SophonDeletedFile] = []
        for category in build.categories {
            try Task.checkCancellation()
            let matches = manifests.filter { $0["category_id"] as? String == category.categoryID }
            guard matches.count == 1, let entry = matches.first,
                  entry["matching_field"] as? String == category.id,
                  let manifest = entry["manifest"] as? [String: Any],
                  let name = manifest["id"] as? String, !name.isEmpty,
                  !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
                  let checksum = manifest["checksum"] as? String,
                  let size = Self.integer(manifest["uncompressed_size"]), size >= 0, size <= 512 * 1024 * 1024,
                  let manifestDownload = entry["manifest_download"] as? [String: Any],
                  Self.integer(manifestDownload["encryption"]) == 0, Self.integer(manifestDownload["compression"]) == 1,
                  let prefix = manifestDownload["url_prefix"] as? String,
                  let base = URL(string: prefix), base.scheme == "https", base.host != nil else {
                throw SophonProtocolError.invalidResponse("资源分类 \(category.id) 的差分清单不完整")
            }
            let suffix = manifestDownload["url_suffix"] as? String ?? ""
            guard Self.validSuffix(suffix), let url = URL(string: base.appendingPathComponent(name).absoluteString + suffix) else {
                throw SophonProtocolError.invalidResponse("差分清单地址无效")
            }
            let decoded = try SophonZstd.decompress(try await download(url), expectedSize: size)
            guard Self.md5(decoded) == checksum.lowercased() else { throw SophonProtocolError.corrupt("差分清单校验失败") }
            deletions.append(contentsOf: try SophonManifestDecoder.decodeDeletions(decoded, installedVersion: installedVersion))
        }
        return deletions
    }

    /// If no direct diff exists, reconstruct the old official file set from
    /// that exact version. The caller subtracts the new manifests and removes
    /// only old files whose on-disk content still matches their old checksum.
    private func historicalFiles(for build: SophonBuild, installedVersion: String) async throws -> [SophonDeletedFile] {
        var components = URLComponents(string: "https://api-takumi.mihoyo.com/downloader/sophon_chunk/api/getBuild")!
        components.queryItems = [URLQueryItem(name: "branch", value: build.branch), URLQueryItem(name: "package_id", value: build.packageID), URLQueryItem(name: "password", value: build.password), URLQueryItem(name: "tag", value: installedVersion)]
        let response = try await getJSON(try require(components.url, "无效的历史清单 URL"))
        guard let data = response["data"] as? [String: Any], data["tag"] as? String == installedVersion,
              let manifests = data["manifests"] as? [[String: Any]] else {
            throw SophonProtocolError.unsupported("官方未提供版本 \(installedVersion) 的完整清单")
        }
        let audio = Set(build.categories.map(\.id).filter { ["zh-cn", "en-us", "ja-jp", "ko-kr"].contains($0) })
        let knownAudio = Set(["zh-cn", "en-us", "ja-jp", "ko-kr"])
        var selected: [[String: Any]] = []
        var selectedFields = Set<String>()
        for manifest in manifests {
            guard let field = manifest["matching_field"] as? String else {
                throw SophonProtocolError.invalidResponse("历史资源分类无效")
            }
            if field.hasPrefix("mini-") || (knownAudio.contains(field) && !audio.contains(field)) { continue }
            let isNumeric = !field.isEmpty && field.utf8.allSatisfy { (48...57).contains($0) }
            let isResource = field == "game" || (build.game == .zenlessZoneZero && isNumeric)
            guard isResource || audio.contains(field) else {
                throw SophonProtocolError.unsupported("历史版本包含无法识别的资源分类：\(field)")
            }
            guard selectedFields.insert(field).inserted else {
                throw SophonProtocolError.invalidResponse("历史版本包含重复资源分类：\(field)")
            }
            selected.append(manifest)
        }
        guard selectedFields.contains("game"), audio.isSubset(of: selectedFields) else {
            throw SophonProtocolError.unsupported("历史版本缺少游戏或已安装语音清单")
        }
        var files: [SophonDeletedFile] = []
        for entry in selected {
            try Task.checkCancellation()
            guard let manifest = entry["manifest"] as? [String: Any],
                  let name = manifest["id"] as? String, !name.isEmpty,
                  !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
                  let checksum = manifest["checksum"] as? String,
                  let size = Self.integer(manifest["uncompressed_size"]), size >= 0, size <= 512 * 1024 * 1024,
                  let downloadInfo = entry["manifest_download"] as? [String: Any],
                  Self.integer(downloadInfo["encryption"]) == 0, Self.integer(downloadInfo["compression"]) == 1,
                  let prefix = downloadInfo["url_prefix"] as? String,
                  let base = URL(string: prefix), base.scheme == "https", base.host != nil else {
                throw SophonProtocolError.invalidResponse("历史资源清单不完整")
            }
            let suffix = downloadInfo["url_suffix"] as? String ?? ""
            guard Self.validSuffix(suffix), let url = URL(string: base.appendingPathComponent(name).absoluteString + suffix) else {
                throw SophonProtocolError.invalidResponse("历史资源清单地址无效")
            }
            let decoded = try SophonZstd.decompress(try await download(url), expectedSize: size)
            guard Self.md5(decoded) == checksum.lowercased() else { throw SophonProtocolError.corrupt("历史清单校验失败") }
            for file in try SophonManifestDecoder.decode(decoded) {
                guard file.flags == 0 || file.flags == 64 else {
                    throw SophonProtocolError.unsupported("历史清单包含未知文件类型")
                }
                if file.flags == 0 {
                    files.append(SophonDeletedFile(path: file.path, size: file.size, md5: file.md5))
                }
            }
        }
        return files
    }

    public func downloadManifest(_ category: SophonCategory) async throws -> [SophonFile] {
        let compressed = try await download(category.manifestURL)
        return try autoreleasepool {
            let decoded = try SophonZstd.decompress(compressed, expectedSize: category.manifestSize)
            guard Self.md5(decoded) == category.manifestMD5 else { throw SophonProtocolError.corrupt("清单校验失败") }
            return try SophonManifestDecoder.decode(decoded)
        }
    }

    public func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host != nil else { throw SophonProtocolError.invalidResponse("下载地址必须为 HTTPS") }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url?.scheme == "https" else { throw SophonProtocolError.invalidResponse("素材请求失败") }
        return data
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let data = try await download(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["retcode"] as? Int == 0 else { throw SophonProtocolError.invalidResponse("官方接口返回错误") }
        return json
    }
    private func dictionary(_ value: Any?, _ message: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw SophonProtocolError.invalidResponse(message) }
        return result
    }
    private func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SophonProtocolError.invalidResponse(message) }
        return value
    }
    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }
    private static func validSuffix(_ value: String) -> Bool {
        value.isEmpty || (value.hasPrefix("?") && !value.contains("#") &&
                          !value.contains("\r") && !value.contains("\n"))
    }
    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
