import AppKit
import SwiftUI

/// Fork: the left sidebar's Agents | Files switch, and the Files view laid
/// over the workspace list. The workspace sidebar stays mounted underneath so
/// its titlebar controls and footer keep working.
struct LeftSidebarFilesOverlay: View {
    @Binding var showsFiles: Bool
    @ObservedObject var store: FileExplorerStore
    @ObservedObject var state: FileExplorerState
    /// A folder the user picked instead of the workspace's working directory.
    let rootOverride: String?
    let background: Color
    let onOpenFile: (String) -> Void
    let onChooseFolder: () -> Void
    let onFollowWorkspace: () -> Void

    /// Room for the window's traffic lights and the sidebar's titlebar buttons.
    private static let topInset: CGFloat = WindowChromeMetrics.appTitlebarHeight + 8
    /// Room for the sidebar footer (account, help, cloud).
    private static let footerInset: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            if showsFiles {
                VStack(spacing: 0) {
                    folderBar
                    FileExplorerPanelView(
                        store: store,
                        state: state,
                        onOpenFilePreview: onOpenFile,
                        presentation: .files
                    )
                }
                .background(background)
                .padding(.top, Self.topInset)
            } else {
                Color.clear.allowsHitTesting(false)
            }
            modeSwitch
                .padding(.bottom, Self.footerInset)
        }
    }

    private var folderBar: some View {
        HStack(spacing: 6) {
            Image(systemName: rootOverride == nil ? "folder" : "folder.fill")
                .foregroundStyle(.secondary)
            Text(store.rootPath.isEmpty
                 ? String(localized: "leftSidebar.files.noFolder", defaultValue: "No folder")
                 : (store.rootPath as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.head)
                .help(store.rootPath)
            Spacer(minLength: 4)
            if rootOverride != nil {
                Button(action: onFollowWorkspace) { Image(systemName: "arrow.uturn.backward") }
                    .help(String(localized: "leftSidebar.files.follow", defaultValue: "Follow the workspace's working directory"))
            }
            Button(action: onChooseFolder) { Image(systemName: "folder.badge.plus") }
                .help(String(localized: "leftSidebar.files.choose", defaultValue: "Choose working directory…"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 26)
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
}
