# swift-sharing per-`@Test` isolation — bleed under parallel load

> **Root cause identified.** Despite *looking* like cross-`@Test` `@Shared`
> bleed, per-test isolation is actually intact. The real bug is a **within-test
> dropped write** in `FileStorageKey`'s debounce, triggered by the in-memory
> test storage's `.immediate` scheduler. See [**Root cause**](#root-cause) and
> [**Proposed fix**](#proposed-fix) below. A [`with-fix`](https://github.com/mAu888/swift-sharing-testing-issue/tree/with-fix)
> branch of this repo points at the patched library and passes.

## Symptom

Under the `@Suite(.dependencies) struct BaseSuite {}` + nested `@Suite` layout
recommended in [swift-dependencies' Testing
docs](https://swiftpackageindex.com/pointfreeco/swift-dependencies/main/documentation/dependencies/testing#Swifts-native-Testing-framework),
parallel `@Test` cases that read and write the same `@Shared` keys
occasionally see *another test's writes* — the per-`@Test` storage
isolation that swift-sharing documents is not fully holding.

## Repro

```sh
git clone <this repo> && cd shared-isolation-repro
for i in $(seq 1 100); do swift test 2>&1 | grep -E "✘|recorded an issue"; done
```

Roughly **3% of runs** show one or two failing tests, with a payload like:

```
Expectation failed: (payload?.events → ["started", "ev2", "completed"])
                   == ["started", "ev1", "ev2", "completed"]
```

i.e. this test's `record("ev1")` call vanished — the queue tail it appended
to belonged to a *sibling* test at that moment, and the sibling
finalize-removed the entry before this test's finalize could see it.

The failure rate climbs with the size of the parallel test pool. The
real-world codebase that surfaced this — 23 `@Test`s touching three
`@Shared` keys via a TCA dependency-client live impl — fails ~1-3% per
test, ~4-18 failures per `xcodebuild test -test-iterations 20` (660 runs).

## Root cause

> **TL;DR** — On failing runs every test still has its **own** distinct
> `FileStorage`, `InMemoryStorage`, and `PersistentReferences` instance, so
> per-`@Test` isolation is holding. The vanished `ev1` is a write that was
> **dropped within a single test**: `FileStorageKey` debounces `.didSet` saves,
> and under the in-memory test storage's `.immediate` scheduler that debounce
> wedges itself so that every save after the first is buffered but never
> persisted.

### The mechanism

`FileStorageKey.save(_:context:continuation:)` debounces `.didSet` writes. On the
first save it writes immediately and arms a `DispatchWorkItem`, **scheduling it
from inside `state.withValue { … }`**:

```swift
try state.withValue { state in
  // …
  case .didSet:
    if state.workItem == nil {
      try save(data: data, url: url, modificationDates: &state.modificationDates)
      continuation.resume()
      let workItem = DispatchWorkItem { /* flush state.value, then state.workItem = nil */ }
      state.workItem = workItem
      storage.asyncAfter(.seconds(1), workItem)   // ← scheduled while still inside withValue
    } else {
      state.value = value                          // ← buffered; only the work item flushes it
      state.continuations.append(continuation)
    }
}
```

In tests `defaultFileStorage` resolves to `.inMemory`, whose scheduler is
`.immediate`, so `storage.asyncAfter` runs the work item **synchronously and
re-entrantly**, before the outer `withValue` returns. And
`ConcurrencyExtras.LockIsolated.withValue` is copy-and-write-back:

```swift
func withValue<T>(_ op: (inout Value) throws -> T) rethrows -> T {
  try lock.sync {
    var value = self._value
    defer { self._value = value }   // ← writes the OUTER copy back on exit
    return try op(&value)
  }
}
```

So the ordering is:

1. Outer `withValue` copies `_value` → `value_outer` (with `workItem == nil`).
2. It sets `value_outer.workItem = workItem`.
3. `storage.asyncAfter` runs the work item re-entrantly. Its own `state.withValue`
   reads the current `_value`, sets `workItem = nil`, writes that back →
   `_value.workItem == nil`. ✅
4. The outer `withValue` returns; its `defer { _value = value_outer }` restores
   `value_outer` → `_value.workItem == workItem` again. ❌ **clobbered.**

From here `state.workItem` is non-nil forever (the one-shot work item has already
run and won't run again), so every later `.didSet` save takes the `else` branch:
it buffers into `state.value` and **never writes to storage**.

### Why it looks like cross-test bleed

A long-lived `@Shared` hides the bug — its in-memory `value` stays correct, so
reads are fine even though storage is stale. But `Client.live` declares `@Shared`
**inside** its closures, so a fresh reference is created and released around each
call. Across an `await` the reference deinits, the buffered (never-persisted)
write is discarded, and the next `@Shared(.queue)` **reloads the stale value from
storage** — the missing `ev1`. It resembles a sibling test's write only because
every test starts its queue with the same `"started"` entry.

### Trace

Instrumenting the in-memory storage's save/load plus the backing reference
identity for one failing test makes it unambiguous:

```
start:    q=[e04:started]  ref=A
  didSet save: IMMEDIATE write           → SAVE [e04:started]
ev1 pre:  q=[e04:started]  ref=A         (same reference reused)
ev1 post: q=[e04:started+ev1]
  didSet save: DEFERRED (workItem != nil) → buffered, NOT written to storage
ev2 pre:  q=[e04:started]  ref=B         (reference recreated; reloads STALE [started])
ev2 post: q=[e04:started+ev2]
  didSet save: IMMEDIATE write           → SAVE [e04:started+ev2]
finalize: q=[e04:started+ev2]            → ev1 is gone
```

### Why each repro ingredient matters

- **`.fileStorage` key** — only this strategy debounces via the work item;
  `.inMemory`/`.appStorage` write synchronously and never wedge.
- **`@Shared` declared inside `static let` closures + `await` between calls** —
  produce the short-lived-reference churn so the dropped write actually matters
  (a long-lived reference would mask it).
- **`withDependencies { } operation:` wrapper** — keeps each step on the test's
  task while still letting the reference deinit between steps.
- **≥60 parallel `@Test`s** — the deinit-before-reuse timing is a race; CPU
  contention from many parallel tests is what makes it likely.

## Proposed fix

Schedule the work item **outside** `state.withValue`, so the immediate scheduler
can no longer run it re-entrantly under the lock (and thus nothing clobbers the
`state.workItem = nil` reset):

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

Deferred (production `DispatchQueue.main`) behavior is unchanged; the immediate
scheduler now persists every write. With the fix this repro passes **200/200**
runs, and `swift-sharing`'s own suite stays green.

- **Fix branch:** [`mAu888/swift-sharing@fix/filestoragekey-immediate-scheduler-dropped-writes`](https://github.com/mAu888/swift-sharing/tree/fix/filestoragekey-immediate-scheduler-dropped-writes)
- **This repo against the fix:** the [`with-fix`](https://github.com/mAu888/swift-sharing-testing-issue/tree/with-fix) branch points its dependency at the fix and passes.

## What's required to reproduce (minimal trigger set)

The bleed reproduces with the smallest combination of:

1. **A `@Suite(.dependencies)` base suite** + nested `@Suite` types
   declared in extensions.
2. **At least one `.fileStorage(url)` key.** Replacing it with `.inMemory`
   makes the bleed disappear, even with 60+ parallel tests.
3. **At least one `.inMemory` key** read alongside the `.fileStorage` key
   (used here to gate writes — the `session` guard before `queue` mutation).
4. **A `static let live` value with closures that declare `@Shared` inside
   their bodies.** Inlining the same logic directly into the test body
   makes the bleed disappear. Capturing the closure values in a value-type
   struct (mirroring TCA's `@DependencyClient` pattern) is required.
5. **`withDependencies { _ in } operation: { ... }`** wrapping the test
   body — even with *no* dependency overrides. Removing this wrapper makes
   the bleed disappear.
6. **`await` suspension points** between the `record` calls
   (`Task.yield()`). Without them: no bleed.
7. **≥60 `@Test` cases** running in parallel. At 30 tests the rate drops
   below my measurement floor.

Each ingredient is necessary; remove any one and the failure rate
collapses to zero in 50-100 iterations.

## What's NOT required

- Real network / async work — `Task.yield()` is enough.
- A `@DependencyClient` macro — a hand-written `struct` works.
- A `Codable` payload — using `String` works too (just easier to read in
  failures with the `Payload { label; events }` shape).
- Multiple `withLock` writes per key per test — one `startSession` write,
  one `record` write, one `finalize` remove is the minimum that bleeds.

## What we tried in the original codebase and ruled out

- **Refactoring `liveValue` to not capture `@Dependency` at static-let
  init.** No change in flake rate.
- **Suite-level `.dependencies` vs per-`@Test` `.dependencies`.** Per-test
  was *worse* (27 failures vs 8 per 660 runs).
- **Probe with a single `.inMemory` key**: 0 / 740 fails.
- **Probe with a single `.fileStorage` key**: 0 / 80 fails.

## Workaround

```swift
@Suite(.serialized, .dependencies { ... })
@MainActor
struct BaseSuite {}
```

Both `.serialized` and `@MainActor` together, applied to *every* nested
`@Suite` (`.serialized` on the parent doesn't propagate to nested suites
declared in `extension`s). With this configuration the real-world suite
passes 660 / 660.

## Versions

- `swift-sharing` 2.8.0
- `swift-dependencies` 1.10.0
- Swift 6.0 (Xcode 16+), tested on macOS 14+ with `swift test`. Also
  reproduces on iOS Simulator under `xcodebuild test -test-iterations`.

## Related

- swift-sharing discussion #108 (parameterized-tests variant of the same
  underlying mechanism):
  https://github.com/pointfreeco/swift-sharing/discussions/108
