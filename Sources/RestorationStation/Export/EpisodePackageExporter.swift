import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: LocalizedError, Equatable {
    case unreadableArtwork(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableArtwork(let name):
            "ATC Studio could not read the artwork \"\(name)\". Pick it again in the Templates tab."
        }
    }
}

/// Writes the episode folder next to `master_episode.mp3`:
/// `transcript.vtt`, `episode_info.txt`, and `artwork.jpg`, and tags `master_episode.mp3` with ID3v2.3 metadata.
/// Safe to run again after edits: files are replaced and the folder follows the title.
public enum EpisodePackageExporter {
    public static let masterName = "master_episode.mp3"
    public static let transcriptName = "transcript.vtt"
    public static let infoName = "episode_info.txt"
    public static let artworkName = "artwork.jpg"
    private static let tagXattrName = "com.rubiconetic.atcstudio.tags"

    private struct TagSignature: Codable, Equatable {
        var title: String
        var artist: String
        var date: String
        var comment: String
        var artworkSHA256: String?
    }

    /// Writes `package` into `folder` (which holds the master MP3), tags the MP3, then renames the folder to
    /// `YYYY-MM-DD_<Sanitized_Title>` if the title changed. Returns the folder's final URL.
    @discardableResult
    public static func export(_ package: EpisodePackage, artworkPath: String?, in folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let transcript = folder.appending(path: transcriptName)
        if package.analysis?.ranModels.contains(.voz) == true && !(package.analysis?.words.isEmpty ?? true) {
            try Data(package.webVTT.utf8).write(to: transcript, options: .atomic)
        } else {
            try? fm.removeItem(at: transcript)
        }
        try Data(package.episodeInfo.utf8).write(to: folder.appending(path: infoName), options: .atomic)
        if let artworkPath, !artworkPath.isEmpty {
            try writeJPEG(from: URL(filePath: artworkPath), to: folder.appending(path: artworkName))
        }

        try tagMaster(package, in: folder)

        let root = folder.deletingLastPathComponent()
        guard !ExportLocation.folder(folder, isNamedFor: package.title, date: package.date) else { return folder }
        let renamed = ExportLocation.newFolder(title: package.title, date: package.date, root: root)
        try fm.moveItem(at: folder, to: renamed)
        return renamed
    }

    /// Losslessly writes ID3v2.3 metadata and optional cover art into `master_episode.mp3`.
    /// Skips rewriting when the title, speakers, summary, date, and artwork have not changed since the last tag pass.
    public static func tagMaster(
        _ package: EpisodePackage,
        in folder: URL,
        ffmpeg: FFmpegRunner? = try? .locate()
    ) throws {
        let masterURL = folder.appending(path: masterName)
        guard let size = (try? masterURL.resourceValues(forKeys: [.fileSizeKey]).fileSize),
              size >= 128,
              let ffmpeg else { return }

        let artworkURL = folder.appending(path: artworkName)
        let artworkHash = (try? Data(contentsOf: artworkURL)).map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let signature = TagSignature(
            title: package.title,
            artist: package.speakerList.joined(separator: ", "),
            date: ExportLocation.dateString(package.date),
            comment: package.summary,
            artworkSHA256: artworkHash
        )

        if readTagSignature(from: masterURL) == signature {
            return
        }

        let tempURL = folder.appending(path: "master_episode.tagging.mp3")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let hasArtwork = artworkHash != nil
        var args = ["-loglevel", "error", "-i", masterURL.path]
        if hasArtwork {
            args += ["-i", artworkURL.path]
        }
        args += ["-map_metadata", "-1", "-map", "0:a:0"]
        if hasArtwork {
            args += ["-map", "1:v:0", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }
        args += [
            "-c:a", "copy",
            "-id3v2_version", "3",
            "-metadata", "title=\(signature.title)",
            "-metadata", "artist=\(signature.artist)",
            "-metadata", "date=\(signature.date)",
            "-metadata", "comment=\(signature.comment)",
            "-y", tempURL.path,
        ]

        try ffmpeg.runSync(args)
        _ = try FileManager.default.replaceItemAt(masterURL, withItemAt: tempURL)
        writeTagSignature(signature, to: masterURL)
    }

    private static func readTagSignature(from url: URL) -> TagSignature? {
        let path = url.path
        let length = getxattr(path, tagXattrName, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = Data(count: length)
        let read = buffer.withUnsafeMutableBytes { ptr in
            getxattr(path, tagXattrName, ptr.baseAddress, length, 0, 0)
        }
        guard read == length else { return nil }
        return try? JSONDecoder().decode(TagSignature.self, from: buffer)
    }

    private static func writeTagSignature(_ signature: TagSignature, to url: URL) {
        guard let data = try? JSONEncoder().encode(signature) else { return }
        _ = data.withUnsafeBytes { ptr in
            setxattr(url.path, tagXattrName, ptr.baseAddress, data.count, 0, 0)
        }
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
