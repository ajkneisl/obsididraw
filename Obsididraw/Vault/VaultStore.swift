import Foundation
import Observation

/// Owns access to the user's Obsidian vault folder and every file-system mutation made in it.
@Observable
final class VaultStore {
    private(set) var rootURL: URL?
    private(set) var tree: [VaultItem] = []
    var includeAllFiles = UserDefaults.standard.bool(forKey: Keys.includeAllFiles) {
        didSet {
            UserDefaults.standard.set(includeAllFiles, forKey: Keys.includeAllFiles)
            Task { await refresh() }
        }
    }

    /// The drawing currently open in the editor, so moves and deletes can flush and retarget it.
    @ObservationIgnored weak var activeSession: DrawingSession?

    private enum Keys {
        static let bookmark = "vaultBookmark"
        static let includeAllFiles = "includeAllFiles"
    }

    #if targetEnvironment(macCatalyst)
    private static let bookmarkCreation: URL.BookmarkCreationOptions = .withSecurityScope
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let bookmarkCreation: URL.BookmarkCreationOptions = []
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    #endif

    init() {
        restoreBookmark()
    }

    /// Obsidian names a vault after its folder.
    var vaultName: String { rootURL?.lastPathComponent ?? "Obsididraw" }

    // MARK: Vault selection

    func open(_ url: URL) throws {
        close()
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        let bookmark = try url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Keys.bookmark)
        rootURL = url
        Task { await refresh() }
    }

    func close() {
        activeSession?.saveNow()
        rootURL?.stopAccessingSecurityScopedResource()
        rootURL = nil
        tree = []
        UserDefaults.standard.removeObject(forKey: Keys.bookmark)
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmark) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.bookmarkResolution, relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else { return }
        if isStale, let fresh = try? url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Keys.bookmark)
        }
        rootURL = url
        Task { await refresh() }
    }

    func refresh() async {
        guard let rootURL else { return }
        let includeAllFiles = includeAllFiles
        let tree = await Task.detached { VaultScanner.scan(rootURL, includeAllFiles: includeAllFiles) }.value
        if self.rootURL == rootURL { self.tree = tree }
    }

    // MARK: Obsidian

    /// Vault-relative path, e.g. `Sketches/Idea.draw`.
    func vaultPath(for url: URL) -> String {
        guard let rootURL, url.isInside(rootURL) else { return url.lastPathComponent }
        return url.relativePath(from: rootURL)
    }

    /// Wiki-link embed for a file, e.g. `![[Sketches/Idea.draw]]`.
    func embedLink(for url: URL) -> String {
        "![[\(vaultPath(for: url))]]"
    }

    /// An `obsidian://open` link that shows the file in Obsidian.
    func obsidianURL(for url: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return URL(string: "obsidian://open?vault=\(encode(vaultName))&file=\(encode(vaultPath(for: url)))")
    }

    /// Resolves an `obsididraw://open?vault=<name>&file=<vault path>` link, as sent by the Obsidian
    /// plugin, to a file in the open vault.
    func fileURL(forOpenLink link: URL) throws -> URL {
        guard link.scheme == "obsididraw", link.host() == "open",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "file" })?.value, !path.isEmpty
        else { throw OpenLinkError.invalid }
        guard let rootURL else { throw OpenLinkError.noVault }
        if let vault = items.first(where: { $0.name == "vault" })?.value, vault != vaultName {
            throw OpenLinkError.otherVault(requested: vault, open: vaultName)
        }

        let url = rootURL.appending(path: path)
        guard url.isInside(rootURL) else { throw OpenLinkError.invalid }
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) || fm.fileExists(atPath: placeholder.path(percentEncoded: false)) else {
            throw OpenLinkError.notFound(path)
        }
        return url
    }

    enum OpenLinkError: LocalizedError {
        case invalid, noVault
        case otherVault(requested: String, open: String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .invalid: "This link isn't a valid Obsididraw link."
            case .noVault: "Open your Obsidian vault in Obsididraw first."
            case .otherVault(let requested, let open): "This drawing is in the vault “\(requested)”, but Obsididraw has “\(open)” open. Use Switch Vault to open it."
            case .notFound(let path): "“\(path)” isn't in this vault yet. If you just created it, wait for it to sync and try again."
            }
        }
    }

    // MARK: Mutations

    @discardableResult
    func createDrawing(in folder: URL) async throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = uniqueURL(in: folder, base: "Drawing \(formatter.string(from: .now))", ext: DrawingFile.fileExtension)
        try CoordinatedFile.write(try DrawingFile.blank(paper: .defaultForNewDrawings).encoded(), to: url)
        await refresh()
        return url
    }

    @discardableResult
    func createFolder(named name: String, in folder: URL) async throws -> URL {
        let url = uniqueURL(in: folder, base: try Self.sanitized(name), ext: nil)
        try CoordinatedFile.createDirectory(url)
        await refresh()
        return url
    }

    /// Renames a file or folder in place, keeping its extension. A PDF's annotations follow it.
    /// Returns the new URL.
    func rename(_ item: VaultItem, to name: String) async throws -> URL {
        let base = try Self.sanitized(name)
        let ext = item.kind == .folder ? nil : item.url.pathExtension
        let destination = item.url.deletingLastPathComponent().appending(path: ext.map { "\(base).\($0)" } ?? base)
        guard destination != item.url else { return item.url }
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw VaultError.nameTaken(destination.lastPathComponent)
        }
        try move(item.url, to: destination)

        if item.kind == .pdf {
            let oldAnnotations = VaultItem.annotationURL(forPDF: item.url)
            if FileManager.default.fileExists(atPath: oldAnnotations.path(percentEncoded: false)) {
                let newAnnotations = VaultItem.annotationURL(forPDF: destination)
                try move(oldAnnotations, to: newAnnotations)
                // Point the annotations at the renamed PDF.
                var file = try DrawingFile.decode(CoordinatedFile.read(newAnnotations))
                file.pdf = destination.lastPathComponent
                try CoordinatedFile.write(try file.encoded(), to: newAnnotations)
            } else {
                // Nothing drawn yet, but the open editor must create its file under the new name.
                activeSession?.relocate(from: oldAnnotations, to: VaultItem.annotationURL(forPDF: destination))
            }
        }
        await refresh()
        return destination
    }

    /// Moves an item into the vault's `.trash` folder, matching Obsidian's "Move to Obsidian trash".
    /// A PDF's annotations go with it.
    func trash(_ item: VaultItem) async throws {
        guard let rootURL else { return }
        let trash = rootURL.appending(path: ".trash")
        try CoordinatedFile.createDirectory(trash)

        var urls = [item.url]
        if item.kind == .pdf, item.isAnnotated { urls.append(VaultItem.annotationURL(forPDF: item.url)) }
        for url in urls {
            activeSession?.detach(ifInside: url)
            let isFolder = url == item.url && item.kind == .folder
            let ext = isFolder ? nil : url.pathExtension
            let base = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            try move(url, to: uniqueURL(in: trash, base: base, ext: ext))
        }
        await refresh()
    }

    private func move(_ source: URL, to destination: URL) throws {
        activeSession?.saveNow()
        try CoordinatedFile.move(source, to: destination)
        activeSession?.relocate(from: source, to: destination)
    }

    private func uniqueURL(in folder: URL, base: String, ext: String?) -> URL {
        let fm = FileManager.default
        for n in 0... {
            let name = n == 0 ? base : "\(base) \(n)"
            let url = folder.appending(path: ext.map { "\(name).\($0)" } ?? name)
            if !fm.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        fatalError("unreachable")
    }

    /// Strips characters that are invalid in file names or break Obsidian wiki-links.
    static func sanitized(_ name: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|#^[]")
        let cleaned = name.unicodeScalars.filter { !forbidden.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, !result.hasPrefix(".") else { throw VaultError.invalidName }
        return result
    }

    enum VaultError: LocalizedError {
        case invalidName
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a name that doesn't start with a period."
            case .nameTaken(let name): "“\(name)” already exists here."
            }
        }
    }
}

nonisolated extension URL {
    /// True if `self` is `other` or lies somewhere inside it.
    func isInside(_ other: URL) -> Bool {
        standardizedFileURL.pathComponents.starts(with: other.standardizedFileURL.pathComponents)
    }

    /// `self` after `source` (itself or a folder containing it) moved to `destination`.
    func relocated(from source: URL, to destination: URL) -> URL {
        guard isInside(source) else { return self }
        let suffix = standardizedFileURL.pathComponents.dropFirst(source.standardizedFileURL.pathComponents.count)
        return suffix.reduce(destination) { $0.appending(path: $1) }
    }

    /// A `/`-separated path from `directory` to `self`, using `..` where needed.
    func relativePath(from directory: URL) -> String {
        let target = standardizedFileURL.pathComponents
        let base = directory.standardizedFileURL.pathComponents
        let common = zip(target, base).prefix { $0 == $1 }.count
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + target.dropFirst(common)).joined(separator: "/")
    }
}
