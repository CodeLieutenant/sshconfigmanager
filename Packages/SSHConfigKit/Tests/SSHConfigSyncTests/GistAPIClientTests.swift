import Foundation
import SSHConfigSync
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct GistAPIClientTests {
    private func client(_ handler: @escaping (URLRequest) -> (Int, [String: Any])) -> GistAPIClient {
        let (session, baseURL) = GistNetworkStub.stub(handler: handler)
        return GistAPIClient(token: "test-token", session: session, baseURL: baseURL)
    }

    @Test func getExtractsLatestHistoryVersion() async throws {
        let gist = try await client({ _ in
            (
                200,
                [
                    "id": "gist123",
                    "files": ["sshconfigmanager.json": ["content": "{}"]],
                    "history": [["version": "v2"], ["version": "v1"]],
                ]
            )
        }).get(id: "gist123")
        #expect(gist.version == "v2")
        #expect(gist.files["sshconfigmanager.json"] == "{}")
    }

    @Test func createSendsAWellFormedBody() async throws {
        nonisolated(unsafe) var captured: [String: Any] = [:]
        _ = try await client({ request in
            captured =
                (try? JSONSerialization.jsonObject(with: request.httpBodyStreamedOrBody())) as? [String: Any] ?? [:]
            return (201, ["id": "new-gist", "files": [:], "history": []])
        }).create(files: ["a.json": "{}"], description: "SSH Config Manager sync")
        #expect(captured["public"] as? Bool == false)
        #expect((captured["files"] as? [String: Any])?["a.json"] != nil)
    }

    @Test func unauthorizedMapsTo401() async throws {
        await #expect(throws: GistError.unauthorized) {
            _ = try await client({ _ in (401, [:]) }).get(id: "gist123")
        }
    }

    @Test func serverErrorMapsToStatusCode() async throws {
        await #expect(throws: GistError.serverError(statusCode: 500)) {
            _ = try await client({ _ in (500, [:]) }).get(id: "gist123")
        }
    }
}

extension URLRequest {
    fileprivate func httpBodyStreamedOrBody() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
