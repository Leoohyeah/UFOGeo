import MapKit
import SwiftUI

struct SharedSimulationControlsView: View {
    @EnvironmentObject private var sharedMapState: SharedLocationMapState
    @Environment(\.adaptiveLayout) private var layout
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(UserDefaults.Keys.lastJoystickSpeed) private var speed: Double = 10
    @AppStorage(UserDefaults.Keys.healthWalkingEnabled) private var healthWalkingEnabled = false
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @StateObject private var portaly = PortalyCheckoutService.shared
    @State private var searchText = ""
    @State private var showResults = false
    @State private var isApplyingSearchSelection = false
    @State private var showSpeedEditor = false
    @State private var showJoystickUpgradePrompt = false
    @State private var pairingExists: Bool = false

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: layout.topControlSpacing) {
                searchControl
                    .overlay(alignment: .topLeading) {
                        searchResults.offset(y: 54)
                    }
                    .zIndex(40)
                speedControl
                    .frame(maxWidth: layout.speedWidth)
                utilityControls
                Spacer()
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.top, 8)
        }
        .onAppear {
            refreshConnectionStatus()
            let value = min(max(speed, 0), 1000)
            sharedMapState.simulationSpeed = value
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshConnectionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pairingFileDidChange)) { _ in
            refreshConnectionStatus()
        }
        .onChange(of: speed) { _, value in
            let clampedValue = min(max(value, 0), 1000)
            sharedMapState.simulationSpeed = clampedValue
        }
        .onChange(of: sharedMapState.simulationSpeed) { _, value in
            let clampedValue = min(max(value, 0), 1000)
            if speed != clampedValue {
                speed = clampedValue
            }
        }
        .onChange(of: searchText) { _, value in
            if isApplyingSearchSelection {
                isApplyingSearchSelection = false
                showResults = false
                searchCompleter.cancelAndClear()
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  CoordinateParser.parse(value) == nil else {
                showResults = false
                searchCompleter.cancelAndClear()
                return
            }
            showResults = true
            searchCompleter.update(query: value)
        }
        .onReceive(searchCompleter.$results) { results in
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            showResults = !trimmed.isEmpty
                && CoordinateParser.parse(searchText) == nil
                && !results.isEmpty
        }
        .alert("搖桿移動是 Pro 功能", isPresented: $showJoystickUpgradePrompt) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("Free 可在前景或背景維持單一位置，且不設產品層時間上限；實際背景執行仍受 iOS 權限與系統排程影響。")
        }
    }

    private var searchControl: some View {
        SearchBarWithCoordinateField(
            searchText: $searchText,
            showResults: $showResults,
            onSubmit: { _ in
                directlyLocate()
            },
            onDirectlyLocate: {
                directlyLocate()
            },
            maxWidth: layout.searchWidth,
            isProcessing: false,
            showDirectLocateButton: true
        )
    }

    @ViewBuilder
    private var speedControl: some View {
        ExpandableSpeedPanel(
            speed: sharedSpeedBinding,
            isExpanded: $showSpeedEditor,
            onSpeedChanged: { newSpeed in
                speed = newSpeed
            },
            unit: "km/hr",
            range: 0...1000,
            maxWidth: layout.speedWidth
        )
    }

    private var sharedSpeedBinding: Binding<Double> {
        Binding(
            get: { sharedMapState.simulationSpeed },
            set: { value in
                let clampedValue = min(max(value, 0), 1000)
                sharedMapState.simulationSpeed = clampedValue
                speed = clampedValue
            }
        )
    }

    private var utilityControls: some View {
        VStack(alignment: .leading, spacing: layout.topControlSpacing) {
            utilityButton("gearshape.fill", color: .accentColor, action: .settings)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            utilityButton("bookmark.fill", color: .accentColor, action: .bookmarks)
            utilityButton("figure.walk", color: healthWalkingEnabled ? .green : .accentColor, action: .walking)
            HStack(spacing: 8) {
                utilityButton(
                    "house.fill",
                    color: .accentColor,
                    action: .returnToRealLocation,
                    disabled: homeActionDisabled,
                    showsLoading: sharedMapState.isReturningToRealLocationInProgress
                )
                .accessibilityLabel(homeActionLabel)

                if sharedMapState.isReturningToRealLocationInProgress {
                    Text("正在\(homeActionLabel)...")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                        .accessibilityLabel("正在\(homeActionLabel)")
                }
            }
            utilityButton(
                "leaf.fill",
                color: leafButtonEnabled ? .green : .secondary,
                action: .locationRefreshCycle,
                disabled: !leafButtonEnabled
            )
            .overlay(alignment: .topTrailing) {
                if let countdown = sharedMapState.locationRefreshCountdown {
                    Text("\(countdown)")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.red, in: Circle())
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 3, y: -3)
                }
            }
            .accessibilityLabel(
                sharedMapState.locationRefreshCountdown.map { "葉子倒數 \($0) 秒" }
                    ?? "葉子定位刷新"
            )
            utilityButton("location.fill", color: .accentColor, action: .recenter)
        }
    }

    private var leafButtonEnabled: Bool {
        sharedMapState.activeTabID == AppFeature.home.id
            && sharedMapState.isSimulationActive
            && !sharedMapState.isLocationRefreshCycleActive
    }

    private var homeActionLabel: String {
        "回到啟動位置"
    }

    private var homeActionDisabled: Bool {
        sharedMapState.isReturningToRealLocationInProgress
            || sharedMapState.launchCoordinate == nil
    }

    private func utilityButton(
        _ image: String,
        color: Color,
        action: SharedControlAction,
        disabled: Bool = false,
        showsLoading: Bool = false
    ) -> some View {
        Button {
            sharedMapState.requestedControlAction = action
        } label: {
            ZStack {
                Image(systemName: image)
                    .font(.headline)
                    .foregroundStyle(color)
                    .opacity(showsLoading ? 0 : 1)
                if showsLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.accentColor)
                }
            }
            .frame(width: layout.controlButtonSize, height: layout.controlButtonSize)
            .background(.regularMaterial, in: Circle())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    @ViewBuilder private var searchResults: some View {
        SearchResultsDropdown(
            results: searchCompleter.results,
            isVisible: showResults,
            maxWidth: layout.searchWidth,
            onSelectResult: { result in
                selectResult(result)
            }
        )
    }

    private var connectionColor: Color {
        guard pairingExists else { return .orange }
        switch sharedMapState.isTunnelReachable {
        case true: return .green
        case false: return .red
        case nil: return .yellow
        }
    }

    private func refreshConnectionStatus() {
        #if targetEnvironment(simulator)
        pairingExists = true
        #else
        pairingExists = FileManager.default.fileExists(
            atPath: PairingFileStore.prepareURL().path
        )
        #endif
        sharedMapState.testTunnel()
    }

    private func selectResult(
        _ result: MKLocalSearchCompletion,
        directlyLocate: Bool = false
    ) {
        showResults = false
        searchCompleter.cancelAndClear()
        KeyboardDismissal.dismiss()
        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            guard let coordinate = response?.mapItems.first?.placemark.coordinate else { return }
            DispatchQueue.main.async {
                let selectedText = [result.title, result.subtitle]
                    .filter { !$0.isEmpty }
                    .joined(separator: "，")
                if searchText != selectedText {
                    isApplyingSearchSelection = true
                    searchText = selectedText
                }
                selectCoordinate(coordinate)
                if directlyLocate {
                    sharedMapState.requestedControlAction = .directLocation
                }
            }
        }
    }

    private func directlyLocate() {
        if let coordinate = CoordinateParser.parse(searchText) {
            selectCoordinate(coordinate)
            sharedMapState.requestedControlAction = .directLocation
            return
        }
        if !searchText.isEmpty,
           let first = searchCompleter.firstResult(matching: searchText) {
            selectResult(first, directlyLocate: true)
            return
        }
    }

    private func selectCoordinate(_ coordinate: CLLocationCoordinate2D) {
        sharedMapState.selectedCoordinate = coordinate
        sharedMapState.mapPosition = .region(
            SharedLocationMapState.defaultSimulationRegion(centeredAt: coordinate)
        )
        sharedMapState.nativeMapCenterRequest = NativeMapCenterRequest(
            coordinate: coordinate,
            preserveZoom: true
        )
        SharedNativeMapStore.shared.center(
            at: coordinate,
            preserveZoom: true
        )
        showResults = false
        KeyboardDismissal.dismiss()
    }
}
