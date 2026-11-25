import AppKit
import SwiftUI

/// Fork: the Workmaxxing start window, shown at launch like Cursor's or
/// Xcode's. Pick a folder on this Mac, choose how many agents, and it opens a
/// workspace there with every box already running the agent command.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    static let showAtLaunchKey = "cmuxFork.welcome.showAtLaunch"

    private var window: NSWindow?

    static func showAtLaunchIfEnabled() {
        guard UserDefaults.standard.object(forKey: showAtLaunchKey) as? Bool ?? true else { return }
        // After session restore has put the main window up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { shared.show() }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WelcomeView(onDone: { [weak self] in self?.close() }))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// Opens a workspace rooted at `folder` with `agents` boxes running
    /// `command` (0 = one plain terminal).
    static func launch(folder: String, agents: Int, command: String) {
        guard let tabManager = AppDelegate.shared?.tabManager else { return }
        LeftSidebarRecents.add(folder)
        let name = (folder as NSString).lastPathComponent
        guard let workspace = tabManager.addWorkspaceIfActive(
            title: name,
            workingDirectory: folder,
            inheritWorkingDirectory: false,
            select: true
        ) else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if agents > 0, !trimmed.isEmpty, let layout = agentLayout(count: agents, command: trimmed) {
            workspace.applyCustomLayout(layout, baseCwd: folder)
        }
    }

    /// Columns of boxes, like the presets in cmux.json: 8 agents is 2, 2, 4.
    static func agentLayout(count: Int, command: String) -> CmuxLayoutNode? {
        let columns: [Int]
        switch count {
        case 1: columns = [1]
        case 2: columns = [1, 1]
        case 3: columns = [1, 2]
        case 4: columns = [2, 2]
        case 5: columns = [2, 2, 1]
        case 6: columns = [2, 2, 2]
        case 7: columns = [2, 2, 3]
        default: columns = [2, 2, 4]
        }
        var box = 0
        func pane() -> [String: Any] {
            box += 1
            var surface: [String: Any] = ["type": "terminal", "name": "box \(box)", "command": command]
            if box == 1 { surface["focus"] = true }
            return ["pane": ["surfaces": [surface]]]
        }
        func chain(_ direction: String, _ items: [[String: Any]]) -> [String: Any] {
            guard items.count > 1 else { return items[0] }
            var node: [String: Any] = ["direction": direction, "children": [items[0], chain(direction, Array(items.dropFirst()))]]
            if items.count > 2 { node["split"] = 1.0 / Double(items.count) }
            return node
        }
        let tree = chain("horizontal", columns.map { rows in chain("vertical", (0..<rows).map { _ in pane() }) })
        guard let data = try? JSONSerialization.data(withJSONObject: tree) else { return nil }
        return try? JSONDecoder().decode(CmuxLayoutNode.self, from: data)
    }
}

private struct WelcomeFolder: Identifiable, Hashable, Sendable {
    let path: String
    let modified: Date
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
}

private struct WelcomeView: View {
    let onDone: () -> Void

    @AppStorage("cmuxFork.welcome.agents") private var agents = 4
    @AppStorage("cmuxFork.welcome.command") private var command = "claude"
    @AppStorage(WelcomeWindowController.showAtLaunchKey) private var showAtLaunch = true
    @State private var query = ""
    @State private var recents: [WelcomeFolder] = []
    @State private var projects: [WelcomeFolder] = []
    @State private var selection: String?

    private static let agentChoices = [0, 1, 2, 3, 4, 6, 8]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
                .background(Color.primary.opacity(0.04))
            Divider()
            folderList
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await load() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workmaxxing").font(.system(size: 26, weight: .bold))
                Text(String(localized: "welcome.subtitle", defaultValue: "Pick a folder, launch your agents."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            Button(action: openOther) {
                Label(String(localized: "welcome.openFolder", defaultValue: "Open Folder…"), systemImage: "folder")
            }
            .controlSize(.large)
            Divider()
            Text(String(localized: "welcome.agents", defaultValue: "Agents per folder")).font(.headline)
            Picker("", selection: $agents) {
                ForEach(Self.agentChoices, id: \.self) { count in
                    Text(count == 0
                         ? String(localized: "welcome.terminalOnly", defaultValue: "Terminal only")
                         : String(format: String(localized: "welcome.agentCount", defaultValue: "%d agents"), count))
                        .tag(count)
                }
            }
            .labelsHidden()
            TextField(String(localized: "welcome.command", defaultValue: "Command (e.g. claude, codex)"), text: $command)
                .textFieldStyle(.roundedBorder)
                .disabled(agents == 0)
            Spacer()
            Toggle(String(localized: "welcome.showAtLaunch", defaultValue: "Show this window at launch"), isOn: $showAtLaunch)
                .font(.caption)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var folderList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "welcome.search", defaultValue: "Search projects"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 16)
            List(selection: $selection) {
                if !filter(recents).isEmpty {
                    Section(String(localized: "welcome.recent", defaultValue: "Recent")) {
                        ForEach(filter(recents)) { row($0) }
                    }
                }
                Section(String(localized: "welcome.projects", defaultValue: "Projects")) {
                    ForEach(filter(projects)) { row($0) }
                }
            }
            .listStyle(.inset)
            HStack {
                Text(selection.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "welcome.pickOne", defaultValue: "Select a folder"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button(String(localized: "welcome.launch", defaultValue: "Launch")) {
                    if let selection { launch(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(16)
        }
    }

    private func row(_ folder: WelcomeFolder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name).lineLimit(1)
                Text(folder.parent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(folder.modified, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(folder.path)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { launch(folder.path) }
    }

    private func filter(_ folders: [WelcomeFolder]) -> [WelcomeFolder] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(trimmed) || $0.parent.localizedCaseInsensitiveContains(trimmed) }
    }

    private func launch(_ path: String) {
        WelcomeWindowController.launch(folder: path, agents: agents, command: command)
        onDone()
    }

    private func openOther() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launch(url.path)
    }

    private func load() async {
        let recentPaths = LeftSidebarRecents.load()
        let found = await Task.detached(priority: .userInitiated) { () -> ([WelcomeFolder], [WelcomeFolder]) in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let roots = ["Desktop/Projects", "Desktop/Full Scale Projects", "Developer", "Projects", "Code", "src"]
                .map { (home as NSString).appendingPathComponent($0) }
            func folder(_ path: String) -> WelcomeFolder? {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                return WelcomeFolder(path: path, modified: modified)
            }
            let recents = recentPaths.compactMap(folder)
            let projects = roots.flatMap { root -> [WelcomeFolder] in
                let children = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
                return children
                    .filter { !$0.hasPrefix(".") }
                    .compactMap { folder((root as NSString).appendingPathComponent($0)) }
            }
            .sorted { $0.modified > $1.modified }
            return (recents, projects)
        }.value
        recents = found.0
        projects = found.1
    }
}
