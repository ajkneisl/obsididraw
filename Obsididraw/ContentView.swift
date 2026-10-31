import SwiftUI

struct ContentView: View {
    @Environment(VaultStore.self) private var store
    @State private var selection: URL?
    @State private var linkError: String?

    var body: some View {
        content
            .onOpenURL { openLink($0) }
            .alert("Can't Open Drawing", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(linkError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.rootURL == nil {
            WelcomeView()
        } else {
            NavigationSplitView {
                VaultSidebar(selection: $selection)
            } detail: {
                if let selection, selection.pathExtension.lowercased() == DrawingFile.fileExtension {
                    DrawingEditorView(url: selection)
                        .id(selection)
                } else if let selection, selection.pathExtension.lowercased() == "pdf" {
                    DrawingEditorView(url: VaultItem.annotationURL(forPDF: selection), pdfURL: selection)
                        .id(selection)
                } else {
                    ContentUnavailableView(
                        "No Drawing Selected",
                        systemImage: "pencil.and.scribble",
                        description: Text("Choose a drawing or PDF in the sidebar, or create a drawing with +.")
                    )
                }
            }
        }
    }

    /// Opens a drawing from an `obsididraw://open` link, e.g. a tapped embed in Obsidian.
    private func openLink(_ link: URL) {
        do {
            let url = try store.fileURL(forOpenLink: link)
            // A PDF's annotations are shown through the PDF itself, as in the sidebar.
            let pdf = url.deletingPathExtension()
            let isAnnotations = pdf.pathExtension.lowercased() == "pdf" && FileManager.default.fileExists(atPath: pdf.path(percentEncoded: false))
            selection = isAnnotations ? pdf : url
            Task { await store.refresh() }
        } catch {
            linkError = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
        .environment(VaultStore())
}
