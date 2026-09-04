import Foundation
import CoreLocation

extension Notification.Name {
    static let locationSimulationDidExpire = Notification.Name(
        "com.ufogeo.location-simulation-did-expire"
    )
}

/// Keeps at most one background location command in flight. If a new
/// heartbeat arrives while the device is busy, only its latest coordinate is
/// retained for the next command.
struct SimulationHeartbeatCoalescer {
    private(set) var isInFlight = false
    private(set) var pendingCoordinate: CLLocationCoordinate2D?

    mutating func enqueue(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D? {
        guard !isInFlight else {
            pendingCoordinate = coordinate
            return nil
        }
        isInFlight = true
        return coordinate
    }

    mutating func complete(success: Bool) -> CLLocationCoordinate2D? {
        guard isInFlight else { return nil }
        isInFlight = false
        guard success, let pendingCoordinate else {
            self.pendingCoordinate = nil
            return nil
        }
        self.pendingCoordinate = nil
        isInFlight = true
        return pendingCoordinate
    }

    mutating func cancel() {
        isInFlight = false
        pendingCoordinate = nil
    }
}

/// 定位模擬 UI 狀態管理
final class LocationSimulationUIState: ObservableObject {
    // MARK: - 模擬控制
    @Published var isSimulating = false
    @Published var isManuallyStopped = false
    @Published var simulationStatus = ""
    @Published var isProcessingSimulation = false

    // MARK: - 警告和提示
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var showCompatibilityCheck = false
    @Published var showInitialPairingPrompt = false
    
    // MARK: - 設定和導航
    @Published var openWalkingSectionInSettings = false
    @Published var returnToSettingsAfterChild = false
    
    // MARK: - 書籤
    @Published var bookmarks: [LocationBookmark] = []
    @Published var showBookmarks = false
    @Published var showSaveBookmark = false
    @Published var newBookmarkName = ""
    @Published var pendingBookmarkOverwrite: LocationBookmark?
    @Published var showBookmarkOverwriteConfirm = false
    
    /// 性能優化：緩存選中的書籤，避免每次渲染都遍歷
    var cachedSelectedBookmark: LocationBookmark?
    
    // MARK: - 路線導入
    @Published var showRouteImporter = false
    
    // MARK: - 配對導入
    @Published var showPairingImporter = false
    @Published var isImportingPairingFile = false
    
    // MARK: - 內部狀態
    @Published var didApplyActualStartCoordinate = false
    @Published var isReturningToCurrentLocation = false
    @Published var requestAlwaysAfterPairingImport = false
    @Published var recenterAfterPairingAuthorization = false
    @Published var didInitializeView = false
    
    // MARK: - 搖桿相關
    @Published var joystickTouchActive = false
    @Published var joystickDirectionLocked = false
    // 以下僅用於內部邏輯判斷，不需要觸發 SwiftUI 重繪
    var joystickCommandInFlight = false
    var pendingJoystickCoordinate: CLLocationCoordinate2D?
    private(set) var simulationCommandGeneration = 0
    private(set) var joystickCommandGeneration = 0
    var lastJoystickUpdateAt: Date = .distantPast
    var joystickHoldStartedAt: Date?
    var joystickHoldAngle: Double = 0
    
    // MARK: - 心跳和通訊
    var lastHeartbeatKeepAliveAt: Date = .distantPast
    private(set) var backgroundHeartbeatCommandGeneration = 0
    var backgroundHeartbeatCoalescer = SimulationHeartbeatCoalescer()

    @discardableResult
    func beginSimulationCommand() -> Int {
        simulationCommandGeneration &+= 1
        return simulationCommandGeneration
    }

    func isCurrentSimulationCommand(_ token: Int) -> Bool {
        simulationCommandGeneration == token
    }

    @discardableResult
    func beginJoystickCommand() -> Int {
        joystickCommandGeneration &+= 1
        return joystickCommandGeneration
    }

    func isCurrentJoystickCommand(_ token: Int) -> Bool {
        joystickCommandGeneration == token
    }

    @discardableResult
    func beginBackgroundHeartbeatCommand() -> Int {
        backgroundHeartbeatCommandGeneration &+= 1
        return backgroundHeartbeatCommandGeneration
    }

    func isCurrentBackgroundHeartbeatCommand(_ token: Int) -> Bool {
        backgroundHeartbeatCommandGeneration == token
    }

    func invalidateJoystickCommands() {
        joystickCommandGeneration &+= 1
        joystickCommandInFlight = false
        pendingJoystickCoordinate = nil
    }

    /// Invalidates all callbacks that belong to the previous simulation
    /// session while leaving the persisted/device location untouched.
    func invalidateSimulationCommands() {
        simulationCommandGeneration &+= 1
        backgroundHeartbeatCommandGeneration &+= 1
        isProcessingSimulation = false
        invalidateJoystickCommands()
        backgroundHeartbeatCoalescer.cancel()
        lastHeartbeatKeepAliveAt = .distantPast
    }
}
