import Foundation
import Testing
import UniformTypeIdentifiers
@testable import UFOGeo

@Suite(.serialized)
struct ImportTypeIsolationTests {
    private static let pairingExtensions: Set<String> = [
        "plist",
        "mobiledevicepairing",
        "mobiledevicepair"
    ]

    private func filenameExtensions(for contentTypes: [UTType]) -> Set<String> {
        Set(
            contentTypes
                .flatMap { $0.tags[.filenameExtension] ?? [] }
                .map { $0.lowercased() }
        )
    }

    @Test func manualPairingPickerAllowsExactlyThreePairingExtensions() {
        #expect(PairingFileStore.supportedFileExtensions == Self.pairingExtensions)
        #expect(
            filenameExtensions(for: PairingFileStore.supportedContentTypes)
                == Self.pairingExtensions
        )
        #expect(PairingFileStore.supportedContentTypes.count == Self.pairingExtensions.count)
    }

    @Test func manualPairingImportRejectsEveryRouteFileExtension() throws {
        for fileExtension in ["gpx", "kml", "geojson", "json", "csv", "txt"] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try Data("25.0330, 121.5654".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(throws: PairingFileError.unsupportedFileExtension(fileExtension)) {
                try PairingFileStore.importFromPicker(url)
            }
        }
    }

    @Test func pairingValidationAcceptsImpactorRemotePairingOnlyFile() throws {
        try PairingFileStore.validate(Self.validPairingData(includeLockdownFields: false))
    }

    @Test func pairingValidationAcceptsILoaderCombinedPairingFile() throws {
        try PairingFileStore.validate(Self.validPairingData())
    }

    @Test func pairingValidationRejectsWrongRemotePairingKeyLengthOrEmptyIdentifier() throws {
        let shortPublicKeyData = try Self.validPairingData(publicKeyLength: 31)
        #expect(throws: PairingFileError.invalidField("public_key")) {
            try PairingFileStore.validate(shortPublicKeyData)
        }

        let shortPrivateKeyData = try Self.validPairingData(privateKeyLength: 33)
        #expect(throws: PairingFileError.invalidField("private_key")) {
            try PairingFileStore.validate(shortPrivateKeyData)
        }

        let emptyIdentifierData = try Self.validPairingData(identifier: " \n ")
        #expect(throws: PairingFileError.invalidField("identifier")) {
            try PairingFileStore.validate(emptyIdentifierData)
        }
    }

    @Test func prepareURLDoesNotMoveOrDeleteLegacyPairingSource() throws {
        let fileManager = FileManager.default
        removeStoredPairingFile(fileManager: fileManager)

        let sourceURL = URL.documentsDirectory
            .appendingPathComponent("legacy-pairing-\(UUID().uuidString).plist")
        try Self.validPairingData().write(to: sourceURL, options: .atomic)
        defer {
            try? fileManager.removeItem(at: sourceURL)
        }

        let destinationURL = PairingFileStore.prepareURL(fileManager: fileManager)

        #expect(fileManager.fileExists(atPath: sourceURL.path))
        #expect(!fileManager.fileExists(atPath: destinationURL.path))
    }

    @Test func manualPairingImportCopiesOnlyTheSelectedFile() throws {
        let fileManager = FileManager.default
        removeStoredPairingFile(fileManager: fileManager)

        let sourceURL = fileManager.temporaryDirectory
            .appendingPathComponent("selected-pairing-\(UUID().uuidString).plist")
        let sourceData = try Self.validPairingData()
        try sourceData.write(to: sourceURL, options: .atomic)
        defer {
            try? fileManager.removeItem(at: sourceURL)
            removeStoredPairingFile(fileManager: fileManager)
        }

        try PairingFileStore.importFromPicker(sourceURL, fileManager: fileManager)

        #expect(fileManager.fileExists(atPath: sourceURL.path))
        let storedData = try Data(contentsOf: PairingFileStore.url)
        #expect(storedData == sourceData)
    }

    @Test func invalidPairingImportPreservesExistingValidFileIncludingLockdownOnly() throws {
        let fileManager = FileManager.default
        removeStoredPairingFile(fileManager: fileManager)

        let validURL = fileManager.temporaryDirectory
            .appendingPathComponent("valid-pairing-\(UUID().uuidString).plist")
        let invalidPropertyListURL = fileManager.temporaryDirectory
            .appendingPathComponent("invalid-pairing-\(UUID().uuidString).plist")
        let lockdownOnlyURL = fileManager.temporaryDirectory
            .appendingPathComponent("lockdown-only-pairing-\(UUID().uuidString).plist")
        let validData = try Self.validPairingData()
        try validData.write(to: validURL, options: .atomic)
        try Data("not a pairing file".utf8).write(
            to: invalidPropertyListURL,
            options: .atomic
        )
        try Self.lockdownOnlyPairingData().write(to: lockdownOnlyURL, options: .atomic)
        defer {
            try? fileManager.removeItem(at: validURL)
            try? fileManager.removeItem(at: invalidPropertyListURL)
            try? fileManager.removeItem(at: lockdownOnlyURL)
            removeStoredPairingFile(fileManager: fileManager)
        }

        try PairingFileStore.importFromPicker(validURL, fileManager: fileManager)

        #expect(throws: PairingFileError.invalidPropertyList) {
            try PairingFileStore.importFromPicker(
                invalidPropertyListURL,
                fileManager: fileManager
            )
        }
        #expect(throws: PairingFileError.missingRequiredFields([
            "public_key",
            "private_key",
            "identifier"
        ])) {
            try PairingFileStore.importFromPicker(lockdownOnlyURL, fileManager: fileManager)
        }
        let storedData = try Data(contentsOf: PairingFileStore.url)
        #expect(storedData == validData)
    }

    @Test func coordinateRoutePickerTypesExcludeEveryPairingType() {
        let pairingIdentifiers = Set(PairingFileStore.supportedContentTypes.map(\.identifier))
        let routeContentTypes = CoordinateImportParser.gpxContentTypes
        let routeIdentifiers = Set(routeContentTypes.map(\.identifier))
        let routeExtensions = filenameExtensions(for: routeContentTypes)

        #expect(pairingIdentifiers.isDisjoint(with: routeIdentifiers))
        #expect(routeExtensions.isDisjoint(with: Self.pairingExtensions))
        #expect(filenameExtensions(for: CoordinateImportParser.gpxContentTypes) == ["gpx"])
    }

    @Test func coordinateRouteParserRejectsPairingFileExtensions() throws {
        for fileExtension in Self.pairingExtensions {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try Data("25.0330, 121.5654".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(throws: CoordinateImportError.self) {
                try CoordinateImportParser.parse(url: url)
            }
        }
    }

    private static func validPairingData(
        includeLockdownFields: Bool = true,
        publicKeyLength: Int = 32,
        privateKeyLength: Int = 32,
        identifier: String = "impactor-device-id"
    ) throws -> Data {
        var propertyList: [String: Any] = [
            "public_key": Data(repeating: 1, count: publicKeyLength),
            "private_key": Data(repeating: 2, count: privateKeyLength),
            "identifier": identifier
        ]
        if includeLockdownFields {
            propertyList["HostID"] = "host-id"
            propertyList["SystemBUID"] = "system-buid"
            propertyList["DeviceCertificate"] = Data([1])
            propertyList["HostCertificate"] = Data([2])
            propertyList["HostPrivateKey"] = Data([3])
            propertyList["RootCertificate"] = Data([4])
            propertyList["RootPrivateKey"] = Data([5])
        }
        return try propertyListData(propertyList)
    }

    private static func lockdownOnlyPairingData() throws -> Data {
        try propertyListData([
            "HostID": "host-id",
            "SystemBUID": "system-buid",
            "DeviceCertificate": Data([1]),
            "HostCertificate": Data([2]),
            "HostPrivateKey": Data([3]),
            "RootCertificate": Data([4]),
            "RootPrivateKey": Data([5])
        ])
    }

    private static func propertyListData(_ propertyList: [String: Any]) throws -> Data {
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
    }

    private func removeStoredPairingFile(fileManager: FileManager) {
        try? fileManager.removeItem(at: PairingFileStore.url)
    }

}
