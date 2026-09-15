import Testing
@testable import UFOGeo

@Suite("Runtime environment detection")
struct RuntimeEnvironmentTests {
    @Test("detects LiveContainer from an injected host marker")
    func detectsLiveContainerFromInjectedMarker() {
        let result = RuntimeEnvironment.detect(
            bundlePath: "/var/mobile/Containers/Data/Application/guest/UFOGeo.app",
            homePath: "/var/mobile/Containers/Data/Application/guest",
            environment: ["LC_HOME_PATH": "/var/mobile/Containers/Data/Application/guest"]
        )

        #expect(result == .liveContainer)
    }

    @Test("detects LiveContainer from its guest bundle path")
    func detectsLiveContainerFromInjectedBundlePath() {
        let result = RuntimeEnvironment.detect(
            bundlePath: "/var/mobile/Documents/Applications/guest/UFOGeo.app",
            homePath: "/var/mobile/Containers/Data/Application/guest",
            environment: [:]
        )

        #expect(result == .liveContainer)
    }

    @Test("detects standalone iOS installation from injected paths")
    func detectsStandaloneInstallation() {
        let result = RuntimeEnvironment.detect(
            bundlePath: "/private/var/containers/Bundle/Application/app/UFOGeo.app",
            homePath: "/private/var/mobile/Containers/Data/Application/app",
            environment: [:]
        )

        #expect(result == .standalone)
    }

    @Test("returns unknown when injected signals identify neither runtime")
    func returnsUnknownWithoutRecognizedSignals() {
        let result = RuntimeEnvironment.detect(
            bundlePath: "/tmp/UFOGeo.app",
            homePath: "/tmp/UFOGeo-data",
            environment: [:]
        )

        #expect(result == .unknown)
    }

    @Test("names the host only when it is known")
    func locationGuidanceUsesKnownHostNames() {
        #expect(RuntimeEnvironment.liveContainer.locationPermissionHostName == "LiveContainer")
        #expect(RuntimeEnvironment.standalone.locationPermissionHostName == "UFOGeo")
        #expect(RuntimeEnvironment.unknown.locationPermissionHostName == nil)

        #expect(RuntimeEnvironment.liveContainer.locationPermissionGuidance.contains("LiveContainer"))
        #expect(RuntimeEnvironment.standalone.locationPermissionGuidance.contains("UFOGeo"))
        #expect(RuntimeEnvironment.unknown.locationPermissionGuidance.contains("宿主 App"))

        #expect(RuntimeEnvironment.liveContainer.deniedLocationPermissionMessage.hasPrefix("定位授權被拒絕。"))
        #expect(RuntimeEnvironment.liveContainer.deniedLocationPermissionMessage.contains("LiveContainer"))
    }
}
