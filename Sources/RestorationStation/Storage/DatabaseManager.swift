import Foundation
import GRDB

public enum DatabaseManagerError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Please type a name."
        case .duplicateName(let name): "\"\(name)\" already exists. Pick a different name."
        }
    }
}

/// Owns the SQLite database and every read and write the app makes to it.
public final class DatabaseManager: Sendable {
    public let writer: any DatabaseWriter

    /// `~/Library/Application Support/ATCStudio/atc_studio.sqlite`
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "ATCStudio", directoryHint: .isDirectory)
            .appending(path: "atc_studio.sqlite")
    }

    /// Opens (and migrates) the database at `url`.
    public static func open(at url: URL = defaultURL) throws -> DatabaseManager {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try DatabaseManager(writer: DatabasePool(path: url.path))
    }

    /// An in-memory database, for tests and previews.
    public static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "templates") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique(onConflict: .abort).collate(.nocase)
                t.column("intro_music_path", .text)
                t.column("intro_vo_path", .text)
                t.column("outro_music_path", .text)
                t.column("outro_vo_path", .text)
                t.column("artwork_path", .text)
                t.column("custom_vocabulary", .text).notNull().defaults(to: "")
                t.column("intro_lead_in_sec", .double).notNull().defaults(to: 3.0)
                t.column("ducking_db", .double).notNull().defaults(to: -14.0)
                t.column("duck_ramp_sec", .double).notNull().defaults(to: 1.5)
                t.column("intro_swell_db", .double).notNull().defaults(to: -6.0)
                t.column("intro_swell_sec", .double).notNull().defaults(to: 1.5)
                t.column("crossfade_sec", .double).notNull().defaults(to: 2.0)
                t.column("outro_underlap_sec", .double).notNull().defaults(to: 3.0)
                t.column("outro_fade_sec", .double).notNull().defaults(to: 3.0)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "speakers") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique(onConflict: .abort).collate(.nocase)
                t.column("role", .text).notNull().defaults(to: "")
                t.column("last_used_at", .datetime)
            }
        }

        // Plain SQL, so this migration keeps working when `Template` gains fields later.
        migrator.registerMigration("v1_seed_templates") { db in
            let now = Date()
            try db.execute(literal: """
                INSERT INTO templates (name, custom_vocabulary, created_at, updated_at)
                VALUES ('Sunday Sermon',
                        'As The Church, ATC, Hallelujah, Selah, Yahweh, Gethsemane, Ecclesiastes',
                        \(now), \(now))
                """)
            try db.execute(literal: """
                INSERT INTO templates (name, custom_vocabulary, created_at, updated_at)
                VALUES ('As The Church Podcast', 'As The Church, ATC, As The Church Podcast', \(now), \(now))
                """)
        }

        return migrator
    }

    // MARK: - Templates

    public func templates() throws -> [Template] {
        try writer.read { db in
            try Template.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }
    }

    /// Inserts a new template or updates an existing one. Returns the saved row.
    @discardableResult
    public func save(_ template: Template) throws -> Template {
        var template = template
        template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.name.isEmpty else { throw DatabaseManagerError.emptyName }
        template.updatedAt = Date()
        do {
            return try writer.write { db in
                try template.save(db)
                return template
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw DatabaseManagerError.duplicateName(template.name)
        }
    }

    public func deleteTemplate(id: Int64) throws {
        _ = try writer.write { db in try Template.deleteOne(db, key: id) }
    }

    // MARK: - Speakers

    /// All speakers, most recently used first, then by name.
    public func speakers() throws -> [Speaker] {
        try writer.read { db in
            try Speaker.order(
                Column("last_used_at").desc,
                Column("name").collating(.localizedCaseInsensitiveCompare)
            ).fetchAll(db)
        }
    }

    /// Inserts a new speaker or updates an existing one. Returns the saved row.
    @discardableResult
    public func save(_ speaker: Speaker) throws -> Speaker {
        var speaker = speaker
        speaker.name = speaker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        speaker.role = speaker.role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speaker.name.isEmpty else { throw DatabaseManagerError.emptyName }
        do {
            return try writer.write { db in
                try speaker.save(db)
                return speaker
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw DatabaseManagerError.duplicateName(speaker.name)
        }
    }

    /// Finds a speaker by name (ignoring case) and marks them as used now,
    /// or creates them. Used when a new name is typed in the Speaker Mapping view.
    @discardableResult
    public func upsertSpeaker(named rawName: String, role: String? = nil, usedAt: Date = Date()) throws -> Speaker {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DatabaseManagerError.emptyName }
        return try writer.write { db in
            var speaker = try Speaker.filter(Column("name") == name).fetchOne(db)
                ?? Speaker(name: name)
            if let role, !role.isEmpty { speaker.role = role }
            speaker.lastUsedAt = usedAt
            try speaker.save(db)
            return speaker
        }
    }

    public func deleteSpeaker(id: Int64) throws {
        _ = try writer.write { db in try Speaker.deleteOne(db, key: id) }
    }
}
