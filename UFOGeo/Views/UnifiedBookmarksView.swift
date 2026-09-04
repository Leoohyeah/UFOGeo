import SwiftUI
import UIKit
import MapKit

struct LocationHistoryRecord: Identifiable, Codable {
    enum Kind: String, Codable { case location = "定位", routeStart = "路線起點", routeEnd = "路線終點" }
    var id = UUID()
    let kind: Kind
    let latitude: Double
    let longitude: Double
    let date: Date
    let routeName: String?
    var displayName: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum LocationHistoryStore {
    private static let key = UserDefaults.Keys.locationHistoryRecords
    private static let maximumCount = 100
    private static let mergeDistanceMeters: CLLocationDistance = 8
    private static let mergeInterval: TimeInterval = 20

    static func load() -> [LocationHistoryRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let decoded = (try? JSONDecoder().decode([LocationHistoryRecord].self, from: data)) ?? []
        let valid = decoded.filter { record in
            (-90...90).contains(record.latitude) && (-180...180).contains(record.longitude)
        }
        return valid.sorted { $0.date > $1.date }
    }

    static func add(kind: LocationHistoryRecord.Kind, coordinate: CLLocationCoordinate2D, routeName: String? = nil) {
        var records = load()
        let record = LocationHistoryRecord(
            kind: kind,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            date: Date(),
            routeName: routeName
        )
        if let first = records.first,
           shouldMerge(first, with: record) {
            var merged = record
            merged.id = first.id
            merged.displayName = first.displayName
            records[0] = merged
        } else {
            records.insert(record, at: 0)
        }
        save(Array(records.prefix(maximumCount)))
        if records.first?.displayName == nil {
            resolveDisplayName(for: records[0])
        }
    }

    static func save(_ records: [LocationHistoryRecord]) {
        let newestRecords = records
            .sorted { $0.date > $1.date }
            .prefix(maximumCount)
        guard let data = try? JSONEncoder().encode(Array(newestRecords)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func resolveDisplayName(for record: LocationHistoryRecord) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: record.latitude, longitude: record.longitude)
        geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_Hant_TW")) { placemarks, _ in
            defer { _ = geocoder }
            guard let placemark = placemarks?.first else { return }
            let country = placemark.country?.trimmingCharacters(in: .whitespacesAndNewlines)
            let city = (placemark.locality ?? placemark.administrativeArea ?? placemark.subAdministrativeArea)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let components = [country, city]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .reduce(into: [String]()) { result, value in
                    if !result.contains(value) { result.append(value) }
                }
            guard !components.isEmpty else { return }

            DispatchQueue.main.async {
                var records = load()
                guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
                records[index].displayName = components.joined(separator: ", ")
                save(records)
            }
        }
    }

    private static func shouldMerge(
        _ existing: LocationHistoryRecord,
        with incoming: LocationHistoryRecord
    ) -> Bool {
        guard existing.kind == incoming.kind,
              existing.routeName == incoming.routeName,
              abs(existing.date.timeIntervalSince(incoming.date)) <= mergeInterval else {
            return false
        }

        let existingLocation = CLLocation(latitude: existing.latitude, longitude: existing.longitude)
        let incomingLocation = CLLocation(latitude: incoming.latitude, longitude: incoming.longitude)
        return existingLocation.distance(from: incomingLocation) <= mergeDistanceMeters
    }
}

struct UnifiedBookmarksView: View {
    private enum BookmarkKind: String, CaseIterable, Identifiable {
        case location = "定位"
        case route = "路線"
        case history = "歷史"
        var id: String { rawValue }
    }

    private enum SortOrder: String, CaseIterable, Identifiable {
        case custom = "自訂順序"
        case nameAsc = "名稱 A → Z"
        case nameDesc = "名稱 Z → A"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedMapState: SharedLocationMapState
    @StateObject private var routeManager = JoystickModeManager()
    @State private var kind: BookmarkKind = .location
    @State private var locationBookmarks: [LocationBookmark]
    @State private var historyRecords: [LocationHistoryRecord]
    @State private var copiedMessage: String?
    @State private var editingLocationBookmark: LocationBookmark?
    @State private var editingRoute: SimulationRoute?
    @State private var sortOrder: SortOrder = .custom

    let onSelectLocation: ((LocationBookmark) -> Void)?
    let onSelectHistory: ((CLLocationCoordinate2D) -> Void)?
    let onLocationBookmarksChanged: (([LocationBookmark]) -> Void)?

    init(
        locationBookmarks: [LocationBookmark]? = nil,
        onSelectLocation: ((LocationBookmark) -> Void)? = nil,
        onSelectHistory: ((CLLocationCoordinate2D) -> Void)? = nil,
        onLocationBookmarksChanged: (([LocationBookmark]) -> Void)? = nil
    ) {
        let stored = LocationBookmarkStore.load()
        _locationBookmarks = State(initialValue: locationBookmarks ?? stored)
        _historyRecords = State(initialValue: LocationHistoryStore.load())
        self.onSelectLocation = onSelectLocation
        self.onSelectHistory = onSelectHistory
        self.onLocationBookmarksChanged = onLocationBookmarksChanged
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("收藏類型", selection: $kind) {
                    ForEach(BookmarkKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if kind == .location {
                    locationList
                } else if kind == .route {
                    routeList
                } else {
                    historyList
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if kind == .history, !historyRecords.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("全部清除", role: .destructive) {
                            historyRecords.removeAll()
                            LocationHistoryStore.save(historyRecords)
                        }
                        .disabled(sharedMapState.isSimulationInteractionLocked)
                    }
                }
                if kind == .location || kind == .route {
                    ToolbarItem(placement: .cancellationAction) {
                        Menu {
                            Picker("排序", selection: $sortOrder) {
                                ForEach(SortOrder.allCases) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                        } label: {
                            Label("排序", systemImage: "arrow.up.arrow.down")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("已複製", isPresented: Binding(
                get: { copiedMessage != nil },
                set: { if !$0 { copiedMessage = nil } }
            )) {
                Button("確定", role: .cancel) { copiedMessage = nil }
            } message: {
                Text(copiedMessage ?? "")
            }
            .sheet(item: $editingLocationBookmark) { bookmark in
                LocationBookmarkEditorView(bookmark: bookmark) { updated in
                    saveEditedLocation(updated)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $editingRoute) { route in
                RouteBookmarkEditorView(route: route) { updated in
                    guard !sharedMapState.isSimulationInteractionLocked else {
                        editingRoute = nil
                        return
                    }
                    routeManager.saveRoute(updated)
                    routeManager.reloadRoutes()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                locationBookmarks = LocationBookmarkStore.load()
                historyRecords = LocationHistoryStore.load()
                routeManager.reloadRoutes()
            }
        }
    }

    @ViewBuilder private var historyList: some View {
        if historyRecords.isEmpty {
            ContentUnavailableView("尚無歷史定位", systemImage: "clock.arrow.circlepath", description: Text("成功啟動定位或路線後會自動記錄。"))
        } else {
            List {
                Section("最近紀錄") {
                    ForEach(historyRecords) { record in
                        Button {
                            selectCoordinate(
                                record.coordinate,
                                updatesSelection: !sharedMapState.isSimulationActive
                            )
                            onSelectHistory?(record.coordinate)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(record.displayName ?? "座標位置", systemImage: record.kind == .location ? "location.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(CoordinateDisplayFormatter.string(record.coordinate))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text([record.kind.rawValue, record.routeName].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(sharedMapState.isSimulationTransitioning)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button { copyHistory(record) } label: {
                                Label("複製", systemImage: "doc.on.doc")
                            }
                            .tint(.accentColor)
                            Button { favoriteHistory(record) } label: {
                                Label("收藏", systemImage: "bookmark.fill")
                            }
                            .tint(.orange)
                            .disabled(sharedMapState.isSimulationInteractionLocked)
                        }
                    }
                    .onDelete(
                        perform: sharedMapState.isSimulationInteractionLocked
                            ? nil
                            : deleteHistory
                    )
                }
            }
        }
    }

    @ViewBuilder private var locationList: some View {
        if locationBookmarks.isEmpty {
            ContentUnavailableView("尚無定位收藏", systemImage: "bookmark", description: Text("在定位頁選擇座標後即可加入收藏。"))
        } else {
            List {
                Section("定位收藏") {
                    ForEach(sortedLocationBookmarks) { bookmark in
                        Button {
                            selectCoordinate(bookmark.coordinate)
                            onSelectLocation?(bookmark)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(bookmark.name, systemImage: "location.fill")
                                    .foregroundStyle(.primary)
                                Text(CoordinateDisplayFormatter.string(bookmark.coordinate))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(sharedMapState.isSimulationTransitioning)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingLocationBookmark = bookmark
                            } label: {
                                Label("編輯", systemImage: "pencil")
                            }
                            .tint(.orange)
                            .disabled(sharedMapState.isSimulationInteractionLocked)
                            Button {
                                copyLocation(bookmark)
                            } label: {
                                Label("複製", systemImage: "doc.on.doc")
                            }
                            .tint(.accentColor)
                        }
                    }
                    .onDelete(
                        perform: sortOrder == .custom
                            && !sharedMapState.isSimulationInteractionLocked
                            ? deleteLocations
                            : nil
                    )
                    .onMove(
                        perform: sortOrder == .custom
                            && !sharedMapState.isSimulationInteractionLocked
                            ? moveLocations
                            : nil
                    )
                }
            }
        }
    }

    @ViewBuilder private var routeList: some View {
        if routeManager.favoriteRoutes.isEmpty {
            ContentUnavailableView(
                "尚無路線收藏",
                systemImage: "bookmark",
                description: Text("在路線頁按下書籤後才會顯示在這裡。")
            )
        } else {
            List {
                Section("路線收藏") {
                    ForEach(sortedRoutes) { route in
                        Button {
                            applyRoute(route)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(route.name, systemImage: route.isFavorite ? "bookmark.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                                    .foregroundStyle(.primary)
                                Text("\(route.points.count) 個路點")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(sharedMapState.isSimulationInteractionLocked)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                guard !sharedMapState.isSimulationInteractionLocked else { return }
                                routeManager.deleteRoute(route)
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                            .disabled(sharedMapState.isSimulationInteractionLocked)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                guard !sharedMapState.isSimulationInteractionLocked else { return }
                                editingRoute = route
                            } label: {
                                Label("編輯", systemImage: "pencil")
                            }
                            .tint(.orange)
                            .disabled(sharedMapState.isSimulationInteractionLocked)
                            Button {
                                copyRoute(route)
                            } label: {
                                Label("複製", systemImage: "doc.on.doc")
                            }
                            .tint(.accentColor)
                        }
                    }
                    .onMove(
                        perform: sortOrder == .custom
                            && !sharedMapState.isSimulationInteractionLocked
                            ? moveRoutes
                            : nil
                    )
                }
            }
        }
    }

    private var sortedLocationBookmarks: [LocationBookmark] {
        switch sortOrder {
        case .custom: return locationBookmarks
        case .nameAsc: return locationBookmarks.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .nameDesc: return locationBookmarks.sorted { $0.name.localizedCompare($1.name) == .orderedDescending }
        }
    }

    private var sortedRoutes: [SimulationRoute] {
        switch sortOrder {
        case .custom: return routeManager.favoriteRoutes
        case .nameAsc: return routeManager.favoriteRoutes.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .nameDesc: return routeManager.favoriteRoutes.sorted { $0.name.localizedCompare($1.name) == .orderedDescending }
        }
    }

    private func selectCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        updatesSelection: Bool = true
    ) {
        if updatesSelection {
            sharedMapState.selectedCoordinate = coordinate
        }
        sharedMapState.mapPosition = .region(
            SharedLocationMapState.defaultSimulationRegion(centeredAt: coordinate)
        )
        sharedMapState.nativeMapCenterRequest = NativeMapCenterRequest(
            coordinate: coordinate,
            preserveZoom: false
        )
        SharedNativeMapStore.shared.center(
            at: coordinate,
            preserveZoom: false
        )
    }

    private func moveLocations(from source: IndexSet, to destination: Int) {
        guard !sharedMapState.isSimulationInteractionLocked else { return }
        locationBookmarks.move(fromOffsets: source, toOffset: destination)
        LocationBookmarkStore.save(locationBookmarks)
        onLocationBookmarksChanged?(locationBookmarks)
    }

    private func moveRoutes(from source: IndexSet, to destination: Int) {
        guard !sharedMapState.isSimulationInteractionLocked else { return }
        routeManager.reorderFavoriteRoutes(from: source, to: destination)
        routeManager.reloadRoutes()
    }

    private func deleteLocations(at offsets: IndexSet) {
        guard !sharedMapState.isSimulationInteractionLocked else { return }
        locationBookmarks.remove(atOffsets: offsets)
        LocationBookmarkStore.save(locationBookmarks)
        onLocationBookmarksChanged?(locationBookmarks)
    }

    private func saveEditedLocation(_ bookmark: LocationBookmark) {
        guard !sharedMapState.isSimulationInteractionLocked else { return }
        guard let index = locationBookmarks.firstIndex(where: { $0.id == bookmark.id }) else {
            return
        }
        locationBookmarks[index] = bookmark
        LocationBookmarkStore.save(locationBookmarks)
        onLocationBookmarksChanged?(locationBookmarks)
    }

    private func copyLocation(_ bookmark: LocationBookmark) {
        UIPasteboard.general.string = CoordinateDisplayFormatter.string(bookmark.coordinate)
        copiedMessage = "已複製「\(bookmark.name)」的座標"
    }

    private func copyRoute(_ route: SimulationRoute) {
        UIPasteboard.general.string = route.points.map { point in
            CoordinateDisplayFormatter.string(point.coordinate)
        }.joined(separator: "\n")
        copiedMessage = "已複製「\(route.name)」的 \(route.points.count) 個座標"
    }

    private func applyRoute(_ route: SimulationRoute) {
        guard !sharedMapState.isSimulationInteractionLocked else { return }
        sharedMapState.requestedRouteID = route.id
        sharedMapState.requestedTabID = AppFeature.pathSimulation.id
        if let coordinate = route.points.first?.coordinate {
            selectCoordinate(coordinate)
        }
        dismiss()
    }

    private func copyHistory(_ record: LocationHistoryRecord) {
        UIPasteboard.general.string = CoordinateDisplayFormatter.string(record.coordinate)
        copiedMessage = "已複製歷史座標"
    }

    private func favoriteHistory(_ record: LocationHistoryRecord) {
        guard !sharedMapState.isSimulationInteractionLocked else { return }
        guard !locationBookmarks.contains(where: {
            abs($0.latitude - record.latitude) < 0.000_001 && abs($0.longitude - record.longitude) < 0.000_001
        }) else {
            copiedMessage = "此座標已在收藏中"
            return
        }
        locationBookmarks.append(LocationBookmark(
            name: record.routeName ?? "歷史位置",
            latitude: record.latitude,
            longitude: record.longitude
        ))
        LocationBookmarkStore.save(locationBookmarks)
        onLocationBookmarksChanged?(locationBookmarks)
        copiedMessage = "已加入定位收藏"
    }

    private func deleteHistory(at offsets: IndexSet) {
        guard !sharedMapState.isSimulationInteractionLocked else { return }
        historyRecords.remove(atOffsets: offsets)
        LocationHistoryStore.save(historyRecords)
    }
}

private struct LocationBookmarkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bookmark: LocationBookmark
    @State private var coordinateText: String
    let onSave: (LocationBookmark) -> Void

    init(bookmark: LocationBookmark, onSave: @escaping (LocationBookmark) -> Void) {
        _bookmark = State(initialValue: bookmark)
        _coordinateText = State(
            initialValue: editableCoordinateString(
                latitude: bookmark.latitude,
                longitude: bookmark.longitude
            )
        )
        self.onSave = onSave
    }

    private var isValid: Bool {
        !bookmark.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedEditableCoordinate(coordinateText) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField("點位名稱", text: $bookmark.name)
                }
                Section("座標") {
                    LabeledContent("座標") {
                        TextField("24.000000, 120.000000", text: $coordinateText)
                            .multilineTextAlignment(.trailing)
                            .numericInputStyle(
                                keyboard: .signedDecimal,
                                clearsOnFocus: false
                            )
                    }
                }
            }
            .navigationTitle("編輯定位收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        guard let coordinate = parsedEditableCoordinate(coordinateText) else {
                            return
                        }
                        bookmark.name = bookmark.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        bookmark.latitude = coordinate.latitude
                        bookmark.longitude = coordinate.longitude
                        onSave(bookmark)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

private struct RouteBookmarkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var route: SimulationRoute
    @State private var coordinateTexts: [UUID: String]
    let onSave: (SimulationRoute) -> Void

    init(route: SimulationRoute, onSave: @escaping (SimulationRoute) -> Void) {
        _route = State(initialValue: route)
        _coordinateTexts = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: route.points.map { point in
                    (
                        point.id,
                        editableCoordinateString(
                            latitude: point.latitude,
                            longitude: point.longitude
                        )
                    )
                }
            )
        )
        self.onSave = onSave
    }

    private var isValid: Bool {
        route.isValid
            && !route.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && route.points.allSatisfy { point in
                coordinateTexts[point.id].flatMap(parsedEditableCoordinate) != nil
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("路線名稱") {
                    TextField("路線名稱", text: $route.name)
                }
                Section {
                    ForEach(route.points) { point in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("第 \(point.order + 1) 點")
                                .font(.subheadline.weight(.semibold))
                            LabeledContent("座標") {
                                TextField(
                                    "24.000000, 120.000000",
                                    text: coordinateTextBinding(for: point.id)
                                )
                                    .multilineTextAlignment(.trailing)
                                    .numericInputStyle(
                                        keyboard: .signedDecimal,
                                        clearsOnFocus: false
                                    )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        let deletedIDs = offsets.map { route.points[$0].id }
                        route.points.remove(atOffsets: offsets)
                        for id in deletedIDs {
                            coordinateTexts[id] = nil
                        }
                        normalizeOrder()
                    }
                    .onMove { source, destination in
                        route.points.move(fromOffsets: source, toOffset: destination)
                        normalizeOrder()
                    }
                } header: {
                    Text("路點")
                } footer: {
                    Text("拖曳可調整順序；向左滑可刪除路點。路線至少需要兩個點。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("編輯收藏路線")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        guard applyCoordinateTexts() else { return }
                        route.name = route.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        normalizeOrder()
                        onSave(route)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func normalizeOrder() {
        for index in route.points.indices {
            route.points[index].order = index
        }
    }

    private func coordinateTextBinding(for pointID: UUID) -> Binding<String> {
        Binding(
            get: { coordinateTexts[pointID] ?? "" },
            set: { coordinateTexts[pointID] = $0 }
        )
    }

    private func applyCoordinateTexts() -> Bool {
        for index in route.points.indices {
            let pointID = route.points[index].id
            guard let text = coordinateTexts[pointID],
                  let coordinate = parsedEditableCoordinate(text) else {
                return false
            }
            route.points[index].latitude = coordinate.latitude
            route.points[index].longitude = coordinate.longitude
        }
        return true
    }
}

private func editableCoordinateString(latitude: Double, longitude: Double) -> String {
    String(
        format: "%.6f, %.6f",
        locale: Locale(identifier: "en_US_POSIX"),
        latitude,
        longitude
    )
}

private func parsedEditableCoordinate(_ text: String) -> CLLocationCoordinate2D? {
    let components = text
        .replacingOccurrences(of: "，", with: ",")
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard components.count == 2,
          let latitude = Double(components[0]),
          let longitude = Double(components[1]) else {
        return nil
    }
    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
}

#Preview {
    UnifiedBookmarksView()
        .environmentObject(SharedLocationMapState())
}
