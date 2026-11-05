import Foundation
import Darwin

// Darwin also exports a `flock` structure for fcntl; bind the C function
// explicitly so Swift does not resolve the name to that structure.
@_silgen_name("flock")
nonisolated private func sophonFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Cooperating MiPlay processes lock the existing installation directory
/// itself. No lock file is created, overwritten, or removed, and the kernel
/// releases the advisory lock automatically when the process exits.
nonisolated public final class SophonDirectoryLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    private init(descriptor: Int32, device: dev_t, inode: ino_t) {
        self.descriptor = descriptor
        self.device = device
        self.inode = inode
    }

    internal static func acquire(at root: URL) throws -> SophonDirectoryLock {
        guard root.isFileURL else { throw SophonProtocolError.unsupported("游戏目录无效") }
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SophonProtocolError.unsupported("无法打开游戏目录以保护下载事务") }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, lstat(root.path, &named) == 0,
              opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            Darwin.close(fd)
            throw SophonProtocolError.corrupt("游戏目录已变化，无法安全开始下载")
        }
        guard sophonFlock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(fd)
            if failure == EWOULDBLOCK {
                throw SophonProtocolError.unsupported("此游戏目录正在被另一个 MiPlay 进程下载、更新或恢复，请等待其完成")
            }
            throw SophonProtocolError.unsupported("无法锁定游戏目录，请检查磁盘是否支持文件锁")
        }
        let token = SophonDirectoryLock(descriptor: fd, device: opened.st_dev, inode: opened.st_ino)
        do { try token.validate(at: root) }
        catch { token.release(); throw error }
        return token
    }

    internal func validate(at root: URL) throws {
        mutex.lock()
        defer { mutex.unlock() }
        var opened = stat(), named = stat()
        guard descriptor >= 0, fstat(descriptor, &opened) == 0, lstat(root.path, &named) == 0,
              opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == device, opened.st_ino == inode,
              named.st_dev == device, named.st_ino == inode else {
            throw SophonProtocolError.corrupt("游戏目录已变化或下载锁已释放，请重新开始")
        }
    }

    internal func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
