import Foundation
import CoreLocation
import Testing
@testable import UFOGeo

struct SimulationCommandTimeoutTests {
    @Test @MainActor func blockedDeviceCommandTimesOutAndCompletesOnlyOnce() async {
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.timeout"),
            setOperation: { _, _, _, _ in
                Thread.sleep(forTimeInterval: 0.35)
                return 0
            },
            clearOperation: { 0 },
            commandTimeout: 0.1
        )
        var completionCount = 0
        var receivedResult: Result<Void, LocationSimulationError>?

        service.setLocation(
            deviceIP: "10.7.0.1",
            latitude: 25.033,
            longitude: 121.5654,
            pairingFile: "/tmp/pairing.plist",
            operation: "測試逾時"
        ) { result in
            completionCount += 1
            receivedResult = result
        }

        try? await Task.sleep(for: .seconds(0.5))

        #expect(completionCount == 1)
        #expect(receivedResult?.failure?.code == 15)
    }

    @Test @MainActor func lateStartResultCannotMakeTimedOutCoordinatorRun() async {
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.start-timeout"),
            setOperation: { _, _, _, _ in
                Thread.sleep(forTimeInterval: 0.35)
                return 0
            },
            clearOperation: { 0 },
            commandTimeout: 0.1
        )
        let coordinator = SimulationCoordinator(service: service)

        let result = await coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "測試啟動逾時"
        )

        #expect(result.failure?.code == 15)
        #expect(coordinator.state.activeMode == nil)

        try? await Task.sleep(for: .seconds(0.35))

        #expect(coordinator.state.activeMode == nil)
        #expect(coordinator.lastCoordinate == nil)
    }

    @Test @MainActor func supersededStartCompletesOldCallerWithoutChangingNewSession() async {
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.superseded-start"),
            setOperation: { _, _, _, _ in
                Thread.sleep(forTimeInterval: 0.15)
                return 0
            },
            clearOperation: { 0 },
            commandTimeout: 1
        )
        let coordinator = SimulationCoordinator(service: service)
        var oldCompletionCount = 0
        var oldResult: Result<Void, LocationSimulationError>?
        var newCompletionCount = 0

        coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "舊啟動"
        ) { result in
            oldCompletionCount += 1
            oldResult = result
        }
        try? await Task.sleep(for: .milliseconds(30))
        coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "新啟動"
        ) { _ in
            newCompletionCount += 1
        }

        try? await Task.sleep(for: .milliseconds(400))

        #expect(oldCompletionCount == 1)
        #expect(oldResult?.failure?.code == SimulationCoordinator.cancelledCommandCode)
        #expect(newCompletionCount == 1)
        #expect(coordinator.lastCoordinate?.latitude == 24.1477)
        #expect(coordinator.state == .running(.fixedLocation))
    }

    @Test @MainActor func recoverableRetryStopsBeforeSecondFFIAfterSessionInvalidation() async {
        let lock = NSLock()
        var setCallCount = 0
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.cancel-retry"),
            setOperation: { _, _, _, _ in
                lock.lock()
                setCallCount += 1
                lock.unlock()
                return 3
            },
            clearOperation: { 0 },
            resetOperation: { },
            commandTimeout: 1
        )
        let coordinator = SimulationCoordinator(service: service)
        let startTask = Task { @MainActor in
            await coordinator.start(
                mode: .fixedLocation,
                coordinate: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
                deviceIP: "10.7.0.1",
                pairingFile: "/tmp/pairing.plist",
                operation: "取消重試"
            )
        }

        try? await Task.sleep(for: .milliseconds(60))
        coordinator.invalidatePendingCommands()
        let result = await startTask.value

        let calls = setCallCount
        #expect(result.failure?.code == SimulationCoordinator.cancelledCommandCode)
        #expect(calls == 1)
        #expect(coordinator.state == .idle)
    }

    @Test @MainActor func staleUpdateCompletionIsDeliveredAndCannotChangeNewSession() async {
        let lock = NSLock()
        var setCallCount = 0
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.stale-update"),
            setOperation: { _, _, _, _ in
                lock.lock()
                setCallCount += 1
                let call = setCallCount
                lock.unlock()
                if call == 2 {
                    Thread.sleep(forTimeInterval: 0.15)
                }
                return 0
            },
            clearOperation: { 0 },
            commandTimeout: 1
        )
        let coordinator = SimulationCoordinator(service: service)

        let initial = await coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "初始啟動"
        )
        guard case .success = initial else {
            Issue.record("初始模擬應成功啟動")
            return
        }

        // The injected service deliberately holds the update FFI call so the
        // generation change happens while its callback is still pending.
        var completionCount = 0
        var staleResult: Result<Void, LocationSimulationError>?
        coordinator.update(
            coordinate: CLLocationCoordinate2D(latitude: 25.034, longitude: 121.566),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "舊更新"
        ) { result in
            completionCount += 1
            staleResult = result
        }

        coordinator.invalidatePendingCommands()
        let next = await coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "新啟動"
        )
        try? await Task.sleep(for: .milliseconds(100))

        #expect(next.failure == nil)
        #expect(completionCount == 1)
        #expect(staleResult?.failure?.code == SimulationCoordinator.cancelledCommandCode)
        #expect(coordinator.lastCoordinate?.latitude == 24.1477)
        #expect(coordinator.state == .running(.fixedLocation))
    }

    @Test @MainActor func supersededStopCannotClearOrResurrectTheNextSession() async {
        let lock = NSLock()
        var clearStarted = false
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.superseded-stop"),
            setOperation: { _, _, _, _ in 0 },
            clearOperation: {
                lock.lock()
                clearStarted = true
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.15)
                return 0
            },
            commandTimeout: 1
        )
        let coordinator = SimulationCoordinator(service: service)
        let initial = await coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "初始啟動"
        )
        guard case .success = initial else {
            Issue.record("初始模擬應成功啟動")
            return
        }

        let stopTask = Task { @MainActor in
            await coordinator.stop(operation: "舊停止")
        }
        var didObserveClear = false
        for _ in 0..<20 {
            lock.lock()
            didObserveClear = clearStarted
            lock.unlock()
            if didObserveClear { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(didObserveClear)

        let next = await coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "新啟動"
        )
        let stopped = await stopTask.value

        #expect(stopped.failure?.code == SimulationCoordinator.cancelledCommandCode)
        #expect(next.failure == nil)
        #expect(coordinator.lastCoordinate?.latitude == 24.1477)
        #expect(coordinator.state == .running(.fixedLocation))
    }

    @Test @MainActor func newerUpdateSupersedesOlderUpdateInTheSameSession() async {
        let lock = NSLock()
        var setCallCount = 0
        var firstUpdateStarted = false
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.superseded-update"),
            setOperation: { _, _, _, _ in
                lock.lock()
                setCallCount += 1
                let call = setCallCount
                if call == 2 {
                    firstUpdateStarted = true
                }
                lock.unlock()
                if call == 2 {
                    Thread.sleep(forTimeInterval: 0.15)
                }
                return 0
            },
            clearOperation: { 0 },
            commandTimeout: 1
        )
        let coordinator = SimulationCoordinator(service: service)
        let initial = await coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "初始啟動"
        )
        guard case .success = initial else {
            Issue.record("初始模擬應成功啟動")
            return
        }

        let oldUpdate = Task { @MainActor in
            await coordinator.update(
                coordinate: CLLocationCoordinate2D(latitude: 25.034, longitude: 121.566),
                deviceIP: "10.7.0.1",
                pairingFile: "/tmp/pairing.plist",
                operation: "舊更新"
            )
        }
        var didObserveFirstUpdate = false
        for _ in 0..<20 {
            lock.lock()
            didObserveFirstUpdate = firstUpdateStarted
            lock.unlock()
            if didObserveFirstUpdate { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(didObserveFirstUpdate)

        let latest = await coordinator.update(
            coordinate: CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "新更新"
        )
        let old = await oldUpdate.value

        #expect(old.failure?.code == SimulationCoordinator.cancelledCommandCode)
        #expect(latest.failure == nil)
        #expect(coordinator.lastCoordinate?.latitude == 24.1477)
        #expect(coordinator.state == .running(.fixedLocation))
    }

    @Test @MainActor func freeJoystickCallbackIsRejectedBeforeDeviceCommand() async {
        let lock = NSLock()
        var setCallCount = 0
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.free-joystick"),
            setOperation: { _, _, _, _ in
                lock.lock()
                setCallCount += 1
                lock.unlock()
                return 0
            },
            clearOperation: { 0 }
        )
        let coordinator = SimulationCoordinator(
            service: service,
            isProProvider: { false }
        )
        let initialCoordinate = CLLocationCoordinate2D(latitude: 25, longitude: 121)
        let initial = await coordinator.start(
            mode: .fixedLocation,
            coordinate: initialCoordinate,
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "開始單點"
        )
        guard case .success = initial else {
            Issue.record("初始模擬應成功啟動")
            return
        }

        var receivedResult: Result<Void, LocationSimulationError>?
        coordinator.update(
            coordinate: CLLocationCoordinate2D(latitude: 25.001, longitude: 121.001),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            intent: .joystickMovement,
            operation: "Free 搖桿"
        ) { result in
            receivedResult = result
        }

        lock.lock()
        let calls = setCallCount
        lock.unlock()
        #expect(receivedResult?.failure?.code == SimulationCoordinator.joystickRequiresProCode)
        #expect(calls == 1)
        #expect(coordinator.lastCoordinate?.latitude == initialCoordinate.latitude)
    }

    @Test @MainActor func updateIntentsRespectFreeAndProCapabilities() async {
        let lock = NSLock()
        var setCallCount = 0
        var isPro = false
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.update-intents"),
            setOperation: { _, _, _, _ in
                lock.lock()
                setCallCount += 1
                lock.unlock()
                return 0
            },
            clearOperation: { 0 }
        )
        let coordinator = SimulationCoordinator(
            service: service,
            isProProvider: { isPro }
        )
        let initial = await coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 25, longitude: 121),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "開始單點"
        )
        guard case .success = initial else {
            Issue.record("初始模擬應成功啟動")
            return
        }

        let keepAlive = await coordinator.update(
            coordinate: CLLocationCoordinate2D(latitude: 25.001, longitude: 121.001),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            intent: .fixedKeepAlive,
            operation: "Free 固定定位 heartbeat"
        )
        let singlePoint = await coordinator.update(
            coordinate: CLLocationCoordinate2D(latitude: 25.002, longitude: 121.002),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            intent: .singlePoint,
            operation: "Free 單點定位"
        )
        isPro = true
        let proJoystickCoordinate = CLLocationCoordinate2D(latitude: 25.003, longitude: 121.003)
        let proJoystick = await coordinator.update(
            coordinate: proJoystickCoordinate,
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            intent: .joystickMovement,
            operation: "Pro 搖桿"
        )
        isPro = false
        let downgradedJoystick = await coordinator.update(
            coordinate: CLLocationCoordinate2D(latitude: 25.004, longitude: 121.004),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            intent: .joystickMovement,
            operation: "降級後搖桿"
        )

        lock.lock()
        let calls = setCallCount
        lock.unlock()
        #expect(keepAlive.failure == nil)
        #expect(singlePoint.failure == nil)
        #expect(proJoystick.failure == nil)
        #expect(downgradedJoystick.failure?.code == SimulationCoordinator.joystickRequiresProCode)
        #expect(calls == 4)
        #expect(coordinator.lastCoordinate?.latitude == proJoystickCoordinate.latitude)
    }

    @Test @MainActor func joystickRetryStopsWhenProIsRevokedDuringFirstAttempt() async {
        let entitlement = LockedBoolean(true)
        let lock = NSLock()
        var setCallCount = 0
        var resetCallCount = 0
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.joystick-revocation"),
            setOperation: { _, _, _, _ in
                lock.lock()
                setCallCount += 1
                let call = setCallCount
                lock.unlock()
                if call == 2 {
                    entitlement.set(false)
                    return 3
                }
                return 0
            },
            clearOperation: { 0 },
            resetOperation: {
                lock.lock()
                resetCallCount += 1
                lock.unlock()
            }
        )
        let coordinator = SimulationCoordinator(
            service: service,
            isProProvider: { entitlement.value }
        )
        let initial = await coordinator.start(
            mode: .fixedLocation,
            coordinate: CLLocationCoordinate2D(latitude: 25, longitude: 121),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "開始單點"
        )
        guard case .success = initial else {
            Issue.record("初始模擬應成功啟動")
            return
        }

        let result = await coordinator.update(
            coordinate: CLLocationCoordinate2D(latitude: 25.001, longitude: 121.001),
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            intent: .joystickMovement,
            operation: "撤權中的搖桿"
        )

        lock.lock()
        let calls = setCallCount
        let resets = resetCallCount
        lock.unlock()
        #expect(result.failure?.code == SimulationCoordinator.joystickRequiresProCode)
        #expect(calls == 2)
        #expect(resets == 0)
    }

    @Test func heartbeatCoalescerKeepsOnlyTheLatestPendingCoordinate() {
        var coalescer = SimulationHeartbeatCoalescer()
        let first = CLLocationCoordinate2D(latitude: 25.033, longitude: 121.565)
        let second = CLLocationCoordinate2D(latitude: 25.034, longitude: 121.566)
        let latest = CLLocationCoordinate2D(latitude: 25.035, longitude: 121.567)

        let firstToSend = coalescer.enqueue(first)
        _ = coalescer.enqueue(second)
        _ = coalescer.enqueue(latest)
        let nextToSend = coalescer.complete(success: true)

        #expect(firstToSend?.latitude == first.latitude)
        #expect(nextToSend?.latitude == latest.latitude)
        #expect(nextToSend?.longitude == latest.longitude)
        #expect(coalescer.isInFlight)
        #expect(coalescer.pendingCoordinate == nil)

        _ = coalescer.complete(success: false)
        #expect(!coalescer.isInFlight)
        #expect(coalescer.pendingCoordinate == nil)
    }

    @Test @MainActor func invalidatingUICommandsClearsPendingStateAndRejectsOldTokens() {
        let state = LocationSimulationUIState()
        let simulationToken = state.beginSimulationCommand()
        let joystickToken = state.beginJoystickCommand()
        let heartbeatToken = state.beginBackgroundHeartbeatCommand()
        state.isProcessingSimulation = true
        state.joystickCommandInFlight = true
        state.pendingJoystickCoordinate = CLLocationCoordinate2D(latitude: 25, longitude: 121)
        _ = state.backgroundHeartbeatCoalescer.enqueue(
            CLLocationCoordinate2D(latitude: 25.001, longitude: 121.001)
        )

        state.invalidateSimulationCommands()

        #expect(!state.isCurrentSimulationCommand(simulationToken))
        #expect(!state.isCurrentJoystickCommand(joystickToken))
        #expect(!state.isCurrentBackgroundHeartbeatCommand(heartbeatToken))
        #expect(!state.isProcessingSimulation)
        #expect(!state.joystickCommandInFlight)
        #expect(state.pendingJoystickCoordinate == nil)
        #expect(!state.backgroundHeartbeatCoalescer.isInFlight)
        #expect(state.backgroundHeartbeatCoalescer.pendingCoordinate == nil)
    }

    @Test @MainActor func invalidatingJoystickCommandsPreservesFixedLocationCommands() {
        let state = LocationSimulationUIState()
        let simulationToken = state.beginSimulationCommand()
        let joystickToken = state.beginJoystickCommand()
        let heartbeatToken = state.beginBackgroundHeartbeatCommand()
        state.joystickCommandInFlight = true
        state.pendingJoystickCoordinate = CLLocationCoordinate2D(latitude: 25, longitude: 121)

        state.invalidateJoystickCommands()

        #expect(state.isCurrentSimulationCommand(simulationToken))
        #expect(!state.isCurrentJoystickCommand(joystickToken))
        #expect(state.isCurrentBackgroundHeartbeatCommand(heartbeatToken))
        #expect(!state.joystickCommandInFlight)
        #expect(state.pendingJoystickCoordinate == nil)
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        storage = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
