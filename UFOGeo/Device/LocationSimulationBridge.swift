import Foundation

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "com.UFOGeo.location-sim", qos: .userInitiated)

    static func preconditionIsolated() {
        dispatchPrecondition(condition: .onQueue(shared))
    }
}

/// A safe copy of an idevice FFI error made before the C error is freed.
struct RemotePairingFFIError: Error, Equatable, Identifiable, LocalizedError, Sendable {
    enum Operation: String, Equatable, Sendable {
        case pairingRead
        case tunnelHandshake
        case remoteServer
        case locationSimulation
        case locationSet
        case locationClear

        var title: String {
            switch self {
            case .pairingRead: return "讀取 pairing file"
            case .tunnelHandshake: return "Remote Pairing handshake"
            case .remoteServer: return "RSD 服務連線"
            case .locationSimulation: return "定位服務建立"
            case .locationSet: return "設定模擬位置"
            case .locationClear: return "清除模擬位置"
            }
        }
    }

    let id: String
    let operation: Operation
    let code: Int32
    let subCode: Int32
    let message: String

    init(operation: Operation, code: Int32, subCode: Int32, message: String) {
        self.operation = operation
        self.code = code
        self.subCode = subCode
        self.message = message
        self.id = operation.rawValue + "-" + String(code) + "-" + String(subCode)
    }

    var errorDescription: String? {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDetail = detail.isEmpty ? "FFI 未提供錯誤訊息。" : detail
        return operation.title
            + "失敗（FFI error code "
            + String(code)
            + ", sub_code "
            + String(subCode)
            + "）："
            + safeDetail
    }
}

struct LocationSimulationError: Error, Equatable, Identifiable, LocalizedError {
    let code: Int32
    let operation: String
    let ffiError: RemotePairingFFIError?

    init(
        code: Int32,
        operation: String,
        ffiError: RemotePairingFFIError? = nil
    ) {
        self.code = code
        self.operation = operation
        self.ffiError = ffiError
    }

    var id: String { "\(operation)-\(code)" }

    var errorDescription: String? {
        let baseMessage = LocationSimulationErrorCatalog.message(for: code, operation: operation)
        guard let ffiError else { return baseMessage }
        return "\(baseMessage)\n\(ffiError.localizedDescription)"
    }
}

extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

/// Guarantees that a device command completes at most once.  The FFI call
/// runs on the serialized command queue and cannot be force-cancelled safely,
/// so the timeout path must be able to release its caller independently.
private final class LocationSimulationCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private let completion: @MainActor (Result<Void, LocationSimulationError>) -> Void

    init(
        completion: @escaping @MainActor (Result<Void, LocationSimulationError>) -> Void
    ) {
        self.completion = completion
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didComplete
    }

    func finish(_ result: Result<Void, LocationSimulationError>) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        lock.unlock()

        Task { @MainActor in
            completion(result)
        }
    }
}

private protocol DeviceLocationTransport: AnyObject {
    var lastFFIError: RemotePairingFFIError? { get }

    func setLocation(
        deviceIP: String,
        latitude: Double,
        longitude: Double,
        pairingFile: String
    ) -> Int32
    func clearLocation() -> Int32
    func resetConnectionState()
}

private final class ClosureDeviceLocationTransport: DeviceLocationTransport {
    private let setOperation: (String, Double, Double, String) -> Int32
    private let clearOperation: () -> Int32
    private let resetOperation: () -> Void
    private let ffiErrorOperation: () -> RemotePairingFFIError?

    init(
        setOperation: @escaping (String, Double, Double, String) -> Int32,
        clearOperation: @escaping () -> Int32,
        resetOperation: @escaping () -> Void,
        ffiErrorOperation: @escaping () -> RemotePairingFFIError?
    ) {
        self.setOperation = setOperation
        self.clearOperation = clearOperation
        self.resetOperation = resetOperation
        self.ffiErrorOperation = ffiErrorOperation
    }

    var lastFFIError: RemotePairingFFIError? { ffiErrorOperation() }

    func setLocation(
        deviceIP: String,
        latitude: Double,
        longitude: Double,
        pairingFile: String
    ) -> Int32 {
        setOperation(deviceIP, latitude, longitude, pairingFile)
    }

    func clearLocation() -> Int32 {
        clearOperation()
    }

    func resetConnectionState() {
        resetOperation()
    }
}

/// Thread-safe because every transport access is serialized through `queue`.
final class LocationSimulationService: @unchecked Sendable {
    static let shared = LocationSimulationService()
    static let defaultCommandTimeout: TimeInterval = 15

    typealias Completion = @MainActor (Result<Void, LocationSimulationError>) -> Void

    private let queue: DispatchQueue
    private let transport: DeviceLocationTransport
    private let commandTimeout: TimeInterval

    init(
        queue: DispatchQueue = LocationSimulationCommandQueue.shared,
        setOperation: @escaping (String, Double, Double, String) -> Int32 = {
            ProductionDeviceLocationTransport.shared.setLocation(
                deviceIP: $0,
                latitude: $1,
                longitude: $2,
                pairingFile: $3
            )
        },
        clearOperation: @escaping () -> Int32 = {
            ProductionDeviceLocationTransport.shared.clearLocation()
        },
        resetOperation: @escaping () -> Void = {
            ProductionDeviceLocationTransport.shared.resetConnectionState()
        },
        ffiErrorOperation: @escaping () -> RemotePairingFFIError? = {
            ProductionDeviceLocationTransport.shared.lastFFIError
        },
        commandTimeout: TimeInterval = LocationSimulationService.defaultCommandTimeout
    ) {
        self.queue = queue
        self.transport = ClosureDeviceLocationTransport(
            setOperation: setOperation,
            clearOperation: clearOperation,
            resetOperation: resetOperation,
            ffiErrorOperation: ffiErrorOperation
        )
        self.commandTimeout = max(0.1, commandTimeout)
    }

    func setLocation(
        deviceIP: String,
        latitude: Double,
        longitude: Double,
        pairingFile: String,
        operation: String,
        completion: @escaping Completion
    ) {
        let gate = LocationSimulationCompletionGate(completion: completion)
        queue.async {
            guard !gate.isFinished else { return }
            let code = self.transport.setLocation(
                deviceIP: deviceIP,
                latitude: latitude,
                longitude: longitude,
                pairingFile: pairingFile
            )
            let result = Self.result(
                code: code,
                operation: operation,
                ffiError: self.transport.lastFFIError
            )
            gate.finish(result)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + commandTimeout
        ) {
            gate.finish(.failure(LocationSimulationError(
                code: 15,
                operation: operation
            )))
        }
    }

    func setLocation(
        deviceIP: String,
        latitude: Double,
        longitude: Double,
        pairingFile: String,
        operation: String
    ) async -> Result<Void, LocationSimulationError> {
        await withCheckedContinuation { continuation in
            setLocation(
                deviceIP: deviceIP,
                latitude: latitude,
                longitude: longitude,
                pairingFile: pairingFile,
                operation: operation
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    func clearLocation(
        operation: String,
        after delay: TimeInterval = 0,
        completion: @escaping Completion
    ) {
        let gate = LocationSimulationCompletionGate(completion: completion)
        queue.asyncAfter(deadline: .now() + delay) {
            guard !gate.isFinished else { return }
            let code = self.transport.clearLocation()
            let result = Self.result(
                code: code,
                operation: operation,
                ffiError: self.transport.lastFFIError
            )
            gate.finish(result)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + commandTimeout
        ) {
            gate.finish(.failure(LocationSimulationError(
                code: 15,
                operation: operation
            )))
        }
    }

    func clearLocation(
        operation: String,
        after delay: TimeInterval = 0
    ) async -> Result<Void, LocationSimulationError> {
        await withCheckedContinuation { continuation in
            clearLocation(operation: operation, after: delay) { result in
                continuation.resume(returning: result)
            }
        }
    }

    func resetConnectionState() {
        queue.async {
            self.transport.resetConnectionState()
        }
    }

    func resetConnectionState() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.transport.resetConnectionState()
                continuation.resume(returning: ())
            }
        }
    }

    static func result(
        code: Int32,
        operation: String,
        ffiError: RemotePairingFFIError? = nil
    ) -> Result<Void, LocationSimulationError> {
        code == 0
            ? .success(())
            : .failure(LocationSimulationError(
                code: code,
                operation: operation,
                ffiError: ffiError
            ))
    }

    /// App 即將終止時同步清除定位（best-effort，在 ~5 秒視窗內完成）。
    func clearLocationSync() {
        queue.sync {
            _ = self.transport.clearLocation()
        }
    }
}

struct LocationSimulationErrorDefinition: Identifiable {
    let code: Int32
    let title: String
    let recovery: String
    var id: Int32 { code }
}

enum LocationSimulationErrorCatalog {
    static let definitions: [LocationSimulationErrorDefinition] = [
        .init(code: 1, title: "目標位址無效", recovery: "請檢查 VPN 與目標 IP 設定。"),
        .init(code: 2, title: "配對文件無法讀取", recovery: "請重新導入此裝置的有效配對文件。"),
        .init(code: 3, title: "配對 Tunnel 建立失敗", recovery: "請確認 Wi-Fi 與 LocalDevVPN 已開啟。"),
        .init(code: 9, title: "RSD 連線失敗", recovery: "請重新連接 VPN 後再試一次。"),
        .init(code: 10, title: "定位服務建立失敗", recovery: "請確認目前 iOS 版本相容並重新連線。"),
        .init(code: 11, title: "座標設定失敗", recovery: "請停止模擬、重新連線後再試一次。"),
        .init(code: 12, title: "清除模擬位置失敗", recovery: "目前可能沒有有效連線，請重新連線後再停止。"),
        .init(code: 13, title: "另一種模擬正在執行", recovery: "請先停止目前的定位模擬。"),
        .init(code: 14, title: "尚未啟動模擬", recovery: "請先啟動定位後再更新座標。"),
        .init(code: 15, title: "裝置指令逾時", recovery: "裝置沒有在期限內回應，請確認連線後再試一次。"),
        .init(code: 17, title: "搖桿需要 Pro", recovery: "Free 可使用單點定位；升級 Pro 後即可使用搖桿連續移動。")
    ]

    static func definition(for code: Int32) -> LocationSimulationErrorDefinition {
        definitions.first(where: { $0.code == code })
            ?? .init(code: code, title: "未知錯誤", recovery: "請重新連線；若持續發生，請將錯誤碼寄至 leoohyeah.app@gmail.com。")
    }

    static func message(for code: Int32, operation: String) -> String {
        let error = definition(for: code)
        return "\(operation)失敗（錯誤碼 \(code)：\(error.title)）。\(error.recovery)"
    }
}

#if targetEnvironment(simulator)

private final class ProductionDeviceLocationTransport: DeviceLocationTransport {
    static let shared = ProductionDeviceLocationTransport()

    var lastFFIError: RemotePairingFFIError? { nil }

    func setLocation(
        deviceIP: String,
        latitude: Double,
        longitude: Double,
        pairingFile: String
    ) -> Int32 {
        LocationSimulationCommandQueue.preconditionIsolated()
        return 0
    }

    func clearLocation() -> Int32 {
        LocationSimulationCommandQueue.preconditionIsolated()
        return 0
    }

    func resetConnectionState() {
        LocationSimulationCommandQueue.preconditionIsolated()
    }
}

#else

import idevice

private func consumeRemotePairingFFIError(
    _ error: UnsafeMutablePointer<idevice.IdeviceFfiError>,
    operation: RemotePairingFFIError.Operation
) -> RemotePairingFFIError {
    let code = error.pointee.code
    let subCode = error.pointee.sub_code
    let message = error.pointee.message.map(String.init(cString:)) ?? "FFI 未提供錯誤訊息。"
    idevice_error_free(error)
    return RemotePairingFFIError(
        operation: operation,
        code: code,
        subCode: subCode,
        message: message
    )
}

private enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12
}

private final class ProductionDeviceLocationTransport: DeviceLocationTransport {
    static let shared = ProductionDeviceLocationTransport()

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationSimulation: OpaquePointer?
    private(set) var lastFFIError: RemotePairingFFIError?

    private func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    func setLocation(
        deviceIP: String,
        latitude: Double,
        longitude: Double,
        pairingFile: String
    ) -> Int32 {
        LocationSimulationCommandQueue.preconditionIsolated()
        lastFFIError = nil

    if let locationSimulation {
        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            lastFFIError = consumeRemotePairingFFIError(
                ffiError,
                operation: .locationSet
            )
            cleanup()
        } else {
            return LocationSimulationStatus.ok
        }
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(49152).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        return LocationSimulationStatus.invalidIP
    }

    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { path in
        rp_pairing_file_read(path, &pairingHandle)
    }
    if let pairingError {
        lastFFIError = consumeRemotePairingFFIError(
            pairingError,
            operation: .pairingRead
        )
        return LocationSimulationStatus.pairingRead
    }
    guard let pairingHandle else {
        return LocationSimulationStatus.pairingRead
    }
    defer { rp_pairing_file_free(pairingHandle) }

    let providerError = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing(
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.stride),
                "UFOGeoLocation",
                pairingHandle,
                nil,
                nil,
                &adapter,
                &handshake
            )
        }
    }

    if let providerError {
        lastFFIError = consumeRemotePairingFFIError(
            providerError,
            operation: .tunnelHandshake
        )
        cleanup()
        return LocationSimulationStatus.providerCreate
    }

    let remoteServerError = remote_server_connect_rsd(
        adapter,
        handshake,
        &remoteServer
    )
    if let remoteServerError {
        lastFFIError = consumeRemotePairingFFIError(
            remoteServerError,
            operation: .remoteServer
        )
        cleanup()
        return LocationSimulationStatus.remoteServer
    }

    let locationSimulationError = location_simulation_new(
        remoteServer,
        &locationSimulation
    )
    if let locationSimulationError {
        lastFFIError = consumeRemotePairingFFIError(
            locationSimulationError,
            operation: .locationSimulation
        )
        cleanup()
        return LocationSimulationStatus.locationSimulation
    }
    // location_simulation_new borrows the server pointer. The caller continues
    // to own it and releases it after the location handle during cleanup.

    let locationSetError = location_simulation_set(
        locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        lastFFIError = consumeRemotePairingFFIError(
            locationSetError,
            operation: .locationSet
        )
        cleanup()
        return LocationSimulationStatus.locationSet
    }

    return LocationSimulationStatus.ok
    }

    func clearLocation() -> Int32 {
        LocationSimulationCommandQueue.preconditionIsolated()
        lastFFIError = nil

    guard let locationSimulation else {
        // Stopping an already-stopped simulation is a successful no-op.
        return LocationSimulationStatus.ok
    }

    let ffiError = location_simulation_clear(locationSimulation)
    cleanup()

    if let ffiError {
        lastFFIError = consumeRemotePairingFFIError(
            ffiError,
            operation: .locationClear
        )
        return LocationSimulationStatus.locationClear
    }

    return LocationSimulationStatus.ok
    }

    func resetConnectionState() {
        LocationSimulationCommandQueue.preconditionIsolated()
        lastFFIError = nil
        cleanup()
    }
}

#endif
