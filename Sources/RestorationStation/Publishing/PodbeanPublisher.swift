import Foundation
import ImageIO

public enum PodbeanPublishError: LocalizedError, Equatable {
    case invalidCredentials
    case missingMasterAudio(String)
    case apiError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Check your PodBean Client ID and Secret."
        case .missingMasterAudio(let name):
            "Could not find the master audio file \"\(name)\" to upload."
        case .apiError(let detail):
            detail
        case .invalidResponse:
            "PodBean returned an unexpected or unreadable response."
        }
    }
}

/// Client for authenticating, uploading media, and creating episodes on PodBean API v1.
public struct PodbeanPublisher: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.podbean.com/v1")!
    public static let minimumArtworkDimension = 1400

    public let credentials: PodbeanCredentials
    public let baseURL: URL
    public let session: URLSession

    public init(
        credentials: PodbeanCredentials,
        baseURL: URL = defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Public API

    /// Verifies the stored Client ID and Secret by obtaining an OAuth token and fetching `/v1/podcast`.
    public func testConnection() async throws -> PodcastAccountInfo {
        let token = try await fetchAccessToken()
        var components = URLComponents(url: baseURL.appending(path: "podcast"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = components.url else { throw PodbeanPublishError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("ATCStudio/\(ReleaseUpdater.currentAppVersion())", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let decoded = try? JSONDecoder().decode(PodcastResponse.self, from: data)
        let title = decoded?.resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let website = decoded?.resolvedWebsite.flatMap(URL.init(string:))
        return PodcastAccountInfo(
            podcastTitle: title.isEmpty ? "Connected PodBean Podcast" : title,
            podcastURL: website
        )
    }

    /// Uploads the episode audio (and valid square artwork if present), creates the episode on PodBean,
    /// and writes `publish.json` into `episodeFolder`.
    public func publish(
        package: EpisodePackage,
        in episodeFolder: URL,
        status: PublishStatus,
        onProgress: @escaping @Sendable (PublishProgress) -> Void = { _ in }
    ) async throws -> PublishResult {
        let mp3URL = episodeFolder.appending(path: EpisodePackageExporter.masterName)
        guard FileManager.default.fileExists(atPath: mp3URL.path) else {
            throw PodbeanPublishError.missingMasterAudio(mp3URL.lastPathComponent)
        }

        onProgress(PublishProgress(message: "Authenticating with PodBean…", fraction: 0.02))
        let token = try await fetchAccessToken()
        try Task.checkCancellation()

        // Upload MP3 (5% -> 85% progress)
        onProgress(PublishProgress(message: "Authorizing audio upload…", fraction: 0.05))
        let mediaKey = try await authorizeAndUpload(
            fileURL: mp3URL,
            contentType: "audio/mpeg",
            accessToken: token
        ) { sentFraction in
            let overall = 0.05 + sentFraction * 0.80
            let pct = Int((sentFraction * 100).rounded())
            onProgress(PublishProgress(message: "Uploading MP3… \(pct)%", fraction: overall))
        }
        try Task.checkCancellation()

        // Optional artwork upload (85% -> 92% progress)
        var logoKey: String?
        var skippedArtworkReason: String?
        let artworkURL = episodeFolder.appending(path: EpisodePackageExporter.artworkName)
        if FileManager.default.fileExists(atPath: artworkURL.path) {
            switch Self.validateArtwork(at: artworkURL) {
            case .valid:
                onProgress(PublishProgress(message: "Uploading episode artwork…", fraction: 0.86))
                do {
                    logoKey = try await authorizeAndUpload(
                        fileURL: artworkURL,
                        contentType: "image/jpeg",
                        accessToken: token
                    ) { sentFraction in
                        onProgress(PublishProgress(
                            message: "Uploading episode artwork…",
                            fraction: 0.86 + sentFraction * 0.06
                        ))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    skippedArtworkReason = "Skipped episode artwork (\(error.localizedDescription))."
                }
            case .skipped(let reason):
                skippedArtworkReason = reason
            }
        }
        try Task.checkCancellation()

        // Create episode (92% -> 100%)
        onProgress(PublishProgress(
            message: status == .draft ? "Creating draft episode on PodBean…" : "Publishing episode on PodBean…",
            fraction: 0.94
        ))
        var result = try await createEpisode(
            package: package,
            mediaKey: mediaKey,
            logoKey: logoKey,
            status: status,
            accessToken: token
        )
        result.skippedArtworkReason = skippedArtworkReason
        try result.save(in: episodeFolder)
        onProgress(PublishProgress(message: "Published to PodBean.", fraction: 1.0))
        return result
    }

    // MARK: - Step 1: OAuth Token

    func fetchAccessToken() async throws -> String {
        guard credentials.isValid else {
            throw PodbeanPublishError.invalidCredentials
        }
        let url = baseURL.appending(path: "oauth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let rawAuth = "\(credentials.clientID):\(credentials.clientSecret)"
        let encodedAuth = Data(rawAuth.utf8).base64EncodedString()
        request.setValue("Basic \(encodedAuth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("ATCStudio/\(ReleaseUpdater.currentAppVersion())", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("grant_type=client_credentials".utf8)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !tokenResponse.access_token.isEmpty else {
            throw PodbeanPublishError.invalidResponse
        }
        return tokenResponse.access_token
    }

    // MARK: - Step 2 & 3: Authorize & Presigned PUT Upload

    func authorizeAndUpload(
        fileURL: URL,
        contentType: String,
        accessToken: String,
        onUploadFraction: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        var components = URLComponents(url: baseURL.appending(path: "files/uploadAuthorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "filename", value: fileURL.lastPathComponent),
            URLQueryItem(name: "filesize", value: String(fileSize)),
            URLQueryItem(name: "content_type", value: contentType),
        ]
        guard let authorizeURL = components.url else { throw PodbeanPublishError.invalidResponse }

        var authRequest = URLRequest(url: authorizeURL)
        authRequest.httpMethod = "GET"
        authRequest.setValue("ATCStudio/\(ReleaseUpdater.currentAppVersion())", forHTTPHeaderField: "User-Agent")

        let (authData, authResponse) = try await session.data(for: authRequest)
        try validateHTTPResponse(authResponse, data: authData)

        guard let uploadAuth = try? JSONDecoder().decode(UploadAuthorizeResponse.self, from: authData),
              let presignedURL = uploadAuth.resolvedURL,
              !uploadAuth.file_key.isEmpty else {
            throw PodbeanPublishError.invalidResponse
        }

        var putRequest = URLRequest(url: presignedURL)
        putRequest.httpMethod = "PUT"
        // S3 presigned URLs require the exact same Content-Type passed to uploadAuthorize.
        putRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if fileSize > 0 {
            putRequest.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        }

        let delegate = UploadProgressDelegate(expectedBytes: fileSize, onProgress: onUploadFraction)
        let (putData, putResponse) = try await session.upload(for: putRequest, fromFile: fileURL, delegate: delegate)
        guard let http = putResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (putResponse as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: putData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PodbeanPublishError.apiError(
                body.isEmpty ? "File upload failed (HTTP \(status))." : "File upload failed (HTTP \(status)): \(body.prefix(200))"
            )
        }
        onUploadFraction(1.0)
        return uploadAuth.file_key
    }

    // MARK: - Step 4: Create Episode

    func createEpisode(
        package: EpisodePackage,
        mediaKey: String,
        logoKey: String?,
        status: PublishStatus,
        accessToken: String
    ) async throws -> PublishResult {
        let url = baseURL.appending(path: "episodes")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("ATCStudio/\(ReleaseUpdater.currentAppVersion())", forHTTPHeaderField: "User-Agent")

        let cleanTitle = package.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [(String, String)] = [
            ("access_token", accessToken),
            ("title", cleanTitle.isEmpty ? "Episode" : cleanTitle),
            ("content", Self.htmlShowNotes(for: package)),
            ("status", status.rawValue),
            ("type", "public"),
            ("media_key", mediaKey),
        ]
        if let logoKey, !logoKey.isEmpty {
            fields.append(("logo_key", logoKey))
        }
        request.httpBody = Data(Self.formURLEncoded(fields).utf8)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let created = try? JSONDecoder().decode(CreateEpisodeResponse.self, from: data),
              let id = created.resolvedID, !id.isEmpty else {
            throw PodbeanPublishError.invalidResponse
        }

        return PublishResult(
            episodeID: id,
            permalinkURL: created.resolvedPermalink,
            status: status,
            publishedAt: Date()
        )
    }

    // MARK: - HTML Formatting & Escaping

    /// Converts the episode's plain-text show notes into HTML paragraphs with `<`, `>`, and `&` escaped.
    public static func htmlShowNotes(for package: EpisodePackage) -> String {
        let blocks = package.showNotes
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return blocks.map { block in
            let escapedLines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { escapeHTML(String($0)) }
                .joined(separator: "<br>")
            return "<p>\(escapedLines)</p>"
        }.joined(separator: "\n")
    }

    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func formURLEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    // MARK: - Artwork Validation

    public enum ArtworkValidation: Equatable {
        case valid
        case skipped(String)
    }

    /// PodBean requires a square image of at least 1400×1400 px for episode logos.
    public static func validateArtwork(at url: URL) -> ArtworkValidation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return .skipped("Skipped episode artwork (could not read image dimensions).")
        }
        guard width == height else {
            return .skipped("Skipped episode artwork (\(width)×\(height) px is not square; PodBean requires a 1:1 square image).")
        }
        guard width >= minimumArtworkDimension else {
            return .skipped("Skipped episode artwork (\(width)×\(height) px is smaller than PodBean's 1400×1400 px minimum).")
        }
        return .valid
    }

    // MARK: - Error Mapping

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PodbeanPublishError.invalidResponse
        }
        guard !(200..<300).contains(http.statusCode) else { return }

        let apiError = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
        if http.statusCode == 401 || apiError?.error == "invalid_client" || apiError?.error == "unauthorized_client" {
            throw PodbeanPublishError.invalidCredentials
        }
        if let description = apiError?.error_description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            throw PodbeanPublishError.apiError(description)
        }
        if let error = apiError?.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            throw PodbeanPublishError.apiError("PodBean error: \(error)")
        }
        throw PodbeanPublishError.apiError("PodBean returned HTTP \(http.statusCode).")
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let expectedBytes: Int64
    let onProgress: @Sendable (Double) -> Void

    init(expectedBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let total = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : expectedBytes
        guard total > 0 else { return }
        let fraction = min(1.0, max(0.0, Double(totalBytesSent) / Double(total)))
        onProgress(fraction)
    }
}

// MARK: - API Response Payloads

private struct TokenResponse: Decodable {
    var access_token: String
    var expires_in: Int?
}

private struct PodcastResponse: Decodable {
    struct PodcastPayload: Decodable {
        var title: String?
        var website: String?
    }
    var podcast: PodcastPayload?
    var title: String?
    var website: String?

    var resolvedTitle: String {
        podcast?.title ?? title ?? ""
    }
    var resolvedWebsite: String? {
        podcast?.website ?? website
    }
}

private struct UploadAuthorizeResponse: Decodable {
    var presigned_url: URL?
    var upload_url: URL?
    var file_key: String

    var resolvedURL: URL? {
        presigned_url ?? upload_url
    }
}

private struct CreateEpisodeResponse: Decodable {
    struct EpisodePayload: Decodable {
        var id: String?
        var permalink_url: String?
        var player_url: String?
    }
    var episode: EpisodePayload?
    var id: String?
    var permalink_url: String?

    var resolvedID: String? {
        episode?.id ?? id
    }
    var resolvedPermalink: URL? {
        let raw = episode?.permalink_url ?? permalink_url ?? episode?.player_url
        return raw.flatMap { URL(string: $0) }
    }
}

private struct APIErrorPayload: Decodable {
    var error: String?
    var error_description: String?
}
