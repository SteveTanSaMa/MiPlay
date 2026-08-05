import Foundation

/// Binary file analysis utilities.
/// Replaces YAAGL's `mhy/unity.ts` and helper functions.
enum BinaryUtils {

    // MARK: - Unity Version Detection

    /// Read game version from Unity's globalgamemanagers file.
    /// - Parameters:
    ///   - gameDataDir: Path to the game's `*_Data` directory.
    ///   - offset: Byte offset where the version string is stored (game-specific).
    /// - Returns: Version string if found, nil otherwise.
    static func readUnityVersion(fromGameDataDir gameDataDir: URL, offset: Int = 0) -> String? {
        let managersPath = gameDataDir.appendingPathComponent("globalgamemanagers")
        guard let data = try? Data(contentsOf: managersPath) else { return nil }

        if offset > 0, offset < data.count {
            return readNullTerminatedString(from: data, at: offset)
        }

        // Try common offsets
        for off in [0xAC, 0xC4, 0x00] {
            if off > 0, off < data.count, let version = readNullTerminatedString(from: data, at: off) {
                return version
            }
        }

        return nil
    }

    /// Read version from Unity 2019+ globalgamemanagers (used by HSR).
    static func readUnity2019Version(fromGameDataDir gameDataDir: URL) -> String? {
        readUnityVersion(fromGameDataDir: gameDataDir, offset: 0xAC)
    }

    // MARK: - Binary Pattern Search

    /// Search for a byte pattern in a file.
    /// - Parameters:
    ///   - data: File data to search.
    ///   - pattern: Byte pattern to find.
    /// - Returns: First offset where the pattern was found, or nil.
    static func binaryPatternSearch(in data: Data, pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, pattern.count <= data.count else { return nil }
        return data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return nil }
            let len = data.count
            let patLen = pattern.count
            return pattern.withUnsafeBytes { patBuf in
                guard let patBase = patBuf.baseAddress else { return nil }
                for i in 0...(len - patLen) {
                    if memcmp(base.advanced(by: i), patBase, patLen) == 0 {
                        return i
                    }
                }
                return nil
            }
        }
    }

    /// Search for an ASCII string in binary data.
    static func searchASCIIString(in data: Data, _ string: String) -> Int? {
        guard let pattern = string.data(using: .ascii) else { return nil }
        return binaryPatternSearch(in: data, pattern: [UInt8](pattern))
    }

    // MARK: - Version from Executable

    /// Try to get the game version from the main executable's PE version info.
    static func readVersionFromExe(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Search for version patterns like "x.x.x" in the binary
        let pattern = try? NSRegularExpression(pattern: "\\d+\\.\\d+\\.\\d+")
        if let pattern = pattern {
            let str = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) ?? ""
            let range = NSRange(str.startIndex..<str.endIndex, in: str)
            let matches = pattern.matches(in: str, range: range)
            // Heuristic: take the shortest match (most likely a version string)
            var bestMatch: String?
            for match in matches {
                if let r = Range(match.range, in: str) {
                    let candidate = String(str[r])
                    if bestMatch == nil || candidate.count < bestMatch!.count {
                        bestMatch = candidate
                    }
                }
            }
            return bestMatch
        }
        return nil
    }

    // MARK: - Helpers

    private static func readNullTerminatedString(from data: Data, at offset: Int) -> String? {
        var bytes: [UInt8] = []
        var pos = offset
        while pos < data.count {
            let byte = data[pos]
            if byte == 0 { break }
            bytes.append(byte)
            pos += 1
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
