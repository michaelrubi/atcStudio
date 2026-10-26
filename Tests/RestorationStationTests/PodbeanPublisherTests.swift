import Foundation
import Synchronization
import Testing
@testable import RestorationStation

@Suite(.serialized)
struct PodbeanPublisherTests {
    @Test func oauthTokenUsesBasicAuthAndDecodesAccessToken() async throws {
        let session = MockURLProtocol.makeSession { request in
            #expect(request.url?.path == "/v1/oauth/token")
            #expect(request.httpMethod == "POST")
            let expectedBasic = Data("my-client:my-secret".utf8).base64EncodedString()
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expectedBasic)")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            #expect(Self.bodyString(of: request) == "grant_type=client_credentials")

            return Self.jsonResponse(
                for: request,
                statusCode: 200,
                json: #"{"access_token":"tok_abc123","token_type":"bearer","expires_in":3600}"#
            )
        }

        let publisher = PodbeanPublisher(
            credentials: PodbeanCredentials(clientID: "my-client", clientSecret: "my-secret"),
            session: session
        )
        let token = try await publisher.fetchAccessToken()
        #expect(token == "tok_abc123")
    }

    @Test func unauthorized401MapsToFriendlyCredentialsError() async throws {
        let session = MockURLProtocol.makeSession { request in
            Self.jsonResponse(
                for: request,
                statusCode: 401,
                json: #"{"error":"invalid_client","error_description":"Invalid client credentials"}"#
            )
        }

        let publisher = PodbeanPublisher(
            credentials: PodbeanCredentials(clientID: "bad", clientSecret: "bad"),
            session: session
        )
        await #expect(throws: PodbeanPublishError.invalidCredentials) {
            _ = try await publisher.testConnection()
        }
    }

    @Test func authorizeAndPutMatchesContentTypeAndCreatesEpisodeWithEscapedHTML() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ATCPodbeanTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let mp3URL = folder.appending(path: EpisodePackageExporter.masterName)
        let mp3Data = Data(repeating: 0x5A, count: 512)
        try mp3Data.write(to: mp3URL)

        // Small non-square artwork should be skipped gracefully without failing the publish.
        let artURL = folder.appending(path: EpisodePackageExporter.artworkName)
        let onePixelPNG = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
        try onePixelPNG.write(to: artURL)

        let recordedPutContentType = Mutex<String?>(nil)
        let recordedEpisodeForm = Mutex<[String: String]>([:])

        let session = MockURLProtocol.makeSession { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/v1/oauth/token":
                return Self.jsonResponse(
                    for: request,
                    statusCode: 200,
                    json: #"{"access_token":"tok_live"}"#
                )

            case "/v1/files/uploadAuthorize":
                let query = Self.queryItems(of: request)
                #expect(query["access_token"] == "tok_live")
                #expect(query["filename"] == "master_episode.mp3")
                #expect(query["filesize"] == "512")
                #expect(query["content_type"] == "audio/mpeg")
                return Self.jsonResponse(
                    for: request,
                    statusCode: 200,
                    json: #"{"presigned_url":"https://s3.example.com/upload/audio1","file_key":"media_key_99"}"#
                )

            case "/upload/audio1":
                #expect(request.httpMethod == "PUT")
                recordedPutContentType.withLock { $0 = request.value(forHTTPHeaderField: "Content-Type") }
                return Self.jsonResponse(for: request, statusCode: 200, json: "")

            case "/v1/episodes":
                #expect(request.httpMethod == "POST")
                let body = Self.bodyString(of: request)
                recordedEpisodeForm.withLock { $0 = Self.parseFormURLEncoded(body) }
                return Self.jsonResponse(
                    for: request,
                    statusCode: 200,
                    json: #"{"episode":{"id":"ep_777","permalink_url":"https://church.podbean.com/e/grace-truth/"}}"#
                )

            default:
                Issue.record("Unexpected request path: \(path)")
                return Self.jsonResponse(for: request, statusCode: 404, json: "{}")
            }
        }

        let package = EpisodePackage(
            title: "Grace & <Truth>",
            summary: "A message on Romans 8 & <faith>.",
            speakerNames: [0: "Pastor John & Sarah"],
            date: Date(timeIntervalSince1970: 1_790_000_000),
            introOffset: 5,
            mainEnd: 65,
            totalDuration: 75,
            analysis: EpisodeAnalysis(
                masterURL: mp3URL,
                introOffset: 5,
                mainEnd: 65,
                totalDuration: 75,
                words: [TimedWord(text: "Hello", start: 6, end: 7, speaker: 0)],
                turns: [SpeakerTurn(start: 6, end: 20, speaker: 0)],
                speakerCount: 1,
                fillers: [],
                suggestedTitles: [],
                summary: "A message on Romans 8 & <faith>."
            )
        )

        let publisher = PodbeanPublisher(
            credentials: PodbeanCredentials(clientID: "cid", clientSecret: "sec"),
            session: session
        )

        let result = try await publisher.publish(package: package, in: folder, status: .draft)
        #expect(result.episodeID == "ep_777")
        #expect(result.status == .draft)
        #expect(result.permalinkURL == URL(string: "https://church.podbean.com/e/grace-truth/"))
        #expect(result.skippedArtworkReason?.contains("1400×1400") == true)

        // PUT Content-Type must match uploadAuthorize content_type.
        #expect(recordedPutContentType.withLock { $0 } == "audio/mpeg")

        // Verify episode POST form fields and HTML escaping.
        let form = recordedEpisodeForm.withLock { $0 }
        #expect(form["access_token"] == "tok_live")
        #expect(form["title"] == "Grace & <Truth>")
        #expect(form["status"] == "draft")
        #expect(form["type"] == "public")
        #expect(form["media_key"] == "media_key_99")
        #expect(form["logo_key"] == nil)

        let content = try #require(form["content"])
        #expect(content.contains("<p>Grace &amp; &lt;Truth&gt;</p>"))
        #expect(content.contains("<p>A message on Romans 8 &amp; &lt;faith&gt;.</p>"))
        #expect(content.contains("<p>Speakers: Pastor John &amp; Sarah</p>"))

        // Verify publish.json was written into the episode folder and round-trips cleanly.
        let loaded = try #require(PublishResult.load(from: folder))
        #expect(loaded.episodeID == "ep_777")
        #expect(loaded.status == .draft)
        #expect(loaded.permalinkURL == result.permalinkURL)
        #expect(loaded.skippedArtworkReason == result.skippedArtworkReason)
    }

    @Test func publishStatusPublishSendsPublishString() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ATCPodbeanPub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 64).write(to: folder.appending(path: EpisodePackageExporter.masterName))

        let recordedStatus = Mutex<String?>(nil)
        let session = MockURLProtocol.makeSession { request in
            switch request.url?.path ?? "" {
            case "/v1/oauth/token":
                return Self.jsonResponse(for: request, statusCode: 200, json: #"{"access_token":"tok"}"#)
            case "/v1/files/uploadAuthorize":
                return Self.jsonResponse(
                    for: request,
                    statusCode: 200,
                    json: #"{"presigned_url":"https://s3.example.com/put","file_key":"mk"}"#
                )
            case "/put":
                return Self.jsonResponse(for: request, statusCode: 200, json: "")
            case "/v1/episodes":
                let form = Self.parseFormURLEncoded(Self.bodyString(of: request))
                recordedStatus.withLock { $0 = form["status"] }
                return Self.jsonResponse(for: request, statusCode: 200, json: #"{"episode":{"id":"ep_pub"}}"#)
            default:
                return Self.jsonResponse(for: request, statusCode: 404, json: "{}")
            }
        }

        let publisher = PodbeanPublisher(
            credentials: PodbeanCredentials(clientID: "c", clientSecret: "s"),
            session: session
        )
        let pkg = EpisodePackage(title: "Sunday Live", introOffset: 0, mainEnd: 30, totalDuration: 30)
        let result = try await publisher.publish(package: pkg, in: folder, status: .publish)
        #expect(result.status == .publish)
        #expect(recordedStatus.withLock { $0 } == "publish")
    }

    // MARK: - Helpers

    private static func jsonResponse(
        for request: URLRequest,
        statusCode: Int,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private static func bodyString(of request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(decoding: body, as: UTF8.self)
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func queryItems(of request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            out[item.name] = item.value ?? ""
        }
        return out
    }

    private static func parseFormURLEncoded(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = parts.first else { continue }
            let key = String(k).removingPercentEncoding ?? String(k)
            let val = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            result[key] = val
        }
        return result
    }
}

private final class MockURLProtocol: URLProtocol {
    private static let handlerStorage = Mutex<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    static func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        handlerStorage.withLock { $0 = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handlerStorage.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
