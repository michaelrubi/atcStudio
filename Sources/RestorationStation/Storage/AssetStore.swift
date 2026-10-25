import Foundation

/// App-owned copies of template stems and artwork, so a template keeps working
/// when a volunteer moves or deletes the original file.
///
/// Each import lands in its own folder: `Assets/<UUID>/<original file name>`.
public struct AssetStore: Sendable {
    public let root: URL

    /// `~/Library/Application Support/ATCStudio/Assets`
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "ATCStudio", directoryHint: .isDirectory)
            .appending(path: "Assets", directoryHint: .isDirectory)
    }

    public init(root: URL = defaultRoot) {
        self.root = root.standardizedFileURL
    }

    /// Copies `source` into the store and returns the copy's path.
    /// A file already inside the store is returned as is.
    public func importFile(at source: URL) throws -> String {
        let source = source.standardizedFileURL
        if contains(source.path) { return source.path }

        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return destination.path
    }

    /// Deletes stored copies that no path in `referenced` points to.
    public func prune(keeping referenced: Set<String>) throws {
        let keep = Set(referenced.filter(contains).map { URL(filePath: $0).deletingLastPathComponent().lastPathComponent })
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    func contains(_ path: String) -> Bool {
        URL(filePath: path).standardizedFileURL.path.hasPrefix(root.path + "/")
    }
}

extension Template {
    /// Every stem and artwork path this template points to.
    public var assetPaths: [String] {
        [introMusicPath, introVoPath, outroMusicPath, outroVoPath, artworkPath].compactMap(\.self)
    }
}
