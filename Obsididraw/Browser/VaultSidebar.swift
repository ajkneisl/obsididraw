import SwiftUI

/// The vault file explorer: browse folders, create drawings and folders anywhere, rename, and trash.
struct VaultSidebar: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Binding var selection: URL?

    @State private var namePrompt: NamePrompt?
    @State private var promptText = ""
    @State private var pendingTrash: VaultItem?
    @State private var errorMessage: String?
    @State private var isChoosingVault = false
    @State private var isShowingSettings = false

    private enum NamePrompt {
        case newFolder(parent: URL)
        case rename(VaultItem)

        var title: String {
            switch self {
            case .newFolder: "New Folder"
            case .rename(let item): "Rename “\(item.displayName)”"
            }
        }
    }

    var body: some View {
        @Bindable var store = store

        List(selection: $selection) {
            OutlineGroup(store.tree, children: \.children) { item in
                Label(item.displayName, systemImage: item.systemImage)
                    .foregroundStyle(item.kind == .folder || item.isOpenable ? .primary : .secondary)
                    .selectionDisabled(!item.isOpenable)
                    .contextMenu { menu(for: item) }
            }
        }
        .overlay {
            if store.tree.isEmpty {
                ContentUnavailableView {
                    Label("No Drawings Yet", systemImage: "pencil.and.scribble")
                } description: {
                    Text("Create a drawing anywhere in your vault with the + button, or by long-pressing a folder.")
                }
            }
        }
        .navigationTitle(store.vaultName)
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    createButtons(in: targetFolder)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Toggle("Show All Files", systemImage: "doc.on.doc", isOn: $store.includeAllFiles)
                    Button("Switch Vault…", systemImage: "folder.badge.gearshape") { isChoosingVault = true }
                    Divider()
                    Button("Settings…", systemImage: "gearshape") { isShowingSettings = true }
                }
            }
        }
        .alert(namePrompt?.title ?? "", isPresented: isPresented($namePrompt)) {
            TextField("Name", text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { commitNamePrompt() }
        }
        .confirmationDialog(
            "Move “\(pendingTrash?.displayName ?? "")” to the vault trash?",
            isPresented: isPresented($pendingTrash),
            titleVisibility: .visible,
            presenting: pendingTrash
        ) { item in
            Button("Move to Trash", role: .destructive) { trash(item) }
        } message: { _ in
            Text("It will be moved to the vault's .trash folder, where Obsidian can restore it.")
        }
        .alert("Something Went Wrong", isPresented: isPresented($errorMessage)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .vaultPicker(isPresented: $isChoosingVault)
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
    }

    // MARK: Menus

    @ViewBuilder
    private func createButtons(in folder: URL?) -> some View {
        if let folder {
            Button("New Drawing", systemImage: "pencil.and.scribble") { createDrawing(in: folder) }
            Button("New Folder", systemImage: "folder.badge.plus") {
                promptText = "Untitled"
                namePrompt = .newFolder(parent: folder)
            }
        }
    }

    @ViewBuilder
    private func menu(for item: VaultItem) -> some View {
        if item.kind == .folder {
            createButtons(in: item.url)
            Divider()
        }
        if item.kind == .drawing || item.kind == .pdf {
            let target = item.isAnnotated ? VaultItem.annotationURL(forPDF: item.url) : item.url
            Button("Open in Obsidian", systemImage: "arrow.up.forward.app") {
                if let url = store.obsidianURL(for: target) { openURL(url) }
            }
            Button(item.isAnnotated ? "Copy Annotated Embed Link" : "Copy Embed Link", systemImage: "link") {
                UIPasteboard.general.string = store.embedLink(for: target)
            }
        }
        Button("Rename", systemImage: "pencil") {
            promptText = item.displayName
            namePrompt = .rename(item)
        }
        Button("Move to Trash", systemImage: "trash", role: .destructive) { pendingTrash = item }
    }

    /// New items go next to the current selection, or at the vault root.
    private var targetFolder: URL? {
        selection?.deletingLastPathComponent() ?? store.rootURL
    }

    // MARK: Actions

    private func createDrawing(in folder: URL) {
        perform { selection = try await store.createDrawing(in: folder) }
    }

    private func commitNamePrompt() {
        guard let prompt = namePrompt else { return }
        let name = promptText
        perform {
            switch prompt {
            case .newFolder(let parent):
                try await store.createFolder(named: name, in: parent)
            case .rename(let item):
                let newURL = try await store.rename(item, to: name)
                if let current = selection, current.isInside(item.url) {
                    let suffix = current.standardizedFileURL.pathComponents.dropFirst(item.url.standardizedFileURL.pathComponents.count)
                    selection = suffix.reduce(newURL) { $0.appending(path: $1) }
                }
            }
        }
    }

    private func trash(_ item: VaultItem) {
        perform {
            if let current = selection, current.isInside(item.url) { selection = nil }
            try await store.trash(item)
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { errorMessage = error.localizedDescription }
        }
    }

    private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
