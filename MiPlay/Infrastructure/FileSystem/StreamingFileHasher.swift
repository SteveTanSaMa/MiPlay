import CryptoKit
import Darwin
import Foundation

/// A single-owner incremental hasher with one reusable bounded read buffer.
/// Unlike repeated FileHandle.read calls, POSIX pread does not create an
/// autoreleased NSData for each megabyte on long-running Swift tasks.
nonisolated final class StreamingFileHasher<H: HashFunction>: @unchecked Sendable {
    static var bufferSize: Int { 1024 * 1024 }
    private var descriptor: Int32
    private let buffer: UnsafeMutableRawPointer
    private var hasher = H()
    private var offset: UInt64 = 0

    init(path: String, followSymlinks: Bool = false) throws {
        // O_NONBLOCK prevents an untrusted FIFO from stalling before fstat;
        // it has no effect on ordinary on-disk files.
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (followSymlinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw POSIXError(.EINVAL)
        }
        descriptor = fd
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: MemoryLayout<UInt64>.alignment)
    }

    deinit {
        close()
        buffer.deallocate()
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    func reset(offset: UInt64 = 0) throws {
        guard offset <= UInt64(Int64.max) else { throw POSIXError(.EOVERFLOW) }
        self.offset = offset
        hasher = H()
    }

    /// Returns zero at EOF. The returned byte count can be used to report
    /// progress without retaining a Data object across an asynchronous call.
    func readNext(maximum: Int = 1024 * 1024) throws -> Int {
        guard descriptor >= 0, maximum > 0, offset <= UInt64(Int64.max) else { throw POSIXError(.EINVAL) }
        let length = min(maximum, Self.bufferSize)
        while true {
            let count = Darwin.pread(descriptor, buffer, length, off_t(offset))
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else { return 0 }
            guard offset <= UInt64(Int64.max) - UInt64(count) else { throw POSIXError(.EOVERFLOW) }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            offset += UInt64(count)
            return count
        }
    }

    func digest() -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(H.Digest.byteCount * 2)
        for byte in hasher.finalize() {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Hash an optional bounded region using the same buffer. A short read is
    /// returned to the caller so truncated resume chunks can be redownloaded.
    func hash(offset: UInt64 = 0, length: UInt64? = nil, honorCancellation: Bool = true) throws -> (digest: String, bytes: UInt64) {
        try reset(offset: offset)
        var total: UInt64 = 0
        while length.map({ total < $0 }) ?? true {
            if honorCancellation { try Task.checkCancellation() }
            let remaining = length.map { $0 - total } ?? UInt64(Self.bufferSize)
            let count = try readNext(maximum: Int(min(UInt64(Self.bufferSize), remaining)))
            if count == 0 { break }
            total += UInt64(count)
        }
        return (digest(), total)
    }
}
