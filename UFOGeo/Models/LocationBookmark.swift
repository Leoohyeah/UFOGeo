import CoreLocation
import Foundation

extension Notification.Name {
    static let locationBookmarksDidChange = Notification.Name(
        "com.ufogeo.location-bookmarks-did-change"
    )
}

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum LocationBookmarkStore {
    private static let key = UserDefaults.Keys.locationBookmarks

    static func load() -> [LocationBookmark] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LocationBookmark].self, from: data)) ?? []
    }

    static func save(_ bookmarks: [LocationBookmark]) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: .locationBookmarksDidChange, object: nil)
    }
}
