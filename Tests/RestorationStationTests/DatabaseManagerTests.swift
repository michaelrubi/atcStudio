import Foundation
import Testing
@testable import RestorationStation

@Suite struct DatabaseManagerTests {
    let db: DatabaseManager

    init() throws {
        db = try DatabaseManager.inMemory()
    }

    @Test func seedsDefaultTemplates() throws {
        let templates = try db.templates()
        #expect(templates.map(\.name) == ["As The Church Podcast", "Sunday Sermon"])
        let sermon = try #require(templates.first { $0.name == "Sunday Sermon" })
        #expect(sermon.introLeadInSec == 3.0)
        #expect(sermon.duckingDb == -14.0)
        #expect(sermon.crossfadeSec == 2.0)
        #expect(sermon.vocabularyTerms.contains("Selah"))
    }

    @Test func migrationIsIdempotentOnDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "atc-\(UUID().uuidString)/atc_studio.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try DatabaseManager.open(at: url)
        let reopened = try DatabaseManager.open(at: url)
        #expect(try reopened.templates().count == 2)
    }

    @Test func savesAndUpdatesTemplate() throws {
        var template = try db.save(Template(name: "  Midweek Podcast ", introMusicPath: "/tmp/intro.wav"))
        #expect(template.id != nil)
        #expect(template.name == "Midweek Podcast")

        template.duckingDb = -18
        try db.save(template)
        let fetched = try #require(try db.templates().first { $0.id == template.id })
        #expect(fetched.duckingDb == -18)
        #expect(fetched.introMusicPath == "/tmp/intro.wav")
    }

    @Test func rejectsDuplicateTemplateNameIgnoringCase() throws {
        #expect(throws: DatabaseManagerError.duplicateName("sunday sermon")) {
            try db.save(Template(name: "sunday sermon"))
        }
    }

    @Test func deletesTemplate() throws {
        let template = try db.save(Template(name: "Temp"))
        try db.deleteTemplate(id: try #require(template.id))
        #expect(try db.templates().count == 2)
    }

    @Test func vocabularyTermsTrimAndDeduplicate() {
        let template = Template(name: "x", customVocabulary: " Selah, ,selah,  Pastor John ,\nATC")
        #expect(template.vocabularyTerms == ["Selah", "Pastor John", "ATC"])
    }

    @Test func upsertSpeakerCreatesThenReuses() throws {
        let first = try db.upsertSpeaker(named: " Pastor John ", role: "Lead Pastor")
        let second = try db.upsertSpeaker(named: "pastor john")
        #expect(first.id == second.id)
        #expect(second.name == "Pastor John")
        #expect(second.role == "Lead Pastor")
        #expect(try db.speakers().count == 1)
    }

    @Test func speakersSortRecentlyUsedFirst() throws {
        try db.save(Speaker(name: "Aaron"))
        try db.upsertSpeaker(named: "Zoe", usedAt: Date(timeIntervalSince1970: 100))
        try db.upsertSpeaker(named: "Mia", usedAt: Date(timeIntervalSince1970: 200))
        #expect(try db.speakers().map(\.name) == ["Mia", "Zoe", "Aaron"])
    }

    @Test func editsAndDeletesSpeaker() throws {
        var speaker = try db.save(Speaker(name: "Guest", role: "Guest"))
        speaker.name = "Guest Speaker"
        try db.save(speaker)
        #expect(try db.speakers().map(\.name) == ["Guest Speaker"])
        try db.deleteSpeaker(id: try #require(speaker.id))
        #expect(try db.speakers().isEmpty)
    }

    @Test func rejectsEmptyNames() {
        #expect(throws: DatabaseManagerError.emptyName) { try db.save(Speaker(name: "   ")) }
        #expect(throws: DatabaseManagerError.emptyName) { try db.upsertSpeaker(named: "") }
    }
}
