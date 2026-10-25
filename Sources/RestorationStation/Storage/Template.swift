import Foundation
import GRDB

/// A production template: bumper stems, artwork, vocabulary hints, and the mixing envelope.
public struct Template: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var name: String

    public var introMusicPath: String?
    public var introVoPath: String?
    public var outroMusicPath: String?
    public var outroVoPath: String?
    public var artworkPath: String?

    /// Comma-separated names and terms passed to `Voz` as vocabulary hints.
    public var customVocabulary: String

    // Mixing & auto-ducking envelope (seconds / dB).
    public var introLeadInSec: Double
    public var duckingDb: Double
    public var duckRampSec: Double
    public var introSwellDb: Double
    public var introSwellSec: Double
    public var crossfadeSec: Double
    public var outroUnderlapSec: Double
    public var outroFadeSec: Double

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        introMusicPath: String? = nil,
        introVoPath: String? = nil,
        outroMusicPath: String? = nil,
        outroVoPath: String? = nil,
        artworkPath: String? = nil,
        customVocabulary: String = "",
        introLeadInSec: Double = 3.0,
        duckingDb: Double = -14.0,
        duckRampSec: Double = 1.5,
        introSwellDb: Double = -6.0,
        introSwellSec: Double = 1.5,
        crossfadeSec: Double = 2.0,
        outroUnderlapSec: Double = 3.0,
        outroFadeSec: Double = 3.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.introMusicPath = introMusicPath
        self.introVoPath = introVoPath
        self.outroMusicPath = outroMusicPath
        self.outroVoPath = outroVoPath
        self.artworkPath = artworkPath
        self.customVocabulary = customVocabulary
        self.introLeadInSec = introLeadInSec
        self.duckingDb = duckingDb
        self.duckRampSec = duckRampSec
        self.introSwellDb = introSwellDb
        self.introSwellSec = introSwellSec
        self.crossfadeSec = crossfadeSec
        self.outroUnderlapSec = outroUnderlapSec
        self.outroFadeSec = outroFadeSec
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `customVocabulary` split on commas, trimmed, empties and duplicates removed.
    public var vocabularyTerms: [String] {
        var seen = Set<String>()
        return customVocabulary
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case introMusicPath = "intro_music_path"
        case introVoPath = "intro_vo_path"
        case outroMusicPath = "outro_music_path"
        case outroVoPath = "outro_vo_path"
        case artworkPath = "artwork_path"
        case customVocabulary = "custom_vocabulary"
        case introLeadInSec = "intro_lead_in_sec"
        case duckingDb = "ducking_db"
        case duckRampSec = "duck_ramp_sec"
        case introSwellDb = "intro_swell_db"
        case introSwellSec = "intro_swell_sec"
        case crossfadeSec = "crossfade_sec"
        case outroUnderlapSec = "outro_underlap_sec"
        case outroFadeSec = "outro_fade_sec"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension Template: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "templates"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
