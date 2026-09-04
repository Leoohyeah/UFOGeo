import UserNotifications

/// 統一管理固定定位與路線兩種模式的背景狀態與通知。
@MainActor
final class BackgroundSimulationManager: ObservableObject {
    static let shared = BackgroundSimulationManager()

    @Published private(set) var currentMode: SimulationMode? = nil
    @Published private(set) var isRoutePaused = false
    @Published private(set) var isRouteManuallyStopped = false
    @Published private(set) var isFixedManuallyStopped = false
    private var lastBackgroundNotificationAt: Date?
    private var lastBackgroundNotificationModeKey: String?

    private init() {}

    /// 標記模式已啟動（固定定位或路線）
    func markSimulationActive(mode: SimulationMode) {
        currentMode = mode
        isRoutePaused = false
        isRouteManuallyStopped = false
        isFixedManuallyStopped = false
        persistActiveFlag(for: mode)
    }

    /// 標記模式已停止
    func markSimulationInactive() {
        currentMode = nil
        isRoutePaused = false
        isRouteManuallyStopped = false
        isFixedManuallyStopped = false
        clearPersistedMode()
    }

    func setRoutePaused(_ paused: Bool) {
        guard currentMode == .route else {
            isRoutePaused = false
            return
        }
        isRoutePaused = paused
    }

    /// 路線已由使用者停止，但暫時保留最後座標供背景心跳與 60 秒重置判斷。
    func markRouteManuallyStoppedHoldingLocation() {
        currentMode = nil
        isRoutePaused = false
        isRouteManuallyStopped = true
        isFixedManuallyStopped = false
        clearPersistedMode()
    }

    /// 定位已由使用者停止，但暫時保留最後座標供背景心跳與 60 秒重置判斷。
    func markFixedManuallyStoppedHoldingLocation() {
        currentMode = nil
        isRoutePaused = false
        isRouteManuallyStopped = false
        isFixedManuallyStopped = true
        clearPersistedMode()
    }

    func notifySimulationActiveIfNeeded(backgroundLocationAvailable: Bool) {
        guard currentMode != nil else { return }
        guard !isRoutePaused else { return }
        if currentMode == .route,
           !PortalyCheckoutService.shared.canUseBackgroundRouteSimulation {
            return
        }
        guard backgroundLocationAvailable else {
            postNotification(
                body: "請回到 App，將定位權限改為「永遠」；目前無法在背景維持模擬。",
                modeKey: "background-unavailable"
            )
            return
        }
        postSimulationActiveNotification()
    }

    private func postSimulationActiveNotification() {
        let body: String
        let modeKey: String
        switch currentMode {
        case .fixedLocation:
            body = "單點定位正在背景維持。"
            modeKey = "fixed"
        case .route:
            body = "路線模擬進行中。"
            modeKey = "route"
        case nil:
            return
        }

        postNotification(body: body, modeKey: modeKey)
    }

    private func postNotification(body: String, modeKey: String) {
        let now = Date()
        if let lastAt = lastBackgroundNotificationAt,
           let lastModeKey = lastBackgroundNotificationModeKey,
           lastModeKey == modeKey,
           now.timeIntervalSince(lastAt) < 2 {
            return
        }
        lastBackgroundNotificationAt = now
        lastBackgroundNotificationModeKey = modeKey

        let content = UNMutableNotificationContent()
        content.title = "UFOGeo"
        content.body = body
        content.sound = nil
        let identifier = "com.ufogeo.simulation-background.\(modeKey).\(Int(now.timeIntervalSince1970 * 1000))"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[BackgroundSimulationManager] notification scheduling failed: \(error.localizedDescription)")
            }
        }
    }

    private func persistActiveFlag(for mode: SimulationMode) {
        let defaults = UserDefaults.standard
        switch mode {
        case .fixedLocation:
            defaults.set(true, forKey: UserDefaults.Keys.fixedSimulationActive)
            clearRoutePersistedMode()
        case .route:
            defaults.set(true, forKey: UserDefaults.Keys.routeSimulationActive)
            clearFixedPersistedMode()
        }
    }

    private func clearPersistedMode() {
        clearFixedPersistedMode()
        clearRoutePersistedMode()
        removeLegacyRestorationData()
    }

    private func clearFixedPersistedMode() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: UserDefaults.Keys.fixedSimulationActive)
    }

    private func clearRoutePersistedMode() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: UserDefaults.Keys.routeSimulationActive)
    }

    private func removeLegacyRestorationData() {
        let defaults = UserDefaults.standard
        [
            "fixedSimulationLat",
            "fixedSimulationLon",
            "routeSimulationID",
            "routeSimulationStartIndex",
            "routeSimulationCurrentIndex",
            "simulationLastActiveAt"
        ].forEach(defaults.removeObject(forKey:))
    }

}
