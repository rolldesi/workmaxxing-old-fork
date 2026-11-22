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

    @Test("No limit is applied unless one is configured")
    func unlimitedByDefault() throws {
        let store = AgentMessageStore(fileURL: nil)
        for _ in 0..<50 { _ = try send(store, from: "a", to: "b") }
    }
}
