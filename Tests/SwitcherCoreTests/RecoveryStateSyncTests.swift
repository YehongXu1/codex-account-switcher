import Foundation
import Testing
@testable import SwitcherCore

@MainActor
struct RecoveryStateSyncTests {
    @Test func externalCompletionClearsOnlyRecoveryUIWithoutTouchingTheAccountOrHistory() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.failRecovery()
        let activeID = fixture.model.activeAccountID
        let auth = try Data(contentsOf: fixture.auth)
        let history = try Data(contentsOf: fixture.history)
        let usageReads = await fixture.client.usageReads

        await fixture.service.setStatus(.init(isPending: false))
        await fixture.model.refreshHerdrRecovery()

        #expect(!fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == nil)
        #expect(fixture.model.activeAccountID == activeID)
        #expect(fixture.model.activeIdentityConfirmed)
        #expect(try Data(contentsOf: fixture.auth) == auth)
        #expect(try Data(contentsOf: fixture.history) == history)
        #expect(await fixture.service.switchCalls == 0)
        #expect(await fixture.service.recoverCalls == 1)
        #expect(await fixture.client.usageReads == usageReads)
    }

    @Test func replacementJournalRemovesTheOldErrorButKeepsTheRecoveryAction() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.failRecovery()

        await fixture.service.setStatus(.init(isPending: true, revision: Data("new-recovery".utf8)))
        await fixture.model.refreshHerdrRecovery()

        #expect(fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == nil)
        #expect(await fixture.service.recoverCalls == 1)
    }

    @Test func unchangedJournalRetainsItsRealRecoveryFailure() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.failRecovery()
        let error = try #require(fixture.model.visibleError)

        await fixture.model.refreshHerdrRecovery()
        await fixture.model.refreshHerdrRecovery()

        #expect(fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == error)
        #expect(fixture.model.activeIdentityConfirmed)
    }

    @Test func unreadableJournalDoesNotDismissItsRecoveryFailure() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.failRecovery()
        let error = try #require(fixture.model.visibleError)

        await fixture.service.setStatus(.init(isPending: true, revision: nil))
        await fixture.model.refreshHerdrRecovery()

        #expect(fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == error)
        await fixture.service.setStatus(.init(isPending: true, revision: Data("readable-replacement".utf8)))
        await fixture.model.refreshHerdrRecovery()
        #expect(fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == nil)
    }

    @Test func recoveryChangesDoNotDismissUnrelatedErrors() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.model.start()
        let errors = [
            OperationError.stage(.reopenDesktop, CodexClientError.connectionClosed),
            OperationError.stage(.verifyTargetIdentity, AccountStoreError.activeCredentialMismatch),
            OperationError(stage: nil, titleKey: "operation_failed", messageKey: nil,
                           message: "Unable to save settings", underlyingDescription: nil),
        ]
        for error in errors {
            fixture.model.visibleError = error
            await fixture.service.setStatus(.init(isPending: true, revision: Data(UUID().uuidString.utf8)))
            await fixture.model.refreshHerdrRecovery()
            #expect(fixture.model.visibleError == error)
            await fixture.service.setStatus(.init(isPending: false))
            await fixture.model.refreshHerdrRecovery()
            #expect(fixture.model.visibleError == error)
        }
    }

    @Test(arguments: [false, true])
    func switchErrorKeepsItsRecoveryScopeWhenTheControllerRebuildsTheBanner(recoveryOnly: Bool) async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.model.start()
        let message = recoveryOnly
            ? "Herdr startup not confirmed"
            : "Herdr startup not confirmed; Codex Desktop also failed to reopen"
        await fixture.service.setSwitchError(OperationError(
            stage: .resumeHerdr, titleKey: "switch_failed", messageKey: nil,
            message: message, underlyingDescription: message,
            isSessionRecoveryOnly: recoveryOnly
        ))
        await fixture.model.switchAccount(to: UUID())
        await fixture.model.waitForWeeklyUsageRefresh()
        let banner = try #require(fixture.model.visibleError)
        #expect(banner.stage == .resumeHerdr)
        #expect(banner.titleKey == "switched_reopen_title")
        #expect(banner.isSessionRecoveryOnly == recoveryOnly)
        #expect(banner.message == message)

        await fixture.service.setStatus(.init(isPending: true, revision: Data("replacement-journal".utf8)))
        await fixture.model.refreshHerdrRecovery()
        #expect(fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == (recoveryOnly ? nil : banner))
        await fixture.service.setStatus(.init(isPending: false))
        await fixture.model.refreshHerdrRecovery()
        #expect(!fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == (recoveryOnly ? nil : banner))
        #expect(await fixture.service.switchCalls == 1)
        #expect(await fixture.service.recoverCalls == 0)
    }

    @Test func failedIdentityCheckIsNotMistakenForAnObsoleteRecoveryFailure() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.model.start()
        await fixture.service.setFailure(.identity)
        await fixture.model.recoverHerdrSessions()
        await fixture.model.waitForWeeklyUsageRefresh()
        let error = try #require(fixture.model.visibleError)
        #expect(error.stage == nil)
        #expect(error.message == AccountStoreError.activeCredentialMismatch.localizedDescription)

        await fixture.service.setStatus(.init(isPending: false))
        await fixture.model.refreshHerdrRecovery()

        #expect(!fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == error)
    }

    @Test func backgroundRefreshNoticesExternalCompletionWithoutOpeningTheMenu() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.failRecovery()
        let firstRead = RecoverySyncGate()
        await fixture.service.pauseNextStatus(at: firstRead)
        fixture.model.startBackgroundRecoveryRefresh(every: .milliseconds(10))
        await firstRead.waitUntilBlocked()
        await fixture.service.setStatus(.init(isPending: false))
        await firstRead.open()

        // The first query captured the old revision. A later timer tick must
        // notice completion, without a usage request or another recovery.
        for _ in 0..<200 {
            if !fixture.model.hasHerdrRecovery && fixture.model.visibleError == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == nil)
        #expect(await fixture.service.recoverCalls == 1)
    }

    @Test func passiveRefreshCannotClearStateDuringAnActiveRecovery() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.failRecovery()
        let error = fixture.model.visibleError
        let recovery = RecoverySyncGate()
        await fixture.service.pauseNextRecovery(at: recovery)
        await fixture.service.setFailure(.none)
        let operation = Task { await fixture.model.recoverHerdrSessions() }
        await recovery.waitUntilBlocked()
        #expect(fixture.model.isMutating)
        let reads = await fixture.service.statusReads

        await fixture.service.setStatus(.init(isPending: false))
        await fixture.model.refreshHerdrRecovery()
        #expect(await fixture.service.statusReads == reads)
        #expect(fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == error)

        await recovery.open()
        await operation.value
        await fixture.model.waitForWeeklyUsageRefresh()
        #expect(!fixture.model.isMutating)
        #expect(!fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == nil)
    }

    @Test func oldStatusResponseCannotOverwriteTheResultOfANewerRecovery() async throws {
        let fixture = try RecoverySyncFixture()
        defer { fixture.clean() }
        await fixture.failRecovery()
        await fixture.service.setStatus(.init(isPending: false))
        let oldQuery = RecoverySyncGate()
        await fixture.service.pauseNextStatus(at: oldQuery)
        let refresh = Task { await fixture.model.refreshHerdrRecovery() }
        await oldQuery.waitUntilBlocked()

        await fixture.service.setStatus(.init(isPending: true, revision: Data("later-journal".utf8)))
        await fixture.model.recoverHerdrSessions()
        await fixture.model.waitForWeeklyUsageRefresh()
        let currentError = fixture.model.visibleError
        #expect(currentError != nil)
        await oldQuery.open()
        await refresh.value

        #expect(fixture.model.hasHerdrRecovery)
        #expect(fixture.model.visibleError == currentError)
    }
}

@MainActor
private struct RecoverySyncFixture {
    let root: URL
    let auth: URL
    let history: URL
    let service: RecoverySyncService
    let client: RecoverySyncClient
    let model: AccountController

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-sync-\(UUID())")
        let home = root.appendingPathComponent("home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        auth = home.appendingPathComponent("auth.json")
        history = sessions.appendingPathComponent("original.jsonl")
        let claims = Data(#"{"email":"mia-fixture@example.test"}"#.utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: ["tokens": [
            "account_id": "mia-fixture", "access_token": "fixture-secret",
            "id_token": "header.\(claims).signature",
        ]]).write(to: auth)
        try Data("{\"message\":\"original conversation\"}\n".utf8).write(to: history)
        service = RecoverySyncService()
        client = RecoverySyncClient()
        model = AccountController(
            store: AccountStore(baseURL: root.appendingPathComponent("store"), activeHomeURL: home),
            codex: client, switchService: service
        )
    }

    func failRecovery() async {
        await model.start()
        await model.recoverHerdrSessions()
        await model.waitForWeeklyUsageRefresh()
        #expect(model.hasHerdrRecovery)
        #expect(model.visibleError?.stage == .resumeHerdr)
        #expect(model.visibleError?.isSessionRecoveryOnly == true)
    }

    func clean() {
        model.stopBackgroundRecoveryRefresh()
        model.stopBackgroundUsageRefresh()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RecoverySyncService: SwitchServicing {
    enum Failure: Sendable { case recovery, identity, none }
    private var status = SessionRecoveryStatus(isPending: true, revision: Data("original-journal".utf8))
    private var failure: Failure = .recovery
    private var switchError: OperationError?
    private var nextStatusGate: RecoverySyncGate?
    private var nextRecoveryGate: RecoverySyncGate?
    private(set) var statusReads = 0
    private(set) var switchCalls = 0
    private(set) var recoverCalls = 0

    func setStatus(_ value: SessionRecoveryStatus) { status = value }
    func setFailure(_ value: Failure) { failure = value }
    func setSwitchError(_ value: OperationError) { switchError = value }
    func pauseNextStatus(at gate: RecoverySyncGate) { nextStatusGate = gate }
    func pauseNextRecovery(at gate: RecoverySyncGate) { nextRecoveryGate = gate }

    func sessionRecoveryStatus() async -> SessionRecoveryStatus {
        statusReads += 1
        let captured = status
        let gate = nextStatusGate
        nextStatusGate = nil
        if let gate { await gate.block() }
        return captured
    }

    func switchAccount(to targetID: UUID) async throws {
        switchCalls += 1
        if let switchError { throw switchError }
    }

    func recoverSessions() async throws {
        recoverCalls += 1
        let gate = nextRecoveryGate
        nextRecoveryGate = nil
        if let gate { await gate.block() }
        switch failure {
        case .recovery:
            throw OperationError.stage(.resumeHerdr, HerdrCoordinatorError.failure("wK:p1 startup not confirmed"))
        case .identity:
            throw AccountStoreError.activeCredentialMismatch
        case .none:
            status = SessionRecoveryStatus(isPending: false)
        }
    }
}

private actor RecoverySyncGate {
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func block() async {
        await withCheckedContinuation { continuation in
            release = continuation
            blocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func open() { release?.resume(); release = nil }
}

private actor RecoverySyncClient: AccountClient {
    private(set) var usageReads = 0
    func readIdentity(profileHome: URL) async throws -> AccountIdentity {
        AccountIdentity(accountID: "mia-fixture", email: "mia-fixture@example.test")
    }
    func readWeeklyUsage(profileHome: URL) async throws -> WeeklyUsage {
        usageReads += 1
        return WeeklyUsage(remainingPercent: 70, resetsAt: Date().addingTimeInterval(86_400))
    }
    func login(profileHome: URL) async throws -> AccountIdentity {
        throw CodexClientError.loginFailed("Recovery synchronization must not log in")
    }
}
