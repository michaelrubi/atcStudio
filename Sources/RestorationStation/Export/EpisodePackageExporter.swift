import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: LocalizedError, Equatable {
    case unreadableArtwork(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableArtwork(let name):
            "Restoration Station could not read the artwork \"\(name)\". Pick it again in the Templates tab."
        }
    }
}

/// Writes the episode folder next to `master_episode.mp3`:
/// `transcript.vtt`, `episode_info.txt`, and `artwork.jpg`.
/// Safe to run again after edits: files are replaced and the folder follows the title.
public enum EpisodePackageExporter {
    public static let masterName = "master_episode.mp3"
    public static let transcriptName = "transcript.vtt"
    public static let infoName = "episode_info.txt"
    public static let artworkName = "artwork.jpg"

    /// Writes `package` into `folder` (which holds the master MP3), then renames the folder to
    /// `YYYY-MM-DD_<Sanitized_Title>` if the title changed. Returns the folder's final URL.
    @discardableResult
    public static func export(_ package: EpisodePackage, artworkPath: String?, in folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let transcript = folder.appending(path: transcriptName)
        if package.analysis != nil {
            try Data(package.webVTT.utf8).write(to: transcript, options: .atomic)
        } else {
            try? fm.removeItem(at: transcript)
        }
        try Data(package.episodeInfo.utf8).write(to: folder.appending(path: infoName), options: .atomic)
        if let artworkPath, !artworkPath.isEmpty {
            try writeJPEG(from: URL(filePath: artworkPath), to: folder.appending(path: artworkName))
        }

        let root = folder.deletingLastPathComponent()
        guard !ExportLocation.folder(folder, isNamedFor: package.title, date: package.date) else { return folder }
        let renamed = ExportLocation.newFolder(title: package.title, date: package.date, root: root)
        try fm.moveItem(at: folder, to: renamed)
        return renamed
    }

    /// Copies a JPEG as is; converts PNG, HEIC, and the rest to JPEG.
    static func writeJPEG(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: source.pathExtension)
        if type?.conforms(to: .jpeg) == true {
            try fm.copyItem(at: source, to: destination)
            return
        }
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(image) > 0,
              let out = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ExportError.unreadableArtwork(source.lastPathComponent) }
        CGImageDestinationAddImageFromSource(out, image, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw ExportError.unreadableArtwork(source.lastPathComponent) }
    }
}
