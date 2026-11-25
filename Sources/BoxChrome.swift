import AppKit
import Bonsplit
import CmuxFoundation

/// What a terminal box draws over its edges: the agent traffic light, the
/// user's outline and tint colors. Applied by ``Workspace/refreshBoxChrome()``.
struct BoxChrome: Equatable {
    var trafficLight: NSColor?
    var outline: NSColor?
    var tint: NSColor?

    /// Blue while the agent works, red when it stopped for the user, green when done.
    static func trafficLightColor(_ state: AgentHibernationLifecycleState) -> NSColor? {
        switch state {
        case .running, .backgroundWorkPending: return .systemBlue
        case .needsInput: return .systemRed
        case .idle: return .systemGreen
        case .unknown: return nil
        }
    }
}

/// Per-box colors the user picked, keyed by panel id (stable across restarts).
// ponytail: entries for closed boxes are never pruned; prune on panel close if this grows.
enum BoxColorStore {
    enum Kind: String {
        case tint = "cmuxFork.boxTintColors"
        case outline = "cmuxFork.boxOutlineColors"
    }

    static func color(_ kind: Kind, panelId: UUID) -> NSColor? {
        (UserDefaults.standard.dictionary(forKey: kind.rawValue)?[panelId.uuidString] as? String)
            .flatMap { NSColor(hex: $0) }
    }

    static func setColor(_ color: NSColor?, _ kind: Kind, panelId: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: kind.rawValue) ?? [:]
        all[panelId.uuidString] = color?.usingColorSpace(.sRGB)?.hexString()
        UserDefaults.standard.set(all, forKey: kind.rawValue)
    }
}

/// The box enlarged by a tab double-click and the divider positions it replaced.
struct EnlargedBox {
    let paneId: PaneID
    let panelId: UUID
    let savedPositions: [UUID: Double]
}

extension Workspace {
    /// Paints every terminal box in this workspace. Idempotent; call after any
    /// agent state, color or message-cap change, and when a box is bound.
    func refreshBoxChrome() {
        let capped = AgentMessageCenter.store.cappedSurfaceIds()
        for case let panel as TerminalPanel in panels.values {
            let state = agentHibernationLifecycleState(panelId: panel.id, fallback: nil)
            // Red and green stay until the user clicks the box; blue stays while it works.
            if state != .needsInput && state != .idle { trafficLightSeen[panel.id] = nil }
            let light = trafficLightSeen[panel.id] == state ? nil : BoxChrome.trafficLightColor(state)
            panel.hostedView.setBoxChrome(BoxChrome(
                trafficLight: light,
                outline: BoxColorStore.color(.outline, panelId: panel.id),
                tint: BoxColorStore.color(.tint, panelId: panel.id)
            ))
            panel.hostedView.agentMessagesCapped = capped.contains(panel.id.uuidString)
        }
    }

    /// Clears a box's red or green light once the user clicks it.
    func acknowledgeTrafficLight(panelId: UUID) {
        let state = agentHibernationLifecycleState(panelId: panelId, fallback: nil)
        guard state == .needsInput || state == .idle, trafficLightSeen[panelId] != state else { return }
        trafficLightSeen[panelId] = state
        refreshBoxChrome()
    }

    // MARK: Enlarge on double-click

    /// Share of the workspace's width and height the enlarged box takes.
    private static let enlargedShare = 0.7

    /// Grows the box to ~70% of the workspace in both directions, shrinking
    /// the rest; a second double-click, or focusing another box, restores it.
    func toggleBoxEnlarge(panelId: UUID) -> Bool {
        if let enlarged = enlargedBox {
            restoreEnlargedBox()
            if enlarged.panelId == panelId { return true }
        }
        guard let paneId = paneId(forPanelId: panelId),
              let path = Self.splitPath(bonsplitController.treeSnapshot(), to: paneId.id.uuidString),
              !path.isEmpty else { return true }
        let depthByOrientation = Dictionary(grouping: path, by: { $0.split.orientation }).mapValues(\.count)
        var saved: [UUID: Double] = [:]
        for (split, targetIsFirst) in path {
            guard let splitId = UUID(uuidString: split.id) else { continue }
            // Each split on the way shares the growth, so nested splits of one
            // orientation multiply out to the target share.
            let share = pow(Self.enlargedShare, 1 / Double(depthByOrientation[split.orientation] ?? 1))
            saved[splitId] = split.dividerPosition
            _ = bonsplitController.setDividerPosition(
                CGFloat(targetIsFirst ? share : 1 - share),
                forSplit: splitId,
                fromExternal: true
            )
        }
        enlargedBox = EnlargedBox(paneId: paneId, panelId: panelId, savedPositions: saved)
        didProgrammaticallyChangeSplitGeometry()
        return true
    }

    /// Puts the dividers back. Splits closed meanwhile are skipped.
    func restoreEnlargedBox() {
        guard let enlarged = enlargedBox else { return }
        enlargedBox = nil
        for (splitId, position) in enlarged.savedPositions {
            _ = bonsplitController.setDividerPosition(CGFloat(position), forSplit: splitId, fromExternal: true)
        }
        didProgrammaticallyChangeSplitGeometry()
    }

    func restoreEnlargedBoxIfFocusLeft(toPane pane: PaneID) {
        guard let enlarged = enlargedBox, enlarged.paneId != pane else { return }
        restoreEnlargedBox()
    }

    /// Splits from the root down to the pane, each with whether the pane is in its first child.
    private static func splitPath(
        _ node: ExternalTreeNode,
        to paneId: String
    ) -> [(split: ExternalSplitNode, targetIsFirst: Bool)]? {
        switch node {
        case .pane(let pane):
            return pane.id.caseInsensitiveCompare(paneId) == .orderedSame ? [] : nil
        case .split(let split):
            if let rest = splitPath(split.first, to: paneId) { return [(split, true)] + rest }
            if let rest = splitPath(split.second, to: paneId) { return [(split, false)] + rest }
            return nil
        }
    }
}
