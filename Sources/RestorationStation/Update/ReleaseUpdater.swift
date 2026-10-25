import Foundation

/// Information about a published GitHub release of ATC Studio.
public struct ReleaseInfo: Sendable, Codable, Equatable {
    public var tagName: String
    public var version: String
    public var title: String
    public var notes: String
    public var publishedAt: Date?
    public var htmlURL: URL
    public var dmgAsset: Asset?

    public struct Asset: Sendable, Codable, Equatable {
        public var name: String
        public var downloadURL: URL
        public var size: Int64

        public init(name: String, downloadURL: URL, size: Int64) {
            self.name = name
            self.downloadURL = downloadURL
            self.size = size
        }
    }

    public init(
        tagName: String,
        version: String,
        title: String,
        notes: String,
        publishedAt: Date? = nil,
        htmlURL: URL,
        dmgAsset: Asset? = nil
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.notes = notes
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
        self.dmgAsset = dmgAsset
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case invalidResponse(Int)
    case missingDMGAsset
    case downloadFailed(String)
    case mountFailed(String)
    case appBundleNotFoundInDMG
    case signatureVerificationFailed(String)
    case bundleIdentifierMismatch(String)
    case installationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let code):
            "GitHub returned an unexpected status code (\(code))."
        case .missingDMGAsset:
            "This release does not contain a downloadable macOS disk image (.dmg)."
        case .downloadFailed(let detail):
            "Could not download the update: \(detail)"
        case .mountFailed(let detail):
            "Could not open the downloaded disk image: \(detail)"
        case .appBundleNotFoundInDMG:
            "Could not find ATC Studio.app inside the downloaded disk image."
        case .signatureVerificationFailed(let detail):
            "The downloaded app did not pass macOS code-signature verification: \(detail)"
        case .bundleIdentifierMismatch(let found):
            "The downloaded app has an unexpected bundle identifier (\(found))."
        case .installationFailed(let detail):
            "Could not install the update: \(detail)"
        }
    }
}

/// Checks GitHub Releases for newer versions and downloads/verifies DMG updates.
public enum ReleaseUpdater {
    public static let repositoryOwner = "michaelrubi"
    public static let repositoryName = "atcStudio"
    public static let expectedBundleIdentifier = "com.rubiconetic.atcstudio"

    public static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
    }

    public static var releasesWebURL: URL {
        URL(string: "https://github.com/\(repositoryOwner)/\(repositoryName)/releases")!
    }

    /// Current bundle version (e.g. "1.0.0"), or "0.0.0" when running unbundled (`swift run`).
    public static func currentAppVersion(bundle: Bundle = .main) -> String {
        let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return normalizeVersion(raw)
    }

    /// True when running from a packaged `.app` bundle with a real release version.
    public static func isPackagedReleaseApp(bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "app" && currentAppVersion(bundle: bundle) != "0.0.0"
    }

    /// Strips a leading "v" or "V" and surrounding whitespace.
    public static func normalizeVersion(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        return trimmed.isEmpty ? "0.0.0" : trimmed
    }

    /// Returns true when `candidate` is strictly newer than `current` using semantic version rules.
    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = parseVersion(candidate)
        let rhs = parseVersion(current)
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for i in 0..<count {
            let a = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let b = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if a != b { return a > b }
        }
        // A stable release (no prerelease suffix) is newer than a prerelease of the same version.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (.some(let a), .some(let b)):
            return a.localizedStandardCompare(b) == .orderedDescending
        case (nil, nil):
            return false
        }
    }

    private static func parseVersion(_ version: String) -> (numbers: [Int], prerelease: String?) {
        let clean = normalizeVersion(version)
        let parts = clean.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts.first.map(String.init) ?? clean
        let prerelease = parts.count > 1 ? String(parts[1]) : nil
        let numbers = core.split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, prerelease)
    }

    // MARK: - GitHub API Parsing

    private struct GitHubReleasePayload: Decodable {
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: URL
        var published_at: String?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [GitHubAssetPayload]
    }

    private struct GitHubAssetPayload: Decodable {
        var name: String
        var browser_download_url: URL
        var size: Int64
    }

    /// Decodes a GitHub `/releases/latest` JSON payload into `ReleaseInfo`.
    public static func decodeRelease(from data: Data) throws -> ReleaseInfo {
        let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        let version = normalizeVersion(payload.tag_name)
        let title = (payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "ATC Studio \(version)"
        let notes = payload.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publishedAt = payload.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }

        // Prefer an asset matching ATC-Studio-*.dmg, else any .dmg asset.
        let dmg = payload.assets.first {
            $0.name.lowercased().hasPrefix("atc-studio") && $0.name.lowercased().hasSuffix(".dmg")
        } ?? payload.assets.first {
            $0.name.lowercased().hasSuffix(".dmg")
        }

        return ReleaseInfo(
            tagName: payload.tag_name,
            version: version,
            title: title,
            notes: notes,
            publishedAt: publishedAt,
            htmlURL: payload.html_url,
            dmgAsset: dmg.map { ReleaseInfo.Asset(name: $0.name, downloadURL: $0.browser_download_url, size: $0.size) }
        )
    }

    public enum FetchResult: Sendable {
        case release(ReleaseInfo, etag: String?, rawData: Data)
        case notModified
        case noReleasesPublished
    }

    /// Queries GitHub for the latest release, supporting optional `If-None-Match` ETag caching.
    public static func fetchLatestRelease(
        etag: String? = nil,
        session: URLSession = .shared
    ) async throws -> FetchResult {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ATCStudio/\(currentAppVersion())", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse(-1)
        }
        switch http.statusCode {
        case 200:
            let info = try decodeRelease(from: data)
            let newETag = http.value(forHTTPHeaderField: "ETag")
            return .release(info, etag: newETag, rawData: data)
        case 304:
            return .notModified
        case 404:
            return .noReleasesPublished
        default:
            throw UpdateError.invalidResponse(http.statusCode)
        }
    }

    // MARK: - Download, Verify & Install

    /// Downloads `asset` to a temporary `.dmg` file and reports progress `0...1`.
    public static func downloadDMG(
        _ asset: ReleaseInfo.Asset,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("ATCStudio/\(currentAppVersion())", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.downloadFailed("HTTP \(code)")
        }

        let expectedBytes = http.expectedContentLength > 0 ? http.expectedContentLength : asset.size
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "ATCStudioUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destination = tempDir.appending(path: asset.name)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var received: Int64 = 0
        progress(0)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 65_536 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expectedBytes > 0 {
                    progress(min(1.0, Double(received) / Double(expectedBytes)))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        progress(1.0)
        return destination
    }

    /// Parses the plist output of `hdiutil attach -plist` and returns the first mounted volume path.
    public static func parseMountPoint(fromPlistData data: Data) throws -> URL {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.mountFailed("Unrecognized hdiutil plist output.")
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return URL(filePath: mountPoint, directoryHint: .isDirectory)
            }
        }
        throw UpdateError.mountFailed("No mount point returned by hdiutil.")
    }

    /// Mounts a DMG headlessly, verifies the `.app` inside, and stages a validated copy in temporary storage.
    public static func stageVerifiedApp(fromDMG dmgURL: URL) async throws -> URL {
        let attachOut = try runProcess(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path]
        )
        let mountURL = try parseMountPoint(fromPlistData: attachOut)
        defer {
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountURL.path, "-quiet"])
        }

        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil)
        guard let mountedApp = items.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appBundleNotFoundInDMG
        }

        // Verify bundle identifier matches ATC Studio.
        let infoPlistURL = mountedApp.appending(path: "Contents/Info.plist")
        if let plistData = try? Data(contentsOf: infoPlistURL),
           let info = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
           let bundleID = info["CFBundleIdentifier"] as? String,
           bundleID != expectedBundleIdentifier {
            throw UpdateError.bundleIdentifierMismatch(bundleID)
        }

        // Verify code signature integrity.
        do {
            _ = try runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", mountedApp.path])
        } catch {
            throw UpdateError.signatureVerificationFailed(error.localizedDescription)
        }

        let stagingDir = fm.temporaryDirectory
            .appending(path: "ATCStudioStaged-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedApp = stagingDir.appending(path: mountedApp.lastPathComponent, directoryHint: .isDirectory)
        try fm.copyItem(at: mountedApp, to: stagedApp)
        // Clear any quarantine xattr added by URLSession so launch proceeds smoothly after verification.
        _ = try? runProcess("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", stagedApp.path])
        return stagedApp
    }

    /// Whether the current running app bundle can be replaced in-place without root privileges.
    public static func canReplaceRunningBundle(bundle: Bundle = .main) -> Bool {
        let appURL = bundle.bundleURL
        guard appURL.pathExtension == "app" else { return false }
        let parent = appURL.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
            && FileManager.default.isWritableFile(atPath: appURL.path)
    }

    /// Spawns a detached helper script that waits for the current process to exit,
    /// swaps `stagedApp` into `targetApp`, and relaunches the updated app.
    public static func launchAtomicSwapAndRelaunch(stagedApp: URL, targetApp: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let stagingParent = stagedApp.deletingLastPathComponent().path
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "$2"
        mv "$1" "$2"
        rm -rf "$3"
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "atc-updater", stagedApp.path, targetApp.path, stagingParent]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.installationFailed(error.localizedDescription)
        }
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Exit code \(process.terminationStatus)"
            throw NSError(domain: "ReleaseUpdater", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return outData
    }
}
