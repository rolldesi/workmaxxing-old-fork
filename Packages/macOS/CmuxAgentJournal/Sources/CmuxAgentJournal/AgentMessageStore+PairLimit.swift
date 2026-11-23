import Foundation

/// Caps how many messages two agent surfaces exchange on their own.
///
/// Every message with a sender surface counts toward its unordered
/// sender/recipient pair, whatever its thread, so starting a fresh thread
/// does not reset it. Messages with no sender surface (a person at a shell)
/// never count. The count starts over when a human submits a prompt in
/// either surface (the `*.prompt-submit` claim), and the app can raise one
/// pair's allowance from its UI.
// ponytail: an agent that forges a prompt-submit claim over the socket can
// reset its own pair; this guards against runaway loops, not hostile agents.
extension AgentMessageStore {
    /// Lets the pair exchange `by` more messages before it is stopped again.
    public func raisePairLimit(surfaceId: String, otherSurfaceId: String, by: Int) {
        let key = Self.pairKey(surfaceId, otherSurfaceId)
        lock.withLock { pairExtra[key, default: 0] += by }
    }

    /// Raises every pair `surfaceId` has messaged in, for the app's
    /// per-box "allow more" button. Returns how many pairs it raised.
    @discardableResult
    public func raisePairLimits(involving surfaceId: String, by: Int) -> Int {
        lock.withLock {
            let keys = pairKeysLocked(involving: surfaceId)
            for key in keys { pairExtra[key, default: 0] += by }
            return keys.count
        }
    }

    private func pairKeysLocked(involving surfaceId: String) -> [String] {
        pairSent.keys.filter { $0.split(separator: "|").contains { $0 == surfaceId } }
    }

    static func pairKey(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "|")
    }

    private func limitedPairKey(_ sender: String?, _ recipient: String) -> String? {
        guard pairMessageLimit != nil, let sender, sender != recipient else { return nil }
        return Self.pairKey(sender, recipient)
    }

    /// Must hold `lock`.
    func pairLimitBlockLocked(_ draft: AgentMessageDraft) -> AgentMessageBlock? {
        guard let limit = pairMessageLimit,
              let key = limitedPairKey(draft.senderSurfaceId, draft.recipientSurfaceId) else { return nil }
        let allowed = limit + pairExtra[key, default: 0]
        guard pairSent[key, default: 0] >= allowed else { return nil }
        return .pairLimitReached(surfaceIds: key.split(separator: "|").map(String.init), limit: allowed)
    }

    /// Must hold `lock`.
    func countPairLocked(_ message: AgentMessage) {
        guard let key = limitedPairKey(message.senderSurfaceId, message.recipientSurfaceId) else { return }
        pairSent[key, default: 0] += 1
    }

    /// Must hold `lock`.
    func resetPairsLocked(surfaceId: String) {
        for key in pairKeysLocked(involving: surfaceId) {
            pairSent[key] = nil
            pairExtra[key] = nil
        }
    }
}
