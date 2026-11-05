import Foundation
import CryptoKit

/// Metadata and manifest types for the mainland HoYoPlay Sophon protocol.
/// All values originate from the official service and must be validated before use.
nonisolated public enum SophonProtocolError: Error, LocalizedError {
    case invalidResponse(String)
    case unsupported(String)
    case corrupt(String)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let value), .unsupported(let value), .corrupt(let value): return value
        }
    }
}

nonisolated public struct SophonChunk: Sendable, Equatable {
    public var name = ""
    public var md5 = ""
    public var offset: UInt64 = 0
    public var compressedSize: UInt64 = 0
    public var uncompressedSize: UInt64 = 0
    public var xxhash: UInt64 = 0
}

nonisolated public struct SophonFile: Sendable, Equatable {
    public var path = ""
    public var chunks: [SophonChunk] = []
    public var flags: UInt64 = 0
    public var size: UInt64 = 0
    public var md5 = ""
}

nonisolated public struct SophonDeletedFile: Sendable, Equatable {
    public var path = ""
    public var size: UInt64 = 0
    public var md5 = ""
}

/// Strict protobuf reader for the Sophon manifest schema. Unknown fields are
/// skipped according to their wire type to allow backwards-compatible additions.
nonisolated public enum SophonManifestDecoder {
    public static func decode(_ data: Data) throws -> [SophonFile] {
        var reader = Reader(data)
        var files: [SophonFile] = []
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            if field == 1 && wire == 2 { files.append(try decodeFile(reader.bytes())) }
            else { try reader.skip(wire) }
        }
        return files
    }

    /// `files_delete` maps installed-version tags to lists of old files.
    public static func decodeDeletions(_ data: Data, installedVersion: String) throws -> [SophonDeletedFile] {
        var result: [SophonDeletedFile] = []
        var reader = Reader(data)
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            guard field == 2 && wire == 2 else { try reader.skip(wire); continue }
            var item = Reader(try reader.bytes()), key = "", nested = Data()
            while !item.isAtEnd {
                let (field, wire) = try item.key()
                if field == 1 && wire == 2 { key = try item.string() }
                else if field == 2 && wire == 2 { nested = try item.bytes() }
                else { try item.skip(wire) }
            }
            guard key == installedVersion else { continue }
            var list = Reader(nested)
            while !list.isAtEnd {
                let (field, wire) = try list.key()
                guard field == 1 && wire == 2 else { try list.skip(wire); continue }
                var entry = Reader(try list.bytes()), file = SophonDeletedFile()
                while !entry.isAtEnd {
                    let (field, wire) = try entry.key()
                    switch (field, wire) {
                    case (1, 2): file.path = try entry.string()
                    case (2, 0): file.size = try entry.varint()
                    case (3, 2): file.md5 = try entry.string()
                    default: try entry.skip(wire)
                    }
                }
                result.append(file)
            }
        }
        return result
    }

    private static func decodeFile(_ data: Data) throws -> SophonFile {
        var r = Reader(data), result = SophonFile()
        while !r.isAtEnd {
            let (field, wire) = try r.key()
            switch (field, wire) {
            case (1, 2): result.path = try r.string()
            case (2, 2): result.chunks.append(try decodeChunk(r.bytes()))
            case (3, 0): result.flags = try r.varint()
            case (4, 0): result.size = try r.varint()
            case (5, 2): result.md5 = try r.string()
            default: try r.skip(wire)
            }
        }
        return result
    }

    private static func decodeChunk(_ data: Data) throws -> SophonChunk {
        var r = Reader(data), result = SophonChunk()
        while !r.isAtEnd {
            let (field, wire) = try r.key()
            switch (field, wire) {
            case (1, 2): result.name = try r.string()
            case (2, 2): result.md5 = try r.string()
            case (3, 0): result.offset = try r.varint()
            case (4, 0): result.compressedSize = try r.varint()
            case (5, 0): result.uncompressedSize = try r.varint()
            case (6, 0): result.xxhash = try r.varint()
            default: try r.skip(wire)
            }
        }
        return result
    }

    private struct Reader {
        let data: Data
        var index = 0
        init(_ data: Data) { self.data = data }
        var isAtEnd: Bool { index == data.count }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<10 {
                guard index < data.count else { throw SophonProtocolError.corrupt("截断的 protobuf varint") }
                let byte = data[data.startIndex + index]; index += 1
                if i == 9 && byte > 1 { throw SophonProtocolError.corrupt("protobuf varint 溢出") }
                value |= UInt64(byte & 0x7f) << (i * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw SophonProtocolError.corrupt("无效的 protobuf varint")
        }
        mutating func key() throws -> (Int, Int) {
            let n = try varint()
            guard n >> 3 > 0, n >> 3 <= UInt64(Int.max) else { throw SophonProtocolError.corrupt("无效的 protobuf 字段") }
            return (Int(n >> 3), Int(n & 7))
        }
        mutating func bytes() throws -> Data {
            let n = try varint()
            guard n <= UInt64(data.count - index) else { throw SophonProtocolError.corrupt("截断的 protobuf 内容") }
            let end = index + Int(n)
            defer { index = end }
            return data.subdata(in: index..<end)
        }
        mutating func string() throws -> String {
            guard let result = String(data: try bytes(), encoding: .utf8) else { throw SophonProtocolError.corrupt("无效的 UTF-8") }
            return result
        }
        mutating func skip(_ wire: Int) throws {
            switch wire {
            case 0: _ = try varint()
            case 1: try advance(8)
            case 2: _ = try bytes()
            case 5: try advance(4)
            default: throw SophonProtocolError.corrupt("不支持的 protobuf wire type")
            }
        }
        mutating func advance(_ n: Int) throws {
            guard n <= data.count - index else { throw SophonProtocolError.corrupt("截断的 protobuf 内容") }
            index += n
        }
    }
}

@_silgen_name("ZSTD_decompress")
nonisolated private func sophonZstdDecompress(_ dst: UnsafeMutableRawPointer?, _ dstCapacity: Int, _ src: UnsafeRawPointer?, _ srcSize: Int) -> Int
@_silgen_name("ZSTD_isError")
nonisolated private func sophonZstdIsError(_ code: Int) -> UInt32

nonisolated public enum SophonZstd {
    /// Decode the declared size exactly, refusing unreasonable or corrupt data.
    public static func decompress(_ compressed: Data, expectedSize: Int, limit: Int = 512 * 1024 * 1024) throws -> Data {
        guard expectedSize >= 0, expectedSize <= limit else { throw SophonProtocolError.corrupt("Zstandard 解压大小超限") }
        var output = Data(count: expectedSize)
        let decoded = output.withUnsafeMutableBytes { dst in
            compressed.withUnsafeBytes { src in
                sophonZstdDecompress(dst.baseAddress, dst.count, src.baseAddress, src.count)
            }
        }
        guard sophonZstdIsError(decoded) == 0, decoded == expectedSize else {
            throw SophonProtocolError.corrupt("Zstandard 数据无效或解压长度不符")
        }
        return output
    }
}
