import SwiftUI

struct ContentView: View {
    @Environment(VaultStore.self) private var store
    @State private var open: OpenDocument?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var linkError: String?

    /// `id` gives the editor its identity, so `url` can follow a rename without rebuilding it.
    private struct OpenDocument {
        let id = UUID()
        var url: URL
    }

    private var selection: Binding<URL?> {
        Binding {
            open?.url
        } set: { url in
            if let url, store.activeSession?.isShowing(url) == true, var current = open {
                // A rename already retargeted the session; keep its canvas and undo history.
                current.url = url
                open = current
            } else {
                open = url.map { OpenDocument(url: $0) }
            }
        }
    }

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
            NavigationSplitView(columnVisibility: $columnVisibility) {
                VaultSidebar(selection: selection)
            } detail: {
                if let open, open.url.pathExtension.lowercased() == DrawingFile.fileExtension {
                    editor(url: open.url, id: open.id)
                } else if let open, open.url.pathExtension.lowercased() == "pdf" {
                    editor(url: VaultItem.annotationURL(forPDF: open.url), pdfURL: open.url, id: open.id)
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

    private func editor(url: URL, pdfURL: URL? = nil, id: UUID) -> some View {
        DrawingEditorView(url: url, pdfURL: pdfURL) { old, new in
            selection.wrappedValue = selection.wrappedValue?.relocated(from: old, to: new)
        } onCanvasTouched: {
            if columnVisibility != .detailOnly {
                withAnimation { columnVisibility = .detailOnly }
            }
        }
        .id(id)
    }

    /// Opens a drawing from an `obsididraw://open` link, e.g. a tapped embed in Obsidian.
    private func openLink(_ link: URL) {
        do {
            let url = try store.fileURL(forOpenLink: link)
            // A PDF's annotations are shown through the PDF itself, as in the sidebar.
            let pdf = url.deletingPathExtension()
            let isAnnotations = pdf.pathExtension.lowercased() == "pdf" && FileManager.default.fileExists(atPath: pdf.path(percentEncoded: false))
            selection.wrappedValue = isAnnotations ? pdf : url
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
