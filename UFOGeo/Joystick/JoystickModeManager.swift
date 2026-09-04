import Foundation
import Combine
import CoreLocation
import UIKit
import UserNotifications

extension Notification.Name {
    static let simulationRoutesDidChange = Notification.Name(
        "com.ufogeo.simulation-routes-did-change"
    )
    static let routeSimulationDidExpire = Notification.Name(
        "com.ufogeo.route-simulation-did-expire"
    )
}

enum PathCompletionMode: String, CaseIterable, Identifiable {
    case returnToStart
    case stopAtLast
    case loop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .returnToStart:
            return "回到起點"
        case .stopAtLast:
            return "停在終點"
        case .loop:
            return "自動循環"
        }
    }
}

struct RouteCompletionNotificationDescriptor: Equatable {
    let title: String
    let body: String

    static func make(
        routeName: String,
        completionMode: PathCompletionMode
    ) -> RouteCompletionNotificationDescriptor? {
        switch completionMode {
        case .returnToStart:
            return RouteCompletionNotificationDescriptor(
                title: "路線模擬已回到起點",
                body: "「\(routeName)」已完成路線並回到起點"
            )
        case .stopAtLast:
            return RouteCompletionNotificationDescriptor(
                title: "路線模擬已達終點",
                body: "「\(routeName)」已完成路線"
            )
        case .loop:
            return nil
        }
    }
}

enum RoutePlanningMode: String, CaseIterable, Identifiable {
    case direct
    case orbitEachWaypoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct:
            return "直線路徑"
        case .orbitEachWaypoint:
            return "跳點繞圈"
        }
    }
}

struct PathPoint: Identifiable, Codable {
    var id: UUID = UUID()
    var latitude: Double
    var longitude: Double
    var order: Int
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    init(coordinate: CLLocationCoordinate2D, order: Int) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.order = order
    }
}

struct SimulationRoute: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var points: [PathPoint]
    var createdDate: Date
    var isFavorite: Bool = false
    
    var isValid: Bool {
        points.count >= 2
    }
}

/// 未收藏路線屬於目前 session。它們在 process 仍存活時可用，
/// 但下一次 process launch 會被清理。
enum SimulationRouteLaunchCleanupPolicy {
    static func routesToKeepOnNewProcess(_ routes: [SimulationRoute]) -> [SimulationRoute] {
        routes.filter(\.isFavorite)
    }
}

@MainActor
class JoystickModeManager: ObservableObject {
    private static let orbitRadiusMetersMax = 39
    private static let simulationTickInterval: TimeInterval = 0.2
    private static let completionModeKey = UserDefaults.Keys.routeCompletionMode
    private static let routePlanningModeKey = UserDefaults.Keys.routePlanningMode
    private static let orbitRadiusMetersKey = UserDefaults.Keys.routeOrbitRadiusMeters

    private let routeDefaults: UserDefaults

    static func metersPerSecond(forKilometersPerHour speed: Double) -> Double {
        max(0, speed) / 3.6
    }
    @Published var routes: [SimulationRoute] = []
    @Published var selectedRoute: SimulationRoute?
    @Published var isSimulating: Bool = false
    @Published var isPaused: Bool = false
    @Published private(set) var isRouteCompleted: Bool = false
    @Published var simulationSpeed: Double = 50 {
        didSet {
            healthCoordinator.updateRouteSpeed(speedKilometersPerHour: simulationSpeed)
        }
    }
    @Published var simulationStartIndex: Int = 0
    @Published var currentRouteIndex: Int = 0
    @Published var simulationProgress: Double = 0.0
    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var completionMode: PathCompletionMode = .stopAtLast {
        didSet {
            UserDefaults.standard.set(completionMode.rawValue, forKey: Self.completionModeKey)
        }
    }
    @Published var routePlanningMode: RoutePlanningMode = .direct {
        didSet {
            UserDefaults.standard.set(routePlanningMode.rawValue, forKey: Self.routePlanningModeKey)
        }
    }
    @Published var orbitRadiusMeters: Int = 30 {
        didSet {
            let clamped = min(max(1, orbitRadiusMeters), Self.orbitRadiusMetersMax)
            if clamped != orbitRadiusMeters {
                orbitRadiusMeters = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.orbitRadiusMetersKey)
        }
    }
    private var simulationTimer: Timer?
    private var routeEngine: RouteSimulationEngine?
    private var routeState: RouteSimulationState?
    private var activeCompletionMode: PathCompletionMode?
    private var lastSimulationUpdateDate: Date?
    private let healthCoordinator = HealthWalkingCoordinator.shared
    
    init(defaults: UserDefaults = .standard) {
        routeDefaults = defaults
        if let raw = UserDefaults.standard.string(forKey: Self.completionModeKey) {
            if let mode = PathCompletionMode(rawValue: raw) {
                completionMode = mode
            } else if raw == "orbitEachWaypoint" {
                // 舊版把每點繞圈存在 completionMode，這裡轉到新路徑規劃設定。
                completionMode = .stopAtLast
                routePlanningMode = .orbitEachWaypoint
            }
        }
        if let raw = UserDefaults.standard.string(forKey: Self.routePlanningModeKey),
           let mode = RoutePlanningMode(rawValue: raw) {
            routePlanningMode = mode
        }
        if UserDefaults.standard.object(forKey: Self.orbitRadiusMetersKey) == nil {
            orbitRadiusMeters = 30
        } else {
            orbitRadiusMeters = min(
                max(UserDefaults.standard.integer(forKey: Self.orbitRadiusMetersKey), 1),
                Self.orbitRadiusMetersMax
            )
        }
        loadRoutes()
    }

    /// Performs the cleanup for one explicit new-process launch.  The app
    /// bootstrap calls this once; runtime manager creation and route reloads
    /// intentionally never call it.
    static func performRouteLaunchCleanup(defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: UserDefaults.Keys.savedSimulationRoutes),
              let decoded = try? JSONDecoder().decode([SimulationRoute].self, from: data) else {
            return
        }

        let cleaned = SimulationRouteLaunchCleanupPolicy.routesToKeepOnNewProcess(decoded)
        guard cleaned.count != decoded.count,
              let encoded = try? JSONEncoder().encode(cleaned) else {
            return
        }
        defaults.set(encoded, forKey: UserDefaults.Keys.savedSimulationRoutes)
        NotificationCenter.default.post(name: .simulationRoutesDidChange, object: nil)
    }

    func reloadRoutes() {
        loadRoutes()
    }
    
    
    func addPathPoint(_ coordinate: CLLocationCoordinate2D, to route: inout SimulationRoute) {
        let newPoint = PathPoint(coordinate: coordinate, order: route.points.count)
        route.points.append(newPoint)
    }
    
    func saveRoute(_ route: SimulationRoute) {
        if let index = routes.firstIndex(where: { $0.id == route.id }) {
            routes[index] = route
        } else {
            routes.append(route)
        }
        persistRoutes()
    }
    
    func createNewRoute(name: String = "新路線") -> SimulationRoute {
        return SimulationRoute(name: name, points: [], createdDate: Date())
    }
    
    func deleteRoute(_ route: SimulationRoute) {
        routes.removeAll { $0.id == route.id }
        if selectedRoute?.id == route.id {
            selectedRoute = nil
        }
        persistRoutes()
    }
    
    func toggleFavorite(_ route: SimulationRoute) {
        if let index = routes.firstIndex(where: { $0.id == route.id }) {
            routes[index].isFavorite.toggle()
            persistRoutes()
        }
    }
    
    var favoriteRoutes: [SimulationRoute] {
        routes.filter { $0.isFavorite }
    }

    func reorderFavoriteRoutes(from source: IndexSet, to destination: Int) {
        var reorderedFavorites = favoriteRoutes
        reorderedFavorites.move(fromOffsets: source, toOffset: destination)

        var favoriteIndex = 0
        for index in routes.indices where routes[index].isFavorite {
            routes[index] = reorderedFavorites[favoriteIndex]
            favoriteIndex += 1
        }
        persistRoutes()
    }
    
    
    func startPathSimulation(route: SimulationRoute, speed: Double, startIndex: Int = 0) {
        guard route.isValid else { return }

        let clampedStartIndex = min(max(startIndex, 0), route.points.count - 1)
        guard let engine = RouteSimulationEngine(
            coordinates: route.points.map(\.coordinate),
            startIndex: clampedStartIndex,
            completionMode: completionMode,
            planningMode: routePlanningMode,
            orbitRadiusMeters: Double(orbitRadiusMeters)
        ) else { return }

        selectedRoute = route
        simulationStartIndex = clampedStartIndex
        currentRouteIndex = clampedStartIndex
        isSimulating = true
        isPaused = false
        isRouteCompleted = false
        simulationSpeed = speed
        simulationProgress = 0.0
        currentLocation = route.points[clampedStartIndex].coordinate
        routeEngine = engine
        routeState = engine.initialState()
        activeCompletionMode = completionMode
        lastSimulationUpdateDate = Date()
        healthCoordinator.startRouteSimulation(speedKilometersPerHour: speed)
        
        startSimulationTimer(speed: speed)
    }
    
    func stopPathSimulation() {
        isSimulating = false
        isPaused = false
        isRouteCompleted = false
        simulationTimer?.invalidate()
        simulationTimer = nil
        lastSimulationUpdateDate = nil
        routeEngine = nil
        routeState = nil
        activeCompletionMode = nil
        selectedRoute = nil
        healthCoordinator.stopRoute()
    }

    /// 停止路線移動，但保留路線與當下座標供背景心跳固定定位。
    func finishPathSimulationHoldingLocation() {
        isRouteCompleted = true
        isPaused = true
        isSimulating = false
        simulationTimer?.invalidate()
        simulationTimer = nil
        lastSimulationUpdateDate = nil
        healthCoordinator.stopRoute()
    }
    
    func pausePathSimulation() {
        isRouteCompleted = false
        isPaused = true
        isSimulating = false
        simulationTimer?.invalidate()
        simulationTimer = nil
        lastSimulationUpdateDate = nil
        healthCoordinator.pauseRoute()
    }
    
    func resumePathSimulation(speed: Double) {
        if selectedRoute != nil, !isRouteCompleted {
            simulationSpeed = speed
            isSimulating = true
            isPaused = false
            lastSimulationUpdateDate = Date()
            healthCoordinator.resumeRoute(speedKilometersPerHour: speed)
            startSimulationTimer()
        }
    }

    func jumpToPoint(index: Int, resetStartPoint: Bool = true) {
        guard let route = selectedRoute, route.points.indices.contains(index) else { return }

        currentRouteIndex = index
        simulationProgress = 0.0
        currentLocation = route.points[index].coordinate

        if resetStartPoint {
            simulationStartIndex = index
        }
        routeEngine = RouteSimulationEngine(
            coordinates: route.points.map(\.coordinate),
            startIndex: simulationStartIndex,
            completionMode: completionMode,
            planningMode: routePlanningMode,
            orbitRadiusMeters: Double(orbitRadiusMeters)
        )
        routeState = RouteSimulationState(
            pointIndex: index,
            segmentProgress: 0,
            coordinate: route.points[index].coordinate
        )
    }
    
    private func startSimulationTimer(speed: Double) {
        simulationSpeed = speed
        startSimulationTimer()
    }

    private func startSimulationTimer() {
        simulationTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.simulationTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateSimulationProgress(at: Date())
            }
        }
        simulationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func advanceForBackgroundHeartbeat(at date: Date = Date()) {
        if isSimulating {
            updateSimulationProgress(at: date)
        } else {
            healthCoordinator.advanceForBackgroundHeartbeat(at: date)
        }
    }

    private func updateSimulationProgress(at date: Date) {
        guard let route = selectedRoute, route.isValid, isSimulating else { return }

        guard let previousSimulationUpdateDate = lastSimulationUpdateDate else {
            self.lastSimulationUpdateDate = date
            return
        }
        guard date >= previousSimulationUpdateDate else { return }
        let elapsed = min(max(date.timeIntervalSince(previousSimulationUpdateDate), 0), 86_400)
        self.lastSimulationUpdateDate = date
        guard elapsed > 0 else { return }

        healthCoordinator.advanceForBackgroundHeartbeat(at: date)

        guard let routeEngine, let routeState else {
            stopPathSimulation()
            return
        }

        let distance = Self.metersPerSecond(forKilometersPerHour: simulationSpeed) * elapsed
        switch routeEngine.advance(state: routeState, distanceMeters: distance) {
        case .advanced(let state):
            applyRouteState(state)
        case .completed(let state):
            applyRouteState(state)
            recordCompletedRoute(route, at: state.coordinate)
            finishPathSimulationHoldingLocation()
        }
    }

    private func applyRouteState(_ state: RouteSimulationState) {
        routeState = state
        currentRouteIndex = state.pointIndex
        simulationProgress = state.segmentProgress
        currentLocation = state.coordinate
    }

    private func recordCompletedRoute(_ route: SimulationRoute, at coordinate: CLLocationCoordinate2D) {
        LocationHistoryStore.add(
            kind: .routeEnd,
            coordinate: coordinate,
            routeName: route.name
        )
        postRouteCompletionNotificationIfNeeded(
            routeName: route.name,
            completionMode: activeCompletionMode ?? completionMode
        )
    }

    private func postRouteCompletionNotificationIfNeeded(
        routeName: String,
        completionMode: PathCompletionMode
    ) {
        guard UIApplication.shared.applicationState != .active,
              let descriptor = RouteCompletionNotificationDescriptor.make(
                routeName: routeName,
                completionMode: completionMode
              ) else { return }
        let content = UNMutableNotificationContent()
        content.title = descriptor.title
        content.body = descriptor.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "com.ufogeo.route-completed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func startStandaloneWalkingSession() {
        // Fixed-location walking lasts for the whole simulation session; the
        // joystick only changes the simulated coordinate and movement speed.
        healthCoordinator.prepareFixedSimulation()
    }

    func stopStandaloneWalkingSession() {
        healthCoordinator.stopFixedSimulation()
    }

    private func persistRoutes() {
        if let encoded = try? JSONEncoder().encode(routes) {
            routeDefaults.set(encoded, forKey: UserDefaults.Keys.savedSimulationRoutes)
            NotificationCenter.default.post(name: .simulationRoutesDidChange, object: nil)
        }
    }
    
    private func loadRoutes() {
        if let data = routeDefaults.data(forKey: UserDefaults.Keys.savedSimulationRoutes),
           let decoded = try? JSONDecoder().decode([SimulationRoute].self, from: data) {
            routes = decoded
        }
    }
}
