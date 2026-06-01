import DependenciesTestSupport
import Foundation
import Sharing
import Testing

extension URL {
    fileprivate static let store = URL.temporaryDirectory.appending(component: "repro.json")
}

@Suite(.dependencies)
struct FileStorageDroppedWriteTests {
    /// Each `withLock` mutation of a `.fileStorage`-backed `@Shared` should persist
    /// to storage, so reloading from storage should reflect every write.
    ///
    /// On swift-sharing 2.8.0 the *second* consecutive write is silently dropped:
    /// after reloading, `items` is `[1]` instead of `[1, 2]`.
    @Test func consecutiveWritesArePersisted() async throws {
        @Shared(.fileStorage(.store)) var items = [Int]()

        $items.withLock { $0.append(1) }
        $items.withLock { $0.append(2) }

        // Reload from storage to observe what was actually persisted.
        try await $items.load()

        #expect(items == [1, 2])
    }
}
