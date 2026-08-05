import Foundation

/// A thread-safe dictionary wrapper using NSLock.
/// Bypasses MainActor isolation via `@unchecked Sendable` + lock-based access.
final class LockedDictionary<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { lock.withLock { storage[key] } }
        set { lock.withLock { storage[key] = newValue } }
    }

    @discardableResult
    func removeValue(forKey key: Key) -> Value? {
        lock.withLock { storage.removeValue(forKey: key) }
    }

    var allValues: [Value] {
        lock.withLock { Array(storage.values) }
    }

    func removeAll() {
        lock.withLock { storage.removeAll() }
    }
}

/// Thread-safe store for active download tasks.
typealias ActiveTasksStore = LockedDictionary<URL, URLSessionDownloadTask>
