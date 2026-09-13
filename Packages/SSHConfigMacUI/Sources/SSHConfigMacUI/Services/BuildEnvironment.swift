import Foundation
import StoreKit

/// Observable flag exposing "is this a beta/dev build?" to the UI. Inject nothing —
/// read `BuildEnvironment.shared.isBeta` directly; it's `@Observable`, so any view that
/// reads it re-renders when the AppTransaction lookup completes shortly after launch.
@MainActor
@Observable
final class BuildEnvironment {
    static let shared = BuildEnvironment()

    /// True for TestFlight + Xcode/dev builds; false for App Store production.
    ///
    /// The default is deliberately conservative: DEBUG starts `true`, Release starts
    /// `false`. `refresh()` then refines the Release value from AppTransaction. If that
    /// read ever fails we leave it `false`, so a real App Store install can never
    /// accidentally surface a tester-only control.
    private(set) var isBeta: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    private init() {}

    nonisolated static var gitHubGistClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GitHubGistClientID") as? String,
            !value.isEmpty, !value.hasPrefix("$(")
        else { return nil }
        return value
    }

    /// Resolve the App Store environment once. Cheap to call again (idempotent).
    func refresh() async {
        #if DEBUG
            isBeta = true
        #else
            do {
                let result = try await AppTransaction.shared
                let environment: AppStore.Environment
                switch result {
                case .verified(let t), .unverified(let t, _): environment = t.environment
                }
                // Anything that isn't the App Store (sandbox = TestFlight, xcode = dev) is beta.
                isBeta = environment != .production
            } catch {
                // Couldn't read it (e.g. offline first launch) — stay non-beta so the reset
                // never shows on an unverified install that might be production.
                isBeta = false
            }
        #endif
    }
}
