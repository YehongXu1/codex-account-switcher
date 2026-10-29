import Foundation

private enum UsageRefreshResult: Sendable {
    case success(UUID, WeeklyUsage)
    case failure(UUID, String)
}

@MainActor
open class AccountController {
    public var onChange: (@MainActor () -> Void)?
    public private(set) var accounts: [AccountProfile] = [] { didSet { onChange?() } }
    public private(set) var activeAccountID: UUID? { didSet { onChange?() } }
    public private(set) var usageStates: [UUID: UsageViewState] = [:] { didSet { onChange?() } }
    public private(set) var subscriptionSnapshots: [UUID: SubscriptionSnapshot] = [:] { didSet { onChange?() } }
    public private(set) var settings: AppSettings = .default { didSet { onChange?() } }
    public private(set) var isMutating = false { didSet { onChange?() } }
    public private(set) var isAddingAccount = false { didSet { onChange?() } }
    public var visibleError: OperationError? { didSet { onChange?() } }
    public private(set) var activeIdentityConfirmed = true { didSet { onChange?() } }
    public private(set) var hasHerdrRecovery = false { didSet { onChange?() } }

    private let store: AccountStore
    private let codex: any AccountClient
    private let switchService: any SwitchServicing
    private var hasStarted = false
    private var usageRefreshTask: Task<Void, Never>?
    private var nextUsageRefreshTask: Task<Void, Never>?
    private var addAccountTask: Task<Void, Never>?
    private var backgroundUsageRefreshInterval: Duration = .seconds(300)
    private var isBackgroundUsageRefreshEnabled = false
    private var resetExpiryExperiment: ResetExpiryExperiment?
    private var resetExpiryTask: Task<Void, Never>?

    public var resetExpiryLogURL: URL { store.resetExpiryLogURL }

    public init(
        store: AccountStore,
        codex: any AccountClient,
        switchService: any SwitchServicing
    ) {
        self.store = store
        self.codex = codex
        self.switchService = switchService
    }

    public func text(_ key: String) -> String {
        L10n.string(key, language: settings.language)
    }

    public func format(_ key: String, _ argument: String) -> String {
        String(format: text(key), argument)
    }

    public var activeRemainingPercent: Int? {
        guard let activeAccountID else { return nil }
        guard let usage = usageStates[activeAccountID]?.displayedUsage else { return nil }
        return settings.statusBarUsageWindow == .fiveHour
            ? (usage.fiveHourRemainingPercent ?? usage.remainingPercent)
            : usage.remainingPercent
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        isMutating = true
        defer { isMutating = false }
        hasHerdrRecovery = await switchService.hasPendingSessionRecovery()
        do {
            settings = try await store.loadSettings()
            apply(try await store.loadRegistry())
            try await syncActiveIdentity()
            await refreshSubscriptionSnapshots()
            do {
                apply(try await store.loadUsageCache())
            } catch {
                showError(error)
            }
            if settings.resetExpiryExperimentEnabled {
                try await beginResetExpiryExperiment(event: "resumed")
            }
        } catch {
            showError(error)
        }
    }

    public func refreshWeeklyUsage() {
        if isBackgroundUsageRefreshEnabled {
            scheduleNextWeeklyUsageRefresh()
        }
        guard !isMutating, usageRefreshTask == nil else { return }
        usageRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performWeeklyUsageRefresh()
            self.usageRefreshTask = nil
            self.scheduleResetExpiryCheck()
        }
    }

    public func waitForWeeklyUsageRefresh() async {
        await usageRefreshTask?.value
    }

    private func refreshSubscriptionSnapshots() async {
        var snapshots: [UUID: SubscriptionSnapshot] = [:]
        for account in accounts {
            if let snapshot = await store.readSubscriptionSnapshot(
                profile: account, isActive: account.id == activeAccountID
            ) {
                snapshots[account.id] = snapshot
            }
        }
        subscriptionSnapshots = snapshots
    }

    public func startBackgroundUsageRefresh(every interval: Duration = .seconds(300)) async {
        backgroundUsageRefreshInterval = interval
        isBackgroundUsageRefreshEnabled = true
        await start()
        refreshWeeklyUsage()
    }

    public func stopBackgroundUsageRefresh() {
        isBackgroundUsageRefreshEnabled = false
        nextUsageRefreshTask?.cancel()
        nextUsageRefreshTask = nil
        resetExpiryTask?.cancel()
        resetExpiryTask = nil
    }

    private func scheduleNextWeeklyUsageRefresh() {
        nextUsageRefreshTask?.cancel()
        let interval = backgroundUsageRefreshInterval
        nextUsageRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.nextUsageRefreshTask = nil
            self.refreshWeeklyUsage()
        }
    }

    private func performWeeklyUsageRefresh() async {
        guard !Task.isCancelled else { return }
        do {
            try await syncActiveIdentity()
        } catch {
            showError(error)
            for account in accounts {
                await observeResetExpiry(profile: account, usage: nil, error: error.localizedDescription)
            }
            return
        }
        guard !Task.isCancelled else { return }
        await refreshSubscriptionSnapshots()
        await withTaskGroup(of: UsageRefreshResult.self) { group in
            for account in accounts {
                group.addTask { [store, codex] in
                    do {
                        let home = await store.profileHome(id: account.id)
                        try Task.checkCancellation()
                        return .success(account.id, try await codex.readWeeklyUsage(profileHome: home))
                    } catch {
                        return .failure(account.id, error.localizedDescription)
                    }
                }
            }
            for await result in group {
                guard !Task.isCancelled else { continue }
                switch result {
                case let .success(id, usage):
                    guard let account = accounts.first(where: { $0.id == id }) else { continue }
                    usageStates[id] = .loaded(usage)
                    await observeResetExpiry(profile: account, usage: usage)
                    do {
                        try await store.cacheWeeklyUsage(usage, profileID: id)
                    } catch {
                        showError(error)
                    }
                case let .failure(id, message):
                    guard let account = accounts.first(where: { $0.id == id }) else { continue }
                    await observeResetExpiry(profile: account, usage: nil, error: message)
                    if let cached = usageStates[id]?.displayedUsage {
                        usageStates[id] = .stale(cached, message)
                    } else {
                        usageStates[id] = .unavailable(message)
                    }
                }
            }
        }
    }

    public func switchAccount(to id: UUID) async {
        guard !isMutating else { return }
        isMutating = true
        await cancelUsageRefresh()
        defer { isMutating = false; refreshWeeklyUsage() }
        do {
            try await syncActiveIdentity()
            guard id != activeAccountID else { return }
            try await switchService.switchAccount(to: id)
            apply(try await store.loadRegistry())
            await refreshSubscriptionSnapshots()
            activeIdentityConfirmed = true
        } catch let error as OperationError {
            if error.stage == .reopenDesktop || error.stage == .resumeHerdr {
                do {
                    apply(try await store.loadRegistry())
                    activeIdentityConfirmed = true
                } catch {
                    showError(error)
                    hasHerdrRecovery = await switchService.hasPendingSessionRecovery()
                    return
                }
                visibleError = OperationError(
                    stage: error.stage,
                    titleKey: "switched_reopen_title",
                    messageKey: error.stage == .reopenDesktop ? "switched_reopen_message" : nil,
                    message: error.stage == .reopenDesktop ? text("switched_reopen_message") : error.message,
                    underlyingDescription: error.underlyingDescription
                )
            } else {
                if let stage = error.stage,
                   [SwitchStage.saveCurrentCredential, .activateTargetCredential, .verifyTargetIdentity, .commitActiveAccountID].contains(stage) {
                    activeIdentityConfirmed = false
                }
                visibleError = error
            }
        } catch {
            showError(error)
        }
        hasHerdrRecovery = await switchService.hasPendingSessionRecovery()
    }

    public func recoverHerdrSessions() async {
        guard !isMutating else { return }
        isMutating = true
        await cancelUsageRefresh()
        defer { isMutating = false; refreshWeeklyUsage() }
        do {
            try await switchService.recoverSessions()
            visibleError = nil
        } catch {
            activeIdentityConfirmed = false
            showError(error)
        }
        hasHerdrRecovery = await switchService.hasPendingSessionRecovery()
    }

    public func addAccount() {
        guard !isMutating, !isAddingAccount else { return }
        visibleError = nil
        isAddingAccount = true
        addAccountTask = Task { [weak self] in
            guard let self else { return }
            await self.performAddAccount()
            self.isAddingAccount = false
            self.addAccountTask = nil
        }
    }

    public func cancelAddingAccount() {
        addAccountTask?.cancel()
    }

    private func performAddAccount() async {
        let id = UUID()
        do {
            let home = try await store.createProfileDirectory(id: id)
            try Task.checkCancellation()
            let identity = try await codex.login(profileHome: home)
            try Task.checkCancellation()
            let profile = AccountProfile(
                id: id,
                displayName: identity.suggestedDisplayName,
                email: identity.email,
                accountID: identity.accountID,
                createdAt: Date(),
                lastUsedAt: nil
            )
            try await store.addProfile(profile)
            apply(try await store.loadRegistry())
            await refreshSubscriptionSnapshots()
        } catch {
            let loginError = error
            do {
                try await store.discardUnregisteredProfile(id: id)
            } catch {
                showError(NSError(domain: "CodexAccountSwitcher.Login", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(loginError.localizedDescription) Removing the incomplete profile also failed: \(error.localizedDescription)",
                ]))
                return
            }
            if !(loginError is CancellationError) { showError(loginError) }
        }
    }

    public func registerCurrentAccount() async {
        guard !isMutating, !isAddingAccount else { return }
        isMutating = true
        await cancelUsageRefresh()
        defer { isMutating = false; refreshWeeklyUsage() }
        do {
            guard await store.activeCredentialExists() else { throw AccountStoreError.activeCredentialMissing }
            try await syncActiveIdentity()
            await refreshSubscriptionSnapshots()
            visibleError = nil
        } catch { showError(error) }
    }

    public func removeAccount(id: UUID) async {
        guard !isMutating else { return }
        isMutating = true
        await cancelUsageRefresh()
        defer { isMutating = false; refreshWeeklyUsage() }
        do {
            try await syncActiveIdentity()
            try await store.removeAccount(id: id)
            apply(try await store.loadRegistry())
            usageStates[id] = nil
        } catch {
            showError(error)
        }
    }

    public func setLanguage(_ language: AppLanguage) async {
        settings.language = language
        do {
            try await store.saveSettings(settings)
        } catch {
            showError(error)
        }
    }

    public func setShowsMenuBarPercentage(_ enabled: Bool) async {
        settings.showsMenuBarPercentage = enabled
        do {
            try await store.saveSettings(settings)
        } catch {
            showError(error)
        }
    }

    public func setShowsFiveHourUsage(_ enabled: Bool) async {
        settings.showsFiveHourUsage = enabled
        do {
            try await store.saveSettings(settings)
        } catch {
            showError(error)
        }
    }

    public func setStatusBarUsageWindow(_ window: StatusBarUsageWindow) async {
        settings.statusBarUsageWindow = window
        do {
            try await store.saveSettings(settings)
        } catch {
            showError(error)
        }
    }

    public func setResetExpiryExperimentEnabled(_ enabled: Bool) async {
        do {
            var updated = settings
            updated.resetExpiryExperimentEnabled = enabled
            try await store.saveSettings(updated)
            settings = updated
            resetExpiryTask?.cancel()
            resetExpiryTask = nil
            resetExpiryExperiment = nil
            if enabled {
                try await beginResetExpiryExperiment(event: "enabled")
                refreshWeeklyUsage()
            } else {
                try await store.appendResetExpiryLog([ResetExpiryEvent(timestamp: Date(), event: "disabled")])
            }
        } catch {
            stopResetExpiryExperiment(error)
        }
    }

    private func beginResetExpiryExperiment(event: String) async throws {
        let history = try await store.loadResetExpiryLog()
        guard settings.resetExpiryExperimentEnabled else { return }
        try await store.appendResetExpiryLog([ResetExpiryEvent(timestamp: Date(), event: event)])
        guard settings.resetExpiryExperimentEnabled else { return }
        resetExpiryExperiment = ResetExpiryExperiment(history: history)
    }

    private func observeResetExpiry(profile: AccountProfile, usage: WeeklyUsage?, error: String? = nil) async {
        guard settings.resetExpiryExperimentEnabled, var experiment = resetExpiryExperiment else { return }
        let events = experiment.observe(profile: profile, usage: usage, error: error, at: Date())
        resetExpiryExperiment = experiment
        do {
            try await store.appendResetExpiryLog(events)
        } catch {
            stopResetExpiryExperiment(error)
        }
    }

    private func scheduleResetExpiryCheck() {
        resetExpiryTask?.cancel()
        resetExpiryTask = nil
        guard isBackgroundUsageRefreshEnabled, settings.resetExpiryExperimentEnabled,
              let date = resetExpiryExperiment?.nextCheckpoint(accountIDs: Set(accounts.map(\.id))) else { return }
        let delay = max(0, date.timeIntervalSinceNow)
        resetExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.resetExpiryTask = nil
            self.refreshWeeklyUsage()
        }
    }

    private func stopResetExpiryExperiment(_ error: any Error) {
        resetExpiryTask?.cancel()
        resetExpiryTask = nil
        resetExpiryExperiment = nil
        showError(error)
    }

    public func dismissError() {
        visibleError = nil
    }

    private func cancelUsageRefresh() async {
        usageRefreshTask?.cancel()
        await usageRefreshTask?.value
    }

    private func apply(_ registry: AccountRegistry) {
        accounts = registry.accounts
        activeAccountID = registry.activeAccountID
        usageStates = usageStates.filter { id, _ in registry.accounts.contains(where: { $0.id == id }) }
        subscriptionSnapshots = subscriptionSnapshots.filter { id, _ in registry.accounts.contains(where: { $0.id == id }) }
    }

    private func apply(_ cache: UsageCache) {
        let validAccountIDs = Set(accounts.map(\.id))
        let now = Date()
        for entry in cache.entries where validAccountIDs.contains(entry.profileID) {
            let age = now.timeIntervalSince(entry.fetchedAt)
            if entry.usage.resetsAt <= now {
                usageStates[entry.profileID] = .unavailable(text("usage_cache_expired"))
            } else if age > 24 * 60 * 60 {
                usageStates[entry.profileID] = .unavailable(text("usage_cache_outdated"))
            } else if age > 15 * 60 {
                usageStates[entry.profileID] = .stale(entry.usage, text("usage_cache_stale"))
            } else {
                usageStates[entry.profileID] = .loaded(entry.usage)
            }
        }
    }

    private func syncActiveIdentity() async throws {
        do {
            apply(try await store.syncActiveCredential())
            activeIdentityConfirmed = activeAccountID != nil || accounts.isEmpty
        } catch {
            activeAccountID = nil
            activeIdentityConfirmed = false
            throw error
        }
    }

    private func showError(_ error: any Error) {
        visibleError = OperationError(
            stage: nil,
            titleKey: "operation_failed",
            messageKey: nil,
            message: error.localizedDescription,
            underlyingDescription: String(describing: error)
        )
    }
}
