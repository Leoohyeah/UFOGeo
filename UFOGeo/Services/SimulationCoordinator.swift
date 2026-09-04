import CoreLocation
import Combine
import Foundation

enum SimulationMode: String, Equatable {
    case fixedLocation
    case route
}

enum SimulationUpdateIntent: Equatable {
    case singlePoint
    case fixedKeepAlive
    case joystickMovement
    case routeMovement
}

enum SimulationSessionState: Equatable {
    case idle
    case starting(SimulationMode)
    case running(SimulationMode)
    case stopping(SimulationMode)
    case failed(SimulationMode?, LocationSimulationError)

    var activeMode: SimulationMode? {
        switch self {
        case .idle:
            return nil
        case .starting(let mode), .running(let mode), .stopping(let mode):
            return mode
        case .failed:
            return nil
        }
    }
}

@MainActor
final class SimulationCoordinator: ObservableObject {
    static let shared = SimulationCoordinator()
    static let cancelledCommandCode: Int32 = 16
    static let joystickRequiresProCode: Int32 = 17
    private static let recoverableStartFailureCodes: Set<Int32> = [3, 9]
    private static let recoverableUpdateFailureCodes: Set<Int32> = [3, 9, 11]
    private static let recoverableStopFailureCodes: Set<Int32> = [3, 9, 12]
    private static let startRetryDelayNanoseconds: UInt64 = 300_000_000

    @Published private(set) var state: SimulationSessionState = .idle
    @Published private(set) var lastCoordinate: CLLocationCoordinate2D?

    private let service: LocationSimulationService
    private let isProProvider: @MainActor () -> Bool
    private var generation = 0
    private var joystickCommandGeneration = 0
    private var allowsModeSwitchWhileHoldingLocation = false
    private var startCallbackTask: Task<Void, Never>?

    init(
        service: LocationSimulationService = .shared,
        isProProvider: @escaping @MainActor () -> Bool = {
            PortalyCheckoutService.shared.canUseJoystick
        }
    ) {
        self.service = service
        self.isProProvider = isProProvider
    }

    func start(
        mode: SimulationMode,
        coordinate: CLLocationCoordinate2D,
        deviceIP: String,
        pairingFile: String,
        operation: String,
        completion: @escaping @MainActor (Result<Void, LocationSimulationError>) -> Void
    ) {
        startCallbackTask?.cancel()
        let preparation = prepareStart(mode: mode, operation: operation)
        guard case .success(let commandGeneration) = preparation else {
            if case .failure(let error) = preparation {
                completion(.failure(error))
            }
            return
        }
        startCallbackTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.performStart(
                mode: mode,
                coordinate: coordinate,
                deviceIP: deviceIP,
                pairingFile: pairingFile,
                operation: operation,
                commandGeneration: commandGeneration
            )
            completion(result)
        }
    }

    @discardableResult
    func start(
        mode: SimulationMode,
        coordinate: CLLocationCoordinate2D,
        deviceIP: String,
        pairingFile: String,
        operation: String
    ) async -> Result<Void, LocationSimulationError> {
        guard !Task.isCancelled else {
            return .failure(cancelledCommandError(operation: operation))
        }

        switch prepareStart(mode: mode, operation: operation) {
        case .failure(let error):
            return .failure(error)
        case .success(let commandGeneration):
            return await performStart(
                mode: mode,
                coordinate: coordinate,
                deviceIP: deviceIP,
                pairingFile: pairingFile,
                operation: operation,
                commandGeneration: commandGeneration
            )
        }
    }

    private func prepareStart(
        mode: SimulationMode,
        operation: String
    ) -> Result<Int, LocationSimulationError> {
        if let activeMode = state.activeMode,
           activeMode != mode,
           !allowsModeSwitchWhileHoldingLocation {
            let error = LocationSimulationError(code: 13, operation: operation)
            state = .failed(activeMode, error)
            return .failure(error)
        }

        allowsModeSwitchWhileHoldingLocation = false
        generation += 1
        let commandGeneration = generation
        state = .starting(mode)
        return .success(commandGeneration)
    }

    private func performStart(
        mode: SimulationMode,
        coordinate: CLLocationCoordinate2D,
        deviceIP: String,
        pairingFile: String,
        operation: String,
        commandGeneration: Int
    ) async -> Result<Void, LocationSimulationError> {
        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        let result = await setLocationWithRecoverableRetry(
            deviceIP: deviceIP,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingFile: pairingFile,
            operation: operation,
            retryFailureCodes: Self.recoverableStartFailureCodes,
            commandGeneration: commandGeneration
        )

        guard isCommandCurrent(commandGeneration) else { return result }

        switch result {
        case .success:
            lastCoordinate = coordinate
            state = .running(mode)
            BackgroundSimulationManager.shared.markSimulationActive(mode: mode)
            let bgActivity: BackgroundLocationManager.Activity = (mode == .route) ? .route : .continuousLocation
            BackgroundLocationManager.shared.requestStart(for: bgActivity)
        case .failure(let error):
            state = .failed(mode, error)
        }
        return result
    }

    @discardableResult
    func update(
        coordinate: CLLocationCoordinate2D,
        deviceIP: String,
        pairingFile: String,
        intent: SimulationUpdateIntent = .singlePoint,
        operation: String
    ) async -> Result<Void, LocationSimulationError> {
        guard !Task.isCancelled else {
            return .failure(cancelledCommandError(operation: operation))
        }

        guard canPerformUpdate(intent) else {
            return .failure(joystickRequiresProError(operation: operation))
        }

        guard case .running = state else {
            return .failure(LocationSimulationError(code: 14, operation: operation))
        }
        let joystickGeneration = intent == .joystickMovement
            ? joystickCommandGeneration
            : nil
        generation &+= 1
        return await performUpdate(
            coordinate: coordinate,
            deviceIP: deviceIP,
            pairingFile: pairingFile,
            intent: intent,
            joystickGeneration: joystickGeneration,
            operation: operation,
            commandGeneration: generation
        )
    }

    private func performUpdate(
        coordinate: CLLocationCoordinate2D,
        deviceIP: String,
        pairingFile: String,
        intent: SimulationUpdateIntent,
        joystickGeneration: Int?,
        operation: String,
        commandGeneration: Int
    ) async -> Result<Void, LocationSimulationError> {
        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        guard canContinueUpdate(intent, joystickGeneration: joystickGeneration) else {
            return .failure(joystickRequiresProError(operation: operation))
        }

        guard case .running(let mode) = state else {
            let error = LocationSimulationError(code: 14, operation: operation)
            return .failure(error)
        }

        let result = await setLocationWithRecoverableRetry(
            deviceIP: deviceIP,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingFile: pairingFile,
            operation: operation,
            retryFailureCodes: Self.recoverableUpdateFailureCodes,
            commandGeneration: commandGeneration,
            updateIntent: intent,
            joystickGeneration: joystickGeneration
        )
        guard isCommandCurrent(commandGeneration) else { return result }

        switch result {
        case .success:
            lastCoordinate = coordinate
            state = .running(mode)
        case .failure:
            // Keep session in running state for transient update failures.
            // Callers still receive the failure and can decide UI/retry behavior.
            state = .running(mode)
        }
        return result
    }

    func update(
        coordinate: CLLocationCoordinate2D,
        deviceIP: String,
        pairingFile: String,
        intent: SimulationUpdateIntent = .singlePoint,
        operation: String,
        completion: @escaping @MainActor (Result<Void, LocationSimulationError>) -> Void
    ) {
        guard canPerformUpdate(intent) else {
            completion(.failure(joystickRequiresProError(operation: operation)))
            return
        }
        guard case .running = state else {
            completion(.failure(LocationSimulationError(code: 14, operation: operation)))
            return
        }
        let joystickGeneration = intent == .joystickMovement
            ? joystickCommandGeneration
            : nil
        generation &+= 1
        let commandGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            let result = await self.performUpdate(
                coordinate: coordinate,
                deviceIP: deviceIP,
                pairingFile: pairingFile,
                intent: intent,
                joystickGeneration: joystickGeneration,
                operation: operation,
                commandGeneration: commandGeneration
            )
            // Always complete, including a stale command. Callers need a
            // result to release loading state; the error code lets them
            // ignore state changes that belong to an older session.
            completion(result)
        }
    }

    /// Invalidates in-flight commands without clearing the device's current
    /// simulated location. This is used when a UI session stops holding its
    /// location so a late callback cannot continue an old command chain.
    func invalidatePendingCommands() {
        startCallbackTask?.cancel()
        startCallbackTask = nil
        generation += 1
        switch state {
        case .starting:
            state = .idle
            lastCoordinate = nil
        case .stopping(let mode):
            // The clear command was invalidated before it completed, so the
            // device still owns the last simulated location.
            state = .running(mode)
        default:
            break
        }
    }

    /// 只撤銷搖桿命令鏈，不影響固定單點或背景 heartbeat。
    func invalidatePendingJoystickCommands() {
        joystickCommandGeneration &+= 1
    }

    @discardableResult
    func stop(
        operation: String,
        after delay: TimeInterval = 0
    ) async -> Result<Void, LocationSimulationError> {
        guard !Task.isCancelled else {
            return .failure(cancelledCommandError(operation: operation))
        }

        startCallbackTask?.cancel()
        startCallbackTask = nil
        let mode = state.activeMode
        allowsModeSwitchWhileHoldingLocation = false
        generation += 1
        let commandGeneration = generation
        if let mode {
            state = .stopping(mode)
        }

        let result = await clearLocationWithRecoverableRetry(
            operation: operation,
            after: delay,
            retryFailureCodes: Self.recoverableStopFailureCodes,
            commandGeneration: commandGeneration
        )
        guard commandGeneration == generation, !Task.isCancelled else { return result }

        switch result {
        case .success:
            lastCoordinate = nil
            state = .idle
        case .failure(let error):
            state = .failed(mode, error)
        }
        return result
    }

    /// 使用者已停止目前的移動，但裝置仍保留最後模擬座標。
    /// 下一次啟動可直接接管並切換模式，不必先清除座標。
    func allowNextModeSwitchWhileHoldingLocation() {
        allowsModeSwitchWhileHoldingLocation = true
    }

    func stop(
        operation: String,
        after delay: TimeInterval = 0,
        completion: @escaping @MainActor (Result<Void, LocationSimulationError>) -> Void
    ) {
        Task {
            completion(await stop(operation: operation, after: delay))
        }
    }

    private func setLocationWithRecoverableRetry(
        deviceIP: String,
        latitude: Double,
        longitude: Double,
        pairingFile: String,
        operation: String,
        retryFailureCodes: Set<Int32>,
        commandGeneration: Int,
        updateIntent: SimulationUpdateIntent? = nil,
        joystickGeneration: Int? = nil
    ) async -> Result<Void, LocationSimulationError> {
        var result = await service.setLocation(
            deviceIP: deviceIP,
            latitude: latitude,
            longitude: longitude,
            pairingFile: pairingFile,
            operation: operation
        )

        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        guard updateIntent.map({
            canContinueUpdate($0, joystickGeneration: joystickGeneration)
        }) ?? true else {
            return .failure(joystickRequiresProError(operation: operation))
        }
        guard shouldRetryRecoverableFailure(result, retryFailureCodes: retryFailureCodes) else {
            return result
        }

        await service.resetConnectionState()
        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        guard updateIntent.map({
            canContinueUpdate($0, joystickGeneration: joystickGeneration)
        }) ?? true else {
            return .failure(joystickRequiresProError(operation: operation))
        }
        do {
            try await Task.sleep(nanoseconds: Self.startRetryDelayNanoseconds)
        } catch {
            return .failure(cancelledCommandError(operation: operation))
        }
        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        guard updateIntent.map({
            canContinueUpdate($0, joystickGeneration: joystickGeneration)
        }) ?? true else {
            return .failure(joystickRequiresProError(operation: operation))
        }
        result = await service.setLocation(
            deviceIP: deviceIP,
            latitude: latitude,
            longitude: longitude,
            pairingFile: pairingFile,
            operation: "\(operation)（重試）"
        )
        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        guard updateIntent.map({
            canContinueUpdate($0, joystickGeneration: joystickGeneration)
        }) ?? true else {
            return .failure(joystickRequiresProError(operation: operation))
        }
        return result
    }

    private func clearLocationWithRecoverableRetry(
        operation: String,
        after delay: TimeInterval,
        retryFailureCodes: Set<Int32>,
        commandGeneration: Int
    ) async -> Result<Void, LocationSimulationError> {
        var result = await service.clearLocation(operation: operation, after: delay)

        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        guard shouldRetryRecoverableFailure(result, retryFailureCodes: retryFailureCodes) else {
            return result
        }

        await service.resetConnectionState()
        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        do {
            try await Task.sleep(nanoseconds: Self.startRetryDelayNanoseconds)
        } catch {
            return .failure(cancelledCommandError(operation: operation))
        }
        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        result = await service.clearLocation(
            operation: "\(operation)（重試）",
            after: 0
        )
        guard isCommandCurrent(commandGeneration) else {
            return .failure(cancelledCommandError(operation: operation))
        }
        return result
    }

    private func isCommandCurrent(_ commandGeneration: Int) -> Bool {
        !Task.isCancelled && commandGeneration == generation
    }

    private func cancelledCommandError(operation: String) -> LocationSimulationError {
        LocationSimulationError(code: Self.cancelledCommandCode, operation: operation)
    }

    private func joystickRequiresProError(operation: String) -> LocationSimulationError {
        LocationSimulationError(code: Self.joystickRequiresProCode, operation: operation)
    }

    private func canPerformUpdate(_ intent: SimulationUpdateIntent) -> Bool {
        intent != .joystickMovement || isProProvider()
    }

    private func canContinueUpdate(
        _ intent: SimulationUpdateIntent,
        joystickGeneration: Int?
    ) -> Bool {
        guard intent == .joystickMovement else { return true }
        return isProProvider() && joystickGeneration == joystickCommandGeneration
    }

    private func shouldRetryRecoverableFailure(
        _ result: Result<Void, LocationSimulationError>,
        retryFailureCodes: Set<Int32>
    ) -> Bool {
        guard case .failure(let error) = result else { return false }
        return retryFailureCodes.contains(error.code)
    }

}
