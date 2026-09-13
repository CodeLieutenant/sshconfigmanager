import AppKit
import Foundation
import SSHConfigSync
import SwiftUI
import Testing

@testable import SSHConfigMacUI

private final class DeviceFlowStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: String
        if path.contains("device/code") {
            body = """
                {"device_code":"dc","user_code":"C893-930C",\
                "verification_uri":"https://github.com/login/device","interval":1,"expires_in":900}
                """
        } else {
            body = #"{"error":"authorization_pending"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private nonisolated final class NullSecretStore: GistSecretStoring, @unchecked Sendable {
    func saveToken(_ token: String) throws {}
    func token() -> String? { nil }
    func removeToken() {}
    func savePassphrase(_ passphrase: String) throws {}
    func passphrase() -> String? { nil }
    func removePassphrase() {}
}

@MainActor
struct DeviceCodeSheetRenderTests {
    private func connectingStore() async -> GistSyncStore {
        var config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeviceFlowStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let sync = GistSyncStore(
            settings: settings, secretStore: NullSecretStore(), configStore: ConfigStore(),
            clientID: "stub",
            deviceFlowClient: {
                GitHubDeviceFlowClient(
                    clientID: "stub", session: session, baseURL: URL(string: "https://stub.local")!)
            },
            apiClient: { GistAPIClient(token: $0, session: session) })
        Task { await sync.connect() }
        for _ in 0..<200 {
            if case .connecting = sync.connection { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return sync
    }

    @Test func connectingStateShowsTheUserCode() async throws {
        let sync = await connectingStore()
        guard case .connecting(let userCode, let uri) = sync.connection else {
            Issue.record("store never reached .connecting; lastError=\(sync.lastError ?? "nil")")
            return
        }
        #expect(userCode == "C893-930C")
        #expect(uri == "https://github.com/login/device")

        let renderer = ImageRenderer(content: DeviceCodeSheet().environment(sync))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test func displayHostStripsTheScheme() {
        #expect(DeviceCodeSheet.displayHost("https://github.com/login/device") == "github.com/login/device")
        #expect(DeviceCodeSheet.displayHost("not a url") == "not a url")
    }

    @Test func spelledOutReadsEachCharacterAndNamesTheDash() {
        #expect(DeviceCodeSheet.spelledOut("C893-930C") == "C 8 9 3 dash 9 3 0 C")
    }
}
