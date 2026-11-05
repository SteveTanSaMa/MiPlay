import Foundation

/// Connects optimistic settings edits to the next launch. Registration happens
/// synchronously on MainActor before a Toggle setter returns; launch readers
/// wait only for this exact store/game's queued writes.
@MainActor
enum LSFGSettingsPersistence {
    private struct Key: Hashable {
        let store: ObjectIdentifier
        let gameID: String
    }

    private struct Pending {
        // Retain identity until completion, even for operations that do not
        // themselves capture the store. ObjectIdentifier must not be reused.
        let store: PersistenceStore
        let revision: UUID
        let task: Task<Void, Never>
    }

    private static var pending: [Key: Pending] = [:]

    @discardableResult
    static func enqueue(
        store: PersistenceStore,
        gameID: String,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let key = Key(store: ObjectIdentifier(store), gameID: gameID)
        let predecessor = pending[key]?.task
        let revision = UUID()
        let task = Task {
            await predecessor?.value
            await operation()
            if pending[key]?.revision == revision { pending.removeValue(forKey: key) }
        }
        pending[key] = Pending(store: store, revision: revision, task: task)
        return task
    }

    static func flush(store: PersistenceStore, gameID: String) async {
        let key = Key(store: ObjectIdentifier(store), gameID: gameID)
        // An edit can arrive while awaiting a previous write. Continue through
        // the latest request instead of reading an intermediate persisted value.
        while let task = pending[key]?.task { await task.value }
    }
}
