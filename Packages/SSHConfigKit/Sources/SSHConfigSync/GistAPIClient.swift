import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct GistAPIClient: Sendable {
    public struct Gist: Sendable {
        public let id: String
        public let version: String
        public let files: [String: String]

        public init(id: String, version: String, files: [String: String]) {
            self.id = id
            self.version = version
            self.files = files
        }
    }

    private let token: String
    private let session: URLSession
    private let baseURL: URL

    public init(token: String, session: URLSession = .shared, baseURL: URL = URL(string: "https://api.github.com")!) {
        self.token = token
        self.session = session
        self.baseURL = baseURL
    }

    private func request(method: String, path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 20
        return request
    }

    public func authenticatedLogin() async throws -> String {
        let json = try await send(request(method: "GET", path: "user"))
        guard let login = json["login"] as? String else { throw GistError.decoding }
        return login
    }

    public func create(files: [String: String], description: String, isPublic: Bool = false) async throws -> Gist {
        var req = request(method: "POST", path: "gists")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "description": description,
            "public": isPublic,
            "files": files.mapValues { ["content": $0] },
        ])
        let json = try await send(req)
        return try await Self.parseGist(json)
    }

    public func get(id: String) async throws -> Gist {
        let json = try await send(request(method: "GET", path: "gists/\(id)"))
        return try await Self.parseGist(json, session: session)
    }

    public func update(id: String, files: [String: String?]) async throws -> Gist {
        var req = request(method: "PATCH", path: "gists/\(id)")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "files": files.mapValues { content -> Any in
                guard let content else { return NSNull() }
                return ["content": content]
            }
        ])
        let json = try await send(req)
        return try await Self.parseGist(json)
    }

    private static func parseGist(_ json: [String: Any], session: URLSession? = nil) async throws -> Gist {
        guard let id = json["id"] as? String,
            let rawFiles = json["files"] as? [String: [String: Any]]
        else { throw GistError.decoding }
        let version = ((json["history"] as? [[String: Any]])?.first?["version"] as? String) ?? ""
        var files: [String: String] = [:]
        for (name, meta) in rawFiles {
            if let content = meta["content"] as? String, meta["truncated"] as? Bool != true {
                files[name] = content
                continue
            }
            guard let session, let rawURLString = meta["raw_url"] as? String, let rawURL = URL(string: rawURLString)
            else { continue }
            if let (data, _) = try? await session.data(from: rawURL) {
                files[name] = String(decoding: data, as: UTF8.self)
            }
        }
        return Gist(id: id, version: version, files: files)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GistError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GistError.networkError("no HTTP response") }
        if http.statusCode == 401 { throw GistError.unauthorized }
        if http.statusCode == 404 { throw GistError.notFound }
        guard (200..<300).contains(http.statusCode) else { throw GistError.serverError(statusCode: http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GistError.decoding
        }
        return json
    }
}
