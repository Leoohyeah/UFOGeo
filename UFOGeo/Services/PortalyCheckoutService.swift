import Combine
import Foundation

enum MembershipFeaturePolicy {
    static func canRunRoute(inBackground: Bool, proActive: Bool) -> Bool {
        !inBackground || proActive
    }

    static func canUseJoystick(proActive: Bool) -> Bool {
        proActive
    }
}

@MainActor
final class PortalyCheckoutService: ObservableObject {
    static let shared = PortalyCheckoutService()
    static let proFeatureAlertTitle = "Pro 功能"
    static let proFeatureAlertMessage = "此功能僅供 Pro 會員使用。若你剛完成付款，請回到「帳號與訂閱」頁刷新一次，等狀態同步後再試。"
    nonisolated static let expectedPlanID = "JO5cmDQdqTtb6AkkcnNW"

    struct MembershipProjection: Equatable {
        enum Entitlement: Equatable {
            case checking
            case verifiedPro
            case verifiedFree
            case unavailable
        }

        enum Payment: Equatable {
            case none
            case checkoutReady
            case checkoutFailed
            case active
            case pastDue
            case canceling
            case canceled
            case unavailable
        }

        enum Tone: Equatable {
            case neutral
            case positive
            case attention
            case progress
        }

        enum Action: Equatable {
            case none
            case refresh
            case startCheckout
            case continueCheckout
            case retryCheckout
            case restartCheckout
            case manageSubscription
            case resolvePayment
            case resumeSubscription

            var title: String? {
                switch self {
                case .none: nil
                case .refresh: "重新同步訂閱狀態"
                case .startCheckout: "訂閱 UFOGeo Pro"
                case .continueCheckout: "繼續付款"
                case .retryCheckout: "重新嘗試付款"
                case .restartCheckout: "重新訂閱 UFOGeo Pro"
                case .manageSubscription: "管理訂閱與付款紀錄"
                case .resolvePayment: "前往 Portaly 處理付款"
                case .resumeSubscription: "前往 Portaly 恢復訂閱"
                }
            }

            var opensCheckout: Bool {
                switch self {
                case .startCheckout, .continueCheckout, .retryCheckout, .restartCheckout:
                    true
                default:
                    false
                }
            }

            var opensPortal: Bool {
                switch self {
                case .manageSubscription, .resolvePayment, .resumeSubscription:
                    true
                default:
                    false
                }
            }
        }

        struct Notice: Equatable {
            enum Kind: Equatable {
                case grant
                case cancellation
            }

            let kind: Kind
            let text: String
        }

        let entitlement: Entitlement
        let payment: Payment
        let label: String
        let detail: String
        let guidance: String
        let tone: Tone
        let action: Action
        let notices: [Notice]
        let isTestMode: Bool

        var isPro: Bool { entitlement == .verifiedPro }

        static let checking = MembershipProjection(
            entitlement: .checking,
            payment: .unavailable,
            label: "同步中",
            detail: "正在向伺服器確認。",
            guidance: "同步完成前不會開放付款或訂閱管理。",
            tone: .neutral,
            action: .none,
            notices: [],
            isTestMode: false
        )

        static func unavailable(syncFailed: Bool = false) -> MembershipProjection {
            MembershipProjection(
                entitlement: .unavailable,
                payment: .unavailable,
                label: syncFailed ? "同步失敗" : "需重新同步",
                detail: "目前無法確認最新會員狀態。",
                guidance: "請稍後重新同步；不需要重新付款。",
                tone: .attention,
                action: .refresh,
                notices: [],
                isTestMode: false
            )
        }
    }

    struct SubscriptionState: Codable, Equatable {
        struct GrantMetadata: Codable, Equatable {
            let kind: String
            let expiresAt: String?
            let grantedAt: String
        }

        let uid: String
        let email: String
        let emailVerified: Bool
        let proActive: Bool
        let subscriptionStatus: String
        let subscriptionId: String?
        let planId: String
        let mode: String?
        let nextBillingAt: String?
        let nextBillingAtMs: TimeInterval?
        let daysUntilRenewal: Double?
        let expiringStage: String?
        let cancelAtPeriodEnd: Bool
        let cancelEffectiveAt: String?
        let lastVerifiedAt: String?
        let entitlementSource: String
        let grant: GrantMetadata?

        init(
            uid: String,
            email: String,
            emailVerified: Bool,
            proActive: Bool,
            subscriptionStatus: String,
            subscriptionId: String?,
            planId: String,
            mode: String?,
            nextBillingAt: String?,
            nextBillingAtMs: TimeInterval? = nil,
            daysUntilRenewal: Double? = nil,
            expiringStage: String? = nil,
            cancelAtPeriodEnd: Bool,
            cancelEffectiveAt: String?,
            lastVerifiedAt: String?,
            entitlementSource: String = "none",
            grant: GrantMetadata? = nil
        ) {
            self.uid = uid
            self.email = email
            self.emailVerified = emailVerified
            self.proActive = proActive
            self.subscriptionStatus = subscriptionStatus
            self.subscriptionId = subscriptionId
            self.planId = planId
            self.mode = mode
            self.nextBillingAt = nextBillingAt
            self.nextBillingAtMs = nextBillingAtMs
            self.daysUntilRenewal = daysUntilRenewal
            self.expiringStage = expiringStage
            self.cancelAtPeriodEnd = cancelAtPeriodEnd
            self.cancelEffectiveAt = cancelEffectiveAt
            self.lastVerifiedAt = lastVerifiedAt
            self.entitlementSource = entitlementSource
            self.grant = grant
        }

        private enum CodingKeys: String, CodingKey {
            case uid
            case email
            case emailVerified
            case proActive
            case subscriptionStatus
            case subscriptionId
            case planId
            case mode
            case nextBillingAt
            case nextBillingAtMs
            case daysUntilRenewal
            case expiringStage
            case cancelAtPeriodEnd
            case cancelEffectiveAt
            case lastVerifiedAt
            case entitlementSource
            case grant
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uid = try container.decode(String.self, forKey: .uid)
            email = try container.decode(String.self, forKey: .email)
            emailVerified = try container.decode(Bool.self, forKey: .emailVerified)
            proActive = try container.decode(Bool.self, forKey: .proActive)
            subscriptionStatus = try container.decode(String.self, forKey: .subscriptionStatus)
            subscriptionId = try container.decodeIfPresent(String.self, forKey: .subscriptionId)
            planId = try container.decode(String.self, forKey: .planId)
            mode = try container.decodeIfPresent(String.self, forKey: .mode)
            nextBillingAt = try container.decodeIfPresent(String.self, forKey: .nextBillingAt)
            nextBillingAtMs = try container.decodeIfPresent(TimeInterval.self, forKey: .nextBillingAtMs)
            daysUntilRenewal = try container.decodeIfPresent(Double.self, forKey: .daysUntilRenewal)
            expiringStage = try container.decodeIfPresent(String.self, forKey: .expiringStage)
            cancelAtPeriodEnd = try container.decode(Bool.self, forKey: .cancelAtPeriodEnd)
            cancelEffectiveAt = try container.decodeIfPresent(String.self, forKey: .cancelEffectiveAt)
            lastVerifiedAt = try container.decodeIfPresent(String.self, forKey: .lastVerifiedAt)
            if let source = try container.decodeIfPresent(String.self, forKey: .entitlementSource) {
                entitlementSource = source
            } else if proActive,
                      subscriptionId != nil,
                      ["active", "past_due", "cancel_requested"].contains(subscriptionStatus) {
                entitlementSource = "portaly"
            } else {
                entitlementSource = "none"
            }
            grant = try container.decodeIfPresent(GrantMetadata.self, forKey: .grant)
        }

        private var normalizedPayment: MembershipProjection.Payment {
            guard let mode,
                  ["live", "test"].contains(mode),
                                    planId == PortalyCheckoutService.expectedPlanID,
                                    Self.isValidOptionalDocumentIdentifier(subscriptionId),
                  Self.isValidOptionalDate(nextBillingAt),
                  Self.isValidOptionalDate(cancelEffectiveAt) else {
                return .unavailable
            }
            switch subscriptionStatus {
            case "none":
                return subscriptionId == nil && !cancelAtPeriodEnd ? .none : .unavailable
            case "pending", "created", "checkout_ready":
                return subscriptionId != nil && !cancelAtPeriodEnd ? .checkoutReady : .unavailable
            case "checkout_failed":
                return subscriptionId == nil && !cancelAtPeriodEnd ? .checkoutFailed : .unavailable
            case "active":
                return subscriptionId != nil && !cancelAtPeriodEnd ? .active : .unavailable
            case "past_due":
                return subscriptionId != nil && !cancelAtPeriodEnd ? .pastDue : .unavailable
            case "cancel_requested":
                return subscriptionId != nil && cancelAtPeriodEnd ? .canceling : .unavailable
            case "canceled":
                return subscriptionId != nil && !cancelAtPeriodEnd ? .canceled : .unavailable
            default:
                return .unavailable
            }
        }

        func canonicalProjection(
            emailVerified: Bool,
            now: Date = Date()
        ) -> MembershipProjection {
            var payment = normalizedPayment
            let validGrant = validatedGrant(now: now)
            let entitlement: MembershipProjection.Entitlement
            let hasServerGrant: Bool

            switch entitlementSource {
            case "server_grant":
                guard proActive, validGrant != nil else {
                    return .unavailable()
                }
                hasServerGrant = true
                entitlement = .verifiedPro
                if [.active, .pastDue, .canceling].contains(payment) {
                    payment = .unavailable
                }
            case "portaly_and_server_grant":
                guard proActive else {
                    return .unavailable()
                }
                if validGrant == nil {
                    guard grantHasExpired(now: now),
                          [.active, .pastDue, .canceling].contains(payment) else {
                        return .unavailable()
                    }
                }
                hasServerGrant = validGrant != nil
                entitlement = .verifiedPro
                if hasServerGrant,
                   ![.active, .pastDue, .canceling].contains(payment) {
                    payment = .unavailable
                }
            case "portaly":
                guard proActive,
                      grant == nil,
                      [.active, .pastDue, .canceling].contains(payment) else {
                    return .unavailable()
                }
                hasServerGrant = false
                entitlement = .verifiedPro
            case "none":
                guard !proActive,
                      grant == nil,
                      [.none, .checkoutReady, .checkoutFailed, .canceled].contains(payment) else {
                    return .unavailable()
                }
                hasServerGrant = false
                entitlement = .verifiedFree
            default:
                return .unavailable()
            }

            return makeProjection(
                entitlement: entitlement,
                payment: payment,
                hasServerGrant: hasServerGrant,
                grant: validGrant,
                emailVerified: emailVerified,
                isTestMode: mode == "test"
            )
        }

        private func validatedGrant(now: Date) -> GrantMetadata? {
            guard ["server_grant", "portaly_and_server_grant"].contains(entitlementSource),
                  let grant,
                  ["lifetime_pro", "owner_pro", "temporary_pro", "promotional_pro"]
                    .contains(grant.kind),
                  let grantedAt = Self.parseDate(grant.grantedAt),
                  grantedAt <= now else { return nil }
            if let expiresAt = grant.expiresAt {
                guard let expiration = Self.parseDate(expiresAt), expiration > now else {
                    return nil
                }
            }
            return grant
        }

        private func grantHasExpired(now: Date) -> Bool {
            guard entitlementSource == "portaly_and_server_grant",
                  let grant,
                                    ["lifetime_pro", "owner_pro", "temporary_pro", "promotional_pro"]
                                        .contains(grant.kind),
                  let grantedAt = Self.parseDate(grant.grantedAt),
                  grantedAt <= now,
                                    let expiresAt = grant.expiresAt.flatMap(Self.parseDate),
                                    expiresAt > grantedAt else {
                return false
            }
            return expiresAt <= now
        }

        private func makeProjection(
            entitlement: MembershipProjection.Entitlement,
            payment: MembershipProjection.Payment,
            hasServerGrant: Bool,
            grant: GrantMetadata?,
            emailVerified: Bool,
            isTestMode: Bool
        ) -> MembershipProjection {
            let label: String
            let detail: String
            let guidance: String
            let tone: MembershipProjection.Tone
            var action: MembershipProjection.Action = .none

            if entitlement == .verifiedPro, hasServerGrant {
                switch payment {
                case .none:
                    label = "免費 Pro 授權"
                    detail = "此授權不需付款；若有期限，將顯示於下方。"
                    guidance = "免費 Pro 授權已啟用，不會自動建立訂單或產生扣款。"
                    tone = .positive
                case .checkoutReady:
                    label = "免費 Pro 授權"
                    detail = "另有一筆付款流程等待確認。"
                    guidance = "免費 Pro 已啟用；不需要繼續這筆付款。"
                    tone = .positive
                case .checkoutFailed:
                    label = "免費 Pro 授權"
                    detail = "另有一筆付款未完成。"
                    guidance = "免費 Pro 仍可使用；不需要重新付款。"
                    tone = .positive
                case .canceled:
                    label = "免費 Pro 授權"
                    detail = "付費訂閱已結束；免費授權仍有效。"
                    guidance = "免費 Pro 仍可使用，不需要重新訂閱。"
                    tone = .positive
                case .active:
                    label = "Pro 使用中"
                    detail = "免費授權與現有付費訂閱並存。"
                    guidance = "免費 Pro 授權已啟用；現有付費訂閱仍可管理，系統不會自動取消。"
                    tone = .positive
                    action = emailVerified ? .manageSubscription : .none
                case .pastDue:
                    label = "付款待處理"
                    detail = "免費 Pro 仍可使用。"
                    guidance = "付款待處理；免費 Pro 授權仍啟用，現有付費訂閱不會被系統自動取消。"
                    tone = .attention
                    action = emailVerified ? .resolvePayment : .none
                case .canceling:
                    label = "已取消續訂"
                    detail = "免費 Pro 授權仍有效。"
                    guidance = "已取消續訂；免費 Pro 授權仍依其授權期限有效。"
                    tone = .positive
                    action = emailVerified ? .resumeSubscription : .none
                case .unavailable:
                    label = "免費 Pro 授權"
                    detail = "免費 Pro 仍可使用；付款狀態目前無法確認。"
                    guidance = "請稍後重新同步付款狀態；不需要重新付款。"
                    tone = .positive
                    action = .refresh
                }
            } else if entitlement == .verifiedPro {
                switch payment {
                case .active:
                    label = "Pro 使用中"
                    detail = "Pro 已啟用。"
                    guidance = "可到管理頁查看付款紀錄、修改付款方式或取消續訂。"
                    tone = .positive
                    action = emailVerified ? .manageSubscription : .none
                case .pastDue:
                    label = "付款待處理"
                    detail = "Pro 目前仍可使用。"
                    guidance = "請前往訂閱管理確認待處理的付款。"
                    tone = .attention
                    action = emailVerified ? .resolvePayment : .none
                case .canceling:
                    label = "已取消續訂"
                    detail = "Pro 會持續到本期結束，期間內仍可正常使用。"
                    guidance = "已取消續訂；Pro 可使用至目前付費期間結束。"
                    tone = .positive
                    action = emailVerified ? .resumeSubscription : .none
                default:
                    return .unavailable()
                }
            } else {
                switch payment {
                case .none:
                    label = "Free 使用中"
                    detail = "尚未開始訂閱。"
                    guidance = "登入並驗證信箱後即可訂閱 UFOGeo Pro。"
                    tone = .neutral
                    action = emailVerified ? .startCheckout : .none
                case .checkoutReady:
                    label = "等待付款"
                    detail = "付款流程已建立，目前尚未啟用 Pro。"
                    guidance = "完成付款後請回到 App 等待同步；請勿立即建立第二筆付款。"
                    tone = .progress
                    action = emailVerified ? .continueCheckout : .none
                case .checkoutFailed:
                    label = "付款未完成"
                    detail = "未啟用 Pro。"
                    guidance = "請先重新同步確認付款結果；確認前請勿重複付款。"
                    tone = .attention
                    action = emailVerified ? .retryCheckout : .none
                case .canceled:
                    label = "已取消訂閱"
                    detail = "訂閱已結束，Pro 已停用。"
                    guidance = "狀態確認後可重新訂閱。"
                    tone = .neutral
                    action = emailVerified ? .restartCheckout : .none
                default:
                    return .unavailable()
                }
            }

            var notices: [MembershipProjection.Notice] = []
            if let grant {
                notices.append(.init(kind: .grant, text: Self.grantDescription(grant)))
            }
            if payment == .canceling {
                notices.append(.init(
                    kind: .cancellation,
                    text: cancellationDescription(hasServerGrant: hasServerGrant)
                ))
            }

            return MembershipProjection(
                entitlement: entitlement,
                payment: payment,
                label: label,
                detail: detail,
                guidance: guidance,
                tone: tone,
                action: action,
                notices: notices,
                isTestMode: isTestMode
            )
        }

        private static func grantDescription(_ grant: GrantMetadata) -> String {
            guard let expiresAt = grant.expiresAt,
                  let date = parseDate(expiresAt) else {
                return "免費 Pro 授權（永久）"
            }
            return "免費 Pro 授權有效至 \(formattedDate(date))"
        }

        private func cancellationDescription(hasServerGrant: Bool) -> String {
            let endDate = (cancelEffectiveAt ?? nextBillingAt).flatMap(Self.parseDate)
            if hasServerGrant {
                guard let endDate else {
                    return "已取消付費訂閱。付費訂閱將於本期結束；免費（含永久）Pro 授權仍依其授權期限有效，不會因付費訂閱取消而失效。"
                }
                return "已取消付費訂閱。付費訂閱將於 \(Self.formattedDate(endDate)) 結束；免費（含永久）Pro 授權仍依其授權期限有效，不會因付費訂閱取消而失效。"
            }
            guard let endDate else {
                return "已取消續訂。Pro 可使用到本期結束；到期後搖桿會停用，路線改為 Free 前景規則，單點定位仍保留。"
            }
            return "已取消續訂。Pro 可使用到 \(Self.formattedDate(endDate))；到期後搖桿會停用，路線改為 Free 前景規則，單點定位仍保留。"
        }

        private static func formattedDate(_ date: Date) -> String {
            date.formatted(
                .dateTime
                    .year()
                    .month(.wide)
                    .day()
                    .locale(Locale(identifier: "zh_Hant_TW"))
            )
        }

        private static func isValidOptionalDate(_ value: String?) -> Bool {
            guard let value else { return true }
            return parseDate(value) != nil
        }

        private static func isValidOptionalDocumentIdentifier(_ value: String?) -> Bool {
            guard let value else { return true }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value == trimmed
                && !trimmed.isEmpty
                && trimmed != "."
                && trimmed != ".."
                && !trimmed.contains("/")
                && trimmed.utf8.count <= 1_500
        }

        fileprivate static func parseDate(_ value: String) -> Date? {
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            let standard = Date.ISO8601FormatStyle()
            return (try? fractional.parse(value)) ?? (try? standard.parse(value))
        }
    }

    enum CheckoutError: LocalizedError {
        case backendNotConfigured
        case invalidBackendURL
        case invalidResponse
        case checkoutRequestInFlight
        case portalRequestInFlight
        case recoveryRequestInFlight
        case server(String)
        case serverResponse(code: String?, message: String)

        var errorDescription: String? {
            switch self {
            case .backendNotConfigured, .invalidBackendURL:
                return "付款功能目前無法使用，請稍後再試。"
            case .invalidResponse:
                return "暫時無法取得會員資料，請稍後再試。"
            case .checkoutRequestInFlight:
                return "付款頁面正在建立中，請稍候，不要重複點擊。"
            case .portalRequestInFlight:
                return "訂閱管理頁面正在開啟，請稍候，不要重複點擊。"
            case .recoveryRequestInFlight:
                return "正在從 Portaly 恢復既有訂閱，請稍候。"
            case let .server(message):
                return message
            case let .serverResponse(_, message):
                return message
            }
        }

        var backendCode: String? {
            guard case let .serverResponse(code, _) = self else { return nil }
            return code
        }
    }

    enum SubscriptionRecoveryOutcome: Equatable {
        case recovered
        case alreadyBound
        case notFound
    }

    enum MembershipSyncOutcome: Equatable {
        case idle
        case inFlight(uid: String)
        case succeeded(uid: String)
        case failed(uid: String)
        case cancelled(uid: String)
    }

    enum SubscriptionRecoveryState: Equatable {
        case idle
        case inFlight
        case recovered
        case alreadyBound
        case notFound
        case ambiguous
        case unavailable
        case conflict
        case safetyHold

        var blocksCheckout: Bool {
            switch self {
            case .inFlight, .ambiguous, .unavailable, .conflict, .safetyHold:
                return true
            case .idle, .recovered, .alreadyBound, .notFound:
                return false
            }
        }
    }

    /// Shared membership operations may outlive the auth session that
    /// started them.  A result can only be reused by the same Firebase UID;
    /// a missing UID is never a valid owner.
    nonisolated static func requestTaskBelongsToCurrentUID(
        ownerUID: String?,
        currentUID: String?
    ) -> Bool {
        guard let ownerUID, let currentUID else { return false }
        return ownerUID == currentUID
    }

    nonisolated static func initialSyncFlags(
        outcome: MembershipSyncOutcome,
        currentUID: String?
    ) -> (completed: Bool, failed: Bool) {
        guard let currentUID else { return (false, false) }
        switch outcome {
        case .succeeded(let uid) where uid == currentUID:
            return (true, false)
        case .failed(let uid) where uid == currentUID:
            return (false, true)
        case .cancelled(let uid) where uid == currentUID:
            return (false, true)
        case .idle, .inFlight, .succeeded, .failed, .cancelled:
            return (false, false)
        }
    }

    nonisolated static func serverErrorMessage(code: String?, serverMessage: String?) -> String {
        switch code {
        case "EMAIL_SUBSCRIPTION_EXISTS":
            return "此 Email 已有有效訂閱，請前往 Portaly 管理現有訂閱。"
        case "ACTIVE_SUBSCRIPTION_EXISTS":
            return "此帳號已有有效訂閱，請前往 Portaly 管理現有訂閱。"
        case "SERVER_GRANT_ACTIVE":
            return "此帳號已有免費 Pro 授權，無需訂閱或付款。"
        case "SERVER_GRANT_PORTAL_UNAVAILABLE":
            return "此帳號使用免費 Pro 授權，沒有需要管理的 Portaly 訂閱。"
        case "PORTALY_RECOVERY_AMBIGUOUS", "SUBSCRIPTION_RECOVERY_AMBIGUOUS",
             "RECOVERY_SUBSCRIPTION_AMBIGUOUS":
            return "找到多筆可用的 Portaly 訂閱，為避免綁定錯誤，尚未變更帳號。請聯絡支援。"
        case "PORTALY_REQUEST_UNCERTAIN", "PORTALY_RESPONSE_INCOMPLETE",
             "PORTALY_CHECKOUT_RECONCILE_FAILED", "PORTALY_CHECKOUT_RECONCILE_UNCERTAIN":
            if let serverMessage,
               !serverMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return serverMessage
            }
            return "付款建立結果尚未確認，\(Self.checkoutSyncFirstGuidance)"
        case "PORTALY_RECONCILE_REQUEST_UNCERTAIN", "PORTALY_RECONCILE_FAILED",
             "PORTALY_RECONCILE_RESPONSE_INVALID":
            if let serverMessage,
               !serverMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return serverMessage
            }
            return "付款狀態尚未確認，\(Self.checkoutSyncFirstGuidance)"
        case "CHECKOUT_SAFETY_HOLD":
            if let serverMessage,
               !serverMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return serverMessage
            }
            return "付款或帳號狀態尚未確認，\(Self.accountSyncFirstGuidance)"
        case "ACCOUNT_DELETION_SAFETY_HOLD", "SUBSCRIPTION_RECOVERY_SAFETY_HOLD":
            return "刪帳安全確認尚未完成，請稍後再試。"
        case "PENDING_CHECKOUT_EXISTS", "RECOVERY_PENDING_CHECKOUT":
            if let serverMessage,
               !serverMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return serverMessage
            }
            return "目前仍有尚未完成的付款流程，付款結果尚未確認，\(Self.checkoutSyncFirstGuidance)"
        case "PORTALY_RECOVERY_CONFLICT", "SUBSCRIPTION_RECOVERY_CONFLICT",
             "RECOVERY_LOCAL_STATE_CONFLICT", "RECOVERY_EXISTING_BINDING_CONFLICT":
            return "目前帳號已有不同的訂閱狀態，為避免覆寫資料，請重新同步或聯絡支援。"
        case "PORTALY_RECOVERY_UNAVAILABLE", "SUBSCRIPTION_RECOVERY_UNAVAILABLE",
             "PORTALY_RECOVERY_LIST_FAILED", "PORTALY_RECOVERY_PROVIDER_FAILED",
             "PORTALY_RECOVERY_RESPONSE_INVALID", "PORTALY_RECOVERY_STATE_CHANGED":
            return "目前無法確認 Portaly 訂閱，付款狀態尚未確認。\(Self.checkoutSyncFirstGuidance)"
        case "PORTALY_RECOVERY_NOT_FOUND", "SUBSCRIPTION_RECOVERY_NOT_FOUND":
            return "目前沒有找到可恢復的 Portaly Pro 訂閱；若要使用 Pro，可以開始新的訂閱。"
        case "EMAIL_NOT_VERIFIED":
            return "請先完成 Email 驗證，再恢復既有訂閱。"
        default:
            if let serverMessage,
               !serverMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return serverMessage
            }
            return "訂閱功能暫時無法使用，請稍後再試。"
        }
    }

    @Published private(set) var isLoading = false
    @Published private(set) var isCheckoutRequestInFlight = false
    @Published private(set) var isPortalRequestInFlight = false
    @Published private(set) var subscription: SubscriptionState?
    @Published private(set) var isEntitlementCacheExpired = true
    @Published private(set) var recoveryState: SubscriptionRecoveryState = .idle
    @Published private(set) var membershipSyncOutcome: MembershipSyncOutcome = .idle

    private static let checkoutCooldownSeconds: TimeInterval = 30
    private static let checkoutLockPrefix = "ufogeo.checkout-lock."
    private static let subscriptionReconcilePrefix = "ufogeo.subscription-reconcile."
    private static let checkoutReturnReconcilePrefix = "ufogeo.checkout-return-reconcile."
    nonisolated private static let checkoutReturnReconcileRetryLimit = 1
    private static let subscriptionReconcileRetryDelayNanoseconds: UInt64 = 1_000_000_000
    nonisolated private static let checkoutSyncFirstGuidance =
        "為避免重複付款，請先重新同步並等待確認；若既有付款有效，同步後可恢復。"
    nonisolated private static let accountSyncFirstGuidance =
        "為避免重複付款，請先重新同步並等待確認；若既有訂閱有效，同步後可恢復。"

    var isCheckoutLocked: Bool {
        guard let uid = authService.session?.uid else { return false }
        let key = Self.checkoutLockPrefix + uid
        let timestamp = UserDefaults.standard.double(forKey: key)
        guard timestamp > 0 else { return false }
        return Date().timeIntervalSince1970 - timestamp < Self.checkoutCooldownSeconds
    }

    /// A recovery request is allowed only for the currently authenticated,
    /// verified member and only when the local account has no usable Portaly
    /// entitlement.  The server derives the email from the Firebase token;
    /// the client never sends an email or subscription identifier for this
    /// operation.
    var shouldOfferSubscriptionRecovery: Bool {
        guard let session = authService.session,
              session.emailVerified,
              !isRecoveryRequestInFlight,
              recoveryState != .recovered,
              recoveryState != .alreadyBound else { return false }

        guard let subscription,
              subscription.uid == session.uid else { return true }
        return !subscription.canonicalProjection(emailVerified: true).isPro
    }

    /// The initial account sync may try recovery once for a new Firebase UID.
    /// A failed provider request is deliberately left to the user-initiated
    /// retry button instead of being retried on every foreground refresh.
    var shouldAttemptAutomaticSubscriptionRecovery: Bool {
        guard shouldOfferSubscriptionRecovery,
              let session = authService.session,
              recoveryAttemptedIdentity != recoveryIdentity(for: session) else {
            return false
        }
        guard let subscription,
              subscription.uid == session.uid else { return false }
        let payment = subscription.canonicalProjection(emailVerified: true).payment
        return [.none, .checkoutFailed, .canceled].contains(payment)
    }

    var recoveryBlocksCheckout: Bool {
        recoveryState == .inFlight ? isRecoveryRequestInFlight : recoveryState.blocksCheckout
    }

    var isRecoveryRequestInFlight: Bool {
        recoveryState == .inFlight
            && Self.requestTaskBelongsToCurrentUID(
                ownerUID: recoveryTaskUID,
                currentUID: authService.session?.uid
            )
    }

    var isLoadingForCurrentSession: Bool {
        guard let uid = authService.session?.uid else { return false }
        return (loadingRequestCounts[uid] ?? 0) > 0
    }

    var isCheckoutRequestInFlightForCurrentSession: Bool {
        isCheckoutRequestInFlight
            && Self.requestTaskBelongsToCurrentUID(
                ownerUID: checkoutRequestUID,
                currentUID: authService.session?.uid
            )
    }

    var isPortalRequestInFlightForCurrentSession: Bool {
        isPortalRequestInFlight
            && Self.requestTaskBelongsToCurrentUID(
                ownerUID: portalRequestUID,
                currentUID: authService.session?.uid
            )
    }

    var recoveryStatusMessage: String? {
        switch recoveryState {
        case .idle, .alreadyBound:
            return nil
        case .inFlight:
            return "正在從 Portaly 恢復既有訂閱；請稍候，不會建立新的付款或扣款。"
        case .recovered:
            return "已恢復既有 Portaly Pro 訂閱，不需要重新付款。"
        case .notFound:
            return "目前沒有找到可恢復的 Portaly Pro 訂閱；若要使用 Pro，可以開始新的訂閱。"
        case .ambiguous:
            return "找到多筆可用的 Portaly 訂閱，為避免綁定錯誤，尚未變更帳號。請聯絡支援。"
        case .unavailable:
            return "目前無法確認 Portaly 訂閱，付款狀態尚未確認。\(Self.checkoutSyncFirstGuidance)"
        case .conflict:
            return "目前帳號已有不同的訂閱狀態，為避免覆寫資料，請重新同步或聯絡支援。"
        case .safetyHold:
            return "刪帳安全確認尚未完成，請稍後再試。"
        }
    }

    var recoveryStatusIcon: String {
        switch recoveryState {
        case .idle, .alreadyBound:
            return "questionmark.circle"
        case .inFlight:
            return "arrow.triangle.2.circlepath"
        case .recovered:
            return "checkmark.seal.fill"
        case .notFound:
            return "info.circle"
        case .ambiguous, .unavailable, .conflict, .safetyHold:
            return "exclamationmark.triangle.fill"
        }
    }

    var isPro: Bool {
        guard let uid = authService.session?.uid,
              let subscription,
              subscription.uid == uid,
              let entitlementValidatedAt else { return false }
        return subscription.canonicalProjection(
            emailVerified: authService.session?.emailVerified == true
        ).isPro
            && !isEntitlementCacheExpired
            && Self.cacheIsFresh(cachedAt: entitlementValidatedAt)
    }

    func membershipProjection(
        initialSyncCompleted: Bool,
        syncFailed: Bool
    ) -> MembershipProjection {
        Self.membershipProjection(
            subscription: subscription,
            currentUID: authService.session?.uid,
            emailVerified: authService.session?.emailVerified == true,
            validatedAt: entitlementValidatedAt,
            isCacheExpired: isEntitlementCacheExpired,
            initialSyncCompleted: initialSyncCompleted,
            syncFailed: syncFailed
        )
    }

    var membershipSyncFlagsForCurrentSession: (completed: Bool, failed: Bool) {
        Self.initialSyncFlags(
            outcome: membershipSyncOutcome,
            currentUID: authService.session?.uid
        )
    }

    static func membershipProjection(
        subscription: SubscriptionState?,
        currentUID: String?,
        emailVerified: Bool,
        validatedAt: Date?,
        isCacheExpired: Bool,
        initialSyncCompleted: Bool,
        syncFailed: Bool,
        now: Date = Date()
    ) -> MembershipProjection {
        guard let currentUID,
              let subscription,
              subscription.uid == currentUID,
              let validatedAt,
              !isCacheExpired,
              Self.cacheIsFresh(cachedAt: validatedAt, now: now) else {
            return initialSyncCompleted || syncFailed
                ? .unavailable(syncFailed: syncFailed)
                : .checking
        }
        return subscription.canonicalProjection(emailVerified: emailVerified, now: now)
    }

    var needsProEntitlementRefresh: Bool {
        isPro && Self.shouldAttemptEntitlementRefresh(
            validatedAt: entitlementValidatedAt,
            lastAttemptAt: lastEntitlementRefreshAttemptAt,
            interval: Self.effectiveEntitlementRefreshInterval(expiringStage: subscription?.expiringStage)
        )
    }

    var proEntitlementRefreshDelay: TimeInterval {
        Self.entitlementRefreshDelay(
            validatedAt: entitlementValidatedAt,
            lastAttemptAt: lastEntitlementRefreshAttemptAt,
            interval: Self.effectiveEntitlementRefreshInterval(expiringStage: subscription?.expiringStage)
        )
    }

    var canUseJoystick: Bool {
        MembershipFeaturePolicy.canUseJoystick(proActive: isPro)
    }

    var canUseBackgroundRouteSimulation: Bool {
        MembershipFeaturePolicy.canRunRoute(inBackground: true, proActive: isPro)
    }

    /// Accept only the app-owned Portaly return contract.  The callback is a
    /// signal to refresh server state; it never carries identity or payment
    /// data and is never treated as proof of entitlement by itself.
    nonisolated static func portalyReturnFlow(from url: URL) -> PortalyReturnFlow? {
        guard url.scheme == "ufogeo",
              url.host == "portaly-return",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.path.isEmpty,
              url.fragment == nil,
              !url.absoluteString.contains("#"),
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              components.scheme == "ufogeo",
              components.host == "portaly-return",
              components.path.isEmpty,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1,
              let flowItem = queryItems.first,
              flowItem.name == "flow",
              let value = flowItem.value else {
            return nil
        }
        return PortalyReturnFlow(rawValue: value)
    }

    @discardableResult
    func refreshProEntitlementIfNeeded() async -> Bool {
        guard isPro else { return false }
        guard needsProEntitlementRefresh else { return true }
        do {
            _ = try await refreshSubscription(force: true)
        } catch {
            scheduleEntitlementExpiry()
        }
        return isPro
    }

    static func shouldSynchronizeOnForeground(
        subscription: SubscriptionState?,
        needsReconcile: Bool,
        needsCheckoutRefresh: Bool = false
    ) -> Bool {
        needsReconcile || needsCheckoutRefresh || shouldRefreshOnForeground(
            subscription: subscription
        )
    }

    static func shouldRefreshOnForeground(subscription: SubscriptionState?) -> Bool {
        guard let subscription else { return true }
        switch subscription.canonicalProjection(emailVerified: true).payment {
        case .checkoutReady, .pastDue, .unavailable:
            return true
        default:
            return false
        }
    }

    /// Decide whether a portal-return marker can be consumed. A matching
    /// provider response is not confirmation that the hosted portal action was
    /// applied; keep the marker so a later foreground can reconcile again.
    /// A changed lifecycle state is the only local evidence that the portal
    /// action reached Portaly, so it consumes the marker after reconciliation.
    static func portalReconciliationCanClearMarker(
        previous: SubscriptionState?,
        latest: SubscriptionState?
    ) -> Bool {
        // A cold start may have no cached baseline. The first provider
        // response is therefore not proof that the portal action was applied;
        // keep the marker for a later foreground with a known baseline.
        guard let previous, let latest, previous.uid == latest.uid else {
            return false
        }
        let stateIsUnchanged = previous.subscriptionId == latest.subscriptionId &&
            previous.proActive == latest.proActive &&
            previous.subscriptionStatus == latest.subscriptionStatus &&
            previous.cancelAtPeriodEnd == latest.cancelAtPeriodEnd &&
            previous.cancelEffectiveAt == latest.cancelEffectiveAt &&
            previous.nextBillingAt == latest.nextBillingAt
        return !stateIsUnchanged
    }

    nonisolated static func armCheckoutReturnReconcileRetries(
        current: Int,
        limit: Int = checkoutReturnReconcileRetryLimit
    ) -> Int {
        max(current, max(limit, 0))
    }

    nonisolated static func consumeCheckoutReturnReconcileRetries(
        current: Int
    ) -> Int {
        max(current - 1, 0)
    }

    private struct CheckoutResponse: Decodable {
        let checkoutUrl: URL
    }

    private struct PortalResponse: Decodable {
        let portalUrl: URL
    }

    private struct AccountDeletionResponse: Decodable {
        let deleted: Bool
    }

    private struct ErrorResponse: Decodable {
        let error: String
        let code: String?
    }

    private struct CachedSubscription: Codable {
        let value: SubscriptionState
        let cachedAt: Date
    }

    private struct QueuedPortalyReturn: Equatable {
        let flow: PortalyReturnFlow
        let uid: String
    }

    enum PortalyReturnFlow: String, Equatable {
        case checkout
        case portal
    }

    nonisolated private static let cacheLifetime: TimeInterval = 24 * 60 * 60
    nonisolated static let entitlementRefreshInterval: TimeInterval = 15 * 60
    nonisolated private static let entitlementRefreshIntervalExpiringSoon: TimeInterval = 30 * 60  // 30 分鐘
    nonisolated private static let entitlementRefreshIntervalExpiringToday: TimeInterval = 5 * 60  // 5 分鐘
    nonisolated private static let entitlementRefreshIntervalExpiringFar: TimeInterval = 60 * 60  // 1 小時
    private static let keychainService = "tw.ufogeo.subscription"
    private static let keychainAccount = "verified-state"
    private let authService: FirebaseAuthService
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let portakySession: URLSession
    private(set) var needsSubscriptionReconcile = false
    private var reconcileMarkerUID: String?
    private var reconciliationInFlightID: UUID?
    private var reconciliationInFlightUID: String?
    private var foregroundSyncTask: Task<Void, Error>?
    private var foregroundSyncID: UUID?
    private var foregroundSyncUID: String?
    private var portalyReturnQueue: [QueuedPortalyReturn] = []
    private var portalyReturnRetryQueue: [QueuedPortalyReturn] = []
    private var portalyReturnProcessorTask: Task<Void, Never>?
    private var portalyReturnProcessorID: UUID?
    private var portalyReturnProcessorUID: String?
    private var subscriptionRefreshTask: Task<SubscriptionState, Error>?
    private var subscriptionRefreshID: UUID?
    private var subscriptionRefreshUID: String?
    private var checkoutRequestUID: String?
    private var portalRequestUID: String?
    private var recoveryTask: Task<SubscriptionRecoveryOutcome, Error>?
    private var recoveryTaskID: UUID?
    private var recoveryTaskUID: String?
    private var recoveryAttemptedIdentity: String?
    private var lastKnownSessionUID: String?
    private var entitlementValidatedAt: Date?
    private var lastEntitlementRefreshAttemptAt: Date?
    private var entitlementExpiryTask: Task<Void, Never>?
    private var loadingRequestCounts: [String: Int] = [:]
    private var checkoutReturnReconcileUID: String?
    private var checkoutReturnReconcileRetries = 0

    init(authService: FirebaseAuthService? = nil) {
        let resolvedAuthService = authService ?? FirebaseAuthService.shared
        self.authService = resolvedAuthService
        self.lastKnownSessionUID = resolvedAuthService.session?.uid
        
        // 配置帶有適當超時的 URLSession
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30  // 請求總超時 30 秒
        config.timeoutIntervalForResource = 30  // 資源獲取超時 30 秒
        config.waitsForConnectivity = true  // 等待連接可用
        config.requestCachePolicy = .useProtocolCachePolicy
        self.portakySession = URLSession(configuration: config)
        
        if let uid = resolvedAuthService.session?.uid {
            reconcileMarkerUID = uid
            needsSubscriptionReconcile = Self.readReconcileMarker(for: uid)
        }
        if let uid = resolvedAuthService.session?.uid,
           let cache = Self.readCache(),
           cache.value.uid == uid,
           Self.cacheIsFresh(cachedAt: cache.cachedAt) {
            subscription = cache.value
            entitlementValidatedAt = cache.cachedAt
            isEntitlementCacheExpired = false
        } else {
            // 快取已過期或不存在，冷啟動時標記為過期
            isEntitlementCacheExpired = true
        }
        scheduleEntitlementExpiry()
    }

    nonisolated static func cacheIsFresh(cachedAt: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(cachedAt)
        return age >= 0 && age < cacheLifetime
    }

    nonisolated static func effectiveEntitlementRefreshInterval(
        expiringStage: String?,
        defaultInterval: TimeInterval = entitlementRefreshInterval
    ) -> TimeInterval {
        guard let expiringStage else { return defaultInterval }
        switch expiringStage {
        case "today":
            return entitlementRefreshIntervalExpiringToday
        case "soon":
            return entitlementRefreshIntervalExpiringSoon
        case "far":
            return entitlementRefreshIntervalExpiringFar
        default:
            return defaultInterval
        }
    }

    nonisolated static func shouldAttemptEntitlementRefresh(
        validatedAt: Date?,
        lastAttemptAt: Date?,
        now: Date = Date(),
        interval: TimeInterval = entitlementRefreshInterval
    ) -> Bool {
        guard interval > 0 else { return true }
        guard let validatedAt else { return true }
        let validationAge = now.timeIntervalSince(validatedAt)
        guard validationAge >= 0, validationAge < interval else {
            if let lastAttemptAt {
                let attemptAge = now.timeIntervalSince(lastAttemptAt)
                if attemptAge >= 0, attemptAge < interval {
                    return false
                }
            }
            return true
        }
        return false
    }

    nonisolated static func entitlementRefreshDelay(
        validatedAt: Date?,
        lastAttemptAt: Date?,
        now: Date = Date(),
        interval: TimeInterval = entitlementRefreshInterval
    ) -> TimeInterval {
        guard interval > 0, let validatedAt else { return 0 }
        let validationAge = now.timeIntervalSince(validatedAt)
        guard validationAge >= 0 else { return 0 }
        let validationDelay = interval - validationAge
        if validationDelay > 0 { return validationDelay }
        guard let lastAttemptAt else { return 0 }
        let attemptAge = now.timeIntervalSince(lastAttemptAt)
        guard attemptAge >= 0 else { return 0 }
        return max(0, interval - attemptAge)
    }

    nonisolated static func calculateExpiringStage(
        proActive: Bool,
        subscriptionStatus: String,
        nextBillingAt: String?,
        now: Date = Date()
    ) -> String {
        guard proActive, subscriptionStatus == "active", let billingDateString = nextBillingAt else {
            return "none"
        }

        guard let billingDate = ISO8601DateFormatter().date(from: billingDateString) else {
            return "none"
        }

        let daysUntilRenewal = billingDate.timeIntervalSince(now) / (24 * 60 * 60)

        if daysUntilRenewal < 0 {
            return "expired"
        } else if daysUntilRenewal < 1 {
            return "today"
        } else if daysUntilRenewal < 2 {
            return "soon"
        } else if daysUntilRenewal < 3 {
            return "far"
        } else {
            return "none"
        }
    }

    /// Rebind a Portaly subscription to the currently authenticated Firebase
    /// UID after the local Firebase/Firestore identity was rebuilt.  This is
    /// intentionally a separate server endpoint: the client sends only an
    /// empty JSON object and a Firebase bearer token, while the backend derives
    /// the verified email, Portaly mode, plan, and candidate subscription.
    @discardableResult
    func recoverSubscription(
        force: Bool = false
    ) async throws -> SubscriptionRecoveryOutcome {
        prepareForCurrentAuthSession()
        guard let expectedSession = authService.session else {
            throw CheckoutError.server("請先登入 UFOGeo 帳號後再試。")
        }
        guard expectedSession.emailVerified else {
            throw CheckoutError.serverResponse(
                code: "EMAIL_NOT_VERIFIED",
                message: Self.serverErrorMessage(
                    code: "EMAIL_NOT_VERIFIED",
                    serverMessage: nil
                )
            )
        }

        if !force,
           let attemptedIdentity = recoveryAttemptedIdentity,
           attemptedIdentity == recoveryIdentity(for: expectedSession) {
            switch recoveryState {
            case .recovered:
                return .recovered
            case .alreadyBound:
                return .alreadyBound
            case .notFound:
                return .notFound
            default:
                break
            }
        }

        // A valid local provider entitlement is already bound.  Do not make a
        // second provider lookup just because a view appeared again.
        if let current = subscription,
           current.uid == expectedSession.uid,
           current.canonicalProjection(emailVerified: true).isPro {
            recoveryState = .alreadyBound
            return .alreadyBound
        }

        if let recoveryTask {
            return try await recoveryTask.value
        }

        let expectedUID = expectedSession.uid
        let expectedEmail = expectedSession.email
        recoveryAttemptedIdentity = recoveryIdentity(for: expectedSession)
        recoveryState = .inFlight

        let operationID = UUID()
        let task = Task { @MainActor in
            do {
                // Email verification can complete while the app is open. Use
                // a newly minted token so the backend sees the current claim.
                _ = try await authService.validIDToken(forceRefresh: true)
                let response: SubscriptionRecoveryResponse = try await authenticatedRequest(
                    path: "/api/portaly/subscription/recover",
                    method: "POST",
                    ownerUID: expectedUID
                )
                guard recoveryTaskID == operationID,
                      authService.session?.uid == expectedUID else {
                    throw CancellationError()
                }
                guard response.value.uid == expectedUID,
                      Self.normalizedEmail(response.value.email) ==
                        Self.normalizedEmail(expectedEmail),
                      response.value.emailVerified,
                      ["live", "test"].contains(response.value.mode ?? ""),
                      response.value.canonicalProjection(emailVerified: true).entitlement !=
                        .unavailable else {
                    throw CheckoutError.invalidResponse
                }

                let outcome = try recoveryOutcome(
                    status: response.recoveryStatus,
                    state: response.value
                )
                try persistSubscription(response.value)
                recoveryState = Self.recoveryState(for: outcome)
                return outcome
            } catch is CancellationError {
                // A sign-out/session switch may cancel this operation after
                // the request started. Never leave the next UID stuck behind
                // the previous member's in-flight recovery state.
                if recoveryTaskID == operationID {
                    recoveryState = .idle
                    recoveryAttemptedIdentity = nil
                }
                throw CancellationError()
            } catch {
                guard recoveryTaskID == operationID,
                      authService.session?.uid == expectedUID else {
                    throw CancellationError()
                }
                let failedState = Self.recoveryState(for: error)
                recoveryState = failedState
                if failedState == .notFound {
                    // A compatible backend may use a 404 for the explicit
                    // no-match result. It is safe to expose Free state only
                    // when the server supplied this stable outcome code.
                    return .notFound
                }
                throw error
            }
        }
        recoveryTaskID = operationID
        recoveryTaskUID = expectedUID
        recoveryTask = task
        defer {
            if recoveryTaskID == operationID {
                recoveryTask = nil
                recoveryTaskID = nil
                recoveryTaskUID = nil
            }
        }
        return try await task.value
    }

    func createCheckoutURL() async throws -> URL {
        prepareForCurrentAuthSession()
        guard !recoveryState.blocksCheckout else {
            throw CheckoutError.serverResponse(
                code: "PORTALY_RECOVERY_REQUIRED",
                message: "目前正在確認既有 Portaly 訂閱，為避免重複付款，請先完成恢復或重新嘗試。"
            )
        }
        guard !isCheckoutRequestInFlightForCurrentSession else {
            throw CheckoutError.checkoutRequestInFlight
        }
        guard let uid = authService.session?.uid else {
            throw CheckoutError.server("請先登入 UFOGeo 帳號後再試。")
        }
        let key = Self.checkoutLockPrefix + uid
        let now = Date().timeIntervalSince1970
        let lastAttempt = UserDefaults.standard.double(forKey: key)
        if lastAttempt > 0, now - lastAttempt < Self.checkoutCooldownSeconds {
            throw CheckoutError.server("請稍等 30 秒後再試一次。")
        }
        UserDefaults.standard.set(now, forKey: key)
        isCheckoutRequestInFlight = true
        checkoutRequestUID = uid
        var shouldKeepCheckoutLock = false
        defer {
            if checkoutRequestUID == uid {
                isCheckoutRequestInFlight = false
                checkoutRequestUID = nil
            }
            if !shouldKeepCheckoutLock {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Verification can finish while the app is already open. Always use
        // a freshly minted token for this security-sensitive request.
        _ = try await authService.validIDToken(forceRefresh: true)
        let response: CheckoutResponse = try await authenticatedRequest(
            path: "/api/portaly/checkout",
            method: "POST",
            ownerUID: uid
        )
        guard response.checkoutUrl.scheme == "https" else {
            throw CheckoutError.invalidResponse
        }
        guard authService.session?.uid == uid else {
            throw CancellationError()
        }
        shouldKeepCheckoutLock = true
        return response.checkoutUrl
    }

    func createPortalURL() async throws -> URL {
        prepareForCurrentAuthSession()
        guard !isPortalRequestInFlightForCurrentSession else {
            throw CheckoutError.portalRequestInFlight
        }
        guard let expectedUID = authService.session?.uid else {
            throw CheckoutError.server("請先登入 UFOGeo 帳號後再試。")
        }
        isPortalRequestInFlight = true
        portalRequestUID = expectedUID
        defer {
            if portalRequestUID == expectedUID {
                isPortalRequestInFlight = false
                portalRequestUID = nil
            }
        }

        let response: PortalResponse = try await authenticatedRequest(
            path: "/api/portaly/portal",
            method: "POST",
            ownerUID: expectedUID
        )
        guard response.portalUrl.scheme == "https" else { throw CheckoutError.invalidResponse }
        guard authService.session?.uid == expectedUID else {
            throw CancellationError()
        }
        return response.portalUrl
    }

    func deleteMemberAccount() async throws {
        prepareForCurrentAuthSession()
        guard let expectedUID = authService.session?.uid else {
            throw CheckoutError.server("請先登入 UFOGeo 帳號後再試。")
        }
        let response: AccountDeletionResponse = try await authenticatedRequest(
            path: "/api/account",
            method: "DELETE",
            ownerUID: expectedUID
        )
        guard authService.session?.uid == expectedUID else {
            throw CancellationError()
        }
        guard response.deleted else { throw CheckoutError.invalidResponse }
        clearLocalState()
    }

    @discardableResult
    func refreshSubscription(force: Bool = false) async throws -> SubscriptionState {
        prepareForCurrentAuthSession()
        guard let expectedUID = authService.session?.uid else {
            throw CheckoutError.server("請先登入 UFOGeo 帳號後再試。")
        }

        if !force,
           let cache = Self.readCache(),
           cache.value.uid == expectedUID,
           Self.cacheIsFresh(cachedAt: cache.cachedAt) {
            subscription = cache.value
            entitlementValidatedAt = cache.cachedAt
            isEntitlementCacheExpired = false
            scheduleEntitlementExpiry()
            markRecoveryStateForRefreshedSubscription(cache.value)
            return cache.value
        }

        if let subscriptionRefreshTask {
            return try await subscriptionRefreshTask.value
        }

        lastEntitlementRefreshAttemptAt = Date()
        let refreshID = UUID()
        let task = Task { @MainActor in
            let value: SubscriptionState
            do {
                value = try await authenticatedRequest(
                    path: "/api/portaly/subscription",
                    method: "GET",
                    ownerUID: expectedUID
                )
            } catch {
                invalidateEntitlementCacheIfNeeded(for: error, expectedUID: expectedUID)
                throw error
            }
            guard subscriptionRefreshID == refreshID,
                  authService.session?.uid == expectedUID else {
                throw CancellationError()
            }
            guard value.uid == expectedUID else {
                invalidateEntitlementCache()
                throw CheckoutError.invalidResponse
            }
            try persistSubscription(value)
            markRecoveryStateForRefreshedSubscription(value)
            return value
        }
        subscriptionRefreshID = refreshID
        subscriptionRefreshUID = expectedUID
        subscriptionRefreshTask = task
        defer {
            if subscriptionRefreshID == refreshID {
                subscriptionRefreshTask = nil
                subscriptionRefreshID = nil
                subscriptionRefreshUID = nil
            }
        }
        return try await task.value
    }

    /// Reconcile the server's entitlement after the user returns from
    /// Portaly's hosted subscription management page.  This endpoint is
    /// intentionally separate from `refreshSubscription`: a normal refresh
    /// reads Firestore and may therefore return the state that existed before
    /// Portaly processed a resume request.
    @discardableResult
    func reconcileSubscriptionIfNeeded(force: Bool = false) async throws -> SubscriptionState? {
        prepareForCurrentAuthSession()
        loadReconcileMarkerIfNeeded()
        guard force || needsSubscriptionReconcile else { return nil }
        guard let reconciliationUID = authService.session?.uid else { return nil }
        guard reconciliationInFlightID == nil,
              reconciliationInFlightUID == nil else { return nil }

        let operationID = UUID()
        reconciliationInFlightID = operationID
        reconciliationInFlightUID = reconciliationUID
        defer {
            if reconciliationInFlightID == operationID {
                reconciliationInFlightID = nil
                reconciliationInFlightUID = nil
            }
        }
        // A service instance can outlive an auth-session switch. Never use a
        // prior member's cached state as the baseline for the new UID.
        let previousState = subscription?.uid == reconciliationUID
            ? subscription
            : nil
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard reconciliationInFlightID == operationID,
                  reconciliationInFlightUID == reconciliationUID,
                  authService.session?.uid == reconciliationUID else {
                throw CancellationError()
            }
            let response: SubscriptionResponse
            do {
                response = try await authenticatedRequest(
                    path: "/api/portaly/subscription/reconcile",
                    method: "POST",
                    ownerUID: reconciliationUID
                )
            } catch {
                invalidateEntitlementCacheIfNeeded(for: error, expectedUID: reconciliationUID)
                throw error
            }
            try Task.checkCancellation()
            guard reconciliationInFlightID == operationID,
                  reconciliationInFlightUID == reconciliationUID,
                  authService.session?.uid == reconciliationUID else {
                throw CancellationError()
            }
            guard response.value.uid == reconciliationUID else {
                invalidateEntitlementCache()
                throw CheckoutError.invalidResponse
            }
            try persistSubscription(response.value)
            let canClearMarker = Self.portalReconciliationCanClearMarker(
                previous: previousState,
                latest: response.value
            )

            if attempt == 0, !canClearMarker {
                // Keep the marker set while waiting for a possible provider
                // state propagation. If the retry fails, the marker remains
                // persisted and the next foreground can retry again.
                setReconcileMarker(true)
                try await Task.sleep(
                    nanoseconds: Self.subscriptionReconcileRetryDelayNanoseconds
                )
                continue
            }

            try Task.checkCancellation()
            guard reconciliationInFlightID == operationID,
                  reconciliationInFlightUID == reconciliationUID,
                  authService.session?.uid == reconciliationUID else {
                throw CancellationError()
            }
            // Two unchanged responses are insufficient confirmation that the
            // hosted portal action was applied. Leave the persisted marker for
            // the next foreground retry.
            setReconcileMarker(!canClearMarker)
            return response.value
        }

        return subscription
    }

    func synchronizeOnForeground(
        forceRefresh: Bool = false,
        forceReconcile: Bool? = nil
    ) async throws {
        startPortalyReturnProcessorIfNeeded()
        guard let uid = authService.session?.uid else { return }
        if let foregroundSyncTask {
            return try await foregroundSyncTask.value
        }

        loadReconcileMarkerIfNeeded()
        loadCheckoutReturnReconcileRetriesIfNeeded()
        let shouldReconcile = forceReconcile ?? (needsSubscriptionReconcile && forceRefresh)
        guard Self.shouldSynchronizeOnForeground(
            subscription: subscription?.uid == uid ? subscription : nil,
            needsReconcile: shouldReconcile,
            needsCheckoutRefresh: forceRefresh
        ) else {
            membershipSyncOutcome = .succeeded(uid: uid)
            return
        }

        let operationID = UUID()
        membershipSyncOutcome = .inFlight(uid: uid)
        let task = Task { @MainActor in
            defer {
                // Clear the shared task before this task becomes observable as
                // completed so a queued callback can start its own sync.
                if foregroundSyncID == operationID {
                    foregroundSyncTask = nil
                    foregroundSyncID = nil
                    foregroundSyncUID = nil
                }
            }
            do {
                var consumedCheckoutFallbackRetry = false
                if shouldReconcile {
                    consumedCheckoutFallbackRetry = consumeCheckoutReturnReconcileRetryIfNeeded()
                    do {
                        _ = try await reconcileSubscriptionIfNeeded(force: true)
                    } catch {
                        if consumedCheckoutFallbackRetry,
                           checkoutReturnReconcileRetries == 0 {
                            // Keep checkout fallback retries finite.
                            setReconcileMarker(false)
                        }
                        throw error
                    }
                    if consumedCheckoutFallbackRetry,
                       checkoutReturnReconcileRetries == 0 {
                        // Checkout fallback only gets a bounded foreground retry.
                        setReconcileMarker(false)
                    }
                }
                _ = try await refreshSubscription(force: true)
                guard foregroundSyncID == operationID,
                      authService.session?.uid == uid else {
                    throw CancellationError()
                }
                membershipSyncOutcome = .succeeded(uid: uid)
            } catch is CancellationError {
                if foregroundSyncID == operationID {
                    membershipSyncOutcome = .cancelled(uid: uid)
                }
                throw CancellationError()
            } catch {
                if foregroundSyncID == operationID,
                   authService.session?.uid == uid {
                    membershipSyncOutcome = .failed(uid: uid)
                }
                throw error
            }
        }
        foregroundSyncID = operationID
        foregroundSyncUID = uid
        foregroundSyncTask = task
        try await task.value
    }

    /// Receive only an app-owned Portaly deep-link callback. Each accepted
    /// callback is queued, so rapid returns cannot be dropped or overlap.
    func handlePortalyReturnURL(_ url: URL) {
        guard let uid = authService.session?.uid else { return }
        guard let flow = Self.portalyReturnFlow(from: url) else { return }
        if !portalyReturnRetryQueue.isEmpty {
            let retryItems = portalyReturnRetryQueue.filter { $0.uid == uid }
            portalyReturnQueue.insert(contentsOf: retryItems, at: 0)
            portalyReturnRetryQueue.removeAll { $0.uid == uid }
        }
        portalyReturnQueue.append(.init(flow: flow, uid: uid))
        startPortalyReturnProcessorIfNeeded()
    }

    private func startPortalyReturnProcessorIfNeeded() {
        prepareForCurrentAuthSession()
        guard let uid = authService.session?.uid else { return }
        guard portalyReturnProcessorTask == nil,
              !portalyReturnQueue.isEmpty else { return }

        let processorID = UUID()
        let task = Task { @MainActor in
            defer {
                if portalyReturnProcessorID == processorID {
                    portalyReturnProcessorTask = nil
                    portalyReturnProcessorID = nil
                    portalyReturnProcessorUID = nil
                    // Callbacks received while this batch was awaiting the
                    // server are handled by a fresh task. Failed items remain
                    // in the retry queue until another explicit callback
                    // arrives.
                    if authService.session?.uid != nil,
                       !portalyReturnQueue.isEmpty {
                        startPortalyReturnProcessorIfNeeded()
                    }
                }
            }

            guard authService.session?.uid == uid else { return }
            let batch = portalyReturnQueue.filter { $0.uid == uid }
            portalyReturnQueue.removeAll(keepingCapacity: true)
            for item in batch {
                guard authService.session?.uid == uid else { return }
                do {
                    try await synchronizeAfterPortalyReturn(item)
                } catch is CancellationError {
                    return
                } catch {
                    // A failed callback is retained for an explicit retry;
                    // do not spin on a failing network request.
                    guard portalyReturnProcessorID == processorID,
                          authService.session?.uid == uid else { return }
                    if item.flow == .checkout {
                        armCheckoutReturnReconcileRetryIfNeeded()
                    }
                    portalyReturnRetryQueue.append(item)
                }
            }
        }
        portalyReturnProcessorID = processorID
        portalyReturnProcessorUID = uid
        portalyReturnProcessorTask = task
    }

    private func synchronizeAfterPortalyReturn(
        _ item: QueuedPortalyReturn
    ) async throws {
        guard authService.session?.uid == item.uid else {
            throw CheckoutError.server("請先登入 UFOGeo 帳號後再試。")
        }
        let flow = item.flow
        if flow == .portal {
            // Only an explicit portal callback creates the reconcile marker.
            setReconcileMarker(true)
            clearCheckoutReturnReconcileRetries()
        }
        // Wait for an initial/session refresh already in flight, then run the
        // callback's own forced request. This preserves checkout GET-only and
        // portal POST-then-GET semantics.
        if let foregroundSyncTask,
           Self.requestTaskBelongsToCurrentUID(
               ownerUID: foregroundSyncUID,
               currentUID: item.uid
           ) {
            try await foregroundSyncTask.value
        }
        guard authService.session?.uid == item.uid else {
            throw CancellationError()
        }
        try await synchronizeOnForeground(
            forceRefresh: true,
            forceReconcile: flow == .portal
        )
    }

    /// Cancel or isolate work that belongs to a previous Firebase session.
    /// Auth can change while a URLSession request is awaiting a response, so
    /// clearing only the published state is not enough: the old task must no
    /// longer be reusable by the new member.
    private func prepareForCurrentAuthSession() {
        let currentUID = authService.session?.uid
        if lastKnownSessionUID != currentUID {
            if let previousUID = lastKnownSessionUID {
                membershipSyncOutcome = .cancelled(uid: previousUID)
            } else {
                membershipSyncOutcome = .idle
            }
            lastKnownSessionUID = currentUID
            subscription = nil
            entitlementValidatedAt = nil
            isEntitlementCacheExpired = true
            entitlementExpiryTask?.cancel()
            entitlementExpiryTask = nil
            recoveryAttemptedIdentity = nil
            recoveryState = .idle
            reconcileMarkerUID = nil
            needsSubscriptionReconcile = false
            checkoutReturnReconcileUID = nil
            checkoutReturnReconcileRetries = 0
            KeychainStore.remove(service: Self.keychainService, account: Self.keychainAccount)
        }

        cancelStaleOperations(for: currentUID)
        discardPortalyReturnsNotOwnedByCurrentSession()
    }

    private func cancelStaleOperations(for currentUID: String?) {
        if !Self.requestTaskBelongsToCurrentUID(
            ownerUID: reconciliationInFlightUID,
            currentUID: currentUID
        ) {
            reconciliationInFlightID = nil
            reconciliationInFlightUID = nil
        }

        if !Self.requestTaskBelongsToCurrentUID(
            ownerUID: checkoutRequestUID,
            currentUID: currentUID
        ) {
            isCheckoutRequestInFlight = false
            checkoutRequestUID = nil
        }

        if !Self.requestTaskBelongsToCurrentUID(
            ownerUID: portalRequestUID,
            currentUID: currentUID
        ) {
            isPortalRequestInFlight = false
            portalRequestUID = nil
        }

        if let task = foregroundSyncTask,
           !Self.requestTaskBelongsToCurrentUID(
               ownerUID: foregroundSyncUID,
               currentUID: currentUID
           ) {
            task.cancel()
            foregroundSyncTask = nil
            foregroundSyncID = nil
            foregroundSyncUID = nil
        }

        if let task = portalyReturnProcessorTask,
           !Self.requestTaskBelongsToCurrentUID(
               ownerUID: portalyReturnProcessorUID,
               currentUID: currentUID
           ) {
            task.cancel()
            portalyReturnProcessorTask = nil
            portalyReturnProcessorID = nil
            portalyReturnProcessorUID = nil
        }

        if let task = subscriptionRefreshTask,
           !Self.requestTaskBelongsToCurrentUID(
               ownerUID: subscriptionRefreshUID,
               currentUID: currentUID
           ) {
            task.cancel()
            subscriptionRefreshTask = nil
            subscriptionRefreshID = nil
            subscriptionRefreshUID = nil
        }

        if let task = recoveryTask,
           !Self.requestTaskBelongsToCurrentUID(
               ownerUID: recoveryTaskUID,
               currentUID: currentUID
           ) {
            task.cancel()
            recoveryTask = nil
            recoveryTaskID = nil
            recoveryTaskUID = nil
            recoveryState = .idle
        }

        if let currentUID {
            let staleUIDs = loadingRequestCounts.keys.filter { $0 != currentUID }
            for uid in staleUIDs {
                loadingRequestCounts.removeValue(forKey: uid)
            }
        } else {
            loadingRequestCounts.removeAll()
        }
        updateLoadingState()
    }

    private func discardPortalyReturnsNotOwnedByCurrentSession() {
        guard let currentUID = authService.session?.uid else {
            portalyReturnQueue.removeAll(keepingCapacity: true)
            portalyReturnRetryQueue.removeAll(keepingCapacity: true)
            return
        }
        portalyReturnQueue.removeAll { $0.uid != currentUID }
        portalyReturnRetryQueue.removeAll { $0.uid != currentUID }
    }

    private func updateLoadingState() {
        guard let uid = authService.session?.uid else {
            isLoading = false
            return
        }
        isLoading = (loadingRequestCounts[uid] ?? 0) > 0
    }

    func clearLocalState() {
        let markerUID = authService.session?.uid ?? reconcileMarkerUID
        let checkoutFallbackUID = authService.session?.uid ?? checkoutReturnReconcileUID
        subscription = nil
        needsSubscriptionReconcile = false
        reconcileMarkerUID = nil
        checkoutReturnReconcileUID = nil
        checkoutReturnReconcileRetries = 0
        reconciliationInFlightID = nil
        reconciliationInFlightUID = nil
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncID = nil
        foregroundSyncUID = nil
        portalyReturnProcessorTask?.cancel()
        portalyReturnProcessorTask = nil
        portalyReturnProcessorID = nil
        portalyReturnProcessorUID = nil
        portalyReturnQueue.removeAll()
        portalyReturnRetryQueue.removeAll()
        subscriptionRefreshTask?.cancel()
        subscriptionRefreshTask = nil
        subscriptionRefreshID = nil
        subscriptionRefreshUID = nil
        isCheckoutRequestInFlight = false
        checkoutRequestUID = nil
        isPortalRequestInFlight = false
        portalRequestUID = nil
        loadingRequestCounts.removeAll()
        isLoading = false
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryTaskID = nil
        recoveryTaskUID = nil
        recoveryAttemptedIdentity = nil
        recoveryState = .idle
        entitlementExpiryTask?.cancel()
        entitlementExpiryTask = nil
        entitlementValidatedAt = nil
        lastEntitlementRefreshAttemptAt = nil
        isEntitlementCacheExpired = true
        if let uid = authService.session?.uid {
            membershipSyncOutcome = .cancelled(uid: uid)
        } else {
            membershipSyncOutcome = .idle
        }
        lastKnownSessionUID = nil
        if let uid = authService.session?.uid {
            UserDefaults.standard.removeObject(forKey: Self.checkoutLockPrefix + uid)
        }
        if let markerUID {
            UserDefaults.standard.removeObject(forKey: Self.reconcileMarkerKey(for: markerUID))
        }
        if let checkoutFallbackUID {
            UserDefaults.standard.removeObject(
                forKey: Self.checkoutReturnReconcileKey(for: checkoutFallbackUID)
            )
        }
        KeychainStore.remove(service: Self.keychainService, account: Self.keychainAccount)
    }

    private static func recoveryState(
        for outcome: SubscriptionRecoveryOutcome
    ) -> SubscriptionRecoveryState {
        switch outcome {
        case .recovered:
            return .recovered
        case .alreadyBound:
            return .alreadyBound
        case .notFound:
            return .notFound
        }
    }

    private static func recoveryState(
        for error: Error
    ) -> SubscriptionRecoveryState {
        guard let checkoutError = error as? CheckoutError else { return .unavailable }
        switch checkoutError.backendCode {
        case "PORTALY_RECOVERY_AMBIGUOUS", "SUBSCRIPTION_RECOVERY_AMBIGUOUS",
             "RECOVERY_SUBSCRIPTION_AMBIGUOUS":
            return .ambiguous
        case "ACCOUNT_DELETION_SAFETY_HOLD", "SUBSCRIPTION_RECOVERY_SAFETY_HOLD":
            return .safetyHold
        case "PORTALY_RECOVERY_CONFLICT", "SUBSCRIPTION_RECOVERY_CONFLICT",
             "RECOVERY_LOCAL_STATE_CONFLICT", "RECOVERY_EXISTING_BINDING_CONFLICT",
             "RECOVERY_PENDING_CHECKOUT", "PENDING_CHECKOUT_EXISTS", "CHECKOUT_SAFETY_HOLD":
            return .conflict
        case "PORTALY_RECOVERY_NOT_FOUND", "SUBSCRIPTION_RECOVERY_NOT_FOUND":
            return .notFound
        default:
            return .unavailable
        }
    }

    private func markRecoveryStateForRefreshedSubscription(
        _ value: SubscriptionState
    ) {
        guard value.uid == authService.session?.uid else { return }
        if value.proActive && value.subscriptionId != nil {
            recoveryState = .alreadyBound
        } else if recoveryState == .recovered || recoveryState == .alreadyBound {
            recoveryState = .idle
        }
    }

    private func recoveryOutcome(
        status: String,
        state: SubscriptionState
    ) throws -> SubscriptionRecoveryOutcome {
        let projection = state.canonicalProjection(emailVerified: true)
        guard projection.entitlement != .unavailable else {
            throw CheckoutError.invalidResponse
        }
        let hasPaidPortalyBinding = state.proActive
            && state.subscriptionId != nil
            && [.active, .pastDue, .canceling].contains(projection.payment)

        switch status.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "recovered":
            guard hasPaidPortalyBinding else { throw CheckoutError.invalidResponse }
            return .recovered
        case "already_bound", "alreadyBound":
            guard hasPaidPortalyBinding else { throw CheckoutError.invalidResponse }
            return .alreadyBound
        case "not_found", "notFound":
            guard !hasPaidPortalyBinding else { throw CheckoutError.invalidResponse }
            return .notFound
        default:
            throw CheckoutError.invalidResponse
        }
    }

    private func recoveryIdentity(
        for session: FirebaseAuthService.Session
    ) -> String {
        "\(session.uid)|\(Self.normalizedEmail(session.email))"
    }

    private static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func reconcileMarkerKey(for uid: String) -> String {
        subscriptionReconcilePrefix + uid
    }

    private static func readReconcileMarker(for uid: String) -> Bool {
        UserDefaults.standard.bool(forKey: reconcileMarkerKey(for: uid))
    }

    private static func checkoutReturnReconcileKey(for uid: String) -> String {
        checkoutReturnReconcilePrefix + uid
    }

    private static func readCheckoutReturnReconcileRetries(for uid: String) -> Int {
        max(UserDefaults.standard.integer(forKey: checkoutReturnReconcileKey(for: uid)), 0)
    }

    private func loadReconcileMarkerIfNeeded() {
        guard let uid = authService.session?.uid else {
            reconcileMarkerUID = nil
            needsSubscriptionReconcile = false
            return
        }
        guard reconcileMarkerUID != uid else { return }
        reconcileMarkerUID = uid
        needsSubscriptionReconcile = Self.readReconcileMarker(for: uid)
    }

    private func setReconcileMarker(_ value: Bool) {
        guard let uid = authService.session?.uid else {
            needsSubscriptionReconcile = false
            reconcileMarkerUID = nil
            return
        }
        reconcileMarkerUID = uid
        needsSubscriptionReconcile = value
        let defaults = UserDefaults.standard
        if value {
            defaults.set(true, forKey: Self.reconcileMarkerKey(for: uid))
        } else {
            defaults.removeObject(forKey: Self.reconcileMarkerKey(for: uid))
        }
    }

    private func loadCheckoutReturnReconcileRetriesIfNeeded() {
        guard let uid = authService.session?.uid else {
            checkoutReturnReconcileUID = nil
            checkoutReturnReconcileRetries = 0
            return
        }
        guard checkoutReturnReconcileUID != uid else { return }
        checkoutReturnReconcileUID = uid
        checkoutReturnReconcileRetries = Self.readCheckoutReturnReconcileRetries(for: uid)
    }

    private func armCheckoutReturnReconcileRetryIfNeeded() {
        loadCheckoutReturnReconcileRetriesIfNeeded()
        guard let uid = authService.session?.uid else { return }
        let retries = Self.armCheckoutReturnReconcileRetries(
            current: checkoutReturnReconcileRetries
        )
        guard retries != checkoutReturnReconcileRetries else { return }
        checkoutReturnReconcileRetries = retries
        UserDefaults.standard.set(retries, forKey: Self.checkoutReturnReconcileKey(for: uid))
        setReconcileMarker(true)
    }

    private func consumeCheckoutReturnReconcileRetryIfNeeded() -> Bool {
        loadCheckoutReturnReconcileRetriesIfNeeded()
        guard let uid = authService.session?.uid,
              checkoutReturnReconcileRetries > 0 else {
            return false
        }
        let remaining = Self.consumeCheckoutReturnReconcileRetries(
            current: checkoutReturnReconcileRetries
        )
        checkoutReturnReconcileRetries = remaining
        let key = Self.checkoutReturnReconcileKey(for: uid)
        if remaining > 0 {
            UserDefaults.standard.set(remaining, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return true
    }

    private func clearCheckoutReturnReconcileRetries() {
        guard let uid = authService.session?.uid else {
            checkoutReturnReconcileUID = nil
            checkoutReturnReconcileRetries = 0
            return
        }
        checkoutReturnReconcileUID = uid
        checkoutReturnReconcileRetries = 0
        UserDefaults.standard.removeObject(forKey: Self.checkoutReturnReconcileKey(for: uid))
    }

    private func authenticatedRequest<Response: Decodable>(
        path: String,
        method: String,
        ownerUID: String? = nil
    ) async throws -> Response {
        if let ownerUID, authService.session?.uid != ownerUID {
            throw CancellationError()
        }
        let requestUID = ownerUID ?? authService.session?.uid
        if let requestUID {
            loadingRequestCounts[requestUID, default: 0] += 1
        }
        updateLoadingState()
        defer {
            if let requestUID,
               let count = loadingRequestCounts[requestUID] {
                if count <= 1 {
                    loadingRequestCounts.removeValue(forKey: requestUID)
                } else {
                    loadingRequestCounts[requestUID] = count - 1
                }
            }
            updateLoadingState()
        }

        let token = try await authService.validIDToken()
        let baseURL = try configuredBaseURL()
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CheckoutError.invalidBackendURL
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw CheckoutError.invalidBackendURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        let maximumAttempts = method == "GET" ? 2 : 1
        for attempt in 0..<maximumAttempts {
            do {
                try Task.checkCancellation()
                let (data, response) = try await portakySession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CheckoutError.invalidResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorResponse = try? decoder.decode(ErrorResponse.self, from: data)
                    let message = Self.serverErrorMessage(
                        code: errorResponse?.code,
                        serverMessage: errorResponse?.error
                    )
                    throw CheckoutError.serverResponse(
                        code: errorResponse?.code,
                        message: message
                    )
                }
                do {
                    return try decoder.decode(Response.self, from: data)
                } catch let decodingError as DecodingError {
                    // 改進 Codable 解析的錯誤訊息
                    let errorMessage = self.localizedDecodingErrorMessage(decodingError)
                    #if DEBUG
                    print("[PortalyCheckoutService] JSON 解析失敗: \(errorMessage)")
                    #endif
                    throw CheckoutError.invalidResponse
                } catch {
                    throw CheckoutError.invalidResponse
                }
            } catch let error as CheckoutError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                guard Self.shouldRetryRequest(
                    method: method,
                    attempt: attempt,
                    error: error
                ) else {
                    throw error
                }
                #if DEBUG
                print("[PortalyCheckoutService] GET 暫時性網路錯誤，500ms 後重試：\(error.localizedDescription)")
                #endif
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                throw error
            }
        }
        throw CheckoutError.invalidResponse
    }

    nonisolated static func shouldRetryRequest(
        method: String,
        attempt: Int,
        error: Error
    ) -> Bool {
        guard method == "GET",
              attempt == 0,
              let urlError = error as? URLError else {
            return false
        }
        return isRetryableNetworkError(urlError)
    }

    private nonisolated static func isRetryableNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// 本地化 Decodable 解析錯誤訊息
    private func localizedDecodingErrorMessage(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            return "訂閱數據格式不正確: \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "缺少必要的訂閱信息 (\(key.stringValue)): \(context.debugDescription)"
        case .typeMismatch(let type, let context):
            return "訂閱數據類型不符 (期望 \(type)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "訂閱數據為空 (期望 \(type)): \(context.debugDescription)"
        @unknown default:
            return "訂閱數據解析失敗"
        }
    }

    private func configuredBaseURL() throws -> URL {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "PortalyBackendURL") as? String,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rawValue.contains("$(") else {
            throw CheckoutError.backendNotConfigured
        }
        guard let url = URL(string: rawValue), url.scheme == "https", url.host != nil else {
            throw CheckoutError.invalidBackendURL
        }
        return url
    }

    private static func readCache() -> CachedSubscription? {
        guard let data = KeychainStore.data(
            service: keychainService,
            account: keychainAccount
        ) else { return nil }
        return try? JSONDecoder().decode(CachedSubscription.self, from: data)
    }

    private func persistSubscription(_ value: SubscriptionState) throws {
        let validatedAt = Date()
        let data = try encoder.encode(CachedSubscription(value: value, cachedAt: validatedAt))
        try KeychainStore.set(
            data,
            service: Self.keychainService,
            account: Self.keychainAccount
        )
        entitlementValidatedAt = validatedAt
        isEntitlementCacheExpired = false
        subscription = value
        scheduleEntitlementExpiry()
    }

    private func invalidateEntitlementCacheIfNeeded(for error: Error, expectedUID: String) {
        guard authService.session?.uid == expectedUID,
              let checkoutError = error as? CheckoutError,
              case .invalidResponse = checkoutError else { return }
        invalidateEntitlementCache()
    }

    private func invalidateEntitlementCache() {
        subscription = nil
        entitlementValidatedAt = nil
        isEntitlementCacheExpired = true
        entitlementExpiryTask?.cancel()
        entitlementExpiryTask = nil
        KeychainStore.remove(service: Self.keychainService, account: Self.keychainAccount)
    }

    static func entitlementExpiryDelay(
        subscription: SubscriptionState?,
        validatedAt: Date,
        now: Date = Date()
    ) -> TimeInterval {
        var remaining = cacheLifetime - now.timeIntervalSince(validatedAt)
        if let subscription,
           let expiration = subscription.grant?.expiresAt.flatMap(SubscriptionState.parseDate),
           !subscription.canonicalProjection(
               emailVerified: true,
               now: expiration
           ).isPro {
            remaining = min(remaining, expiration.timeIntervalSince(now))
        }
        return remaining
    }

    private func scheduleEntitlementExpiry() {
        entitlementExpiryTask?.cancel()
        entitlementExpiryTask = nil
        guard let entitlementValidatedAt else {
            isEntitlementCacheExpired = true
            return
        }
        let now = Date()
        let remaining = Self.entitlementExpiryDelay(
            subscription: subscription,
            validatedAt: entitlementValidatedAt,
            now: now
        )
        guard remaining > 0 else {
            isEntitlementCacheExpired = true
            return
        }
        isEntitlementCacheExpired = false
        let expectedValidationDate = entitlementValidatedAt
        entitlementExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard let self,
                  self.entitlementValidatedAt == expectedValidationDate else { return }
            self.isEntitlementCacheExpired = true
        }
    }
}

/// The recovery endpoint has a dedicated, strict envelope.  In particular,
/// do not decode the legacy `{recovered, subscription}` response here: the
/// explicit `recovery.status` is the server's authoritative outcome.
struct SubscriptionRecoveryResponse: Decodable {
    let value: PortalyCheckoutService.SubscriptionState
    let recoveryStatus: String

    private enum CodingKeys: String, CodingKey {
        case value
        case recovery
    }

    private struct Recovery: Decodable {
        let status: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(
            PortalyCheckoutService.SubscriptionState.self,
            forKey: .value
        )
        let recovery = try container.decode(Recovery.self, forKey: .recovery)
        guard !recovery.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .recovery,
                in: container,
                debugDescription: "Recovery status must not be empty"
            )
        }

        recoveryStatus = recovery.status
    }
}

private struct SubscriptionResponse: Decodable {
    let value: PortalyCheckoutService.SubscriptionState
    let recoveryStatus: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case subscription
        case data
        case recovery
    }

    private struct Recovery: Decodable {
        let status: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let recovery = try? container.decode(Recovery.self, forKey: .recovery) {
            recoveryStatus = recovery.status
        } else {
            recoveryStatus = nil
        }
        if let nested = try? container.decode(
            PortalyCheckoutService.SubscriptionState.self,
            forKey: .value
        ) {
            value = nested
            return
        }
        if let nested = try? container.decode(
            PortalyCheckoutService.SubscriptionState.self,
            forKey: .subscription
        ) {
            value = nested
            return
        }
        if let nested = try? container.decode(
            PortalyCheckoutService.SubscriptionState.self,
            forKey: .data
        ) {
            value = nested
            return
        }
        value = try PortalyCheckoutService.SubscriptionState(from: decoder)
    }
}
