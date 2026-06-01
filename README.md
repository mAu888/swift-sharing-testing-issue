# swift-sharing: `.fileStorage` drops consecutive writes

A `.fileStorage`-backed `@Shared` silently **drops the second of two consecutive
`withLock` writes** when the storage uses a synchronous (immediate) scheduler —
which is the default in tests. The in-memory value looks correct, but nothing
after the first write is persisted, so any reload (or a freshly created `@Shared`
reading the same file) sees stale data.

Reproduced on **swift-sharing 2.8.0**.

## Reproduce

```sh
swift test
```

[`Tests/SharedIsolationReproTests/FileStorageDroppedWriteTests.swift`](Tests/SharedIsolationReproTests/FileStorageDroppedWriteTests.swift):

```swift
@Suite(.dependencies)
struct FileStorageDroppedWriteTests {
    @Test func consecutiveWritesArePersisted() async throws {
        @Shared(.fileStorage(.store)) var items = [Int]()

        $items.withLock { $0.append(1) }
        $items.withLock { $0.append(2) }

        try await $items.load()   // reload from storage

        #expect(items == [1, 2])  // ❌ 2.8.0: items == [1]
    }
}
```

It is **deterministic** — it fails on every run:

```
Expectation failed: (items → [1]) == [1, 2]
```

## Root cause

`FileStorageKey.save(_:context:continuation:)` debounces `.didSet` writes. On the
first save it writes immediately and arms a `DispatchWorkItem`, **scheduling it
from inside `state.withValue { … }`**:

```swift
try state.withValue { state in
  …
  state.workItem = workItem
  storage.asyncAfter(.seconds(1), workItem)   // scheduled while still holding the lock
}
```

In tests `defaultFileStorage` is `.inMemory`, whose scheduler runs the work item
**synchronously and re-entrantly**. And `ConcurrencyExtras.LockIsolated.withValue`
is copy-and-write-back:

```swift
var value = self._value
defer { self._value = value }   // restores the outer copy on exit
return try operation(&value)
```

So the re-entrant work item's `state.workItem = nil` is **clobbered** by the
outer scope's write-back. `state.workItem` then stays non-nil forever (the
one-shot work item has already run), so every later `.didSet` save takes the
buffering branch — it stores into `state.value` and never writes to storage.

Production (`.fileSystem` → `DispatchQueue.main`) is unaffected: there the work
item is genuinely deferred and runs *outside* the lock.

## Proposed fix

Schedule the work item **outside** `state.withValue`, so it can't run
re-entrantly under the lock (and nothing clobbers the `state.workItem = nil`
reset):

```diff
-        try state.withValue { state in
+        let workItem = try state.withValue { state -> DispatchWorkItem? in
           let data = try encode(value)
           switch context {
           case .didSet:
-            if state.workItem == nil {
-              try save(data: data, url: url, modificationDates: &state.modificationDates)
-              continuation.resume()
-              let workItem = DispatchWorkItem { /* … */ }
-              state.workItem = workItem
-              storage.asyncAfter(.seconds(1), workItem)
-            } else {
+            guard state.workItem == nil else {
               state.value = value
               state.continuations.append(continuation)
+              return nil
             }
+            try save(data: data, url: url, modificationDates: &state.modificationDates)
+            continuation.resume()
+            let workItem = DispatchWorkItem { /* … */ }
+            state.workItem = workItem
+            return workItem
           case .userInitiated:
             state.cancelWorkItem()
             try storage.save(data, url)
             continuation.resume()
+            return nil
           }
         }
+        if let workItem {
+          storage.asyncAfter(.seconds(1), workItem)
+        }
```

Deferred (production) behavior is unchanged; the immediate scheduler now persists
every write.

- **Fix branch:** [`mAu888/swift-sharing@fix/filestoragekey-immediate-scheduler-dropped-writes`](https://github.com/mAu888/swift-sharing/tree/fix/filestoragekey-immediate-scheduler-dropped-writes)
- **PR:** https://github.com/pointfreeco/swift-sharing/pull/213
- **This repo against the fix:** the [`with-fix`](https://github.com/mAu888/swift-sharing-testing-issue/tree/with-fix) branch points its dependency at the fix — `swift test` passes there.

## How this originally surfaced

This was first hit as flaky `@Shared` "bleed" across parallel `@Test`s: a
dependency-client whose `@Shared` is declared inside its closures recreates the
reference around each `await`, so when a reference deinits before reuse the lost
write surfaces as *another* test's data. That symptom is real but
timing-dependent and noisy — the deterministic test above isolates the same root
cause with no concurrency. (The original parallel reproduction is in this repo's
git history.)

## Versions

- swift-sharing 2.8.0
- Swift 6 / Xcode 26.5
