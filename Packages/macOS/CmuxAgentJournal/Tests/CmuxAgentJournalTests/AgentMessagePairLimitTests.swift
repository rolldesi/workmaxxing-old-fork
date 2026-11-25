import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite("Agent message pair limit")
struct AgentMessagePairLimitTests {
    private func send(
        _ store: AgentMessageStore,
        from sender: String?,
        to recipient: String,
        inReplyTo: String? = nil
    ) throws -> AgentMessage {
        try store.append(AgentMessageDraft(
            senderName: sender ?? "human",
            senderSurfaceId: sender,
            recipientSurfaceId: recipient,
            body: "hi",
            inReplyTo: inReplyTo
        ))
    }

    private let limitHit = AgentMessageBlockedError(
        block: .pairLimitReached(surfaceIds: ["a", "b"], limit: 3)
    )

    @Test("Messages both ways count toward one pair limit, and the refused one is not stored")
    func refusesPastLimit() throws {
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 3)
        let first = try send(store, from: "a", to: "b")
        _ = try send(store, from: "b", to: "a", inReplyTo: first.id)
        _ = try send(store, from: "a", to: "b")
        #expect(throws: limitHit) { try send(store, from: "b", to: "a") }
        #expect(store.messages(surfaceId: nil, states: nil, limit: 100).count == 3)
    }

    @Test("A fresh thread between the same pair still counts")
    func freshThreadCounts() throws {
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 3)
        for _ in 0..<3 { _ = try send(store, from: "a", to: "b") }
        #expect(throws: limitHit) { try send(store, from: "a", to: "b") }
    }

    @Test("Messages with no sender surface and other pairs are not limited")
    func onlyAgentPairsCount() throws {
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 3)
        for _ in 0..<3 { _ = try send(store, from: "a", to: "b") }
        for _ in 0..<5 { _ = try send(store, from: nil, to: "b") }
        for _ in 0..<3 { _ = try send(store, from: "a", to: "c") }
    }

    @Test("Raising the limit allows that many more, for that pair only")
    func raiseAllowsMore() throws {
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 3)
        for _ in 0..<3 { _ = try send(store, from: "a", to: "b") }
        store.raisePairLimit(surfaceId: "b", otherSurfaceId: "a", by: 2)
        _ = try send(store, from: "a", to: "b")
        _ = try send(store, from: "b", to: "a")
        #expect(throws: AgentMessageBlockedError(block: .pairLimitReached(surfaceIds: ["a", "b"], limit: 5))) {
            try send(store, from: "a", to: "b")
        }
    }

    @Test("Raising from one box raises every pair it is in, and no others")
    func raiseInvolvingSurface() throws {
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 1)
        _ = try send(store, from: "a", to: "b")
        _ = try send(store, from: "c", to: "a")
        _ = try send(store, from: "c", to: "d")
        #expect(store.raisePairLimits(involving: "a", by: 1) == 2)
        _ = try send(store, from: "b", to: "a")
        _ = try send(store, from: "a", to: "c")
        #expect(throws: AgentMessageBlockedError(block: .pairLimitReached(surfaceIds: ["c", "d"], limit: 1))) {
            try send(store, from: "d", to: "c")
        }
    }

    @Test("A human prompt in either agent starts the pair's count over")
    func humanPromptResets() throws {
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 3)
        for _ in 0..<3 { _ = try send(store, from: "a", to: "b") }
        _ = store.claimQueued(recipientSurfaceId: "b", via: "claude.wake")
        #expect(throws: limitHit) { try send(store, from: "a", to: "b") }
        _ = store.claimQueued(recipientSurfaceId: "b", via: "claude.prompt-submit")
        for _ in 0..<3 { _ = try send(store, from: "a", to: "b") }
        #expect(throws: limitHit) { try send(store, from: "a", to: "b") }
    }

    @Test("A refused pair is capped until a raise or a human prompt frees it, per pair")
    func cappedSurfaces() throws {
        let changes = Counter()
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 1, onPairLimitsChange: { changes.bump() })
        _ = try send(store, from: "a", to: "b")
        _ = try send(store, from: "a", to: "c")
        #expect(store.cappedSurfaceIds().isEmpty)
        #expect(throws: AgentMessageBlockedError.self) { try send(store, from: "b", to: "a") }
        #expect(throws: AgentMessageBlockedError.self) { try send(store, from: "c", to: "a") }
        #expect(store.cappedSurfaceIds() == ["a", "b", "c"])
        _ = store.claimQueued(recipientSurfaceId: "b", via: "claude.prompt-submit")
        #expect(store.cappedSurfaceIds() == ["a", "c"])
        store.raisePairLimit(surfaceId: "c", otherSurfaceId: "a", by: 1)
        #expect(store.cappedSurfaceIds().isEmpty)
        // Two sends, two refusals, the reset and the raise each report.
        #expect(changes.value == 6)
    }

    @Test("Each box counts down its tightest pair, and a raise adds to it")
    func remainingAllowance() throws {
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 10)
        #expect(store.remainingAllowance(surfaceId: "a") == 10)
        for _ in 0..<2 { _ = try send(store, from: "a", to: "b") }
        for _ in 0..<5 { _ = try send(store, from: "a", to: "c") }
        #expect(store.remainingAllowance(surfaceId: "a") == 5)
        #expect(store.remainingAllowance(surfaceId: "b") == 8)
        store.raisePairLimits(involving: "a", by: 10)
        #expect(store.remainingAllowance(surfaceId: "a") == 15)
        _ = store.claimQueued(recipientSurfaceId: "a", via: "claude.prompt-submit")
        #expect(store.remainingAllowance(surfaceId: "a") == 10)
    }

    @Test("A raise before any messages carries into the box's pairs")
    func raiseBeforeMessages() throws {
        let store = AgentMessageStore(fileURL: nil, pairMessageLimit: 2)
        #expect(store.raisePairLimits(involving: "a", by: 3) == 1)
        #expect(store.remainingAllowance(surfaceId: "a") == 5)
        for _ in 0..<5 { _ = try send(store, from: "a", to: "b") }
        #expect(throws: AgentMessageBlockedError(block: .pairLimitReached(surfaceIds: ["a", "b"], limit: 5))) {
            try send(store, from: "b", to: "a")
        }
        // Other boxes keep the plain limit.
        #expect(store.remainingAllowance(surfaceId: "c") == 2)
    }

    @Test("No limit is applied unless one is configured")
    func unlimitedByDefault() throws {
        let store = AgentMessageStore(fileURL: nil)
        for _ in 0..<50 { _ = try send(store, from: "a", to: "b") }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
