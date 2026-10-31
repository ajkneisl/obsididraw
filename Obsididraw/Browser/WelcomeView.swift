import SwiftUI
import UniformTypeIdentifiers

/// First-launch screen asking for the Obsidian vault folder.
struct WelcomeView: View {
    @State private var isChoosingVault = false

    var body: some View {
        ContentUnavailableView {
            Label("Obsididraw", systemImage: "pencil.and.scribble")
        } description: {
            Text("Handwritten notes and sketches, saved straight into your Obsidian vault.")
        } actions: {
            Button("Open Vault…") { isChoosingVault = true }
                .buttonStyle(.borderedProminent)
        }
        .vaultPicker(isPresented: $isChoosingVault)
    }
}

extension View {
    /// Presents a folder picker and opens the chosen folder as the vault.
    func vaultPicker(isPresented: Binding<Bool>) -> some View {
        modifier(VaultPicker(isPresented: isPresented))
    }
}

private struct VaultPicker: ViewModifier {
    @Environment(VaultStore.self) private var store
    @Binding var isPresented: Bool
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder]) { result in
                do { try store.open(result.get()) } catch { errorMessage = error.localizedDescription }
            }
            .alert(
                "Couldn't Open Vault",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }
}
