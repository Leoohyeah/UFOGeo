import CoreLocation
import UIKit

extension Notification.Name {
    static let backgroundLocationHeartbeat = Notification.Name(
        "com.ufogeo.background-location-heartbeat"
    )
}

@MainActor
final class BackgroundLocationManager: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Activity: Hashable {
        case continuousLocation
        case route
        case locationRefreshCycle
    }

    static let shared = BackgroundLocationManager()

    private let locationManager = CLLocationManager()
    private var isRunning = false
    private var activities: Set<Activity> = []
    private var backgroundActivitySession: CLBackgroundActivitySession?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleAppDidEnterBackground() {
        // 背景使用 10 公尺精度，在心跳穩定度與耗電之間取得平衡。
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    @objc private func handleAppWillEnterForeground() {
        // 回前景後恢復高精度
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // 使用者可在系統設定重新開啟定位；保留中的活動應在回到 App
        // 時重新嘗試啟動，不讓先前的拒絕永久卡住背景定位。
        if !activities.isEmpty, !isRunning {
            start()
        }
    }

    func start() {
        guard !isRunning else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            isRunning = true
            backgroundActivitySession = CLBackgroundActivitySession()
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            isRunning = true
            locationManager.requestAlwaysAuthorization()
        case .notDetermined:
            isRunning = true
            // iOS expects the permission flow to progress from When In Use to Always.
            locationManager.requestWhenInUseAuthorization()
        default:
            // Keep activities so a permission change can be retried on the
            // next foreground transition, but do not report the service running.
            isRunning = false
        }
    }

    func stop() {
        isRunning = false
        locationManager.stopUpdatingLocation()
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
    }

    /// App 已沒有任何模擬時，清除所有使用者並立即關閉背景定位。
    func stopAllActivities() {
        activities.removeAll()
        stop()
    }

    func requestAlwaysPermission() {
        if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    func requestStart(for activity: Activity) {
        if activity == .route
            && !PortalyCheckoutService.shared.canUseBackgroundRouteSimulation {
            activities.remove(.route)
            if !shouldRunLocationService {
                stop()
            }
            return
        }

        let inserted = activities.insert(activity).inserted

        if inserted, shouldRunLocationService {
            start()
        }
    }

    func requestStop(for activity: Activity) {
        activities.remove(activity)
        if !shouldRunLocationService {
            stop()
        }
    }

    private var shouldRunLocationService: Bool {
        !activities.isEmpty
    }

    var canDeliverBackgroundHeartbeats: Bool {
        isRunning
            && locationManager.authorizationStatus == .authorizedAlways
            && backgroundActivitySession != nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRunning else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            if backgroundActivitySession == nil {
                backgroundActivitySession = CLBackgroundActivitySession()
            }
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard isRunning, let date = locations.last?.timestamp else { return }
        NotificationCenter.default.post(
            name: .backgroundLocationHeartbeat,
            object: nil,
            userInfo: ["date": date]
        )
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        guard let clError = error as? CLError else { return }
        switch clError.code {
        case .denied:
            // 使用者撤銷定位授權，停止服務避免無限等待。
            stop()
        default:
            // kCLErrorLocationUnknown 等暫時性錯誤不處理，等待下次定位更新。
            break
        }
    }
}
