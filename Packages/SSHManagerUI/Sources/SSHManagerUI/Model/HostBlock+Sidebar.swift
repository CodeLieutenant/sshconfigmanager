import SSHConfigCore

extension HostBlock {
    /// The key the sidebar and the detail screen use to name this host.
    ///
    /// `id` is a fresh UUID on every parse, and the app re-parses after every
    /// save, so anything that must survive a save keys on this instead.
    public var sidebarKey: String {
        primaryAlias ?? title
    }
}
