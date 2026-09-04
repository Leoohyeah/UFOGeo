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
                    guidance = "狀態確認後可再試，請勿重複付款。"
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
        case server(String)

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
            case let .server(message):
                return message
            }
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

    private static let checkoutCooldownSeconds: TimeInterval = 30
    private static let checkoutLockPrefix = "ufogeo.checkout-lock."
    private static let subscriptionReconcilePrefix = "ufogeo.subscription-reconcile."
    private static let subscriptionReconcileRetryDelayNanoseconds: UInt64 = 1_000_000_000

    var isCheckoutLocked: Bool {
        guard let uid = authService.session?.uid else { return false }
        let key = Self.checkoutLockPrefix + uid
        let timestamp = UserDefaults.standard.double(forKey: key)
        guard timestamp > 0 else { return false }
        return Date().timeIntervalSince1970 - timestamp < Self.checkoutCooldownSeconds
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
            lastAttemptAt: lastEntitlementRefreshAttemptAt
        )
    }

    var proEntitlementRefreshDelay: TimeInterval {
        Self.entitlementRefreshDelay(
            validatedAt: entitlementValidatedAt,
            lastAttemptAt: lastEntitlementRefreshAttemptAt
        )
    }

    var hasRecentlyValidatedEntitlement: Bool {
        guard let uid = authService.session?.uid,
              subscription?.uid == uid,
              let entitlementValidatedAt else { return false }
        let age = Date().timeIntervalSince(entitlementValidatedAt)
        return age >= 0 && age < Self.entitlementRefreshInterval
    }

    var canUseJoystick: Bool {
        MembershipFeaturePolicy.canUseJoystick(proActive: isPro)
    }

    var canUseBackgroundRouteSimulation: Bool {
        MembershipFeaturePolicy.canRunRoute(inBackground: true, proActive: isPro)
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

    nonisolated private static let cacheLifetime: TimeInterval = 24 * 60 * 60
    nonisolated static let entitlementRefreshInterval: TimeInterval = 15 * 60
    private static let keychainService = "tw.ufogeo.subscription"
    private static let keychainAccount = "verified-state"
    private let authService: FirebaseAuthService
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var needsSubscriptionReconcile = false
    private var reconcileMarkerUID: String?
    private var reconciliationInFlightID: UUID?
    private var foregroundSyncTask: Task<Void, Error>?
    private var foregroundSyncID: UUID?
    private var checkoutReturnUID: String?
    private var subscriptionRefreshTask: Task<SubscriptionState, Error>?
    private var subscriptionRefreshID: UUID?
    private var entitlementValidatedAt: Date?
    private var lastEntitlementRefreshAttemptAt: Date?
    private var entitlementExpiryTask: Task<Void, Never>?
    private var loadingRequestCount = 0

    init(authService: FirebaseAuthService? = nil) {
        let resolvedAuthService = authService ?? FirebaseAuthService.shared
        self.authService = resolvedAuthService
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
        }
        scheduleEntitlementExpiry()
    }

    nonisolated static func cacheIsFresh(cachedAt: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(cachedAt)
        return age >= 0 && age < cacheLifetime
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

    func createCheckoutURL() async throws -> URL {
        guard !isCheckoutRequestInFlight else {
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
        var shouldKeepCheckoutLock = false
        defer {
            isCheckoutRequestInFlight = false
            if !shouldKeepCheckoutLock {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Verification can finish while the app is already open. Always use
        // a freshly minted token for this security-sensitive request.
        _ = try await authService.validIDToken(forceRefresh: true)
        let response: CheckoutResponse = try await authenticatedRequest(
            path: "/api/portaly/checkout",
            method: "POST"
        )
        guard response.checkoutUrl.scheme == "https" else {
            throw CheckoutError.invalidResponse
        }
        shouldKeepCheckoutLock = true
        checkoutReturnUID = uid
        return response.checkoutUrl
    }

    func createPortalURL() async throws -> URL {
        guard !isPortalRequestInFlight else {
            throw CheckoutError.portalRequestInFlight
        }
        isPortalRequestInFlight = true
        defer { isPortalRequestInFlight = false }

        let response: PortalResponse = try await authenticatedRequest(
            path: "/api/portaly/portal",
            method: "POST"
        )
        guard response.portalUrl.scheme == "https" else { throw CheckoutError.invalidResponse }
        setReconcileMarker(true)
        return response.portalUrl
    }

    func deleteMemberAccount() async throws {
        let response: AccountDeletionResponse = try await authenticatedRequest(
            path: "/api/account",
            method: "DELETE"
        )
        guard response.deleted else { throw CheckoutError.invalidResponse }
        clearLocalState()
    }

    @discardableResult
    func refreshSubscription(force: Bool = false) async throws -> SubscriptionState {
        if !force,
           let uid = authService.session?.uid,
           let cache = Self.readCache(),
           cache.value.uid == uid,
           Self.cacheIsFresh(cachedAt: cache.cachedAt) {
            subscription = cache.value
            entitlementValidatedAt = cache.cachedAt
            isEntitlementCacheExpired = false
            scheduleEntitlementExpiry()
            return cache.value
        }

        if let subscriptionRefreshTask {
            return try await subscriptionRefreshTask.value
        }

        guard let expectedUID = authService.session?.uid else {
            throw CheckoutError.server("請先登入 UFOGeo 帳號後再試。")
        }
        lastEntitlementRefreshAttemptAt = Date()
        let refreshID = UUID()
        let task = Task { @MainActor in
            let value: SubscriptionState
            do {
                value = try await authenticatedRequest(
                    path: "/api/portaly/subscription",
                    method: "GET"
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
            return value
        }
        subscriptionRefreshID = refreshID
        subscriptionRefreshTask = task
        defer {
            if subscriptionRefreshID == refreshID {
                subscriptionRefreshTask = nil
                subscriptionRefreshID = nil
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
    func reconcileSubscriptionIfNeeded() async throws -> SubscriptionState? {
        loadReconcileMarkerIfNeeded()
        guard needsSubscriptionReconcile else { return nil }
        guard let reconciliationUID = authService.session?.uid else { return nil }
        guard reconciliationInFlightID == nil else { return nil }

        let operationID = UUID()
        reconciliationInFlightID = operationID
        defer {
            if reconciliationInFlightID == operationID {
                reconciliationInFlightID = nil
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
                  authService.session?.uid == reconciliationUID else {
                throw CancellationError()
            }
            let response: SubscriptionResponse
            do {
                response = try await authenticatedRequest(
                    path: "/api/portaly/subscription/reconcile",
                    method: "POST"
                )
            } catch {
                invalidateEntitlementCacheIfNeeded(for: error, expectedUID: reconciliationUID)
                throw error
            }
            try Task.checkCancellation()
            guard reconciliationInFlightID == operationID,
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

    func synchronizeOnForeground(forceRefresh: Bool = false) async throws {
        if let foregroundSyncTask {
            return try await foregroundSyncTask.value
        }

        loadReconcileMarkerIfNeeded()
        guard let uid = authService.session?.uid else { return }
        let shouldReconcile = needsSubscriptionReconcile
        guard Self.shouldSynchronizeOnForeground(
            subscription: subscription?.uid == uid ? subscription : nil,
            needsReconcile: shouldReconcile,
            needsCheckoutRefresh: forceRefresh || checkoutReturnUID == uid
        ) else { return }

        let operationID = UUID()
        let task = Task { @MainActor in
            if shouldReconcile {
                _ = try await reconcileSubscriptionIfNeeded()
            }
            _ = try await refreshSubscription(force: true)
            guard authService.session?.uid == uid else {
                throw CancellationError()
            }
            if checkoutReturnUID == uid {
                checkoutReturnUID = nil
            }
        }
        foregroundSyncID = operationID
        foregroundSyncTask = task
        defer {
            if foregroundSyncID == operationID {
                foregroundSyncTask = nil
                foregroundSyncID = nil
            }
        }
        try await task.value
    }

    func clearLocalState() {
        let markerUID = authService.session?.uid ?? reconcileMarkerUID
        subscription = nil
        needsSubscriptionReconcile = false
        reconcileMarkerUID = nil
        reconciliationInFlightID = nil
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncID = nil
        checkoutReturnUID = nil
        subscriptionRefreshTask?.cancel()
        subscriptionRefreshTask = nil
        subscriptionRefreshID = nil
        entitlementExpiryTask?.cancel()
        entitlementExpiryTask = nil
        entitlementValidatedAt = nil
        lastEntitlementRefreshAttemptAt = nil
        isEntitlementCacheExpired = true
        if let uid = authService.session?.uid {
            UserDefaults.standard.removeObject(forKey: Self.checkoutLockPrefix + uid)
        }
        if let markerUID {
            UserDefaults.standard.removeObject(forKey: Self.reconcileMarkerKey(for: markerUID))
        }
        KeychainStore.remove(service: Self.keychainService, account: Self.keychainAccount)
    }

    private static func reconcileMarkerKey(for uid: String) -> String {
        subscriptionReconcilePrefix + uid
    }

    private static func readReconcileMarker(for uid: String) -> Bool {
        UserDefaults.standard.bool(forKey: reconcileMarkerKey(for: uid))
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

    private func authenticatedRequest<Response: Decodable>(
        path: String,
        method: String
    ) async throws -> Response {
        loadingRequestCount += 1
        isLoading = true
        defer {
            loadingRequestCount = max(0, loadingRequestCount - 1)
            isLoading = loadingRequestCount > 0
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
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CheckoutError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorResponse = try? decoder.decode(ErrorResponse.self, from: data)
            let message = Self.serverErrorMessage(
                code: errorResponse?.code,
                serverMessage: errorResponse?.error
            )
            throw CheckoutError.server(message)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw CheckoutError.invalidResponse
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

private struct SubscriptionResponse: Decodable {
    let value: PortalyCheckoutService.SubscriptionState

    private enum CodingKeys: String, CodingKey {
        case subscription
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
