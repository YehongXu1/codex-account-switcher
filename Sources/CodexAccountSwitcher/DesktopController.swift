import SwitcherCore
import AppKit
import Foundation
import Darwin

enum DesktopControllerError: LocalizedError, Sendable {
    case applicationNotFound
    case quitRequestFailed
    case didNotExit
    case reopenFailed
    case executionHost
    case processAncestryUnavailable
    case recoveryInProgress

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            "The Codex Desktop application could not be found."
        case .quitRequestFailed:
            "Codex Desktop rejected the quit request."
        case .didNotExit:
            "Codex Desktop did not finish quitting within 30 seconds. Finish or stop active tasks and close Desktop, then switch again. The account has not changed."
        case .reopenFailed:
            "Codex Desktop could not be reopened. Open it manually to continue."
        case .executionHost:
            "This switch was started inside Codex Desktop. Quitting Desktop would interrupt the switch. Use the standalone Codex Account Switcher menu-bar app instead. No quit request was sent."
        case .processAncestryUnavailable:
            "The switch could not verify that it runs independently of Codex Desktop. No quit request was sent. Use the standalone Codex Account Switcher menu-bar app."
        case .recoveryInProgress:
            "A previous Desktop quit request is still being recovered. Wait for recovery to finish before switching again. No new quit request was sent."
        }
    }
}

/// A helper launched by Desktop must never quit its own execution host. Read only
/// parent process IDs, and reject incomplete or inconsistent process trees.
enum DesktopCloseSafety {
    static func validate(currentPID: pid_t, desktopPIDs: Set<pid_t>,
                         parentOf: (pid_t) -> pid_t?) throws {
        guard !desktopPIDs.isEmpty else { return }
        var pid = currentPID
        var visited = Set<pid_t>()
        for _ in 0..<128 {
            if desktopPIDs.contains(pid) { throw DesktopControllerError.executionHost }
            if pid == 1 { return }
            guard pid > 1, visited.insert(pid).inserted,
                  let parent = parentOf(pid), parent > 0 else {
                throw DesktopControllerError.processAncestryUnavailable
            }
            pid = parent
        }
        throw DesktopControllerError.processAncestryUnavailable
    }

    static func parentProcessID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// Only quit requests accepted by the OS participate in late-exit recovery.
struct DesktopQuitRecovery: Sendable {
    enum Action: Equatable { case none, wait, reopen }
    var requestedPIDs = Set<pid_t>()

    func action(runningPIDs: Set<pid_t>) -> Action {
        guard !requestedPIDs.isEmpty else { return .none }
        if !requestedPIDs.isDisjoint(with: runningPIDs) { return .wait }
        return runningPIDs.isEmpty ? .reopen : .none
    }
}

enum DesktopRecoveryStatus: String, Sendable {
    case notNeeded, waitingForExit, reopening, reopened, desktopStillRunning
    case replacementRunning, reopenFailed, reopenTimedOut, waitTimedOut, waitCancelled

    var isPending: Bool { self == .waitingForExit || self == .reopening }
}

/// Every callback must belong to the current attempt and its expected phase.
/// A late NSWorkspace completion must not revive an expired recovery or modify
/// a new switch that started after the reopen watchdog released the old one.
struct DesktopRecoveryState: Sendable {
    private(set) var generation = UUID()
    private(set) var status = DesktopRecoveryStatus.notNeeded

    mutating func reset() {
        generation = UUID()
        status = .notNeeded
    }

    mutating func beginWaiting() -> UUID {
        reset()
        status = .waitingForExit
        return generation
    }

    func isWaiting(generation: UUID) -> Bool {
        self.generation == generation && status == .waitingForExit
    }

    @discardableResult
    mutating func transition(generation: UUID, from: DesktopRecoveryStatus,
                             to: DesktopRecoveryStatus) -> Bool {
        guard self.generation == generation, status == from else { return false }
        status = to
        return true
    }
}

/// A command-line helper must keep its AppKit run loop alive until both the
/// observation and any asynchronous reopen finish. The menu-bar app need not wait.
struct DesktopRecoveryWaiter: Sendable {
    var timeout: Duration = .seconds(140)
    var pollInterval: Duration = .milliseconds(100)

    func wait(status: @Sendable () async -> DesktopRecoveryStatus) async -> DesktopRecoveryStatus {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let current = await status()
            guard current.isPending else { return current }
            if Task.isCancelled { return .waitCancelled }
            guard clock.now < deadline else { return .waitTimedOut }
            do { try await Task.sleep(for: min(pollInterval, deadline - clock.now)) }
            catch { return .waitCancelled }
        }
    }
}

// A quit request may be waiting for Desktop's active-task dialog or durable history writes.
// Expiry must stop the switch before credentials change; it must never escalate to SIGKILL.
struct DesktopQuitWaiter: Sendable {
    var timeout: Duration = .seconds(30)
    var pollInterval: Duration = .milliseconds(100)

    func wait(isRunning: @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await isRunning() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw DesktopControllerError.didNotExit }
            try await Task.sleep(for: min(pollInterval, deadline - clock.now))
        }
        try Task.checkCancellation()
    }
}

@MainActor
final class DesktopController: DesktopControlling {
    private let bundleIdentifiers = ["com.openai.codex"]
    private let applicationPaths = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
    private var recovery = DesktopQuitRecovery()
    private var terminationObserver: NSObjectProtocol?
    private var recoveryExpiry: Task<Void, Never>?
    private var reopenExpiry: Task<Void, Never>?
    private var recoveryState = DesktopRecoveryState()

    func validateCloseRequest() async throws {
        try validateCloseRequest(for: runningDesktopApplications)
    }

    private func validateCloseRequest(for applications: [NSRunningApplication]) throws {
        guard !recoveryState.status.isPending else { throw DesktopControllerError.recoveryInProgress }
        try DesktopCloseSafety.validate(currentPID: getpid(),
            desktopPIDs: Set(applications.map(\.processIdentifier)),
            parentOf: DesktopCloseSafety.parentProcessID)
    }

    func closeDesktop() async throws {
        let running = runningDesktopApplications
        // Repeat the preflight against the actual processes being closed. The
        // separate validation method lets SwitchService fail before Herdr prep.
        try validateCloseRequest(for: running)
        stopRecoveryObservation()
        stopReopenWatchdog()
        recovery = DesktopQuitRecovery()
        recoveryState.reset()
        guard !running.isEmpty else { return }
        for application in running where !application.isTerminated {
            let processIdentifier = application.processIdentifier
            guard application.terminate() || !isDesktopRunning(processIdentifier: processIdentifier) else {
                throw DesktopControllerError.quitRequestFailed
            }
            recovery.requestedPIDs.insert(processIdentifier)
        }

        try await DesktopQuitWaiter().wait {
            await self.isDesktopRunning
        }
    }

    func recoverAfterCloseFailure() async throws {
        guard !recovery.requestedPIDs.isEmpty else { return }
        // Register before taking the snapshot so an exit between them cannot be
        // missed. A timeout is not proof that Desktop will remain open.
        stopRecoveryObservation()
        stopReopenWatchdog()
        let generation = recoveryState.beginWaiting()
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [self] _ in
            // Retain the recovery owner until the bounded expiry removes this
            // observer, even if the short-lived operation releases its service.
            Task { @MainActor in
                do { try await self.recoverIfDesktopExited(generation: generation) }
                catch { NSLog("Codex Account Switcher: late Desktop reopen failed; open Desktop manually.") }
            }
        }
        // Bound the observer lifetime; do not intercept a later, unrelated quit.
        recoveryExpiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(120)) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.recoveryState.transition(generation: generation, from: .waitingForExit,
                                                to: .desktopStillRunning) else { return }
            self.stopRecoveryObservation()
            self.recovery = DesktopQuitRecovery()
        }
        // Do not await a possibly slow NSWorkspace open here. A CLI caller must
        // reach its bounded drain even when Desktop has already exited.
        Task { @MainActor in
            do { try await self.recoverIfDesktopExited(generation: generation) }
            catch { NSLog("Codex Account Switcher: Desktop reopen failed; open Desktop manually.") }
        }
    }

    func waitForCloseFailureRecovery() async -> DesktopRecoveryStatus {
        await DesktopRecoveryWaiter().wait { await self.recoveryState.status }
    }

    private func recoverIfDesktopExited(generation: UUID) async throws {
        guard recoveryState.isWaiting(generation: generation) else { return }
        let runningPIDs = Set(runningDesktopApplications.map(\.processIdentifier))
        switch recovery.action(runningPIDs: runningPIDs) {
        case .wait: return
        case .none:
            recoveryState.transition(generation: generation, from: .waitingForExit,
                                     to: .replacementRunning)
            stopRecoveryObservation()
            recovery = DesktopQuitRecovery()
        case .reopen:
            // Clear before awaiting to ensure simultaneous notifications cannot
            // submit duplicate opens. The error remains visible to the caller.
            stopRecoveryObservation()
            recovery = DesktopQuitRecovery()
            recoveryState.transition(generation: generation, from: .waitingForExit, to: .reopening)
            // NSWorkspace can leave its asynchronous completion pending. Release
            // this attempt after 15 seconds so manual recovery or a retry works.
            reopenExpiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                guard !Task.isCancelled, let self,
                      self.recoveryState.transition(generation: generation, from: .reopening,
                                                    to: .reopenTimedOut) else { return }
                self.reopenExpiry = nil
                NSLog("Codex Account Switcher: Desktop reopen timed out; open Desktop manually.")
            }
            do {
                try await openDesktop()
                guard recoveryState.transition(generation: generation, from: .reopening,
                                               to: .reopened) else { return }
                stopReopenWatchdog()
            } catch {
                guard recoveryState.transition(generation: generation, from: .reopening,
                                               to: .reopenFailed) else { return }
                stopReopenWatchdog()
                throw error
            }
        }
    }

    private func stopRecoveryObservation() {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        recoveryExpiry?.cancel()
        recoveryExpiry = nil
    }

    private func stopReopenWatchdog() {
        reopenExpiry?.cancel()
        reopenExpiry = nil
    }

    func reopenDesktop() async throws {
        stopRecoveryObservation()
        stopReopenWatchdog()
        recovery = DesktopQuitRecovery()
        recoveryState.reset()
        try await openDesktop()
    }

    private func openDesktop() async throws {
        guard let url = applicationURL() else {
            throw DesktopControllerError.applicationNotFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw DesktopControllerError.reopenFailed
        }
    }

    private func applicationURL() -> URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return applicationPaths
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private var isDesktopRunning: Bool {
        !runningDesktopApplications.isEmpty
    }

    private var runningDesktopApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return bundleIdentifiers.contains(bundleIdentifier)
        }
    }

    private func isDesktopRunning(processIdentifier: pid_t) -> Bool {
        runningDesktopApplications.contains { $0.processIdentifier == processIdentifier }
    }
}
