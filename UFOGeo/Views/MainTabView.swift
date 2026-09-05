import SwiftUI
import Foundation
import MapKit
import UIKit

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    private static let noSimulationColdStartInterval: TimeInterval = 60
    @StateObject private var sharedLocationMapState = SharedLocationMapState()
    @StateObject private var startupLocationProvider = CurrentLocationProvider()
    @StateObject private var backgroundSimulationManager = BackgroundSimulationManager.shared
    @StateObject private var portaly = PortalyCheckoutService.shared
    @StateObject private var auth = FirebaseAuthService.shared
    @StateObject private var healthCoordinator = HealthWalkingCoordinator.shared
    @AppStorage(UserDefaults.Keys.primaryTabSelection) private var selection: String = AppFeature.home.id
    @State private var didApplyStartupLocation = false
    @State private var showStopSimulationPrompt = false
    @State private var showResetWarning = false
    @State private var resetWarningMessage = ""
    @State private var membershipRefreshTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            UnifiedSimulationPage(
                selection: tabSelectionBinding,
                onBlockedSwitch: { showStopSimulationPrompt = true }
            )
            .environmentObject(sharedLocationMapState)
            .onAppear {
                ensureSelectionIsValid()
                sharedLocationMapState.activeTabID = selection
                sharedLocationMapState.testTunnel()
                handleAppBecameActive()
            }
            .onChange(of: selection) { _, newSelection in
                sharedLocationMapState.activeTabID = newSelection
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    handleAppBecameActive()
                case .background:
                    stopMembershipRefreshLoop()
                    recordNoSimulationBackgroundIfNeeded()
                    stopBackgroundLocationIfSimulationIsInactive()
                case .inactive:
                    refreshProEntitlementBeforeBackgroundIfNeeded()
                    recordNoSimulationBackgroundIfNeeded()
                @unknown default:
                    break
                }
            }
            .onDisappear {
                stopMembershipRefreshLoop()
            }
            .onOpenURL { url in
                portaly.handlePortalyReturnURL(url)
            }
            .task(id: auth.session?.uid) {
                stopMembershipRefreshLoop()
                guard let expectedUID = auth.session?.uid,
                      scenePhase == .active else { return }
                await synchronizeMembershipEntitlement(forceRefresh: true)
                guard auth.session?.uid == expectedUID else { return }
                startMembershipRefreshLoopIfNeeded()
            }
            .onChange(of: portaly.isPro) { _, _ in
                startMembershipRefreshLoopIfNeeded()
            }
            .onChange(of: sharedLocationMapState.isMovementActive) { _, _ in
                startMembershipRefreshLoopIfNeeded()
            }
            .onChange(of: healthCoordinator.isGenerating) { _, _ in
                startMembershipRefreshLoopIfNeeded()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            ) { _ in
                backgroundSimulationManager.notifySimulationActiveIfNeeded(
                    backgroundLocationAvailable: BackgroundLocationManager.shared
                        .canDeliverBackgroundHeartbeats
                )
            }
            .onReceive(backgroundSimulationManager.$currentMode) { mode in
                guard scenePhase == .active else { return }
                switchToActiveSimulationTabIfNeeded(mode: mode)
            }
            .onReceive(startupLocationProvider.$currentCoordinate) { coordinate in
                guard let coordinate,
                      coordinate.latitude.isFinite,
                      coordinate.longitude.isFinite,
                      CLLocationCoordinate2DIsValid(coordinate) else { return }
                sharedLocationMapState.captureLaunchCoordinateIfNeeded(coordinate)
                guard
                      !didApplyStartupLocation,
                      !sharedLocationMapState.isSimulationInteractionLocked else { return }
                didApplyStartupLocation = true
                sharedLocationMapState.selectedCoordinate = coordinate
                sharedLocationMapState.mapPosition = .region(
                    SharedLocationMapState.defaultSimulationRegion(centeredAt: coordinate)
                )
                sharedLocationMapState.nativeMapCenterRequest = NativeMapCenterRequest(
                    coordinate: coordinate,
                    preserveZoom: false
                )
                SharedNativeMapStore.shared.center(
                    at: coordinate,
                    preserveZoom: false
                )
            }
            .onReceive(sharedLocationMapState.$requestedTabID) { requestedTabID in
                guard let requestedTabID,
                      AppFeature.mainTabs.contains(where: { $0.id == requestedTabID }) else { return }
                guard sharedLocationMapState.canSwitchTabs else {
                    showStopSimulationPrompt = true
                    sharedLocationMapState.requestedTabID = nil
                    return
                }
                selection = requestedTabID
                sharedLocationMapState.requestedTabID = nil
            }
            .alert("請先停止模擬", isPresented: $showStopSimulationPrompt) {
                if let active = activeSimulationInfo,
                   selection != active.tabID {
                    Button("前往\(active.pageTitle)") {
                        selection = active.tabID
                        sharedLocationMapState.activeTabID = active.tabID
                        showStopSimulationPrompt = false
                    }
                }
                Button("知道了", role: .cancel) { }
            } message: {
                Text(stopSimulationPromptMessage)
            }
            .alert("閒置背景重置未完成", isPresented: $showResetWarning) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(resetWarningMessage)
            }
        }
    }

    private var tabSelectionBinding: Binding<String> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard newSelection != selection else { return }
                guard sharedLocationMapState.canSwitchTabs else {
                    showStopSimulationPrompt = true
                    return
                }
                withAnimation(.easeInOut(duration: 0.18)) {
                    selection = newSelection
                }
            }
        )
    }

    private func ensureSelectionIsValid() {
        let ids = AppFeature.mainTabs.map { $0.id }
        if ids.contains(selection) {
            return
        }
        selection = AppFeature.home.id
    }

    private var activeSimulationInfo: (pageTitle: String, tabID: String)? {
        switch backgroundSimulationManager.currentMode {
        case .fixedLocation:
            return ("定位/步數頁", AppFeature.home.id)
        case .route:
            return ("路線頁", AppFeature.pathSimulation.id)
        case nil:
            return nil
        }
    }

    private var stopSimulationPromptMessage: String {
        if sharedLocationMapState.isSimulationTransitioning {
            return "模擬正在啟動或停止，請稍候完成後再切換分頁。"
        }
        switch backgroundSimulationManager.currentMode {
        case .fixedLocation:
            return "目前仍在執行定位/步數模擬。請先到定位頁按下停止，再切換分頁。"
        case .route:
            return "目前仍在執行路線模擬。請先到路線頁按下停止，再切換分頁。"
        case nil:
            return "定位或路線模擬仍在執行。請先回到目前畫面按下停止，停止完成後才能切換分頁。"
        }
    }

    private func switchToActiveSimulationTabIfNeeded(
        mode: SimulationMode? = nil
    ) {
        let activeMode = mode ?? backgroundSimulationManager.currentMode
        let targetTabID: String
        switch activeMode {
        case .fixedLocation:
            targetTabID = AppFeature.home.id
        case .route:
            targetTabID = AppFeature.pathSimulation.id
        case nil:
            return
        }

        guard selection != targetTabID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            selection = targetTabID
        }
        sharedLocationMapState.activeTabID = targetTabID
    }

    private func handleAppBecameActive() {
        guard !sharedLocationMapState.isSimulationTransitioning else { return }
        if shouldApplyNoSimulationColdStartReset() {
            applyNoSimulationColdStartReset()
            return
        }
        if case nil = backgroundSimulationManager.currentMode,
           !sharedLocationMapState.isSimulationActive {
            returnToFreshRealLocation()
            return
        }
        switchToActiveSimulationTabIfNeeded()
    }

    private func synchronizeMembershipEntitlement(forceRefresh: Bool) async {
        // The service performs the initial/session sync. Portaly callbacks are
        // handled separately by the deep-link queue.
        try? await portaly.synchronizeOnForeground(forceRefresh: forceRefresh)
    }

    private var isForegroundProFeatureActive: Bool {
        sharedLocationMapState.isMovementActive || healthCoordinator.isGenerating
    }

    nonisolated static func shouldRunPeriodicMembershipRefresh(
        isSignedIn: Bool,
        isSceneActive: Bool,
        isPro: Bool,
        isMovementActive: Bool,
        isHealthGenerating: Bool
    ) -> Bool {
        isSignedIn && isSceneActive && isPro &&
            (isMovementActive || isHealthGenerating)
    }

    private func startMembershipRefreshLoopIfNeeded() {
        stopMembershipRefreshLoop()
        guard Self.shouldRunPeriodicMembershipRefresh(
            isSignedIn: auth.isSignedIn,
            isSceneActive: scenePhase == .active,
            isPro: portaly.isPro,
            isMovementActive: sharedLocationMapState.isMovementActive,
            isHealthGenerating: healthCoordinator.isGenerating
        ) else { return }
        membershipRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(max(portaly.proEntitlementRefreshDelay, 1))
                    )
                } catch {
                    return
                }
                guard auth.isSignedIn,
                      scenePhase == .active,
                      portaly.isPro,
                      isForegroundProFeatureActive else { return }
                _ = await portaly.refreshProEntitlementIfNeeded()
            }
        }
    }

    private func refreshProEntitlementBeforeBackgroundIfNeeded() {
        guard auth.isSignedIn,
              portaly.isPro,
              backgroundSimulationManager.currentMode == .route ||
                sharedLocationMapState.isMovementActive ||
                healthCoordinator.isGenerating else { return }
        Task {
            _ = await portaly.refreshProEntitlementIfNeeded()
        }
    }

    private func stopMembershipRefreshLoop() {
        membershipRefreshTask?.cancel()
        membershipRefreshTask = nil
    }

    private func returnToFreshRealLocation() {
        didApplyStartupLocation = false
        startupLocationProvider.requestCurrentLocation(allowCachedLocation: false)
    }

    private func stopBackgroundLocationIfSimulationIsInactive() {
        guard case nil = backgroundSimulationManager.currentMode,
              !sharedLocationMapState.isSimulationActive,
              !sharedLocationMapState.isSimulationTransitioning,
              !sharedLocationMapState.isLocationRefreshCycleActive else { return }

        // 手動停止旗標若保留為 true，背景心跳流程可能再次 requestStart，
        // 造成無模擬狀態下定位服務被重新拉起而讓系統指示持續存在。
        if backgroundSimulationManager.isRouteManuallyStopped
            || backgroundSimulationManager.isFixedManuallyStopped {
            backgroundSimulationManager.markSimulationInactive()
        }

        BackgroundLocationManager.shared.stopAllActivities()
    }

    private func recordNoSimulationBackgroundIfNeeded() {
        let defaults = UserDefaults.standard
        guard shouldTrackNoSimulationBackground else {
            defaults.removeObject(forKey: UserDefaults.Keys.noSimulationBackgroundAt)
            return
        }
        defaults.set(Date(), forKey: UserDefaults.Keys.noSimulationBackgroundAt)
    }

    private var shouldTrackNoSimulationBackground: Bool {
        if backgroundSimulationManager.isRouteManuallyStopped
            || backgroundSimulationManager.isFixedManuallyStopped {
            return true
        }
        if case nil = backgroundSimulationManager.currentMode {
            return AppFeature.mainTabs.contains(where: { $0.id == selection })
                && !sharedLocationMapState.isSimulationActive
                && !sharedLocationMapState.isMovementActive
                && !sharedLocationMapState.isSimulationTransitioning
        }
        return false
    }

    private func shouldApplyNoSimulationColdStartReset() -> Bool {
        guard let backgroundAt = UserDefaults.standard.object(
            forKey: UserDefaults.Keys.noSimulationBackgroundAt
        ) as? Date else {
            return false
        }
        return Date().timeIntervalSince(backgroundAt) >= Self.noSimulationColdStartInterval
    }

    private func applyNoSimulationColdStartReset() {
        UserDefaults.standard.removeObject(forKey: UserDefaults.Keys.noSimulationBackgroundAt)

        // 保險地清除可能殘留的模擬設定，確保回到真實定位。
        SimulationCoordinator.shared.stop(operation: "閒置背景恢復真實定位") { result in
            if case .success = result {
                backgroundSimulationManager.markSimulationInactive()
                performNoSimulationColdStartLocalReset()
            } else {
                let reason = result.failure?.localizedDescription ?? "未知錯誤"
                resetWarningMessage = "閒置背景重置失敗，仍維持目前狀態：\(reason)"
                showResetWarning = true
            }
        }
    }

    private func performNoSimulationColdStartLocalReset() {
        NotificationCenter.default.post(name: .routeSimulationDidExpire, object: nil)
        NotificationCenter.default.post(name: .locationSimulationDidExpire, object: nil)
        selection = AppFeature.home.id
        sharedLocationMapState.activeTabID = AppFeature.home.id
        sharedLocationMapState.isSimulationActive = false
        sharedLocationMapState.isSimulationTransitioning = false
        sharedLocationMapState.isMovementActive = false
        sharedLocationMapState.requestedControlAction = nil
        sharedLocationMapState.requestedRouteID = nil
        sharedLocationMapState.requestedTabID = nil

        didApplyStartupLocation = false
        startupLocationProvider.requestCurrentLocation()
        sharedLocationMapState.testTunnel()
    }

}

private struct UnifiedSimulationPage: View {
    @EnvironmentObject private var sharedMapState: SharedLocationMapState
    @Binding var selection: String
    let onBlockedSwitch: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SharedNativeMapHostView()
                    .ignoresSafeArea()

                LocationSimulationUIView()
                    .opacity(selection == AppFeature.home.id ? 1 : 0)
                    .allowsHitTesting(selection == AppFeature.home.id)
                    .accessibilityHidden(selection != AppFeature.home.id)

                PathSimulationView()
                    .opacity(selection == AppFeature.pathSimulation.id ? 1 : 0)
                    .allowsHitTesting(selection == AppFeature.pathSimulation.id)
                    .accessibilityHidden(selection != AppFeature.pathSimulation.id)

                SharedSimulationControlsView()
                    .zIndex(40)

                HStack(spacing: 0) {
                    modeButton(.home)
                    modeButton(.pathSimulation)
                }
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.35), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(.horizontal, min(max(proxy.size.width * 0.11, 32), 52))
                .padding(.bottom, max(8, proxy.safeAreaInsets.bottom == 0 ? 8 : 4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(50)
            }
            .environment(\.adaptiveLayout, AdaptiveLayoutMetrics(size: proxy.size))
        }
    }

    private func modeButton(_ feature: AppFeature) -> some View {
        Button {
            guard feature.id == selection || sharedMapState.canSwitchTabs else {
                onBlockedSwitch()
                return
            }
            selection = feature.id
        } label: {
            VStack(spacing: 3) {
                Image(systemName: modeIcon(for: feature))
                    .font(.system(size: 18, weight: .semibold))
                Text(feature.title)
                    .font(.caption2)
            }
            .foregroundStyle(selection == feature.id ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(feature.title)
        .accessibilityAddTraits(selection == feature.id ? .isSelected : [])
    }

    private func modeIcon(for feature: AppFeature) -> String {
        if feature.id != selection, !sharedMapState.canSwitchTabs {
            return "lock.fill"
        }
        return feature.systemImage
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
