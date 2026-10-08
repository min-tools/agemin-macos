import AppKit
import StoreKit
import SwiftUI

/// Owns verified access: StoreKit purchases, the 30-day trial clock, the Free tier's daily
/// allowance, and the Pro panel. Views observe it for the current access level.
@MainActor
final class AgeminProStore: ObservableObject {
    static let shared = AgeminProStore()
    /// Posted when the verified entitlement or the signed production trial date changes.
    static let entitlementDidChange = Notification.Name("AgeminProEntitlementDidChange")
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    /// How a purchase ended. `pending` means an approval such as Ask to Buy is still outstanding.
    enum PurchaseOutcome: Equatable { case unlocked, pending, cancelled }

    @Published private(set) var entitlement = AgeminEntitlement.free
    @Published private(set) var yearly: Product?
    @Published private(set) var lifetime: Product?
    @Published private(set) var storeError: String?
    @Published private(set) var isLoading = false
    /// When the trial began: Apple's signed acquisition date in production, a local clock elsewhere.
    @Published private(set) var appTrialStartedAt: Date?
    /// True once an App Store build has finished its signed lookup, whatever the outcome.
    @Published private(set) var hasResolvedAppTrial = false
    /// True once StoreKit's current entitlements have been read at least once.
    @Published private(set) var hasResolvedEntitlement = false
    /// True until the welcome alert is accepted and its trial lookup has finished.
    @Published private(set) var isTrialWelcomePending = true
    /// Encryptions and decryptions started today under the Free tier.
    @Published private(set) var freeOperationsUsedToday = 0

    /// Listens for StoreKit transaction updates for the rest of the app's life.
    private var updates: Task<Void, Never>?
    /// Counts refreshes so a slow, stale StoreKit read cannot overwrite a newer result.
    private var refreshGeneration = 0
    /// Schedules subscription checks up to a minute apart while the app is awake.
    private var entitlementTimer: Timer?
    /// Fires when the trial ends so views re-evaluate the access level.
    private var appTrialTimer: Timer?
    /// Re-checks access whenever the app becomes active; nil in private unlocked builds.
    private var activationObserver: NSObjectProtocol?
    /// The open Pro panel; it clears this when its window closes.
    private var panel: NSWindowController?
    /// The day the stored allowance count belongs to.
    private var freeUsageDay: Date?
    private let defaults = UserDefaults.standard

    // Preferences keys for the local trial clock, the accepted disclosure, and the daily count.
    private static let appTrialStartedAtKey = "AgeminAppTrialStartedAt"
    private static let appTrialDisclosureAcceptedKey = "AgeminAppTrialDisclosureAccepted"
    private static let freeUsageDayKey = "AgeminFreeUsageDay"
    private static let freeUsageCountKey = "AgeminFreeUsageCount"

    /// Only a git-ignored private build input can grant local Pro access; nil means normal rules.
    private var developerOverride: Bool? { AgeminEdition.localProAccess }

    /// A verified purchase, or the private build's local unlock.
    var isPro: Bool { developerOverride ?? entitlement.isPro }
    /// True only in a private build whose local input grants Pro.
    var isLocalBuild: Bool { developerOverride == true }
    /// The trial counts only in public builds and only until a purchase is verified.
    var isAppTrialActive: Bool {
        guard developerOverride == nil, !entitlement.isPro, let appTrialStartedAt else { return false }
        return AgeminFreeAccessPolicy.isTrialActive(startedAt: appTrialStartedAt)
    }
    /// Pro or an active app trial; neither is subject to the daily allowance.
    var hasFullAccess: Bool { isPro || isAppTrialActive }
    /// True once the welcome and its trial lookup are done, so Free limits can apply. Private
    /// builds and expired-trial previews have no welcome step.
    var hasPreparedFreeAccess: Bool {
        isLocalBuild || AgeminEdition.isExpiredTrialPreview
            || (!isTrialWelcomePending && (appTrialStartedAt != nil || hasResolvedAppTrial))
    }
    /// True after the trial without a verified purchase, once StoreKit state is known.
    var isLimitedToFreeOperations: Bool { hasResolvedEntitlement && hasPreparedFreeAccess && !hasFullAccess }
    /// How many Free operations are left today.
    var freeOperationsRemainingToday: Int {
        let used = AgeminFreeAccessPolicy.operationsUsedToday(
            storedDay: freeUsageDay,
            storedCount: freeOperationsUsedToday
        )
        return AgeminFreeAccessPolicy.operationsRemaining(used: used)
    }

    /// The one-line access status the Pro panel shows.
    var statusText: String {
        // Private unlocked builds show their own status text.
        if isLocalBuild {
            return AgeminEdition.localAccessStatus ?? localized("Pro")
        }
        // The app's own trial counts down in whole days.
        if isAppTrialActive, let appTrialStartedAt {
            let days = AgeminFreeAccessPolicy.trialDaysRemaining(startedAt: appTrialStartedAt)
            return days == 1 ? localized("Pro trial · 1 day remaining")
                : localizedFormat("Pro trial · %lld days remaining", Int64(days))
        }
        // Other states follow the entitlement; any date shows without a time.
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        switch AgeminEntitlementLogic.statusKind(for: entitlement) {
        case .free: return localizedFormat("Free · Available today: %lld", Int64(freeOperationsRemainingToday))
        case .active: return localized("Pro")
        case .lifetime: return localized("Lifetime")
        case .familyShared: return localized("Shared with your family")
        case .trialRenews(let date): return localizedFormat("Pro trial · first payment %@", formatter.string(from: date))
        case .trialEnds(let date): return localizedFormat("Pro trial · ends %@", formatter.string(from: date))
        case .trialUntil(let date): return localizedFormat("Pro trial · until %@", formatter.string(from: date))
        case .renews(let date): return localizedFormat("Renews %@", formatter.string(from: date))
        case .ends(let date): return localizedFormat("Expires %@", formatter.string(from: date))
        case .activeUntil(let date): return localizedFormat("Until %@", formatter.string(from: date))
        }
    }

    // start(): Begin StoreKit observation and the first entitlement read once per launch; private
    // unlocked builds skip StoreKit entirely.
    func start() {
        guard developerOverride == nil else {
            hasResolvedEntitlement = true
            return
        }
        // Source and private previews restore their local trial immediately; App Store builds
        // only restore today's allowance until the signed lookup answers.
        if AgeminEdition.isAppStoreBuild {
            refreshFreeUsage(now: Date())
        } else {
            // Local previews can restore their trial without waiting for
            // StoreKit.
            prepareLocalFreeAccess()
        }
        guard updates == nil else { return }
        // Finish each verified transaction so the App Store stops redelivering it, then re-read.
        updates = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                // Finish only verified transactions; unverified ones are left unfinished.
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refreshEntitlement()
            }
        }
        // Recheck after wake or an Apple Account change while the app was inactive.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Timers do not fire during sleep, so roll the daily count over to the new day and
                // reschedule a local trial's expiry; the refresh below redoes the signed lookup.
                if AgeminEdition.isAppStoreBuild {
                    self.refreshFreeUsage(now: Date())
                } else {
                    // Local previews restore their local trial after wake as
                    // well.
                    self.prepareLocalFreeAccess()
                }
                self.objectWillChange.send()
                await self.refreshEntitlement()
            }
        }
        Task { [weak self] in await self?.refreshEntitlement() }
    }

    // deinit(): Stop the update stream, timers, and activation observer.
    deinit {
        updates?.cancel()
        entitlementTimer?.invalidate()
        appTrialTimer?.invalidate()
        // The observer exists only after start() ran in a public build.
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    // loadProducts(): Fetch the yearly and lifetime products; throws when neither is on sale.
    func loadProducts() async throws {
        guard developerOverride == nil else { return }
        isLoading = true
        storeError = nil
        defer { isLoading = false }
        let products = try await Product.products(for: AgeminProductID.all)
        let yearly = products.first { $0.id == AgeminProductID.yearly }
        let lifetime = products.first { $0.id == AgeminProductID.lifetime }
        guard yearly != nil || lifetime != nil else {
            throw StoreFailure(localized("Pro purchases are unavailable right now. Try again later."))
        }
        self.yearly = yearly
        self.lifetime = lifetime
    }

    // beginOperation([now = Date()]): Count an encryption or decryption when it starts. Return
    // false when today's resolved Free allowance is spent. Operations started while access is
    // resolving, or with full access, do not count.
    func beginOperation(now: Date = Date()) -> Bool {
        guard developerOverride == nil else { return true }
        // Bring the trial and today's count up to date before deciding.
        if AgeminEdition.isAppStoreBuild {
            refreshFreeUsage(now: now)
        } else {
            // Local previews resolve their trial directly before counting the
            // operation.
            prepareLocalFreeAccess(now: now)
        }
        // Use the same readiness gate as the limited-access UI. An operation started while
        // StoreKit checks for a purchase must not spend a slot or open the Pro panel.
        guard isLimitedToFreeOperations else { return true }
        refreshFreeUsage(now: now)
        guard let nextCount = AgeminFreeAccessPolicy.countAfterStartingOperation(
            used: freeOperationsUsedToday
        ) else { return false }
        freeOperationsUsedToday = nextCount
        defaults.set(freeOperationsUsedToday, forKey: Self.freeUsageCountKey)
        return true
    }

    // purchase(product, confirmIn window): Buy through StoreKit and report the result.
    // A nil window or older macOS uses the store's standalone confirmation.
    func purchase(_ product: Product, confirmIn window: NSWindow?) async throws -> PurchaseOutcome {
        // Local builds have nothing to buy.
        if developerOverride == true { return .unlocked }
        let result: Product.PurchaseResult
        // macOS 15.2 can show the confirmation as a sheet on the panel.
        if #available(macOS 15.2, *), let window {
            result = try await product.purchase(confirmIn: window, options: [])
        } else {
            // Older systems, or a missing window, get the App Store's own confirmation window.
            result = try await product.purchase(options: [])
        }
        switch result {
        case .success(let verification):
            // Only a verified transaction unlocks; finishing it confirms delivery to the App Store.
            guard case .verified(let transaction) = verification else {
                throw StoreFailure(localized("The App Store could not verify this purchase."))
            }
            await transaction.finish()
            await refreshEntitlement()
            return .unlocked
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    // restore(): Sync purchases with the App Store and report whether Pro access is now verified.
    func restore() async throws -> Bool {
        // Local builds are always unlocked.
        if developerOverride == true { return true }
        try await AppStore.sync()
        await refreshEntitlement()
        return isPro
    }

    // refreshProducts(): Load the products for the panel, keeping the failure text instead of
    // throwing.
    func refreshProducts() async {
        do {
            try await loadProducts()
        } catch {
            storeError = error.localizedDescription
        }
    }

    // present([feature = nil]): Show the Pro panel, naming the feature that prompted it, or bring
    // the open panel forward.
    func present(feature: AgeminProFeature? = nil) {
        // Reuse the open panel rather than stacking a second one.
        if let panel {
            panel.showWindow(nil)
            panel.window?.makeKeyAndOrderFront(nil)
            return
        }
        // The panel releases itself when its window closes.
        let controller = AgeminProPanelController(store: self, feature: feature)
        panel = controller
        controller.onClose = { [weak self] in self?.panel = nil }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // refreshEntitlement(): Re-read the trial state and StoreKit's current entitlements, publish
    // the result, and schedule the next check.
    private func refreshEntitlement() async {
        guard developerOverride == nil else { return }
        await refreshAppTrial()
        refreshGeneration += 1
        let generation = refreshGeneration
        // Summarize every verified current entitlement; StoreKit has already dropped expired ones.
        var summaries: [AgeminTransactionSummary] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            summaries.append(summary(of: transaction))
        }
        // A newer StoreKit refresh supersedes this result.
        guard generation == refreshGeneration else { return }
        // StoreKit's entitlement state is now known; post-trial UI waits for this flag.
        hasResolvedEntitlement = true
        var next = AgeminEntitlementLogic.evaluate(summaries)
        // Preserve known renewal state while refreshing the same entitlement.
        if next.kind == entitlement.kind,
           next.expirationDate == entitlement.expirationDate,
           next.isFamilyShared == entitlement.isFamilyShared {
            next.willAutoRenew = entitlement.willAutoRenew
        }
        applyEntitlement(next)
        scheduleEntitlementRefresh()
        // Publish verified access before an optional network-backed renewal lookup finishes.
        if next.kind == .subscription {
            next.willAutoRenew = await subscriptionWillAutoRenew(for: next)
            guard generation == refreshGeneration else { return }
            applyEntitlement(next)
        }
    }

    // beginAppTrial([now = Date()]): Record that the user accepted the trial disclosure and resolve
    // the trial start date.
    func beginAppTrial(now: Date = Date()) {
        defaults.set(true, forKey: Self.appTrialDisclosureAcceptedKey)
        // App Store builds must verify the transaction environment before choosing a clock.
        if AgeminEdition.isAppStoreBuild {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshAppTrial(now: now)
                self.isTrialWelcomePending = false
            }
        } else {
            // Source builds start or restore the local clock right away.
            prepareLocalFreeAccess(startTrialIfNeeded: true, now: now)
            isTrialWelcomePending = false
        }
    }

    // refreshAppTrial([now = Date()]): In App Store builds, resolve the trial from the signed app
    // transaction: Apple's acquisition date in production, the disclosed local clock in a verified
    // sandbox. Other builds return at once and leave hasResolvedAppTrial false.
    private func refreshAppTrial(now: Date = Date()) async {
        guard AgeminEdition.isAppStoreBuild else { return }
        defer {
            // Finish startup even on failure. A failed first lookup grants no trial;
            // a later failure keeps the previously verified in-memory start date.
            hasResolvedAppTrial = true
        }
        guard let result = try? await AppTransaction.shared,
              case .verified(let transaction) = result,
              transaction.bundleID == AgeminEdition.bundleIdentifier else {
            // A production build must never replace a failed signed lookup with local state.
            return
        }
        // Production counts from Apple's signed acquisition date, which the user cannot reset.
        if transaction.environment == .production {
            let authoritative = AgeminFreeAccessPolicy.authoritativeTrialStartDate(
                appStoreOriginalPurchaseDate: transaction.originalPurchaseDate,
                localStartedAt: nil,
                usesAppStoreDate: true
            )
            // The policy answers nil only without a signed date, which production always has.
            if let authoritative {
                applyAppTrialStartDate(authoritative, now: now)
            }
        } else {
            // Sandbox and Xcode environments use the local clock, started once the disclosure
            // was accepted.
            let accepted = defaults.bool(forKey: Self.appTrialDisclosureAcceptedKey)
            prepareLocalFreeAccess(
                startTrialIfNeeded: accepted,
                now: now,
                allowAppStoreSandbox: true
            )
        }
    }

    // prepareLocalFreeAccess([startTrialIfNeeded = false], [now = Date()],
    // [allowAppStoreSandbox = false]): Restore the local trial clock from preferences, start it
    // when asked and not yet started, refresh today's allowance, and schedule the expiry.
    private func prepareLocalFreeAccess(
        startTrialIfNeeded: Bool = false,
        now: Date = Date(),
        allowAppStoreSandbox: Bool = false
    ) {
        // Only a verified sandbox transaction may use local state in an App Store build.
        guard !AgeminEdition.isAppStoreBuild || allowAppStoreSandbox else { return }
        // Private previews force a start date and must not change the real one in preferences.
        if let forced = AgeminEdition.forcedTrialStartedAt {
            appTrialStartedAt = forced
        } else if appTrialStartedAt == nil {
            // A running clock is left alone; otherwise preferences decide.
            // A stored date means the trial already began on this Mac.
            if let stored = defaults.object(forKey: Self.appTrialStartedAtKey) as? Date {
                appTrialStartedAt = stored
            } else if startTrialIfNeeded {
                // Start the clock now and keep it; a plain restore never starts a trial.
                appTrialStartedAt = now
                defaults.set(now, forKey: Self.appTrialStartedAtKey)
            }
        }
        refreshFreeUsage(now: now)
        scheduleAppTrialExpiry(now: now)
    }

    // applyAppTrialStartDate(startedAt, [now = Date()]): Publish the signed production trial date
    // without storing a resettable copy, then schedule the expiry.
    private func applyAppTrialStartDate(_ startedAt: Date, now: Date = Date()) {
        // Notify only on a real change so observers do not refresh needlessly.
        if appTrialStartedAt != startedAt {
            appTrialStartedAt = startedAt
            NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
        }
        refreshFreeUsage(now: now)
        scheduleAppTrialExpiry(now: now)
    }

    // scheduleAppTrialExpiry([now = Date()]): Publish the Free tier as soon as the trial expires.
    private func scheduleAppTrialExpiry(now: Date = Date()) {
        appTrialTimer?.invalidate()
        appTrialTimer = nil
        guard let appTrialStartedAt,
              AgeminFreeAccessPolicy.isTrialActive(startedAt: appTrialStartedAt, now: now) else {
            return
        }
        // The timer only nudges observers; the access properties re-evaluate against the clock.
        let expiry = appTrialStartedAt.addingTimeInterval(AgeminFreeAccessPolicy.trialDuration)
        appTrialTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, expiry.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    // refreshFreeUsage(now): Load today's count from preferences, dropping a count that belongs
    // to another day, and write the normalized value back.
    private func refreshFreeUsage(now: Date) {
        let storedDay = defaults.object(forKey: Self.freeUsageDayKey) as? Date
        let storedCount = defaults.integer(forKey: Self.freeUsageCountKey)
        let isSameDay = storedDay.map {
            Calendar.autoupdatingCurrent.isDate($0, inSameDayAs: now)
        } ?? false
        let used = AgeminFreeAccessPolicy.operationsUsedToday(
            storedDay: storedDay,
            storedCount: storedCount,
            now: now
        )
        freeUsageDay = now
        freeOperationsUsedToday = used
        // Only write when the day rolled over or the stored count was out of range.
        if used != storedCount || !isSameDay {
            defaults.set(now, forKey: Self.freeUsageDayKey)
            defaults.set(used, forKey: Self.freeUsageCountKey)
        }
    }

    // applyEntitlement(updated): Publish a changed entitlement and post the change notification;
    // identical state is ignored.
    private func applyEntitlement(_ updated: AgeminEntitlement) {
        guard updated != entitlement else { return }
        entitlement = updated
        NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
    }

    // summary(of transaction): Keep the fields used by the entitlement decision.
    private func summary(of transaction: StoreKit.Transaction) -> AgeminTransactionSummary {
        let introductory: Bool
        // macOS 14.2 replaced the deprecated offerType with the offer object.
        if #available(macOS 14.2, *) {
            introductory = transaction.offer?.type == .introductory
        } else {
            // Older systems still expose the offer type directly.
            introductory = transaction.offerType == .introductory
        }
        return AgeminTransactionSummary(
            productID: transaction.productID,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isFamilyShared: transaction.ownershipType == .familyShared,
            isIntroductoryOffer: introductory
        )
    }

    // subscriptionWillAutoRenew(for current): Look up this subscription's renewal,
    // or nil when StoreKit cannot answer.
    private func subscriptionWillAutoRenew(for current: AgeminEntitlement) async -> Bool? {
        guard current.kind == .subscription else { return nil }
        // Renewal status comes from the product, so load it if the panel has not yet.
        if yearly == nil { try? await loadProducts() }
        guard let statuses = try? await yearly?.subscription?.status else { return nil }
        // Use only the status for the shown entitlement, so an older transaction cannot answer.
        for status in statuses {
            guard case .verified(let transaction) = status.transaction,
                  transaction.productID == AgeminProductID.yearly,
                  transaction.revocationDate == nil,
                  transaction.expirationDate == current.expirationDate,
                  (transaction.ownershipType == .familyShared) == current.isFamilyShared,
                  case .verified(let renewal) = status.renewalInfo else { continue }
            return renewal.willAutoRenew
        }
        return nil
    }

    // scheduleEntitlementRefresh(): Re-read a subscription's entitlement at most a minute out, so a
    // renewal or lapse shows promptly without waiting for a StoreKit update.
    private func scheduleEntitlementRefresh() {
        entitlementTimer?.invalidate()
        entitlementTimer = nil
        guard entitlement.kind == .subscription else { return }
        // Poll each minute, or at the expiry if sooner; after expiry, until StoreKit drops it.
        let remaining = entitlement.expirationDate?.timeIntervalSinceNow ?? 60
        let delay = remaining > 0 ? max(1, min(60, remaining)) : 60
        entitlementTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshEntitlement() }
        }
    }
}
