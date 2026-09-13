import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum GistError: Error, LocalizedError, Sendable, Equatable {
    case networkError(String)
    case serverError(statusCode: Int)
    case unauthorized
    case notFound
    case decoding

    public var errorDescription: String? {
        switch self {
        case .networkError(let message): return "Couldn't reach GitHub: \(message)"
        case .serverError(let code): return "GitHub returned an error (HTTP \(code))."
        case .unauthorized: return "GitHub rejected the stored access token. Reconnect your account."
        case .notFound: return "The gist is gone from GitHub."
        case .decoding: return "GitHub returned a response this app couldn't parse."
        }
    }
}

public struct GitHubDeviceFlowClient: Sendable {
    public struct DeviceCode: Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURI: String
        public let interval: Int
        public let expiresIn: Int

        public init(deviceCode: String, userCode: String, verificationURI: String, interval: Int, expiresIn: Int) {
            self.deviceCode = deviceCode
            self.userCode = userCode
            self.verificationURI = verificationURI
            self.interval = interval
            self.expiresIn = expiresIn
        }
    }

    public enum PollResult: Sendable, Equatable {
        case token(String)
        case pending
        case slowDown(newInterval: Int)
        case denied
        case expired
    }

    private let clientID: String
    private let session: URLSession
    private let baseURL: URL

    public init(clientID: String, session: URLSession = .shared, baseURL: URL = URL(string: "https://github.com")!) {
        self.clientID = clientID
        self.session = session
        self.baseURL = baseURL
    }

    public func requestCode(scope: String = "gist") async throws -> DeviceCode {
        var request = URLRequest(url: baseURL.appendingPathComponent("login/device/code"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["client_id": clientID, "scope": scope])
        request.timeoutInterval = 15

        let json = try await Self.send(request, session: session)
        guard let deviceCode = json["device_code"] as? String, let userCode = json["user_code"] as? String,
            let verificationURI = json["verification_uri"] as? String
        else { throw GistError.decoding }
        let interval = (json["interval"] as? Int) ?? 5
        let expiresIn = (json["expires_in"] as? Int) ?? 900
        return DeviceCode(
            deviceCode: deviceCode, userCode: userCode, verificationURI: verificationURI, interval: interval,
            expiresIn: expiresIn)
    }

    public func poll(deviceCode: String) async throws -> PollResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("login/oauth/access_token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "client_id": clientID, "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        request.timeoutInterval = 15

        let json = try await Self.send(request, session: session)
        if let token = json["access_token"] as? String { return .token(token) }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down":
            let newInterval = (json["interval"] as? Int) ?? 5
            return .slowDown(newInterval: newInterval)
        case "expired_token": return .expired
        case "access_denied": return .denied
        default: throw GistError.decoding
        }
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        let encoded = fields.map { key, value in
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    static func send(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GistError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GistError.networkError("no HTTP response") }
        guard http.statusCode == 200 else { throw GistError.serverError(statusCode: http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GistError.decoding
        }
        return json
    }
}
