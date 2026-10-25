import Foundation
import Observation
import RestorationStation

/// Main-actor view of the SQLite data. Views read `templates` / `speakers`
/// and call the methods below; every write reloads the lists.
@MainActor @Observable
final class Library {
    let database: DatabaseManager
    let assets: AssetStore
    private(set) var templates: [Template] = []
    private(set) var speakers: [Speaker] = []

    private(set) static var loadError: String?

    static func load() -> Library? {
        do {
            return try Library(database: .open(), assets: AssetStore())
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    init(database: DatabaseManager, assets: AssetStore) throws {
        self.database = database
        self.assets = assets
        try reload()
    }

    func reload() throws {
        templates = try database.templates()
        speakers = try database.speakers()
    }

    @discardableResult
    func save(_ template: Template) throws -> Template {
        defer { reloadAndPruneAssets() }
        return try database.save(template)
    }

    func deleteTemplate(_ template: Template) throws {
        guard let id = template.id else { return }
        try database.deleteTemplate(id: id)
        reloadAndPruneAssets()
    }

    /// Copies a picked stem or artwork file into the app's Assets folder. Returns the copy's path.
    func importAsset(at url: URL) throws -> String {
        try assets.importFile(at: url)
    }

    /// Removes asset copies that no saved template uses any more
    /// (replaced, cleared, or from a deleted template).
    private func reloadAndPruneAssets() {
        try? reload()
        try? assets.prune(keeping: Set(templates.flatMap(\.assetPaths)))
    }

    @discardableResult
    func save(_ speaker: Speaker) throws -> Speaker {
        defer { try? reload() }
        return try database.save(speaker)
    }

    func deleteSpeaker(_ speaker: Speaker) throws {
        guard let id = speaker.id else { return }
        try database.deleteSpeaker(id: id)
        try reload()
    }

    /// A template name that isn't taken yet: "New Template", "New Template 2", ...
    func unusedTemplateName(base: String = "New Template") -> String {
        let taken = Set(templates.map { $0.name.lowercased() })
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }
}
