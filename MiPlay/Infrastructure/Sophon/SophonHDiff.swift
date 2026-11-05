import Foundation

@_silgen_name("miplay_hdiff_apply")
nonisolated private func miplayHDiffApply(
    _ oldFD: Int32, _ diffFD: Int32, _ outputFD: Int32,
    _ offset: UInt64, _ length: UInt64, _ oldSize: UInt64, _ newSize: UInt64,
    _ cancelled: @convention(c) (UnsafeMutableRawPointer?) -> Int32,
    _ context: UnsafeMutableRawPointer?
) -> Int32

/// Low-level isolated HDIFF13 decoder. The output descriptor must refer to a
/// new, empty regular file. A failure can leave a partial output to discard.
/// Callers must verify source and output hashes and handle transactions before
/// considering any file ready for installation.
nonisolated enum SophonHDiff {
    enum Error: Swift.Error { case invalidOrUnsupportedPatch }

    private final class CancellationContext {
        let check: @Sendable () -> Bool
        var observed = false
        init(check: @escaping @Sendable () -> Bool) { self.check = check }
    }

    static func apply(oldFD: Int32, diffFD: Int32, outputFD: Int32,
                      offset: UInt64, length: UInt64,
                      oldSize: UInt64, newSize: UInt64,
                      isCancelled: @escaping @Sendable () -> Bool = { Task<Never, Never>.isCancelled }) throws {
        let context = CancellationContext(check: isCancelled)
        if isCancelled() { throw CancellationError() }
        let result = miplayHDiffApply(oldFD, diffFD, outputFD, offset, length, oldSize, newSize, { pointer in
            guard let pointer else { return 1 }
            let context = Unmanaged<CancellationContext>.fromOpaque(pointer).takeUnretainedValue()
            if context.check() { context.observed = true; return 1 }
            return 0
        }, Unmanaged.passUnretained(context).toOpaque())
        if context.observed || isCancelled() { throw CancellationError() }
        if result < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: -result) ?? .EIO)
        }
        guard result == 1 else {
            throw Error.invalidOrUnsupportedPatch
        }
    }
}
