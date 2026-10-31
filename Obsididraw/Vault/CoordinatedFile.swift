import Foundation

/// File operations wrapped in `NSFileCoordinator`, so we play nicely with iCloud Drive,
/// Obsidian Sync, and other apps touching the vault at the same time.
nonisolated enum CoordinatedFile {
    static func read(_ url: URL) throws -> Data {
        try coordinate { coordinator, error, result in
            coordinator.coordinate(readingItemAt: url, options: [], error: error) { url in
                result = Result { try Data(contentsOf: url) }
            }
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        try coordinate { coordinator, error, result in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: error) { url in
                result = Result { try data.write(to: url, options: .atomic) }
            }
        }
    }

    static func createDirectory(_ url: URL) throws {
        try coordinate { coordinator, error, result in
            coordinator.coordinate(writingItemAt: url, options: [], error: error) { url in
                result = Result { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            }
        }
    }

    static func move(_ source: URL, to destination: URL) throws {
        try coordinate { coordinator, error, result in
            coordinator.coordinate(
                writingItemAt: source, options: .forMoving,
                writingItemAt: destination, options: .forReplacing,
                error: error
            ) { source, destination in
                result = Result {
                    try FileManager.default.moveItem(at: source, to: destination)
                    coordinator.item(at: source, didMoveTo: destination)
                }
            }
        }
    }

    private static func coordinate<T>(
        _ body: (NSFileCoordinator, NSErrorPointer, inout Result<T, Error>?) -> Void
    ) throws -> T {
        var error: NSError?
        var result: Result<T, Error>?
        body(NSFileCoordinator(), &error, &result)
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
