import Foundation
import Observation
import PencilKit

/// Loads one drawing and autosaves edits back to its file.
///
/// A PDF is edited through a companion drawing next to it (`Paper.pdf` → `Paper.pdf.draw`), which
/// is only created once something is drawn, so the PDF itself is never modified.
@Observable
final class DrawingSession {
    enum State {
        case loading
        case ready
        case failed(String)
    }

    private(set) var url: URL
    /// The background PDF, if this drawing annotates one.
    private(set) var pdfURL: URL?
    private(set) var state: State = .loading
    private(set) var document: EditorDocument?
    /// Bumped whenever `document.drawing` is replaced, telling the canvas to reload it.
    private(set) var revision = 0

    @ObservationIgnored private var latestDrawing: PKDrawing?
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isDetached = false

    private static let autosaveDelay: Duration = .seconds(1)

    init(url: URL, pdfURL: URL? = nil) {
        self.url = url
        self.pdfURL = pdfURL
    }

    var title: String {
        (pdfURL ?? url).deletingPathExtension().lastPathComponent
    }

    /// The vault file this document is named after: the PDF it annotates, or else the drawing.
    var vaultItem: VaultItem {
        if let pdfURL { VaultItem(url: pdfURL, kind: .pdf) } else { VaultItem(url: url, kind: .drawing) }
    }

    /// Whether this session is editing the document selected as `selection`.
    func isShowing(_ selection: URL) -> Bool {
        vaultItem.url.standardizedFileURL.path(percentEncoded: false) == selection.standardizedFileURL.path(percentEncoded: false)
    }

    /// The file to show in Obsidian: the drawing once it exists, otherwise the PDF it annotates.
    var fileForObsidian: URL {
        if let pdfURL, !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return pdfURL }
        return url
    }

    /// The document including strokes drawn since the last save.
    var currentDocument: EditorDocument? {
        guard var document else { return nil }
        if let latestDrawing { document.drawing = latestDrawing }
        return document
    }

    func load() {
        do {
            let file: DrawingFile
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                file = try DrawingFile.decode(CoordinatedFile.read(url))
                if let path = file.pdf {
                    pdfURL = URL(filePath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                }
            } else if let pdfURL {
                var paper = Paper.defaultForNewDrawings
                paper.size = .pdf
                file = DrawingFile(paper: paper, pdf: pdfURL.lastPathComponent, pages: [])
            } else {
                throw CocoaError(.fileNoSuchFile)
            }

            let pdf = try pdfURL.map(PDFLoader.load)
            var paper = file.paper
            if let size = pdf?.page(at: 1)?.displaySize {
                paper.width = size.width
                paper.height = size.height
            }
            var resolved = file
            resolved.paper = paper
            document = EditorDocument(file: resolved, pdf: pdf)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func drawingChanged(_ drawing: PKDrawing) {
        latestDrawing = drawing
        markDirty()
    }

    func updatePaper(_ paper: Paper) {
        replaceDocument { $0.setPaper(paper) }
    }

    /// Appends a blank page. Existing pages don't move, so the canvas keeps its strokes and undo history.
    func addPage() {
        replaceDocument(reloadsCanvas: false) { $0.addPage() }
    }

    /// Removes a page and its ink. Taking a blank page off the end moves no ink, so the canvas
    /// keeps its strokes and undo history; anything else reloads it.
    func deletePage(at index: Int) {
        guard let document = currentDocument, document.canDeletePages, document.pageSizes.indices.contains(index) else { return }
        let movesInk = index < document.pageSizes.count - 1 || document.pageHasInk(at: index)
        replaceDocument(reloadsCanvas: movesInk) { $0.deletePage(at: index) }
    }

    private func replaceDocument(reloadsCanvas: Bool = true, _ change: (inout EditorDocument) -> Void) {
        guard var document = currentDocument else { return }
        change(&document)
        self.document = document
        latestDrawing = nil
        if reloadsCanvas { revision += 1 }
        markDirty()
    }

    private func markDirty() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard isDirty, !isDetached, let document = currentDocument else { return }
        do {
            let file = document.file(pdfPath: pdfURL.map { $0.relativePath(from: url.deletingLastPathComponent()) })
            try CoordinatedFile.write(try file.encoded(), to: url)
            isDirty = false
        } catch {
            state = .failed("Couldn't save: \(error.localizedDescription)")
        }
    }

    /// Follows a rename or move of the drawing, its PDF, or any folder containing them.
    func relocate(from source: URL, to destination: URL) {
        url = url.relocated(from: source, to: destination)
        pdfURL = pdfURL?.relocated(from: source, to: destination)
    }

    /// Stops writing once the file has been trashed, so autosave can't resurrect it.
    func detach(ifInside trashed: URL) {
        guard url.isInside(trashed) || pdfURL?.isInside(trashed) == true else { return }
        saveTask?.cancel()
        isDetached = true
    }
}
