import Foundation
import SSHConfigSync
import Testing

@testable import SSHConfigMacUI

private final class DeletedGistStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var getStatus = 404
    nonisolated(unsafe) static var seenMethods: [String] = []
    nonisolated(unsafe) static var createdID = "recreated-gist"

    static func reset() {
        getStatus = 404
        seenMethods = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.seenMethods.append("\(method) \(path)")

        var status = 200
        var body = "{}"
        if path.hasSuffix("/user") {
            body = #"{"login":"tester"}"#
        } else if method == "POST" {
            body = """
                {"id":"\(Self.createdID)","files":{"sshmanager.config.json":{"content":"{}"}},\
                "history":[{"version":"v-new"}]}
                """
            status = 201
        } else if method == "GET" {
            status = Self.getStatus
            body =
                status == 200
                ? #"{"id":"old-gist","files":{"sshmanager.config.json":{"content":"{}"}},"history":[{"version":"v1"}]}"#
                : #"{"message":"Not Found"}"#
        }

        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private nonisolated final class TokenStore: GistSecretStoring, @unchecked Sendable {
    func saveToken(_ token: String) throws {}
    func token() -> String? { "gho_test" }
    func removeToken() {}
    func savePassphrase(_ passphrase: String) throws {}
    func passphrase() -> String? { nil }
    func removePassphrase() {}
}

@MainActor
@Suite(.serialized)
struct GistDeletedRemotelyTests {
    private func makeStore(gistID: String) async -> (GistSyncStore, AppSettings) {
        DeletedGistStubURLProtocol.reset()
        var config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeletedGistStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        settings.gistSyncEnabled = true
        settings.gistEncryptionEnabled = false
        settings.gistID = gistID
        settings.gistLastSyncedVersion = "v1"
        settings.gistLastSyncedLocalHash = "hash"
        let sync = GistSyncStore(
            settings: settings, secretStore: TokenStore(), configStore: ConfigStore(), clientID: "stub",
            apiClient: { GistAPIClient(token: $0, session: session, baseURL: URL(string: "https://stub.local")!) })
        for _ in 0..<200 {
            if case .connected = sync.connection { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return (sync, settings)
    }

    @Test func pushRecreatesTheGistWhenItIsGone() async {
        let (sync, settings) = await makeStore(gistID: "old-gist")
        await sync.pushNow()
        #expect(settings.gistID == DeletedGistStubURLProtocol.createdID)
        #expect(settings.gistLastSyncedVersion == "v-new")
        #expect(sync.recreatedAfterRemoteDeletion)
        #expect(sync.lastError == nil)
        #expect(DeletedGistStubURLProtocol.seenMethods.contains { $0.hasPrefix("POST") })
    }

    @Test func pullSaysTheGistIsGoneAndCreatesNothing() async {
        let (sync, settings) = await makeStore(gistID: "old-gist")
        await sync.pullNow()
        #expect(sync.lastError?.contains("no longer exists") == true)
        #expect(!sync.recreatedAfterRemoteDeletion)
        #expect(settings.gistID.isEmpty)
        #expect(!DeletedGistStubURLProtocol.seenMethods.contains { $0.hasPrefix("POST /gists") })
    }

    @Test func pushAfterAFailedPullCreatesTheReplacement() async {
        let (sync, settings) = await makeStore(gistID: "old-gist")
        await sync.pullNow()
        await sync.pushNow()
        #expect(settings.gistID == DeletedGistStubURLProtocol.createdID)
        #expect(sync.lastError == nil)
    }

    @Test func autoSyncRecreatesTheGistWhenItIsGone() async {
        let (sync, settings) = await makeStore(gistID: "old-gist")
        await sync.autoSyncIfNeeded()
        #expect(settings.gistID == DeletedGistStubURLProtocol.createdID)
        #expect(sync.recreatedAfterRemoteDeletion)
    }

    @Test func aLiveGistIsNeverRecreated() async {
        let (sync, settings) = await makeStore(gistID: "old-gist")
        DeletedGistStubURLProtocol.getStatus = 200
        await sync.pushNow()
        #expect(!sync.recreatedAfterRemoteDeletion)
        #expect(settings.gistID == "old-gist")
        #expect(!DeletedGistStubURLProtocol.seenMethods.contains { $0.hasPrefix("POST /gists") })
    }

    @Test func disconnectClearsTheRecreatedNotice() async {
        let (sync, _) = await makeStore(gistID: "old-gist")
        await sync.pushNow()
        #expect(sync.recreatedAfterRemoteDeletion)
        sync.disconnect()
        #expect(!sync.recreatedAfterRemoteDeletion)
    }
}
