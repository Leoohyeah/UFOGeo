import CoreLocation
import SwiftUI

enum CompatibilityCheckScrollTarget {
    case walkingHealth
}

struct CompatibilityCheckView: View {
    var onImportPairing: (() -> Void)?
    var onImportCoordinates: (() -> Void)?
    var onOpenSavedItems: (() -> Void)?
    var savedItemsTitle: String = "收藏位置"
    var initialScrollTarget: CompatibilityCheckScrollTarget?

    private enum TunnelStatus: Equatable {
        case testing, reachable
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var sharedMapState: SharedLocationMapState
    @ObservedObject private var healthCoordinator = HealthWalkingCoordinator.shared
    @ObservedObject private var portaly = PortalyCheckoutService.shared
    @AppStorage(UserDefaults.Keys.lastJoystickSpeed) private var simulationSpeed: Double = 10
    @AppStorage(UserDefaults.Keys.routeCompletionMode) private var completionModeRaw: String = PathCompletionMode.stopAtLast.rawValue
    @AppStorage(UserDefaults.Keys.routePlanningMode) private var routePlanningModeRaw: String = RoutePlanningMode.direct.rawValue
    @AppStorage(UserDefaults.Keys.routeOrbitRadiusMeters) private var routeOrbitRadiusMeters: Int = 30
    @State private var showHealthPermissionAlert = false
    @State private var showSupportAlert = false
    @State private var supportAlertTitle = "贊助 UFOGeo"
    @State private var supportAlertMessage = "贊助連結尚未設定。"
    @State private var healthAlertTitle = "健康權限"
    @State private var healthPermissionMessage = ""
    @State private var directHealthStepsText = ""
    @State private var isWritingDirectSteps = false
    @State private var simulationSpeedText = "10"
    @State private var simulationSpeedSlider = 10.0
    @State private var isDraggingSimulationSpeed = false
    @State private var pairingExists = false
    @State private var didInitialScroll = false
    @State private var batchSizeText = ""
    @State private var targetText = ""
    @State private var isTargetInputDirty = false
    @FocusState private var isSimulationSpeedFocused: Bool
    @FocusState private var isBatchSizeFocused: Bool
    @FocusState private var isTargetFocused: Bool

    private enum SectionID {
        static let walkingHealth = "walking-health-section"
    }

    private let supportURL: URL? = URL(string: "https://portaly.cc/leoohyeah/support")

    private var tunnelStatus: TunnelStatus {
        switch sharedMapState.isTunnelReachable {
        case true: return .reachable
        case false: return .failed("請確認 LocalDevVPN 已開啟後再重新測試。")
        case nil: return .testing
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        connectionOverview
                        compactStatusRow("配對文件", value: pairingExists ? "已就緒" : "需要導入",
                                         color: pairingExists ? .green : .orange)
                        compactStatusRow("VPN Tunnel", value: tunnelCompactText, color: tunnelCompactColor)
                        compactStatusRow("背景定位權限", value: locationAuthorizationText,
                                         color: locationAuthorizationColor)

                        settingsAction("手動匯入配對文件", icon: "doc.badge.plus",
                                       color: pairingExists ? .accentColor : .orange) {
                            onImportPairing?()
                        }

                        if pairingExists, case .failed = tunnelStatus {
                            Button { sharedMapState.testTunnel(force: true) } label: {
                                Label("重新測試 VPN Tunnel", systemImage: "arrow.clockwise")
                            }
                        }
                    } header: {
                        Text("準備狀態")
                    }

                    Section {
                        HStack {
                            Label("模擬速度", systemImage: "speedometer")
                            Spacer()
                            TextField("0", text: $simulationSpeedText)
                                .multilineTextAlignment(.trailing)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.tint)
                                .frame(width: 64)
                                .focused($isSimulationSpeedFocused)
                                .numericInputStyle()
                                .onChange(of: simulationSpeedText) { _, value in
                                    guard let speed = Double(value) else { return }
                                    let clampedValue = min(max(speed, 0), 1000)
                                    sharedMapState.simulationSpeed = clampedValue
                                    simulationSpeed = clampedValue
                                }
                            Text("km/hr")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: sharedSimulationSpeedBinding,
                            in: 0...1000,
                            step: 1,
                            onEditingChanged: { editing in
                                isDraggingSimulationSpeed = editing
                                if !editing {
                                    DispatchQueue.main.async {
                                        simulationSpeed = sharedMapState.simulationSpeed
                                    }
                                }
                            }
                        )
                    } header: {
                        Text("速度")
                    } footer: {
                        Text("此速度用於 Pro 搖桿移動與路線模擬，範圍為 0–1000 km/hr。")
                    }

                    Section {
                        Picker("到達終點", selection: $completionModeRaw) {
                            ForEach(PathCompletionMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        Picker("路徑規劃", selection: $routePlanningModeRaw) {
                            ForEach(RoutePlanningMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        if routePlanningModeRaw == RoutePlanningMode.orbitEachWaypoint.rawValue {
                            Stepper(value: orbitRadiusBinding, in: 1...39) {
                                HStack {
                                    Text("半徑")
                                    Spacer()
                                    Text("\(routeOrbitRadiusMeters)m")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text("循環模式")
                    } footer: {
                        Text("可分別設定到達終點行為與路徑規劃方式。")
                    }

                    Section {
                        Toggle(isOn: healthWalkingBinding) {
                            Label("步行與健康同步", systemImage: "figure.walk")
                        }
                        .id(SectionID.walkingHealth)
                        Picker("增加頻率", selection: walkingRateBinding) {
                            ForEach(1...3, id: \.self) { rate in
                                Text("\(rate) 步/秒").tag(rate)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!portaly.isPro)
                    } header: {
                        Text("步行與健康")
                    }

                    Section("步數進度") {
                        LabeledContent("目前累計", value: "\(healthCoordinator.pendingSteps) 步")
                        LabeledContent("剩餘步數", value: "\(displayedRemainingSteps) 步")
                    }

                    healthWriteSettingsSection

                    Section {
                        HStack(spacing: 10) {
                            TextField("直接寫入步數", text: $directHealthStepsText)
                                .monospacedDigit()
                                .numericInputStyle()
                                .disabled(!canEditStepSettings)
                            Button("GO") {
                                KeyboardDismissal.dismiss()
                                writeDirectHealthSteps()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canEditStepSettings || directHealthStepCount == nil || isWritingDirectSteps)
                        }
                    } header: {
                        Text("直接寫入健康")
                    } footer: {
                        Text("輸入步數後按 GO，會立即新增一筆 Apple 健康步數資料。")
                    }

                    Section("資料管理") {
                        settingsAction(savedItemsTitle, icon: "bookmark.fill") {
                            onOpenSavedItems?()
                        }
                        settingsAction("匯入座標路線", icon: "square.and.arrow.down") {
                            onImportCoordinates?()
                        }
                    }

                    Section("技術資訊") {
                        HStack {
                            Label("程式版本", systemImage: "app.badge")
                            Spacer()
                            Text(appVersion).foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        NavigationLink {
                            SubscriptionAccountView()
                        } label: {
                            Label("帳號與 Pro 訂閱", systemImage: "person.crop.circle.badge.checkmark")
                        }

                        Button {
                            if let supportURL {
                                openURL(supportURL)
                            } else {
                                supportAlertTitle = "贊助 UFOGeo"
                                supportAlertMessage = "贊助連結尚未設定。"
                                showSupportAlert = true
                            }
                        } label: {
                            Label("贊助 UFOGeo", systemImage: "heart.fill")
                        }
                    } header: {
                        Text("支持 UFOGeo")
                    } footer: {
                        Text("透過 Portaly 安全結帳；付款、續訂取消與管理變更都會以伺服器回呼同步到 App。也歡迎單次贊助作者。")
                    }
                }
                .onAppear {
                    scrollToRequestedSection(proxy)
                }
                .onChange(of: initialScrollTarget) { _, _ in
                    scrollToRequestedSection(proxy)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        commitSimulationSpeedInput()
                        commitBatchSizeInput()
                        commitTargetInput()
                        dismiss()
                    }
                }
            }
            .onAppear {
                refreshConnectionStatus()
                healthCoordinator.refreshEntitlement()
                let speed = min(max(simulationSpeed, 0), 1000)
                sharedMapState.simulationSpeed = speed
                simulationSpeedText = String(Int(speed))
                simulationSpeedSlider = speed
                batchSizeText = String(healthCoordinator.batchSize)
                targetText = String(healthCoordinator.target)
                isTargetInputDirty = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .pairingFileDidChange)) { _ in
                refreshConnectionStatus()
            }
            .onChange(of: simulationSpeed) { _, value in
                sharedMapState.simulationSpeed = min(max(value, 0), 1000)
                if !isDraggingSimulationSpeed {
                    simulationSpeedSlider = value
                }
                guard !isSimulationSpeedFocused else { return }
                simulationSpeedText = String(Int(min(max(value, 0), 1000)))
            }
            .onChange(of: healthCoordinator.batchSize) { _, value in
                guard !isBatchSizeFocused else { return }
                batchSizeText = String(value)
            }
            .onChange(of: healthCoordinator.target) { _, value in
                guard !isTargetFocused, !isTargetInputDirty else { return }
                targetText = String(value)
                isTargetInputDirty = false
            }
            .onChange(of: portaly.isPro) { _, _ in
                healthCoordinator.refreshEntitlement()
                guard !isTargetFocused, !isTargetInputDirty else { return }
                targetText = String(healthCoordinator.target)
            }
            .alert(healthAlertTitle, isPresented: $showHealthPermissionAlert) {
                Button("確定", role: .cancel) { }
            } message: {
                Text(healthPermissionMessage)
            }
            .alert(supportAlertTitle, isPresented: $showSupportAlert) {
                Button("確定", role: .cancel) { }
            } message: {
                Text(supportAlertMessage)
            }
        }
    }

    private func scrollToRequestedSection(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll,
              initialScrollTarget == .walkingHealth else { return }
        didInitialScroll = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(SectionID.walkingHealth, anchor: .top)
            }
        }
    }

    private var healthWriteSettingsSection: some View {
        Section {
            stepInputRow(
                "每次累計寫入",
                text: $batchSizeText,
                isFocused: $isBatchSizeFocused,
                onCommit: commitBatchSizeInput
            )
            .disabled(!canEditStepSettings)
            stepInputRow(
                "預計寫入總數",
                text: targetInputBinding,
                isFocused: $isTargetFocused,
                onCommit: commitTargetInput
            )
            .disabled(!canEditStepSettings)
        } header: {
            Text("寫入設定")
        } footer: {
            Text(
                canEditStepSettings
                    ? "Pro 可自訂每日預計寫入總數；設定會保留在本機。"
                    : "Free 每次固定累計寫入 1000 步、每日最多 10000 步；升級 Pro 後會恢復先前保存的設定。"
            )
        }
    }

    private var orbitRadiusBinding: Binding<Int> {
        Binding(
            get: { min(max(routeOrbitRadiusMeters, 1), 39) },
            set: { routeOrbitRadiusMeters = min(max($0, 1), 39) }
        )
    }

    private func commitSimulationSpeedInput() {
        let speed = min(max(Double(simulationSpeedText) ?? simulationSpeed, 0), 1000)
        sharedMapState.simulationSpeed = speed
        simulationSpeed = speed
        simulationSpeedText = String(Int(speed))
    }

    private var sharedSimulationSpeedBinding: Binding<Double> {
        Binding(
            get: { sharedMapState.simulationSpeed },
            set: { value in
                let clampedValue = min(max(value, 0), 1000)
                sharedMapState.simulationSpeed = clampedValue
                simulationSpeedSlider = clampedValue
                if !isSimulationSpeedFocused {
                    simulationSpeedText = String(Int(clampedValue))
                }
            }
        )
    }

    private var canEditStepSettings: Bool {
        portaly.isPro
    }

    private var directHealthStepCount: Int? {
        guard let value = Int(directHealthStepsText), (1...1_000_000).contains(value) else { return nil }
        return value
    }

    private func writeDirectHealthSteps() {
        let portaly = PortalyCheckoutService.shared
        guard portaly.isPro else {
            healthAlertTitle = PortalyCheckoutService.proFeatureAlertTitle
            healthPermissionMessage = PortalyCheckoutService.proFeatureAlertMessage
            showHealthPermissionAlert = true
            return
        }

        guard let steps = directHealthStepCount else { return }
        isWritingDirectSteps = true
        Task { @MainActor in
            guard await portaly.refreshProEntitlementIfNeeded() else {
                isWritingDirectSteps = false
                healthAlertTitle = PortalyCheckoutService.proFeatureAlertTitle
                healthPermissionMessage = PortalyCheckoutService.proFeatureAlertMessage
                showHealthPermissionAlert = true
                return
            }
            performDirectHealthWrite(steps)
        }
    }

    private func performDirectHealthWrite(_ steps: Int) {
        HealthStepSyncManager.shared.requestAuthorizationIfNeeded { granted in
            guard granted else {
                DispatchQueue.main.async {
                    isWritingDirectSteps = false
                    healthAlertTitle = "無法寫入健康"
                    healthPermissionMessage = "需要允許 UFOGeo 寫入步數。請到系統設定或健康 App 開啟步數權限。"
                    showHealthPermissionAlert = true
                }
                return
            }

            HealthStepSyncManager.shared.writeSteps(steps) { result in
                DispatchQueue.main.async {
                    isWritingDirectSteps = false
                    switch result {
                    case .success:
                        directHealthStepsText = ""
                        healthAlertTitle = "寫入完成"
                        healthPermissionMessage = "已將 \(steps) 步寫入 Apple 健康。"
                    case .failure(let error):
                        healthAlertTitle = "寫入失敗"
                        healthPermissionMessage = error.localizedDescription
                    }
                    showHealthPermissionAlert = true
                }
            }
        }
    }

    private func compactStatusRow(_ title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Circle().fill(color).frame(width: 8, height: 8)
            Text(value).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var tunnelCompactText: String {
        switch tunnelStatus {
        case .testing: return "測試中"
        case .reachable: return "正常"
        case .failed: return "無法連線"
        }
    }

    private var tunnelCompactColor: Color {
        switch tunnelStatus {
        case .testing: return .yellow
        case .reachable: return .green
        case .failed: return .red
        }
    }

    private func stepInputRow(
        _ title: String,
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("步數", text: text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 110)
                .focused(isFocused)
                .numericInputStyle()
                .onSubmit(onCommit)
                .onChange(of: isFocused.wrappedValue) { _, focused in
                    if !focused { onCommit() }
                }
            Text("步").foregroundStyle(.secondary)
        }
    }

    private func commitBatchSizeInput() {
        guard canEditStepSettings else {
            batchSizeText = String(healthCoordinator.batchSize)
            return
        }

        let value = max(Int(batchSizeText) ?? healthCoordinator.batchSize, 1)
        healthCoordinator.updateBatchSize(value)
        batchSizeText = String(healthCoordinator.batchSize)
    }

    private var targetInputBinding: Binding<String> {
        Binding(
            get: { targetText },
            set: { value in
                if value != targetText {
                    isTargetInputDirty = true
                }
                targetText = value
            }
        )
    }

    private func commitTargetInput() {
        guard canEditStepSettings else {
            targetText = String(healthCoordinator.target)
            isTargetInputDirty = false
            return
        }

        guard isTargetInputDirty else {
            targetText = String(healthCoordinator.target)
            return
        }

        guard let enteredTarget = Int(targetText), enteredTarget >= 0 else {
            targetText = String(healthCoordinator.target)
            isTargetInputDirty = false
            return
        }

        let target = max(enteredTarget, 1)
        healthCoordinator.updateTarget(target)
        targetText = String(healthCoordinator.target)
        isTargetInputDirty = false
    }

    private var displayedRemainingSteps: Int {
        guard isTargetFocused,
              isTargetInputDirty,
              let previewTarget = Int(targetText),
              previewTarget > 0 else {
            return healthCoordinator.remainingSteps
        }
        return previewTarget
    }

    private func showProFeatureAlert() {
        healthAlertTitle = PortalyCheckoutService.proFeatureAlertTitle
        healthPermissionMessage = PortalyCheckoutService.proFeatureAlertMessage
        showHealthPermissionAlert = true
    }

    private var walkingRateBinding: Binding<Int> {
        Binding(
            get: { healthCoordinator.stepsPerSecond },
            set: { value in
                guard portaly.isPro else {
                    showProFeatureAlert()
                    return
                }
                healthCoordinator.updateRate(value)
            }
        )
    }

    private var healthWalkingBinding: Binding<Bool> {
        Binding(
            get: { healthCoordinator.isEnabled },
            set: { enabled in
                guard enabled else {
                    healthCoordinator.setEnabled(false)
                    return
                }
                healthCoordinator.setEnabled(true) { granted in
                    guard !granted else { return }
                    healthAlertTitle = "健康權限"
                    healthPermissionMessage = "需要允許 UFOGeo 寫入步數。請到系統設定或健康 App 開啟步數權限。"
                    showHealthPermissionAlert = true
                }
            }
        )
    }

    private var connectionOverview: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(connectionOverviewColor.opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: connectionOverviewIcon)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(connectionOverviewColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(connectionOverviewTitle)
                    .font(.headline)
                Text(connectionOverviewDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var connectionOverviewColor: Color {
        if !pairingExists { return .orange }
        switch tunnelStatus {
        case .reachable: return .green
        case .failed: return .red
        default: return .accentColor
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

    private var connectionOverviewIcon: String {
        if !pairingExists { return "doc.badge.ellipsis" }
        switch tunnelStatus {
        case .reachable: return "checkmark.circle.fill"
        case .failed: return "wifi.exclamationmark"
        default: return "iphone.and.arrow.forward"
        }
    }

    private var connectionOverviewTitle: String {
        if !pairingExists { return "需要配對文件" }
        switch tunnelStatus {
        case .reachable: return "連線準備完成"
        case .failed: return "Tunnel 連線失敗"
        case .testing: return "正在檢查連線"
        }
    }

    private var connectionOverviewDetail: String {
        if !pairingExists { return "先導入此 iPhone 的配對文件，才能啟動定位或路線。" }
        switch tunnelStatus {
        case .reachable: return "UFOGeo 已可連接本機 VPN Tunnel。"
        case .failed: return "確認已連上 Wi-Fi 並開啟 LocalDevVPN，再重新測試。"
        case .testing: return "正在確認 LocalDevVPN 是否可以連線。"
        }
    }

    private var locationAuthorizationText: String {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: return "已就緒（永遠）"
        case .authorizedWhenInUse: return "需改為「永遠」"
        case .denied: return "已拒絕"
        case .restricted: return "受限制"
        case .notDetermined: return "尚未詢問"
        @unknown default: return "未知"
        }
    }

    private var locationAuthorizationColor: Color {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .orange
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private func settingsAction(
        _ title: String,
        icon: String,
        color: Color = .accentColor,
        action: (() -> Void)?
    ) -> some View {
        if let action {
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
            } label: {
                Label(title, systemImage: icon)
                    .foregroundStyle(color)
            }
        }
    }
}

#Preview {
    CompatibilityCheckView()
        .environmentObject(SharedLocationMapState())
}
