import Combine
import CoreLocation
import MapKit
import Network
import SwiftUI

enum SharedControlAction: Equatable {
    case settings
    case bookmarks
    case walking
    case returnToRealLocation
    case locationRefreshCycle
    case recenter
    case directLocation
}

enum RouteLaunchCoordinateAction: Equatable {
    case recenterOnly
    case stopAndRecenter
    case stopAfterPendingStartAndRecenter
}

enum FixedLocationLaunchCoordinateAction: Equatable {
    case recenterOnly
    case updateSimulationAndHold
}

enum LaunchCoordinateReturnPolicy {
    static func fixedLocationAction(
        isSimulating: Bool
    ) -> FixedLocationLaunchCoordinateAction {
        isSimulating ? .updateSimulationAndHold : .recenterOnly
    }

    static func routeAction(
        isStarting: Bool,
        isSimulating: Bool,
        isPaused: Bool
    ) -> RouteLaunchCoordinateAction {
        if isStarting {
            return .stopAfterPendingStartAndRecenter
        }
        if isSimulating || isPaused {
            return .stopAndRecenter
        }
        return .recenterOnly
    }
}

struct NativeMapCenterRequest {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let preserveZoom: Bool
    let resumesRouteFollowing: Bool

    init(
        coordinate: CLLocationCoordinate2D,
        preserveZoom: Bool,
        resumesRouteFollowing: Bool = false
    ) {
        self.coordinate = coordinate
        self.preserveZoom = preserveZoom
        self.resumesRouteFollowing = resumesRouteFollowing
    }
}

struct AdaptiveLayoutMetrics {
    let size: CGSize

    private var widthScale: CGFloat {
        min(max(size.width / 430, 0.82), 2.0)
    }

    private var heightScale: CGFloat {
        min(max(size.height / 932, 0.78), 2.0)
    }

    var horizontalPadding: CGFloat { max(10, 12 * widthScale) }
    var searchWidth: CGFloat { min(320 * widthScale, size.width - horizontalPadding * 2) }
    var speedWidth: CGFloat { min(180 * widthScale, size.width * 0.48) }
    var controlButtonSize: CGFloat { min(max(44, 46 * widthScale), 50) }
    var joystickSize: CGFloat { min(max(84, 100 * min(widthScale, heightScale)), 104) }
    var bottomControlInset: CGFloat { min(max(82, 90 * heightScale), 96) }
    /// The bottom simulation cards use the same responsive heights on both tabs.
    /// Keep the active height large enough for the route progress controls while
    /// allowing the location card to reserve the same space for its health row.
    var inactiveSimulationCardHeight: CGFloat {
        min(max(125, 119 * heightScale), 131)
    }

    var activeSimulationCardHeight: CGFloat {
        min(max(155, 164 * heightScale), 163)
    }

    func simulationCardHeight(isActive: Bool) -> CGFloat {
        isActive ? activeSimulationCardHeight : inactiveSimulationCardHeight
    }

    func joystickBottomInset(isSimulationActive: Bool) -> CGFloat {
        bottomControlInset
            + simulationCardHeight(isActive: isSimulationActive)
            + min(max(30, 40 * heightScale), 44)
    }
    var topControlSpacing: CGFloat { min(max(7, 10 * heightScale), 11) }
}

private struct AdaptiveLayoutMetricsKey: EnvironmentKey {
    static let defaultValue = AdaptiveLayoutMetrics(size: CGSize(width: 430, height: 932))
}

extension EnvironmentValues {
    var adaptiveLayout: AdaptiveLayoutMetrics {
        get { self[AdaptiveLayoutMetricsKey.self] }
        set { self[AdaptiveLayoutMetricsKey.self] = newValue }
    }
}

final class SharedLocationMapState: ObservableObject {
    private static let tunnelTestMinInterval: TimeInterval = 3

    static func defaultSimulationRegion(
        centeredAt coordinate: CLLocationCoordinate2D
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 1_500,
            longitudinalMeters: 1_500
        )
    }

    @Published var selectedCoordinate: CLLocationCoordinate2D?
    @Published private(set) var launchCoordinate: CLLocationCoordinate2D?
    @Published var mapPosition: MapCameraPosition = .automatic
    // MKMapView delegate callbacks synchronously refresh these camera caches.
    // They are read on later user actions and do not drive SwiftUI rendering,
    // so publishing them would trigger a view update from inside updateUIView.
    var visibleRegion: MKCoordinateRegion?
    var lastCamera: MapCamera?
    @Published var nativeMapCenterRequest: NativeMapCenterRequest?
    @Published var isSimulationActive = false
    @Published var isSimulationTransitioning = false
    @Published var isMovementActive = false
    @Published var simulationSpeed = min(
        max(UserDefaults.standard.object(forKey: UserDefaults.Keys.lastJoystickSpeed) as? Double ?? 10, 0),
        1000
    )
    @Published var activeTabID = AppFeature.home.id
    @Published var requestedControlAction: SharedControlAction?
    @Published var requestedRouteID: UUID?
    @Published var requestedTabID: String?
    @Published var isLocationRefreshCycleActive = false
    @Published var locationRefreshCountdown: Int?
    @Published var isReturningToRealLocationInProgress = false
    @Published private(set) var isTunnelReachable: Bool?

    private var tunnelConnection: NWConnection?
    private var isTunnelTestInFlight = false
    private var pendingForcedTunnelRetest = false
    private var lastTunnelTestAt: Date = .distantPast

    var isSimulationInteractionLocked: Bool {
        isSimulationActive || isSimulationTransitioning
    }

    var canSwitchTabs: Bool { !isSimulationInteractionLocked }

    /// 保存本次 process 啟動後取得的第一個有效真實座標。
    @discardableResult
    func captureLaunchCoordinateIfNeeded(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard launchCoordinate == nil,
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              CLLocationCoordinate2DIsValid(coordinate) else { return false }
        launchCoordinate = coordinate
        return true
    }

    /// 只更新本地選取座標與地圖中心，不操作定位權限或裝置模擬。
    @discardableResult
    func returnToLaunchLocation() -> CLLocationCoordinate2D? {
        guard let launchCoordinate else { return nil }
        selectedCoordinate = launchCoordinate
        mapPosition = .region(Self.defaultSimulationRegion(centeredAt: launchCoordinate))
        nativeMapCenterRequest = NativeMapCenterRequest(
            coordinate: launchCoordinate,
            preserveZoom: false
        )
        return launchCoordinate
    }

    func testTunnel(force: Bool = false) {
        let now = Date()
        if !force,
           now.timeIntervalSince(lastTunnelTestAt) < Self.tunnelTestMinInterval {
            return
        }
        if isTunnelTestInFlight {
            if force {
                pendingForcedTunnelRetest = true
            }
            return
        }

        isTunnelTestInFlight = true
        lastTunnelTestAt = now
        tunnelConnection?.cancel()
        isTunnelReachable = nil
        let connection = NWConnection(
            host: NWEndpoint.Host(DeviceConnectionContext.targetIPAddress),
            port: 49152,
            using: .tcp
        )
        tunnelConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.tunnelConnection === connection else { return }
                switch state {
                case .ready:
                    self.isTunnelReachable = true
                    connection.cancel()
                    self.finishTunnelTest(using: connection)
                case .failed:
                    self.isTunnelReachable = false
                    connection.cancel()
                    self.finishTunnelTest(using: connection)
                default: break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "com.ufogeo.startup-tunnel"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection,
                  self.tunnelConnection === connection,
                  self.isTunnelReachable == nil else { return }
            self.isTunnelReachable = false
            connection.cancel()
            self.finishTunnelTest(using: connection)
        }
    }

    private func finishTunnelTest(using connection: NWConnection) {
        guard tunnelConnection === connection else { return }
        tunnelConnection = nil
        isTunnelTestInFlight = false

        guard pendingForcedTunnelRetest else { return }
        pendingForcedTunnelRetest = false
        DispatchQueue.main.async { [weak self] in
            self?.testTunnel(force: true)
        }
    }
}
