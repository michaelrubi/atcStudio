import Align
import Clear
import DesertAnt
import Foundation
import Title
import Uhm
import Voz
import Who

/// The six Desert Ant Labs models Restoration Station uses.
/// Each downloads once into the SDK's cache and then works offline.
public enum PipelineModel: String, CaseIterable, Identifiable, Sendable, Codable {
    case clear, voz, who, align, uhm, title

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .clear: "Clear"
        case .voz: "Voz"
        case .who: "Who"
        case .align: "Align"
        case .uhm: "Uhm"
        case .title: "Title"
        }
    }

    public var purpose: String {
        switch self {
        case .clear: "Removes HVAC rumble, room echo, and mic hiss"
        case .voz: "Writes the transcript"
        case .who: "Finds who is speaking when"
        case .align: "Lines up each word with the audio"
        case .uhm: "Finds filler words and long pauses"
        case .title: "Suggests titles and a summary"
        }
    }

    public var isDownloaded: Bool {
        switch self {
        case .clear: Clear.isDownloaded()
        case .voz: Voz.isDownloaded()
        case .who: Who.isDownloaded()
        case .align: Align().isDownloaded()
        case .uhm: Uhm.isDownloaded()
        case .title: TitleModel.isAvailable()
        }
    }

    public static var allDownloaded: Bool { allCases.allSatisfy(\.isDownloaded) }

    /// Normalizes a selection by resolving model dependencies (e.g. Align and Title require Voz).
    public static func normalized(_ selection: Set<PipelineModel>) -> Set<PipelineModel> {
        var result = selection
        if !result.contains(.voz) {
            result.remove(.align)
            result.remove(.title)
        }
        return result
    }

    /// Default selection with all available models.
    public static let defaultSelection: Set<PipelineModel> = Set(allCases)

    /// Essential speech cleanup and transcript preset.
    public static let cleanAndTranscript: Set<PipelineModel> = [.clear, .voz, .who, .align]

    /// Clean sanctuary audio only (bypass all speech/text models).
    public static let audioOnly: Set<PipelineModel> = [.clear]

    /// Downloads the model if needed (a no-op when it is already there). `progress` is 0...1.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        switch self {
        case .clear: try await Clear().download(progress: progress)
        case .voz: try await Voz.download { progress($0.fraction) }
        case .who: try await Who().download(progress: progress)
        case .align: try await Align().download(progress: progress)
        case .uhm: try await Uhm().download(progress: progress)
        case .title: _ = try await TitleModel.resolve { progress($0.fraction) }
        }
        progress(1)
    }

    /// Folder holding the Title model's MLX files (download first).
    static func titleDirectory() async throws -> URL {
        URL(filePath: try await TitleModel.resolve().rootPath)
    }
}
