public enum SyncDecision: Equatable, Sendable {
    case noop
    case push
    case pull
    case conflict
}

public enum GistSyncDecision {
    public static func decide(
        remoteVersion: String?, localHash: String,
        lastVersion: String?, lastHash: String?
    ) -> SyncDecision {
        guard lastVersion != nil || lastHash != nil else { return .push }
        let remoteMoved = remoteVersion != lastVersion
        let localMoved = localHash != lastHash
        switch (remoteMoved, localMoved) {
        case (false, false): return .noop
        case (false, true): return .push
        case (true, false): return .pull
        case (true, true): return .conflict
        }
    }

    public static func isTransient(_ error: Error) -> Bool {
        switch error {
        case GistError.networkError: return true
        case GistError.serverError(let code): return code == 503 || code == 0
        default: return false
        }
    }
}
