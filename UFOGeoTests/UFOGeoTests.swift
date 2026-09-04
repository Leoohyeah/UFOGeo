//
//  UFOGeoTests.swift
//  UFOGeoTests
//
//  Created by Stephen on 3/26/25.
//

import Foundation
import Testing
import CoreLocation
@testable import UFOGeo

struct UFOGeoTests {

    @Test func searchCompletionAcceptsOnlyTheCurrentQueryGenerationAndSession() {
        let currentSessionID = UUID()
        let staleSessionID = UUID()

        #expect(
            LocationSearchCompleter.shouldAcceptResults(
                callbackGeneration: 2,
                currentGeneration: 2,
                callbackQuery: "台北車站",
                currentQuery: " 台北車站 ",
                callbackSessionID: currentSessionID,
                currentSessionID: currentSessionID
            )
        )
        #expect(
            !LocationSearchCompleter.shouldAcceptResults(
                callbackGeneration: 1,
                currentGeneration: 2,
                callbackQuery: "台北",
                currentQuery: "台北車站",
                callbackSessionID: staleSessionID,
                currentSessionID: currentSessionID
            )
        )
        #expect(
            !LocationSearchCompleter.shouldAcceptResults(
                callbackGeneration: 1,
                currentGeneration: 3,
                callbackQuery: "台北",
                currentQuery: "台北",
                callbackSessionID: staleSessionID,
                currentSessionID: currentSessionID
            )
        )
        #expect(
            !LocationSearchCompleter.shouldAcceptResults(
                callbackGeneration: 2,
                currentGeneration: 2,
                callbackQuery: "台北",
                currentQuery: "高雄",
                callbackSessionID: currentSessionID,
                currentSessionID: currentSessionID
            )
        )
    }

    @Test func membershipPollingRunsOnlyForActiveForegroundProUse() {
        #expect(
            MainTabView.shouldRunPeriodicMembershipRefresh(
                isSignedIn: true,
                isSceneActive: true,
                isPro: true,
                isMovementActive: true,
                isHealthGenerating: false
            )
        )
        #expect(
            MainTabView.shouldRunPeriodicMembershipRefresh(
                isSignedIn: true,
                isSceneActive: true,
                isPro: true,
                isMovementActive: false,
                isHealthGenerating: true
            )
        )
        for input in [
            (false, true, true, true, false),
            (true, false, true, true, false),
            (true, true, false, true, false),
            (true, true, true, false, false)
        ] {
            #expect(
                !MainTabView.shouldRunPeriodicMembershipRefresh(
                    isSignedIn: input.0,
                    isSceneActive: input.1,
                    isPro: input.2,
                    isMovementActive: input.3,
                    isHealthGenerating: input.4
                )
            )
        }
    }

    @Test func inlineCoordinateParserAcceptsValidLinesAndRejectsInvalidOnes() async throws {
        let coordinates = CoordinateImportParser.parseInline(
            "25.0330, 121.5654\ninvalid\n-33.8688 151.2093"
        )

        #expect(coordinates.count == 2)
        #expect(abs(coordinates[0].latitude - 25.0330) < 0.000_001)
        #expect(abs(coordinates[0].longitude - 121.5654) < 0.000_001)
        #expect(abs(coordinates[1].latitude + 33.8688) < 0.000_001)
        #expect(abs(coordinates[1].longitude - 151.2093) < 0.000_001)
    }

    @Test func inlineCoordinateParserRejectsOutOfRangeCoordinates() async throws {
        let coordinates = CoordinateImportParser.parseInline(
            "91, 121\n25, 181\n-91, -181"
        )

        #expect(coordinates.isEmpty)
    }

    @Test func copiedRouteCoordinatesRoundTripWithoutPointLabels() {
        let copiedRouteText = [
            CoordinateDisplayFormatter.string(latitude: 25.033012, longitude: 121.565401),
            CoordinateDisplayFormatter.string(latitude: -33.868812, longitude: 151.209298)
        ].joined(separator: "\n")

        let coordinates = CoordinateImportParser.parseInline(copiedRouteText)

        #expect(coordinates.count == 2)
        #expect(abs(coordinates[0].latitude - 25.033012) < 0.000_001)
        #expect(abs(coordinates[0].longitude - 121.565401) < 0.000_001)
        #expect(abs(coordinates[1].latitude + 33.868812) < 0.000_001)
        #expect(abs(coordinates[1].longitude - 151.209298) < 0.000_001)
    }

    @Test func routeFileParserSupportsCommonFormats() throws {
        let samples: [(String, String)] = [
            ("gpx", """
            <?xml version="1.0"?><gpx><trk><trkseg>
            <trkpt lat="25.033" lon="121.5654"/><trkpt lat="25.034" lon="121.566"/>
            </trkseg></trk></gpx>
            """),
            ("kml", """
            <?xml version="1.0"?><kml><Placemark><LineString><coordinates>
            121.5654,25.033,0 121.566,25.034,0
            </coordinates></LineString></Placemark></kml>
            """),
            ("geojson", """
            {"type":"LineString","coordinates":[[121.5654,25.033],[121.566,25.034]]}
            """),
            ("json", """
            [{"latitude":25.033,"longitude":121.5654},{"latitude":25.034,"longitude":121.566}]
            """),
            ("csv", "latitude,longitude\n25.033,121.5654\n25.034,121.566"),
            ("txt", "25.033, 121.5654\n25.034, 121.566")
        ]

        for (fileExtension, contents) in samples {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }

            let coordinates = try CoordinateImportParser.parse(url: url)
            #expect(coordinates.count == 2, "\(fileExtension) 應解析出兩個路點")
            #expect(abs(coordinates[0].latitude - 25.033) < 0.000_001)
            #expect(abs(coordinates[0].longitude - 121.5654) < 0.000_001)
        }
    }

    @Test func routeFilePickerUsesOnlyGPXExtension() {
        let extensions = Set(
            CoordinateImportParser.gpxContentTypes.compactMap(\.preferredFilenameExtension)
        )

        #expect(extensions == Set(["gpx"]))
        #expect(!extensions.contains("plist"))
        #expect(!extensions.contains("mobiledevicepairing"))
        #expect(!extensions.contains("mobiledevicepair"))
    }

    @Test func routeFileParserRejectsPairingAndUnknownExtensionsBeforeReadingContents() throws {
        let unsupportedExtensions = [
            "plist", "mobiledevicepairing", "mobiledevicepair", "xml", ""
        ]

        for fileExtension in unsupportedExtensions {
            var url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            if !fileExtension.isEmpty {
                url.appendPathExtension(fileExtension)
            }
            try "25.033, 121.5654\n25.034, 121.566".write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(throws: CoordinateImportError.self) {
                try CoordinateImportParser.parse(url: url)
            }
        }
    }

    @Test func savedItemNameMatchingSupportsChineseAndWidthDifferences() {
        #expect(SavedItemNameMatcher.matches("台北路線", " 台北路線 "))
        #expect(SavedItemNameMatcher.matches("路線 #1", "路線 ＃1"))
        #expect(SavedItemNameMatcher.matches("Route A", "route a"))
        #expect(!SavedItemNameMatcher.matches("台北路線", "臺北路線"))
    }

    @Test func routeNameGeneratorUsesFirstAvailableNumber() {
        let routes = [
            SimulationRoute(name: "路線 #1", points: [], createdDate: Date()),
            SimulationRoute(name: "路線 #3", points: [], createdDate: Date())
        ]
        #expect(RouteNameGenerator.nextAvailableName(in: routes) == "路線 #2")
    }

    @Test func routeMapSuppressesZoomImmediatelyAfterInsertionOnlyWhileEditing() {
        #expect(
            RouteEditingMapInteractionPolicy.shouldSuppressZoomAfterPointInsertion(
                isEditing: true,
                isSimulationActive: false
            )
        )
        #expect(
            !RouteEditingMapInteractionPolicy.shouldSuppressZoomAfterPointInsertion(
                isEditing: false,
                isSimulationActive: false
            )
        )
        #expect(
            !RouteEditingMapInteractionPolicy.shouldSuppressZoomAfterPointInsertion(
                isEditing: true,
                isSimulationActive: true
            )
        )
    }

    @Test func routeMapZoomSuppressionRestoresAfterExpirationWhenGestureSettled() {
        #expect(
            RouteEditingMapInteractionPolicy.canRestoreZoomAfterSuppression(
                isSuppressed: true,
                tokenMatches: true,
                isSimulationActive: false,
                isMapGestureActive: false
            )
        )
        #expect(
            !RouteEditingMapInteractionPolicy.canRestoreZoomAfterSuppression(
                isSuppressed: true,
                tokenMatches: false,
                isSimulationActive: false,
                isMapGestureActive: false
            )
        )
        #expect(
            !RouteEditingMapInteractionPolicy.canRestoreZoomAfterSuppression(
                isSuppressed: true,
                tokenMatches: true,
                isSimulationActive: false,
                isMapGestureActive: true
            )
        )
    }

    @Test func routeMapZoomSuppressionNeverRestoresDuringSimulation() {
        #expect(
            !RouteEditingMapInteractionPolicy.canRestoreZoomAfterSuppression(
                isSuppressed: true,
                tokenMatches: true,
                isSimulationActive: true,
                isMapGestureActive: false
            )
        )
    }

    @Test func routeMapCenterRequestControlsAutomaticSimulationFollowing() {
        let simulated = CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654)
        let inspected = CLLocationCoordinate2D(latitude: 22.6273, longitude: 120.3014)

        #expect(
            RouteEditingMapInteractionPolicy.shouldFollowSimulationAfterCenterRequest(
                isSimulationActive: true,
                requestedCoordinate: simulated,
                simulatedCoordinate: simulated,
                resumesRouteFollowing: false
            )
        )
        #expect(
            !RouteEditingMapInteractionPolicy.shouldFollowSimulationAfterCenterRequest(
                isSimulationActive: true,
                requestedCoordinate: inspected,
                simulatedCoordinate: simulated,
                resumesRouteFollowing: false
            )
        )
        #expect(
            RouteEditingMapInteractionPolicy.shouldFollowSimulationAfterCenterRequest(
                isSimulationActive: false,
                requestedCoordinate: inspected,
                simulatedCoordinate: simulated,
                resumesRouteFollowing: false
            )
        )
        #expect(
            RouteEditingMapInteractionPolicy.shouldFollowSimulationAfterCenterRequest(
                isSimulationActive: true,
                requestedCoordinate: inspected,
                simulatedCoordinate: simulated,
                resumesRouteFollowing: true
            )
        )
    }

    @Test func routeHistorySelectionPushesOnlyWhileRouteIsHeld() {
        #expect(
            RouteHistorySelectionPolicy.shouldPauseAndPush(
                isSimulating: true,
                isPaused: false
            )
        )
        #expect(
            RouteHistorySelectionPolicy.shouldPauseAndPush(
                isSimulating: false,
                isPaused: true
            )
        )
        #expect(
            !RouteHistorySelectionPolicy.shouldPauseAndPush(
                isSimulating: false,
                isPaused: false
            )
        )
    }

    @Test @MainActor func routeUnfavoriteRemainsAvailableDuringCurrentSession() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        let manager = JoystickModeManager(defaults: defaults)
        let route = SimulationRoute(name: "路線 #1", points: [], createdDate: Date(), isFavorite: true)

        manager.saveRoute(route)
        manager.toggleFavorite(route)
        manager.reloadRoutes()
        let secondManager = JoystickModeManager(defaults: defaults)
        secondManager.reloadRoutes()

        #expect(manager.routes.count == 1)
        #expect(manager.routes[0].isFavorite == false)
        #expect(secondManager.routes.count == 1)
        #expect(secondManager.routes[0].isFavorite == false)
        #expect(RouteNameGenerator.nextAvailableName(in: manager.routes) == "路線 #2")
    }

    @Test @MainActor func routeLaunchCleanupKeepsFavoritesAndRuntimeReloadDoesNotClean() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        let manager = JoystickModeManager(defaults: defaults)
        let transientRoute = SimulationRoute(name: "路線 #1", points: [], createdDate: Date())
        let favoriteRoute = SimulationRoute(
            name: "路線 #2",
            points: [],
            createdDate: Date(),
            isFavorite: true
        )
        manager.saveRoute(transientRoute)
        manager.saveRoute(favoriteRoute)

        #expect(
            SimulationRouteLaunchCleanupPolicy.routesToKeepOnNewProcess(
                [transientRoute, favoriteRoute]
            ).map(\.id) == [favoriteRoute.id]
        )
        JoystickModeManager.performRouteLaunchCleanup(defaults: defaults)
        manager.reloadRoutes()
        #expect(manager.routes.map(\.id) == [favoriteRoute.id])
        #expect(RouteNameGenerator.nextAvailableName(in: manager.routes) == "路線 #1")

        // A route created and unfavorited after launch cleanup remains in this
        // process, including after another manager is initialized/reloaded.
        let runtimeRoute = SimulationRoute(name: "路線 #1", points: [], createdDate: Date())
        manager.saveRoute(runtimeRoute)
        let secondManager = JoystickModeManager(defaults: defaults)
        secondManager.reloadRoutes()
        #expect(secondManager.routes.contains(where: { $0.id == runtimeRoute.id }))

        // An explicit second launch cleanup removes the route that was created
        // and left unfavorited during the previous process.
        JoystickModeManager.performRouteLaunchCleanup(defaults: defaults)
        secondManager.reloadRoutes()
        #expect(!secondManager.routes.contains(where: { $0.id == runtimeRoute.id }))
        #expect(RouteNameGenerator.nextAvailableName(in: secondManager.routes) == "路線 #1")
    }

    @Test func routeRequiresAtLeastTwoPoints() async throws {
        let emptyRoute = SimulationRoute(name: "Empty", points: [], createdDate: Date())
        let onePointRoute = SimulationRoute(
            name: "One",
            points: [PathPoint(coordinate: CLLocationCoordinate2D(latitude: 25, longitude: 121), order: 0)],
            createdDate: Date()
        )

        #expect(emptyRoute.isValid == false)
        #expect(onePointRoute.isValid == false)

        let validRoute = SimulationRoute(
            name: "Valid",
            points: [
                PathPoint(coordinate: .init(latitude: 25, longitude: 121), order: 0),
                PathPoint(coordinate: .init(latitude: 25.001, longitude: 121.001), order: 1)
            ],
            createdDate: Date()
        )
        #expect(validRoute.isValid)
    }

    @Test @MainActor func speedUsesKilometersPerHour() {
        #expect(abs(JoystickModeManager.metersPerSecond(forKilometersPerHour: 36) - 10) < 0.000_001)
        #expect(JoystickModeManager.metersPerSecond(forKilometersPerHour: -1) == 0)
    }

    @Test func routeCompletionModesHaveStableTitles() {
        #expect(PathCompletionMode.returnToStart.title == "回到起點")
        #expect(PathCompletionMode.stopAtLast.title == "停在終點")
        #expect(PathCompletionMode.loop.title == "自動循環")
    }

    @Test func routeCompletionNotificationsMatchCompletionMode() throws {
        let returned = try #require(
            RouteCompletionNotificationDescriptor.make(
                routeName: "河濱路線",
                completionMode: .returnToStart
            )
        )
        #expect(returned.title == "路線模擬已回到起點")
        #expect(returned.body == "「河濱路線」已完成路線並回到起點")

        let stopped = try #require(
            RouteCompletionNotificationDescriptor.make(
                routeName: "河濱路線",
                completionMode: .stopAtLast
            )
        )
        #expect(stopped.title == "路線模擬已達終點")
        #expect(stopped.body == "「河濱路線」已完成路線")
        #expect(
            RouteCompletionNotificationDescriptor.make(
                routeName: "河濱路線",
                completionMode: .loop
            ) == nil
        )
    }

    @Test func historyStoreKeepsOnlyNewestHundredRecords() {
        let original = LocationHistoryStore.load()
        defer { LocationHistoryStore.save(original) }

        let records = (0..<105).map { index in
            LocationHistoryRecord(
                kind: .location,
                latitude: 25 + Double(index) / 10_000,
                longitude: 121,
                date: Date(timeIntervalSince1970: Double(index)),
                routeName: nil
            )
        }
        LocationHistoryStore.save(records)
        let saved = LocationHistoryStore.load()

        #expect(saved.count == 100)
        #expect(saved.first?.date == records[104].date)
        #expect(saved.last?.date == records[5].date)
    }

    @Test func locationBookmarkRoundTripsThroughJSON() throws {
        let bookmark = LocationBookmark(name: "台北", latitude: 25.033, longitude: 121.5654)
        let data = try JSONEncoder().encode(bookmark)
        let decoded = try JSONDecoder().decode(LocationBookmark.self, from: data)

        #expect(decoded.id == bookmark.id)
        #expect(decoded.name == bookmark.name)
        #expect(decoded.latitude == bookmark.latitude)
        #expect(decoded.longitude == bookmark.longitude)
    }

    @Test func sharedStateBlocksTabSwitchDuringSimulation() {
        let state = SharedLocationMapState()
        #expect(state.canSwitchTabs)
        state.isSimulationActive = true
        #expect(state.canSwitchTabs == false)
    }

    @Test func sharedStateBlocksRouteAndCoordinateMutationDuringStartAndStopTransitions() {
        let state = SharedLocationMapState()

        state.isSimulationTransitioning = true
        #expect(state.isSimulationInteractionLocked)
        #expect(state.canSwitchTabs == false)

        state.isSimulationTransitioning = false
        state.isSimulationActive = true
        #expect(state.isSimulationInteractionLocked)
        #expect(state.canSwitchTabs == false)
    }

    @Test func launchCoordinateKeepsFirstValidCoordinate() {
        let state = SharedLocationMapState()
        let first = CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654)
        let later = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)

        #expect(state.captureLaunchCoordinateIfNeeded(first))
        #expect(!state.captureLaunchCoordinateIfNeeded(later))
        #expect(state.launchCoordinate?.latitude == first.latitude)
        #expect(state.launchCoordinate?.longitude == first.longitude)
    }

    @Test func launchCoordinateRejectsNonFiniteAndOutOfRangeCoordinates() {
        let state = SharedLocationMapState()
        let invalidCoordinates = [
            CLLocationCoordinate2D(latitude: .nan, longitude: 121),
            CLLocationCoordinate2D(latitude: 25, longitude: .infinity),
            CLLocationCoordinate2D(latitude: 91, longitude: 121),
            CLLocationCoordinate2D(latitude: 25, longitude: 181)
        ]

        for coordinate in invalidCoordinates {
            #expect(!state.captureLaunchCoordinateIfNeeded(coordinate))
        }
        #expect(state.launchCoordinate == nil)
    }

    @Test func returningToLaunchLocationUpdatesSelectionAndCenterRequest() {
        let state = SharedLocationMapState()
        let launch = CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654)
        state.captureLaunchCoordinateIfNeeded(launch)
        state.selectedCoordinate = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)

        let returned = state.returnToLaunchLocation()

        #expect(returned?.latitude == launch.latitude)
        #expect(returned?.longitude == launch.longitude)
        #expect(state.selectedCoordinate?.latitude == launch.latitude)
        #expect(state.selectedCoordinate?.longitude == launch.longitude)
        #expect(state.nativeMapCenterRequest?.coordinate.latitude == launch.latitude)
        #expect(state.nativeMapCenterRequest?.coordinate.longitude == launch.longitude)
        #expect(state.nativeMapCenterRequest?.preserveZoom == false)
    }

    @Test func launchCoordinateReturnPolicyDistinguishesRouteStates() {
        #expect(
            LaunchCoordinateReturnPolicy.routeAction(
                isStarting: false,
                isSimulating: false,
                isPaused: false
            ) == .recenterOnly
        )
        #expect(
            LaunchCoordinateReturnPolicy.routeAction(
                isStarting: false,
                isSimulating: true,
                isPaused: false
            ) == .stopAndRecenter
        )
        #expect(
            LaunchCoordinateReturnPolicy.routeAction(
                isStarting: false,
                isSimulating: false,
                isPaused: true
            ) == .stopAndRecenter
        )
        #expect(
            LaunchCoordinateReturnPolicy.routeAction(
                isStarting: true,
                isSimulating: false,
                isPaused: false
            ) == .stopAfterPendingStartAndRecenter
        )
    }

    @Test func fixedLocationHomeActionUsesLaunchCoordinate() {
        #expect(SharedControlAction.returnToRealLocation == .returnToRealLocation)
        #expect(
            LaunchCoordinateReturnPolicy.fixedLocationAction(isSimulating: false)
                == .recenterOnly
        )
        #expect(
            LaunchCoordinateReturnPolicy.fixedLocationAction(isSimulating: true)
                == .updateSimulationAndHold
        )
    }

    @Test func pairingFileValidationAcceptsRequiredFields() throws {
        let propertyList: [String: Any] = [
            "HostID": "host-id",
            "SystemBUID": "system-buid",
            "DeviceCertificate": Data([1]),
            "HostCertificate": Data([2]),
            "HostPrivateKey": Data([3]),
            "RootCertificate": Data([4]),
            "RootPrivateKey": Data([5])
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )

        try PairingFileStore.validate(data)
    }

    @Test func pairingFileValidationRejectsMissingPrivateKey() throws {
        let propertyList: [String: Any] = [
            "HostID": "host-id",
            "SystemBUID": "system-buid",
            "DeviceCertificate": Data([1]),
            "HostCertificate": Data([2]),
            "RootCertificate": Data([4]),
            "RootPrivateKey": Data([5])
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )

        #expect(throws: PairingFileError.self) {
            try PairingFileStore.validate(data)
        }
    }

    @Test func pairingFileValidationRejectsNonPropertyListData() {
        #expect(throws: PairingFileError.self) {
            try PairingFileStore.validate(Data("not a plist".utf8))
        }
    }

    @Test func locationSimulationResultMapsTypedError() {
        let result = LocationSimulationService.result(code: 11, operation: "設定位置")

        guard case .failure(let error) = result else {
            Issue.record("非零 FFI 狀態必須映射為型別化錯誤")
            return
        }
        #expect(error.code == 11)
        #expect(error.operation == "設定位置")
        #expect(error.localizedDescription.contains("座標設定失敗"))
    }

    @Test func locationSimulationResultAcceptsSuccess() {
        let result = LocationSimulationService.result(code: 0, operation: "停止模擬")
        guard case .success = result else {
            Issue.record("狀態碼 0 必須映射為成功")
            return
        }
    }

    @Test @MainActor func locationSimulationServiceUsesInjectedOperation() async {
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.location-service"),
            setOperation: { ip, latitude, longitude, pairingFile in
                #expect(ip == "10.7.0.1")
                #expect(latitude == 25.033)
                #expect(longitude == 121.5654)
                #expect(pairingFile == "/tmp/pairing.plist")
                return 9
            },
            clearOperation: { 0 }
        )

        await withCheckedContinuation { continuation in
            service.setLocation(
                deviceIP: "10.7.0.1",
                latitude: 25.033,
                longitude: 121.5654,
                pairingFile: "/tmp/pairing.plist",
                operation: "連線測試"
            ) { result in
                guard case .failure(let error) = result else {
                    Issue.record("Service 應回傳注入操作的錯誤")
                    continuation.resume()
                    return
                }
                #expect(error.code == 9)
                #expect(error.operation == "連線測試")
                continuation.resume()
            }
        }
    }

    @Test @MainActor func routePauseAndStopStatesAreConsistent() {
        let manager = JoystickModeManager()
        let healthCoordinator = HealthWalkingCoordinator.shared
        let wasHealthWalkingEnabled = healthCoordinator.isEnabled
        healthCoordinator.setEnabled(false)
        defer {
            if wasHealthWalkingEnabled {
                healthCoordinator.setEnabled(true)
            }
        }
        let route = SimulationRoute(
            name: "Test",
            points: [
                PathPoint(coordinate: .init(latitude: 25, longitude: 121), order: 0),
                PathPoint(coordinate: .init(latitude: 25.001, longitude: 121.001), order: 1)
            ],
            createdDate: Date()
        )

        manager.startPathSimulation(route: route, speed: 50)
        #expect(manager.isSimulating)
        manager.pausePathSimulation()
        #expect(manager.isPaused && !manager.isSimulating)
        manager.stopPathSimulation()
        #expect(!manager.isPaused && !manager.isSimulating && manager.selectedRoute == nil)
    }

    @Test @MainActor func routeAdvancesUsingElapsedBackgroundTime() {
        let defaults = UserDefaults.standard
        let originalHealthEnabled = defaults.object(forKey: UserDefaults.Keys.healthWalkingEnabled)
        let originalStepRate = defaults.object(forKey: UserDefaults.Keys.walkingStepsPerSecond)
        defer {
            if let originalHealthEnabled {
                defaults.set(originalHealthEnabled, forKey: UserDefaults.Keys.healthWalkingEnabled)
            } else {
                defaults.removeObject(forKey: UserDefaults.Keys.healthWalkingEnabled)
            }
            if let originalStepRate {
                defaults.set(originalStepRate, forKey: UserDefaults.Keys.walkingStepsPerSecond)
            } else {
                defaults.removeObject(forKey: UserDefaults.Keys.walkingStepsPerSecond)
            }
        }
        defaults.set(false, forKey: UserDefaults.Keys.healthWalkingEnabled)
        defaults.set(2, forKey: UserDefaults.Keys.walkingStepsPerSecond)

        let manager = JoystickModeManager()
        let route = SimulationRoute(
            name: "Background",
            points: [
                PathPoint(coordinate: .init(latitude: 0, longitude: 0), order: 0),
                PathPoint(coordinate: .init(latitude: 0, longitude: 0.001), order: 1)
            ],
            createdDate: Date()
        )

        manager.startPathSimulation(route: route, speed: 36)
        manager.advanceForBackgroundHeartbeat(at: Date().addingTimeInterval(5))

        #expect(manager.isSimulating)
        #expect(manager.simulationProgress > 0.35)
        #expect(manager.simulationProgress < 0.60)
        #expect((manager.currentLocation?.longitude ?? 0) > 0.000_35)
    }

    @Test func routeEngineAdvancesWithoutDependingOnUITimers() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
        ]
        let engine = try #require(
            RouteSimulationEngine(
                coordinates: coordinates,
                startIndex: 0,
                completionMode: .stopAtLast,
                planningMode: .direct
            )
        )

        let transition = engine.advance(
            state: engine.initialState(),
            distanceMeters: 50
        )
        guard case .advanced(let state) = transition else {
            Issue.record("尚未走完整段時不應結束路線")
            return
        }

        #expect(state.pointIndex == 0)
        #expect(state.segmentProgress > 0.4)
        #expect(state.segmentProgress < 0.5)
        #expect(state.coordinate.longitude > 0.000_4)
    }

    @Test func routeEngineStopsExactlyAtLastPoint() throws {
        let destination = CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
        let engine = try #require(
            RouteSimulationEngine(
                coordinates: [
                    CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    destination
                ],
                startIndex: 0,
                completionMode: .stopAtLast,
                planningMode: .direct
            )
        )

        let transition = engine.advance(
            state: engine.initialState(),
            distanceMeters: 1_000
        )
        guard case .completed(let state) = transition else {
            Issue.record("超過路線總長後必須完成")
            return
        }

        #expect(state.pointIndex == 1)
        #expect(abs(state.coordinate.latitude - destination.latitude) < 0.000_001)
        #expect(abs(state.coordinate.longitude - destination.longitude) < 0.000_001)
    }

    @Test func routeEngineReturnToStartCompletesAtSelectedStartPoint() throws {
        let selectedStart = CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
        let engine = try #require(
            RouteSimulationEngine(
                coordinates: [
                    CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    selectedStart,
                    CLLocationCoordinate2D(latitude: 0, longitude: 0.002)
                ],
                startIndex: 1,
                completionMode: .returnToStart,
                planningMode: .direct
            )
        )

        let transition = engine.advance(
            state: engine.initialState(),
            distanceMeters: 1_000
        )
        guard case .completed(let state) = transition else {
            Issue.record("回到起點模式應在走回所選起點時完成")
            return
        }

        #expect(state.pointIndex == 1)
        #expect(abs(state.coordinate.latitude - selectedStart.latitude) < 0.000_001)
        #expect(abs(state.coordinate.longitude - selectedStart.longitude) < 0.000_001)
    }

    @Test func routeEngineLoopModeNeverEmitsCompletionAtRouteBoundary() throws {
        let engine = try #require(
            RouteSimulationEngine(
                coordinates: [
                    CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
                ],
                startIndex: 0,
                completionMode: .loop,
                planningMode: .direct
            )
        )

        let transition = engine.advance(
            state: engine.initialState(),
            distanceMeters: 250
        )
        guard case .advanced = transition else {
            Issue.record("循環模式跨越路線邊界時不應完成")
            return
        }
    }

    @Test func joystickMovementUsesBearingAndElapsedTime() {
        let engine = JoystickMovementEngine()
        let origin = CLLocationCoordinate2D(latitude: 25, longitude: 121)
        let east = engine.destination(
            from: origin,
            joystickAngleDegrees: 180,
            speedKilometersPerHour: 36,
            elapsed: 1
        )
        let north = engine.destination(
            from: origin,
            joystickAngleDegrees: 90,
            speedKilometersPerHour: 36,
            elapsed: 1
        )
        guard let east, let north else {
            Issue.record("有效速度與時間應產生目的座標")
            return
        }

        #expect(east.longitude > origin.longitude)
        #expect(abs(east.latitude - origin.latitude) < 0.000_001)
        #expect(north.latitude > origin.latitude)
        #expect(abs(north.longitude - origin.longitude) < 0.000_001)
        #expect(
            CLLocation(latitude: east.latitude, longitude: east.longitude)
                .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)) > 9.9
        )
    }

    @Test @MainActor func coordinatorRejectsConflictingSimulationModes() async {
        let service = LocationSimulationService(
            queue: DispatchQueue(label: "com.ufogeo.tests.coordinator"),
            setOperation: { _, _, _, _ in 0 },
            clearOperation: { 0 }
        )
        let coordinator = SimulationCoordinator(service: service)
        let coordinate = CLLocationCoordinate2D(latitude: 25, longitude: 121)

        let first = await coordinator.start(
            mode: .fixedLocation,
            coordinate: coordinate,
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "開始單點"
        )
        guard case .success = first else {
            Issue.record("第一個模擬模式應成功啟動")
            return
        }

        let conflicting = await coordinator.start(
            mode: .route,
            coordinate: coordinate,
            deviceIP: "10.7.0.1",
            pairingFile: "/tmp/pairing.plist",
            operation: "開始路線"
        )
        #expect(conflicting.failure?.code == 13)
    }

    @Test @MainActor func healthWalkingTargetResetStartsNewRound() async {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        let writer = TestHealthStepWriter()
        let start = Date()
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: writer,
            automaticallyStartTimer: false,
            currentDate: start,
            isProProvider: { true }
        )
        #expect(await enableTestHealthCoordinator(coordinator, at: start))
        coordinator.startRouteSimulation(
            speedKilometersPerHour: 36,
            at: start
        )
        coordinator.tick(at: start.addingTimeInterval(2))
        #expect(coordinator.totalProgress > 0)
        coordinator.updateTarget(3_000)
        #expect(coordinator.pendingSteps == 0)
        #expect(coordinator.writtenSteps == 0)
        #expect(coordinator.remainingSteps == 3_000)
    }

    @Test @MainActor func healthWalkingFreeNewInstallUsesTenThousandTarget() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne,
            isProProvider: { false }
        )

        #expect(coordinator.target == HealthWalkingCoordinator.freeDailyTarget)
        #expect(coordinator.remainingSteps == HealthWalkingCoordinator.freeDailyTarget)
    }

    @Test @MainActor func healthWalkingFreeUsesFixedThousandBatchAndIgnoresLegacyBatch() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        defaults.set(100, forKey: UserDefaults.Keys.walkingStepResetTarget)
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne,
            isProProvider: { false },
            isAppActiveProvider: { true }
        )

        #expect(coordinator.batchSize == HealthWalkingCoordinator.freeBatchSize)
        #expect(defaults.integer(forKey: UserDefaults.Keys.walkingStepResetTarget) == 1_000)
        #expect(coordinator.target == HealthWalkingCoordinator.freeDailyTarget)
    }

    @Test @MainActor func healthWalkingProBatchPersistsAcrossDowngradeAndUpgrade() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        var isPro = true
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne,
            isProProvider: { isPro },
            isAppActiveProvider: { true }
        )

        coordinator.updateBatchSize(4_321, at: healthDayOne)
        #expect(coordinator.batchSize == 4_321)
        #expect(defaults.integer(forKey: UserDefaults.Keys.savedProHealthBatchSize) == 4_321)

        isPro = false
        coordinator.refreshEntitlement(at: healthDayOne)
        #expect(coordinator.batchSize == HealthWalkingCoordinator.freeBatchSize)
        #expect(defaults.integer(forKey: UserDefaults.Keys.walkingStepResetTarget) == 1_000)
        #expect(defaults.integer(forKey: UserDefaults.Keys.savedProHealthBatchSize) == 4_321)

        isPro = true
        coordinator.refreshEntitlement(at: healthDayOne)
        #expect(coordinator.batchSize == 4_321)
    }

    @Test @MainActor func healthWalkingFreeIgnoresLegacyTargetAndPreservesItForPro() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        defaults.set(2_500, forKey: UserDefaults.Keys.healthStepWriteTarget)
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne,
            isProProvider: { false }
        )

        #expect(coordinator.target == HealthWalkingCoordinator.freeDailyTarget)
        #expect(defaults.integer(forKey: UserDefaults.Keys.savedHealthSimulationTarget) == 2_500)
    }

    @Test @MainActor func healthWalkingProUsesAndPersistsCustomTarget() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        defaults.set(4_321, forKey: UserDefaults.Keys.savedHealthSimulationTarget)
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne,
            isProProvider: { true }
        )

        #expect(coordinator.target == 4_321)
        coordinator.updateTarget(5_678, at: healthDayOne)
        #expect(coordinator.target == 5_678)
        #expect(defaults.integer(forKey: UserDefaults.Keys.savedHealthSimulationTarget) == 5_678)
    }

    @Test @MainActor func healthWalkingSameNaturalDayDoesNotResetAfterRestart() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        let first = HealthWalkingCoordinator(
            defaults: defaults,
            writer: TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne,
            isProProvider: { true }
        )
        first.setEnabled(true, at: healthDayOne)
        first.startRouteSimulation(speedKilometersPerHour: 36, at: healthDayOne)
        first.tick(at: healthDayOne.addingTimeInterval(2))
        let progressBeforeRestart = first.totalProgress

        let restarted = HealthWalkingCoordinator(
            defaults: defaults,
            writer: TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne.addingTimeInterval(3_600),
            isProProvider: { true }
        )

        #expect(progressBeforeRestart == 2)
        #expect(restarted.totalProgress == progressBeforeRestart)
    }

    @Test @MainActor func healthWalkingCrossingNaturalDayResetsProgressAndBaseline() {
        let coordinator = makeTestHealthCoordinator(
            batch: 100,
            target: 1_000,
            isPro: true,
            currentDate: healthDayOne
        )
        coordinator.setEnabled(true, at: healthDayOne)
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: healthDayOne)
        coordinator.tick(at: healthDayOne.addingTimeInterval(2))
        #expect(coordinator.totalProgress == 2)

        let nextDay = healthDayTwo.addingTimeInterval(1)
        coordinator.tick(at: nextDay)
        #expect(coordinator.pendingSteps == 0)
        #expect(coordinator.writtenSteps == 0)
        #expect(coordinator.totalProgress == 0)
        #expect(coordinator.remainingSteps == coordinator.target)

        coordinator.tick(at: nextDay.addingTimeInterval(2))
        #expect(coordinator.totalProgress == 2)
    }

    @Test @MainActor func healthWalkingCrossDayOldWriteCompletionCannotPolluteNewDay() async {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        defaults.set(1, forKey: UserDefaults.Keys.walkingStepResetTarget)
        let writer = ControlledHealthStepWriter()
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: writer,
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne,
            isProProvider: { true }
        )
        coordinator.setEnabled(true, at: healthDayOne)
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: healthDayOne)
        coordinator.tick(at: healthDayOne.addingTimeInterval(1))
        #expect(writer.pendingCompletions == 1)

        coordinator.tick(at: healthDayTwo.addingTimeInterval(1))
        #expect(coordinator.totalProgress == 0)
        writer.completeNext(.success(()))
        await Task.yield()

        #expect(coordinator.totalProgress == 0)
        #expect(coordinator.writtenSteps == 0)
    }

    @Test @MainActor func healthWalkingDowngradeAppliesFreeTargetAndRetainsProTarget() {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        defaults.set(6_789, forKey: UserDefaults.Keys.savedHealthSimulationTarget)
        var isPro = true
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: healthDayOne,
            isProProvider: { isPro }
        )

        #expect(coordinator.target == 6_789)
        isPro = false
        coordinator.refreshEntitlement(at: healthDayOne)
        #expect(coordinator.target == HealthWalkingCoordinator.freeDailyTarget)
        #expect(defaults.integer(forKey: UserDefaults.Keys.savedHealthSimulationTarget) == 6_789)

        isPro = true
        coordinator.refreshEntitlement(at: healthDayOne)
        #expect(coordinator.target == 6_789)
    }

    @Test @MainActor func healthWalkingFreeBackgroundDoesNotAccumulateOrBackfill() async {
        var isAppActive = true
        let coordinator = makeTestHealthCoordinator(
            batch: 100,
            target: 10_000,
            isPro: false,
            currentDate: healthDayOne,
            isAppActiveProvider: { isAppActive }
        )
        #expect(await enableTestHealthCoordinator(coordinator, at: healthDayOne))
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: healthDayOne)
        coordinator.tick(at: healthDayOne.addingTimeInterval(2))
        #expect(coordinator.totalProgress == 2)

        isAppActive = false
        coordinator.advanceForBackgroundHeartbeat(at: healthDayOne.addingTimeInterval(100))
        #expect(coordinator.totalProgress == 2)

        isAppActive = true
        coordinator.tick(at: healthDayOne.addingTimeInterval(101))
        #expect(coordinator.totalProgress == 2)
        coordinator.tick(at: healthDayOne.addingTimeInterval(102))
        #expect(coordinator.totalProgress == 3)
    }

    @Test @MainActor func healthWalkingProBackgroundContinuesGeneratingAndWriting() async {
        let coordinator = makeTestHealthCoordinator(
            batch: 1,
            target: 10,
            isPro: true,
            currentDate: healthDayOne,
            isAppActiveProvider: { false }
        )
        #expect(await enableTestHealthCoordinator(coordinator, at: healthDayOne))
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: healthDayOne)
        coordinator.advanceForBackgroundHeartbeat(at: healthDayOne.addingTimeInterval(2))
        await Task.yield()

        #expect(coordinator.totalProgress == 2)
        #expect(coordinator.writtenSteps == 2)
    }

    @Test @MainActor func healthWalkingPauseDoesNotAccumulate() async {
        let coordinator = makeTestHealthCoordinator(batch: 100)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(2))
        let beforePause = coordinator.totalProgress
        coordinator.pauseRoute(at: start.addingTimeInterval(2))
        coordinator.tick(at: start.addingTimeInterval(20))
        #expect(coordinator.totalProgress == beforePause)
    }

    @Test @MainActor func healthWalkingOffDoesNotAccumulateOrBackfill() async {
        let coordinator = makeTestHealthCoordinator(batch: 100)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(1))
        let beforeOff = coordinator.totalProgress
        coordinator.setEnabled(false)
        coordinator.tick(at: start.addingTimeInterval(20))
        #expect(coordinator.totalProgress == beforeOff)
    }

    @Test @MainActor func healthWalkingOffThenOnDoesNotBackfillDisabledTime() async {
        let coordinator = makeTestHealthCoordinator(batch: 100)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(1))
        coordinator.setEnabled(false)
        coordinator.tick(at: start.addingTimeInterval(30))
        let beforeReenable = coordinator.totalProgress

        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.tick(at: Date())
        #expect(coordinator.totalProgress == beforeReenable)
    }

    @Test @MainActor func healthWalkingRateChangeResetsTimeBaseline() async {
        let coordinator = makeTestHealthCoordinator(batch: 100)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(0.5))
        coordinator.updateRate(3, at: start.addingTimeInterval(0.5))
        coordinator.tick(at: start.addingTimeInterval(1.0))
        #expect(coordinator.totalProgress == 1)
    }

    @Test @MainActor func healthWalkingZeroSpeedRouteDoesNotAccumulate() async {
        let coordinator = makeTestHealthCoordinator(batch: 100)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.startRouteSimulation(speedKilometersPerHour: 0, at: start)
        coordinator.tick(at: start.addingTimeInterval(20))
        #expect(coordinator.totalProgress == 0)
    }

    @Test @MainActor func healthWalkingFixedLocationStartsCountingImmediately() async {
        let coordinator = makeTestHealthCoordinator(batch: 100)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.prepareFixedSimulation(at: start)
        coordinator.tick(at: start.addingTimeInterval(20))
        #expect(coordinator.totalProgress == 20)
    }

    @Test @MainActor func healthWalkingFixedLocationStopsWithSimulation() async {
        let coordinator = makeTestHealthCoordinator(batch: 100)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.prepareFixedSimulation(at: start)
        coordinator.tick(at: start.addingTimeInterval(2))
        coordinator.stopFixedSimulation(at: start.addingTimeInterval(2))
        coordinator.tick(at: start.addingTimeInterval(4))
        #expect(coordinator.totalProgress == 2)
    }

    @Test @MainActor func healthWalkingRouteCanResumeAfterZeroSpeed() async {
        let coordinator = makeTestHealthCoordinator(batch: 100)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.startRouteSimulation(speedKilometersPerHour: 0, at: start)
        coordinator.tick(at: start.addingTimeInterval(10))
        coordinator.updateRouteSpeed(speedKilometersPerHour: 36, at: start.addingTimeInterval(10))
        coordinator.tick(at: start.addingTimeInterval(12))
        #expect(coordinator.totalProgress == 2)
    }

    @Test @MainActor func healthWalkingBatchWriteUpdatesRemainingProgress() async {
        let coordinator = makeTestHealthCoordinator(batch: 3, target: 10)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(3))
        await Task.yield()
        #expect(coordinator.writtenSteps == 3)
        #expect(coordinator.pendingSteps == 0)
        #expect(coordinator.remainingSteps == 7)
    }

    @Test @MainActor func healthWalkingNeverExceedsDailyTarget() async {
        let coordinator = makeTestHealthCoordinator(batch: 100, target: 5)
        let start = Date()
        #expect(await enableTestHealthCoordinator(coordinator))
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(10))
        await Task.yield()

        #expect(coordinator.totalProgress == 5)
        #expect(coordinator.remainingSteps == 0)
    }

    @Test @MainActor func healthWalkingResetIgnoresOldInFlightCompletion() async {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        let writer = ControlledHealthStepWriter()
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: writer,
            automaticallyStartTimer: false,
            isProProvider: { true }
        )
        coordinator.updateBatchSize(1)
        #expect(await enableTestHealthCoordinator(coordinator))
        let start = Date()
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(1))
        #expect(writer.pendingCompletions == 1)

        coordinator.updateTarget(500)
        #expect(writer.pendingCompletions == 1)
        writer.completeNext(.success(()))
        await Task.yield()
        #expect(coordinator.pendingSteps == 0)
        #expect(coordinator.writtenSteps == 0)

        coordinator.tick(at: Date().addingTimeInterval(1))
        #expect(writer.pendingCompletions == 1)
    }

    @Test @MainActor func healthWalkingDoesNotGenerateBeforeAuthorizationCompletes() async {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        let writer = DelayedAuthorizationHealthStepWriter()
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: writer,
            automaticallyStartTimer: false,
            isProProvider: { true }
        )
        coordinator.setEnabled(true)
        let start = Date()
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(10))
        #expect(coordinator.totalProgress == 0)

        writer.completeAuthorization(granted: true)
        await Task.yield()
        let afterAuthorization = Date()
        coordinator.tick(at: afterAuthorization.addingTimeInterval(1))
        #expect(coordinator.totalProgress == 1)
    }

    @Test @MainActor func healthWalkingOffInFlightWriteRecordsWithoutChaining() async {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        let writer = ControlledHealthStepWriter()
        let coordinator = HealthWalkingCoordinator(
            defaults: defaults,
            writer: writer,
            automaticallyStartTimer: false,
            isProProvider: { true }
        )
        coordinator.updateBatchSize(1)
        #expect(await enableTestHealthCoordinator(coordinator))
        let start = Date()
        coordinator.startRouteSimulation(speedKilometersPerHour: 36, at: start)
        coordinator.tick(at: start.addingTimeInterval(1))
        coordinator.setEnabled(false)
        writer.completeNext(.success(()))
        await Task.yield()
        #expect(coordinator.writtenSteps == 1)
        #expect(coordinator.pendingSteps == 0)
        #expect(writer.pendingCompletions == 0)
    }

    private var healthTestCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var healthDayOne: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    private var healthDayTwo: Date {
        healthTestCalendar.date(byAdding: .day, value: 1, to: healthDayOne)!
    }

    @MainActor
    private func makeTestHealthCoordinator(
        batch: Int,
        target: Int = 1_000,
        isPro: Bool = true,
        currentDate: Date = Date(),
        writer: HealthStepWriting? = nil,
        isAppActiveProvider: (() -> Bool)? = nil
    ) -> HealthWalkingCoordinator {
        let defaults = UserDefaults(suiteName: "UFOGeoTests-\(UUID().uuidString)")!
        defaults.set(batch, forKey: UserDefaults.Keys.walkingStepResetTarget)
        defaults.set(target, forKey: UserDefaults.Keys.healthStepWriteTarget)
        return HealthWalkingCoordinator(
            defaults: defaults,
            writer: writer ?? TestHealthStepWriter(),
            automaticallyStartTimer: false,
            calendar: healthTestCalendar,
            currentDate: currentDate,
            isProProvider: { isPro },
            isAppActiveProvider: isAppActiveProvider ?? { true }
        )
    }

    @MainActor
    private func enableTestHealthCoordinator(
        _ coordinator: HealthWalkingCoordinator,
        at date: Date = Date()
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            coordinator.setEnabled(true, at: date) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

}

@MainActor
private final class TestHealthStepWriter: HealthStepWriting {
    var isAvailable = true

    func requestAuthorizationIfNeeded(completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }

    func writeSteps(
        _ steps: Int,
        remainingSteps: Int?,
        at date: Date,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        completion(.success(()))
    }
}

@MainActor
private final class ControlledHealthStepWriter: HealthStepWriting {
    var isAvailable = true
    private var completions: [(Result<Void, Error>) -> Void] = []
    var pendingCompletions: Int { completions.count }

    func requestAuthorizationIfNeeded(completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }

    func writeSteps(
        _ steps: Int,
        remainingSteps: Int?,
        at date: Date,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        completions.append(completion)
    }

    func completeNext(_ result: Result<Void, Error>) {
        guard !completions.isEmpty else { return }
        completions.removeFirst()(result)
    }
}

@MainActor
private final class DelayedAuthorizationHealthStepWriter: HealthStepWriting {
    var isAvailable = true
    private var authorizationCompletion: ((Bool) -> Void)?

    func requestAuthorizationIfNeeded(completion: @escaping @MainActor (Bool) -> Void) {
        authorizationCompletion = completion
    }

    func completeAuthorization(granted: Bool) {
        authorizationCompletion?(granted)
        authorizationCompletion = nil
    }

    func writeSteps(
        _ steps: Int,
        remainingSteps: Int?,
        at date: Date,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        completion(.success(()))
    }
}
