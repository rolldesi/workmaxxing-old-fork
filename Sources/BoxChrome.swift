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

/// The box a triple-click enlarged.
struct EnlargedBox {
    let paneId: PaneID
    let panelId: UUID
}

extension Workspace {
    /// Paints every terminal box in this workspace. Idempotent; call after any
    /// agent state, color or message-cap change, and when a box is bound.
    func refreshBoxChrome() {
        let capped = AgentMessageCenter.store.cappedSurfaceIds()
        for case let panel as TerminalPanel in panels.values {
            let state = agentHibernationLifecycleState(panelId: panel.id, fallback: nil)
            // Red and green stay until the user clicks the box; blue stays while it works.
            if state == .running || state == .backgroundWorkPending {
                trafficLightSeen[panel.id] = nil
                agentWorkedPanels.insert(panel.id)
            }
            // A fresh agent that has not worked yet is idle, not complete.
            let hidden = trafficLightSeen[panel.id] == state || (state == .idle && !agentWorkedPanels.contains(panel.id))
            let light = hidden ? nil : BoxChrome.trafficLightColor(state)
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

    /// Every click inside a terminal box (see GhosttyNSView.mouseDown): clears
    /// its red or green light, and a triple-click enlarges it.
    static func boxClicked(panelId: UUID, clickCount: Int) {
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: panelId)?.workspace else { return }
        workspace.acknowledgeTrafficLight(panelId: panelId)
        guard clickCount == 3 else { return }
        // After the click's own focus change settles.
        DispatchQueue.main.async { _ = workspace.toggleBoxEnlarge(panelId: panelId) }
    }

    /// Grows the box to ~70% of the workspace in both directions, shrinking
    /// the rest; doing it again, or focusing another box, restores it.
    func toggleBoxEnlarge(panelId: UUID) -> Bool {
        let previous = enlargedBox
        if previous?.panelId == panelId {
            restoreEnlargedBox()
            return true
        }
        guard let paneId = paneId(forPanelId: panelId),
              let path = Self.splitPath(bonsplitController.treeSnapshot(), to: paneId.id.uuidString),
              !path.isEmpty else {
            restoreEnlargedBox()
            return true
        }
        let depthByOrientation = Dictionary(grouping: path, by: { $0.split.orientation }).mapValues(\.count)
        // Start from the normal layout: any other enlarged or still-restoring
        // splits go back to their originals in the same motion.
        var targets = boxOriginalPositions
        for (split, targetIsFirst) in path {
            guard let splitId = UUID(uuidString: split.id) else { continue }
            if boxOriginalPositions[splitId] == nil { boxOriginalPositions[splitId] = split.dividerPosition }
            // Each split on the way shares the growth, so nested splits of one
            // orientation multiply out to the target share.
            let share = pow(Self.enlargedShare, 1 / Double(depthByOrientation[split.orientation] ?? 1))
            targets[splitId] = targetIsFirst ? share : 1 - share
        }
        enlargedBox = EnlargedBox(paneId: paneId, panelId: panelId)
        animateDividers(to: targets)
        return true
    }

    /// Springs the dividers back to the normal layout. Splits closed meanwhile are skipped.
    func restoreEnlargedBox() {
        guard enlargedBox != nil else { return }
        enlargedBox = nil
        animateDividers(to: boxOriginalPositions)
    }

    /// Moves dividers to their targets along a slightly bouncy spring.
    private func animateDividers(to targets: [UUID: Double]) {
        boxEnlargeAnimation?.invalidate()
        var starts: [UUID: Double] = [:]
        Self.collectDividerPositions(bonsplitController.treeSnapshot(), into: &starts)
        let begin = CACurrentMediaTime()
        let duration = 0.45
        boxEnlargeAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, (CACurrentMediaTime() - begin) / duration)
                // Damped spring: ~5% overshoot, settled by t = 1.
                let progress = t >= 1 ? 1 : 1 - exp(-7 * t) * cos(9 * t)
                for (splitId, target) in targets {
                    let from = starts[splitId] ?? target
                    _ = self.bonsplitController.setDividerPosition(
                        CGFloat(from + (target - from) * progress),
                        forSplit: splitId,
                        fromExternal: true
                    )
                }
                guard t >= 1 else { return }
                timer.invalidate()
                self.boxEnlargeAnimation = nil
                // The normal layout is reached; forget it until the next enlarge.
                if self.enlargedBox == nil { self.boxOriginalPositions = [:] }
                self.didProgrammaticallyChangeSplitGeometry()
            }
        }
    }

    private static func collectDividerPositions(_ node: ExternalTreeNode, into positions: inout [UUID: Double]) {
        guard case .split(let split) = node else { return }
        if let id = UUID(uuidString: split.id) { positions[id] = split.dividerPosition }
        collectDividerPositions(split.first, into: &positions)
        collectDividerPositions(split.second, into: &positions)
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
