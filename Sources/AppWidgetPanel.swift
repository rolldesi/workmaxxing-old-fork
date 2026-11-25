import AppKit
import Bonsplit
import CmuxWorkspaces
import Combine
import EventKit
import SwiftUI

/// Saved state of an app tab (Spotify, sticky note, prompt queue).
struct SessionAppWidgetPanelSnapshot: Codable, Sendable {
    var kind: String
    var text: String?
    var prompts: [String]?
    var targetPanelId: UUID?
    var autoSend: Bool?
    var path: String?
}

/// A small native app opened from a box's apps button, living as a tab.
@MainActor
final class AppWidgetPanel: Panel, ObservableObject {
    enum Kind: String, CaseIterable {
        case spotify
        case stickyNote
        case promptQueue
        case vault
        case calendar

        var title: String {
            switch self {
            case .spotify: return String(localized: "appWidget.spotify.title", defaultValue: "Spotify")
            case .stickyNote: return String(localized: "appWidget.stickyNote.title", defaultValue: "Sticky Note")
            case .promptQueue: return String(localized: "appWidget.promptQueue.title", defaultValue: "Prompt Queue")
            case .vault: return String(localized: "appWidget.vault.title", defaultValue: "Obsidian Vault")
            case .calendar: return String(localized: "appWidget.calendar.title", defaultValue: "Calendar")
            }
        }

        var icon: String {
            switch self {
            case .spotify: return "music.note"
            case .stickyNote: return "note.text"
            case .promptQueue: return "list.bullet.rectangle"
            case .vault: return "books.vertical"
            case .calendar: return "calendar"
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
    /// The vault folder an Obsidian Vault tab browses.
    @Published var path: String?
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
        path = snapshot?.path ?? (kind == .vault ? Self.defaultObsidianVault() : nil)
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
            autoSend: kind == .promptQueue ? autoSend : nil,
            path: kind == .vault ? path : nil
        )
    }

    func close() {
        queueTimer?.invalidate()
        queueTimer = nil
    }

    /// Opens a note beside this tab in cmux's markdown viewer (live-reloads on save).
    func openNote(_ url: URL) {
        guard let workspace, let pane = workspace.paneId(forPanelId: id) else { return }
        _ = workspace.newMarkdownSurface(inPane: pane, filePath: url.path, focus: true)
    }

    static func obsidianURL(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// The vault Obsidian last had open, from its own vault list.
    static func defaultObsidianVault() -> String? {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return nil }
        let entries = vaults.values.compactMap { entry -> (path: String, open: Bool, ts: Double)? in
            guard let path = entry["path"] as? String else { return nil }
            return (path, entry["open"] as? Bool ?? false, (entry["ts"] as? NSNumber)?.doubleValue ?? 0)
        }
        return entries.max { ($0.open ? 1 : 0, $0.ts) < ($1.open ? 1 : 0, $1.ts) }?.path
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
        menu.addItem(BoxMenuItem(
            title: String(localized: "appWidget.pdf.title", defaultValue: "PDF…"),
            symbol: "doc.text.magnifyingglass"
        ) { [weak self] in
            let open = NSOpenPanel()
            open.allowedContentTypes = [.pdf]
            open.allowsMultipleSelection = false
            guard open.runModal() == .OK, let url = open.url else { return }
            _ = self?.newFilePreviewSurface(inPane: paneId, filePath: url.path, focus: true)
        })

        menu.addItem(.separator())
        for source in BrowserWithLogins.allCases {
            menu.addItem(BoxMenuItem(title: source.menuTitle, symbol: source.symbol) { [weak self] in
                self?.openBrowserWithLogins(source, inPane: paneId)
            })
        }

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
            case .vault: VaultView(panel: panel)
            case .calendar: CalendarWidgetView()
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
    @Published private(set) var shuffling = false
    @Published private(set) var repeating = false
    @Published private(set) var volume: Double = 50
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
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string) & linefeed & (shuffling as string) & linefeed & (repeating as string) & linefeed & (sound volume as string)
            end tell
        else
            return "notrunning"
        end if
        """) { [weak self] output, error in
            self?.refreshInFlight = false
            self?.apply(output: output, error: error)
        }
    }

    func playPause() {
        status == .notRunning ? startInBackground(then: "play") : command("playpause")
    }
    func next() { command("next track") }
    func previous() { command("previous track") }
    func toggleShuffle() { command("set shuffling to not shuffling") }
    func toggleRepeat() { command("set repeating to not repeating") }
    func setVolume(_ level: Double) { command("set sound volume to \(Int(level.rounded()))") }

    /// Plays a track or other Spotify URI now, starting Spotify hidden if needed.
    func play(uri: String) {
        // URIs are spotify:kind:id; anything else never reaches the script.
        guard uri.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" }) else { return }
        let verb = "play track \"\(uri)\""
        status == .notRunning ? startInBackground(then: verb) : command(verb)
    }

    /// Starts Spotify without showing its window, then runs `verb` once it is up.
    func startInBackground(then verb: String? = nil) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            lastError = String(localized: "appWidget.spotify.notInstalled", defaultValue: "Spotify isn't installed.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in
                // ponytail: fixed wait for Spotify to accept commands; poll its state if 3s proves flaky.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let verb { SpotifyModel.shared.command(verb) } else { SpotifyModel.shared.refresh() }
            }
        }
    }

    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    fileprivate func command(_ verb: String) {
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
            if lines.count >= 9 {
                shuffling = lines[6] == "true"
                repeating = lines[7] == "true"
                volume = Double(lines[8]) ?? volume
            }
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
                        Button {
                            spotify.playPause()
                        } label: {
                            Label(String(localized: "appWidget.spotify.playHidden", defaultValue: "Play (Spotify stays hidden)"), systemImage: "play.fill")
                        }
                        if let error = spotify.lastError, !spotify.needsPermission { errorText(error) }
                        if size.width >= 340 && size.height >= 380 { SpotifyLibraryView() }
                    }
                case .stopped:
                    VStack(spacing: 10) {
                        Text(String(localized: "appWidget.spotify.stopped", defaultValue: "Nothing playing")).foregroundStyle(.secondary)
                        Button { spotify.playPause() } label: { Image(systemName: "play.fill") }
                    }
                case .playing, .paused:
                    if size.width < 260 || size.height < 200 {
                        compact(size)
                    } else if size.width >= 340 && size.height >= 380 {
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
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                artwork.frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 6) {
                    titleBlock
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = spotify.status == .playing ? context.date.timeIntervalSince(spotify.positionReadAt) : 0
                        ProgressView(value: min(spotify.position + elapsed, max(spotify.duration, 1)), total: max(spotify.duration, 1))
                            .tint(.green)
                    }
                }
            }
            HStack(spacing: 18) {
                Button(action: spotify.toggleShuffle) {
                    Image(systemName: "shuffle").foregroundStyle(spotify.shuffling ? Color.green : Color.white.opacity(0.7))
                }
                controls
                Button(action: spotify.toggleRepeat) {
                    Image(systemName: "repeat").foregroundStyle(spotify.repeating ? Color.green : Color.white.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
            SpotifyVolumeSlider(spotify: spotify)
            SpotifyLibraryView()
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

// MARK: - Obsidian vault

private struct VaultNote: Identifiable, Sendable {
    let url: URL
    let relativeFolder: String
    let modified: Date
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Browses an Obsidian vault's notes; opens them in cmux's markdown viewer or in Obsidian.
private struct VaultView: View {
    @ObservedObject var panel: AppWidgetPanel
    @State private var notes: [VaultNote] = []
    @State private var query = ""
    @State private var newNoteName = ""
    @State private var loading = false

    private var filtered: [VaultNote] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return notes }
        return notes.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.relativeFolder.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = panel.path {
                HStack {
                    Image(systemName: "books.vertical")
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline).lineLimit(1)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(String(localized: "appWidget.vault.refresh", defaultValue: "Refresh"))
                    Button { openInObsidian(path) } label: { Image(systemName: "arrow.up.forward.app") }
                        .help(String(localized: "appWidget.vault.openVault", defaultValue: "Open vault in Obsidian"))
                    Button(String(localized: "appWidget.vault.change", defaultValue: "Change…"), action: pickVault)
                }
                .buttonStyle(.borderless)
                TextField(String(localized: "appWidget.vault.search", defaultValue: "Search notes"), text: $query)
                    .textFieldStyle(.roundedBorder)
                List(filtered) { note in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(note.name).lineLimit(1)
                            if !note.relativeFolder.isEmpty {
                                Text(note.relativeFolder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button { openInObsidian(note.url.path) } label: { Image(systemName: "arrow.up.forward.app") }
                            .buttonStyle(.borderless)
                            .help(String(localized: "appWidget.vault.openNote", defaultValue: "Open in Obsidian"))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { panel.openNote(note.url) }
                }
                HStack {
                    TextField(String(localized: "appWidget.vault.newNote", defaultValue: "New note name"), text: $newNoteName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createNote)
                    Button(String(localized: "appWidget.vault.create", defaultValue: "Create"), action: createNote)
                        .disabled(newNoteName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Spacer()
                Text(String(localized: "appWidget.vault.none", defaultValue: "No Obsidian vault found."))
                    .foregroundStyle(.secondary)
                Button(String(localized: "appWidget.vault.choose", defaultValue: "Choose Vault Folder…"), action: pickVault)
                Spacer()
            }
        }
        .padding(10)
        .task(id: panel.path) { await reload() }
    }

    private func reload() async {
        guard let path = panel.path else { return }
        loading = true
        let root = URL(fileURLWithPath: path)
        notes = await Task.detached(priority: .userInitiated) { Self.listNotes(in: root) }.value
        loading = false
    }

    // ponytail: capped at 5000 notes, newest first; page or index if vaults grow past that.
    private nonisolated static func listNotes(in root: URL) -> [VaultNote] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var notes: [VaultNote] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            let folder = url.deletingLastPathComponent().path
                .replacingOccurrences(of: root.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let modified = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            notes.append(VaultNote(url: url, relativeFolder: folder, modified: modified))
            if notes.count >= 5000 { break }
        }
        return notes.sorted { $0.modified > $1.modified }
    }

    private func pickVault() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        if open.runModal() == .OK, let url = open.url { panel.path = url.path }
    }

    private func openInObsidian(_ path: String) {
        if let url = AppWidgetPanel.obsidianURL(for: path) { NSWorkspace.shared.open(url) }
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespaces)
        guard let path = panel.path, !name.isEmpty, !name.contains("/") else { return }
        let url = URL(fileURLWithPath: path).appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data("# \(name)\n\n".utf8))
        }
        newNoteName = ""
        panel.openNote(url)
        Task { await reload() }
    }
}

// MARK: - Calendar

/// Upcoming events from the Mac's calendars (EventKit). Asks for access once.
@MainActor
final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [EKEvent] = []
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarModel.shared.reload() }
            }
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            reload()
        case .notDetermined:
            store.requestFullAccessToEvents { granted, _ in
                Task { @MainActor in
                    CalendarModel.shared.access = granted ? .granted : .denied
                    CalendarModel.shared.reload()
                }
            }
        default:
            access = .denied
        }
    }

    func reload() {
        guard access == .granted else { return }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > Date() }
            .sorted { $0.startDate < $1.startDate }
    }

    func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The next 7 days of events; just the next event when the tab is small.
private struct CalendarWidgetView: View {
    @ObservedObject private var calendar = CalendarModel.shared

    var body: some View {
        GeometryReader { geometry in
            Group {
                switch calendar.access {
                case .unknown:
                    ProgressView()
                case .denied:
                    VStack(spacing: 8) {
                        Text(String(localized: "appWidget.calendar.denied", defaultValue: "cmux can't read your calendars."))
                            .foregroundStyle(.secondary)
                        Button(String(localized: "appWidget.calendar.settings", defaultValue: "Open Settings"), action: calendar.openPrivacySettings)
                    }
                case .granted:
                    if calendar.events.isEmpty {
                        Text(String(localized: "appWidget.calendar.empty", defaultValue: "Nothing in the next 7 days"))
                            .foregroundStyle(.secondary)
                    } else if geometry.size.width < 260 || geometry.size.height < 200 {
                        nextEvent(calendar.events[0])
                    } else {
                        agenda
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(10)
        .onAppear { calendar.start() }
    }

    private func nextEvent(_ event: EKEvent) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 4) {
                Text(event.title ?? "").font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(event.startDate > context.date
                     ? event.startDate.formatted(.relative(presentation: .named))
                     : String(localized: "appWidget.calendar.now", defaultValue: "Now"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(timeRange(event)).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: event.calendar.color).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .onTapGesture(perform: calendar.openCalendarApp)
        }
    }

    private var agenda: some View {
        let days = Dictionary(grouping: calendar.events) { Calendar.current.startOfDay(for: $0.startDate) }
        return List {
            ForEach(days.keys.sorted(), id: \.self) { day in
                Section(day.formatted(.dateTime.weekday(.wide).day().month())) {
                    ForEach(Array((days[day] ?? []).enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: event.calendar.color))
                                .frame(width: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title ?? "").lineLimit(1)
                                Text(timeRange(event)).font(.caption).foregroundStyle(.secondary)
                                if let location = event.location, !location.isEmpty {
                                    Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(perform: calendar.openCalendarApp)
                    }
                }
            }
        }
    }

    private func timeRange(_ event: EKEvent) -> String {
        if event.isAllDay { return String(localized: "appWidget.calendar.allDay", defaultValue: "All day") }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}

/// Volume that only tells Spotify the level when the drag ends.
private struct SpotifyVolumeSlider: View {
    @ObservedObject var spotify: SpotifyModel
    @State private var level: Double = 50
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.white.opacity(0.6))
            Slider(value: $level, in: 0...100) { editing in
                dragging = editing
                if !editing { spotify.setVolume(level) }
            }
            .tint(.green)
            Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .onAppear { level = spotify.volume }
        .onChange(of: spotify.volume) { _, newValue in if !dragging { level = newValue } }
    }
}

// MARK: - Browsers with the user's logins

/// A cmux browser profile carrying cookies imported from a real browser, so
/// sites open signed in. Agents reach the same profile with
/// `cmux browser open --profile Chrome` (or Safari).
enum BrowserWithLogins: CaseIterable {
    case chrome
    case safari

    var profileName: String { self == .chrome ? "Chrome" : "Safari" }
    var importId: String { self == .chrome ? "google-chrome" : "safari" }
    var menuTitle: String {
        self == .chrome
            ? String(localized: "appWidget.browser.chrome", defaultValue: "Chrome (your logins)")
            : String(localized: "appWidget.browser.safari", defaultValue: "Safari (your logins)")
    }
    var symbol: String { self == .chrome ? "globe" : "safari" }
}

extension Workspace {
    /// Opens a browser tab on the matching profile. The first time it imports
    /// that browser's cookies before loading; later it refreshes them after.
    func openBrowserWithLogins(_ source: BrowserWithLogins, inPane paneId: PaneID) {
        let store = BrowserProfileStore.shared
        guard let profile = store.profiles.first(where: { $0.displayName == source.profileName })
                ?? store.createProfile(named: source.profileName) else { return }
        let importedKey = "cmuxFork.browserLoginsImported.\(source.profileName)"
        let firstTime = !UserDefaults.standard.bool(forKey: importedKey)
        Task { @MainActor [weak self] in
            if firstTime {
                await Self.importLogins(source, reportProblems: true)
                UserDefaults.standard.set(true, forKey: importedKey)
            }
            _ = self?.newBrowserSurface(inPane: paneId, focus: true, preferredProfileID: profile.id)
            if !firstTime { await Self.importLogins(source, reportProblems: false) }
        }
    }

    private static func importLogins(_ source: BrowserWithLogins, reportProblems: Bool) async {
        guard let coordinator = AppDelegate.shared?.browserDataImportCoordinator else { return }
        let params: [String: Any] = ["browser": source.importId, "destination_profile": source.profileName]
        var problems: [String] = []
        do {
            let outcome = try await BrowserImportAutomation.importCookies(params: params, coordinator: coordinator)
            problems = outcome.warnings
        } catch {
            problems = [error.localizedDescription]
        }
        guard reportProblems, !problems.isEmpty else { return }
        // Safari needs Full Disk Access; Chrome asks for its Keychain item.
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "appWidget.browser.importProblem", defaultValue: "Some %@ logins couldn't be imported"),
            source.profileName
        )
        alert.informativeText = problems.joined(separator: "\n\n")
        alert.runModal()
    }
}
