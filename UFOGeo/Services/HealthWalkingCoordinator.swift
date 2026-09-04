import Combine
import Foundation
import UIKit

/// The single owner of UFOGeo's automatic walking state.
///
/// The coordinator deliberately separates the simulated progress kept by UFOGeo
/// from the samples already written to HealthKit.  A HealthKit write is
/// serialized here, so the location and route screens cannot race each other
/// while updating the same pending/written counters.
@MainActor
protocol HealthStepWriting: AnyObject {
    var isAvailable: Bool { get }

    func requestAuthorizationIfNeeded(completion: @escaping @MainActor (Bool) -> Void)
    func writeSteps(
        _ steps: Int,
        remainingSteps: Int?,
        at date: Date,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    )
}

extension HealthStepSyncManager: HealthStepWriting {}

@MainActor
final class HealthWalkingCoordinator: ObservableObject {
    static let shared = HealthWalkingCoordinator()
    static let freeDailyTarget = 10_000
    static let freeBatchSize = 1_000
    private static let defaultProTarget = 1_000
    private static let defaultProBatchSize = 100

    private enum Activity: Equatable {
        case none
        case route(speedMetersPerSecond: Double)
        case fixed

        var speedMetersPerSecond: Double {
            switch self {
            case .none: return 0
            case .route(let speed): return max(speed, 0)
            case .fixed: return 1
            }
        }
    }

    private enum DefaultsKey {
        static let fraction = UserDefaults.Keys.pendingHealthSimulationFraction
    }

    private let defaults: UserDefaults
    private let writer: HealthStepWriting
    private let calendar: Calendar
    private let isProProvider: () -> Bool
    private let isAppActiveProvider: () -> Bool
    private var lifecycleObserverTokens: [NSObjectProtocol] = []
    private var activity: Activity = .none
    private var lastActivityDate: Date?
    private var timer: Timer?
    private var pendingFraction = 0.0
    private var isWriteInFlight = false
    private var inFlightGeneration: UUID?
    private var generation = UUID()
    private var inFlightBatch = 0
    private var shouldFlushRemainder = false
    private var isAuthorizing = false
    private var authorizationRequestInFlight = false
    private var hasAuthorizationResult = false
    private var authorizationGeneration = UUID()
    private var pendingEnableCompletion: (@MainActor (Bool) -> Void)?
    private var lastKnownProState: Bool
    private var lastObservedAppActive: Bool

    @Published private(set) var isEnabled: Bool
    @Published private(set) var stepsPerSecond: Int
    @Published private(set) var batchSize: Int
    @Published private(set) var target: Int
    @Published private(set) var pendingSteps: Int
    @Published private(set) var writtenSteps: Int

    var totalProgress: Int { pendingSteps + writtenSteps }
    var remainingSteps: Int { max(target - totalProgress, 0) }
    var isPro: Bool { isProProvider() }
    var isGenerating: Bool {
        isEnabled
            && !isAuthorizing
            && activity != .none
            && activity.speedMetersPerSecond > 0
            && remainingSteps > 0
    }

    init(
        defaults: UserDefaults = .standard,
        writer: HealthStepWriting? = nil,
        automaticallyStartTimer: Bool = true,
        calendar: Calendar = .autoupdatingCurrent,
        currentDate: Date = Date(),
        isProProvider: (() -> Bool)? = nil,
        isAppActiveProvider: (() -> Bool)? = nil
    ) {
        self.defaults = defaults
        let resolvedWriter = writer ?? HealthStepSyncManager.shared
        self.writer = resolvedWriter
        self.calendar = calendar
        self.isProProvider = isProProvider ?? { PortalyCheckoutService.shared.isPro }
        self.isAppActiveProvider = isAppActiveProvider ?? {
            UIApplication.shared.applicationState == .active
        }
        let initialIsPro = self.isProProvider()
        self.lastKnownProState = initialIsPro
        self.lastObservedAppActive = self.isAppActiveProvider()
        let savedEnabled = defaults.bool(forKey: UserDefaults.Keys.healthWalkingEnabled)
        let initialEnabled = savedEnabled && resolvedWriter.isAvailable
        self.isEnabled = initialEnabled
        self.isAuthorizing = initialEnabled
        if savedEnabled && !resolvedWriter.isAvailable {
            defaults.set(false, forKey: UserDefaults.Keys.healthWalkingEnabled)
        }
        self.stepsPerSecond = Self.clampedRate(
            defaults.object(forKey: UserDefaults.Keys.walkingStepsPerSecond) == nil
                ? 1
                : defaults.integer(forKey: UserDefaults.Keys.walkingStepsPerSecond)
        )
        let legacyBatchSize = defaults.object(forKey: UserDefaults.Keys.walkingStepResetTarget) == nil
            ? nil
            : max(defaults.integer(forKey: UserDefaults.Keys.walkingStepResetTarget), 1)
        let savedProBatchSize = defaults.object(forKey: UserDefaults.Keys.savedProHealthBatchSize) == nil
            ? nil
            : max(defaults.integer(forKey: UserDefaults.Keys.savedProHealthBatchSize), 1)
        let resolvedProBatchSize = savedProBatchSize ?? legacyBatchSize ?? Self.defaultProBatchSize
        if initialIsPro {
            self.batchSize = resolvedProBatchSize
            defaults.set(resolvedProBatchSize, forKey: UserDefaults.Keys.savedProHealthBatchSize)
            defaults.set(resolvedProBatchSize, forKey: UserDefaults.Keys.walkingStepResetTarget)
        } else {
            self.batchSize = Self.freeBatchSize
            // Migrate an older Pro preference before replacing the active
            // Free value. The dedicated key keeps it safe across downgrade.
            if savedProBatchSize == nil, let legacyBatchSize {
                defaults.set(legacyBatchSize, forKey: UserDefaults.Keys.savedProHealthBatchSize)
            }
            defaults.set(Self.freeBatchSize, forKey: UserDefaults.Keys.walkingStepResetTarget)
        }
        let legacyTarget = defaults.object(forKey: UserDefaults.Keys.healthStepWriteTarget) == nil
            ? nil
            : max(defaults.integer(forKey: UserDefaults.Keys.healthStepWriteTarget), 1)
        let savedProTarget = defaults.object(forKey: UserDefaults.Keys.savedHealthSimulationTarget) == nil
            ? nil
            : max(defaults.integer(forKey: UserDefaults.Keys.savedHealthSimulationTarget), 1)
        let resolvedProTarget = savedProTarget ?? legacyTarget ?? Self.defaultProTarget
        if initialIsPro {
            self.target = resolvedProTarget
            defaults.set(resolvedProTarget, forKey: UserDefaults.Keys.savedHealthSimulationTarget)
            defaults.set(resolvedProTarget, forKey: UserDefaults.Keys.healthStepWriteTarget)
        } else {
            self.target = Self.freeDailyTarget
            // A value written by an older build is the best available source
            // for the Pro preference. Never replace it with Free's 10,000.
            if savedProTarget == nil, let legacyTarget {
                defaults.set(legacyTarget, forKey: UserDefaults.Keys.savedHealthSimulationTarget)
            }
        }
        self.pendingSteps = max(
            defaults.integer(forKey: UserDefaults.Keys.pendingHealthSimulationSteps),
            0
        )
        self.writtenSteps = max(
            defaults.integer(forKey: UserDefaults.Keys.writtenHealthSimulationSteps),
            0
        )
        self.pendingFraction = min(
            max(defaults.double(forKey: DefaultsKey.fraction), 0),
            0.999_999
        )

        ensureNaturalDay(at: currentDate)
        installLifecycleObservers()

        if automaticallyStartTimer && isGenerating {
            startTimerIfNeeded()
        }
    }

    deinit {
        timer?.invalidate()
        lifecycleObserverTokens.forEach(NotificationCenter.default.removeObserver)
    }

    static func clampedRate(_ value: Int) -> Int {
        min(max(value, 1), 3)
    }

    static func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(components.era ?? 0)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObserverTokens = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppDidEnterBackground(at: Date())
                }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppWillEnterForeground(at: Date())
                }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppDidEnterBackground(at: Date())
                }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppWillEnterForeground(at: Date())
                }
            }
        ]
    }

    private func handleAppDidEnterBackground(at date: Date) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)
        lastObservedAppActive = false
        if !isPro {
            // Free does not earn simulated steps while backgrounded. The
            // baseline is moved at the transition so the next foreground
            // tick cannot backfill the suspended interval.
            lastActivityDate = date
            persist()
        }
    }

    private func handleAppWillEnterForeground(at date: Date) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)
        lastObservedAppActive = true
        guard !isPro else { return }

        // Do not count time spent in the background. Any pending steps that
        // were generated before suspension may still be flushed now that
        // writing is allowed again.
        lastActivityDate = date
        persist()
        attemptWriteIfNeeded(at: date)
    }

    private func shouldSkipFreeBackgroundActivity(at date: Date) -> Bool {
        let isAppActive = isAppActiveProvider()
        let wasAppActive = lastObservedAppActive
        lastObservedAppActive = isAppActive

        guard !isPro else { return false }
        guard isAppActive, wasAppActive else {
            lastActivityDate = date
            persist()
            return true
        }
        return false
    }

    // MARK: - Activity lifecycle

    /// Start a fixed-location session. Fixed-location mode represents walking
    /// for the whole session, so it keeps generating steps even while the
    /// joystick is idle.
    func prepareFixedSimulation(at date: Date = Date()) {
        setActivity(.fixed, at: date)
    }

    func stopFixedSimulation(at date: Date = Date()) {
        finishActivity(flushRemainder: true, at: date)
    }

    func startRouteSimulation(
        speedKilometersPerHour: Double,
        at date: Date = Date()
    ) {
        let metersPerSecond = max(speedKilometersPerHour, 0) / 3.6
        setActivity(
            .route(speedMetersPerSecond: metersPerSecond),
            at: date
        )
    }

    func updateRouteSpeed(
        speedKilometersPerHour: Double,
        at date: Date = Date()
    ) {
        guard case .route = activity else { return }
        startRouteSimulation(speedKilometersPerHour: speedKilometersPerHour, at: date)
    }

    func pauseRoute(at date: Date = Date()) {
        setActivity(.none, at: date)
    }

    func resumeRoute(
        speedKilometersPerHour: Double,
        at date: Date = Date()
    ) {
        startRouteSimulation(speedKilometersPerHour: speedKilometersPerHour, at: date)
    }

    func stopRoute(at date: Date = Date()) {
        finishActivity(flushRemainder: true, at: date)
    }

    func advanceForBackgroundHeartbeat(at date: Date = Date()) {
        tick(at: date)
    }

    /// Pure time policy entry point used by the UI and by tests.  A non-active
    /// state always resets its baseline, so a pause/off interval is never
    /// counted when the next active heartbeat arrives.
    func tick(at date: Date) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)

        if shouldSkipFreeBackgroundActivity(at: date) {
            return
        }

        guard isEnabled, !isAuthorizing else {
            lastActivityDate = date
            return
        }
        guard activity != .none, activity.speedMetersPerSecond > 0 else {
            lastActivityDate = date
            return
        }
        guard let previousDate = lastActivityDate else {
            lastActivityDate = date
            return
        }
        guard date >= previousDate else {
            return
        }

        let elapsed = min(max(date.timeIntervalSince(previousDate), 0), 86_400)
        lastActivityDate = date
        guard elapsed > 0 else { return }

        pendingFraction += elapsed * Double(stepsPerSecond)
        let generatedSteps = Int(pendingFraction.rounded(.down))
        guard generatedSteps > 0 else {
            persist()
            return
        }
        pendingFraction -= Double(generatedSteps)

        let accepted = min(generatedSteps, remainingSteps)
        if accepted > 0 {
            pendingSteps += accepted
        }
        persist()
        attemptWriteIfNeeded(at: date)
        if remainingSteps == 0 {
            stopTimer()
        }
    }

    // MARK: - Settings and progress

    /// Re-evaluate the shared Portaly entitlement when the settings screen or
    /// subscription state becomes active. The same check also protects the
    /// natural-day boundary when the app has been suspended.
    func refreshEntitlement(at date: Date = Date()) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)
    }

    func setEnabled(
        _ enabled: Bool,
        at date: Date = Date(),
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)

        if !enabled {
            authorizationGeneration = UUID()
            authorizationRequestInFlight = false
            hasAuthorizationResult = false
            isAuthorizing = false
            pendingEnableCompletion = nil
            isEnabled = false
            defaults.set(false, forKey: UserDefaults.Keys.healthWalkingEnabled)
            shouldFlushRemainder = false
            lastActivityDate = date
            stopTimer()
            completion?(true)
            return
        }

        if isEnabled && hasAuthorizationResult {
            completion?(true)
            return
        }

        guard writer.isAvailable else {
            isAuthorizing = false
            isEnabled = false
            defaults.set(false, forKey: UserDefaults.Keys.healthWalkingEnabled)
            completion?(false)
            return
        }

        isEnabled = true
        isAuthorizing = true
        hasAuthorizationResult = false
        pendingEnableCompletion = completion
        defaults.set(true, forKey: UserDefaults.Keys.healthWalkingEnabled)
        lastActivityDate = date
        shouldFlushRemainder = false
        startTimerIfNeeded()
        requestAuthorizationIfNeeded()
    }

    func updateRate(_ value: Int, at date: Date = Date()) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)
        stepsPerSecond = Self.clampedRate(value)
        defaults.set(stepsPerSecond, forKey: UserDefaults.Keys.walkingStepsPerSecond)
        lastActivityDate = date
        pendingFraction = 0
        persist()
        if isGenerating { startTimerIfNeeded() }
    }

    func updateBatchSize(_ value: Int, at date: Date = Date()) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)
        guard isPro else { return }
        batchSize = max(value, 1)
        defaults.set(batchSize, forKey: UserDefaults.Keys.walkingStepResetTarget)
        persist()
        attemptWriteIfNeeded(at: date)
    }

    func updateTarget(_ value: Int, at date: Date = Date()) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)
        guard isPro else { return }
        target = max(value, 1)
        defaults.set(target, forKey: UserDefaults.Keys.healthStepWriteTarget)
        defaults.set(target, forKey: UserDefaults.Keys.savedHealthSimulationTarget)
        generation = UUID()
        // Keep an existing HealthKit write busy until its callback returns.
        // The callback will clear the old busy slot without touching this
        // new round, then the next tick may start a new generation write.
        pendingSteps = 0
        writtenSteps = 0
        pendingFraction = 0
        shouldFlushRemainder = false
        lastActivityDate = date
        persist()
    }

    // MARK: - Internal write queue

    private func setActivity(_ next: Activity, at date: Date) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)

        if activity == next {
            if isGenerating {
                startTimerIfNeeded()
            } else {
                stopTimer()
            }
            return
        }

        // Account for the old activity up to the transition instant before
        // replacing it.  Repeated joystick callbacks with the same activity
        // therefore do not move the baseline or lose elapsed time.
        if activity != .none {
            tick(at: date)
        }
        activity = next
        lastActivityDate = date
        if next != .none {
            shouldFlushRemainder = false
            requestAuthorizationIfNeeded()
        }
        if isGenerating {
            startTimerIfNeeded()
        } else {
            stopTimer()
        }
    }

    private func finishActivity(flushRemainder: Bool, at date: Date) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)
        tick(at: date)
        activity = .none
        lastActivityDate = date
        stopTimer()
        shouldFlushRemainder = flushRemainder
        attemptWriteIfNeeded(at: date)
    }

    private func startTimerIfNeeded() {
        guard timer == nil, isGenerating else { return }
        let newTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick(at: Date())
            }
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func requestAuthorizationIfNeeded() {
        guard isEnabled,
              writer.isAvailable,
              !authorizationRequestInFlight,
              !hasAuthorizationResult else { return }
        isAuthorizing = true
        authorizationRequestInFlight = true
        let requestGeneration = UUID()
        authorizationGeneration = requestGeneration
        writer.requestAuthorizationIfNeeded { [weak self] granted in
            guard let self,
                  self.authorizationGeneration == requestGeneration else { return }
            self.authorizationRequestInFlight = false
            self.hasAuthorizationResult = true
            self.isAuthorizing = false
            if !granted {
                self.isEnabled = false
                self.defaults.set(false, forKey: UserDefaults.Keys.healthWalkingEnabled)
                self.lastActivityDate = Date()
                self.stopTimer()
            } else {
                // Time spent waiting for the permission prompt is never
                // treated as active walking time.
                self.lastActivityDate = Date()
                if self.isGenerating {
                    self.startTimerIfNeeded()
                }
            }
            let completion = self.pendingEnableCompletion
            self.pendingEnableCompletion = nil
            completion?(granted)
        }
    }

    private func attemptWriteIfNeeded(at date: Date) {
        synchronizeEntitlementIfNeeded(at: date)
        ensureNaturalDay(at: date)
        if !isPro && !isAppActiveProvider() {
            // A completion from a foreground write can arrive after the app
            // was backgrounded. Keep the pending steps, but never start a
            // new HealthKit write from the background.
            lastObservedAppActive = false
            lastActivityDate = date
            persist()
            return
        }
        guard isEnabled, !isWriteInFlight, pendingSteps > 0 else { return }

        let remainingTarget = max(target - writtenSteps, 0)
        guard remainingTarget > 0 else { return }
        let reachedTarget = pendingSteps >= remainingTarget
        let threshold = shouldFlushRemainder || reachedTarget ? 1 : batchSize
        guard pendingSteps >= threshold || shouldFlushRemainder else { return }

        let batch = min(pendingSteps, remainingTarget, shouldFlushRemainder ? pendingSteps : batchSize)
        guard batch > 0 else { return }

        isWriteInFlight = true
        let writeGeneration = generation
        inFlightGeneration = writeGeneration
        inFlightBatch = batch
        let writeDayIdentifier = Self.dayIdentifier(for: date, calendar: calendar)
        let remainingAfterWrite = max(remainingTarget - batch, 0)

        writer.writeSteps(
            batch,
            remainingSteps: remainingAfterWrite,
            at: date
        ) { [weak self] result in
            guard let self else { return }
            // Re-check the day before touching counters. A rollover may have
            // invalidated this generation while HealthKit was in flight. Keep
            // the write lock until this callback arrives so a new day's
            // HealthKit sample is not submitted concurrently with yesterday's.
            self.ensureNaturalDay(at: date)
            guard self.inFlightGeneration == writeGeneration else { return }

            let callbackDayMatchesWrite = self.defaults.string(
                forKey: UserDefaults.Keys.healthSimulationDayIdentifier
            ) == writeDayIdentifier
            guard callbackDayMatchesWrite else {
                self.isWriteInFlight = false
                self.inFlightGeneration = nil
                self.inFlightBatch = 0
                self.attemptWriteIfNeeded(at: self.lastActivityDate ?? date)
                return
            }

            self.isWriteInFlight = false
            self.inFlightGeneration = nil
            self.inFlightBatch = 0
            guard case .success = result else {
                self.shouldFlushRemainder = false
                if self.generation != writeGeneration {
                    self.attemptWriteIfNeeded(at: self.lastActivityDate ?? date)
                }
                return
            }

            if self.generation != writeGeneration {
                self.attemptWriteIfNeeded(at: self.lastActivityDate ?? date)
                return
            }

            self.pendingSteps = max(self.pendingSteps - batch, 0)
            self.writtenSteps += batch
            self.persist()
            if self.isEnabled {
                self.attemptWriteIfNeeded(at: self.lastActivityDate ?? date)
            }
        }
    }

    private func persist() {
        defaults.set(pendingSteps, forKey: UserDefaults.Keys.pendingHealthSimulationSteps)
        defaults.set(writtenSteps, forKey: UserDefaults.Keys.writtenHealthSimulationSteps)
        if isPro {
            defaults.set(batchSize, forKey: UserDefaults.Keys.walkingStepResetTarget)
            defaults.set(batchSize, forKey: UserDefaults.Keys.savedProHealthBatchSize)
            defaults.set(target, forKey: UserDefaults.Keys.healthStepWriteTarget)
            defaults.set(target, forKey: UserDefaults.Keys.savedHealthSimulationTarget)
        } else {
            defaults.set(Self.freeBatchSize, forKey: UserDefaults.Keys.walkingStepResetTarget)
        }
        defaults.set(pendingFraction, forKey: DefaultsKey.fraction)
    }

    // MARK: - Entitlement and natural-day boundaries

    private func synchronizeEntitlementIfNeeded(at date: Date) {
        let currentIsPro = isProProvider()
        guard currentIsPro != lastKnownProState else { return }

        if currentIsPro {
            let restoredTarget = defaults.object(
                forKey: UserDefaults.Keys.savedHealthSimulationTarget
            ) == nil
                ? Self.defaultProTarget
                : max(defaults.integer(forKey: UserDefaults.Keys.savedHealthSimulationTarget), 1)
            target = restoredTarget
            defaults.set(restoredTarget, forKey: UserDefaults.Keys.healthStepWriteTarget)

            let restoredBatchSize = defaults.object(
                forKey: UserDefaults.Keys.savedProHealthBatchSize
            ) == nil
                ? Self.defaultProBatchSize
                : max(defaults.integer(forKey: UserDefaults.Keys.savedProHealthBatchSize), 1)
            batchSize = restoredBatchSize
            defaults.set(restoredBatchSize, forKey: UserDefaults.Keys.walkingStepResetTarget)
        } else {
            let proTarget = max(target, 1)
            defaults.set(proTarget, forKey: UserDefaults.Keys.savedHealthSimulationTarget)
            target = Self.freeDailyTarget

            let proBatchSize = max(batchSize, 1)
            defaults.set(proBatchSize, forKey: UserDefaults.Keys.savedProHealthBatchSize)
            batchSize = Self.freeBatchSize
            defaults.set(Self.freeBatchSize, forKey: UserDefaults.Keys.walkingStepResetTarget)
        }

        lastKnownProState = currentIsPro
        persist()
        ensureNaturalDay(at: date)
    }

    private func ensureNaturalDay(at date: Date) {
        let identifier = Self.dayIdentifier(for: date, calendar: calendar)
        guard let storedIdentifier = defaults.string(
            forKey: UserDefaults.Keys.healthSimulationDayIdentifier
        ) else {
            defaults.set(identifier, forKey: UserDefaults.Keys.healthSimulationDayIdentifier)
            return
        }
        guard storedIdentifier != identifier else { return }
        // Location callbacks can arrive out of order. Never move a running
        // coordinator back to an older natural day because of a stale sample.
        if let lastActivityDate, date < lastActivityDate {
            return
        }

        // Invalidate the old callback before clearing the day's counters. Keep
        // the in-flight lock until its callback arrives so HealthKit writes
        // remain serialized across midnight. The callback can still arrive,
        // but its generation no longer matches and therefore cannot add
        // yesterday's batch to today's progress.
        generation = UUID()
        inFlightBatch = 0
        pendingSteps = 0
        writtenSteps = 0
        pendingFraction = 0
        shouldFlushRemainder = false
        lastActivityDate = date
        defaults.set(identifier, forKey: UserDefaults.Keys.healthSimulationDayIdentifier)
        persist()
        if isGenerating {
            startTimerIfNeeded()
        }
    }
}
