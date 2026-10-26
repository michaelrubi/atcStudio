import Foundation

/// `~/Movies/ATC Studio Exports/YYYY-MM-DD_<Sanitized_Title>/`
public enum ExportLocation {
    public static var root: URL {
        URL.moviesDirectory.appending(path: "ATC Studio Exports", directoryHint: .isDirectory)
    }

    /// A folder for this run that does not exist yet. Adds `_2`, `_3`, … rather than overwrite.
    public static func newFolder(title: String, date: Date = Date(), root: URL = root) -> URL {
        let base = baseName(title: title, date: date)
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: root.appending(path: name).path) {
            name = "\(base)_\(n)"
            n += 1
        }
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    /// True when `folder` is already `YYYY-MM-DD_<title>` or `YYYY-MM-DD_<title>_N`.
    public static func folder(_ folder: URL, isNamedFor title: String, date: Date) -> Bool {
        let base = baseName(title: title, date: date)
        let name = folder.lastPathComponent
        if name == base { return true }
        guard name.hasPrefix(base + "_") else { return false }
        return Int(name.dropFirst(base.count + 1)).map { $0 >= 2 } ?? false
    }

    public static func dateString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date) // local day, not UTC
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func baseName(title: String, date: Date) -> String {
        "\(dateString(date))_\(sanitize(title))"
    }

    /// Letters and digits kept, everything else becomes `_`, runs collapsed, max 60 characters.
    public static func sanitize(_ title: String) -> String {
        let mapped = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let collapsed = String(mapped)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        let trimmed = String(collapsed.prefix(60))
        return trimmed.isEmpty ? "Episode" : trimmed
    }
}
