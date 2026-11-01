@testable import SwitcherCore
import Foundation
import Darwin
import Testing
@testable import CodexAccountSwitcher

struct DesktopControllerTests {
    @Test func allowsIndependentMenuBarApp() throws {
        try DesktopCloseSafety.validate(currentPID: 400, desktopPIDs: [100]) { pid in
            [400: 1][pid]
        }
    }

    @Test func refusesHelperLaunchedByDesktopThroughShellAndAppServer() {
        do {
            try DesktopCloseSafety.validate(currentPID: 400, desktopPIDs: [100]) { pid in
                [400: 300, 300: 200, 200: 100, 100: 1][pid]
            }
            Issue.record("Expected execution-host protection")
        } catch DesktopControllerError.executionHost {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func refusesToCloseTheCurrentProcess() {
        do {
            try DesktopCloseSafety.validate(currentPID: 100, desktopPIDs: [100]) { _ in 1 }
            Issue.record("Expected execution-host protection")
        } catch DesktopControllerError.executionHost {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unknownOrCyclicAncestryFailsClosed() {
        let trees: [[pid_t: pid_t]] = [[:], [400: 0], [400: 300, 300: 400]]
        for tree in trees {
            do {
                try DesktopCloseSafety.validate(currentPID: 400, desktopPIDs: [100]) { tree[$0] }
                Issue.record("Expected refusal for an unverifiable process tree")
            } catch DesktopControllerError.processAncestryUnavailable {
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func ancestryTraversalIsBounded() {
        do {
            try DesktopCloseSafety.validate(currentPID: 400, desktopPIDs: [100]) { $0 + 1 }
            Issue.record("Expected bounded traversal")
        } catch DesktopControllerError.processAncestryUnavailable {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func noDesktopNeedsNoAncestryInspection() throws {
        try DesktopCloseSafety.validate(currentPID: 400, desktopPIDs: []) { _ in
            Issue.record("Unexpected process inspection")
            return nil
        }
    }

    @Test func rejectedQuitDoesNotReopenDesktop() {
        let recovery = DesktopQuitRecovery()
        #expect(recovery.action(runningPIDs: [100]) == .none)
        #expect(recovery.action(runningPIDs: []) == .none)
    }

    @Test func acceptedQuitCanRecoverAfterItTimesOutThenExits() {
        var recovery = DesktopQuitRecovery()
        recovery.requestedPIDs.insert(100)
        #expect(recovery.action(runningPIDs: [100]) == .wait)
        #expect(recovery.action(runningPIDs: []) == .reopen)
    }

    @Test func recoveryWaitsForEveryAcceptedQuitAndAvoidsReplacementDesktop() {
        var recovery = DesktopQuitRecovery()
        recovery.requestedPIDs = [100, 200]
        #expect(recovery.action(runningPIDs: [100, 200]) == .wait)
        #expect(recovery.action(runningPIDs: [200]) == .wait)
        #expect(recovery.action(runningPIDs: [300]) == .none)
        #expect(recovery.action(runningPIDs: []) == .reopen)
    }

    @Test func helperWaitsForAsynchronousReopenAfterObservationEnds() async {
        let statuses = RecoveryStatusSequence([.waitingForExit, .reopening, .reopening, .reopened])
        let result = await DesktopRecoveryWaiter(timeout: .seconds(1), pollInterval: .milliseconds(1))
            .wait { await statuses.next() }
        #expect(result == .reopened)
        #expect(await statuses.readCount == 4)
    }

    @Test func helperReportsReopenFailureInsteadOfClaimingRecovery() async {
        let statuses = RecoveryStatusSequence([.waitingForExit, .reopening, .reopenFailed])
        let result = await DesktopRecoveryWaiter(timeout: .seconds(1), pollInterval: .milliseconds(1))
            .wait { await statuses.next() }
        #expect(result == .reopenFailed)
    }

    @Test func helperRecoveryWaitIsBoundedEvenIfOpenNeverCompletes() async {
        let result = await DesktopRecoveryWaiter(timeout: .zero).wait { .reopening }
        #expect(result == .waitTimedOut)
    }

    @Test func helperDoesNotWaitAfterRecoveryExpiresOrWasNotNeeded() async {
        for status in [DesktopRecoveryStatus.desktopStillRunning, .notNeeded, .replacementRunning] {
            let result = await DesktopRecoveryWaiter(timeout: .zero).wait { status }
            #expect(result == status)
        }
    }

    @Test func allowsHistoryFlushToTakeLongerThanTwoSeconds() async throws {
        let clock = ContinuousClock()
        let exitsAt = clock.now.advanced(by: .milliseconds(2_100))
        try await DesktopQuitWaiter().wait { clock.now < exitsAt }
        #expect(clock.now >= exitsAt)
    }

    @Test func reportsTimeoutWhileDesktopStillRuns() async {
        do {
            try await DesktopQuitWaiter(timeout: .milliseconds(10)).wait { true }
            Issue.record("Expected quit timeout")
        } catch DesktopControllerError.didNotExit {
            // No force-quit or credential mutation is available to the waiter.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func returnsImmediatelyWhenDesktopHasExited() async throws {
        try await DesktopQuitWaiter(timeout: .zero).wait { false }
    }

    @Test func cancellationStopsWaiting() async {
        let task = Task { try await DesktopQuitWaiter().wait { true } }
        task.cancel()
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor RecoveryStatusSequence {
    private var statuses: [DesktopRecoveryStatus]
    private(set) var readCount = 0

    init(_ statuses: [DesktopRecoveryStatus]) { self.statuses = statuses }

    func next() -> DesktopRecoveryStatus {
        readCount += 1
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses[0]
    }
}
