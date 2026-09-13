import Foundation
import SSHConfigCore

#if canImport(Glibc)
    import Glibc
#endif

/// Everything the app knows about the user's configuration, in one value.
///
/// A value type on purpose: Meta's `@State` triggers a view update when the
/// property is assigned, not when an object mutates, so a class here would
/// render stale views.
public struct ConfigStore {
    public var directory: SSHDirectory.State
    public var graph: ConfigGraph
    public var findings: [LintFinding]
    public var keys: [SSHKeyEntry]
    public var knownHosts: [KnownHostRow]
    public var status: String?

    public init(
        directory: SSHDirectory.State = SSHDirectory.inspect(),
        graph: ConfigGraph = .init(),
        findings: [LintFinding] = [],
        keys: [SSHKeyEntry] = [],
        knownHosts: [KnownHostRow] = [],
        status: String? = nil
    ) {
        self.directory = directory
        self.graph = graph
        self.findings = findings
        self.keys = keys
        self.knownHosts = knownHosts
        self.status = status
    }

    public var document: SSHConfigDocument? { graph.root }

    /// Blocks in the order ssh reads them, with included files spliced in place.
    public var blocks: [HostBlock] { graph.linearizedBlocks }

    /// The blocks the sidebar lists: real hosts, no `Host *` catch-all.
    public var hosts: [HostBlock] {
        blocks.filter { $0.kind == .host && !$0.isWildcard }
    }

    public func block(id: HostBlock.ID) -> HostBlock? {
        blocks.first { $0.id == id }
    }

    /// Looks a host up by the key the sidebar uses. Aliases survive a reload;
    /// block IDs do not.
    ///
    /// The sidebar list excludes the `Host *` catch-all and every `Match` block,
    /// but both have their own screen, so the fallback searches all of them.
    /// Without it the Global Defaults screen can only ever report "Host not
    /// found", and every edit it makes is dropped without a word.
    public func block(alias: String) -> HostBlock? {
        hosts.first { $0.sidebarKey == alias } ?? blocks.first { $0.sidebarKey == alias }
    }

    public func findings(for id: HostBlock.ID) -> [LintFinding] {
        findings.filter { $0.blockID == id }
    }

    /// Applies a change to the host with this alias and saves the document.
    public mutating func update(alias: String, _ change: (inout HostBlock) -> Void) throws {
        guard let block = block(alias: alias) else { return }
        try update(block: block.id, change)
    }

    public func effectiveSettings(for block: HostBlock) -> [ResolvedSetting] {
        guard let alias = block.primaryAlias else { return [] }
        return EffectiveConfigResolver.resolve(target: alias, in: graph)
    }
}

extension ConfigStore {
    public static var configPath: String { "\(SSHDirectory.defaultPath)/config" }

    /// Reads the configuration and everything derived from it. Never throws: a
    /// missing or unreadable file is a state the UI shows, not a crash.
    public static func load() -> ConfigStore {
        var store = ConfigStore(directory: SSHDirectory.inspect())
        guard case .ready = store.directory else { return store }

        let graph = ConfigGraphLoader.load(path: configPath)
        store.graph = graph
        store.keys = SSHKeyScanner.scan()
        store.knownHosts = KnownHostsReader.load()
        store.findings = ConfigLinter.lint(
            graph.documents,
            existingFiles: Set(store.keys.map(\.path)),
            graph: graph
        )
        return store
    }

    /// Re-reads everything from disk, keeping nothing.
    public mutating func reload() {
        self = Self.load()
    }

    /// Writes the root document back and reloads. The serializer is lossless, so
    /// an untouched file comes back byte for byte.
    public mutating func save(_ document: SSHConfigDocument) throws {
        let text = SSHConfigSerializer.serialize(document)
        let path = document.sourceURL.path
        HistoryStore.snapshot(path: path)
        try text.write(to: document.sourceURL, atomically: true, encoding: .utf8)
        // ssh refuses a config other users can write. atomically: true replaces the
        // file, so the mode has to be set again after every write.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        reload()
    }

    /// Applies a change to one block and saves the document that holds it.
    public mutating func update(block id: HostBlock.ID, _ change: (inout HostBlock) -> Void) throws {
        for document in graph.documents {
            guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { continue }
            var edited = document
            change(&edited.blocks[index])
            try save(edited)
            return
        }
    }
}

extension ConfigStore {
    /// Where a file-backed group lives. The macOS build uses the same directory,
    /// so a configuration written by one is read by the other.
    public static var groupDirectory: String { "\(SSHDirectory.defaultPath)/ssh-config-manager.d" }

    /// Creates an included file and wires it into the main configuration.
    ///
    /// The `Include` goes into the preamble, above every Host block. ssh applies
    /// the first value it finds for an option, so an Include placed after a
    /// wildcard block would be silently overridden by it.
    @discardableResult
    public mutating func createIncludedFile(named fileName: String) throws -> URL {
        let name = fileName.hasSuffix(".conf") ? fileName : "\(fileName).conf"
        try FileManager.default.createDirectory(
            atPath: Self.groupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = URL(fileURLWithPath: "\(Self.groupDirectory)/\(name)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try "# Managed by SSH Config Manager\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }

        guard var root = document else { return url }
        let pattern = "~/.ssh/ssh-config-manager.d/*.conf"
        let alreadyIncluded = root.includeDirectives.contains { directive in
            ConfigGraphLoader.resolve(directive.value).contains(url.path)
        }
        if !alreadyIncluded {
            root.appendPreamble(directive: .init(keyword: "Include", value: pattern, isDirty: true))
            try save(root)
        } else {
            reload()
        }
        return url
    }

    /// Moves blocks into another document, both files written in one step.
    public mutating func move(blockIDs: [HostBlock.ID], to url: URL) throws {
        guard var target = graph.documents.first(where: { $0.sourceURL == url }) else { return }
        var moved: [HostBlock] = []
        var sources: [URL: SSHConfigDocument] = [:]
        for document in graph.documents where document.sourceURL != url {
            var edited = document
            let taken = edited.blocks.filter { blockIDs.contains($0.id) }
            guard !taken.isEmpty else { continue }
            edited.blocks.removeAll { blockIDs.contains($0.id) }
            sources[document.sourceURL] = edited
            moved.append(contentsOf: taken)
        }
        guard !moved.isEmpty else { return }
        target.appendBlocks(moved.map { $0.adoptingLineEnding(target.lineEnding) })
        for (_, document) in sources {
            try save(document)
        }
        try save(target)
    }
}

/// Resolves `Include` directives into a `ConfigGraph`. Core models the graph but
/// deliberately does no file I/O, so the globbing lives here.
enum ConfigGraphLoader {
    static let includeDepthLimit = 16

    static func load(path: String) -> ConfigGraph {
        guard let root = parse(path: path) else { return .init() }
        var documents = [root]
        var inclusions: [UUID: [SSHConfigDocument]] = [:]
        expand(root, into: &documents, inclusions: &inclusions, depth: 0)
        return .init(documents: documents, inclusions: inclusions)
    }

    private static func expand(
        _ document: SSHConfigDocument,
        into documents: inout [SSHConfigDocument],
        inclusions: inout [UUID: [SSHConfigDocument]],
        depth: Int
    ) {
        guard depth < includeDepthLimit else { return }
        for directive in document.includeDirectives {
            let included = resolve(directive.value).compactMap { parse(path: $0) }
            guard !included.isEmpty else { continue }
            inclusions[directive.id] = included
            for child in included {
                documents.append(child)
                expand(child, into: &documents, inclusions: &inclusions, depth: depth + 1)
            }
        }
    }

    private static func parse(path: String) -> SSHConfigDocument? {
        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SSHConfigParser.parse(text, sourceURL: url)
    }

    /// ssh reads an Include value as whitespace-separated patterns, resolves a
    /// relative one against ~/.ssh, and expands shell globs.
    static func resolve(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace)
            .map { SSHValueQuoting.unquoted(String($0)) }
            .flatMap { pattern -> [String] in
                let expanded = HomePath.expanding(pattern, home: SSHDirectory.home)
                let absolute =
                    expanded.hasPrefix("/")
                    ? expanded : "\(SSHDirectory.defaultPath)/\(expanded)"
                return globPaths(absolute)
            }
    }

    private static func globPaths(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Glibc.glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
        .filter { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
    }
}
