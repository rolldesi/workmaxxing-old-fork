import AppKit
import SwiftUI

/// Fork: the left sidebar's Agents | Files switch, and the Files view laid
/// over the workspace list. The workspace sidebar stays mounted underneath so
/// its titlebar controls and footer keep working.
struct LeftSidebarFilesOverlay: View {
    @Binding var showsFiles: Bool
    @ObservedObject var store: FileExplorerStore
    @ObservedObject var state: FileExplorerState
    /// A folder the user opened instead of the workspace's working directory.
    let rootOverride: String?
    let background: Color
    let onOpenFile: (String) -> Void
    let onOpenFolder: (String) -> Void
    let onFollowWorkspace: () -> Void

    @State private var recents: [String] = []

    /// Room for the window's traffic lights and the sidebar's titlebar buttons.
    private static let topInset: CGFloat = WindowChromeMetrics.appTitlebarHeight + 8
    /// Room for the sidebar footer (account, help, cloud).
    private static let footerInset: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            if showsFiles {
                VStack(spacing: 0) {
                    folderBar
                    if store.rootPath.isEmpty {
                        welcome
                    } else {
                        FileExplorerPanelView(
                            store: store,
                            state: state,
                            onOpenFilePreview: onOpenFile,
                            presentation: .files
                        )
                    }
                }
                .background(background)
                .padding(.top, Self.topInset)
            } else {
                Color.clear.allowsHitTesting(false)
            }
            modeSwitch
                .padding(.bottom, Self.footerInset)
        }
        .onAppear { recents = LeftSidebarRecents.load() }
    }

    private var folderBar: some View {
        HStack(spacing: 6) {
            Image(systemName: rootOverride == nil ? "folder" : "folder.fill")
                .foregroundStyle(.secondary)
            Text(store.rootPath.isEmpty
                 ? String(localized: "leftSidebar.files.noFolder", defaultValue: "No folder open")
                 : (store.rootPath as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.head)
                .help(store.rootPath)
            Spacer(minLength: 4)
            openMenu
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private var openMenu: some View {
        Menu {
            Button(String(localized: "leftSidebar.files.open", defaultValue: "Open…")) { pick(files: true, folders: true) }
            Button(String(localized: "leftSidebar.files.openFolder", defaultValue: "Open Folder…")) { pick(files: false, folders: true) }
            Button(String(localized: "leftSidebar.files.openFile", defaultValue: "Open File…")) { pick(files: true, folders: false) }
            Menu(String(localized: "leftSidebar.files.recent", defaultValue: "Open Recent")) {
                ForEach(recents, id: \.self) { path in
                    Button((path as NSString).abbreviatingWithTildeInPath) { open(URL(fileURLWithPath: path)) }
                }
                if !recents.isEmpty {
                    Divider()
                    Button(String(localized: "leftSidebar.files.clearRecent", defaultValue: "Clear Recently Opened")) {
                        LeftSidebarRecents.clear()
                        recents = []
                    }
                }
            }
            .disabled(recents.isEmpty)
            if rootOverride != nil {
                Divider()
                Button(String(localized: "leftSidebar.files.follow", defaultValue: "Follow Workspace Folder"), action: onFollowWorkspace)
            }
        } label: {
            Image(systemName: "folder.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "leftSidebar.files.openHelp", defaultValue: "Open a folder, project or file"))
        .onAppear { recents = LeftSidebarRecents.load() }
    }

    /// Like VS Code's empty explorer: open something, or pick up a recent.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(String(localized: "leftSidebar.files.openFolder", defaultValue: "Open Folder…")) { pick(files: false, folders: true) }
            Button(String(localized: "leftSidebar.files.openFile", defaultValue: "Open File…")) { pick(files: true, folders: false) }
            if !recents.isEmpty {
                Text(String(localized: "leftSidebar.files.recent", defaultValue: "Open Recent"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(recents.prefix(8), id: \.self) { path in
                    Button { open(URL(fileURLWithPath: path)) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent).lineLimit(1)
                            Text(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var modeSwitch: some View {
        Picker("", selection: $showsFiles) {
            Label(String(localized: "leftSidebar.mode.agents", defaultValue: "Agents"), systemImage: "person.2")
                .tag(false)
            Label(String(localized: "leftSidebar.mode.files", defaultValue: "Files"), systemImage: "folder")
                .tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(background)
    }

    private func pick(files: Bool, folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if !store.rootPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: store.rootPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Folders become the explorer root. Files open in a tab; projects
    /// (.xcodeproj, .xcworkspace, .code-workspace) also root the explorer at
    /// their folder, the way VS Code and Cursor open them.
    private func open(_ url: URL) {
        LeftSidebarRecents.add(url.path)
        recents = LeftSidebarRecents.load()
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let ext = url.pathExtension.lowercased()
        if ext == "code-workspace", let folder = Self.firstWorkspaceFolder(in: url) {
            onOpenFolder(folder)
            return
        }
        if isDirectory.boolValue && ext != "xcodeproj" && ext != "xcworkspace" {
            onOpenFolder(url.path)
            return
        }
        if ext == "xcodeproj" || ext == "xcworkspace" || store.rootPath.isEmpty {
            onOpenFolder(url.deletingLastPathComponent().path)
        }
        onOpenFile(url.path)
    }

    /// The first folder a VS Code / Cursor `.code-workspace` file lists.
    private static func firstWorkspaceFolder(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = json["folders"] as? [[String: Any]],
              let path = folders.first?["path"] as? String else { return nil }
        let base = file.deletingLastPathComponent()
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path))
            .standardizedFileURL.path
    }
}

/// Recently opened folders, projects and files, newest first.
enum LeftSidebarRecents {
    private static let key = "cmuxFork.leftSidebarRecents"

    static func load() -> [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func add(_ path: String) {
        var list = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
