import SSHConfigSync
import Testing

struct GistSyncDecisionTests {
    @Test func firstEverSyncPushes() {
        let decision = GistSyncDecision.decide(
            remoteVersion: nil, localHash: "abc", lastVersion: nil, lastHash: nil)
        #expect(decision == .push)
    }

    @Test func neitherMovedIsNoop() {
        let decision = GistSyncDecision.decide(
            remoteVersion: "v1", localHash: "abc", lastVersion: "v1", lastHash: "abc")
        #expect(decision == .noop)
    }

    @Test func onlyLocalMovedPushes() {
        let decision = GistSyncDecision.decide(
            remoteVersion: "v1", localHash: "def", lastVersion: "v1", lastHash: "abc")
        #expect(decision == .push)
    }

    @Test func onlyRemoteMovedPulls() {
        let decision = GistSyncDecision.decide(
            remoteVersion: "v2", localHash: "abc", lastVersion: "v1", lastHash: "abc")
        #expect(decision == .pull)
    }

    @Test func bothMovedConflicts() {
        let decision = GistSyncDecision.decide(
            remoteVersion: "v2", localHash: "def", lastVersion: "v1", lastHash: "abc")
        #expect(decision == .conflict)
    }

    @Test func networkErrorIsTransient() {
        #expect(GistSyncDecision.isTransient(GistError.networkError("offline")))
    }

    @Test func serverUnavailableIsTransient() {
        #expect(GistSyncDecision.isTransient(GistError.serverError(statusCode: 503)))
        #expect(GistSyncDecision.isTransient(GistError.serverError(statusCode: 0)))
    }

    @Test func unauthorizedIsTerminal() {
        #expect(!GistSyncDecision.isTransient(GistError.unauthorized))
    }

    @Test func clientErrorIsTerminal() {
        #expect(!GistSyncDecision.isTransient(GistError.serverError(statusCode: 422)))
    }
}
