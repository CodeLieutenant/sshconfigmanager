/// `HostMetadata.PersistedGroupRecord` is Identifiable already, but ForEach in a
/// menu reads better with one named box beside the others.
struct GroupBox: Identifiable {
    let id: String
    let group: HostMetadata.PersistedGroupRecord

    static func boxes(_ groups: [HostMetadata.PersistedGroupRecord]) -> [GroupBox] {
        groups.map { .init(id: $0.name, group: $0) }
    }
}
