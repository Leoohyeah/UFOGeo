import Foundation
import HealthKit
import UIKit
import os
import UserNotifications

enum HealthStepWriteError: LocalizedError {
    case unavailable
    case unauthorized
    case invalidStepCount

    var errorDescription: String? {
        switch self {
        case .unavailable: return "此裝置無法使用 Apple 健康步數功能。"
        case .unauthorized: return "UFOGeo 沒有寫入 Apple 健康步數的權限。"
        case .invalidStepCount: return "請輸入大於 0 的有效步數。"
        }
    }
}

@MainActor
final class HealthStepSyncManager {
    static let shared = HealthStepSyncManager()

    private let logger = Logger(subsystem: "com.ufogeo.app", category: "HealthKit")
    private let healthStore = HKHealthStore()
    private let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)

    private var hasRequestedAuthorization = false
    private var isAuthorized = false

    private init() {}

    private func postBackgroundNotificationIfNeeded(steps: Int, remainingSteps: Int?) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        if let remainingSteps {
            content.body = "已成功寫入 \(steps) 步到健康，剩餘 \(max(remainingSteps, 0)) 步"
        } else {
            content.body = "已成功寫入 \(steps) 步到健康"
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "com.ufogeo.health-step-written-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable() && stepType != nil
    }

    func requestAuthorizationIfNeeded(completion: @escaping @MainActor (Bool) -> Void) {
        guard isAvailable, let stepType else {
            completion(false)
            return
        }

        // HealthKit permissions can be changed outside the app. Always read
        // the current status so a previous denial does not become permanent.
        let currentStatus = healthStore.authorizationStatus(for: stepType)
        if currentStatus == .sharingAuthorized {
            isAuthorized = true
            completion(true)
            return
        }

        if hasRequestedAuthorization {
            isAuthorized = false
            completion(false)
            return
        }

        hasRequestedAuthorization = true
        healthStore.requestAuthorization(toShare: [stepType], read: [stepType]) { [weak self] success, error in
            Task { @MainActor in
                guard let self else {
                    completion(false)
                    return
                }
                let authorized = success
                    && self.healthStore.authorizationStatus(for: stepType) == .sharingAuthorized
                self.isAuthorized = authorized
                if let error {
                    self.logger.error("Health authorization failed: \(error.localizedDescription, privacy: .public)")
                }
                completion(authorized)
            }
        }
    }

    func writeSteps(
        _ steps: Int,
        remainingSteps: Int? = nil,
        at date: Date = Date(),
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard isAvailable, let stepType else {
            completion(.failure(HealthStepWriteError.unavailable))
            return
        }
        guard steps > 0 else {
            completion(.failure(HealthStepWriteError.invalidStepCount))
            return
        }
        guard isAuthorized, healthStore.authorizationStatus(for: stepType) == .sharingAuthorized else {
            completion(.failure(HealthStepWriteError.unauthorized))
            return
        }

        let quantity = HKQuantity(unit: .count(), doubleValue: Double(steps))
        let sample = HKQuantitySample(
            type: stepType,
            quantity: quantity,
            start: date.addingTimeInterval(-1),
            end: date
        )
        healthStore.save(sample) { success, error in
            Task { @MainActor in
                if success {
                    self.postBackgroundNotificationIfNeeded(
                        steps: steps,
                        remainingSteps: remainingSteps
                    )
                    completion(.success(()))
                } else {
                    if let error {
                        self.logger.error("Health step write failed: \(error.localizedDescription, privacy: .public)")
                    }
                    completion(.failure(error ?? HealthStepWriteError.unauthorized))
                }
            }
        }
    }
}
