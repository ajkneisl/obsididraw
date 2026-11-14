import SwiftUI
import UniformTypeIdentifiers

struct DrawingEditorView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var session: DrawingSession
    @State private var isShowingPageSetup = false
    @State private var exportedPDF: PDFFile?
    @State private var shapeKind: ShapeKind?
    @State private var canvasProxy = CanvasProxy()
    @State private var pageToDelete: Int?
    @State private var renameError: String?
    @AppStorage("allowsFingerDrawing") private var allowsFingerDrawing = false

    private let onRenamed: (_ old: URL, _ new: URL) -> Void
    private let onCanvasTouched: () -> Void

    init(url: URL, pdfURL: URL? = nil, onRenamed: @escaping (_ old: URL, _ new: URL) -> Void, onCanvasTouched: @escaping () -> Void) {
        _session = State(initialValue: DrawingSession(url: url, pdfURL: pdfURL))
        self.onRenamed = onRenamed
        self.onCanvasTouched = onCanvasTouched
    }

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView("Can't Open Drawing", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                if let document = session.document {
                    CanvasView(
                        document: document,
                        revision: session.revision,
                        allowsFingerDrawing: allowsFingerDrawing,
                        shapeKind: shapeKind,
                        onChange: { session.drawingChanged($0) },
                        onTouch: onCanvasTouched,
                        onAddPage: document.canAddPages ? { session.addPage() } : nil,
                        proxy: canvasProxy
                    )
                    .ignoresSafeArea(.container, edges: .bottom)
                    .background(Color(uiColor: PageCanvasView.deskColor).ignoresSafeArea())
                }
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $isShowingPageSetup) {
            if let document = session.document {
                PageSetupView(paper: document.paper, isPDF: document.pdf != nil) { session.updatePaper($0) }
            }
        }
        .alert("Delete Page?", isPresented: Binding(get: { pageToDelete != nil }, set: { if !$0 { pageToDelete = nil } }), presenting: pageToDelete) { index in
            Button("Delete Page \(index + 1)", role: .destructive) { session.deletePage(at: index) }
            Button("Cancel", role: .cancel) {}
        } message: { index in
            Text("Page \(index + 1) has ink on it, which will be deleted too. This can't be undone.")
        }
        .alert("Couldn't Rename", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
        .fileExporter(
            isPresented: Binding(get: { exportedPDF != nil }, set: { if !$0 { exportedPDF = nil } }),
            document: exportedPDF,
            contentType: .pdf,
            defaultFilename: session.title
        ) { _ in }
        .task {
            store.activeSession = session
            session.load()
        }
        .onDisappear {
            session.saveNow()
            if store.activeSession === session { store.activeSession = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.saveNow() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            DocumentTitleField(title: session.title, onRename: rename)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Shape", selection: $shapeKind) {
                    Label("Freehand", systemImage: "scribble").tag(ShapeKind?.none)
                    ForEach(ShapeKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.systemImage).tag(ShapeKind?.some(kind))
                    }
                }
            } label: {
                Label("Shapes", systemImage: shapeKind?.systemImage ?? "square.on.circle")
                    .symbolVariant(shapeKind == nil ? .none : .fill)
            }
            .disabled(session.document == nil)
            if session.document?.canAddPages == true {
                Button("Add Page", systemImage: "plus.rectangle.portrait") { session.addPage() }
                Button("Delete Page", systemImage: "minus.rectangle.portrait") { deletePageInView() }
                    .disabled(session.document?.canDeletePages != true)
            }
            Button("Page Setup", systemImage: "doc.badge.gearshape") { isShowingPageSetup = true }
                .disabled(session.document == nil)
            Button("Export PDF", systemImage: "square.and.arrow.up") {
                if let document = session.currentDocument {
                    exportedPDF = PDFFile(data: PDFExporter.data(for: document))
                }
            }
            .disabled(session.document == nil)
            #if !targetEnvironment(macCatalyst)
            Toggle("Draw with Finger", systemImage: "hand.point.up.left", isOn: $allowsFingerDrawing)
            #endif
            Button("Open in Obsidian", systemImage: "arrow.up.forward.app") {
                session.saveNow()
                if let url = store.obsidianURL(for: session.fileForObsidian) { openURL(url) }
            }
        }
    }

    /// Deletes the page on screen, asking first if that would throw ink away.
    private func deletePageInView() {
        guard let index = canvasProxy.pageInView, let document = session.currentDocument else { return }
        if document.pageHasInk(at: index) {
            pageToDelete = index
        } else {
            session.deletePage(at: index)
        }
    }

    private func rename(to name: String) {
        let item = session.vaultItem
        Task {
            do {
                onRenamed(item.url, try await store.rename(item, to: name))
            } catch {
                renameError = error.localizedDescription
            }
        }
    }
}

/// The document's name, centered in the navigation bar. Tapping it edits the name in place.
private struct DocumentTitleField: View {
    let title: String
    let onRename: (String) -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .frame(width: 320)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .task { isFocused = true }
        } else {
            Button {
                draft = title
                isEditing = true
            } label: {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Renames this document")
        }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != title { onRename(name) }
    }
}
