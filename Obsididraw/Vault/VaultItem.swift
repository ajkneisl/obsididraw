import Foundation

nonisolated struct VaultItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case folder, drawing, pdf, markdown, other
    }

    let url: URL
    let kind: Kind
    /// For PDFs: whether a companion drawing (`Name.pdf.draw`) holds annotations for it.
    var isAnnotated = false
    /// Non-nil for folders (even empty ones, so they stay expandable); nil for files.
    var children: [VaultItem]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var displayName: String {
        switch kind {
        case .folder, .pdf, .other: name
        case .drawing, .markdown: url.deletingPathExtension().lastPathComponent
        }
    }
    var isOpenable: Bool { kind == .drawing || kind == .pdf }

    var systemImage: String {
        switch kind {
        case .folder: "folder"
        case .drawing: "pencil.and.scribble"
        case .pdf: isAnnotated ? "doc.richtext.fill" : "doc.richtext"
        case .markdown: "doc.text"
        case .other: "doc"
        }
    }

    /// The companion drawing that stores annotations for a PDF.
    static func annotationURL(forPDF pdf: URL) -> URL {
        pdf.appendingPathExtension(DrawingFile.fileExtension)
    }
}

nonisolated enum VaultScanner {
    /// Recursively lists `directory`, skipping hidden entries such as `.obsidian` and `.trash`.
    /// Files are limited to drawings and PDFs unless `includeAllFiles` is set.
    static func scan(_ directory: URL, includeAllFiles: Bool) -> [VaultItem] {
        let fm = FileManager.default
        guard let rawNames = try? fm.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return [] }

        // iCloud stores not-yet-downloaded files as `.Name.ext.icloud`; a coordinated read of
        // the real name downloads them.
        let entries: [(name: String, raw: String)] = rawNames.compactMap { raw in
            var name = raw
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            return name.hasPrefix(".") ? nil : (name, raw)
        }
        let names = Set(entries.map(\.name))
        let drawingSuffix = ".pdf." + DrawingFile.fileExtension

        var items: [VaultItem] = []
        for (name, raw) in entries {
            let url = directory.appending(path: name)
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: directory.appending(path: raw).path(percentEncoded: false), isDirectory: &isDirectory)

            if isDirectory.boolValue {
                items.append(VaultItem(url: url, kind: .folder, children: scan(url, includeAllFiles: includeAllFiles)))
                continue
            }

            let kind: VaultItem.Kind = switch url.pathExtension.lowercased() {
            case DrawingFile.fileExtension: .drawing
            case "pdf": .pdf
            case "md": .markdown
            default: .other
            }
            // A PDF's annotations are reached through the PDF itself.
            if kind == .drawing, name.lowercased().hasSuffix(drawingSuffix), names.contains(String(name.dropLast(DrawingFile.fileExtension.count + 1))) {
                continue
            }
            if kind == .drawing || kind == .pdf || includeAllFiles {
                let isAnnotated = kind == .pdf && names.contains(VaultItem.annotationURL(forPDF: url).lastPathComponent)
                items.append(VaultItem(url: url, kind: kind, isAnnotated: isAnnotated))
            }
        }

        return items.sorted { a, b in
            if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
