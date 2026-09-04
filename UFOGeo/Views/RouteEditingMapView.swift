import MapKit
import SwiftUI

enum RouteEditingMapInteractionPolicy {
    static let postInsertionZoomSuppressionDuration: TimeInterval = 0.35

    static func shouldSuppressZoomAfterPointInsertion(
        isEditing: Bool,
        isSimulationActive: Bool
    ) -> Bool {
        isEditing && !isSimulationActive
    }

    static func canRestoreZoomAfterSuppression(
        isSuppressed: Bool,
        tokenMatches: Bool,
        isSimulationActive: Bool,
        isMapGestureActive: Bool
    ) -> Bool {
        isSuppressed
            && tokenMatches
            && !isSimulationActive
            && !isMapGestureActive
    }

    static func shouldFollowSimulationAfterCenterRequest(
        isSimulationActive: Bool,
        requestedCoordinate: CLLocationCoordinate2D,
        simulatedCoordinate: CLLocationCoordinate2D?,
        resumesRouteFollowing: Bool
    ) -> Bool {
        if resumesRouteFollowing { return true }
        guard isSimulationActive,
              let simulatedCoordinate else { return true }
        return CLLocation(
            latitude: requestedCoordinate.latitude,
            longitude: requestedCoordinate.longitude
        ).distance(from: CLLocation(
            latitude: simulatedCoordinate.latitude,
            longitude: simulatedCoordinate.longitude
        )) <= 0.01
    }
}

struct RouteEditingMapView: UIViewRepresentable {
    @Binding var route: SimulationRoute
    @Binding var selectedPointID: UUID?
    @ObservedObject var sharedMapState: SharedLocationMapState
    let isEditing: Bool
    let isSimulationActive: Bool
    let simulatedCoordinate: CLLocationCoordinate2D?
    let simulatedHeading: Double
    let isSimulationMoving: Bool
    let onMapTap: (CLLocationCoordinate2D) -> Void
    /// 目前顯示路線的 ID，改變時自動清除 snapshot 讓地圖立即重繪。
    var routeID: UUID? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SharedNativeMapContainerView {
        let container = SharedNativeMapContainerView()
        guard sharedMapState.activeTabID == AppFeature.pathSimulation.id else {
            return container
        }
        let mapView = SharedNativeMapStore.shared.mapView
        mapView.delegate = context.coordinator
        context.coordinator.installTapIfNeeded(on: mapView)
        mapView.mapType = .standard
        mapView.showsCompass = true
        mapView.showsScale = true
        context.coordinator.updateCameraInteraction(on: mapView)

        context.coordinator.installRoute(on: mapView)
        if let camera = sharedMapState.lastCamera {
            mapView.camera = MKMapCamera(
                lookingAtCenter: camera.centerCoordinate,
                fromDistance: camera.distance,
                pitch: 0,
                heading: camera.heading
            )
        } else if let coordinate = sharedMapState.selectedCoordinate {
            mapView.setRegion(
                SharedLocationMapState.defaultSimulationRegion(centeredAt: coordinate),
                animated: false
            )
        } else if let coordinate = route.points.first?.coordinate {
            mapView.setRegion(
                SharedLocationMapState.defaultSimulationRegion(centeredAt: coordinate),
                animated: false
            )
        }
        return container
    }

    func updateUIView(_ container: SharedNativeMapContainerView, context: Context) {
        guard sharedMapState.activeTabID == AppFeature.pathSimulation.id else {
            context.coordinator.isRouteTabActive = false
            return
        }
        let isEnteringRouteTab = !context.coordinator.isRouteTabActive
        context.coordinator.isRouteTabActive = true
        let mapView = SharedNativeMapStore.shared.mapView
        mapView.delegate = context.coordinator
        context.coordinator.installTapIfNeeded(on: mapView)
        mapView.gestureRecognizers?.forEach {
            if $0.name == "LocationMapTap" { $0.isEnabled = false }
            if $0.name == "RouteMapTap" { $0.isEnabled = true }
        }
        context.coordinator.parent = self
        if isEnteringRouteTab {
            context.coordinator.invalidateRouteSnapshot()
        }
        // 路線切換時清除 snapshot，確保地圖立即重繪新路線的路點與折線。
        if context.coordinator.currentRouteID != routeID {
            context.coordinator.currentRouteID = routeID
            context.coordinator.invalidateRouteSnapshot()
        }
        context.coordinator.updateCameraInteraction(on: mapView)
        context.coordinator.applyPendingCenterRequest(on: mapView)
        guard !context.coordinator.isDraggingPoint else { return }
        // 若路線已切換（snapshot 被清除），即使手勢仍在也要立即更新路點。
        let needsForceInstall = context.coordinator.needsForceInstall
        context.coordinator.needsForceInstall = false
        // Pinch/pan gestures must own the main thread while they are active.
        // The latest route state is retained in `parent` and applied as soon as
        // MapKit finishes the gesture and SwiftUI performs the next update.
        guard !context.coordinator.isMapInteractionOngoing(on: mapView) || needsForceInstall else { return }
        context.coordinator.installRoute(on: mapView)
        if isEnteringRouteTab,
           let centerCoordinate = sharedMapState.selectedCoordinate
                ?? simulatedCoordinate
                ?? route.points.first?.coordinate {
            SharedNativeMapStore.shared.center(
                at: centerCoordinate,
                preserveZoom: true
            )
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: RouteEditingMapView
        var isDraggingPoint = false
        var isRouteTabActive = false
        var currentRouteID: UUID? = nil
        fileprivate var needsForceInstall: Bool = false
        private weak var mapView: MKMapView?
        private var displayLink: CADisplayLink?
        private var lastIsSimulationMoving: Bool?
        private var lastGestureActivityAt = Date.distantPast
        private let gestureSettleDuration: TimeInterval = 0.25
        private var postInsertionZoomSuppressionToken: UUID?
        private var postInsertionZoomRestoreWorkItem: DispatchWorkItem?
        private var postInsertionZoomSuppressed = false
        private var postInsertionRestoreZoomEnabled = true

        func invalidateRouteSnapshot() {
            routeSnapshot = nil
            needsForceInstall = true
        }
        private var routeOverlay: LiveRouteOverlay?
        private weak var routeRenderer: LiveRouteOverlayRenderer?
        private var lastFollowedCoordinate: CLLocationCoordinate2D?
        private var appliedCenterRequestID: UUID?
        private var followsSimulation = true
        private var routeSnapshot: RouteSnapshot?

        private struct RouteSnapshot: Equatable {
            struct Point: Equatable {
                let id: UUID
                let order: Int
                let latitude: Double
                let longitude: Double
            }

            let points: [Point]
            let isEditing: Bool
            let selectedPointID: UUID?
        }

        init(_ parent: RouteEditingMapView) {
            self.parent = parent
        }

        deinit {
            displayLink?.invalidate()
            postInsertionZoomRestoreWorkItem?.cancel()
        }

        func installTapIfNeeded(on mapView: MKMapView) {
            self.mapView = mapView
            guard mapView.gestureRecognizers?.contains(where: {
                $0.name == "RouteMapTap"
            }) != true else { return }
            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleMapTap(_:))
            )
            tap.name = "RouteMapTap"
            tap.delegate = self
            tap.cancelsTouchesInView = false
            mapView.addGestureRecognizer(tap)
        }

        func updateCameraInteraction(on mapView: MKMapView) {
            let moving = parent.isSimulationMoving
            let simulating = parent.isSimulationActive
            if simulating {
                finishPostInsertionZoomSuppressionWithoutRestore()
                lastIsSimulationMoving = moving
                mapView.isZoomEnabled = false
                mapView.isScrollEnabled = false
                mapView.isRotateEnabled = false
                return
            }
            if postInsertionZoomSuppressed {
                lastIsSimulationMoving = moving
                // SwiftUI may call updateUIView immediately after the route
                // binding changes.  Keep zoom disabled until the tokenized
                // restore callback decides that the gesture has settled.
                mapView.isZoomEnabled = false
                mapView.isScrollEnabled = true
                mapView.isRotateEnabled = true
                return
            }
            // 僅在狀態實際改變時才寫入，避免每個模擬 tick 都打斷手勢辨識。
            guard lastIsSimulationMoving != moving || mapView.isZoomEnabled == simulating,
                !isMapInteractionOngoing(on: mapView) else { return }
            lastIsSimulationMoving = moving
            // 路線模擬中完全鎖定地圖互動（縮放/平移/旋轉）；暫停或停止後恢復。
            mapView.isZoomEnabled = !simulating
            mapView.isScrollEnabled = !simulating
            mapView.isRotateEnabled = !simulating
        }

        func applyPendingCenterRequest(on mapView: MKMapView) {
            guard let request = parent.sharedMapState.nativeMapCenterRequest,
                  request.id != appliedCenterRequestID else { return }
            appliedCenterRequestID = request.id
            SharedNativeMapStore.shared.center(
                at: request.coordinate,
                preserveZoom: request.preserveZoom
            )

            followsSimulation = RouteEditingMapInteractionPolicy
                .shouldFollowSimulationAfterCenterRequest(
                    isSimulationActive: parent.sharedMapState.isSimulationActive,
                    requestedCoordinate: request.coordinate,
                    simulatedCoordinate: parent.simulatedCoordinate,
                    resumesRouteFollowing: request.resumesRouteFollowing
                )
        }

        func installRoute(on mapView: MKMapView) {
            self.mapView = mapView
            let snapshot = RouteSnapshot(
                points: parent.route.points.map {
                    RouteSnapshot.Point(
                        id: $0.id,
                        order: $0.order,
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                },
                isEditing: parent.isEditing,
                selectedPointID: parent.selectedPointID
            )
            guard snapshot != routeSnapshot else {
                updateSimulationMarker(on: mapView)
                return
            }
            routeSnapshot = snapshot
            for annotation in mapView.annotations
            where !(annotation is RoutePointMapAnnotation)
                && !(annotation is RouteSimulationMapAnnotation) {
                mapView.removeAnnotation(annotation)
            }
            let existing = Dictionary(
                uniqueKeysWithValues: mapView.annotations.compactMap {
                    annotation -> (UUID, RoutePointMapAnnotation)? in
                    guard let annotation = annotation as? RoutePointMapAnnotation else {
                        return nil
                    }
                    return (annotation.pointID, annotation)
                }
            )
            let routeIDs = Set(parent.route.points.map(\.id))

            for annotation in existing.values where !routeIDs.contains(annotation.pointID) {
                mapView.removeAnnotation(annotation)
            }

            for point in parent.route.points {
                if let annotation = existing[point.id] {
                    annotation.order = point.order
                    if CLLocation(
                        latitude: annotation.coordinate.latitude,
                        longitude: annotation.coordinate.longitude
                    ).distance(from: CLLocation(
                        latitude: point.coordinate.latitude,
                        longitude: point.coordinate.longitude
                    )) > 0.01 {
                        annotation.coordinate = point.coordinate
                    }
                } else {
                    mapView.addAnnotation(
                        RoutePointMapAnnotation(
                            pointID: point.id,
                            order: point.order,
                            coordinate: point.coordinate
                        )
                    )
                }
            }
            updateSimulationMarker(on: mapView)
            updatePolyline(on: mapView, rebuildOverlay: true)
            refreshSelection(on: mapView)
        }

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: MKAnnotation
        ) -> MKAnnotationView? {
            if let simulation = annotation as? RouteSimulationMapAnnotation {
                let view = RouteSimulationAnnotationView(
                    annotation: simulation,
                    reuseIdentifier: "RouteSimulation"
                )
                view.displayPriority = .required
                view.collisionMode = .none
                view.zPriority = .max
                view.layer.zPosition = 10_000
                view.configure(
                    heading: simulation.heading,
                    moving: simulation.moving
                )
                configureSimulationInteraction(for: view)
                return view
            }
            guard let point = annotation as? RoutePointMapAnnotation else { return nil }
            let identifier = "RoutePoint"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? RoutePointAnnotationView)
                ?? RoutePointAnnotationView(annotation: point, reuseIdentifier: identifier)
            view.annotation = point
            view.isDraggable = false
            view.isEnabled = true
            view.isUserInteractionEnabled = parent.isEditing
            view.canShowCallout = false
            view.displayPriority = .required
            view.collisionMode = .none
            view.zPriority = parent.isEditing ? .max : .defaultUnselected
            view.layer.zPosition = parent.isEditing ? 20_000 : 0
            view.configure(order: point.order, selected: point.pointID == parent.selectedPointID)
            if view.gestureRecognizers?.contains(where: { $0.name == "RoutePointPan" }) != true {
                let pan = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleAnnotationPan(_:))
                )
                pan.name = "RoutePointPan"
                pan.delegate = self
                view.addGestureRecognizer(pan)
            }
            if view.gestureRecognizers?.contains(where: { $0.name == "RoutePointTap" }) != true {
                let tap = UITapGestureRecognizer(
                    target: self,
                    action: #selector(handleAnnotationTap(_:))
                )
                tap.name = "RoutePointTap"
                view.addGestureRecognizer(tap)
            }
            updateRoutePointInteraction(for: view)
            return view
        }

        @objc private func handleAnnotationTap(_ recognizer: UITapGestureRecognizer) {
            guard parent.isEditing,
                  recognizer.state == .ended,
                  let view = recognizer.view as? RoutePointAnnotationView,
                  let annotation = view.annotation as? RoutePointMapAnnotation,
                  let mapView else { return }
            if parent.selectedPointID == annotation.pointID {
                parent.selectedPointID = nil
                mapView.deselectAnnotation(annotation, animated: false)
            } else {
                parent.selectedPointID = annotation.pointID
                mapView.selectAnnotation(annotation, animated: false)
            }
            refreshSelection(on: mapView)
        }

        @objc private func handleSimulationMarkerTap(
            _ recognizer: UITapGestureRecognizer
        ) {
            guard recognizer.state == .ended,
                  parent.isEditing,
                  let view = recognizer.view as? RouteSimulationAnnotationView,
                  let annotation = view.annotation as? RouteSimulationMapAnnotation else {
                return
            }
            parent.onMapTap(annotation.coordinate)
        }

        @objc private func handleAnnotationPan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.isEditing,
                  let view = recognizer.view as? RoutePointAnnotationView,
                  let annotation = view.annotation as? RoutePointMapAnnotation,
                  let mapView else { return }

            switch recognizer.state {
            case .began:
                isDraggingPoint = true
                mapView.isScrollEnabled = false
                parent.selectedPointID = annotation.pointID
                refreshSelection(on: mapView)
                startDisplayLink(for: mapView)
            case .changed:
                let location = recognizer.location(in: mapView)
                annotation.coordinate = mapView.convert(location, toCoordinateFrom: mapView)
            case .ended, .cancelled, .failed:
                stopDisplayLink()
                isDraggingPoint = false
                updatePolyline(on: mapView, rebuildOverlay: true)
                commitAnnotations(from: mapView)
                mapView.isScrollEnabled = true
            default:
                break
            }
        }

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState oldState: MKAnnotationView.DragState
        ) {
            guard let annotation = view.annotation as? RoutePointMapAnnotation else { return }
            switch newState {
            case .starting:
                isDraggingPoint = true
                parent.selectedPointID = annotation.pointID
                view.dragState = .dragging
                startDisplayLink(for: mapView)
            case .ending, .canceling:
                stopDisplayLink()
                isDraggingPoint = false
                updatePolyline(on: mapView, rebuildOverlay: true)
                commitAnnotations(from: mapView)
                view.dragState = .none
            default:
                break
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            refreshSelection(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for view in views {
                if view.annotation is RouteSimulationMapAnnotation {
                    view.zPriority = .max
                    view.layer.zPosition = 10_000
                } else if view.annotation is RoutePointMapAnnotation {
                    view.zPriority = parent.isEditing ? .max : .defaultUnselected
                    view.layer.zPosition = parent.isEditing ? 20_000 : 0
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let routeOverlay = overlay as? LiveRouteOverlay {
                let renderer = LiveRouteOverlayRenderer(
                    overlay: routeOverlay,
                    coordinates: pointAnnotations(in: mapView).map(\.coordinate)
                )
                routeRenderer = renderer
                return renderer
            }
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isDraggingPoint else { return }
            parent.sharedMapState.visibleRegion = mapView.region
            parent.sharedMapState.lastCamera = MapCamera(
                centerCoordinate: mapView.camera.centerCoordinate,
                distance: mapView.camera.centerCoordinateDistance,
                heading: mapView.camera.heading,
                pitch: mapView.camera.pitch
            )
        }

        @objc func handleMapTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let mapView else { return }
            let location = recognizer.location(in: mapView)
            let coordinate = mapView.convert(location, toCoordinateFrom: mapView)
            guard parent.isEditing else {
                parent.onMapTap(coordinate)
                return
            }
            var route = parent.route
            beginPostInsertionZoomSuppression(on: mapView)
            route.points.append(PathPoint(coordinate: coordinate, order: route.points.count))
            parent.route = route
            installRoute(on: mapView)
        }

        private func beginPostInsertionZoomSuppression(on mapView: MKMapView) {
            guard RouteEditingMapInteractionPolicy.shouldSuppressZoomAfterPointInsertion(
                isEditing: parent.isEditing,
                isSimulationActive: parent.isSimulationActive
            ) else { return }

            postInsertionZoomRestoreWorkItem?.cancel()
            if !postInsertionZoomSuppressed {
                postInsertionRestoreZoomEnabled = mapView.isZoomEnabled
            }
            let token = UUID()
            postInsertionZoomSuppressionToken = token
            postInsertionZoomSuppressed = true
            mapView.isZoomEnabled = false
            schedulePostInsertionZoomRestore(token: token)
        }

        private func schedulePostInsertionZoomRestore(token: UUID) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.postInsertionZoomRestoreWorkItem = nil
                self.restorePostInsertionZoomIfPossible(token: token)
            }
            postInsertionZoomRestoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + RouteEditingMapInteractionPolicy.postInsertionZoomSuppressionDuration,
                execute: workItem
            )
        }

        private func restorePostInsertionZoomIfPossible(token: UUID) {
            guard let mapView else {
                finishPostInsertionZoomSuppressionWithoutRestore()
                return
            }
            if parent.isSimulationActive {
                finishPostInsertionZoomSuppressionWithoutRestore()
                updateCameraInteraction(on: mapView)
                return
            }
            let canRestore = RouteEditingMapInteractionPolicy.canRestoreZoomAfterSuppression(
                isSuppressed: postInsertionZoomSuppressed,
                tokenMatches: postInsertionZoomSuppressionToken == token,
                isSimulationActive: parent.isSimulationActive,
                isMapGestureActive: isMapGestureActive(on: mapView)
            )
            guard canRestore else {
                guard postInsertionZoomSuppressed,
                      postInsertionZoomSuppressionToken == token else { return }
                schedulePostInsertionZoomRestore(token: token)
                return
            }

            let shouldRestoreZoom = postInsertionRestoreZoomEnabled
            postInsertionZoomSuppressed = false
            postInsertionZoomSuppressionToken = nil
            postInsertionZoomRestoreWorkItem = nil
            mapView.isZoomEnabled = shouldRestoreZoom
            mapView.isScrollEnabled = true
            mapView.isRotateEnabled = true
        }

        private func finishPostInsertionZoomSuppressionWithoutRestore() {
            postInsertionZoomRestoreWorkItem?.cancel()
            postInsertionZoomRestoreWorkItem = nil
            postInsertionZoomSuppressionToken = nil
            postInsertionZoomSuppressed = false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            if gestureRecognizer.name == "RoutePointPan" {
                return parent.isEditing
            }
            var view: UIView? = touch.view
            while let current = view {
                if current is MKAnnotationView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // RoutePointPan 拖曳路點時，不允許同時識別地圖的 pan/pinch，避免誤觸縮放。
            if gestureRecognizer.name == "RoutePointPan"
                || otherGestureRecognizer.name == "RoutePointPan" {
                return false
            }
            return true
        }

        private func startDisplayLink(for mapView: MKMapView) {
            self.mapView = mapView
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(refreshDraggingPolyline))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func refreshDraggingPolyline() {
            guard let mapView else { return }
            updatePolyline(on: mapView)
        }

        private func updatePolyline(
            on mapView: MKMapView,
            rebuildOverlay: Bool = false
        ) {
            let coordinates = pointAnnotations(in: mapView)
                .map(\.coordinate)
                .filter(CLLocationCoordinate2DIsValid)
            guard coordinates.count > 1 else {
                if let routeOverlay {
                    mapView.removeOverlay(routeOverlay)
                    self.routeOverlay = nil
                    routeRenderer = nil
                }
                return
            }
            if !rebuildOverlay,
               let routeOverlay,
               mapView.overlays.contains(where: { $0 === routeOverlay }) {
                routeRenderer?.update(coordinates: coordinates)
            } else {
                if let routeOverlay {
                    mapView.removeOverlay(routeOverlay)
                }
                routeRenderer = nil
                let overlay = LiveRouteOverlay(coordinates: coordinates)
                self.routeOverlay = overlay
                mapView.addOverlay(overlay)
            }
        }

        private func updateSimulationMarker(on mapView: MKMapView) {
            if !parent.sharedMapState.isSimulationActive {
                followsSimulation = true
            }
            let existing = mapView.annotations.compactMap {
                $0 as? RouteSimulationMapAnnotation
            }
            guard let coordinate = parent.simulatedCoordinate else {
                mapView.removeAnnotations(existing)
                return
            }
            let annotation: RouteSimulationMapAnnotation
            if let current = existing.first {
                annotation = current
                if CLLocation(
                    latitude: annotation.coordinate.latitude,
                    longitude: annotation.coordinate.longitude
                ).distance(from: CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )) > 0.01 {
                    annotation.coordinate = coordinate
                }
                annotation.heading = parent.simulatedHeading
                annotation.moving = parent.isSimulationMoving
            } else {
                annotation = RouteSimulationMapAnnotation(
                    coordinate: coordinate,
                    heading: parent.simulatedHeading,
                    moving: parent.isSimulationMoving
                )
                mapView.addAnnotation(annotation)
            }
            if let view = mapView.view(for: annotation) as? RouteSimulationAnnotationView {
                view.zPriority = .max
                view.layer.zPosition = 10_000
                view.configure(heading: annotation.heading, moving: annotation.moving)
                configureSimulationInteraction(for: view)
            }
            if parent.isSimulationMoving,
                    followsSimulation,
               !isMapInteractionOngoing(on: mapView),
               shouldFollow(coordinate) {
                lastFollowedCoordinate = coordinate
                mapView.setCenter(coordinate, animated: false)
            } else if !parent.isSimulationMoving {
                lastFollowedCoordinate = nil
            }
        }

        func isMapInteractionOngoing(on mapView: MKMapView) -> Bool {
            if isMapGestureActive(on: mapView) {
                lastGestureActivityAt = Date()
                return true
            }
            return Date().timeIntervalSince(lastGestureActivityAt) < gestureSettleDuration
        }

        func isMapGestureActive(on mapView: MKMapView) -> Bool {
            mapView.gestureRecognizers?.contains {
                $0.state == .began || $0.state == .changed
            } == true
        }

        private func shouldFollow(_ coordinate: CLLocationCoordinate2D) -> Bool {
            guard let lastFollowedCoordinate else { return true }
            return CLLocation(
                latitude: lastFollowedCoordinate.latitude,
                longitude: lastFollowedCoordinate.longitude
            ).distance(from: CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )) > 0.01
        }

        private func commitAnnotations(from mapView: MKMapView) {
            let annotations = pointAnnotations(in: mapView)
            var route = parent.route
            for annotation in annotations {
                guard let index = route.points.firstIndex(where: {
                    $0.id == annotation.pointID
                }) else { continue }
                route.points[index].latitude = annotation.coordinate.latitude
                route.points[index].longitude = annotation.coordinate.longitude
            }
            parent.route = route
        }

        private func pointAnnotations(in mapView: MKMapView) -> [RoutePointMapAnnotation] {
            mapView.annotations
                .compactMap { $0 as? RoutePointMapAnnotation }
                .sorted { $0.order < $1.order }
        }

        private func refreshSelection(on mapView: MKMapView) {
            for annotation in pointAnnotations(in: mapView) {
                guard let view = mapView.view(for: annotation) as? RoutePointAnnotationView else {
                    continue
                }
                view.displayPriority = parent.isEditing ? .required : .defaultLow
                view.zPriority = parent.isEditing ? .max : .defaultUnselected
                view.layer.zPosition = parent.isEditing ? 20_000 : 0
                view.configure(
                    order: annotation.order,
                    selected: annotation.pointID == parent.selectedPointID
                )
                updateRoutePointInteraction(for: view)
            }
        }

        private func updateRoutePointInteraction(for view: RoutePointAnnotationView) {
            view.isDraggable = false
            view.isEnabled = parent.isEditing
            view.isUserInteractionEnabled = parent.isEditing
            view.gestureRecognizers?.forEach { recognizer in
                if recognizer.name == "RoutePointPan"
                    || recognizer.name == "RoutePointTap" {
                    recognizer.isEnabled = parent.isEditing
                }
            }
        }

        private func configureSimulationInteraction(
            for view: RouteSimulationAnnotationView
        ) {
            view.isEnabled = parent.isEditing
            view.isUserInteractionEnabled = parent.isEditing
            if parent.isEditing,
               view.gestureRecognizers?.contains(where: {
                   $0.name == "RouteSimulationTap"
               }) != true {
                let tap = UITapGestureRecognizer(
                    target: self,
                    action: #selector(handleSimulationMarkerTap(_:))
                )
                tap.name = "RouteSimulationTap"
                view.addGestureRecognizer(tap)
            }
        }
    }
}

private final class LiveRouteOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(coordinates: [CLLocationCoordinate2D]) {
        let points = coordinates
            .filter(CLLocationCoordinate2DIsValid)
            .map(MKMapPoint.init)
        let routeRect = points.reduce(MKMapRect.null) { rect, point in
            rect.union(MKMapRect(origin: point, size: MKMapSize(width: 1, height: 1)))
        }
        // 固定留白即可涵蓋線寬；不可用整段路線跨度作為留白，否則長路線
        // 會把 overlay 外框膨脹到 MapKit 無法穩定裁切而整條不顯示。
        let padding: Double = 4_096
        boundingMapRect = routeRect.insetBy(dx: -padding, dy: -padding)
        coordinate = MKMapPoint(
            x: boundingMapRect.midX,
            y: boundingMapRect.midY
        ).coordinate
        super.init()
    }
}

private final class LiveRouteOverlayRenderer: MKOverlayPathRenderer {
    private var coordinates: [CLLocationCoordinate2D]

    init(overlay: MKOverlay, coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        super.init(overlay: overlay)
        strokeColor = .systemBlue
        lineWidth = 4
        lineCap = .round
        lineJoin = .round
    }

    func update(coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        invalidatePath()
        setNeedsDisplay()
    }

    override func createPath() {
        let path = CGMutablePath()
        for (index, coordinate) in coordinates.enumerated() {
            let point = point(for: MKMapPoint(coordinate))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        self.path = path
    }
}

private final class RoutePointMapAnnotation: MKPointAnnotation {
    let pointID: UUID
    var order: Int

    init(pointID: UUID, order: Int, coordinate: CLLocationCoordinate2D) {
        self.pointID = pointID
        self.order = order
        super.init()
        self.coordinate = coordinate
    }
}

private final class RoutePointAnnotationView: MKAnnotationView {
    private let numberLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        centerOffset = .zero
        backgroundColor = .systemBlue
        layer.cornerRadius = 12
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        numberLabel.frame = bounds
        numberLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        numberLabel.textAlignment = .center
        numberLabel.textColor = .white
        numberLabel.font = .systemFont(ofSize: 12, weight: .heavy)
        addSubview(numberLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(order: Int, selected: Bool) {
        numberLabel.text = "\(order + 1)"
        backgroundColor = .systemBlue
        layer.borderColor = (selected ? UIColor.systemRed : UIColor.white).cgColor
        layer.borderWidth = selected ? 3 : 2
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        dragState = .none
    }
}

private final class RouteSimulationMapAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    var heading: Double
    var moving: Bool

    init(coordinate: CLLocationCoordinate2D, heading: Double, moving: Bool) {
        self.coordinate = coordinate
        self.heading = heading
        self.moving = moving
    }
}

private final class RouteSimulationAnnotationView: MKAnnotationView {
    private let marker = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        marker.frame = bounds
        marker.contentMode = .center
        marker.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 12,
            weight: .bold
        )
        marker.tintColor = .white
        marker.backgroundColor = .systemBlue
        marker.layer.cornerRadius = 12
        marker.layer.borderColor = UIColor.white.cgColor
        marker.layer.borderWidth = 2
        addSubview(marker)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(heading: Double, moving: Bool) {
        marker.image = moving ? UIImage(systemName: "location.north.fill") : nil
        marker.transform = CGAffineTransform(rotationAngle: heading * .pi / 180)
    }
}
