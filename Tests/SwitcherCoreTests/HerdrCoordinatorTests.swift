@testable import SwitcherCore
import Foundation
import Testing

struct HerdrCoordinatorTests {
    @Test func roundTripKeepsExactThreadsAndOnlyWritesRecoveryMetadata() async throws {
        let fixture = try Fixture(count: 2)
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        #expect(await fixture.runner.mutations().isEmpty)
        let metadata = try String(contentsOf: fixture.journal, encoding: .utf8)
        #expect(metadata.contains(fixture.ids[0]))
        #expect(!metadata.contains("access_token"))
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.journal.path)[.posixPermissions] as? Int) == 0o600)
        try await fixture.coordinator.suspend()
        #expect(await fixture.runner.quits() == ["w1:p1", "w1:p2"])
        try await fixture.coordinator.resume()
        let commands = await fixture.runner.starts()
        #expect(commands.count == 2)
        #expect(commands[0].contains("--no-daemon"))
        #expect(commands[0].contains("resume '\(fixture.ids[0])'"))
        #expect(!commands[0].contains("--last"))
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
        // The generated -C arguments must remain eligible for the next account switch.
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.resume()
    }

    @Test func prepareOnlyRecoveryDoesNotTouchAnyPane() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.mutations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func externalJournalRemovalClearsCachedRecoveryWithoutRestartingApp() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        let pending = await fixture.coordinator.recoveryStatus()
        #expect(pending.isPending)
        #expect(pending.revision != nil)
        try FileManager.default.removeItem(at: fixture.journal)
        #expect(await fixture.coordinator.recoveryStatus() == SessionRecoveryStatus(isPending: false))
        await #expect(throws: (any Error).self) { try await fixture.coordinator.suspend() }
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.mutations().isEmpty)
        // A subsequent switch must also be allowed, rather than blocked by old memory.
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.resume()
    }

    @Test(arguments: [false, true])
    func externalPreparedJournalChangeStopsHandoffBeforeAnyQuit(_ replacement: Bool) async throws {
        let fixture = try Fixture(count: 2)
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        if replacement {
            var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journal)) as? [String: Any])
            let records = try #require(metadata["records"] as? [[String: Any]])
            metadata["records"] = [records[0]]
            try JSONSerialization.data(withJSONObject: metadata).write(to: fixture.journal, options: .atomic)
        } else {
            // A recovery helper sees only prepared records and clears them while
            // the GUI is still waiting for Desktop to close.
            try await fixture.makeCoordinator().resume()
        }
        // Passive refresh may clear the old cache, but must retain the handoff precondition.
        _ = await fixture.coordinator.recoveryStatus()
        await #expect(throws: (any Error).self) { try await fixture.coordinator.suspend() }
        #expect(await fixture.runner.mutations().isEmpty)
        try await fixture.coordinator.resume()
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 2)
    }

    @Test func operationReloadsDeletedJournalEvenWithoutStatusRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        try FileManager.default.removeItem(at: fixture.journal)
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().isEmpty)
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
    }

    @Test(arguments: [false, true])
    func externalJournalReplacementSupersedesCachedRecords(_ refreshFirst: Bool) async throws {
        let fixture = try Fixture(count: 2)
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        let previousRevision = try Data(contentsOf: fixture.journal)
        var replacement = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journal)) as? [String: Any])
        var records = try #require(replacement["records"] as? [[String: Any]])
        records[0]["state"] = "resumed"
        replacement["records"] = records
        try JSONSerialization.data(withJSONObject: replacement).write(to: fixture.journal, options: .atomic)
        if refreshFirst {
            let current = await fixture.coordinator.recoveryStatus()
            #expect(current.isPending)
            #expect(current.revision != previousRevision)
        }
        try await fixture.coordinator.resume()
        let commands = await fixture.runner.starts()
        #expect(commands.count == 1)
        #expect(commands.first?.contains("resume '\(fixture.ids[1])'") == true)
    }

    @Test(arguments: [false, true])
    func invalidJournalReplacementNeverReplaysCachedRecords(_ directory: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        if directory {
            try FileManager.default.removeItem(at: fixture.journal)
            try FileManager.default.createDirectory(at: fixture.journal, withIntermediateDirectories: false)
        } else {
            try Data("not a recovery journal".utf8).write(to: fixture.journal, options: .atomic)
        }
        await #expect(throws: (any Error).self) { try await fixture.coordinator.resume() }
        #expect(await fixture.coordinator.hasPendingRecovery())
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.starts().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func externalSuccessfulRecoveryIsObservedByOriginalCoordinator() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        try await fixture.makeCoordinator().resume()
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func statusRefreshDuringSuspensionPreservesInFlightJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        let coordinator = fixture.coordinator
        let journalURL = fixture.journal
        await fixture.runner.setQuitHook {
            // The actor is suspended awaiting this command. An intervening status
            // query must not discard its in-progress journal, even if disk changes.
            try FileManager.default.removeItem(at: journalURL)
            #expect(await coordinator.recoveryStatus().isPending)
        }
        try await fixture.coordinator.suspend()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
    }

    @Test(arguments: ["›", "»"])
    func emptyComposerVariantsKeepExactConversation(_ glyph: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.runner.setComposer("""
        › An earlier user message
        A completed response

        \(glyph) Ask Codex to do anything

          GPT-6-Astra ultra · ~/repo · Original conversation
          ? for shortcuts                                      ⚠ 1 warning · f2 to view
        """)
        try await fixture.coordinator.prepare()
        #expect(await fixture.runner.mutations().isEmpty)
        try await fixture.coordinator.suspend()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.quits() == ["w1:p1"])
        let commands = await fixture.runner.starts()
        #expect(commands.count == 1)
        #expect(commands.first?.contains("resume '\(fixture.ids[0])'") == true)
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
    }

    @Test(arguments: ["›", "»"])
    func draftAndTranscriptVariantsNeverReceiveQuit(_ glyph: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let footer = "GPT-6-Astra ultra · ~/repo"
        let outputs = [
            "\(glyph) unsent draft\n\(footer)\n? for shortcuts",
            "\(glyph) Ask Codex to do anything\n  continued draft\n\(footer)\n? for shortcuts",
            "\(glyph) \n  multiline draft\n\(footer)\n? for shortcuts              ⚠ 1 warning · f2 to view",
            "\(glyph) Ask Codex to do anything\n\(footer)\nBrowsing transcript · ↑↓/jk scroll · ←→/hl prompts · ⌃t details · ↵ rewind · esc back",
            "\(glyph) Ask Codex to do anything\n\(footer)\nNew activity · Earlier messages available.  enter/esc latest · ? shortcuts",
            "\(glyph) Ask Codex to do anything\n\(footer)\nesc again to edit previous message",
            "\(glyph) Ask Codex to do anything\n\(footer)\n? for shortcuts · unknown mode"
        ]
        for output in outputs {
            await fixture.runner.setComposer(output)
            await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
            #expect(await fixture.runner.mutations().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        }
    }

    @Test(arguments: ["working", "blocked", "unknown"])
    func busyOrUncertainAgentBlocksBeforeAnyQuit(_ status: String) async throws {
        let fixture = try Fixture(count: 2)
        defer { fixture.clean() }
        await fixture.runner.setStatus("w1:p2", status)
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func missingThreadOrDraftNeverGetsSubmitted() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.runner.setComposer("› unfinished user request\nGPT-6-Sol low · ~/repo")
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
        await fixture.runner.setComposer("› Ask Codex to do anything\nGPT-6-Sol low · ~/repo")
        await fixture.runner.setThread("w1:p1", "unknown")
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
    }

    @Test func changedTerminalAfterPreparePreventsQuit() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        await fixture.runner.replaceTerminal("w1:p1")
        await #expect(throws: (any Error).self) { try await fixture.coordinator.suspend() }
        #expect(await fixture.runner.mutations().isEmpty)
    }

    @Test func partialFailureRestartsOnlyAlreadyStoppedPane() async throws {
        let fixture = try Fixture(count: 2)
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        await fixture.runner.failQuit("w1:p2")
        await #expect(throws: (any Error).self) { try await fixture.coordinator.suspend() }
        await #expect(throws: (any Error).self) { try await fixture.coordinator.resume() }
        #expect(await fixture.runner.starts().count == 1)
        #expect(await fixture.coordinator.hasPendingRecovery())
    }

    @Test func lostResumeResponseIsVerifiedWithoutResendingCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.loseNextResumeResponse()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
    }

    @Test func replacementConversationIsNeverOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.startDifferentThread("w1:p1")
        await #expect(throws: (any Error).self) { try await fixture.coordinator.resume() }
        #expect(await fixture.runner.starts().isEmpty)
        #expect(await fixture.coordinator.hasPendingRecovery())
    }

    @Test func lateCodexProcessPreventsCredentialHandoff() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        await fixture.runner.addAgentAfterQuit()
        await #expect(throws: (any Error).self) { try await fixture.coordinator.suspend() }
        #expect(await fixture.coordinator.hasPendingRecovery())
    }

    @Test func knownSelectionWithEmptyComposerIsClearedAndRechecked() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.runner.setComposer("› Ask Codex to do anything\nGPT-6-Sol low · ~/repo\n⌃c copy · enter copy & follow · esc clear")
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        #expect(await fixture.runner.mutations() == ["esc:w1:p1", "quit:w1:p1"])
        try await fixture.coordinator.resume()
    }

    @Test func absentHerdrSessionUsesOpenRolloutAndSupportsRepeatedSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.runner.hideSessionMetadata()
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
    }

    @Test func lostResumeResponseWithNoHookUsesRuntimeFileWithoutDuplicateStart() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.hideSessionMetadata()
        await fixture.runner.loseNextResumeResponse()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
    }

    @Test(arguments: ["pane", "process", "lsof", "environment"])
    func temporaryStartupObservationFailureConvergesWithoutDuplicateLaunch(_ probe: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.failStartupProbe(probe)
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
    }

    @Test func delayedOpenRolloutWithNoHookConverges() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.hideSessionMetadata()
        await fixture.runner.delayRuntimeFile(probes: 2)
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
    }

    @Test func savedResumingStateWaitsForQueuedLaunchWithoutResubmitting() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.delayNextLaunch(polls: 4)
        await fixture.runner.loseNextResumeResponse()
        await #expect(throws: (any Error).self) { try await fixture.coordinator.resume() }
        #expect(await fixture.coordinator.hasPendingRecovery())
        let restarted = fixture.makeCoordinator()
        try await restarted.resume()
        #expect(await fixture.runner.starts().count == 1)
        #expect(!(await restarted.hasPendingRecovery()))
    }

    @Test func savedResumingStateWaitsForRuntimeIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.hideSessionMetadata()
        await fixture.runner.delayRuntimeFile(probes: 4)
        await #expect(throws: (any Error).self) { try await fixture.coordinator.resume() }
        #expect(await fixture.coordinator.hasPendingRecovery())
        let restarted = fixture.makeCoordinator()
        try await restarted.resume()
        #expect(await fixture.runner.starts().count == 1)
        #expect(!(await restarted.hasPendingRecovery()))
    }

    @Test(arguments: [false, true])
    func conflictingRuntimeIdentityDuringStartupRemainsBlocking(_ ambiguous: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.hideSessionMetadata()
        await fixture.runner.setRuntimeThreads(ambiguous ? [fixture.ids[0], UUID().uuidString] : [UUID().uuidString])
        await #expect(throws: (any Error).self) { try await fixture.coordinator.resume() }
        await #expect(throws: (any Error).self) { try await fixture.makeCoordinator().resume() }
        #expect(await fixture.runner.starts().count == 1)
        #expect(await fixture.coordinator.hasPendingRecovery())
    }

    @Test func mismatchedOrAmbiguousRuntimeThreadsBlockBeforeQuit() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.runner.setRuntimeThreads([UUID().uuidString])
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
        await fixture.runner.setRuntimeThreads([fixture.ids[0], UUID().uuidString])
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
        await fixture.runner.hideSessionMetadata()
        await fixture.runner.setRuntimeThreads([])
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
    }

    @Test(arguments: [false, true])
    func verifiedSubagentTreeKeepsExactRootConversation(_ hideHook: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = fixture.ids[0]
        let child = UUID().uuidString.lowercased()
        let sibling = UUID().uuidString.lowercased()
        let grandchild = UUID().uuidString.lowercased()
        try fixture.writeRollout(root, payload: ["id": root, "source": hideHook ? "cli" : "vscode"])
        try fixture.writeRollout(child, payload: Fixture.subagentPayload(child, parent: root))
        try fixture.writeRollout(sibling, payload: Fixture.subagentPayload(sibling, parent: root))
        var nested = Fixture.subagentPayload(grandchild, parent: child)
        // Optional corroborating fields may be absent; source must still prove
        // the complete immediate-parent chain among the open files.
        nested.removeValue(forKey: "parent_thread_id")
        nested.removeValue(forKey: "forked_from_id")
        try fixture.writeRollout(grandchild, payload: nested, suffix: "not JSON: transcript body must never be parsed\n")
        await fixture.runner.setRuntimeThreads([grandchild, sibling, root, child, child])
        if hideHook { await fixture.runner.hideSessionMetadata() }
        try await fixture.coordinator.prepare()
        #expect(await fixture.runner.mutations().isEmpty)
        let metadata = try String(contentsOf: fixture.journal, encoding: .utf8)
        #expect(metadata.contains(root))
        #expect(!metadata.contains(child))
        try await fixture.coordinator.suspend()
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.quits() == ["w1:p1"])
        #expect(await fixture.runner.starts().first?.contains("resume '\(root)'") == true)
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
    }

    @Test(arguments: [false, true])
    func verifiedTreeStillRejectsConflictingHookOrResumeArgument(_ hideHook: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = fixture.ids[0]
        let child = UUID().uuidString.lowercased()
        try fixture.writeRollout(root, payload: ["id": root, "source": "vscode"])
        try fixture.writeRollout(child, payload: Fixture.subagentPayload(child, parent: root))
        await fixture.runner.setRuntimeThreads([root, child])
        await fixture.runner.setThread("w1:p1", child)
        if hideHook { await fixture.runner.hideSessionMetadata() }
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test(arguments: ["multiple-roots", "no-root", "unknown-source", "unknown-subagent", "missing-source", "missing-parent",
                      "missing-chain-link", "cycle", "self-parent", "mismatched-id", "mismatched-parent",
                      "mismatched-fork", "invalid-parent", "null-parent", "root-with-parent", "wrong-record-type",
                      "malformed-json", "missing-newline", "oversized-header", "missing-file"])
    func unverifiedRolloutRelationshipsBlockBeforeAnyQuit(_ scenario: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = fixture.ids[0]
        let child = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        var rootPayload: [String: Any] = ["id": root, "source": "vscode"]
        var childPayload = Fixture.subagentPayload(child, parent: root)
        var threads = [root, child]
        var recordType = "session_meta"
        switch scenario {
        case "multiple-roots": childPayload = ["id": child, "source": "cli"]
        case "no-root": rootPayload = Fixture.subagentPayload(root, parent: child)
        case "unknown-source": rootPayload["source"] = "unknown"
        case "unknown-subagent": childPayload["source"] = ["subagent": "review"]
        case "missing-source": rootPayload.removeValue(forKey: "source")
        case "missing-parent": childPayload["source"] = ["subagent": ["thread_spawn": [:]]]
        case "missing-chain-link": childPayload = Fixture.subagentPayload(child, parent: other)
        case "cycle":
            childPayload = Fixture.subagentPayload(child, parent: other)
            try fixture.writeRollout(other, payload: Fixture.subagentPayload(other, parent: child))
            threads.append(other)
        case "self-parent": childPayload = Fixture.subagentPayload(child, parent: child)
        case "mismatched-id": childPayload["id"] = other
        case "mismatched-parent": childPayload["parent_thread_id"] = other
        case "mismatched-fork": childPayload["forked_from_id"] = other
        case "invalid-parent": childPayload["parent_thread_id"] = 123
        case "null-parent": childPayload["parent_thread_id"] = NSNull()
        case "root-with-parent": rootPayload["parent_thread_id"] = other
        case "wrong-record-type": recordType = "response_item"
        default: break
        }
        try fixture.writeRollout(root, payload: rootPayload)
        try fixture.writeRollout(child, payload: childPayload, type: recordType)
        let childURL = fixture.rolloutURL(child)
        switch scenario {
        case "malformed-json": try Data("{not json}\n".utf8).write(to: childURL)
        case "missing-newline":
            let data = try Data(contentsOf: childURL)
            try Data(data.dropLast()).write(to: childURL)
        case "oversized-header":
            let data = try Data(contentsOf: childURL)
            try (Data(repeating: 0x20, count: 1_048_576) + data).write(to: childURL)
        case "missing-file": try FileManager.default.removeItem(at: childURL)
        default: break
        }
        await fixture.runner.setRuntimeThreads(threads)
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func changedSubagentMetadataAfterPreparePreventsQuit() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = fixture.ids[0]
        let child = UUID().uuidString.lowercased()
        try fixture.writeRollout(root, payload: ["id": root, "source": "vscode"])
        try fixture.writeRollout(child, payload: Fixture.subagentPayload(child, parent: root))
        await fixture.runner.setRuntimeThreads([root, child])
        try await fixture.coordinator.prepare()
        try fixture.writeRollout(child, payload: ["id": child, "source": "cli"])
        await #expect(throws: (any Error).self) { try await fixture.coordinator.suspend() }
        #expect(await fixture.runner.mutations().isEmpty)
        try await fixture.coordinator.resume()
        #expect(!(await fixture.coordinator.hasPendingRecovery()))
    }

    @Test func distinctFilesClaimingOneUUIDBlockTreeDisambiguation() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = fixture.ids[0]
        let child = UUID().uuidString.lowercased()
        try fixture.writeRollout(root, payload: ["id": root, "source": "vscode"])
        try fixture.writeRollout(child, payload: Fixture.subagentPayload(child, parent: root))
        let duplicate = fixture.rolloutURL(child).deletingLastPathComponent()
            .appendingPathComponent("rollout-duplicate-\(child).jsonl")
        try FileManager.default.copyItem(at: fixture.rolloutURL(child), to: duplicate)
        await fixture.runner.setRuntimeThreads([root, child])
        await fixture.runner.setExtraRuntimePaths([duplicate.path])
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func excessiveRolloutCountBlocksBeforeReadingUnboundedMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let root = fixture.ids[0]
        try fixture.writeRollout(root, payload: ["id": root, "source": "vscode"])
        var threads = [root]
        for _ in 0..<64 {
            let child = UUID().uuidString.lowercased()
            try fixture.writeRollout(child, payload: Fixture.subagentPayload(child, parent: root))
            threads.append(child)
        }
        await fixture.runner.setRuntimeThreads(threads)
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func runtimePathsAreScopedAndDuplicatesDoNotCreateAmbiguity() {
        let id = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        let home = URL(fileURLWithPath: "/test/codex")
        let output = """
        p123
        n/test/codex/sessions/2026/10/29/rollout-2026-10-29T12-00-00-\(id).jsonl
        n/test/codex/sessions/2026/10/29/rollout-2026-10-29T12-00-00-\(id).jsonl
        n/test/codex-other/sessions/rollout-2026-10-29T12-00-00-\(other).jsonl
        n/test/codex/logs/rollout-2026-10-29T12-00-00-\(other).jsonl
        n/test/codex/sessions/not-a-rollout-\(other).jsonl
        """
        #expect(HerdrCoordinator.runtimeThreadIDs(from: output, home: home) == [id])
    }

    @Test func shellDraftPreventsAutomaticResumeInput() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.coordinator.prepare()
        try await fixture.coordinator.suspend()
        await fixture.runner.setShellPrompt("fixture@host repo % unfinished command")
        await #expect(throws: (any Error).self) { try await fixture.coordinator.resume() }
        #expect(await fixture.runner.starts().isEmpty)
        #expect(await fixture.coordinator.hasPendingRecovery())
        await fixture.runner.setShellPrompt("fixture@host repo %")
        try await fixture.coordinator.resume()
        #expect(await fixture.runner.starts().count == 1)
    }

    @Test func unknownLaunchArgumentsAreNotSilentlyDropped() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.runner.setExtraArguments(["--model", "special-model"])
        await #expect(throws: (any Error).self) { try await fixture.coordinator.prepare() }
        #expect(await fixture.runner.mutations().isEmpty)
    }

    @Test func composerAndEnvironmentParsingAreConservative() {
        #expect(HerdrCoordinator.hasEmptyComposer("› Ask Codex to do anything\n\nGPT-6-Sol low · ~/repo"))
        #expect(HerdrCoordinator.hasEmptyComposer("» Ask Codex to do anything\n\nGPT-6-Sol low · ~/repo"))
        #expect(!HerdrCoordinator.hasEmptyComposer("› \n  a multiline draft\nGPT-6-Sol low · ~/repo"))
        #expect(!HerdrCoordinator.hasEmptyComposer("» \n  a multiline draft\nGPT-6-Sol low · ~/repo"))
        #expect(!HerdrCoordinator.hasEmptyComposer("› Ask Codex to do anything\n⌃c copy · enter copy & follow · esc clear"))
        #expect(!HerdrCoordinator.hasEmptyComposer("› /quit"))
        #expect(!HerdrCoordinator.hasEmptyComposer("› \nGPT-6-Sol low · draft text\nGPT-6-Sol low · ~/repo"))
        #expect(HerdrCoordinator.hasEmptyShellPrompt("(base) xyh@MacBook repo %"))
        #expect(!HerdrCoordinator.hasEmptyShellPrompt("(base) xyh@MacBook repo % echo something %"))
        #expect(!HerdrCoordinator.hasEmptyShellPrompt("custom prompt > "))
        #expect(HerdrCoordinator.codexHome(from: "codex resume x HOME=/Users/test CODEX_HOME=/a path/codex USER=test", defaultHome: "/fallback") == "/a path/codex")
        let command = HerdrCoordinator.resumeCommand(executable: "/bin/codex", home: "/home/a'b", cwd: "/work/$(touch nope)", threadID: "thread-id")
        #expect(command.contains("'/home/a'\\''b'"))
        #expect(command.contains("'/work/$(touch nope)'"))
    }
}

private struct Fixture {
    let root: URL
    let journal: URL
    let runner: FakeHerdr
    let coordinator: HerdrCoordinator
    let ids: [String]
    init(count: Int = 1) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = root.appendingPathComponent("recovery.json")
        ids = (0..<count).map { _ in UUID().uuidString.lowercased() }
        runner = FakeHerdr(home: root.path, ids: ids)
        coordinator = HerdrCoordinator(runner: runner, herdr: URL(fileURLWithPath: "/test/herdr"), activeHome: root, journalURL: journal)
    }
    func makeCoordinator() -> HerdrCoordinator {
        HerdrCoordinator(runner: runner, herdr: URL(fileURLWithPath: "/test/herdr"), activeHome: root, journalURL: journal)
    }
    func rolloutURL(_ id: String) -> URL {
        root.appendingPathComponent("sessions/2026/10/29/rollout-2026-10-29T12-00-00-\(id).jsonl")
    }
    func writeRollout(_ id: String, payload: [String: Any], type: String = "session_meta", suffix: String = "") throws {
        let url = rolloutURL(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
        data.append(contentsOf: ("\n" + suffix).utf8)
        try data.write(to: url)
    }
    static func subagentPayload(_ id: String, parent: String) -> [String: Any] {
        ["id": id, "source": ["subagent": ["thread_spawn": ["parent_thread_id": parent, "depth": 1]]],
         "parent_thread_id": parent, "forked_from_id": parent]
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private actor FakeHerdr: HerdrCommandRunning {
    struct Agent {
        var pane: String
        var terminal: String
        var thread: String
        var status = "idle"
        var pid: Int
        var shell = false
        var resumedByCoordinator = false
    }
    private var agents: [Agent]
    private let home: String
    private var operations: [String] = []
    private var launchCommands: [String] = []
    private var quitFailure: String?
    private var quitHook: (@Sendable () async throws -> Void)?
    private var loseResume = false
    private var lateAgent = false
    private var extraArguments: [String] = []
    private var shellPrompt = "fixture@host repo %"
    private var metadataHidden = false
    private var runtimeThreads: [String]?
    private var extraRuntimePaths: [String] = []
    private var failedStartupProbe: String?
    private var runtimeFileDelay = 0
    private var launchDelay = 0
    private var queuedLaunch: (index: Int, polls: Int)?
    private var composer = "› Ask Codex to do anything\nGPT-6-Sol low · ~/repo"
    init(home: String, ids: [String]) {
        self.home = home
        agents = ids.enumerated().map { Agent(pane: "w1:p\($0.offset + 1)", terminal: "terminal-\($0.offset)", thread: $0.element, pid: 100 + $0.offset) }
    }
    func setStatus(_ pane: String, _ status: String) { agents[agents.firstIndex { $0.pane == pane }!].status = status }
    func setComposer(_ value: String) { composer = value }
    func setThread(_ pane: String, _ value: String) { agents[agents.firstIndex { $0.pane == pane }!].thread = value }
    func replaceTerminal(_ pane: String) { agents[agents.firstIndex { $0.pane == pane }!].terminal = "replacement" }
    func failQuit(_ pane: String) { quitFailure = pane }
    func setQuitHook(_ hook: @escaping @Sendable () async throws -> Void) { quitHook = hook }
    func loseNextResumeResponse() { loseResume = true }
    func addAgentAfterQuit() { lateAgent = true }
    func setExtraArguments(_ values: [String]) { extraArguments = values }
    func setShellPrompt(_ value: String) { shellPrompt = value }
    func hideSessionMetadata() { metadataHidden = true }
    func setRuntimeThreads(_ values: [String]) { runtimeThreads = values }
    func setExtraRuntimePaths(_ values: [String]) { extraRuntimePaths = values }
    func failStartupProbe(_ name: String) { failedStartupProbe = name }
    func delayRuntimeFile(probes: Int) { runtimeFileDelay = probes }
    func delayNextLaunch(polls: Int) { launchDelay = polls }
    func startDifferentThread(_ pane: String) {
        let index = agents.firstIndex { $0.pane == pane }!
        agents[index].shell = false; agents[index].pid += 500; agents[index].thread = UUID().uuidString
    }
    func mutations() -> [String] { operations }
    func quits() -> [String] { operations.filter { $0.hasPrefix("quit:") }.map { String($0.dropFirst(5)) } }
    func starts() -> [String] { launchCommands }

    func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        if executable.path == "/bin/ps" {
            try failProbeIfRequested("environment")
            return "codex HOME=/test CODEX_HOME=\(home) USER=test"
        }
        if executable.path == "/usr/sbin/lsof" {
            try failProbeIfRequested("lsof")
            let pid = Int(arguments[3])!
            let agent = agents.first { $0.pid == pid }!
            if agent.resumedByCoordinator, runtimeFileDelay > 0 { runtimeFileDelay -= 1; return "p\(pid)\n" }
            let paths = (runtimeThreads ?? [agent.thread]).map {
                "n\(home)/sessions/2026/10/29/rollout-2026-10-29T12-00-00-\($0).jsonl"
            } + extraRuntimePaths.map { "n" + $0 }
            return paths.joined(separator: "\n")
        }
        #expect(Array(arguments.prefix(2)) == ["--session", "yehong"])
        let args = Array(arguments.dropFirst(2))
        if args == ["api", "snapshot"] {
            return try json(["result": ["snapshot": ["panes": agents.map(paneJSON)]]])
        }
        if args[0...1] == ["pane", "get"] {
            if let queued = queuedLaunch {
                if queued.polls == 0 { finishLaunch(queued.index); queuedLaunch = nil }
                else { queuedLaunch = (queued.index, queued.polls - 1) }
            }
            try failProbeIfRequested("pane")
            let a = agents.first { $0.pane == args[2] }!
            return try json(["result": ["pane": paneJSON(a)]])
        }
        if args[0...1] == ["pane", "process-info"] {
            try failProbeIfRequested("process")
            let a = agents.first { $0.pane == args[3] }!
            let argv = a.resumedByCoordinator
                ? ["/test/codex", "--no-daemon", "-C", home, "resume", a.thread] + extraArguments
                : ["/test/codex", "--no-daemon", "resume", a.thread] + extraArguments
            let process: [String: Any] = a.shell
                ? ["pid": 10, "name": "zsh", "argv": ["-zsh"], "cwd": home]
                : ["pid": a.pid, "name": "codex", "argv": argv, "cwd": home]
            return try json(["result": ["process_info": ["shell_pid": 10, "foreground_process_group_id": a.shell ? 10 : a.pid, "foreground_processes": [process]]]])
        }
        if args[0...1] == ["pane", "read"] { return shellPrompt }
        if args[0...1] == ["agent", "read"] {
            // Also exercise the API result envelope accepted by the coordinator.
            return try json(["result": ["text": composer]])
        }
        if args[0...1] == ["agent", "send-keys"] {
            #expect(args[3] == "esc")
            operations.append("esc:\(args[2])")
            composer = "› Ask Codex to do anything\nGPT-6-Sol low · ~/repo"
            return "{}"
        }
        if args[0...1] == ["agent", "prompt"] {
            #expect(args[3] == "/quit")
            if quitFailure == args[2] { throw HerdrCoordinatorError.failure("injected quit failure") }
            let i = agents.firstIndex { $0.pane == args[2] }!
            operations.append("quit:\(args[2])")
            agents[i].shell = true
            if let hook = quitHook {
                quitHook = nil
                try await hook()
            }
            if lateAgent {
                lateAgent = false
                agents.append(Agent(pane: "w2:p1", terminal: "late", thread: UUID().uuidString, pid: 999))
            }
            return "{}"
        }
        if args[0...1] == ["pane", "run"] {
            let i = agents.firstIndex { $0.pane == args[2] }!
            operations.append("resume:\(args[2])"); launchCommands.append(args[3])
            if launchDelay > 0 { queuedLaunch = (i, launchDelay); launchDelay = 0 }
            else { finishLaunch(i) }
            if loseResume { loseResume = false; throw HerdrCoordinatorError.failure("injected lost response") }
            return "{}"
        }
        Issue.record("Unexpected command \(args)")
        throw HerdrCoordinatorError.failure("unexpected command")
    }
    private func finishLaunch(_ index: Int) {
        agents[index].shell = false; agents[index].pid += 500; agents[index].resumedByCoordinator = true
    }
    private func failProbeIfRequested(_ name: String) throws {
        if failedStartupProbe == name, agents.contains(where: { $0.resumedByCoordinator }) {
            failedStartupProbe = nil
            throw HerdrCoordinatorError.failure("injected temporary observation failure")
        }
    }
    private func paneJSON(_ a: Agent) -> [String: Any] {
        var result: [String: Any] = ["pane_id": a.pane, "terminal_id": a.terminal, "cwd": home, "foreground_cwd": home]
        if !a.shell {
            result["agent"] = "codex"; result["agent_status"] = a.status
            if !metadataHidden { result["agent_session"] = ["agent": "codex", "kind": "id", "value": a.thread] }
        }
        return result
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
