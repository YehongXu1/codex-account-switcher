import Foundation
#if os(macOS)
import Darwin
#endif

/// A credential handoff must not leave terminal clients using the previous identity.
public protocol HerdrSessionCoordinating: Sendable {
    func prepare() async throws
    func suspend() async throws
    func resume() async throws
    func hasPendingRecovery() async -> Bool
}

public struct NoopHerdrCoordinator: HerdrSessionCoordinating {
    public init() {}
    public func prepare() async throws {}
    public func suspend() async throws {}
    public func resume() async throws {}
    public func hasPendingRecovery() async -> Bool { false }
}

protocol HerdrCommandRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> String
}

private struct HerdrCommandRunner: HerdrCommandRunning {
    func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        let invocation = HerdrInvocation(executable, arguments)
        return try await withTaskCancellationHandler {
            try await Task.detached { try invocation.run() }.value
        } onCancel: {
            invocation.cancel()
        }
    }
}

/// Bounds only the short-lived CLI client process, never the Herdr server or a pane.
private final class HerdrInvocation: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    init(_ executable: URL, _ arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }

    func run() throws -> String {
        let pipe = Pipe()
        process.standardOutput = pipe
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch {
            lock.unlock()
            throw HerdrCoordinatorError.failure("无法启动 Herdr 命令。请检查 Herdr 安装。")
        }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [self] in
            lock.lock()
            let shouldStop = !finished
            if shouldStop { cancelled = true }
            lock.unlock()
            if shouldStop && process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                    lock.lock()
                    let stillRunning = !finished && process.isRunning
                    lock.unlock()
                    #if os(macOS)
                    if stillRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    #endif
                }
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock()
        finished = true
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw HerdrCoordinatorError.failure("Herdr 命令超时或已取消；请检查恢复列表。") }
        guard process.terminationStatus == 0, data.count <= 2_000_000,
              let text = String(data: data, encoding: .utf8) else {
            throw HerdrCoordinatorError.failure("Herdr 命令失败；请检查 yehong 会话和窗口状态。")
        }
        return text
    }
}

public enum HerdrCoordinatorError: LocalizedError, Sendable {
    case failure(String)
    public var errorDescription: String? {
        switch self { case .failure(let message): return message }
    }
}

/// Only the explicitly configured local Herdr session participates in the switch.
/// The journal stores identifiers and launch paths, never authentication credentials.
public actor HerdrCoordinator: HerdrSessionCoordinating {
    private let runner: any HerdrCommandRunning
    private let herdr: URL
    private let activeHome: URL
    private let journalURL: URL
    private let sessionName: String
    private let sessionExists: @Sendable () -> Bool
    private let pollDelay: Duration
    private let pollAttempts: Int
    private var journal: Journal?
    private var operating = false

    public init(sessionName: String = "yehong", journalURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", home.appendingPathComponent(".local/bin/herdr").path]
        self.herdr = URL(fileURLWithPath: candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0])
        self.runner = HerdrCommandRunner()
        self.activeHome = Foundation.ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        self.journalURL = journalURL ?? home.appendingPathComponent("Library/Application Support/Codex Account Switcher/herdr-recovery.json")
        self.sessionName = sessionName
        let socket = home.appendingPathComponent(".config/herdr/sessions/\(sessionName)/herdr.sock").path
        self.sessionExists = { FileManager.default.fileExists(atPath: socket) }
        self.pollDelay = .milliseconds(250)
        self.pollAttempts = 120
    }

    init(runner: any HerdrCommandRunning, herdr: URL, activeHome: URL, journalURL: URL,
         sessionName: String = "yehong", pollDelay: Duration = .zero, pollAttempts: Int = 3,
         sessionExists: @escaping @Sendable () -> Bool = { true }) {
        self.runner = runner; self.herdr = herdr; self.activeHome = activeHome
        self.journalURL = journalURL; self.sessionName = sessionName
        self.pollDelay = pollDelay; self.pollAttempts = pollAttempts; self.sessionExists = sessionExists
    }

    public func hasPendingRecovery() async -> Bool {
        journal != nil || FileManager.default.fileExists(atPath: journalURL.path)
    }

    public func prepare() async throws {
        try beginOperation()
        defer { operating = false }
        guard !(await hasPendingRecovery()) else { throw failure("存在上次未完成的 Herdr 恢复，请先恢复原对话。") }
        guard sessionExists() else { return }
        let snapshot = try await snapshot()
        var records: [Record] = []
        for pane in snapshot.panes {
            let info = try await processInfo(pane.paneID)
            let processes = info.foregroundProcesses.filter { $0.isCodex }
            guard !info.isShellOnly, pane.agent == "codex" || !processes.isEmpty else { continue }
            let record = try await inspect(pane: pane, info: info)
            records.append(record)
        }
        guard !records.isEmpty else { return }
        let originalAccountID = try CredentialIdentity.read(from: activeHome)?.accountID
        journal = Journal(version: 1, sessionName: sessionName, originalAccountID: originalAccountID, records: records)
        do { try persist() } catch { journal = nil; throw error }
    }

    public func suspend() async throws {
        try beginOperation()
        defer { operating = false }
        try loadJournal()
        guard let prepared = journal else { return }
        // Validate the entire group before exiting the first pane.
        for record in prepared.records {
            guard record.state == .prepared else { throw failure("Herdr 切换已开始，请先恢复原对话。") }
            try await validateOriginal(record)
        }
        for index in prepared.records.indices {
            let record = prepared.records[index]
            // Revalidate immediately before sending input, including draft and selection checks.
            let current = try await validateOriginal(record)
            if current.needsSelectionClear {
                _ = try await command(["agent", "send-keys", record.paneID, "esc"])
                var selectionCleared = false
                for _ in 0..<min(pollAttempts, 8) {
                    let cleared = try await validateOriginal(record)
                    if !cleared.needsSelectionClear { selectionCleared = true; break }
                    try await Task.sleep(for: pollDelay)
                }
                guard selectionCleared else { throw failure("\(record.paneID) 未能退出文本选择模式，已停止切换。") }
            }
            journal?.records[index].state = .quitting
            try persist()
            _ = try await command(["agent", "prompt", record.paneID, "/quit"])
            var stopped = false
            for _ in 0..<pollAttempts {
                let pane = try await pane(record.paneID)
                try sameTerminal(pane, record)
                let info = try await processInfo(record.paneID)
                if info.isShellOnly {
                    journal?.records[index].state = .suspended
                    try persist()
                    stopped = true
                    break
                }
                if let codex = info.foregroundProcesses.first(where: { $0.isCodex }), codex.pid != record.pid {
                    throw failure("\(record.paneID) 的进程已改变，已停止切换。")
                }
                try await Task.sleep(for: pollDelay)
            }
            guard stopped else { throw failure("\(record.paneID) 未正常退出；账号尚未切换，请先恢复已退出的对话。") }
        }
        // A pane started during suspension must not silently keep the old identity.
        let remaining = try await snapshot()
        for pane in remaining.panes {
            let info = try await processInfo(pane.paneID)
            if !info.isShellOnly && (pane.agent == "codex" || info.foregroundProcesses.contains(where: { $0.isCodex })) {
                throw failure("Herdr 中又出现了运行中的 Codex（\(pane.paneID)）；已停止账号切换。")
            }
        }
    }

    public func resume() async throws {
        try beginOperation()
        defer { operating = false }
        try loadJournal()
        guard let recovery = journal else { return }
        var failures: [String] = []
        for index in recovery.records.indices {
            do { try await resumeRecord(index) }
            catch { failures.append(error.localizedDescription) }
        }
        if failures.isEmpty {
            if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
            journal = nil
        } else {
            throw failure(failures.joined(separator: "\n"))
        }
    }

    private func resumeRecord(_ index: Int) async throws {
        guard let record = journal?.records[index] else { return }
        // Nothing was sent to this pane, so cancellation has nothing to undo.
        if record.state == .prepared || record.state == .resumed { return }
        let current = try await pane(record.paneID)
        try sameTerminal(current, record)
        let info = try await processInfo(record.paneID)
        if let process = info.foregroundProcesses.first(where: { $0.isCodex }) {
            guard current.agentSession?.value == record.threadID else {
                throw failure("\(record.paneID) 正在运行另一条对话，未自动输入任何内容。")
            }
            if process.pid == record.pid {
                let currentID = try CredentialIdentity.read(from: activeHome)?.accountID
                guard record.state == .quitting, currentID == journal?.originalAccountID else {
                    throw failure("\(record.paneID) 的旧进程仍在运行，请正常退出后恢复。")
                }
                // A timed-out CLI request may still be queued in Herdr. Keep the journal
                // until the old process has exited; do not declare it recovered prematurely.
                throw failure("\(record.paneID) 的退出结果尚未确认；请在该窗口正常退出 Codex 后重试恢复。")
            }
            guard current.isReady else { throw failure("\(record.paneID) 已恢复原对话，但仍需在窗口中完成登录或处理提示。") }
            try await verifyFreshProcess(process, record: record)
            journal?.records[index].state = .resumed
            try persist()
            return
        }
        guard info.isShellOnly else {
            throw failure("\(record.paneID) 当前有其他程序，未自动输入恢复命令。")
        }
        guard record.state != .resuming else {
            throw failure("\(record.paneID) 已发送过恢复命令但未确认成功；请在该窗口运行 codex --no-daemon resume \(record.threadID)，然后重试恢复。")
        }
        let shellText = Self.readText(try await command(["pane", "read", record.paneID, "--source", "visible", "--lines", "20"]))
        guard Self.hasEmptyShellPrompt(shellText), info.foregroundProcesses.first?.cwd == record.cwd else {
            throw failure("\(record.paneID) 的 shell 有未发送输入或提示符/目录无法确认，请回到原目录的空提示符后重试恢复。")
        }
        journal?.records[index].state = .resuming
        try persist()
        let line = Self.resumeCommand(executable: record.executable, home: record.codexHome,
                                      cwd: record.cwd, threadID: record.threadID)
        _ = try await command(["pane", "run", record.paneID, line])
        for _ in 0..<pollAttempts {
            let pane = try await pane(record.paneID)
            try sameTerminal(pane, record)
            let process = try await processInfo(record.paneID)
            if pane.agent == "codex", pane.agentSession?.value == record.threadID,
               let running = process.foregroundProcesses.first(where: { $0.isCodex }),
               running.pid != record.pid, pane.isReady {
                try await verifyFreshProcess(running, record: record)
                journal?.records[index].state = .resumed
                try persist()
                return
            }
            if pane.agent == "codex", let actual = pane.agentSession?.value, actual != record.threadID {
                throw failure("\(record.paneID) 的对话 ID 与原记录不一致，请在窗口中检查。")
            }
            try await Task.sleep(for: pollDelay)
        }
        throw failure("\(record.paneID) 的恢复尚未确认；原对话记录仍在，请在窗口中查看提示后重试恢复。")
    }

    private func verifyFreshProcess(_ process: ForegroundProcess, record: Record) async throws {
        guard process.argv.contains("--no-daemon"), process.cwd == record.cwd,
              Self.supportsArguments(Array(process.argv.dropFirst()), cwd: record.cwd, threadID: record.threadID) else {
            throw failure("\(record.paneID) 的恢复进程未使用预期的独立运行方式或目录，请检查窗口。")
        }
        let environment = try await runner.run(URL(fileURLWithPath: "/bin/ps"), ["eww", "-p", String(process.pid), "-o", "command="])
        let home = Self.codexHome(from: environment, defaultHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        guard URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: record.codexHome).standardizedFileURL.resolvingSymlinksInPath() else {
            throw failure("\(record.paneID) 恢复后使用了不同的登录目录，请检查窗口。")
        }
    }

    static func hasEmptyShellPrompt(_ output: String) -> Bool {
        guard let line = output.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        // The user's normal zsh prompt. Unknown/custom prompts need manual recovery.
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.range(of: #"^(?:\([^()\r\n]+\) )?[A-Za-z0-9._-]+@[A-Za-z0-9._-]+ [^%$\r\n]+ [%$]$"#, options: .regularExpression) != nil
    }

    static func resumeCommand(executable: String, home: String, cwd: String, threadID: String) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "env CODEX_HOME=" + quote(home) + " " + quote(executable) + " --no-daemon -C " + quote(cwd) + " resume " + quote(threadID)
    }

    private func inspect(pane: Pane, info: ProcessInfo) async throws -> Record {
        guard pane.agent == "codex", pane.isReady else {
            throw failure("\(pane.paneID) 的 Codex 正在工作、等待审批或状态不明确，请先让它回到空闲输入界面。")
        }
        guard let session = pane.agentSession, session.agent == "codex", session.kind == "id",
              UUID(uuidString: session.value) != nil else {
            throw failure("\(pane.paneID) 没有可确认的原对话 ID，已停止切换。")
        }
        guard info.foregroundProcesses.count == 1, let process = info.foregroundProcesses.first,
              process.isCodex, process.pid > 0, process.pid != info.shellPID,
              let executable = process.argv.first, executable.hasPrefix("/"),
              !process.argv.contains(where: { $0 == "--remote" || $0.hasPrefix("--remote=") || $0 == "--remote-auth-token-env" }),
              let cwd = process.cwd ?? pane.foregroundCWD ?? pane.cwd, cwd.hasPrefix("/") else {
            throw failure("\(pane.paneID) 的 Codex 启动方式无法安全恢复，已停止切换。")
        }
        // Custom profiles/config arguments could select different auth stores. Do not silently drop them.
        guard !process.argv.contains(where: { $0 == "-p" || $0 == "--profile" || $0.hasPrefix("--profile=") || $0 == "-c" || $0 == "--config" || $0.hasPrefix("--config=") }) else {
            throw failure("\(pane.paneID) 使用了自定义 profile/config，请手动退出并恢复该窗口。")
        }
        guard Self.supportsArguments(Array(process.argv.dropFirst()), cwd: cwd, threadID: session.value) else {
            throw failure("\(pane.paneID) 使用了额外启动参数，请手动退出并恢复该窗口，以保留这些设置。")
        }
        let environment = try await runner.run(URL(fileURLWithPath: "/bin/ps"), ["eww", "-p", String(process.pid), "-o", "command="])
        let home = Self.codexHome(from: environment, defaultHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        guard URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath() == activeHome.standardizedFileURL.resolvingSymlinksInPath() else {
            throw failure("\(pane.paneID) 使用了不同的 CODEX_HOME，请先用标准登录目录重新打开该对话。")
        }
        let output = try await command(["agent", "read", pane.paneID, "--source", "detection", "--lines", "40"])
        let text = Self.readText(output)
        guard Self.hasEmptyComposer(text, allowSelection: true) else {
            throw failure("\(pane.paneID) 有未发送输入、文本选择或无法识别的界面，请清空输入并按 Esc 返回普通输入界面。")
        }
        return Record(paneID: pane.paneID, terminalID: pane.terminalID, threadID: session.value,
                      cwd: cwd, executable: executable, codexHome: home, pid: process.pid, needsSelectionClear: Self.isKnownSelection(text), state: .prepared)
    }

    @discardableResult
    private func validateOriginal(_ record: Record) async throws -> Record {
        let current = try await pane(record.paneID)
        try sameTerminal(current, record)
        let checked = try await inspect(pane: current, info: processInfo(record.paneID))
        guard checked.threadID == record.threadID, checked.pid == record.pid,
              checked.cwd == record.cwd, checked.codexHome == record.codexHome else {
            throw failure("\(record.paneID) 在检查后发生变化，已停止切换。")
        }
        return checked
    }

    static func supportsArguments(_ arguments: [String], cwd: String, threadID: String) -> Bool {
        var index = 0
        var resumeSeen = false
        var threadSeen = false
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--no-daemon": break
            case "resume":
                guard !resumeSeen else { return false }
                resumeSeen = true
            case "--last", "--all":
                guard resumeSeen else { return false }
            case "-C", "--cd":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/"),
                      URL(fileURLWithPath: arguments[index]).standardizedFileURL.resolvingSymlinksInPath()
                        == URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath() else { return false }
            default:
                if argument.hasPrefix("--cd=") {
                    let path = String(argument.dropFirst(5))
                    guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                        == URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath() else { return false }
                } else {
                    guard resumeSeen, !threadSeen, let parsed = UUID(uuidString: argument), parsed == UUID(uuidString: threadID) else { return false }
                    threadSeen = true
                }
            }
            index += 1
        }
        return true
    }

    private static func readText(_ output: String) -> String {
        struct Envelope: Decodable { let result: Result; struct Result: Decodable { let text: String } }
        return (try? JSONDecoder().decode(Envelope.self, from: Data(output.utf8)))?.result.text ?? output
    }

    private static func isKnownSelection(_ output: String) -> Bool {
        guard let last = output.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        return last.contains("copy & follow") && last.contains("esc clear")
    }

    /// Conservative guard: never clear or submit user drafts to make a switch work.
    static func hasEmptyComposer(_ output: String, allowSelection: Bool = false) -> Bool {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var nonempty = lines.indices.filter { !lines[$0].isEmpty }
        guard let last = nonempty.last else { return false }
        if lines[last].contains("copy & follow") || lines[last].contains("esc clear") {
            guard allowSelection && isKnownSelection(output) else { return false }
            nonempty.removeLast()
        }
        if let last = nonempty.last, lines[last] == "? for shortcuts"
            || lines[last].range(of: #"^\d+% context left(?: · .*)?$"#, options: .regularExpression) != nil {
            nonempty.removeLast()
        }
        // The footer is one line at the bottom, not an arbitrary draft line starting with GPT.
        guard let footer = nonempty.last,
              lines[footer].range(of: #"^(?:GPT|gpt)-[A-Za-z0-9.-]+ (?:minimal|low|medium|high|xhigh|max|ultra) · .+$"#, options: .regularExpression) != nil,
              let promptIndex = lines[..<footer].lastIndex(where: { $0.hasPrefix("›") }) else { return false }
        let prompt = lines[promptIndex].dropFirst().trimmingCharacters(in: .whitespaces)
        guard prompt.isEmpty || prompt == "Ask Codex to do anything" else { return false }
        return lines[(promptIndex + 1)..<footer].allSatisfy { $0.isEmpty }
    }

    static func codexHome(from environment: String, defaultHome: String) -> String {
        let pattern = #"(?:^| )CODEX_HOME=(.*?)(?= [A-Za-z_][A-Za-z0-9_]*=|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: environment, range: NSRange(environment.startIndex..., in: environment)).last,
              let range = Range(match.range(at: 1), in: environment) else { return defaultHome }
        return String(environment[range]).trimmingCharacters(in: .newlines)
    }

    private func sameTerminal(_ pane: Pane, _ record: Record) throws {
        guard pane.terminalID == record.terminalID else { throw failure("\(record.paneID) 已被替换，未向新窗口发送任何命令。") }
    }

    private func snapshot() async throws -> Snapshot {
        try decode(SnapshotEnvelope.self, await command(["api", "snapshot"])).result.snapshot
    }
    private func pane(_ id: String) async throws -> Pane {
        try decode(PaneEnvelope.self, await command(["pane", "get", id])).result.pane
    }
    private func processInfo(_ id: String) async throws -> ProcessInfo {
        try decode(ProcessEnvelope.self, await command(["pane", "process-info", "--pane", id])).result.processInfo
    }
    private func command(_ arguments: [String]) async throws -> String {
        try await runner.run(herdr, ["--session", sessionName] + arguments)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ string: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(string.utf8)) }
        catch { throw failure("Herdr 返回了无法识别的数据，已停止自动处理。") }
    }
    private func beginOperation() throws {
        guard !operating else { throw failure("Herdr 正在处理另一项操作，请稍后重试。") }
        operating = true
    }
    private func failure(_ message: String) -> HerdrCoordinatorError { .failure(message) }
    private func loadJournal() throws {
        guard journal == nil, FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw failure("Herdr 恢复文件不是普通文件，请检查安装目录。") }
        let loaded: Journal
        do { loaded = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)) }
        catch { throw failure("Herdr 恢复记录无法读取；请保留文件并检查原窗口。") }
        guard loaded.version == 1, loaded.sessionName == sessionName else { throw failure("Herdr 恢复记录版本或会话不匹配。") }
        for record in loaded.records {
            guard UUID(uuidString: record.threadID) != nil, record.pid > 0,
                  record.paneID.range(of: #"^[A-Za-z0-9]+:p[0-9]+$"#, options: .regularExpression) != nil,
                  !record.terminalID.isEmpty, record.cwd.hasPrefix("/"), record.executable.hasPrefix("/"),
                  URL(fileURLWithPath: record.executable).lastPathComponent == "codex",
                  URL(fileURLWithPath: record.codexHome).standardizedFileURL.resolvingSymlinksInPath()
                    == activeHome.standardizedFileURL.resolvingSymlinksInPath() else {
                throw failure("Herdr 恢复记录中的窗口、对话或启动路径无效。")
            }
        }
        journal = loaded
    }
    private func persist() throws {
        guard let journal else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: journalURL.path) {
            let attributes = try fm.attributesOfItem(atPath: journalURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw failure("Herdr 恢复文件不是普通文件。") }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = journalURL.deletingLastPathComponent().appendingPathComponent(".herdr-recovery-\(UUID()).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw failure("无法创建 Herdr 恢复记录。")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: encoder.encode(journal))
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        #if os(macOS)
        guard Darwin.rename(temporary.path, journalURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        #else
        if fm.fileExists(atPath: journalURL.path) { _ = try fm.replaceItemAt(journalURL, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: journalURL) }
        #endif
    }

    private struct Journal: Codable, Sendable {
        let version: Int
        let sessionName: String
        let originalAccountID: String?
        var records: [Record]
    }
    private struct Record: Codable, Sendable {
        let paneID: String
        let terminalID: String
        let threadID: String
        let cwd: String
        let executable: String
        let codexHome: String
        let pid: Int
        let needsSelectionClear: Bool
        var state: State
    }
    private enum State: String, Codable, Sendable { case prepared, quitting, suspended, resuming, resumed }
    private struct Session: Decodable { let agent: String; let kind: String; let value: String }
    private struct Pane: Decodable {
        let paneID: String
        let terminalID: String
        let agent: String?
        let agentStatus: String?
        let agentSession: Session?
        let cwd: String?
        let foregroundCWD: String?
        var isReady: Bool { agentStatus == "idle" || agentStatus == "done" }
        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", terminalID = "terminal_id", agent, agentStatus = "agent_status"
            case agentSession = "agent_session", cwd, foregroundCWD = "foreground_cwd"
        }
    }
    private struct ForegroundProcess: Decodable {
        let pid: Int
        let name: String
        let argv: [String]
        let cwd: String?
        var isCodex: Bool { name == "codex" || argv.first.map { URL(fileURLWithPath: $0).lastPathComponent == "codex" } == true }
    }
    private struct ProcessInfo: Decodable {
        let shellPID: Int
        let foregroundProcessGroupID: Int
        let foregroundProcesses: [ForegroundProcess]
        var isShellOnly: Bool {
            foregroundProcessGroupID == shellPID && foregroundProcesses.count == 1 && foregroundProcesses.first?.pid == shellPID
        }
        enum CodingKeys: String, CodingKey {
            case shellPID = "shell_pid", foregroundProcessGroupID = "foreground_process_group_id", foregroundProcesses = "foreground_processes"
        }
    }
    private struct Snapshot: Decodable { let panes: [Pane] }
    private struct SnapshotEnvelope: Decodable { let result: Result; struct Result: Decodable { let snapshot: Snapshot } }
    private struct PaneEnvelope: Decodable { let result: Result; struct Result: Decodable { let pane: Pane } }
    private struct ProcessEnvelope: Decodable {
        let result: Result
        struct Result: Decodable {
            let processInfo: ProcessInfo
            enum CodingKeys: String, CodingKey { case processInfo = "process_info" }
        }
    }
}
