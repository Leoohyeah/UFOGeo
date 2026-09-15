import Foundation

/// The host that is currently running UFOGeo.
///
/// LiveContainer does not provide a public runtime API to guest apps. Keep the
/// detection read-only and conservative so the UI never presents a host name
/// based on a weak or guessed signal.
enum RuntimeEnvironment: Equatable {
    case liveContainer
    case standalone
    case unknown

    static var current: RuntimeEnvironment {
        detect()
    }

    static func detect(
        bundlePath: String = Bundle.main.bundlePath,
        homePath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RuntimeEnvironment {
        let normalizedBundlePath = bundlePath.lowercased()
        let normalizedHomePath = homePath.lowercased()

        // These variables are set by LiveContainer before it launches a guest
        // app. They are intentionally read only; no private API or probing is
        // needed.
        let hasLiveContainerHomeMarker = hasValue(environment["LC_HOME_PATH"])
        let hasLiveContainerTweakMarker = hasValue(environment["LC_GLOBAL_TWEAKS_FOLDER"])

        // Guest app bundles and data containers are stored below these paths.
        // The second path also covers shared LiveContainer app storage.
        let hasLiveContainerBundlePath = normalizedBundlePath.contains("/documents/applications/")
            || normalizedBundlePath.contains("/livecontainer/applications/")
        let hasLiveContainerHomePath = normalizedHomePath.contains("/documents/data/application/")
            || normalizedHomePath.contains("/livecontainer/data/application/")

        // One exact LC environment marker is already strong evidence. A path
        // marker is independently sufficient when the bundle was relocated by
        // a custom/external container, while combinations cover older or
        // partially configured LiveContainer launches.
        let liveContainerEvidence = [
            hasLiveContainerHomeMarker ? 2 : 0,
            hasLiveContainerTweakMarker ? 2 : 0,
            hasLiveContainerBundlePath ? 2 : 0,
            hasLiveContainerHomePath ? 1 : 0
        ].reduce(0, +)
        if liveContainerEvidence >= 2 {
            return .liveContainer
        }

        let hasStandardBundlePath = normalizedBundlePath.contains(
            "/var/containers/bundle/application/"
        ) || normalizedBundlePath.contains("/build/products/")
        let hasStandardHomePath = normalizedHomePath.contains(
            "/var/mobile/containers/data/application/"
        ) || normalizedHomePath.contains("/coresimulator/devices/")

        if hasStandardBundlePath && hasStandardHomePath {
            return .standalone
        }

        return .unknown
    }

    var displayName: String {
        switch self {
        case .liveContainer:
            return "LiveContainer"
        case .standalone:
            return "獨立安裝"
        case .unknown:
            return "無法判定"
        }
    }

    /// The app name that iOS shows in Location Services for this runtime.
    /// Unknown deliberately has no guessed host name.
    var locationPermissionHostName: String? {
        switch self {
        case .liveContainer:
            return "LiveContainer"
        case .standalone:
            return "UFOGeo"
        case .unknown:
            return nil
        }
    }

    var locationPermissionGuidance: String {
        if let hostName = locationPermissionHostName {
            return "請到「設定」>「隱私權與安全性」>「定位服務」>「\(hostName)」，允許定位並選擇「永遠」。"
        }

        return "請到「設定」>「隱私權與安全性」>「定位服務」，找到執行 UFOGeo 的宿主 App 並允許定位，然後選擇「永遠」。"
    }

    var deniedLocationPermissionMessage: String {
        "定位授權被拒絕。\n\(locationPermissionGuidance)"
    }

    private static func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
