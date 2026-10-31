import SwiftUI
import UniformTypeIdentifiers

struct DrawingEditorView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var session: DrawingSession
    @State private var isShowingPageSetup = false
    @State private var exportedPDF: PDFFile?
    @AppStorage("allowsFingerDrawing") private var allowsFingerDrawing = false

    init(url: URL, pdfURL: URL? = nil) {
        _session = State(initialValue: DrawingSession(url: url, pdfURL: pdfURL))
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
                        onChange: { session.drawingChanged($0) },
                        onAddPage: document.canAddPages ? { session.addPage() } : nil
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
        ToolbarItemGroup(placement: .primaryAction) {
            if session.document?.canAddPages == true {
                Button("Add Page", systemImage: "plus.rectangle.portrait") { session.addPage() }
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
}
