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
        await #expect(throws: (any Error).self) { try await fixture.coordinator.resume() }
        // Simulate application restart: recover using only the saved journal.
        let restarted = fixture.makeCoordinator()
        try await restarted.resume()
        #expect(await fixture.runner.starts().count == 1)
        #expect(!(await restarted.hasPendingRecovery()))
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
        #expect(!HerdrCoordinator.hasEmptyComposer("› \n  a multiline draft\nGPT-6-Sol low · ~/repo"))
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
    private var loseResume = false
    private var lateAgent = false
    private var extraArguments: [String] = []
    private var shellPrompt = "fixture@host repo %"
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
    func loseNextResumeResponse() { loseResume = true }
    func addAgentAfterQuit() { lateAgent = true }
    func setExtraArguments(_ values: [String]) { extraArguments = values }
    func setShellPrompt(_ value: String) { shellPrompt = value }
    func startDifferentThread(_ pane: String) {
        let index = agents.firstIndex { $0.pane == pane }!
        agents[index].shell = false; agents[index].pid += 500; agents[index].thread = UUID().uuidString
    }
    func mutations() -> [String] { operations }
    func quits() -> [String] { operations.filter { $0.hasPrefix("quit:") }.map { String($0.dropFirst(5)) } }
    func starts() -> [String] { launchCommands }

    func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        if executable.path == "/bin/ps" { return "codex HOME=/test CODEX_HOME=\(home) USER=test" }
        #expect(Array(arguments.prefix(2)) == ["--session", "yehong"])
        let args = Array(arguments.dropFirst(2))
        if args == ["api", "snapshot"] {
            return try json(["result": ["snapshot": ["panes": agents.map(paneJSON)]]])
        }
        if args[0...1] == ["pane", "get"] {
            let a = agents.first { $0.pane == args[2] }!
            return try json(["result": ["pane": paneJSON(a)]])
        }
        if args[0...1] == ["pane", "process-info"] {
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
            if lateAgent {
                lateAgent = false
                agents.append(Agent(pane: "w2:p1", terminal: "late", thread: UUID().uuidString, pid: 999))
            }
            return "{}"
        }
        if args[0...1] == ["pane", "run"] {
            let i = agents.firstIndex { $0.pane == args[2] }!
            operations.append("resume:\(args[2])"); launchCommands.append(args[3])
            agents[i].shell = false; agents[i].pid += 500; agents[i].resumedByCoordinator = true
            if loseResume { loseResume = false; throw HerdrCoordinatorError.failure("injected lost response") }
            return "{}"
        }
        Issue.record("Unexpected command \(args)")
        throw HerdrCoordinatorError.failure("unexpected command")
    }
    private func paneJSON(_ a: Agent) -> [String: Any] {
        var result: [String: Any] = ["pane_id": a.pane, "terminal_id": a.terminal, "cwd": home, "foreground_cwd": home]
        if !a.shell {
            result["agent"] = "codex"; result["agent_status"] = a.status
            result["agent_session"] = ["agent": "codex", "kind": "id", "value": a.thread]
        }
        return result
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
