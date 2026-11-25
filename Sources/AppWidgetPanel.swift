import AppKit
import Bonsplit
import CmuxWorkspaces
import Combine
import SwiftUI

/// Saved state of an app tab (Spotify, sticky note, prompt queue).
struct SessionAppWidgetPanelSnapshot: Codable, Sendable {
    var kind: String
    var text: String?
    var prompts: [String]?
    var targetPanelId: UUID?
    var autoSend: Bool?
}

/// A small native app opened from a box's apps button, living as a tab.
@MainActor
final class AppWidgetPanel: Panel, ObservableObject {
    enum Kind: String, CaseIterable {
        case spotify
        case stickyNote
        case promptQueue

        var title: String {
            switch self {
            case .spotify: return String(localized: "appWidget.spotify.title", defaultValue: "Spotify")
            case .stickyNote: return String(localized: "appWidget.stickyNote.title", defaultValue: "Sticky Note")
            case .promptQueue: return String(localized: "appWidget.promptQueue.title", defaultValue: "Prompt Queue")
            }
        }

        var icon: String {
            switch self {
            case .spotify: return "music.note"
            case .stickyNote: return "note.text"
            case .promptQueue: return "list.bullet.rectangle"
            }
        }
    }

    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .appWidget
    let kind: Kind
    weak var workspace: Workspace?

    @Published var text: String
    @Published var prompts: [String]
    @Published var targetPanelId: UUID?
    @Published var autoSend: Bool
    /// Set after the queue sends a prompt; cleared once the agent starts on it,
    /// so one idle reading never sends twice.
    private var awaitingAgentStart = false
    private var queueTimer: Timer?

    var displayTitle: String { kind.title }
    var displayIcon: String? { kind.icon }

    init(id: UUID = UUID(), kind: Kind, workspace: Workspace, snapshot: SessionAppWidgetPanelSnapshot? = nil) {
        self.id = id
        self.kind = kind
        self.workspace = workspace
        text = snapshot?.text ?? ""
        prompts = snapshot?.prompts ?? []
        targetPanelId = snapshot?.targetPanelId
        autoSend = snapshot?.autoSend ?? false
        if kind == .promptQueue {
            queueTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoSendIfAgentDone() }
            }
        }
    }

    var snapshot: SessionAppWidgetPanelSnapshot {
        SessionAppWidgetPanelSnapshot(
            kind: kind.rawValue,
            text: kind == .stickyNote ? text : nil,
            prompts: kind == .promptQueue ? prompts : nil,
            targetPanelId: targetPanelId,
            autoSend: kind == .promptQueue ? autoSend : nil
        )
    }

    func close() {
        queueTimer?.invalidate()
        queueTimer = nil
    }

    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }

    // MARK: Prompt queue

    /// Terminal boxes in this workspace the queue can feed, by title.
    var targetChoices: [(id: UUID, title: String)] {
        guard let workspace else { return [] }
        return workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .map { ($0.id, workspace.panelTitles[$0.id] ?? $0.displayTitle) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func targetState() -> AgentHibernationLifecycleState? {
        guard let workspace, let targetPanelId else { return nil }
        return workspace.agentHibernationLifecycleState(panelId: targetPanelId, fallback: nil)
    }

    /// Types the next prompt into the target box and presses Return.
    func sendNext() {
        guard !prompts.isEmpty,
              let targetPanelId,
              let target = workspace?.terminalPanel(for: targetPanelId) else { return }
        let prompt = prompts.removeFirst()
        _ = target.sendText(prompt)
        if !target.sendNamedKey("return") { _ = target.sendText("\r") }
        awaitingAgentStart = true
    }

    /// Unattended sends only go to a box whose agent reported done, never to a
    /// bare shell, where the text would run as a command.
    private func autoSendIfAgentDone() {
        guard autoSend, !prompts.isEmpty, let state = targetState() else { return }
        if state != .idle {
            awaitingAgentStart = false
            return
        }
        guard !awaitingAgentStart else { return }
        sendNext()
    }
}

extension Workspace {
    @discardableResult
    func newAppWidgetSurface(
        inPane paneId: PaneID,
        kind: AppWidgetPanel.Kind,
        snapshot: SessionAppWidgetPanelSnapshot? = nil,
        focus: Bool? = nil
    ) -> AppWidgetPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let widget = AppWidgetPanel(kind: kind, workspace: self, snapshot: snapshot)
        panels[widget.id] = widget
        panelTitles[widget.id] = widget.displayTitle
        guard let newTabId = bonsplitController.createTab(
            title: widget.displayTitle,
            icon: widget.displayIcon,
            kind: SurfaceKind.appWidget.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: widget.id)
            panelTitles.removeValue(forKey: widget.id)
            widget.close()
            return nil
        }
        bindSurface(newTabId, toPanelId: widget.id)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }
        return widget
    }

    /// The apps button's menu: open an app tab in this pane, or style its box.
    func showAppsMenu(inPane paneId: PaneID) {
        let menu = NSMenu()
        for kind in AppWidgetPanel.Kind.allCases {
            menu.addItem(BoxMenuItem(title: kind.title, symbol: kind.icon) { [weak self] in
                self?.newAppWidgetSurface(inPane: paneId, kind: kind, focus: true)
            })
        }
        menu.addItem(BoxMenuItem(
            title: String(localized: "appWidget.markdown.title", defaultValue: "Markdown File…"),
            symbol: "doc.richtext"
        ) { [weak self] in
            let open = NSOpenPanel()
            open.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText, .plainText]
            open.allowsMultipleSelection = false
            guard open.runModal() == .OK, let url = open.url else { return }
            self?.newMarkdownSurface(inPane: paneId, filePath: url.path, focus: true)
        })

        let selectedPanelId = bonsplitController.selectedTab(inPane: paneId).flatMap { panelIdFromSurfaceId($0.id) }
        if let panelId = selectedPanelId, panels[panelId] is TerminalPanel {
            menu.addItem(.separator())
            menu.addItem(BoxMenuItem(
                title: String(localized: "boxChrome.enlarge", defaultValue: "Enlarge Box"),
                symbol: "arrow.up.left.and.arrow.down.right"
            ) { [weak self] in _ = self?.toggleBoxEnlarge(panelId: panelId) })
            menu.addItem(BoxMenuItem(
                title: String(localized: "boxChrome.tint", defaultValue: "Box Color…"),
                symbol: "paintpalette"
            ) { [weak self] in self.map { BoxColorPicker.show(.tint, panelId: panelId, workspace: $0) } })
            menu.addItem(BoxMenuItem(
                title: String(localized: "boxChrome.outline", defaultValue: "Outline Color…"),
                symbol: "square.dashed"
            ) { [weak self] in self.map { BoxColorPicker.show(.outline, panelId: panelId, workspace: $0) } })
            menu.addItem(BoxMenuItem(
                title: String(localized: "boxChrome.reset", defaultValue: "Reset Box Colors"),
                symbol: "arrow.uturn.backward"
            ) { [weak self] in
                BoxColorStore.setColor(nil, .tint, panelId: panelId)
                BoxColorStore.setColor(nil, .outline, panelId: panelId)
                self?.refreshBoxChrome()
            })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// An NSMenuItem that runs a closure.
final class BoxMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// Feeds the system color panel's picks into one box's saved color, live.
@MainActor
final class BoxColorPicker: NSObject {
    private static var current: BoxColorPicker?
    private let kind: BoxColorStore.Kind
    private let panelId: UUID
    private weak var workspace: Workspace?

    private init(kind: BoxColorStore.Kind, panelId: UUID, workspace: Workspace) {
        self.kind = kind
        self.panelId = panelId
        self.workspace = workspace
    }

    static func show(_ kind: BoxColorStore.Kind, panelId: UUID, workspace: Workspace) {
        let picker = BoxColorPicker(kind: kind, panelId: panelId, workspace: workspace)
        current = picker
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.color = BoxColorStore.color(kind, panelId: panelId) ?? (kind == .tint ? .systemBlue : .systemPink)
        panel.isContinuous = true
        panel.setTarget(picker)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        BoxColorStore.setColor(sender.color, kind, panelId: panelId)
        workspace?.refreshBoxChrome()
    }
}

// MARK: - Views

struct AppWidgetPanelView: View {
    @ObservedObject var panel: AppWidgetPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            switch panel.kind {
            case .spotify: SpotifyWidgetView()
            case .stickyNote: StickyNoteView(panel: panel)
            case .promptQueue: PromptQueueView(panel: panel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .simultaneousGesture(TapGesture().onEnded { if !isFocused { onRequestPanelFocus() } })
    }
}

private struct StickyNoteView: View {
    @ObservedObject var panel: AppWidgetPanel

    var body: some View {
        TextEditor(text: $panel.text)
            .font(.system(size: 15))
            .foregroundStyle(Color.black.opacity(0.85))
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(Color(red: 1, green: 0.92, blue: 0.55))
    }
}

private struct PromptQueueView: View {
    @ObservedObject var panel: AppWidgetPanel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(String(localized: "appWidget.promptQueue.target", defaultValue: "Send to"), selection: $panel.targetPanelId) {
                    Text(String(localized: "appWidget.promptQueue.noTarget", defaultValue: "Choose a box")).tag(UUID?.none)
                    ForEach(panel.targetChoices, id: \.id) { choice in
                        Text(choice.title).tag(Optional(choice.id))
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Circle()
                        .fill(Color(nsColor: panel.targetState().flatMap(BoxChrome.trafficLightColor) ?? .tertiaryLabelColor))
                        .frame(width: 10, height: 10)
                }
            }
            Toggle(String(localized: "appWidget.promptQueue.auto", defaultValue: "Send next automatically when the agent is done"), isOn: $panel.autoSend)
            HStack(alignment: .bottom) {
                TextField(String(localized: "appWidget.promptQueue.placeholder", defaultValue: "Queue a prompt…"), text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit(add)
                Button(String(localized: "appWidget.promptQueue.add", defaultValue: "Add"), action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(Array(panel.prompts.enumerated()), id: \.offset) { index, prompt in
                    HStack(alignment: .top) {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(prompt).lineLimit(3)
                        Spacer()
                        Button { panel.prompts.remove(at: index) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { panel.prompts.move(fromOffsets: $0, toOffset: $1) }
            }
            HStack {
                Text(String(format: String(localized: "appWidget.promptQueue.count", defaultValue: "%d queued"), panel.prompts.count))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "appWidget.promptQueue.sendNext", defaultValue: "Send Next"), action: panel.sendNext)
                    .disabled(panel.prompts.isEmpty || panel.targetPanelId == nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    private func add() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        panel.prompts.append(prompt)
        draft = ""
    }
}

// MARK: - Spotify

/// Reads and drives the Spotify app through AppleScript. Shared by every
/// Spotify tab; polls only while one is on screen.
@MainActor
final class SpotifyModel: ObservableObject {
    static let shared = SpotifyModel()

    enum Status { case notRunning, stopped, playing, paused }

    @Published private(set) var status: Status = .notRunning
    @Published private(set) var track = ""
    @Published private(set) var artist = ""
    @Published private(set) var artworkURL: URL?
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var positionReadAt = Date()
    @Published private(set) var lastError: String?

    private var viewers = 0
    private var refreshInFlight = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        refresh()
        // ponytail: 2s poll alongside Spotify's change notification; drop the poll
        // if the notification proves reliable.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { SpotifyModel.shared.refresh() }
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { SpotifyModel.shared.refresh() }
        }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    /// macOS refused to let cmux send Apple events to Spotify (error -1743).
    var needsPermission: Bool {
        guard let lastError else { return false }
        return lastError.contains("-1743") || lastError.localizedCaseInsensitiveContains("not authori")
    }

    /// Forgets this app's Automation decision so the next call asks again.
    /// Rebuilt dev copies get a new signature, which can leave a stale denial.
    func askForPermissionAgain() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "AppleEvents", bundleId]
            try? reset.run()
            reset.waitUntilExit()
            DispatchQueue.main.async { SpotifyModel.shared.refresh() }
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        // One osascript at a time; a pending permission prompt blocks it.
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Self.run("""
        if application "Spotify" is running then
            tell application "Spotify"
                set s to player state as string
                if s is "stopped" then return "stopped"
                set t to current track
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string)
            end tell
        else
            return "notrunning"
        end if
        """) { [weak self] output, error in
            self?.refreshInFlight = false
            self?.apply(output: output, error: error)
        }
    }

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func command(_ verb: String) {
        Self.run("if application \"Spotify\" is running then tell application \"Spotify\" to \(verb)") { [weak self] _, error in
            if let error { self?.lastError = error }
            self?.refresh()
        }
    }

    private func apply(output: String, error: String?) {
        lastError = error
        let lines = output.components(separatedBy: "\n")
        switch lines.first {
        case "notrunning": status = .notRunning
        case "stopped": status = .stopped
        case "playing", "paused":
            guard lines.count >= 6 else { return }
            status = lines[0] == "playing" ? .playing : .paused
            track = lines[1]
            artist = lines[2]
            artworkURL = URL(string: lines[3])
            duration = (Double(lines[4].replacingOccurrences(of: ",", with: ".")) ?? 0) / 1000
            position = Double(lines[5].replacingOccurrences(of: ",", with: ".")) ?? 0
            positionReadAt = Date()
        default:
            break
        }
    }

    /// Runs a script with osascript off the main thread. The first run asks the
    /// user to let cmux control Spotify (macOS Automation permission).
    private static func run(_ script: String, completion: @escaping @MainActor (String, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            var output = "", error: String?
            do {
                try process.run()
                process.waitUntilExit()
                output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                error = errText.isEmpty ? nil : errText
            } catch let launchError {
                error = launchError.localizedDescription
            }
            let result = (output, error)
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
    }
}

/// Spotify mini player that changes shape with the tab's size: a spinning
/// record with the song and a skip button when small, artwork and controls
/// when medium, and a progress bar when large.
private struct SpotifyWidgetView: View {
    @ObservedObject private var spotify = SpotifyModel.shared

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Group {
                switch spotify.status {
                case .notRunning:
                    VStack(spacing: 10) {
                        Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                        Button(String(localized: "appWidget.spotify.open", defaultValue: "Open Spotify"), action: spotify.openSpotify)
                        if let error = spotify.lastError, !spotify.needsPermission { errorText(error) }
                    }
                case .stopped:
                    VStack(spacing: 10) {
                        Text(String(localized: "appWidget.spotify.stopped", defaultValue: "Nothing playing")).foregroundStyle(.secondary)
                        Button { spotify.playPause() } label: { Image(systemName: "play.fill") }
                    }
                case .playing, .paused:
                    if size.width < 260 || size.height < 200 {
                        compact(size)
                    } else if size.width >= 380 && size.height >= 440 {
                        large(size)
                    } else {
                        medium(size)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .padding(10)
        .overlay(alignment: .top) {
            if spotify.needsPermission { permissionBanner }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .foregroundStyle(.white)
        .onAppear { spotify.viewerAppeared() }
        .onDisappear { spotify.viewerDisappeared() }
    }

    private func compact(_ size: CGSize) -> some View {
        let disc = max(40, min(size.width, size.height) * 0.6)
        return VStack(spacing: 6) {
            VinylDisc(artworkURL: spotify.artworkURL, spinning: spotify.status == .playing)
                .frame(width: disc, height: disc)
            Text(spotify.track).font(.caption.bold()).lineLimit(1)
            Button { spotify.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(.plain)
        }
    }

    private func medium(_ size: CGSize) -> some View {
        HStack(spacing: 14) {
            artwork.frame(width: min(size.height * 0.8, size.width * 0.4), height: min(size.height * 0.8, size.width * 0.4))
            VStack(alignment: .leading, spacing: 6) {
                titleBlock
                controls
            }
            Spacer(minLength: 0)
        }
    }

    private func large(_ size: CGSize) -> some View {
        VStack(spacing: 14) {
            artwork.frame(width: min(size.width, size.height * 0.6), height: min(size.width, size.height * 0.6))
            titleBlock.frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = spotify.status == .playing ? context.date.timeIntervalSince(spotify.positionReadAt) : 0
                ProgressView(value: min(spotify.position + elapsed, max(spotify.duration, 1)), total: max(spotify.duration, 1))
                    .tint(.green)
            }
            controls
        }
    }

    private var artwork: some View {
        AsyncImage(url: spotify.artworkURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.white.opacity(0.08).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spotify.track).font(.headline).lineLimit(1)
            Text(spotify.artist).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            Button { spotify.previous() } label: { Image(systemName: "backward.fill") }
            Button { spotify.playPause() } label: {
                Image(systemName: spotify.status == .playing ? "pause.circle.fill" : "play.circle.fill").font(.title)
            }
            Button { spotify.next() } label: { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
    }

    private var permissionBanner: some View {
        VStack(spacing: 6) {
            Text(String(localized: "appWidget.spotify.permission", defaultValue: "Allow cmux to control Spotify"))
                .font(.caption.bold())
            HStack {
                Button(String(localized: "appWidget.spotify.askAgain", defaultValue: "Ask Again"), action: spotify.askForPermissionAgain)
                Button(String(localized: "appWidget.spotify.openSettings", defaultValue: "Open Settings"), action: spotify.openAutomationSettings)
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .padding(6)
    }

    private func errorText(_ error: String) -> some View {
        Text(error).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
    }
}

private struct VinylDisc: View {
    let artworkURL: URL?
    let spinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            ZStack {
                Circle().fill(Color.black)
                ForEach(1..<6) { ring in
                    Circle()
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                        .scaleEffect(0.45 + Double(ring) * 0.1)
                }
                AsyncImage(url: artworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.green.opacity(0.6)
                }
                .clipShape(Circle())
                .scaleEffect(0.4)
                Circle().fill(Color.black).scaleEffect(0.06)
            }
            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 45))
        }
    }
}
