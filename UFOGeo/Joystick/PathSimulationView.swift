import SwiftUI
import MapKit
import UniformTypeIdentifiers
import UIKit

enum RouteHistorySelectionPolicy {
    static func shouldPauseAndPush(isSimulating: Bool, isPaused: Bool) -> Bool {
        isSimulating || isPaused
    }
}

struct PathSimulationView: View {
    @EnvironmentObject private var sharedMapState: SharedLocationMapState
    @Environment(\.adaptiveLayout) private var layout
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(UserDefaults.Keys.lastJoystickSpeed) private var simulationSpeed: Double = 10
    @AppStorage(UserDefaults.Keys.routeCompletionMode) private var completionModeRaw: String = PathCompletionMode.stopAtLast.rawValue
    @AppStorage(UserDefaults.Keys.routePlanningMode) private var routePlanningModeRaw: String = RoutePlanningMode.direct.rawValue
    @AppStorage(UserDefaults.Keys.routeOrbitRadiusMeters) private var routeOrbitRadiusMeters: Int = 30
    @StateObject private var modeManager = JoystickModeManager()
    @StateObject private var portaly = PortalyCheckoutService.shared
    @ObservedObject private var healthCoordinator = HealthWalkingCoordinator.shared
    @StateObject private var currentLocationProvider = CurrentLocationProvider()
    @State private var isReturningToCurrentLocation = false
    @State private var recenterAfterPairingAuthorization = false
    @State private var showCoordinatePaste = false
    @State private var showPairingImporter = false
    @State private var showSettings = false
    @State private var showUnifiedBookmarks = false
    @State private var openWalkingSectionInSettings = false
    @State private var returnToSettingsAfterChild = false
    @State private var showAlert = false
    @State private var alertTitle = "路線提示"
    @State private var alertMessage = ""
    @State private var inlineEditingRoute: SimulationRoute?
    @State private var selectedInlinePointID: UUID?
    @State private var pendingFirstRoutePoint: CLLocationCoordinate2D?
    @State private var previewStartCoordinate: CLLocationCoordinate2D?
    @State private var startPointByRoute: [UUID: Int] = [:]
    @State private var selectedRouteID: UUID?
    @State private var showDiscardInlineEditConfirm = false
    @State private var pendingInlineRouteOverwrite: SimulationRoute?
    @State private var showInlineRouteOverwriteConfirm = false
    @State private var showInlineCoordinatePaste = false
    @State private var inlineCoordinateText = ""
    @State private var isStartingRoute = false
    @State private var routeStartGeneration = 0
    @State private var shouldReturnToLaunchAfterRouteStart = false
    @State private var lastRoutePushAt: Date = .distantPast
    @State private var routeLocationCommandInFlightGeneration: Int?
    @State private var routeLocationCommandGeneration = 0
    @State private var pendingStoppedRouteCoordinate: CLLocationCoordinate2D?
    @State private var pendingRouteHistoryCoordinate: CLLocationCoordinate2D?
    @State private var isReturningStoppedRouteToLaunch = false
    @State private var stableRouteHeading: Double = 0
    @State private var previousRouteLocation: CLLocationCoordinate2D?
    @State private var routePausedForFreeBackground = false
    @State private var shouldPresentFreeBackgroundPauseAlert = false
    @StateObject private var backgroundSimulationManager = BackgroundSimulationManager.shared

    @State private var pairingExists: Bool = false

    private var selectedRoute: SimulationRoute? {
        if let id = selectedRouteID,
           let route = modeManager.routes.first(where: { $0.id == id }) {
            return route
        }
        return nil
    }

    private var routeIDs: [UUID] {
        modeManager.routes.map { $0.id }
    }

    private var isProUser: Bool {
        portaly.isPro
    }

    private var isRouteInteractionLocked: Bool {
        sharedMapState.isSimulationInteractionLocked
    }

    private var isRouteLocationCommandInFlight: Bool {
        routeLocationCommandInFlightGeneration != nil
    }

    private var completionModeSummary: String {
        if modeManager.routePlanningMode == .orbitEachWaypoint {
            return "跳點繞圈 · \(modeManager.completionMode.title) · 半徑\(max(modeManager.orbitRadiusMeters, 1))m"
        }
        return "直線路徑 · \(modeManager.completionMode.title)"
    }

    var body: some View {
        observedContent
    }

    private var mapPosition: MapCameraPosition {
        get { sharedMapState.mapPosition }
        nonmutating set { sharedMapState.mapPosition = newValue }
    }

    private var rootContent: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            mapPreview

            if let runningRoute = modeManager.selectedRoute,
               modeManager.isSimulating || modeManager.isPaused {
                SimulationProgressView(
                    modeManager: modeManager,
                    healthCoordinator: healthCoordinator,
                    route: runningRoute,
                    speed: $simulationSpeed,
                    onStop: { stopRouteSimulationNow() }
                )
                .padding(16)
                .frame(
                    height: layout.simulationCardHeight(isActive: true),
                    alignment: .bottom
                )
                .panelStyle(cornerRadius: 18)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.bottom, layout.bottomControlInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

        }
    }

    private var presentationContent: some View {
        rootContent
        .navigationTitle("路線")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(
            isPresented: $showCoordinatePaste,
            onDismiss: { reopenSettingsIfNeeded() },
            content: {
            CoordinateToRouteView(
                modeManager: modeManager,
                onRouteImported: { routeID in
                    sharedMapState.requestedRouteID = routeID
                }
            )
            }
        )
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: PairingFileStore.supportedContentTypes
        ) { result in
            importPairingFile(result)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                reopenSettingsIfNeeded()
            }
        }
        .sheet(isPresented: $showSettings) {
            CompatibilityCheckView(
                onImportPairing: {
                    returnToSettingsAfterChild = true
                    showPairingImporter = true
                },
                onImportCoordinates: {
                    returnToSettingsAfterChild = true
                    showCoordinatePaste = true
                },
                onOpenSavedItems: {
                    returnToSettingsAfterChild = true
                    showUnifiedBookmarks = true
                },
                savedItemsTitle: "定位與路線收藏",
                initialScrollTarget: openWalkingSectionInSettings ? .walkingHealth : nil
            )
        }
        .sheet(isPresented: $showUnifiedBookmarks, onDismiss: { reopenSettingsIfNeeded() }) {
            UnifiedBookmarksView(
                onSelectHistory: { coordinate in
                    handleRouteHistorySelection(coordinate)
                }
            )
        }
        .sheet(isPresented: $showInlineCoordinatePaste) {
            inlineCoordinatePasteSheet
        }
    }

    private var dialogContent: some View {
        presentationContent
        .alert(alertTitle, isPresented: $showAlert) {
            Button("確定", role: .cancel) {
                alertTitle = "路線提示"
            }
        } message: {
            Text(alertMessage)
        }
        .alert("設為路線起點？", isPresented: Binding(
            get: { pendingFirstRoutePoint != nil },
            set: { if !$0 { pendingFirstRoutePoint = nil } }
        )) {
            Button("設為起點") { confirmFirstRoutePoint() }
            Button("取消", role: .cancel) { pendingFirstRoutePoint = nil }
        } message: {
            Text("此座標將成為路線的第 1 個路點。")
        }
    }

    // 拆成三層 computed property 避免 Swift 型別推導逾時（expression too complex）
    private var observedContent: some View {
        locationObservedContent
            .onChange(of: modeManager.isSimulating) { _, _ in
                sharedMapState.isSimulationActive = modeManager.isSimulating || modeManager.isPaused
                sharedMapState.isMovementActive = modeManager.isSimulating && simulationSpeed > 0
                if !modeManager.isSimulating,
                   !modeManager.isPaused,
                   !isStartingRoute,
                   !isReturningStoppedRouteToLaunch {
                    BackgroundLocationManager.shared.requestStop(for: .route)
                    backgroundSimulationManager.markSimulationInactive()
                }
            }
            .onChange(of: modeManager.isPaused) { _, _ in
                sharedMapState.isSimulationActive = modeManager.isSimulating || modeManager.isPaused
                sharedMapState.isMovementActive = modeManager.isSimulating && simulationSpeed > 0
                if modeManager.isPaused {
                    backgroundSimulationManager.setRoutePaused(true)
                    if isProUser {
                        // Pro 暫停或完成後保留心跳，只重送同一座標固定定位。
                        BackgroundLocationManager.shared.requestStart(for: .route)
                    } else {
                        BackgroundLocationManager.shared.requestStop(for: .route)
                    }
                } else if modeManager.isSimulating {
                    routePausedForFreeBackground = false
                    backgroundSimulationManager.setRoutePaused(false)
                    recenterMapOnSimulatedLocation()
                    if isProUser {
                        BackgroundLocationManager.shared.requestStart(for: .route)
                    } else {
                        BackgroundLocationManager.shared.requestStop(for: .route)
                    }
                } else {
                    routePausedForFreeBackground = false
                }
            }
            .onChange(of: simulationSpeed) { _, newSpeed in
                modeManager.simulationSpeed = min(max(newSpeed, 0), 1000)
            }
            .onChange(of: isProUser) { _, isPro in
                guard !isPro else { return }
                BackgroundLocationManager.shared.requestStop(for: .route)
                pauseFreeRouteForBackgroundIfNeeded()
            }
            .onChange(of: selectedRouteID) { _, newID in
                guard !isRouteInteractionLocked,
                      !modeManager.isSimulating,
                      !modeManager.isPaused else { return }
                guard let newID,
                      let route = modeManager.routes.first(where: { $0.id == newID }),
                      let firstPoint = route.points.first?.coordinate else { return }
                previewStartCoordinate = firstPoint
                sharedMapState.selectedCoordinate = firstPoint
                centerMapOnRoutePoint(firstPoint)
            }
            .onChange(of: routeIDs) { _, _ in
                guard !isRouteInteractionLocked else { return }
                if modeManager.routes.isEmpty {
                    selectedRouteID = nil
                } else if let id = selectedRouteID,
                          !modeManager.routes.contains(where: { $0.id == id }) {
                    selectedRouteID = nil
                }
            }
    }

    private var locationObservedContent: some View {
        lifecycleObservedContent
            .onReceive(modeManager.$currentLocation) { newLocation in
                updateStableRouteHeading(newLocation)
                if modeManager.isSimulating, let newLocation = newLocation {
                    sharedMapState.selectedCoordinate = newLocation
                }
                pushRouteLocationUpdateIfNeeded(newLocation)
            }
            .onReceive(NotificationCenter.default.publisher(for: .backgroundLocationHeartbeat)) { notification in
                guard scenePhase != .active,
                      isProUser,
                      !routePausedForFreeBackground else { return }
                let date = notification.userInfo?["date"] as? Date ?? Date()
                modeManager.advanceForBackgroundHeartbeat(at: date)
                pushRouteLocationUpdateIfNeeded(modeManager.currentLocation)
            }
            .onReceive(currentLocationProvider.$currentCoordinate) { coordinate in
                guard isReturningToCurrentLocation,
                      let coordinate = coordinate else { return }
                isReturningToCurrentLocation = false
                sharedMapState.isReturningToRealLocationInProgress = false
                if currentLocationProvider.authorizationStatus == .authorizedAlways {
                    recenterAfterPairingAuthorization = false
                }
                sharedMapState.selectedCoordinate = coordinate
                previewStartCoordinate = coordinate
                modeManager.currentLocation = coordinate
                mapPosition = .region(
                    SharedLocationMapState.defaultSimulationRegion(centeredAt: coordinate)
                )
                SharedNativeMapStore.shared.center(at: coordinate, preserveZoom: false)
                requestAlwaysPermissionAfterPairingIfNeeded()
            }
            .onReceive(currentLocationProvider.$authorizationStatus) { status in
                if isReturningToCurrentLocation,
                   status == .denied || status == .restricted {
                    isReturningToCurrentLocation = false
                    sharedMapState.isReturningToRealLocationInProgress = false
                }
                guard recenterAfterPairingAuthorization else { return }
                switch status {
                case .authorizedAlways:
                    recenterAfterPairingAuthorization = false
                    isReturningToCurrentLocation = true
                    currentLocationProvider.requestCurrentLocation(allowCachedLocation: false)
                case .denied, .restricted:
                    recenterAfterPairingAuthorization = false
                default:
                    break
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    refreshPairingExists()
                    if shouldPresentFreeBackgroundPauseAlert {
                        shouldPresentFreeBackgroundPauseAlert = false
                        alertTitle = "路線已暫停"
                        alertMessage = "Free 僅支援前景路線，按播放可繼續。"
                        showAlert = true
                    }
                case .background:
                    pauseFreeRouteForBackgroundIfNeeded()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .onReceive(sharedMapState.$requestedControlAction) { action in
                handleSharedControlAction(action)
            }
            .onReceive(sharedMapState.$requestedRouteID) { routeID in
                applyRequestedRoute(routeID)
            }
    }

    private var lifecycleObservedContent: some View {
        dialogContent
            .onAppear {
                applyStoredRouteSettings()
                refreshPairingExists()
                modeManager.reloadRoutes()
                positionRouteMapForEntryIfActive()
            }
            .onChange(of: completionModeRaw) { _, value in
                modeManager.completionMode = PathCompletionMode(rawValue: value) ?? .stopAtLast
            }
            .onChange(of: routePlanningModeRaw) { _, value in
                if let planning = RoutePlanningMode(rawValue: value) {
                    modeManager.routePlanningMode = planning
                }
            }
            .onChange(of: routeOrbitRadiusMeters) { _, value in
                modeManager.orbitRadiusMeters = min(max(value, 1), 39)
            }
            .onReceive(sharedMapState.$activeTabID) { activeTabID in
                guard activeTabID == AppFeature.pathSimulation.id else { return }
                positionRouteMapForEntryIfActive()
            }
            .onReceive(NotificationCenter.default.publisher(for: .simulationRoutesDidChange)) { _ in
                guard !isRouteInteractionLocked else { return }
                let previousSelection = selectedRouteID
                modeManager.reloadRoutes()
                if let previousSelection,
                   modeManager.routes.contains(where: { $0.id == previousSelection }) {
                    selectedRouteID = previousSelection
                } else {
                    selectedRouteID = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .routeSimulationDidExpire)) { _ in
                routeStartGeneration &+= 1
                routeLocationCommandGeneration &+= 1
                routeLocationCommandInFlightGeneration = nil
                pendingStoppedRouteCoordinate = nil
                pendingRouteHistoryCoordinate = nil
                isReturningStoppedRouteToLaunch = false
                isStartingRoute = false
                SimulationCoordinator.shared.invalidatePendingCommands()
                SimulationCoordinator.shared.allowNextModeSwitchWhileHoldingLocation()
                modeManager.stopPathSimulation()
                sharedMapState.isSimulationTransitioning = false
                sharedMapState.isSimulationActive = false
                sharedMapState.isMovementActive = false
                BackgroundLocationManager.shared.requestStop(for: .route)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pairingFileDidChange)) { _ in
                refreshPairingExists()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            ) { _ in
                refreshPairingExists()
                guard isProUser,
                      !routePausedForFreeBackground else { return }
                modeManager.advanceForBackgroundHeartbeat()
            }
            .onDisappear {
                if isStartingRoute {
                    routeStartGeneration &+= 1
                    isStartingRoute = false
                    SimulationCoordinator.shared.invalidatePendingCommands()
                }
                routeLocationCommandGeneration &+= 1
                routeLocationCommandInFlightGeneration = nil
                pendingStoppedRouteCoordinate = nil
                pendingRouteHistoryCoordinate = nil
                isReturningStoppedRouteToLaunch = false
                if !sharedMapState.isSimulationActive {
                    sharedMapState.isSimulationTransitioning = false
                }
            }
    }

    private var mapPreview: some View {
        ZStack(alignment: .top) {
            RouteEditingMapView(
                route: inlineRouteBinding,
                selectedPointID: $selectedInlinePointID,
                sharedMapState: sharedMapState,
                isEditing: inlineEditingRoute != nil
                    && !modeManager.isSimulating
                    && !modeManager.isPaused
                    && !isRouteInteractionLocked,
                isSimulationActive: modeManager.isSimulating,
                simulatedCoordinate: routeMarkerCoordinate,
                simulatedHeading: stableRouteHeading,
                isSimulationMoving: modeManager.isSimulating && simulationSpeed > 0,
                onMapTap: { coordinate in handleRouteMapTap(coordinate) },
                routeID: inlineEditingRoute?.id ?? selectedRouteID
            )
            .ignoresSafeArea()

            if !modeManager.isSimulating && !modeManager.isPaused {
                controlPanel
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.bottom, layout.bottomControlInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private var inlineRouteBinding: Binding<SimulationRoute> {
        Binding(
            get: {
                inlineEditingRoute
                    ?? selectedRoute
                    ?? modeManager.createNewRoute(name: "新路線")
            },
            set: { inlineEditingRoute = $0 }
        )
    }

    private func handleSharedControlAction(_ action: SharedControlAction?) {
        guard sharedMapState.activeTabID == AppFeature.pathSimulation.id,
              let action = action else { return }
        sharedMapState.requestedControlAction = nil
        switch action {
        case .settings:
            openWalkingSectionInSettings = false
            showSettings = true
        case .bookmarks:
            showUnifiedBookmarks = true
        case .walking:
            openWalkingSectionInSettings = true
            showSettings = true
        case .returnToRealLocation:
            returnToLaunchLocation()
        case .locationRefreshCycle:
            break
        case .recenter:
            recenterMapOnSimulatedLocation()
        case .directLocation:
            // 搜尋不可改變正在執行的路線進度或座標。
            break
        }
    }

    private var routeMarkerCoordinate: CLLocationCoordinate2D? {
        if modeManager.isSimulating || modeManager.isPaused {
            // 模擬中或暫停：優先回到路線當前位置
            return modeManager.currentLocation
                ?? previewStartCoordinate
                ?? sharedMapState.selectedCoordinate
        }
        // 未模擬（含已選路線未啟動、路線停止）：
        // selectedCoordinate 選路線時被設為起點，去定位頁點新點後變成新點，
        // 直接以它為準即可同時滿足兩種情境。
        return sharedMapState.selectedCoordinate
            ?? previewStartCoordinate
            ?? modeManager.currentLocation
    }

    private func applyRequestedRoute(_ routeID: UUID?) {
        guard let routeID = routeID else { return }
        guard !isRouteInteractionLocked else {
            sharedMapState.requestedRouteID = nil
            return
        }
        modeManager.reloadRoutes()
        guard let route = modeManager.routes.first(where: { $0.id == routeID }) else {
            sharedMapState.requestedRouteID = nil
            return
        }
        selectedRouteID = route.id
        inlineEditingRoute = nil
        selectedInlinePointID = nil
        startPointByRoute[route.id] = 0
        if let coordinate = route.points.first?.coordinate {
            previewStartCoordinate = coordinate
            sharedMapState.selectedCoordinate = coordinate
            centerMapOnRoutePoint(coordinate)
        }
        sharedMapState.requestedRouteID = nil
    }

    private func positionRouteMapForEntryIfActive() {
        guard sharedMapState.activeTabID == AppFeature.pathSimulation.id else { return }

        if let coordinate = routeMarkerCoordinate {
            centerMapOnRoutePoint(coordinate)
            return
        }

        if let coordinate = displayedRoute?.points.first?.coordinate {
            previewStartCoordinate = coordinate
            sharedMapState.selectedCoordinate = coordinate
            centerMapOnRoutePoint(coordinate)
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 14) {
            if !pairingExists {
                startupGuidePanel
            }
            routeModePanel
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(
            height: inlineEditingRoute == nil
                ? layout.simulationCardHeight(isActive: false)
                : nil,
            alignment: .bottom
        )
        .panelStyle(cornerRadius: 18)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }

    private var startupGuidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checklist")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text("首次使用導引")
                        .font(.subheadline.weight(.semibold))
                    Text("請先從設定手動匯入此 iPhone 的配對文件；完成前這段提醒會持續保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Label("Free 可在 App 前景執行；Pro 可在背景繼續", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
    }

    private var routeModePanel: some View {
        VStack(spacing: 14) {
            if inlineEditingRoute != nil {
                inlineRouteEditorPanel
            } else if let route = selectedRoute {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: route.isValid ? "point.topleft.down.to.point.bottomright.curvepath" : "exclamationmark.triangle.fill")
                        .foregroundStyle(route.isValid ? Color.accentColor : Color(.systemOrange))
                        .frame(width: 22)

                    Menu {
                        if !route.points.isEmpty {
                            Divider()
                            ForEach(0..<route.points.count, id: \.self) { index in
                                Button("從第 \(index + 1) 點開始") {
                                    selectRouteStartPoint(route, index: index)
                                }
                            }
                        }
                        Divider()
                        Button("編輯路線", systemImage: "pencil") {
                            beginInlineRouteEditing(route)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(route.points.count) 個路點 · \(completionModeSummary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()

                    HStack(spacing: 0) {
                        PanelActionIconButton(systemName: "pencil") {
                            guard !isRouteInteractionLocked else { return }
                            withAnimation(AnimationPreferences.slow) {
                                beginInlineRouteEditing(route)
                            }
                        }
                        .accessibilityLabel("在啟動卡片中編輯路線")

                        PanelActionIconButton(systemName: "square.and.arrow.down") {
                            showCoordinatePaste = true
                        }
                        .accessibilityLabel("匯入座標路線")

                        PanelActionIconButton(
                            systemName: route.isFavorite ? "bookmark.fill" : "bookmark",
                            foregroundStyle: route.isFavorite ? .accentColor : .secondary
                        ) {
                            guard !isRouteInteractionLocked else { return }
                            modeManager.toggleFavorite(route)
                        }
                        .accessibilityLabel(route.isFavorite ? "從收藏移除路線" : "將路線加入收藏")
                    }
                }
                .frame(height: 44, alignment: .top)

            } else if modeManager.routes.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("尚無路線").font(.subheadline.weight(.semibold))
                        Text("直接點地圖加入第一個路點。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    HStack(spacing: 0) {
                        PanelActionIconButton(systemName: "square.and.arrow.down") {
                            showCoordinatePaste = true
                        }
                        .accessibilityLabel("匯入座標路線")

                        PanelActionIconButton(systemName: "bookmark") { }
                            .disabled(true)
                            .accessibilityLabel("加入兩個以上路點後即可收藏")
                    }
                }
                .frame(height: 44, alignment: .top)

            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "list.bullet.circle")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("尚未選擇路線").font(.subheadline.weight(.semibold))
                        Text("可直接點地圖開始畫路線，或到收藏頁面選擇路線。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    HStack(spacing: 0) {
                        PanelActionIconButton(systemName: "square.and.arrow.down") {
                            showCoordinatePaste = true
                        }
                        .accessibilityLabel("匯入座標路線")

                        PanelActionIconButton(systemName: "bookmark.fill") {
                            showUnifiedBookmarks = true
                        }
                        .accessibilityLabel("從收藏選擇路線")
                    }
                }
                .frame(height: 44, alignment: .top)

            }

            routeStartButton
        }
        .disabled(isRouteInteractionLocked)
        .confirmationDialog("放棄路線編輯？", isPresented: $showDiscardInlineEditConfirm, titleVisibility: .visible) {
            Button("放棄變更", role: .destructive) { cancelInlineEditing() }
            Button("繼續編輯", role: .cancel) { }
        } message: {
            Text("尚未儲存的路點與名稱修改會遺失。")
        }
        .alert("路線名稱重複", isPresented: $showInlineRouteOverwriteConfirm) {
            Button("覆蓋", role: .destructive) { overwritePendingInlineRoute() }
            Button("取消", role: .cancel) { pendingInlineRouteOverwrite = nil }
        } message: {
            Text("已存在相同名稱的路線，是否以目前內容覆蓋？")
        }
    }

    private var displayedRoute: SimulationRoute? {
        inlineEditingRoute ?? selectedRoute
    }

    private var inlineRouteEditorPanel: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("路線名稱", text: Binding(
                    get: { inlineEditingRoute?.name ?? "" },
                    set: { inlineEditingRoute?.name = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Text("\(inlineEditingRoute?.points.count ?? 0) 點")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let point = selectedInlinePoint {
                HStack(spacing: 10) {
                    Text("\(point.order + 1)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已選擇第 \(point.order + 1) 點")
                            .font(.caption.weight(.semibold))
                        Text(formatCoordinate(point.coordinate))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color(.secondarySystemBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 10) {
                editorAction("復原", icon: "arrow.uturn.backward") {
                    inlineEditingRoute?.points.removeLast()
                    normalizeInlinePointOrder()
                    selectedInlinePointID = nil
                }
                .disabled(inlineEditingRoute?.points.isEmpty != false)

                editorAction("刪除點", icon: "trash") {
                    guard let selectedInlinePointID = selectedInlinePointID else { return }
                    inlineEditingRoute?.points.removeAll { $0.id == selectedInlinePointID }
                    normalizeInlinePointOrder()
                    self.selectedInlinePointID = nil
                }
                .disabled(selectedInlinePointID == nil)

                editorAction("清空", icon: "eraser") {
                    inlineEditingRoute?.points.removeAll()
                    selectedInlinePointID = nil
                }
                .disabled(inlineEditingRoute?.points.isEmpty != false)
            }

            Text("點地圖新增路點；點數字路點可選取或刪除。座標與順序可在收藏清單中編輯。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    showDiscardInlineEditConfirm = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                Button {
                    saveInlineRoute()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(inlineEditingRoute?.isValid != true || inlineEditingRoute?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            }

        }
    }

    private var routeStartButton: some View {
        GeometryReader { geometry in
            Button(action: { startCurrentRoute() }) {
                Group {
                    if isStartingRoute {
                        Label(
                            "正在連線…",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                    } else {
                        Label("啟動路線", systemImage: "play.fill")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundStyle(.white)
                .background(
                    Color.accentColor,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(
                displayedRoute?.isValid != true
                    || !pairingExists
                    || simulationSpeed <= 0
                    || isStartingRoute
                    || shouldReturnToLaunchAfterRouteStart
            )
            .opacity(
                displayedRoute?.isValid != true
                    || !pairingExists
                    || simulationSpeed <= 0
                    || isStartingRoute
                    || shouldReturnToLaunchAfterRouteStart
                    ? 0.55 : 1
            )
            .frame(width: geometry.size.width * 0.5)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 40)
    }

    private func startCurrentRoute() {
        guard !isRouteInteractionLocked else { return }
        if inlineEditingRoute != nil {
            startInlineRouteSimulation()
        } else if let route = selectedRoute {
            startRouteSimulation(route)
        }
    }

    private func refreshPairingExists() {
        #if targetEnvironment(simulator)
        pairingExists = true
        #else
        pairingExists = FileManager.default.fileExists(
            atPath: PairingFileStore.prepareURL().path
        )
        #endif
    }

    private var selectedInlinePoint: PathPoint? {
        guard let selectedInlinePointID = selectedInlinePointID else { return nil }
        return inlineEditingRoute?.points.first(where: { $0.id == selectedInlinePointID })
    }

    private func editorAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func beginInlineRouteCreation() {
        guard !isRouteInteractionLocked else { return }
        inlineEditingRoute = modeManager.createNewRoute(
            name: RouteNameGenerator.nextAvailableName(in: modeManager.routes)
        )
        selectedInlinePointID = nil
        previewStartCoordinate = nil
    }

    private func beginInlineRouteEditing(_ route: SimulationRoute) {
        guard !isRouteInteractionLocked else { return }
        inlineEditingRoute = route
        selectedInlinePointID = nil
    }

    private func addInlinePoint(_ coordinate: CLLocationCoordinate2D) {
        guard !isRouteInteractionLocked,
              var route = inlineEditingRoute else { return }
        modeManager.addPathPoint(coordinate, to: &route)
        inlineEditingRoute = route
    }

    private func handleRouteMapTap(_ coordinate: CLLocationCoordinate2D) {
        guard !isRouteInteractionLocked,
              !modeManager.isSimulating,
              !modeManager.isPaused else { return }
        if inlineEditingRoute == nil {
            beginInlineRouteCreation()
        }
        if inlineEditingRoute?.points.isEmpty != false {
            pendingFirstRoutePoint = coordinate
        } else {
            addInlinePoint(coordinate)
        }
    }

    private func confirmFirstRoutePoint() {
        guard !isRouteInteractionLocked,
              let coordinate = pendingFirstRoutePoint else { return }
        pendingFirstRoutePoint = nil
        if inlineEditingRoute == nil {
            beginInlineRouteCreation()
        }
        addInlinePoint(coordinate)
    }

    private func selectRouteStartPoint(_ route: SimulationRoute, index: Int) {
        guard !isRouteInteractionLocked,
              route.points.indices.contains(index) else { return }
        startPointByRoute[route.id] = index
        let coordinate = route.points[index].coordinate
        previewStartCoordinate = coordinate
        sharedMapState.selectedCoordinate = coordinate
        centerMapOnRoutePoint(coordinate)
    }

    private func centerMapOnRoutePoint(_ coordinate: CLLocationCoordinate2D) {
        let camera = MapCamera(
            centerCoordinate: coordinate,
            distance: sharedMapState.lastCamera?.distance ?? 1_500,
            heading: sharedMapState.lastCamera?.heading ?? 0,
            pitch: sharedMapState.lastCamera?.pitch ?? 0
        )
        sharedMapState.lastCamera = camera
        mapPosition = .camera(camera)
        sharedMapState.nativeMapCenterRequest = NativeMapCenterRequest(
            coordinate: coordinate,
            preserveZoom: true,
            resumesRouteFollowing: true
        )
        SharedNativeMapStore.shared.center(
            at: coordinate,
            preserveZoom: true
        )
    }

    private func normalizeInlinePointOrder() {
        guard var route = inlineEditingRoute else { return }
        for index in route.points.indices {
            route.points[index].order = index
        }
        inlineEditingRoute = route
    }

    private func cancelInlineEditing() {
        inlineEditingRoute = nil
        selectedInlinePointID = nil
    }

    private func saveInlineRoute() {
        guard !isRouteInteractionLocked,
              var route = inlineEditingRoute else { return }
        route.name = route.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard route.isValid, !route.name.isEmpty else { return }
        for index in route.points.indices { route.points[index].order = index }
        if let existing = modeManager.routes.first(where: {
            $0.id != route.id &&
            SavedItemNameMatcher.matches($0.name, route.name)
        }) {
            route.id = existing.id
            route.createdDate = existing.createdDate
            route.isFavorite = existing.isFavorite
            pendingInlineRouteOverwrite = route
            showInlineRouteOverwriteConfirm = true
            return
        }
        finishSavingInlineRoute(route)
    }

    private func startInlineRouteSimulation() {
        guard var route = inlineEditingRoute, route.isValid else { return }
        route.name = route.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if route.name.isEmpty {
            route.name = "未儲存路線"
        }
        for index in route.points.indices {
            route.points[index].order = index
        }
        inlineEditingRoute = route
        startRouteSimulation(route)
    }

    private func overwritePendingInlineRoute() {
        guard !isRouteInteractionLocked,
              let route = pendingInlineRouteOverwrite else { return }
        if let editingID = inlineEditingRoute?.id, editingID != route.id,
           let original = modeManager.routes.first(where: { $0.id == editingID }) {
            modeManager.deleteRoute(original)
        }
        pendingInlineRouteOverwrite = nil
        finishSavingInlineRoute(route)
    }

    private func finishSavingInlineRoute(_ route: SimulationRoute) {
        guard !isRouteInteractionLocked else { return }
        modeManager.saveRoute(route)
        selectedRouteID = route.id
        inlineEditingRoute = nil
        selectedInlinePointID = nil
    }

    private var inlineCoordinatePasteSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                Text("每行輸入或貼上一組緯度、經度，座標會接在目前路線後方。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $inlineCoordinateText)
                    .font(.body.monospacedDigit())
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Button("加入目前路線") {
                    KeyboardDismissal.dismiss()
                    appendInlineCoordinates()
                }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(CoordinateImportParser.parseInline(inlineCoordinateText).isEmpty)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("加入座標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        KeyboardDismissal.dismiss()
                        showInlineCoordinatePaste = false
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { KeyboardDismissal.dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func appendInlineCoordinates() {
        guard !isRouteInteractionLocked else { return }
        let coordinates = CoordinateImportParser.parseInline(inlineCoordinateText)
        guard var route = inlineEditingRoute else { return }
        for coordinate in coordinates { modeManager.addPathPoint(coordinate, to: &route) }
        inlineEditingRoute = route
        inlineCoordinateText = ""
        showInlineCoordinatePaste = false
    }

    private func startIndex(for route: SimulationRoute) -> Int {
        guard route.points.count > 0 else { return 0 }
        let raw = startPointByRoute[route.id] ?? 0
        return min(max(raw, 0), route.points.count - 1)
    }

    private func importPairingFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try PairingFileStore.importFromPicker(url)
                finishPairingImport()
            } catch {
                alertMessage = "導入配對文件失敗：\(error.localizedDescription)"
                showAlert = true
            }
        case .failure(let error):
            alertMessage = "文件讀取失敗：\(error.localizedDescription)"
            showAlert = true
        }
    }

    private func finishPairingImport() {
        pairingExists = true
        isReturningToCurrentLocation = true
        recenterAfterPairingAuthorization = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            requestAlwaysPermissionAfterPairingIfNeeded()
            currentLocationProvider.requestCurrentLocation(allowCachedLocation: false)
        }

        if let selected = sharedMapState.selectedCoordinate {
            previewStartCoordinate = selected
        } else if let firstPoint = displayedRoute?.points.first?.coordinate {
            previewStartCoordinate = firstPoint
        } else {
            previewStartCoordinate = nil
        }
    }

    private func startRouteSimulation(_ route: SimulationRoute) {
        guard !isRouteInteractionLocked else { return }
        // 每次啟動前重新套用設定，避免設定頁與路線引擎狀態不同步。
        applyStoredRouteSettings()

        if sharedMapState.isTunnelReachable == false {
            sharedMapState.testTunnel(force: true)
            alertMessage = "VPN Tunnel 尚未就緒，請確認 LocalDevVPN 已開啟後重試。"
            showAlert = true
            return
        }

        if CLLocationManager().authorizationStatus == .authorizedWhenInUse {
            BackgroundLocationManager.shared.requestAlwaysPermission()
        }
        guard simulationSpeed > 0 else {
            alertMessage = "目前時速必須大於 0 km/hr 才能啟動路線。"
            showAlert = true
            return
        }
        guard pairingExists else {
            alertMessage = "配對文件不存在，請先手動匯入配對文件。"
            showAlert = true
            return
        }

        let index = startIndex(for: route)
        guard route.points.indices.contains(index) else { return }
        let coordinate = route.points[index].coordinate
        routeStartGeneration &+= 1
        let startGeneration = routeStartGeneration
        isStartingRoute = true
        sharedMapState.isSimulationTransitioning = true
        let pairingFile = PairingFileStore.prepareURL().path
        let ip = DeviceConnectionContext.targetIPAddress

        SimulationCoordinator.shared.start(
            mode: .route,
            coordinate: coordinate,
            deviceIP: ip,
            pairingFile: pairingFile,
            operation: "啟動路線"
        ) { result in
            guard routeStartGeneration == startGeneration else { return }
            isStartingRoute = false
            if shouldReturnToLaunchAfterRouteStart {
                shouldReturnToLaunchAfterRouteStart = false
                guard let launchCoordinate = sharedMapState.launchCoordinate else { return }
                if case .success = result {
                    isReturningStoppedRouteToLaunch = true
                    stopRouteSimulationNow()
                    finishReturningToLaunchLocation(launchCoordinate, updateHeldRoute: true)
                } else {
                    sharedMapState.isSimulationTransitioning = false
                    finishReturningToLaunchLocation(launchCoordinate, updateHeldRoute: false)
                }
                return
            }
            guard case .success = result else {
                sharedMapState.isSimulationTransitioning = false
                alertMessage = result.failure?.localizedDescription ?? "啟動路線失敗"
                showAlert = true
                return
            }
            lastRoutePushAt = Date()
            selectedInlinePointID = nil
            sharedMapState.selectedCoordinate = coordinate
            LocationHistoryStore.add(
                kind: .routeStart,
                coordinate: coordinate,
                routeName: route.name
            )
            modeManager.startPathSimulation(route: route, speed: simulationSpeed, startIndex: index)
            // Close the transition only after the shared active state is set;
            // otherwise tab/search controls can briefly unlock before SwiftUI
            // observes modeManager.isSimulating.
            sharedMapState.isSimulationActive = modeManager.isSimulating || modeManager.isPaused
            sharedMapState.isMovementActive = modeManager.isSimulating && simulationSpeed > 0
            sharedMapState.isSimulationTransitioning = false
            pauseFreeRouteForBackgroundIfNeeded()
        }
    }

    private func pauseFreeRouteForBackgroundIfNeeded() {
        guard scenePhase == .background,
              modeManager.isSimulating,
                            !MembershipFeaturePolicy.canRunRoute(
                                inBackground: true,
                                proActive: isProUser
                            ) else { return }

        routePausedForFreeBackground = true
        shouldPresentFreeBackgroundPauseAlert = true
        modeManager.pausePathSimulation()
        BackgroundLocationManager.shared.requestStop(for: .route)
    }

    private func applyStoredRouteSettings() {
        let completionMode = PathCompletionMode(rawValue: completionModeRaw) ?? .stopAtLast
        if completionModeRaw != completionMode.rawValue {
            completionModeRaw = completionMode.rawValue
        }
        modeManager.completionMode = completionMode

        let planningMode = RoutePlanningMode(rawValue: routePlanningModeRaw) ?? .direct
        if routePlanningModeRaw != planningMode.rawValue {
            routePlanningModeRaw = planningMode.rawValue
        }
        modeManager.routePlanningMode = planningMode
        modeManager.orbitRadiusMeters = min(max(routeOrbitRadiusMeters, 1), 39)
    }

    private func returnToLaunchLocation() {
        guard let coordinate = sharedMapState.launchCoordinate else { return }

        switch LaunchCoordinateReturnPolicy.routeAction(
            isStarting: isStartingRoute,
            isSimulating: modeManager.isSimulating,
            isPaused: modeManager.isPaused
        ) {
        case .stopAfterPendingStartAndRecenter:
            shouldReturnToLaunchAfterRouteStart = true
            finishReturningToLaunchLocation(coordinate, updateHeldRoute: false)
        case .stopAndRecenter:
            isReturningStoppedRouteToLaunch = true
            stopRouteSimulationNow()
            finishReturningToLaunchLocation(coordinate, updateHeldRoute: true)
        case .recenterOnly:
            finishReturningToLaunchLocation(coordinate, updateHeldRoute: false)
        }
    }

    private func finishReturningToLaunchLocation(
        _ coordinate: CLLocationCoordinate2D,
        updateHeldRoute: Bool
    ) {
        if updateHeldRoute {
            // stopRouteSimulationNow 保留裝置模擬；房屋只把停止後持有的座標改為 launch。
            pendingStoppedRouteCoordinate = coordinate
            modeManager.currentLocation = coordinate
            previewStartCoordinate = coordinate
        }
        // 執行中的路線先沿用停止按鈕語意，再以啟動座標收尾，避免後續 tick 拉回路線。
        _ = sharedMapState.returnToLaunchLocation()
        SharedNativeMapStore.shared.center(at: coordinate, preserveZoom: false)
        sendPendingStoppedRouteCoordinateIfPossible()
    }

    private func sendPendingStoppedRouteCoordinateIfPossible() {
        guard let coordinate = pendingStoppedRouteCoordinate else { return }
        guard pairingExists else {
            pendingStoppedRouteCoordinate = nil
            isReturningStoppedRouteToLaunch = false
            alertTitle = "路線提示"
            alertMessage = "路線已停止，但配對文件已不存在；請重新手動匯入配對文件。"
            showAlert = true
            finishRouteStoppingIfIdle()
            return
        }
        guard !isRouteLocationCommandInFlight else { return }
        pendingStoppedRouteCoordinate = nil
        pushRouteLocationUpdateIfNeeded(coordinate)
    }

    private func stopRouteSimulationNow() {
        routePausedForFreeBackground = false
        shouldPresentFreeBackgroundPauseAlert = false
        routeStartGeneration &+= 1
        routeLocationCommandGeneration &+= 1
        routeLocationCommandInFlightGeneration = nil
        pendingRouteHistoryCoordinate = nil
        isStartingRoute = false
        sharedMapState.isSimulationTransitioning = true
        SimulationCoordinator.shared.invalidatePendingCommands()
        modeManager.stopPathSimulation()
        sharedMapState.isSimulationActive = false
        sharedMapState.isMovementActive = false
        SimulationCoordinator.shared.allowNextModeSwitchWhileHoldingLocation()
        backgroundSimulationManager.markRouteManuallyStoppedHoldingLocation()
        BackgroundLocationManager.shared.requestStart(for: .route)
        DispatchQueue.main.async {
            finishRouteStoppingIfIdle()
        }
    }

    private func finishRouteStoppingIfIdle() {
        guard sharedMapState.isSimulationTransitioning,
              !isStartingRoute,
              !modeManager.isSimulating,
              !modeManager.isPaused,
              !isRouteLocationCommandInFlight,
              pendingStoppedRouteCoordinate == nil else { return }
        sharedMapState.isSimulationTransitioning = false
    }

    private func pushRouteLocationUpdateIfNeeded(_ location: CLLocationCoordinate2D?) {
        // 房屋流程由 pending queue 序列化送出；忽略 currentLocation publisher 的同步重複觸發。
        if isReturningStoppedRouteToLaunch,
           pendingStoppedRouteCoordinate != nil {
            return
        }
        guard pairingExists,
              modeManager.isSimulating
                || modeManager.isPaused
                || backgroundSimulationManager.isRouteManuallyStopped,
              let location,
              !isRouteLocationCommandInFlight else { return }

        let now = Date()
        if modeManager.isSimulating,
           now.timeIntervalSince(lastRoutePushAt) < 0.35 {
            return
        }
        lastRoutePushAt = now

        let pairingFile = PairingFileStore.prepareURL().path
        let ip = DeviceConnectionContext.targetIPAddress
        let commandGeneration = routeLocationCommandGeneration
        routeLocationCommandInFlightGeneration = commandGeneration

        SimulationCoordinator.shared.update(
            coordinate: location,
            deviceIP: ip,
            pairingFile: pairingFile,
            intent: .routeMovement,
            operation: "更新路線位置"
        ) { result in
            guard commandGeneration == routeLocationCommandGeneration else {
                sendPendingStoppedRouteCoordinateIfPossible()
                finishRouteStoppingIfIdle()
                return
            }
            routeLocationCommandInFlightGeneration = nil
            if pendingStoppedRouteCoordinate != nil {
                // 房屋停止後以 launch update 收尾；舊 route command 不得回寫舊座標。
                sendPendingStoppedRouteCoordinateIfPossible()
                return
            }
            if pendingRouteHistoryCoordinate != nil {
                sendPendingRouteHistoryCoordinateIfPossible()
                return
            }
            isReturningStoppedRouteToLaunch = false
            if case .success = result {
                sharedMapState.selectedCoordinate = location
                if modeManager.isSimulating
                    || modeManager.isPaused
                    || backgroundSimulationManager.isRouteManuallyStopped {
                    BackgroundLocationManager.shared.requestStart(for: .route)
                } else {
                    BackgroundLocationManager.shared.requestStop(for: .route)
                }
            }
            finishRouteStoppingIfIdle()
        }
    }

    private func handleRouteHistorySelection(_ coordinate: CLLocationCoordinate2D) {
        guard RouteHistorySelectionPolicy.shouldPauseAndPush(
            isSimulating: modeManager.isSimulating,
            isPaused: modeManager.isPaused
        ) else { return }
        guard pairingExists else {
            alertTitle = "路線提示"
            alertMessage = "配對文件不存在，無法推送歷史座標。"
            showAlert = true
            return
        }

        if modeManager.isSimulating {
            modeManager.pausePathSimulation()
        }
        sharedMapState.isSimulationActive = true
        sharedMapState.isMovementActive = false
        pendingRouteHistoryCoordinate = coordinate
        sendPendingRouteHistoryCoordinateIfPossible()
    }

    private func sendPendingRouteHistoryCoordinateIfPossible() {
        guard let coordinate = pendingRouteHistoryCoordinate,
              !isRouteLocationCommandInFlight else { return }
        pendingRouteHistoryCoordinate = nil

        let previousCoordinate = modeManager.currentLocation
        let canResumeRoute = !modeManager.isRouteCompleted
        let commandGeneration = routeLocationCommandGeneration
        routeLocationCommandInFlightGeneration = commandGeneration
        SimulationCoordinator.shared.update(
            coordinate: coordinate,
            deviceIP: DeviceConnectionContext.targetIPAddress,
            pairingFile: PairingFileStore.prepareURL().path,
            intent: .singlePoint,
            operation: "推送歷史座標"
        ) { result in
            guard commandGeneration == routeLocationCommandGeneration else { return }
            if case .success = result {
                modeManager.currentLocation = coordinate
                sharedMapState.selectedCoordinate = coordinate
                previewStartCoordinate = coordinate
                alertTitle = "路線已暫停"
                alertMessage = canResumeRoute
                    ? "已推送歷史座標；按播放可繼續原路線。"
                    : "已推送歷史座標。"
            } else {
                if let previousCoordinate {
                    modeManager.currentLocation = previousCoordinate
                    sharedMapState.selectedCoordinate = previousCoordinate
                }
                alertTitle = "歷史座標推送失敗"
                alertMessage = result.failure?.localizedDescription
                    ?? "無法將歷史座標推送到裝置。"
            }
            routeLocationCommandInFlightGeneration = nil
            showAlert = true
        }
    }

    private func formatCoordinate(_ coordinate: CLLocationCoordinate2D) -> String {
        CoordinateDisplayFormatter.string(coordinate)
    }

    private func recenterMapOnSimulatedLocation() {
        guard let coordinate = modeManager.currentLocation
                ?? sharedMapState.selectedCoordinate else { return }
        let camera = MapCamera(
            centerCoordinate: coordinate,
            distance: sharedMapState.lastCamera?.distance ?? 1_500,
            heading: sharedMapState.lastCamera?.heading ?? 0,
            pitch: sharedMapState.lastCamera?.pitch ?? 0
        )
        sharedMapState.lastCamera = camera
        mapPosition = .camera(camera)
        sharedMapState.nativeMapCenterRequest = NativeMapCenterRequest(
            coordinate: coordinate,
            preserveZoom: true,
            resumesRouteFollowing: true
        )
        SharedNativeMapStore.shared.center(
            at: coordinate,
            preserveZoom: true
        )
    }

    private func updateStableRouteHeading(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate = coordinate else {
            previousRouteLocation = nil
            return
        }
        defer { previousRouteLocation = coordinate }
        guard let previousRouteLocation = previousRouteLocation else { return }
        let fromLocation = CLLocation(latitude: previousRouteLocation.latitude, longitude: previousRouteLocation.longitude)
        let toLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard fromLocation.distance(from: toLocation) > 0.2 else { return }
        let fromLat = previousRouteLocation.latitude * .pi / 180
        let toLat = coordinate.latitude * .pi / 180
        let deltaLongitude = (coordinate.longitude - previousRouteLocation.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(toLat)
        let x = cos(fromLat) * sin(toLat) - sin(fromLat) * cos(toLat) * cos(deltaLongitude)
        stableRouteHeading = atan2(y, x) * 180 / .pi
    }

    private func requestAlwaysPermissionAfterPairingIfNeeded() {
        currentLocationProvider.requestAlwaysAuthorizationIfPossible()
    }


    private func reopenSettingsIfNeeded() {
        guard returnToSettingsAfterChild else { return }
        returnToSettingsAfterChild = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showSettings = true
        }
    }
}



#Preview {
    PathSimulationView()
        .environmentObject(SharedLocationMapState())
}
