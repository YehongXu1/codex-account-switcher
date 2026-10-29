import Foundation
import SwitcherCore
import Darwin
import AppKit

/// One production operation per invocation. An external orchestrator owns the
/// alternate-account / original-account round trip and its unconditional return.
/// This program prints only sanitized metadata; it never prints credentials or RPC diagnostics.
@main
struct HerdrRoundtripCheck {
    @MainActor static func main() {
        // NSWorkspace lifecycle observations require a real AppKit run loop.
        // An async command-line main only drains the dispatch queue, which can
        // leave runningApplications stale after a successful Desktop quit.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await execute()
            exit(0)
        }
        application.run()
    }

    @MainActor private static func execute() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first, ["switch", "usage", "inspect", "recover"].contains(mode),
              args.count == ((mode == "switch" || mode == "usage") ? 3 : 2),
              let outputPath = args.last, outputPath.hasPrefix("/") else {
            print("Usage: HerdrRoundtripCheck switch|usage <profile-UUID> /absolute/result.json; inspect|recover /absolute/result.json")
            exit(2)
        }
        let requested = (mode == "switch" || mode == "usage") ? UUID(uuidString: args[1]) : nil
        if (mode == "switch" || mode == "usage") && requested == nil { exit(2) }
        let output = URL(fileURLWithPath: outputPath)
        let store = AccountStore()
        let identityReader = CredentialIdentity()
        let sessions = HerdrCoordinator()
        let service = SwitchService(desktop: DesktopController(), store: store,
                                    codex: identityReader, sessions: sessions)
        var report: [String: Any] = ["mode": mode, "status": "started", "timestamp": timestamp()]
        if let requested { report["requestedProfileID"] = requested.uuidString }
        do {
            try write(report, to: output)
            let registry = try await store.loadRegistry()
            guard let activeID = registry.activeAccountID else { throw CheckError.noActiveProfile }
            let activeProfile = try await store.profile(id: activeID)
            let activeHome = await store.activeCodexHome()
            let liveIdentity = try await identityReader.readIdentity(profileHome: activeHome)
            guard liveIdentity.matches(activeProfile) else { throw CheckError.activeIdentityMismatch }
            addIdentity(liveIdentity, profileID: activeID, to: &report)
            report["pendingRecovery"] = await service.hasPendingSessionRecovery()

            switch mode {
            case "inspect": break
            case "recover":
                try await service.recoverSessions()
            case "usage":
                guard let requested else { throw CheckError.invalidProfile }
                let profile = try await store.profile(id: requested)
                // The live account may have refreshed since its saved snapshot was made.
                let home = requested == activeID ? activeHome : await store.profileHome(id: requested)
                let local = try await identityReader.readIdentity(profileHome: home)
                guard local.matches(profile) else { throw CheckError.savedIdentityMismatch }
                let client = CodexClient(requestTimeout: .seconds(30))
                let account = try await client.readIdentity(profileHome: home)
                guard account.matches(profile) else { throw CheckError.remoteIdentityMismatch }
                let usage = try await client.readWeeklyUsage(profileHome: home)
                let refreshed = try await identityReader.readIdentity(profileHome: home)
                guard refreshed.matches(profile) else { throw CheckError.savedIdentityMismatch }
                report["usageProfileID"] = requested.uuidString
                report["usageEmail"] = refreshed.email
                report["usageAccountID"] = refreshed.accountID
                report["remainingPercent"] = usage.remainingPercent
                report["resetsAt"] = ISO8601DateFormatter().string(from: usage.resetsAt)
            case "switch":
                guard let requested else { throw CheckError.invalidProfile }
                guard !(await service.hasPendingSessionRecovery()) else { throw CheckError.pendingRecovery }
                let target = try await store.profile(id: requested)
                let targetHome = requested == activeID ? activeHome : await store.profileHome(id: requested)
                let saved = try await identityReader.readIdentity(profileHome: targetHome)
                guard saved.matches(target) else { throw CheckError.savedIdentityMismatch }
                if requested != activeID { try await service.switchAccount(to: requested) }
                let current = try await store.loadRegistry()
                let installed = try await identityReader.readIdentity(profileHome: activeHome)
                guard current.activeAccountID == requested, installed.matches(target) else { throw CheckError.activeIdentityMismatch }
                addIdentity(installed, profileID: requested, to: &report)
            default: throw CheckError.invalidProfile
            }
            report["status"] = "completed"
            report["pendingRecovery"] = await service.hasPendingSessionRecovery()
            report["timestamp"] = timestamp()
            try write(report, to: output)
            printJSON(report)
        } catch {
            report["status"] = "failed"
            report["timestamp"] = timestamp()
            report["errorType"] = String(reflecting: type(of: error))
            if let error = error as? OperationError {
                report["errorStage"] = error.stage?.rawValue
                // Handoff stages only emit coordinator/desktop diagnostics, not auth RPC bodies.
                if let stage = error.stage, [.prepareHerdr, .suspendHerdr, .resumeHerdr].contains(stage) {
                    report["handoffDiagnostic"] = error.message
                }
            }
            if let error = error as? HerdrCoordinatorError { report["handoffDiagnostic"] = error.localizedDescription }
            if let error = error as? CheckError { report["errorCategory"] = error.rawValue }
            report["pendingRecovery"] = await service.hasPendingSessionRecovery()
            // Report the actual post-failure state; an error after commit can keep the target active.
            let observedStore = AccountStore()
            if let observedRegistry = try? await observedStore.loadRegistry() {
                report["observedActiveProfileID"] = observedRegistry.activeAccountID?.uuidString
            }
            if let observed = try? await identityReader.readIdentity(profileHome: observedStore.activeCodexHome()) {
                report["observedEmail"] = observed.email
                report["observedAccountID"] = observed.accountID
            }
            // Never forward localizedDescription / underlyingDescription from auth or RPC errors.
            try? write(report, to: output)
            printJSON(report)
            exit(1)
        }
    }

    private static func addIdentity(_ identity: AccountIdentity, profileID: UUID, to report: inout [String: Any]) {
        report["activeProfileID"] = profileID.uuidString
        report["email"] = identity.email
        report["accountID"] = identity.accountID
    }
    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func printJSON(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys),
              let string = String(data: data, encoding: .utf8) else { return }
        print(string)
    }
    private enum CheckError: String, Error {
        case noActiveProfile, invalidProfile, activeIdentityMismatch, savedIdentityMismatch
        case remoteIdentityMismatch, pendingRecovery
    }
}
