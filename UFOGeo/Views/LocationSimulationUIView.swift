import SwiftUI
import MapKit
import CoreLocation

struct LocationSimulationUIView: View {
    @Environment(\.adaptiveLayout) private var layout
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var sharedMapState: SharedLocationMapState
    @AppStorage(UserDefaults.Keys.lastJoystickSpeed) private var lastJoystickSpeed: Double = 10
    @AppStorage(UserDefaults.Keys.hasShownInitialPairingPrompt) private var hasShownInitialPairingPrompt = false
    @State private var cachedPairingExists: Bool = false
    
    /// UI 狀態集中管理
    @StateObject private var uiState = LocationSimulationUIState()
    
    // MARK: - 服務層物件（保留為 @StateObject，具有獨立生命週期）
    @StateObject private var joystickManager = JoystickManager()
    @StateObject private var currentLocationProvider = CurrentLocationProvider()
    @StateObject private var routeImportManager = JoystickModeManager()
    @StateObject private var backgroundSimulationManager = BackgroundSimulationManager.shared
    @StateObject private var portaly = PortalyCheckoutService.shared
    @ObservedObject private var healthCoordinator = HealthWalkingCoordinator.shared
    
    // MARK: - 系統級資源（保留為 @State，涉及複雜生命週期）
    @State private var leafBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var leafRefreshTask: Task<Void, Never>?
    @State private var resendTimer: Timer?
    @State private var pendingDirectLocationCoordinate: CLLocationCoordinate2D?
    @State private var joystickEntitlementPreflightID: UUID?
    
    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }
    
    private var pairingExists: Bool { cachedPairingExists }
    
    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var canUseJoystick: Bool {
        portaly.canUseJoystick
    }

    private var selectedCoordinate: CLLocationCoordinate2D? {
        get { sharedMapState.selectedCoordinate }
        nonmutating set { sharedMapState.selectedCoordinate = newValue }
    }

    private var selectedBookmark: LocationBookmark? {
        guard let selectedCoordinate else { return nil }
        // 優化：使用緩存避免每次渲染都重新計算
        // 只在座標改變時重新查詢
        let cached = uiState.cachedSelectedBookmark
        if let cached,
           cached.latitude == selectedCoordinate.latitude,
           cached.longitude == selectedCoordinate.longitude {
            return cached
        }
        
        let found = uiState.bookmarks.first { bookmark in
            CLLocation(latitude: bookmark.latitude, longitude: bookmark.longitude)
                .distance(from: CLLocation(
                    latitude: selectedCoordinate.latitude,
                    longitude: selectedCoordinate.longitude
                )) < 1
        }
        uiState.cachedSelectedBookmark = found
        return found
    }

    private var isSelectedCoordinateBookmarked: Bool {
        selectedBookmark != nil
    }

    private var mapPosition: MapCameraPosition {
        get { sharedMapState.mapPosition }
        nonmutating set { sharedMapState.mapPosition = newValue }
    }

    private var visibleMapRegion: MKCoordinateRegion? {
        get { sharedMapState.visibleRegion }
        nonmutating set { sharedMapState.visibleRegion = newValue }
    }

    var body: some View {
        ZStack {
            mapLayer

            FloatingJoystickView(
                manager: joystickManager,
                size: layout.joystickSize,
                layout: layout,
                isSimulating: uiState.isSimulating,
                joystickDirectionLocked: uiState.joystickDirectionLocked,
                isEnabled: canUseJoystick,
                onDragChanged: handleJoystickDragChanged,
                onDragEnded: handleJoystickDragEnded,
                onDoubleTap: unlockJoystickDirection,
                onLockedTap: showJoystickUpgradePrompt
            )

            compactControlPanel
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.bottom, layout.bottomControlInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(
            isPresented: $uiState.showPairingImporter,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importPairingFile(result)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                reopenSettingsIfNeeded()
            }
        }
        .alert("提示", isPresented: $uiState.showAlert) {
            Button("確定", role: .cancel) { }
        } message: {
            Text(uiState.alertMessage)
        }
        .alert("需要配對文件", isPresented: $uiState.showInitialPairingPrompt) {
            Button("立即匯入") { uiState.showPairingImporter = true }
            Button("稍後", role: .cancel) { }
        } message: {
            Text("請先手動匯入此 iPhone 的配對文件，才能使用定位與路線模擬。")
        }
        .sheet(isPresented: $uiState.showBookmarks, onDismiss: reopenSettingsIfNeeded) {
            UnifiedBookmarksView(
                locationBookmarks: uiState.bookmarks,
                onSelectLocation: { bookmark in
                    handleSavedCoordinateSelection(
                        bookmark.coordinate,
                        operation: "收藏座標更新",
                        failureMessage: "收藏座標更新失敗"
                    )
                },
                onSelectHistory: { coordinate in
                    handleSavedCoordinateSelection(
                        coordinate,
                        operation: "歷史座標更新",
                        failureMessage: "歷史座標更新失敗"
                    )
                },
                onLocationBookmarksChanged: { updated in
                    uiState.bookmarks = updated
                }
            )
        }
        .sheet(isPresented: $uiState.showCompatibilityCheck) {
            CompatibilityCheckView(
                onImportPairing: {
                    uiState.returnToSettingsAfterChild = true
                    uiState.showPairingImporter = true
                },
                onImportCoordinates: {
                    uiState.returnToSettingsAfterChild = true
                    uiState.showRouteImporter = true
                },
                onOpenSavedItems: {
                    uiState.returnToSettingsAfterChild = true
                    uiState.showBookmarks = true
                },
                savedItemsTitle: "定位與路線收藏",
                initialScrollTarget: uiState.openWalkingSectionInSettings ? .walkingHealth : nil
            )
        }
        .sheet(isPresented: $uiState.showRouteImporter, onDismiss: reopenSettingsIfNeeded) {
            CoordinateToRouteView(modeManager: routeImportManager)
        }
        .alert("儲存書籤", isPresented: $uiState.showSaveBookmark) {
            TextField("位置名稱", text: $uiState.newBookmarkName)
            Button("儲存") { addBookmark() }
            Button("取消", role: .cancel) { uiState.newBookmarkName = "" }
        } message: {
            Text("請為此位置輸入一個名稱。")
        }
        .alert("書籤名稱重複", isPresented: $uiState.showBookmarkOverwriteConfirm) {
            Button("覆蓋", role: .destructive) { overwritePendingBookmark() }
            Button("取消", role: .cancel) { uiState.pendingBookmarkOverwrite = nil }
        } message: {
            Text("已存在相同名稱的書籤，是否以目前座標覆蓋？")
        }
        .onAppear {
            if !uiState.didInitializeView {
                uiState.didInitializeView = true
                loadInitialState()
                let restoredSpeed = min(max(lastJoystickSpeed, 0), 1000)
                joystickManager.maxSpeed = restoredSpeed
                joystickManager.reset(within: CGRect(x: 0, y: 0, width: 100, height: 100))
                currentLocationProvider.requestCurrentLocation()
                if !pairingExists && !hasShownInitialPairingPrompt {
                    hasShownInitialPairingPrompt = true
                    uiState.showInitialPairingPrompt = true
                }
            }
        }
        .onReceive(currentLocationProvider.$currentCoordinate) { coordinate in
            if uiState.isReturningToCurrentLocation, let coordinate {
                uiState.isReturningToCurrentLocation = false
                sharedMapState.isReturningToRealLocationInProgress = false
                if currentLocationProvider.authorizationStatus == .authorizedAlways {
                    uiState.recenterAfterPairingAuthorization = false
                }
                selectLocation(coordinate, recenter: true)
                updateActiveSimulationToCoordinateIfNeeded(
                    coordinate,
                    operation: "回到真實定位",
                    failureMessage: "更新至真實定位失敗"
                )
                requestAlwaysPermissionAfterPairingIfNeeded()
                return
            }
            guard let coordinate,
                  !uiState.didApplyActualStartCoordinate,
                  !uiState.isSimulating else { return }
            uiState.didApplyActualStartCoordinate = true
            selectLocation(coordinate, recenter: true)
            requestAlwaysPermissionAfterPairingIfNeeded()
        }
        .onReceive(currentLocationProvider.$authorizationStatus) { status in
            if uiState.isReturningToCurrentLocation,
               status == .denied || status == .restricted {
                uiState.isReturningToCurrentLocation = false
                sharedMapState.isReturningToRealLocationInProgress = false
            }
            guard uiState.recenterAfterPairingAuthorization else { return }
            switch status {
            case .authorizedAlways:
                uiState.recenterAfterPairingAuthorization = false
                uiState.isReturningToCurrentLocation = true
                currentLocationProvider.requestCurrentLocation(allowCachedLocation: false)
            case .denied, .restricted:
                uiState.recenterAfterPairingAuthorization = false
                uiState.alertMessage = "定位授權被拒絕。請到「設定」>「隱私」>「定位服務」中允許此應用進行定位。"
                uiState.showAlert = true
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .locationBookmarksDidChange)) { _ in
            loadBookmarks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pairingFileDidChange)) { _ in
            refreshPairingExists()
        }
        .onChange(of: uiState.isSimulating) { _, active in
            sharedMapState.isSimulationActive = active
            if !active {
                sharedMapState.isMovementActive = false
            }
        }
        .onChange(of: uiState.isManuallyStopped) { _, stopped in
            if stopped {
                sharedMapState.isSimulationActive = false
                sharedMapState.isMovementActive = false
            }
        }
        .onChange(of: lastJoystickSpeed) { _, newSpeed in
            let clampedSpeed = min(max(newSpeed, 0), 1000)
            joystickManager.maxSpeed = clampedSpeed
        }
        .onChange(of: canUseJoystick) { _, isAllowed in
            if !isAllowed {
                revokeJoystickAccess()
            }
        }
        .onChange(of: uiState.isProcessingSimulation) { _, isProcessing in
            if !isProcessing {
                applyPendingDirectLocationIfPossible()
            }
        }
        .onChange(of: sharedMapState.isSimulationTransitioning) { _, isTransitioning in
            if !isTransitioning {
                applyPendingDirectLocationIfPossible()
            }
        }
        .onReceive(sharedMapState.$requestedControlAction) { action in
            handleSharedControlAction(action)
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundLocationHeartbeat)) {
            notification in
            guard scenePhase != .active,
                  uiState.isSimulating || uiState.isManuallyStopped,
                  !uiState.isProcessingSimulation,
                  !uiState.joystickCommandInFlight,
                  let coordinate = selectedCoordinate else { return }

            let date = notification.userInfo?["date"] as? Date ?? Date()
            routeImportManager.advanceForBackgroundHeartbeat(at: date)
            guard date.timeIntervalSince(uiState.lastHeartbeatKeepAliveAt) >= 2 else { return }
            uiState.lastHeartbeatKeepAliveAt = date
            enqueueBackgroundHeartbeatUpdate(coordinate)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: .locationSimulationDidExpire)) { _ in
            pendingDirectLocationCoordinate = nil
            uiState.invalidateSimulationCommands()
            SimulationCoordinator.shared.invalidatePendingCommands()
            SimulationCoordinator.shared.allowNextModeSwitchWhileHoldingLocation()
            uiState.isSimulating = false
            uiState.isManuallyStopped = false
            sharedMapState.isSimulationTransitioning = false
            BackgroundLocationManager.shared.requestStop(for: .continuousLocation)
            routeImportManager.stopStandaloneWalkingSession()
            stopResendLoop()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard sharedMapState.activeTabID == AppFeature.home.id else { return }
            updateLocationFromJoystickIfNeeded()
        }
        .onDisappear {
            pendingDirectLocationCoordinate = nil
            // 清理Timer資源
            resendTimer?.invalidate()
            resendTimer = nil
            
            // 清理Task資源
            leafRefreshTask?.cancel()
            leafRefreshTask = nil

            uiState.invalidateSimulationCommands()
            SimulationCoordinator.shared.invalidatePendingCommands()
            sharedMapState.isSimulationTransitioning = false
            
            // 停止位置刷新循環
            sharedMapState.isLocationRefreshCycleActive = false
            sharedMapState.locationRefreshCountdown = nil
            BackgroundLocationManager.shared.requestStop(for: .locationRefreshCycle)
            endLeafBackgroundTask()
        }
    }

    private func handleSharedControlAction(_ action: SharedControlAction?) {
        guard sharedMapState.activeTabID == AppFeature.home.id,
              let action else { return }
        sharedMapState.requestedControlAction = nil
        switch action {
        case .settings:
            uiState.openWalkingSectionInSettings = false
            uiState.showCompatibilityCheck = true
        case .bookmarks:
            uiState.showBookmarks = true
        case .walking:
            uiState.openWalkingSectionInSettings = true
            uiState.showCompatibilityCheck = true
        case .returnToRealLocation:
            returnToRealLocation()
        case .locationRefreshCycle:
            guard uiState.isSimulating else { return }
            startLocationRefreshCycle()
        case .recenter:
            recenterMapOnSimulatedLocation()
        case .directLocation:
            // 未啟動時搜尋只移動鏡頭；定位模擬中才同步更新模擬座標。
            handleDirectLocationRequest()
        }
    }

    private func handleDirectLocationRequest() {
        guard let coordinate = selectedCoordinate else { return }
        cancelJoystickMovementCommands()
        guard uiState.isSimulating
                || sharedMapState.isSimulationTransitioning else { return }
        pendingDirectLocationCoordinate = coordinate
        applyPendingDirectLocationIfPossible()
    }

    private func applyPendingDirectLocationIfPossible() {
        guard let coordinate = pendingDirectLocationCoordinate else { return }
        guard !sharedMapState.isSimulationTransitioning else { return }
        guard uiState.isSimulating else {
            pendingDirectLocationCoordinate = nil
            return
        }
        guard !uiState.isProcessingSimulation else { return }
        pendingDirectLocationCoordinate = nil
        selectedCoordinate = coordinate
        centerMapOnCoordinate(coordinate, preserveZoom: true)
        updateActiveSimulationToCoordinateIfNeeded(
            coordinate,
            operation: "搜尋座標更新",
            failureMessage: "搜尋座標更新失敗"
        )
    }
    

    private func recenterMapOnSimulatedLocation() {
        guard let coordinate = selectedCoordinate else { return }
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
            preserveZoom: true
        )
        SharedNativeMapStore.shared.center(
            at: coordinate,
            preserveZoom: true
        )
    }

    private var compactControlPanel: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: uiState.isSimulating ? "location.fill" : "hand.tap")
                    .foregroundStyle(uiState.isSimulating ? Color.green : Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(panelTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(panelDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                CoordinateActionButtonGroup(
                    coordinate: selectedCoordinate,
                    isBookmarked: isSelectedCoordinateBookmarked,
                    onCopyAction: nil,
                    onBookmarkAction: {
                        toggleSelectedCoordinateBookmark()
                    }
                )
            }
            .frame(height: 44, alignment: .top)

            if uiState.isSimulating {
                HStack {
                    Label("累計 \(healthCoordinator.pendingSteps)", systemImage: "figure.walk")
                    Spacer()
                    Text("剩餘 \(healthCoordinator.remainingSteps) 步")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(healthCoordinator.isEnabled ? .primary : .secondary)
            }

            PrimaryActionButton(
                isSimulating: uiState.isSimulating,
                isProcessing: uiState.isProcessingSimulation,
                isDisabled: !uiState.isSimulating && primaryActionDisabled,
                action: uiState.isSimulating ? stopSimulation : startSimulation
            )

        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(
            height: layout.simulationCardHeight(isActive: uiState.isSimulating),
            alignment: .bottom
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: uiState.isSimulating)
        .panelStyle(cornerRadius: 18)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }

    private var locationMarkerRotation: Double {
        guard joystickManager.isActive else { return 0 }
        return joystickManager.angle - 90
    }

    private var panelTitle: String {
        if let selectedBookmark { return selectedBookmark.name }
        if uiState.isSimulating { return "定位模擬執行中" }
        if !pairingExists { return "先連接你的 iPhone" }
        if selectedCoordinate == nil { return "在地圖上選擇目標位置" }
        return "目標位置已選擇"
    }

    private var panelDetail: String {
        if selectedBookmark != nil, let coordinate = selectedCoordinate {
            if uiState.isSimulating {
                return "\(CoordinateDisplayFormatter.string(coordinate)) · 定位模擬執行中"
            }
            return CoordinateDisplayFormatter.string(coordinate)
        }
        if uiState.isSimulating, let coordinate = selectedCoordinate {
            return CoordinateDisplayFormatter.string(coordinate)
        }
        if !pairingExists { return "請先從齒輪選單手動匯入配對文件。" }
        if let coordinate = selectedCoordinate {
            return CoordinateDisplayFormatter.string(coordinate)
        }
        return "搜尋地點或直接點一下地圖，選好後即可啟動。"
    }
    
    private var mapLayer: some View {
        LocationNativeMapView(
            coordinate: Binding(
                get: { selectedCoordinate },
                set: { selectedCoordinate = $0 }
            ),
            rotation: locationMarkerRotation,
            isMoving: canUseJoystick
                && uiState.isSimulating
                && (uiState.joystickTouchActive || uiState.joystickDirectionLocked),
            onTap: { coordinate in
                selectLocation(coordinate)
                guard uiState.isSimulating,
                      !uiState.isProcessingSimulation else { return }
                updateActiveSimulationToCoordinateIfNeeded(
                    coordinate,
                    operation: "更新模擬座標",
                    failureMessage: "更新模擬座標失敗"
                )
            },
            sharedMapState: sharedMapState
        )
        .ignoresSafeArea()
    }
    
    private var primaryActionDisabled: Bool {
        selectedCoordinate == nil
    }


    private func handleJoystickDragChanged() {
        guard canUseJoystick else {
            revokeJoystickAccess()
            return
        }
        if !uiState.joystickTouchActive,
           portaly.needsProEntitlementRefresh {
            guard joystickEntitlementPreflightID == nil else { return }
            let preflightID = UUID()
            joystickEntitlementPreflightID = preflightID
            Task { @MainActor in
                let allowed = await portaly.refreshProEntitlementIfNeeded()
                guard joystickEntitlementPreflightID == preflightID else { return }
                joystickEntitlementPreflightID = nil
                guard allowed else {
                    revokeJoystickAccess()
                    showJoystickUpgradePrompt()
                    return
                }
                guard joystickManager.isActive else { return }
                applyJoystickDragChanged()
            }
            return
        }
        applyJoystickDragChanged()
    }

    private func applyJoystickDragChanged() {
        let now = Date()

        if uiState.isSimulating,
           joystickManager.isActive,
           joystickManager.magnitude > 0,
           !sharedMapState.isMovementActive {
            sharedMapState.isMovementActive = true
        }

        if !uiState.joystickTouchActive {
            uiState.joystickTouchActive = true
            if uiState.joystickDirectionLocked {
                return
            }
            uiState.joystickHoldStartedAt = now
            uiState.joystickHoldAngle = joystickManager.angle
            return
        }

        guard !uiState.joystickDirectionLocked else { return }
        if angularDifference(joystickManager.angle, uiState.joystickHoldAngle) > 12 {
            uiState.joystickHoldStartedAt = now
            uiState.joystickHoldAngle = joystickManager.angle
        }
    }

    private func handleJoystickDragEnded() -> Bool {
        joystickEntitlementPreflightID = nil
        guard canUseJoystick else {
            revokeJoystickAccess()
            return false
        }
        uiState.joystickTouchActive = false
        uiState.joystickHoldStartedAt = nil
        if !uiState.joystickDirectionLocked {
            sharedMapState.isMovementActive = false
        }
        return uiState.joystickDirectionLocked
    }

    private func unlockJoystickDirection() {
        guard canUseJoystick else {
            revokeJoystickAccess()
            return
        }
        uiState.joystickDirectionLocked = false
        uiState.joystickTouchActive = false
        uiState.joystickHoldStartedAt = nil
        joystickManager.reset(within: CGRect(x: 0, y: 0, width: 100, height: 100))
        sharedMapState.isMovementActive = false
        Haptics.selection()
    }

    private func angularDifference(_ first: Double, _ second: Double) -> Double {
        let raw = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }



    private func updateLocationFromJoystickIfNeeded() {
        guard canUseJoystick,
              uiState.isSimulating,
              joystickManager.isActive,
              joystickManager.magnitude > 0,
              !uiState.isProcessingSimulation,
              !uiState.backgroundHeartbeatCoalescer.isInFlight,
              pairingExists,
              let base = selectedCoordinate else { return }

        let now = Date()
        if uiState.joystickTouchActive,
           !uiState.joystickDirectionLocked,
           let holdStartedAt = uiState.joystickHoldStartedAt,
           now.timeIntervalSince(holdStartedAt) >= 2 {
            withAnimation(.spring(response: 0.2)) {
                uiState.joystickDirectionLocked = true
            }
            Haptics.medium()
        }
        let elapsedSinceLastUpdate = now.timeIntervalSince(uiState.lastJoystickUpdateAt)
        guard elapsedSinceLastUpdate >= 0.1 else { return }
        let movementInterval = elapsedSinceLastUpdate.isFinite && elapsedSinceLastUpdate < 1
            ? min(elapsedSinceLastUpdate, 0.5)
            : 0.1
        uiState.lastJoystickUpdateAt = now

        guard let next = JoystickMovementEngine().destination(
            from: base,
            joystickAngleDegrees: joystickManager.angle,
            speedKilometersPerHour: joystickManager.maxSpeed,
            elapsed: movementInterval
        ) else { return }
        let pairingFile = pairingFilePath
        let ip = deviceIP
        selectedCoordinate = next
        SharedNativeMapStore.shared.center(
            at: next,
            preserveZoom: true
        )
        if uiState.joystickCommandInFlight {
            uiState.pendingJoystickCoordinate = next
            return
        }

        sendJoystickCoordinateUpdate(
            coordinate: next,
            previousCoordinate: base,
            deviceIP: ip,
            pairingFile: pairingFile
        )
    }

    private func enqueueBackgroundHeartbeatUpdate(_ coordinate: CLLocationCoordinate2D) {
        guard let nextCoordinate = uiState.backgroundHeartbeatCoalescer.enqueue(coordinate) else {
            return
        }
        let commandToken = uiState.beginBackgroundHeartbeatCommand()
        sendBackgroundHeartbeatUpdate(
            coordinate: nextCoordinate,
            commandToken: commandToken
        )
    }

    private func sendBackgroundHeartbeatUpdate(
        coordinate: CLLocationCoordinate2D,
        commandToken: Int
    ) {
        SimulationCoordinator.shared.update(
            coordinate: coordinate,
            deviceIP: deviceIP,
            pairingFile: pairingFilePath,
            intent: .fixedKeepAlive,
            operation: "背景維持模擬位置"
        ) { result in
            guard uiState.isCurrentBackgroundHeartbeatCommand(commandToken) else {
                return
            }
            let nextCoordinate = uiState.backgroundHeartbeatCoalescer.complete(
                success: result.failure == nil
            )
            guard uiState.isSimulating || uiState.isManuallyStopped else {
                uiState.backgroundHeartbeatCoalescer.cancel()
                return
            }
            guard let nextCoordinate else { return }
            let nextToken = uiState.beginBackgroundHeartbeatCommand()
            sendBackgroundHeartbeatUpdate(
                coordinate: nextCoordinate,
                commandToken: nextToken
            )
        }
    }

    private func sendJoystickCoordinateUpdate(
        coordinate: CLLocationCoordinate2D,
        previousCoordinate: CLLocationCoordinate2D,
        deviceIP: String,
        pairingFile: String,
        commandToken: Int? = nil
    ) {
        guard canUseJoystick else {
            selectedCoordinate = previousCoordinate
            centerMapOnCoordinate(previousCoordinate, preserveZoom: true)
            revokeJoystickAccess()
            return
        }
        let commandToken = commandToken ?? uiState.beginJoystickCommand()
        uiState.joystickCommandInFlight = true
        SimulationCoordinator.shared.update(
            coordinate: coordinate,
            deviceIP: deviceIP,
            pairingFile: pairingFile,
            intent: .joystickMovement,
            operation: "搖桿定位"
        ) { result in
            guard uiState.isCurrentJoystickCommand(commandToken) else { return }
            uiState.joystickCommandInFlight = false
            if case .success = result {
                guard uiState.isSimulating,
                      let pending = uiState.pendingJoystickCoordinate else {
                    uiState.pendingJoystickCoordinate = nil
                    return
                }
                uiState.pendingJoystickCoordinate = nil
                sendJoystickCoordinateUpdate(
                    coordinate: pending,
                    previousCoordinate: coordinate,
                    deviceIP: deviceIP,
                    pairingFile: pairingFile,
                    commandToken: commandToken
                )
            } else {
                uiState.pendingJoystickCoordinate = nil
                selectedCoordinate = previousCoordinate
                SharedNativeMapStore.shared.center(
                    at: previousCoordinate,
                    preserveZoom: true
                )
                unlockJoystickDirection()
                uiState.alertMessage = result.failure?.localizedDescription ?? "搖桿定位失敗"
                uiState.showAlert = true
            }
        }
    }

    private func showJoystickUpgradePrompt() {
        uiState.alertMessage = "搖桿移動是 Pro 功能。Free 可在前景或背景維持單一位置，且不設產品層時間上限；實際背景執行仍受 iOS 權限與系統排程影響。"
        uiState.showAlert = true
    }

    private func revokeJoystickAccess() {
        let lastConfirmedCoordinate = SimulationCoordinator.shared.lastCoordinate
        let shouldRestoreConfirmedCoordinate = uiState.isSimulating
            && pairingExists
            && (uiState.joystickCommandInFlight || uiState.pendingJoystickCoordinate != nil)
        cancelJoystickMovementCommands()

        guard shouldRestoreConfirmedCoordinate,
              let lastConfirmedCoordinate else { return }
        selectedCoordinate = lastConfirmedCoordinate
        centerMapOnCoordinate(lastConfirmedCoordinate, preserveZoom: true)
        SimulationCoordinator.shared.update(
            coordinate: lastConfirmedCoordinate,
            deviceIP: deviceIP,
            pairingFile: pairingFilePath,
            intent: .fixedKeepAlive,
            operation: "降級後維持最後單點"
        ) { _ in }
    }

    private func cancelJoystickMovementCommands() {
        joystickEntitlementPreflightID = nil
        SimulationCoordinator.shared.invalidatePendingJoystickCommands()
        uiState.invalidateJoystickCommands()
        uiState.joystickDirectionLocked = false
        uiState.joystickTouchActive = false
        uiState.joystickHoldStartedAt = nil
        joystickManager.reset(within: CGRect(x: 0, y: 0, width: 100, height: 100))
        sharedMapState.isMovementActive = false
    }
    
    private func selectLocation(_ coordinate: CLLocationCoordinate2D, recenter: Bool = false) {
        selectedCoordinate = coordinate
        centerMapOnCoordinate(coordinate, preserveZoom: !recenter)
    }

    private func centerMapOnCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        preserveZoom: Bool
    ) {
        if preserveZoom, let visibleMapRegion {
            mapPosition = .region(
                MKCoordinateRegion(center: coordinate, span: visibleMapRegion.span)
            )
        } else {
            mapPosition = .region(
                SharedLocationMapState.defaultSimulationRegion(centeredAt: coordinate)
            )
        }
        sharedMapState.nativeMapCenterRequest = NativeMapCenterRequest(
            coordinate: coordinate,
            preserveZoom: preserveZoom
        )
        SharedNativeMapStore.shared.center(
            at: coordinate,
            preserveZoom: preserveZoom
        )
    }
    
    private func startSimulation() {
        guard let coordinate = selectedCoordinate else { return }
        centerMapOnCoordinate(coordinate, preserveZoom: true)
        if sharedMapState.isTunnelReachable == false {
            sharedMapState.testTunnel(force: true)
            uiState.alertMessage = "VPN Tunnel 尚未就緒，請確認 LocalDevVPN 已開啟後重試。"
            uiState.showAlert = true
            return
        }
        guard pairingExists else {
            uiState.alertMessage = "配對文件不存在，請先手動匯入配對文件。"
            uiState.showAlert = true
            return
        }
        if CLLocationManager().authorizationStatus == .authorizedWhenInUse {
            BackgroundLocationManager.shared.requestAlwaysPermission()
        }
        
        // 立即反饋：先顯示「正在連接」的狀態，優化用戶體驗
        uiState.invalidateSimulationCommands()
        let commandToken = uiState.beginSimulationCommand()
        uiState.isProcessingSimulation = true
        sharedMapState.isSimulationTransitioning = true
        uiState.simulationStatus = "正在連接設備..."

        SimulationCoordinator.shared.start(
            mode: .fixedLocation,
            coordinate: coordinate,
            deviceIP: deviceIP,
            pairingFile: pairingFilePath,
            operation: "設定位置"
        ) { result in
            guard uiState.isCurrentSimulationCommand(commandToken) else { return }
            uiState.isProcessingSimulation = false
            if case .success = result {
                uiState.isSimulating = true
                sharedMapState.isSimulationActive = true
                uiState.isManuallyStopped = false
                uiState.simulationStatus = "模擬位置設定成功"
                LocationHistoryStore.add(
                    kind: .location,
                    coordinate: coordinate
                )

                routeImportManager.startStandaloneWalkingSession()

                updateResendLoopForCurrentState()
            } else {
                uiState.simulationStatus = result.failure?.localizedDescription ?? "設定位置失敗"
                uiState.alertMessage = uiState.simulationStatus
                uiState.showAlert = true
            }
            sharedMapState.isSimulationTransitioning = false
        }
    }

    private func returnToRealLocation() {
        // 房屋按鈕與路線頁一致：只使用 App 啟動時記錄的座標，完全不重新抓取 GPS。
        leafRefreshTask?.cancel()
        leafRefreshTask = nil
        sharedMapState.isLocationRefreshCycleActive = false
        sharedMapState.locationRefreshCountdown = nil
        BackgroundLocationManager.shared.requestStop(for: .locationRefreshCycle)
        endLeafBackgroundTask()

        guard let launchCoordinate = sharedMapState.launchCoordinate,
              !uiState.isProcessingSimulation else { return }

        // 取消任何仍在等待真實 GPS 的舊流程，避免其非同步回呼覆蓋啟動座標。
        uiState.isReturningToCurrentLocation = false
        uiState.invalidateSimulationCommands()
        SimulationCoordinator.shared.invalidatePendingCommands()

        switch LaunchCoordinateReturnPolicy.fixedLocationAction(
            isSimulating: uiState.isSimulating
        ) {
        case .recenterOnly:
            sharedMapState.isReturningToRealLocationInProgress = false
            _ = sharedMapState.returnToLaunchLocation()
            SharedNativeMapStore.shared.center(at: launchCoordinate, preserveZoom: false)

        case .updateSimulationAndHold:
            let previousCoordinate = selectedCoordinate
            unlockJoystickDirection()
            sharedMapState.isReturningToRealLocationInProgress = true
            _ = sharedMapState.returnToLaunchLocation()
            SharedNativeMapStore.shared.center(at: launchCoordinate, preserveZoom: false)
            updateActiveSimulationToLaunchLocation(
                launchCoordinate,
                previousCoordinate: previousCoordinate
            )
        }
    }

    private func updateActiveSimulationToLaunchLocation(
        _ coordinate: CLLocationCoordinate2D,
        previousCoordinate: CLLocationCoordinate2D?
    ) {
        guard uiState.isSimulating else {
            sharedMapState.isReturningToRealLocationInProgress = false
            return
        }
        cancelJoystickMovementCommands()
        let commandToken = uiState.beginSimulationCommand()
        uiState.isProcessingSimulation = true
        SimulationCoordinator.shared.update(
            coordinate: coordinate,
            deviceIP: deviceIP,
            pairingFile: pairingFilePath,
            intent: .singlePoint,
            operation: "回到啟動位置"
        ) { result in
            guard uiState.isCurrentSimulationCommand(commandToken) else { return }
            uiState.isProcessingSimulation = false
            sharedMapState.isReturningToRealLocationInProgress = false
            if case .success = result {
                uiState.simulationStatus = "已回到啟動位置"
                backgroundSimulationManager.markSimulationActive(
                    mode: .fixedLocation
                )
                startResendLoop()
            } else {
                if let previousCoordinate {
                    selectedCoordinate = previousCoordinate
                    centerMapOnCoordinate(previousCoordinate, preserveZoom: false)
                }
                uiState.alertMessage = result.failure?.localizedDescription
                    ?? "回到啟動位置失敗"
                uiState.showAlert = true
            }
        }
    }

    private func updateActiveSimulationToCoordinateIfNeeded(
        _ coordinate: CLLocationCoordinate2D,
        operation: String = "更新模擬座標",
        failureMessage: String = "更新模擬座標失敗"
    ) {
        guard uiState.isSimulating else { return }
        cancelJoystickMovementCommands()
        let commandToken = uiState.beginSimulationCommand()
        uiState.isProcessingSimulation = true
        SimulationCoordinator.shared.update(
            coordinate: coordinate,
            deviceIP: deviceIP,
            pairingFile: pairingFilePath,
            intent: .singlePoint,
            operation: operation
        ) { result in
            guard uiState.isCurrentSimulationCommand(commandToken) else { return }
            uiState.isProcessingSimulation = false
            if case .success = result {
                backgroundSimulationManager.markSimulationActive(
                    mode: .fixedLocation
                )
                startResendLoop()
            } else {
                uiState.alertMessage = result.failure?.localizedDescription
                    ?? failureMessage
                uiState.showAlert = true
            }
        }
    }

    private func handleSavedCoordinateSelection(
        _ coordinate: CLLocationCoordinate2D,
        operation: String,
        failureMessage: String
    ) {
        selectLocation(coordinate, recenter: true)
        uiState.showBookmarks = false
        guard uiState.isSimulating,
              !uiState.isProcessingSimulation else { return }
        updateActiveSimulationToCoordinateIfNeeded(
            coordinate,
            operation: operation,
            failureMessage: failureMessage
        )
    }

    private func stopSimulation() {
        pendingDirectLocationCoordinate = nil
        uiState.invalidateSimulationCommands()
        SimulationCoordinator.shared.invalidatePendingCommands()
        unlockJoystickDirection()
        uiState.isSimulating = false
        uiState.isManuallyStopped = true
        uiState.isProcessingSimulation = false
        uiState.simulationStatus = "位置模擬已停止"
        sharedMapState.isSimulationTransitioning = false
        sharedMapState.isSimulationActive = false
        sharedMapState.isMovementActive = false
        routeImportManager.stopStandaloneWalkingSession()
        stopResendLoop()
        SimulationCoordinator.shared.allowNextModeSwitchWhileHoldingLocation()
        backgroundSimulationManager.markFixedManuallyStoppedHoldingLocation()
        BackgroundLocationManager.shared.requestStart(for: .continuousLocation)
    }

    private func startLocationRefreshCycle() {
        guard uiState.isSimulating,
              !uiState.isProcessingSimulation,
              !sharedMapState.isLocationRefreshCycleActive,
              let restoreCoordinate = selectedCoordinate else { return }

        let restoreIP = deviceIP
        let restorePairingFile = pairingFilePath
        uiState.isProcessingSimulation = true
        sharedMapState.isLocationRefreshCycleActive = true
        sharedMapState.locationRefreshCountdown = 5
        beginLeafBackgroundTask()
        BackgroundLocationManager.shared.requestStart(for: .locationRefreshCycle)

        leafRefreshTask = Task { @MainActor in
            do {
                // 第 1 秒：等待後再送出 stop。
                try await Task.sleep(for: .seconds(1))
                let clearResult = await SimulationCoordinator.shared.stop(
                    operation: "葉子恢復真實定位"
                )
                guard case .success = clearResult else {
                    throw clearResult.failure ?? LocationSimulationError(
                        code: 12,
                        operation: "葉子恢復真實定位"
                    )
                }

                // 第 2-4 秒：每秒請求一次 fresh 真實定位。
                for remainingSeconds in stride(from: 4, through: 2, by: -1) {
                    sharedMapState.locationRefreshCountdown = remainingSeconds
                    currentLocationProvider.requestCurrentLocation(allowCachedLocation: false)
                    try await Task.sleep(for: .seconds(1))
                }

                // 第 5 秒：僅維持真實定位，不再追加 fresh 請求。
                sharedMapState.locationRefreshCountdown = 1
                try await Task.sleep(for: .seconds(1))

                // 在真實定位狀態再停 1 秒。
                sharedMapState.locationRefreshCountdown = nil
                try await Task.sleep(for: .seconds(1))
                let restoreResult = await SimulationCoordinator.shared.start(
                    mode: .fixedLocation,
                    coordinate: restoreCoordinate,
                    deviceIP: restoreIP,
                    pairingFile: restorePairingFile,
                    operation: "葉子恢復 UFOGeo 定位"
                )
                guard case .success = restoreResult else {
                    throw restoreResult.failure ?? LocationSimulationError(
                        code: 11,
                        operation: "葉子恢復 UFOGeo 定位"
                    )
                }
                selectedCoordinate = restoreCoordinate
                uiState.simulationStatus = "已回到原定位座標"
            } catch is CancellationError {
                uiState.simulationStatus = "葉子定位流程已取消"
            } catch {
                uiState.simulationStatus = error.localizedDescription
                uiState.alertMessage = error.localizedDescription
                uiState.showAlert = true
            }
            uiState.isProcessingSimulation = false
            sharedMapState.isLocationRefreshCycleActive = false
            sharedMapState.locationRefreshCountdown = nil
            BackgroundLocationManager.shared.requestStop(for: .locationRefreshCycle)
            endLeafBackgroundTask()
            leafRefreshTask = nil
        }
    }

    private func beginLeafBackgroundTask() {
        guard leafBackgroundTaskID == .invalid else { return }
        leafBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "UFOGeoLocationRefresh"
        ) {
            Task { @MainActor in
                sharedMapState.isLocationRefreshCycleActive = false
                sharedMapState.locationRefreshCountdown = nil
                BackgroundLocationManager.shared.requestStop(for: .locationRefreshCycle)
                endLeafBackgroundTask()
            }
        }
    }

    private func endLeafBackgroundTask() {
        guard leafBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(leafBackgroundTaskID)
        leafBackgroundTaskID = .invalid
    }
    
    private func loadInitialState() {
        refreshPairingExists()
        loadBookmarks()
    }

    private func refreshPairingExists() {
        #if targetEnvironment(simulator)
        cachedPairingExists = true
        #else
        cachedPairingExists = FileManager.default.fileExists(atPath: pairingFilePath)
        #endif
    }

    private func reopenSettingsIfNeeded() {
        guard uiState.returnToSettingsAfterChild else { return }
        uiState.returnToSettingsAfterChild = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            uiState.showCompatibilityCheck = true
        }
    }
    
    
    private func loadBookmarks() {
        uiState.bookmarks = LocationBookmarkStore.load()
    }
    
    private func saveBookmarks() {
        LocationBookmarkStore.save(uiState.bookmarks)
    }

    private func toggleSelectedCoordinateBookmark() {
        if let selectedBookmark {
            uiState.bookmarks.removeAll { $0.id == selectedBookmark.id }
            saveBookmarks()
        } else {
            uiState.showSaveBookmark = true
        }
    }

    private func addBookmark() {
        guard let coord = selectedCoordinate else { return }
        guard !isSelectedCoordinateBookmarked else {
            uiState.newBookmarkName = ""
            return
        }
        let name = uiState.newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? CoordinateDisplayFormatter.string(coord) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        if uiState.bookmarks.contains(where: { SavedItemNameMatcher.matches($0.name, bookmark.name) }) {
            uiState.pendingBookmarkOverwrite = bookmark
            uiState.newBookmarkName = ""
            DispatchQueue.main.async { uiState.showBookmarkOverwriteConfirm = true }
        } else {
            uiState.bookmarks.append(bookmark)
            saveBookmarks()
            uiState.newBookmarkName = ""
        }
    }

    private func overwritePendingBookmark() {
        guard let pending = uiState.pendingBookmarkOverwrite,
              let index = uiState.bookmarks.firstIndex(where: {
                  SavedItemNameMatcher.matches($0.name, pending.name)
              }) else {
            uiState.pendingBookmarkOverwrite = nil
            return
        }
        var replacement = pending
        replacement.id = uiState.bookmarks[index].id
        uiState.bookmarks[index] = replacement
        saveBookmarks()
        uiState.pendingBookmarkOverwrite = nil
    }

    private func importPairingFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            uiState.isImportingPairingFile = true
            
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try PairingFileStore.importFromPicker(url)
                    }.value
                    
                    await MainActor.run {
                        finishPairingImport()
                    }
                } catch {
                    await MainActor.run {
                        uiState.isImportingPairingFile = false
                        uiState.alertMessage = "導入失敗：\(error.localizedDescription)"
                        uiState.showAlert = true
                    }
                }
            }
        case .failure(let error):
            uiState.alertMessage = "文件讀取失敗：\(error.localizedDescription)"
            uiState.showAlert = true
        }
    }

    private func finishPairingImport() {
        uiState.isImportingPairingFile = false
        refreshPairingExists()
        uiState.didApplyActualStartCoordinate = false
        uiState.isReturningToCurrentLocation = true
        uiState.requestAlwaysAfterPairingImport = true
        uiState.recenterAfterPairingAuthorization = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            requestAlwaysPermissionAfterPairingIfNeeded()
            currentLocationProvider.requestCurrentLocation(allowCachedLocation: false)
        }
    }

    private func requestAlwaysPermissionAfterPairingIfNeeded() {
        guard uiState.requestAlwaysAfterPairingImport else { return }
        uiState.requestAlwaysAfterPairingImport = false
        currentLocationProvider.requestAlwaysAuthorizationIfPossible()
    }

    private func ensureRuntimeServicesForFixedSimulation() {
        BackgroundLocationManager.shared.requestStart(for: .continuousLocation)
        routeImportManager.startStandaloneWalkingSession()
        updateResendLoopForCurrentState()
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if uiState.isSimulating {
                ensureRuntimeServicesForFixedSimulation()
            }
            updateResendLoopForCurrentState()
        case .background:
            stopResendLoop()
        case .inactive:
            stopResendLoop()
        @unknown default:
            stopResendLoop()
        }
    }

    private func updateResendLoopForCurrentState() {
        guard uiState.isSimulating,
              scenePhase == .active else {
            stopResendLoop()
            return
        }
        startResendLoop()
    }

    private func startResendLoop() {
        resendTimer?.invalidate()
        
        /// 定時重發位置的原因：
        /// iOS 系統可能在低功耗模式下間斷位置更新
        /// 每 4 秒重發一次以確保設備位置的連續性
        /// 這是網路調試工具的標準做法
        resendTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in
                guard uiState.isSimulating,
                      !uiState.isProcessingSimulation,
                      !uiState.joystickCommandInFlight,
                      !uiState.backgroundHeartbeatCoalescer.isInFlight,
                      let coordinate = selectedCoordinate else { return }

                let commandToken = uiState.beginSimulationCommand()
                uiState.isProcessingSimulation = true
                SimulationCoordinator.shared.update(
                    coordinate: coordinate,
                    deviceIP: deviceIP,
                    pairingFile: pairingFilePath,
                    intent: .fixedKeepAlive,
                    operation: "維持模擬位置"
                ) { _ in
                    guard uiState.isCurrentSimulationCommand(commandToken) else { return }
                    uiState.isProcessingSimulation = false
                }
            }
        }
    }
    
    private func stopResendLoop() {
        resendTimer?.invalidate()
        resendTimer = nil
    }
}

#Preview {
    NavigationStack {
        LocationSimulationUIView()
    }
    .environmentObject(SharedLocationMapState())
}
