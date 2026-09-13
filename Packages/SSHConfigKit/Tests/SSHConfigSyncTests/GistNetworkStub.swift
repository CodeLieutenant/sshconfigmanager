import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class GistNetworkStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> (Int, [String: Any])] = [:]

    static func stub(
        handler: @escaping (URLRequest) -> (Int, [String: Any])
    ) -> (session: URLSession, baseURL: URL) {
        let id = UUID().uuidString
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GistNetworkStub.self]
        let session = URLSession(configuration: config)
        let baseURL = URL(string: "https://stub.local/\(id)")!
        return (session, baseURL)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.url?.pathComponents.dropFirst().first ?? ""
        Self.lock.lock()
        let handler = Self.handlers[id]
        Self.lock.unlock()
        let (statusCode, body) = handler?(request) ?? (599, [:])
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
