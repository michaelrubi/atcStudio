import Foundation

/// Whether a PodBean episode should be saved as a draft or published immediately.
public enum PublishStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case draft = "draft"
    case publish = "publish"

    public var label: String {
        switch self {
        case .draft: "Draft"
        case .publish: "Publish Now"
        }
    }
}

/// Progress update emitted during an episode upload and publish flow.
public struct PublishProgress: Sendable, Equatable {
    public var message: String
    /// Overall progress in `0...1`.
    public var fraction: Double

    public init(message: String, fraction: Double) {
        self.message = message
        self.fraction = fraction
    }
}

/// Persisted result of publishing an episode to PodBean, stored as `publish.json` in the episode folder.
public struct PublishResult: Codable, Sendable, Equatable {
    public static let recordFileName = "publish.json"

    public var episodeID: String
    public var permalinkURL: URL?
    public var status: PublishStatus
    public var publishedAt: Date
    public var skippedArtworkReason: String?

    public init(
        episodeID: String,
        permalinkURL: URL? = nil,
        status: PublishStatus,
        publishedAt: Date = Date(),
        skippedArtworkReason: String? = nil
    ) {
        self.episodeID = episodeID
        self.permalinkURL = permalinkURL
        self.status = status
        self.publishedAt = publishedAt
        self.skippedArtworkReason = skippedArtworkReason
    }

    /// Reads `publish.json` from `folder` if present.
    public static func load(from folder: URL) -> PublishResult? {
        let url = folder.appending(path: recordFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PublishResult.self, from: data)
    }

    /// Writes `publish.json` into `folder` atomically.
    public func save(in folder: URL) throws {
        let url = folder.appending(path: Self.recordFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

/// Information about the connected PodBean podcast returned by `/v1/podcast`.
public struct PodcastAccountInfo: Sendable, Equatable {
    public var podcastTitle: String
    public var podcastURL: URL?

    public init(podcastTitle: String, podcastURL: URL? = nil) {
        self.podcastTitle = podcastTitle
        self.podcastURL = podcastURL
    }
}
