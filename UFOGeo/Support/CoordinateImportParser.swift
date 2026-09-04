import CoreLocation
import Foundation
import UniformTypeIdentifiers

enum CoordinateImportError: LocalizedError {
    case emptyFile
    case noCoordinates
    case unsupportedFileExtension(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile: return "匯入的檔案是空的。"
        case .noCoordinates:
            return "找不到有效座標。支援 GPX、KML、GeoJSON、JSON、CSV 或純文字格式（緯度、經度）。"
        case .unsupportedFileExtension(let fileExtension):
            let suffix = fileExtension.isEmpty ? "（無副檔名）" : ".\(fileExtension)"
            return "不支援的路線檔案副檔名：\(suffix)。請選擇 GPX、KML、GeoJSON、JSON、CSV 或 TXT 檔案。"
        }
    }
}

enum CoordinateImportParser {
    static let supportedFileExtensions: Set<String> = [
        "gpx", "kml", "geojson", "json", "csv", "txt"
    ]

    // Kept as a narrowly scoped convenience for callers that intentionally
    // want a GPX-only picker. It must never fall back to the generic XML type.
    static let gpxContentTypes: [UTType] = [
        UTType(filenameExtension: "gpx")!
    ]

    static func parse(url: URL) throws -> [CLLocationCoordinate2D] {
        let fileExtension = url.pathExtension.lowercased()
        guard supportedFileExtensions.contains(fileExtension) else {
            throw CoordinateImportError.unsupportedFileExtension(fileExtension)
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CoordinateImportError.emptyFile }

        if ["gpx", "kml"].contains(fileExtension) {
            let coordinates = parseXMLCoordinates(from: data)
            if !coordinates.isEmpty { return coordinates }
        }
        if ["json", "geojson"].contains(fileExtension),
           let coordinates = try? parseJSONCoordinates(from: data),
           !coordinates.isEmpty {
            return coordinates
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
            let coordinates = parseInline(text)
            if !coordinates.isEmpty { return coordinates }
        }
        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        text.components(separatedBy: .newlines).compactMap { line in
            let numbers = extractNumbers(from: line)
            guard numbers.count >= 2 else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: numbers[0], longitude: numbers[1])
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }
    }

    private static func extractNumbers(from text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }

    private static func parseXMLCoordinates(from data: Data) -> [CLLocationCoordinate2D] {
        let collector = XMLCoordinateCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.coordinates
    }

    private final class XMLCoordinateCollector: NSObject, XMLParserDelegate {
        var coordinates: [CLLocationCoordinate2D] = []
        private var kmlBuffer = ""
        private var isCollecting = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let lower = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(lower),
               let latitude = Double(attributeDict["lat"] ?? ""),
               let longitude = Double(attributeDict["lon"] ?? "") {
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if CLLocationCoordinate2DIsValid(coordinate) { coordinates.append(coordinate) }
            } else if lower == "coordinates" {
                isCollecting = true
                kmlBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollecting { kmlBuffer += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "coordinates" else { return }
            for value in kmlBuffer.split(whereSeparator: { $0.isWhitespace }) {
                let parts = value.split(separator: ",").compactMap { Double($0) }
                guard parts.count >= 2 else { continue }
                let coordinate = CLLocationCoordinate2D(latitude: parts[1], longitude: parts[0])
                if CLLocationCoordinate2DIsValid(coordinate) { coordinates.append(coordinate) }
            }
            isCollecting = false
        }
    }

    private static func parseJSONCoordinates(from data: Data) throws -> [CLLocationCoordinate2D] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let dictionary = json as? [String: Any], dictionary["type"] is String {
            return extractGeoJSONCoordinates(json)
        }
        return extractCoordinatesFromJSON(json)
    }

    private static func extractGeoJSONCoordinates(_ object: Any) -> [CLLocationCoordinate2D] {
        guard let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String else { return [] }

        switch type.lowercased() {
        case "featurecollection":
            return (dictionary["features"] as? [Any] ?? []).flatMap(extractGeoJSONCoordinates)
        case "feature":
            return dictionary["geometry"].map(extractGeoJSONCoordinates) ?? []
        case "geometrycollection":
            return (dictionary["geometries"] as? [Any] ?? []).flatMap(extractGeoJSONCoordinates)
        default:
            guard let coordinates = dictionary["coordinates"] else { return [] }
            return extractLongitudeLatitudePairs(coordinates)
        }
    }

    private static func extractLongitudeLatitudePairs(_ object: Any) -> [CLLocationCoordinate2D] {
        guard let array = object as? [Any] else { return [] }
        if array.count >= 2,
           let longitude = array[0] as? Double,
           let latitude = array[1] as? Double {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return CLLocationCoordinate2DIsValid(coordinate) ? [coordinate] : []
        }
        return array.flatMap(extractLongitudeLatitudePairs)
    }

    private static func extractCoordinatesFromJSON(_ object: Any) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        if let dictionary = object as? [String: Any] {
            if let latitude = dictionary["latitude"] as? Double ?? dictionary["lat"] as? Double,
               let longitude = dictionary["longitude"] as? Double
                    ?? dictionary["lon"] as? Double
                    ?? dictionary["lng"] as? Double {
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if CLLocationCoordinate2DIsValid(coordinate) { result.append(coordinate) }
            }
            for value in dictionary.values {
                result.append(contentsOf: extractCoordinatesFromJSON(value))
            }
        } else if let array = object as? [Any] {
            if array.count >= 2, let latitude = array[0] as? Double, let longitude = array[1] as? Double {
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if CLLocationCoordinate2DIsValid(coordinate) { result.append(coordinate) }
            }
            for value in array { result.append(contentsOf: extractCoordinatesFromJSON(value)) }
        }
        return result
    }
}
