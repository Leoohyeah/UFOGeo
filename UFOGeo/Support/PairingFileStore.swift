import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let pairingFileDidChange = Notification.Name("com.ufogeo.pairing-file-did-change")
}

enum PairingFileError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidPropertyList
    case missingRequiredFields([String])
    case invalidField(String)
    case unsupportedFileExtension(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "配對文件過大，請重新匯出有效的配對文件。"
        case .invalidPropertyList:
            return "配對文件不是有效的 Property List。"
        case .missingRequiredFields(let fields):
            return "配對文件缺少必要欄位：\(fields.joined(separator: "、"))。"
        case .invalidField(let field):
            return "配對文件欄位 \(field) 的格式無效。"
        case .unsupportedFileExtension(let fileExtension):
            let suffix = fileExtension.isEmpty ? "（無副檔名）" : ".\(fileExtension)"
            return "不支援的配對文件副檔名：\(suffix)。請選擇 .plist、.mobiledevicepairing 或 .mobiledevicepair。"
        }
    }
}

enum PairingFileStore {
    private static let fileName = "rp_pairing_file.plist"
    private static let maximumFileSize = 10 * 1_024 * 1_024
    private static let requiredStringFields = ["HostID", "SystemBUID"]
    private static let requiredDataFields = [
        "DeviceCertificate",
        "HostCertificate",
        "HostPrivateKey",
        "RootCertificate",
        "RootPrivateKey"
    ]
    static let supportedContentTypes: [UTType] = [
        // Use extension-tagged dynamic types rather than a generic `.data`
        // or `.propertyList` type. UIDocumentPicker will then limit manual
        // selection to exactly these three filename extensions.
        UTType(filenameExtension: "plist")!,
        UTType(filenameExtension: "mobiledevicepairing")!,
        UTType(filenameExtension: "mobiledevicepair")!
    ]
    static let supportedFileExtensions: Set<String> = [
        "plist",
        "mobiledevicepairing",
        "mobiledevicepair"
    ]

    static var url: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    @discardableResult
    static func prepareURL(fileManager: FileManager = .default) -> URL {
        let destination = url
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        protectPairingDirectory(at: directoryURL, fileManager: fileManager)

        guard !fileManager.fileExists(atPath: destination.path) else {
            protectPairingFile(at: destination, fileManager: fileManager)
            return destination
        }

        return destination
    }

    private static func replace(with sourceURL: URL, fileManager: FileManager) throws {
        let destination = url
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        protectPairingDirectory(at: directoryURL, fileManager: fileManager)
        let data = try coordinatedData(from: sourceURL)
        try validate(data)

        guard sourceURL.standardizedFileURL != destination.standardizedFileURL else {
            protectPairingFile(at: destination, fileManager: fileManager)
            return
        }

        try data.write(to: destination, options: .atomic)
        protectPairingFile(at: destination, fileManager: fileManager)
        notifyPairingFileDidChange()
    }

    static func validate(_ data: Data) throws {
        guard data.count <= maximumFileSize else {
            throw PairingFileError.fileTooLarge
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw PairingFileError.invalidPropertyList
        }

        guard let dictionary = propertyList as? [String: Any] else {
            throw PairingFileError.invalidPropertyList
        }

        let missing = (requiredStringFields + requiredDataFields).filter {
            dictionary[$0] == nil
        }
        guard missing.isEmpty else {
            throw PairingFileError.missingRequiredFields(missing)
        }

        for field in requiredStringFields {
            guard let value = dictionary[field] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PairingFileError.invalidField(field)
            }
        }
        for field in requiredDataFields {
            guard let value = dictionary[field] as? Data, !value.isEmpty else {
                throw PairingFileError.invalidField(field)
            }
        }
    }

    static func importFromPicker(_ sourceURL: URL, fileManager: FileManager = .default) throws {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedFileExtensions.contains(fileExtension) else {
            throw PairingFileError.unsupportedFileExtension(sourceURL.pathExtension)
        }

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        try replace(with: sourceURL, fileManager: fileManager)
    }

    private static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    private static func coordinatedData(from sourceURL: URL) throws -> Data {
        var coordinatedData: Data?
        var readError: Error?
        var coordinationError: NSError?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                coordinatedData = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
            } catch {
                readError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let readError {
            throw readError
        }
        guard let coordinatedData else {
            throw CocoaError(.fileReadUnknown)
        }
        return coordinatedData
    }

    private static func protectPairingDirectory(at url: URL, fileManager: FileManager) {
        applySensitiveDataProtection(
            at: url,
            permissions: 0o700,
            fileManager: fileManager
        )
    }

    private static func protectPairingFile(at url: URL, fileManager: FileManager) {
        applySensitiveDataProtection(
            at: url,
            permissions: 0o600,
            fileManager: fileManager
        )
    }

    private static func applySensitiveDataProtection(
        at url: URL,
        permissions: Int,
        fileManager: FileManager
    ) {
        try? fileManager.setAttributes(
            [
                .posixPermissions: permissions,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: url.path
        )

        var protectedURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(resourceValues)
    }

    private static func notifyPairingFileDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pairingFileDidChange, object: nil)
        }
    }
}
