import Foundation
import SSHConfigSync
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct GitHubDeviceFlowClientTests {
    private func client(_ handler: @escaping (URLRequest) -> (Int, [String: Any])) -> GitHubDeviceFlowClient {
        let (session, baseURL) = GistNetworkStub.stub(handler: handler)
        return GitHubDeviceFlowClient(clientID: "test-client-id", session: session, baseURL: baseURL)
    }

    @Test func requestCodeParsesTheResponse() async throws {
        let code = try await client({ _ in
            (
                200,
                [
                    "device_code": "dc", "user_code": "ABCD-1234",
                    "verification_uri": "https://github.com/login/device", "interval": 5, "expires_in": 900,
                ]
            )
        }).requestCode()
        #expect(code.userCode == "ABCD-1234")
        #expect(code.interval == 5)
    }

    @Test func pollMapsAccessToken() async throws {
        let result = try await client({ _ in (200, ["access_token": "gho_abc"]) }).poll(deviceCode: "dc")
        #expect(result == .token("gho_abc"))
    }

    @Test func pollMapsAuthorizationPending() async throws {
        let result = try await client({ _ in (200, ["error": "authorization_pending"]) }).poll(deviceCode: "dc")
        #expect(result == .pending)
    }

    @Test func pollMapsSlowDownWithNewInterval() async throws {
        let result = try await client({ _ in (200, ["error": "slow_down", "interval": 10]) }).poll(deviceCode: "dc")
        #expect(result == .slowDown(newInterval: 10))
    }

    @Test func pollMapsExpiredToken() async throws {
        let result = try await client({ _ in (200, ["error": "expired_token"]) }).poll(deviceCode: "dc")
        #expect(result == .expired)
    }

    @Test func pollMapsAccessDenied() async throws {
        let result = try await client({ _ in (200, ["error": "access_denied"]) }).poll(deviceCode: "dc")
        #expect(result == .denied)
    }
}
