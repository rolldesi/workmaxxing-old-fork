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
        let appearance = bonsplitController.configuration.appearance
        let buttonCount = appearance.showSplitButtons ? appearance.splitButtons.count : 0
        // The tab bar's action-button lane as drawn: ~17.5pt per button plus padding.
        // ponytail: measured, not read from Bonsplit; re-measure if its button metrics change.
        let tabBarButtonsWidth = buttonCount == 0 ? 0 : 8 + CGFloat(buttonCount) * 17.5
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
            let surfaceId = panel.id.uuidString
            panel.hostedView.agentMessagesCapped = capped.contains(surfaceId)
            panel.hostedView.setAgentMessageAllowance(
                AgentMessageCenter.store.remainingAllowance(surfaceId: surfaceId),
                tabBarButtonsWidth: tabBarButtonsWidth
            )
            // In-process only, like the +10 built-in: agents can't raise their own cap.
            panel.hostedView.onAgentAllowanceTap = {
                _ = AgentMessageCenter.store.raisePairLimits(
                    involving: surfaceId,
                    by: AgentMessageCenter.pairMessageLimitStep
                )
            }
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

    /// Glides dividers to their targets, one step per display refresh.
    private func animateDividers(to targets: [UUID: Double]) {
        if let running = boxEnlargeAnimation {
            running.stop()
            splitTabBarDividerDragDidEnd(bonsplitController)
        }
        var starts: [UUID: Double] = [:]
        Self.collectDividerPositions(bonsplitController.treeSnapshot(), into: &starts)
        let apply: @MainActor (Double) -> Void = { [weak self] progress in
            guard let self else { return }
            for (splitId, target) in targets {
                let from = starts[splitId] ?? target
                _ = self.bonsplitController.setDividerPosition(
                    CGFloat(from + (target - from) * progress),
                    forSplit: splitId,
                    fromExternal: true
                )
            }
        }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.boxEnlargeAnimation = nil
            // The normal layout is reached; forget it until the next enlarge.
            if self.enlargedBox == nil { self.boxOriginalPositions = [:] }
            self.didProgrammaticallyChangeSplitGeometry()
        }
        guard let view = panels.values.lazy
            .compactMap({ ($0 as? TerminalPanel)?.hostedView })
            .first(where: { $0.window != nil }) else {
            apply(1)
            finish()
            return
        }
        // Terminals resize as they do while a divider is dragged, which keeps
        // the motion smooth, then settle once at the end.
        splitTabBarDividerDragDidBegin(bonsplitController)
        let begin = CACurrentMediaTime()
        let duration = 0.5
        boxEnlargeAnimation = BoxAnimationTicker(view: view) { [weak self] in
            let t = CACurrentMediaTime() - begin
            guard t < duration else {
                apply(1)
                if let self { self.splitTabBarDividerDragDidEnd(self.bonsplitController) }
                finish()
                return true
            }
            // Critically damped spring: eases in and out with no overshoot,
            // so each box only grows or shrinks, never bounces back.
            let stiffness = 14.0
            apply(1 - (1 + stiffness * t) * exp(-stiffness * t))
            return false
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

/// Calls `onFrame` once per display refresh of the view's screen until it returns true.
@MainActor
final class BoxAnimationTicker: NSObject {
    private var link: CADisplayLink?
    private let onFrame: @MainActor () -> Bool

    init(view: NSView, onFrame: @escaping @MainActor () -> Bool) {
        self.onFrame = onFrame
        super.init()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        if onFrame() { stop() }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

/// A box's "N+" agent-message counter, drawn over its tab bar (see
/// GhosttySurfaceScrollView.positionAgentAllowanceButton). The terminal portal
/// lets this type take clicks in the tab-bar strip it otherwise passes through.
final class AgentAllowanceTabBarButton: NSButton {}
