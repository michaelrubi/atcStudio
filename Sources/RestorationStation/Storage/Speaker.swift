import Foundation
import GRDB

/// A saved host, pastor, or guest. Names are unique, ignoring case.
public struct Speaker: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    public var role: String
    public var lastUsedAt: Date?

    public init(id: Int64? = nil, name: String, role: String = "", lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role
        case lastUsedAt = "last_used_at"
    }
}

extension Speaker: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "speakers"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
