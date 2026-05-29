import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

// MARK: - Minimal types

struct Payload: Codable, Equatable, Sendable {
    var label: String
    var events: [String]
}

struct Session: Codable, Equatable, Sendable {
    var label: String
}

// MARK: - Two @Shared keys: one .inMemory, one .fileStorage

extension SharedReaderKey where Self == InMemoryKey<Session?>.Default {
    static var session: Self { Self[.inMemory("repro.session"), default: nil] }
}
extension SharedReaderKey where Self == FileStorageKey<[Payload]>.Default {
    static var queue: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "repro-queue.json")), default: []]
    }
}

// MARK: - Client
//
// A `static let live` value whose closures each declare `@Shared` inside
// their bodies. Mirrors a TCA-style dependency-client live impl.

struct Client: Sendable {
    var startSession: @Sendable (String) -> Void
    var record: @Sendable (String) -> Void
    var finalize: @Sendable () async -> Payload?

    static let live = Client(
        startSession: { label in
            @Shared(.session) var session
            @Shared(.queue) var queue
            $session.withLock { $0 = Session(label: label) }
            $queue.withLock { $0.append(Payload(label: label, events: ["started"])) }
        },
        record: { event in
            @Shared(.session) var session
            guard let s = session else {
                Issue.record("record fired with nil session")
                return
            }
            @Shared(.queue) var queue
            $queue.withLock { q in
                guard let tail = q.indices.last else {
                    Issue.record("record fired but queue is empty (session=\(s.label))")
                    return
                }
                guard q[tail].label == s.label else {
                    Issue.record("record fired but queue tail label=\(q[tail].label) ≠ session.label=\(s.label)")
                    return
                }
                q[tail].events.append(event)
            }
        },
        finalize: {
            @Shared(.session) var session
            @Shared(.queue) var queue
            guard let s = session else { return nil }
            return $queue.withLock { q -> Payload? in
                guard let tail = q.indices.last, q[tail].label == s.label else { return nil }
                q[tail].events.append("completed")
                return q.remove(at: tail)
            }
        }
    )
}

// MARK: - Base suite + nested groups
//
// Layout matches the swift-dependencies Testing docs:
//   @Suite(.dependencies) struct BaseSuite {}
//   extension BaseSuite { @Suite struct Group { @Test ... } }

@Suite(.dependencies) struct BaseSuite {}

extension BaseSuite {
    @Suite struct GA { @Test func a01() async { await drive("a01") }; @Test func a02() async { await drive("a02") }; @Test func a03() async { await drive("a03") }; @Test func a04() async { await drive("a04") }; @Test func a05() async { await drive("a05") }; @Test func a06() async { await drive("a06") }; @Test func a07() async { await drive("a07") }; @Test func a08() async { await drive("a08") }; @Test func a09() async { await drive("a09") }; @Test func a10() async { await drive("a10") } }
    @Suite struct GB { @Test func b01() async { await drive("b01") }; @Test func b02() async { await drive("b02") }; @Test func b03() async { await drive("b03") }; @Test func b04() async { await drive("b04") }; @Test func b05() async { await drive("b05") }; @Test func b06() async { await drive("b06") }; @Test func b07() async { await drive("b07") }; @Test func b08() async { await drive("b08") }; @Test func b09() async { await drive("b09") }; @Test func b10() async { await drive("b10") } }
    @Suite struct GC { @Test func c01() async { await drive("c01") }; @Test func c02() async { await drive("c02") }; @Test func c03() async { await drive("c03") }; @Test func c04() async { await drive("c04") }; @Test func c05() async { await drive("c05") }; @Test func c06() async { await drive("c06") }; @Test func c07() async { await drive("c07") }; @Test func c08() async { await drive("c08") }; @Test func c09() async { await drive("c09") }; @Test func c10() async { await drive("c10") } }
    @Suite struct GD { @Test func d01() async { await drive("d01") }; @Test func d02() async { await drive("d02") }; @Test func d03() async { await drive("d03") }; @Test func d04() async { await drive("d04") }; @Test func d05() async { await drive("d05") }; @Test func d06() async { await drive("d06") }; @Test func d07() async { await drive("d07") }; @Test func d08() async { await drive("d08") }; @Test func d09() async { await drive("d09") }; @Test func d10() async { await drive("d10") } }
    @Suite struct GE { @Test func e01() async { await drive("e01") }; @Test func e02() async { await drive("e02") }; @Test func e03() async { await drive("e03") }; @Test func e04() async { await drive("e04") }; @Test func e05() async { await drive("e05") }; @Test func e06() async { await drive("e06") }; @Test func e07() async { await drive("e07") }; @Test func e08() async { await drive("e08") }; @Test func e09() async { await drive("e09") }; @Test func e10() async { await drive("e10") } }
    @Suite struct GF { @Test func f01() async { await drive("f01") }; @Test func f02() async { await drive("f02") }; @Test func f03() async { await drive("f03") }; @Test func f04() async { await drive("f04") }; @Test func f05() async { await drive("f05") }; @Test func f06() async { await drive("f06") }; @Test func f07() async { await drive("f07") }; @Test func f08() async { await drive("f08") }; @Test func f09() async { await drive("f09") }; @Test func f10() async { await drive("f10") } }
}

/// Each test follows the same shape: a `withDependencies` wrapper (with no
/// overrides — it's just here to mirror real-world test bodies that inject
/// a mock client), then drive `Client.live` through startSession → record →
/// record → finalize, then assert the result payload contains only THIS
/// test's writes.
///
/// Per swift-sharing's per-`@Test` isolation guarantee, every assertion
/// should succeed in every test, every run. Empirically, a small
/// percentage of runs see one or more failures consistent with cross-test
/// `@Shared` bleed.
private func drive(_ label: String) async {
    await withDependencies { _ in } operation: {
        Client.live.startSession(label)
        Client.live.record("ev1")
        await Task.yield()
        Client.live.record("ev2")
        await Task.yield()
        let payload = await Client.live.finalize()
        #expect(payload?.label == label, "[\(label)] payload.label=\(String(describing: payload?.label))")
        #expect(payload?.events == ["started", "ev1", "ev2", "completed"], "[\(label)] events=\(payload?.events ?? [])")
    }
}
