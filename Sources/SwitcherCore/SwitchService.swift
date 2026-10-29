import Foundation

// The same ordered handoff and bounded restoration run on both platforms.

public protocol DesktopControlling: Sendable {
    func closeDesktop() async throws
    func reopenDesktop() async throws
}

public protocol CodexIdentityReading: Sendable {
    func readIdentity(profileHome: URL) async throws -> AccountIdentity
}

public protocol SwitchServicing: Sendable {
    func switchAccount(to targetID: UUID) async throws
    func hasPendingSessionRecovery() async -> Bool
    func recoverSessions() async throws
}

public extension SwitchServicing {
    func hasPendingSessionRecovery() async -> Bool { false }
    func recoverSessions() async throws {}
}

public struct SwitchService: SwitchServicing {
    public let desktop: any DesktopControlling
    public let store: any AccountStoring
    public let codex: any CodexIdentityReading
    public let sessions: any HerdrSessionCoordinating

    public init(desktop: any DesktopControlling, store: any AccountStoring,
                codex: any CodexIdentityReading,
                sessions: any HerdrSessionCoordinating = NoopHerdrCoordinator()) {
        self.desktop = desktop; self.store = store; self.codex = codex; self.sessions = sessions
    }

    public func hasPendingSessionRecovery() async -> Bool { await sessions.hasPendingRecovery() }
    public func recoverSessions() async throws {
        let registry = try await store.loadRegistry()
        guard let activeID = registry.activeAccountID,
              let profile = registry.accounts.first(where: { $0.id == activeID }) else {
            throw AccountStoreError.activeProfileMissing
        }
        let identity = try await codex.readIdentity(profileHome: await store.activeCodexHome())
        guard identity.matches(profile) else { throw AccountStoreError.activeCredentialMismatch }
        try await sessions.resume()
    }

    public func switchAccount(to targetID: UUID) async throws {
        let target: AccountProfile
        let originalActiveID: UUID?
        let originalProfile: AccountProfile?
        do {
            target = try await store.profile(id: targetID)
        } catch {
            throw OperationError.stage(.activateTargetCredential, error)
        }
        do {
            let registry = try await store.loadRegistry()
            originalActiveID = registry.activeAccountID
            if let activeID = originalActiveID {
                guard let profile = registry.accounts.first(where: { $0.id == activeID }) else {
                    throw AccountStoreError.activeProfileMissing
                }
                originalProfile = profile
            } else {
                guard await !store.activeCredentialExists() else { throw AccountStoreError.activeProfileMissing }
                originalProfile = nil
            }
        } catch {
            throw OperationError.stage(.saveCurrentCredential, error)
        }
        // Preflight all terminal sessions before closing anything or changing credentials.
        do { try await sessions.prepare() }
        catch { throw OperationError.stage(.prepareHerdr, error) }

        var stage = SwitchStage.closeDesktop
        var desktopClosed = false
        var credentialMayHaveChanged = false
        var committed = false
        do {
            try await desktop.closeDesktop()
            desktopClosed = true
            stage = .suspendHerdr
            try await sessions.suspend()
            stage = .saveCurrentCredential
            if let originalProfile {
                let identity = try await codex.readIdentity(profileHome: await store.activeCodexHome())
                guard identity.matches(originalProfile) else { throw AccountStoreError.activeCredentialMismatch }
                try await store.saveCurrentCredential()
            } else if await store.activeCredentialExists() {
                throw AccountStoreError.activeCredentialMismatch
            }
            stage = .activateTargetCredential
            credentialMayHaveChanged = true
            try await store.activateTargetCredential(id: targetID)
            stage = .verifyTargetIdentity
            let identity = try await codex.readIdentity(profileHome: await store.activeCodexHome())
            guard identity.matches(target) else { throw CodexClientError.identityUnavailable }
            stage = .commitActiveAccountID
            try await store.commitActiveAccountID(targetID)
            committed = true
            stage = .resumeHerdr
            try await sessions.resume()
            stage = .reopenDesktop
            try await desktop.reopenDesktop()
        } catch {
            let primaryError = error
            var recoveryFailures: [String] = []
            var credentialsSafe = true
            if !committed && credentialMayHaveChanged {
                do {
                    if let originalActiveID, let originalProfile {
                        try await store.restoreActiveCredential(id: originalActiveID)
                        let identity = try await codex.readIdentity(profileHome: await store.activeCodexHome())
                        guard identity.matches(originalProfile) else { throw AccountStoreError.activeCredentialMismatch }
                    } else if await store.activeCredentialExists() {
                        try await store.clearActiveCredential()
                    }
                } catch {
                    credentialsSafe = false
                    recoveryFailures.append("Restoring the previous credential failed: \(error.localizedDescription)")
                }
            }
            if !committed && credentialsSafe && desktopClosed {
                do {
                    if let originalProfile {
                        let identity = try await codex.readIdentity(profileHome: await store.activeCodexHome())
                        guard identity.matches(originalProfile) else { throw AccountStoreError.activeCredentialMismatch }
                    } else if await store.activeCredentialExists() {
                        throw AccountStoreError.activeCredentialMismatch
                    }
                } catch {
                    credentialsSafe = false
                    recoveryFailures.append("Confirm the current account before recovering Herdr chats: \(error.localizedDescription)")
                }
            }
            if !committed && credentialsSafe {
                do { try await sessions.resume() }
                catch { recoveryFailures.append("Restoring Herdr sessions failed: \(error.localizedDescription)") }
            }
            // A post-commit Herdr failure keeps the selected account and its recovery journal.
            // Still reopen Desktop so the result and recovery controls remain reachable.
            if desktopClosed && stage != .reopenDesktop && credentialsSafe {
                do { try await desktop.reopenDesktop() }
                catch { recoveryFailures.append("Reopening Codex Desktop failed: \(error.localizedDescription)") }
            }
            if recoveryFailures.isEmpty { throw OperationError.stage(stage, primaryError) }
            throw OperationError(stage: stage, titleKey: "switch_failed", messageKey: nil,
                message: ([primaryError.localizedDescription] + recoveryFailures).joined(separator: "\n"),
                underlyingDescription: String(describing: primaryError) + "; restoration: " + recoveryFailures.joined(separator: "; "))
        }
    }
}
