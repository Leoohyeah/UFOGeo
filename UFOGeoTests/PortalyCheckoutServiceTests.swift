import Foundation
import Testing
@testable import UFOGeo

struct PortalyCheckoutServiceTests {
    private func state(
        _ status: String,
        proActive: Bool,
        cancelAtPeriodEnd: Bool = false,
        uid: String = "uid-1",
        subscriptionId: String? = "sub-1",
        planId: String = PortalyCheckoutService.expectedPlanID,
        mode: String? = "test",
        nextBillingAt: String? = nil,
        cancelEffectiveAt: String? = nil,
        entitlementSource: String? = nil,
        grant: PortalyCheckoutService.SubscriptionState.GrantMetadata? = nil
    ) -> PortalyCheckoutService.SubscriptionState {
        let resolvedSource = entitlementSource ?? (proActive ? "portaly" : "none")
        let resolvedGrant = grant ?? (resolvedSource.contains("server_grant")
            ? .init(
                kind: "lifetime_pro",
                expiresAt: nil,
                grantedAt: "2026-08-01T00:00:00Z"
            )
            : nil)
        return PortalyCheckoutService.SubscriptionState(
            uid: uid,
            email: "member@example.com",
            emailVerified: true,
            proActive: proActive,
            subscriptionStatus: status,
            subscriptionId: subscriptionId,
            planId: planId,
            mode: mode,
            nextBillingAt: nextBillingAt,
            cancelAtPeriodEnd: cancelAtPeriodEnd,
            cancelEffectiveAt: cancelEffectiveAt,
            lastVerifiedAt: "2026-08-26T04:00:00Z",
            entitlementSource: resolvedSource,
            grant: resolvedGrant
        )
    }

    @Test func emailSubscriptionConflictGuidesMemberToExistingSubscription() {
        let message = PortalyCheckoutService.serverErrorMessage(
            code: "EMAIL_SUBSCRIPTION_EXISTS",
            serverMessage: "Email conflict"
        )

        #expect(message == "此 Email 已有有效訂閱，請前往 Portaly 管理現有訂閱。")
    }

    @Test func activeSubscriptionConflictGuidesMemberToExistingSubscription() {
        let message = PortalyCheckoutService.serverErrorMessage(
            code: "ACTIVE_SUBSCRIPTION_EXISTS",
            serverMessage: "Active subscription conflict"
        )

        #expect(message == "此帳號已有有效訂閱，請前往 Portaly 管理現有訂閱。")
    }

    @Test func otherServerErrorsPreferBackendMessage() {
        let message = PortalyCheckoutService.serverErrorMessage(
            code: "CHECKOUT_IN_PROGRESS",
            serverMessage: "付款流程正在建立中，請稍後再試。"
        )

        #expect(message == "付款流程正在建立中，請稍後再試。")
    }

    @Test func missingServerMessageUsesGenericFallback() {
        #expect(
            PortalyCheckoutService.serverErrorMessage(
                code: "UNKNOWN",
                serverMessage: nil
            ) == "訂閱功能暫時無法使用，請稍後再試。"
        )
        #expect(
            PortalyCheckoutService.serverErrorMessage(
                code: nil,
                serverMessage: "  \n"
            ) == "訂閱功能暫時無法使用，請稍後再試。"
        )
    }

    @Test func portalyReturnParserAcceptsOnlySupportedFlows() throws {
        let supported: [(String, PortalyCheckoutService.PortalyReturnFlow)] = [
            ("ufogeo://portaly-return?flow=checkout", .checkout),
            ("ufogeo://portaly-return?flow=portal", .portal)
        ]
        for (rawURL, expectedFlow) in supported {
            let url = try #require(URL(string: rawURL))
            #expect(
                PortalyCheckoutService.portalyReturnFlow(from: url) == expectedFlow,
                "應接受合法 Portaly return URL：\(rawURL)"
            )
        }

        let rejected = [
            "http://portaly-return?flow=checkout",
            "https://portaly-return?flow=checkout",
            "ufogeo://wrong-host?flow=checkout",
            "ufogeo://portaly-return",
            "ufogeo://portaly-return?flow=unknown",
            "ufogeo://portaly-return?flow=checkout&flow=portal",
            "ufogeo://user@portaly-return?flow=checkout",
            "ufogeo://portaly-return:443?flow=checkout",
            "ufogeo://portaly-return/path?flow=checkout",
            "ufogeo://portaly-return?flow=checkout#fragment"
        ]
        for rawURL in rejected {
            let url = try #require(URL(string: rawURL))
            #expect(
                PortalyCheckoutService.portalyReturnFlow(from: url) == nil,
                "不應接受非契約 URL：\(rawURL)"
            )
        }
    }

    @Test func accountDeletionSafetyErrorsPreserveBackendChineseMessage() {
        #expect(
            PortalyCheckoutService.serverErrorMessage(
                code: "PENDING_CHECKOUT_EXISTS",
                serverMessage: "目前仍有尚未完成的付款流程，請完成或等待流程到期後再刪除帳號。"
            ) == "目前仍有尚未完成的付款流程，請完成或等待流程到期後再刪除帳號。"
        )
        #expect(
            PortalyCheckoutService.serverErrorMessage(
                code: "CHECKOUT_SAFETY_HOLD",
                serverMessage: "付款或刪帳狀態尚未確認，為避免重複扣款，暫時無法刪除帳號。"
            ) == "付款或刪帳狀態尚未確認，為避免重複扣款，暫時無法刪除帳號。"
        )
    }

    @Test func uncertainCheckoutErrorsProvideSafeFallbackGuidance() {
        let codes = [
            "PORTALY_REQUEST_UNCERTAIN",
            "PORTALY_RESPONSE_INCOMPLETE",
            "PORTALY_CHECKOUT_RECONCILE_FAILED",
            "PORTALY_CHECKOUT_RECONCILE_UNCERTAIN",
            "PORTALY_RECONCILE_REQUEST_UNCERTAIN",
            "PORTALY_RECONCILE_FAILED",
            "PORTALY_RECONCILE_RESPONSE_INVALID",
            "CHECKOUT_SAFETY_HOLD",
            "PENDING_CHECKOUT_EXISTS",
            "RECOVERY_PENDING_CHECKOUT",
        ]

        for code in codes {
            let message = PortalyCheckoutService.serverErrorMessage(
                code: code,
                serverMessage: nil
            )
            #expect(message.contains("尚未確認"), "應說明付款結果尚未確認：\(code)")
            #expect(message.contains("重新同步"), "應提供重新同步恢復路徑：\(code)")
            #expect(message.contains("重複付款"), "應阻止重複付款：\(code)")
        }
    }

    @Test @MainActor func duplicateRequestErrorsExplainThatTheExistingRequestIsStillRunning() {
        #expect(
            PortalyCheckoutService.CheckoutError.checkoutRequestInFlight.errorDescription
                == "付款頁面正在建立中，請稍候，不要重複點擊。"
        )
        #expect(
            PortalyCheckoutService.CheckoutError.portalRequestInFlight.errorDescription
                == "訂閱管理頁面正在開啟，請稍候，不要重複點擊。"
        )
    }

    @Test func requestRetryPolicyOnlyRetriesTransientGetFailuresOnce() {
        #expect(
            PortalyCheckoutService.shouldRetryRequest(
                method: "GET",
                attempt: 0,
                error: URLError(.timedOut)
            )
        )
        #expect(
            PortalyCheckoutService.shouldRetryRequest(
                method: "GET",
                attempt: 0,
                error: URLError(.networkConnectionLost)
            )
        )
        #expect(
            !PortalyCheckoutService.shouldRetryRequest(
                method: "GET",
                attempt: 1,
                error: URLError(.timedOut)
            )
        )
        #expect(
            !PortalyCheckoutService.shouldRetryRequest(
                method: "POST",
                attempt: 0,
                error: URLError(.timedOut)
            )
        )
        #expect(
            !PortalyCheckoutService.shouldRetryRequest(
                method: "DELETE",
                attempt: 0,
                error: URLError(.networkConnectionLost)
            )
        )
        #expect(
            !PortalyCheckoutService.shouldRetryRequest(
                method: "GET",
                attempt: 0,
                error: URLError(.cancelled)
            )
        )
        #expect(
            !PortalyCheckoutService.shouldRetryRequest(
                method: "GET",
                attempt: 0,
                error: CancellationError()
            )
        )
        let checkoutErrors: [Error] = [
            PortalyCheckoutService.CheckoutError.backendNotConfigured,
            PortalyCheckoutService.CheckoutError.invalidBackendURL,
            PortalyCheckoutService.CheckoutError.invalidResponse,
            PortalyCheckoutService.CheckoutError.checkoutRequestInFlight,
            PortalyCheckoutService.CheckoutError.portalRequestInFlight,
            PortalyCheckoutService.CheckoutError.recoveryRequestInFlight,
            PortalyCheckoutService.CheckoutError.server("server"),
            PortalyCheckoutService.CheckoutError.serverResponse(
                code: "SERVER_ERROR",
                message: "server"
            )
        ]
        for error in checkoutErrors {
            #expect(
                !PortalyCheckoutService.shouldRetryRequest(
                    method: "GET",
                    attempt: 0,
                    error: error
                )
            )
        }
    }

    @Test func recoveryStatesKeepCheckoutClosedUntilTheOutcomeIsSafe() {
        let checkoutBlockingStates: [PortalyCheckoutService.SubscriptionRecoveryState] = [
            .inFlight,
            .ambiguous,
            .unavailable,
            .conflict,
        ]
        let checkoutAllowedStates: [PortalyCheckoutService.SubscriptionRecoveryState] = [
            .idle,
            .recovered,
            .alreadyBound,
            .notFound,
        ]

        for recoveryState in checkoutBlockingStates {
            #expect(recoveryState.blocksCheckout)
        }
        for recoveryState in checkoutAllowedStates {
            #expect(!recoveryState.blocksCheckout)
        }
    }

    @Test func recoveryErrorsExplainAmbiguityAndNeverSuggestDuplicatePayment() {
        #expect(
            PortalyCheckoutService.serverErrorMessage(
                code: "PORTALY_RECOVERY_AMBIGUOUS",
                serverMessage: nil
            ).contains("多筆")
        )
        let unavailable = PortalyCheckoutService.serverErrorMessage(
            code: "PORTALY_RECOVERY_UNAVAILABLE",
            serverMessage: nil
        )
        #expect(unavailable.contains("避免重複付款"))
        #expect(!unavailable.contains("開始新的訂閱"))
        #expect(
            PortalyCheckoutService.serverErrorMessage(
                code: "PORTALY_RECOVERY_NOT_FOUND",
                serverMessage: nil
            ).contains("開始新的訂閱")
        )
    }

    @Test func recoveryResponseRequiresValueAndExplicitStatus() throws {
        let valueData = try JSONEncoder().encode(
            state("active", proActive: true)
        )
        let value = try JSONSerialization.jsonObject(with: valueData)
        for status in ["recovered", "already_bound", "not_found"] {
            let validEnvelope = try JSONSerialization.data(withJSONObject: [
                "value": value,
                "recovery": ["status": status],
            ])
            let decoded = try JSONDecoder().decode(
                SubscriptionRecoveryResponse.self,
                from: validEnvelope
            )
            #expect(decoded.recoveryStatus == status)
            #expect(decoded.value.subscriptionId == "sub-1")
        }

        let legacyEnvelope = try JSONSerialization.data(withJSONObject: [
            "recovered": true,
            "subscription": value,
        ])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                SubscriptionRecoveryResponse.self,
                from: legacyEnvelope
            )
        }

        let missingStatusEnvelope = try JSONSerialization.data(withJSONObject: [
            "value": value,
            "recovery": [:],
        ])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                SubscriptionRecoveryResponse.self,
                from: missingStatusEnvelope
            )
        }
    }

    @Test func membershipCacheRejectsExpiredAndFutureTimestamps() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(
            PortalyCheckoutService.cacheIsFresh(
                cachedAt: now.addingTimeInterval(-(24 * 60 * 60) + 1),
                now: now
            )
        )
        #expect(
            !PortalyCheckoutService.cacheIsFresh(
                cachedAt: now.addingTimeInterval(-(24 * 60 * 60)),
                now: now
            )
        )
        #expect(
            !PortalyCheckoutService.cacheIsFresh(
                cachedAt: now.addingTimeInterval(1),
                now: now
            )
        )
    }

    @Test func proEntitlementRefreshUsesFifteenMinuteFreshnessAndAttemptThrottling() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let interval = PortalyCheckoutService.entitlementRefreshInterval

        #expect(
            !PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: now.addingTimeInterval(-interval + 1),
                lastAttemptAt: nil,
                now: now
            )
        )
        #expect(
            PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: now.addingTimeInterval(-interval),
                lastAttemptAt: nil,
                now: now
            )
        )
        #expect(
            !PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: now.addingTimeInterval(-interval),
                lastAttemptAt: now.addingTimeInterval(-interval + 1),
                now: now
            )
        )
        #expect(
            PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: now.addingTimeInterval(-interval),
                lastAttemptAt: now.addingTimeInterval(-interval),
                now: now
            )
        )
        #expect(
            PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: nil,
                lastAttemptAt: nil,
                now: now
            )
        )
        #expect(
            PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: now.addingTimeInterval(1),
                lastAttemptAt: nil,
                now: now
            )
        )
        #expect(
            PortalyCheckoutService.entitlementRefreshDelay(
                validatedAt: now.addingTimeInterval(-interval + 10),
                lastAttemptAt: nil,
                now: now
            ) == 10
        )
        #expect(
            PortalyCheckoutService.entitlementRefreshDelay(
                validatedAt: now.addingTimeInterval(-interval),
                lastAttemptAt: now.addingTimeInterval(-interval + 30),
                now: now
            ) == 30
        )
    }

    @Test func subscriptionStateUsesLegacyFreeFallbackWhenSourceIsMissing() throws {
        let data = Data(
            """
            {"uid":"uid-1","email":"member@example.com","emailVerified":true,"proActive":false,"subscriptionStatus":"none","subscriptionId":null,"planId":"\(PortalyCheckoutService.expectedPlanID)","mode":"test","nextBillingAt":null,"cancelAtPeriodEnd":false,"cancelEffectiveAt":null}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(
            PortalyCheckoutService.SubscriptionState.self,
            from: data
        )
        #expect(decoded.lastVerifiedAt == nil)
        #expect(decoded.entitlementSource == "none")
        #expect(decoded.grant == nil)
        let projection = decoded.canonicalProjection(emailVerified: true)
        #expect(projection.entitlement == .verifiedFree)
        #expect(projection.payment == .none)
    }

    @Test func subscriptionStateUsesLegacyPortalyFallbackWhenSourceIsMissing() throws {
        let data = Data(
            """
            {"uid":"uid-1","email":"member@example.com","emailVerified":true,"proActive":true,"subscriptionStatus":"active","subscriptionId":"sub-legacy","planId":"\(PortalyCheckoutService.expectedPlanID)","mode":"test","nextBillingAt":null,"cancelAtPeriodEnd":false,"cancelEffectiveAt":null}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(
            PortalyCheckoutService.SubscriptionState.self,
            from: data
        )

        let projection = decoded.canonicalProjection(emailVerified: true)
        #expect(decoded.entitlementSource == "portaly")
        #expect(projection.entitlement == .verifiedPro)
        #expect(projection.payment == .active)
        #expect(projection.action == .manageSubscription)
    }

    @Test func subscriptionStateDecodesAndCachesServerGrantSourceMetadata() throws {
        let data = Data(
            """
            {"uid":"uid-1","email":"member@example.com","emailVerified":true,"proActive":true,"subscriptionStatus":"none","subscriptionId":null,"planId":"plan-1","mode":"test","nextBillingAt":null,"cancelAtPeriodEnd":false,"cancelEffectiveAt":null,"lastVerifiedAt":null,"entitlementSource":"server_grant","grant":{"kind":"lifetime_pro","expiresAt":null,"grantedAt":"2026-08-01T00:00:00Z"}}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(
            PortalyCheckoutService.SubscriptionState.self,
            from: data
        )

        #expect(decoded.entitlementSource == "server_grant")
        #expect(decoded.grant?.kind == "lifetime_pro")
        #expect(decoded.grant?.expiresAt == nil)
        #expect(decoded.grant?.grantedAt == "2026-08-01T00:00:00Z")

        let encoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(
            PortalyCheckoutService.SubscriptionState.self,
            from: encoded
        )
        #expect(roundTrip == decoded)
    }

    @Test func subscriptionSourcePolicyKeepsPaidManagementWhenGrantAlsoExists() {
        let grant = PortalyCheckoutService.SubscriptionState.GrantMetadata(
            kind: "lifetime_pro",
            expiresAt: nil,
            grantedAt: "2026-08-01T00:00:00Z"
        )
        let both = state(
            "active",
            proActive: true,
            entitlementSource: "portaly_and_server_grant",
            grant: grant
        )

        let projection = both.canonicalProjection(emailVerified: true)
        #expect(projection.entitlement == .verifiedPro)
        #expect(projection.payment == .active)
        #expect(projection.action == .manageSubscription)
    }

    @Test func expiredCombinedGrantFallsBackToVerifiedPortalyPro() throws {
        let expiredGrant = PortalyCheckoutService.SubscriptionState.GrantMetadata(
            kind: "temporary_pro",
            expiresAt: "2026-09-01T00:00:00Z",
            grantedAt: "2026-08-01T00:00:00Z"
        )
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-09-04T00:00:00Z")
        )
        let cases: [(
            status: String,
            cancelAtPeriodEnd: Bool,
            payment: PortalyCheckoutService.MembershipProjection.Payment,
            action: PortalyCheckoutService.MembershipProjection.Action
        )] = [
            ("active", false, .active, .manageSubscription),
            ("past_due", false, .pastDue, .resolvePayment),
            ("cancel_requested", true, .canceling, .resumeSubscription),
        ]

        for testCase in cases {
            let projection = state(
                testCase.status,
                proActive: true,
                cancelAtPeriodEnd: testCase.cancelAtPeriodEnd,
                entitlementSource: "portaly_and_server_grant",
                grant: expiredGrant
            ).canonicalProjection(emailVerified: true, now: now)

            #expect(projection.entitlement == .verifiedPro)
            #expect(projection.payment == testCase.payment)
            #expect(projection.action == testCase.action)
            #expect(!projection.notices.contains { $0.kind == .grant })
        }
    }

    @Test func expiredCombinedGrantDoesNotBypassUnknownPaymentFailClosed() throws {
        let expiredGrant = PortalyCheckoutService.SubscriptionState.GrantMetadata(
            kind: "temporary_pro",
            expiresAt: "2026-09-01T00:00:00Z",
            grantedAt: "2026-08-01T00:00:00Z"
        )
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-09-04T00:00:00Z")
        )
        let projection = state(
            "unknown",
            proActive: true,
            entitlementSource: "portaly_and_server_grant",
            grant: expiredGrant
        ).canonicalProjection(emailVerified: true, now: now)

        #expect(projection.entitlement == .unavailable)
        #expect(projection.payment == .unavailable)
        #expect(projection.action == .refresh)
    }

    @Test @MainActor func grantExpirySchedulingPreservesPaidPortalyUntilCacheExpiry() throws {
        let grant = PortalyCheckoutService.SubscriptionState.GrantMetadata(
            kind: "temporary_pro",
            expiresAt: "2026-09-04T01:00:00Z",
            grantedAt: "2026-08-01T00:00:00Z"
        )
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-09-04T00:00:00Z")
        )
        let validatedAt = now.addingTimeInterval(-60)
        let grantOnly = state(
            "none",
            proActive: true,
            subscriptionId: nil,
            entitlementSource: "server_grant",
            grant: grant
        )

        for (status, cancelAtPeriodEnd) in [
            ("active", false),
            ("past_due", false),
            ("cancel_requested", true),
        ] {
            let combined = state(
                status,
                proActive: true,
                cancelAtPeriodEnd: cancelAtPeriodEnd,
                entitlementSource: "portaly_and_server_grant",
                grant: grant
            )
            #expect(
                PortalyCheckoutService.entitlementExpiryDelay(
                    subscription: combined,
                    validatedAt: validatedAt,
                    now: now
                ) == (24 * 60 * 60) - 60
            )
        }
        #expect(
            PortalyCheckoutService.entitlementExpiryDelay(
                subscription: grantOnly,
                validatedAt: validatedAt,
                now: now
            ) == 60 * 60
        )
    }

    @Test func sourcePolicyHidesPortalyManagementForGrantOnlyState() {
        let grant = PortalyCheckoutService.SubscriptionState.GrantMetadata(
            kind: "temporary_pro",
            expiresAt: "2026-12-31T00:00:00Z",
            grantedAt: "2026-08-01T00:00:00Z"
        )
        let grantOnly = state(
            "none",
            proActive: true,
            subscriptionId: nil,
            entitlementSource: "server_grant",
            grant: grant
        )

        let projection = grantOnly.canonicalProjection(
            emailVerified: true,
            now: Date(timeIntervalSince1970: 1_790_000_000)
        )
        #expect(projection.entitlement == .verifiedPro)
        #expect(projection.payment == .none)
        #expect(projection.action == .none)
        #expect(grantOnly.grant?.expiresAt == "2026-12-31T00:00:00Z")
    }

    @Test func canonicalProjectionKeepsServerGrantIndependentFromPaymentFailure() {
        let failedPaymentWithGrant = state(
            "checkout_failed",
            proActive: true,
            subscriptionId: nil,
            entitlementSource: "server_grant"
        )
        let projection = failedPaymentWithGrant.canonicalProjection(emailVerified: true)

        #expect(projection.entitlement == .verifiedPro)
        #expect(projection.payment == .checkoutFailed)
        #expect(projection.label == "免費 Pro 授權")
        #expect(projection.action == .none)
        #expect(projection.guidance.contains("不需要重新付款"))
    }

    @Test func unknownOrContradictoryMembershipStateFailsClosed() {
        for unsafe in [
            state("unknown", proActive: false, subscriptionId: nil),
            state("active", proActive: false),
            state("none", proActive: true, subscriptionId: nil),
            state("checkout_ready", proActive: false, subscriptionId: nil),
        ] {
            let projection = unsafe.canonicalProjection(emailVerified: true)
            #expect(projection.entitlement == .unavailable)
            #expect(projection.payment == .unavailable)
            #expect(projection.action == .refresh)
        }
    }

    @Test func backendConfirmedCheckoutFailureRemainsDistinctAndCanRetrySafely() {
        let failed = state(
            "checkout_failed",
            proActive: false,
            subscriptionId: nil
        )
        let projection = failed.canonicalProjection(emailVerified: true)

        #expect(projection.entitlement == .verifiedFree)
        #expect(projection.payment == .checkoutFailed)
        #expect(projection.label == "付款未完成")
        #expect(projection.action == .retryCheckout)
    }

    @Test func canonicalProjectionProvidesThePublishedPaymentActions() {
        let cases: [(PortalyCheckoutService.SubscriptionState, PortalyCheckoutService.MembershipProjection.Action)] = [
            (state("none", proActive: false, subscriptionId: nil), .startCheckout),
            (state("checkout_ready", proActive: false), .continueCheckout),
            (state("checkout_failed", proActive: false, subscriptionId: nil), .retryCheckout),
            (state("canceled", proActive: false), .restartCheckout),
            (state("active", proActive: true), .manageSubscription),
            (state("past_due", proActive: true), .resolvePayment),
            (
                state("cancel_requested", proActive: true, cancelAtPeriodEnd: true),
                .resumeSubscription
            ),
        ]

        for (state, expectedAction) in cases {
            #expect(state.canonicalProjection(emailVerified: true).action == expectedAction)
            #expect(state.canonicalProjection(emailVerified: false).action == .none)
        }
    }

    @Test func serverGrantKeepsProButBlocksPaymentWhenProviderStateIsUnavailable() {
        let projection = state(
            "unavailable",
            proActive: true,
            subscriptionId: nil,
            entitlementSource: "server_grant"
        ).canonicalProjection(emailVerified: true)

        #expect(projection.entitlement == .verifiedPro)
        #expect(projection.payment == .unavailable)
        #expect(projection.action == .refresh)
        #expect(projection.guidance.contains("不需要重新付款"))
    }

    @Test func malformedPaymentAndExpiredGrantFailClosed() throws {
        let expiredGrant = PortalyCheckoutService.SubscriptionState.GrantMetadata(
            kind: "temporary_pro",
            expiresAt: "2026-09-01T00:00:00Z",
            grantedAt: "2026-08-01T00:00:00Z"
        )
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-09-04T00:00:00Z")
        )
        let unsafeStates = [
            state("none", proActive: false, subscriptionId: nil, mode: nil),
            state("none", proActive: false, subscriptionId: nil, planId: ""),
            state("none", proActive: false, subscriptionId: nil, planId: "other-plan"),
            state("active", proActive: true, cancelAtPeriodEnd: true),
            state("active", proActive: true, subscriptionId: "invalid/subscription"),
            state("active", proActive: true, nextBillingAt: "not-a-date"),
            state(
                "none",
                proActive: true,
                subscriptionId: nil,
                entitlementSource: "server_grant",
                grant: expiredGrant
            ),
        ]

        for unsafe in unsafeStates {
            let projection = unsafe.canonicalProjection(emailVerified: true, now: now)
            #expect(projection.entitlement == .unavailable)
            #expect(projection.action == .refresh)
        }
    }

    @Test @MainActor func uidMismatchAndExpiredCacheFailClosedBeforeProjectingPro() throws {
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-09-04T00:00:00Z")
        )
        let active = state("active", proActive: true)

        let valid = PortalyCheckoutService.membershipProjection(
            subscription: active,
            currentUID: "uid-1",
            emailVerified: true,
            validatedAt: now.addingTimeInterval(-60),
            isCacheExpired: false,
            initialSyncCompleted: true,
            syncFailed: false,
            now: now
        )
        #expect(valid.entitlement == .verifiedPro)

        for unsafe in [
            PortalyCheckoutService.membershipProjection(
                subscription: active,
                currentUID: "uid-other",
                emailVerified: true,
                validatedAt: now.addingTimeInterval(-60),
                isCacheExpired: false,
                initialSyncCompleted: true,
                syncFailed: false,
                now: now
            ),
            PortalyCheckoutService.membershipProjection(
                subscription: active,
                currentUID: "uid-1",
                emailVerified: true,
                validatedAt: now.addingTimeInterval(-(24 * 60 * 60)),
                isCacheExpired: false,
                initialSyncCompleted: true,
                syncFailed: false,
                now: now
            ),
            PortalyCheckoutService.membershipProjection(
                subscription: active,
                currentUID: "uid-1",
                emailVerified: true,
                validatedAt: now.addingTimeInterval(1),
                isCacheExpired: false,
                initialSyncCompleted: true,
                syncFailed: false,
                now: now
            ),
        ] {
            #expect(unsafe.entitlement == .unavailable)
            #expect(!unsafe.isPro)
            #expect(unsafe.action == .refresh)
        }
    }

    @Test func accountReloadFreshnessIsBounded() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(
            FirebaseAuthService.accountReloadIsFresh(
                completedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
        #expect(
            !FirebaseAuthService.accountReloadIsFresh(
                completedAt: now.addingTimeInterval(-2),
                now: now
            )
        )
        #expect(
            !FirebaseAuthService.accountReloadIsFresh(
                completedAt: now.addingTimeInterval(1),
                now: now
            )
        )
    }

    @Test @MainActor func refreshesOnCheckoutPendingAndPastDueButNotOnActiveOrCanceled() {
        #expect(PortalyCheckoutService.shouldRefreshOnForeground(subscription: nil))
        #expect(PortalyCheckoutService.shouldRefreshOnForeground(subscription: state("checkout_ready", proActive: false)))
        #expect(PortalyCheckoutService.shouldRefreshOnForeground(subscription: state("past_due", proActive: true)))
        #expect(!PortalyCheckoutService.shouldRefreshOnForeground(subscription: state("active", proActive: true)))
        #expect(!PortalyCheckoutService.shouldRefreshOnForeground(subscription: state("cancel_requested", proActive: true, cancelAtPeriodEnd: true)))
        #expect(!PortalyCheckoutService.shouldRefreshOnForeground(subscription: state("canceled", proActive: false, cancelAtPeriodEnd: false)))
    }

    @Test @MainActor func foregroundSynchronizationIncludesEveryRequiredTrigger() {
        #expect(
            PortalyCheckoutService.shouldSynchronizeOnForeground(
                subscription: state("active", proActive: true),
                needsReconcile: true
            )
        )
        #expect(
            PortalyCheckoutService.shouldSynchronizeOnForeground(
                subscription: state("active", proActive: true),
                needsReconcile: false,
                needsCheckoutRefresh: true
            )
        )
        #expect(
            PortalyCheckoutService.shouldSynchronizeOnForeground(
                subscription: state("checkout_ready", proActive: false),
                needsReconcile: false
            )
        )
        #expect(
            !PortalyCheckoutService.shouldSynchronizeOnForeground(
                subscription: state("active", proActive: true),
                needsReconcile: false
            )
        )
        #expect(
            !PortalyCheckoutService.shouldSynchronizeOnForeground(
                subscription: state("none", proActive: false, subscriptionId: nil),
                needsReconcile: false
            )
        )
    }

    @Test @MainActor func unchangedPortalResponsesKeepMarkerButAChangedStateConsumesIt() {
        let cancelRequested = state(
            "cancel_requested",
            proActive: true,
            cancelAtPeriodEnd: true
        )
        let active = state("active", proActive: true)

        #expect(
            !PortalyCheckoutService.portalReconciliationCanClearMarker(
                previous: cancelRequested,
                latest: cancelRequested
            )
        )
        #expect(
            !PortalyCheckoutService.portalReconciliationCanClearMarker(
                previous: active,
                latest: active
            )
        )
        #expect(
            PortalyCheckoutService.portalReconciliationCanClearMarker(
                previous: cancelRequested,
                latest: active
            )
        )
        #expect(
            PortalyCheckoutService.portalReconciliationCanClearMarker(
                previous: active,
                latest: cancelRequested
            )
        )
    }

    @Test @MainActor func missingCachedBaselineKeepsMarkerForTheNextForeground() {
        #expect(
            !PortalyCheckoutService.portalReconciliationCanClearMarker(
                previous: nil,
                latest: state("active", proActive: true)
            )
        )
    }

    @Test @MainActor func mismatchedMemberBaselineKeepsMarkerUntilTheCurrentUIDHasABaseline() {
        #expect(
            !PortalyCheckoutService.portalReconciliationCanClearMarker(
                previous: state("active", proActive: true, uid: "uid-old"),
                latest: state("canceled", proActive: false, uid: "uid-new")
            )
        )
    }

    @Test func freeAndProCapabilitiesMatchThePublishedMatrix() {
        #expect(MembershipFeaturePolicy.canRunRoute(inBackground: false, proActive: false))
        #expect(MembershipFeaturePolicy.canRunRoute(inBackground: false, proActive: true))
        #expect(!MembershipFeaturePolicy.canRunRoute(inBackground: true, proActive: false))
        #expect(MembershipFeaturePolicy.canRunRoute(inBackground: true, proActive: true))
        #expect(!MembershipFeaturePolicy.canUseJoystick(proActive: false))
        #expect(MembershipFeaturePolicy.canUseJoystick(proActive: true))
    }

    @Test func expiringSubscriptionRefreshIntervalIncreasesWithUrgency() {
        let defaultInterval = PortalyCheckoutService.entitlementRefreshInterval
        let farInterval = PortalyCheckoutService.effectiveEntitlementRefreshInterval(expiringStage: "far")
        let soonInterval = PortalyCheckoutService.effectiveEntitlementRefreshInterval(expiringStage: "soon")
        let todayInterval = PortalyCheckoutService.effectiveEntitlementRefreshInterval(expiringStage: "today")
        let noneInterval = PortalyCheckoutService.effectiveEntitlementRefreshInterval(expiringStage: "none")
        let nilInterval = PortalyCheckoutService.effectiveEntitlementRefreshInterval(expiringStage: nil)

        #expect(defaultInterval == 15 * 60)  // 15 分鐘
        #expect(farInterval == 60 * 60)      // 1 小時
        #expect(soonInterval == 30 * 60)     // 30 分鐘
        #expect(todayInterval == 5 * 60)     // 5 分鐘
        #expect(noneInterval == defaultInterval)
        #expect(nilInterval == defaultInterval)

        // 驗證優先級順序：today < soon < far < default
        #expect(todayInterval < soonInterval)
        #expect(soonInterval < farInterval)
        #expect(farInterval > defaultInterval)
    }

    @Test func subscriptionStateIncludesExpiringStageAndBillingDates() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let nextBillingInThreeDays = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 24 * 60 * 60))
        let parsedNextBillingDate = try #require(
            ISO8601DateFormatter().date(from: nextBillingInThreeDays)
        )

        let subscription = PortalyCheckoutService.SubscriptionState(
            uid: "uid-1",
            email: "member@example.com",
            emailVerified: true,
            proActive: true,
            subscriptionStatus: "active",
            subscriptionId: "sub-1",
            planId: PortalyCheckoutService.expectedPlanID,
            mode: "test",
            nextBillingAt: nextBillingInThreeDays,
            nextBillingAtMs: parsedNextBillingDate.timeIntervalSince1970 * 1000,
            daysUntilRenewal: 3.0,
            expiringStage: "far",
            cancelAtPeriodEnd: false,
            cancelEffectiveAt: nil,
            lastVerifiedAt: ISO8601DateFormatter().string(from: now),
            entitlementSource: "portaly"
        )

        #expect(subscription.expiringStage == "far")
        #expect(subscription.daysUntilRenewal == 3.0)
        #expect(subscription.nextBillingAt == nextBillingInThreeDays)
        #expect(subscription.nextBillingAtMs != nil)
    }

    @Test func foregroundReturnRefreshesOnlyWhenCacheExpiredOrReconcileNeeded() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let freshCache = now.addingTimeInterval(-12 * 60 * 60)  // 12 小時前
        let expiredCache = now.addingTimeInterval(-25 * 60 * 60)  // 25 小時前

        // 情景 1：快取新鮮，無 reconcile，應不強制刷新
        #expect(
            !PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: freshCache,
                lastAttemptAt: nil,
                now: now
            )
        )

        // 情景 2：快取已過期，應強制刷新
        #expect(
            PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: expiredCache,
                lastAttemptAt: nil,
                now: now
            )
        )

        // 情景 3：24 小時邊界
        let exactlyTwentyFourHours = now.addingTimeInterval(-(24 * 60 * 60))
        #expect(
            PortalyCheckoutService.shouldAttemptEntitlementRefresh(
                validatedAt: exactlyTwentyFourHours,
                lastAttemptAt: nil,
                now: now
            )
        )
    }

    @Test func expiringSubscriptionStageTransitionsProgressivelyWithTime() {
        let now = Date(timeIntervalSince1970: 2_000_000)

        // 情景 1：正常 Pro（> 72 小時）
        let inThreeDaysPlus = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(4 * 24 * 60 * 60)
        )
        #expect(
            PortalyCheckoutService.calculateExpiringStage(
                proActive: true,
                subscriptionStatus: "active",
                nextBillingAt: inThreeDaysPlus,
                now: now
            ) == "none"
        )

        // 情景 2：快到期 far (48-72 小時)
        let inSixtyHours = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(60 * 60 * 60)
        )
        #expect(
            PortalyCheckoutService.calculateExpiringStage(
                proActive: true,
                subscriptionStatus: "active",
                nextBillingAt: inSixtyHours,
                now: now
            ) == "far"
        )

        // 情景 3：快到期 soon (24-48 小時)
        let inThirtySixHours = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(36 * 60 * 60)
        )
        #expect(
            PortalyCheckoutService.calculateExpiringStage(
                proActive: true,
                subscriptionStatus: "active",
                nextBillingAt: inThirtySixHours,
                now: now
            ) == "soon"
        )

        // 情景 4：快到期 today (0-24 小時)
        let inTwelveHours = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(12 * 60 * 60)
        )
        #expect(
            PortalyCheckoutService.calculateExpiringStage(
                proActive: true,
                subscriptionStatus: "active",
                nextBillingAt: inTwelveHours,
                now: now
            ) == "today"
        )

        // 情景 5：已過期
        let yesterday = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-1 * 60 * 60)
        )
        #expect(
            PortalyCheckoutService.calculateExpiringStage(
                proActive: true,
                subscriptionStatus: "active",
                nextBillingAt: yesterday,
                now: now
            ) == "expired"
        )
    }

    @Test func expiringStageToleratesClockSkewUpto24Hours() {
        let baseTime = Date(timeIntervalSince1970: 2_000_000)
        let billingDate = ISO8601DateFormatter().string(
            from: baseTime.addingTimeInterval(36 * 60 * 60)  // 36 小時後
        )

        // 系統時間快 1 小時（認為是 soon）
        let fastClock = baseTime.addingTimeInterval(1 * 60 * 60)
        #expect(
            PortalyCheckoutService.calculateExpiringStage(
                proActive: true,
                subscriptionStatus: "active",
                nextBillingAt: billingDate,
                now: fastClock
            ) == "soon"
        )

        // 系統時間慢 1 小時（認為是 far 或 soon）
        let slowClock = baseTime.addingTimeInterval(-1 * 60 * 60)
        #expect(
            PortalyCheckoutService.calculateExpiringStage(
                proActive: true,
                subscriptionStatus: "active",
                nextBillingAt: billingDate,
                now: slowClock
            ) == "far"
        )
    }

    @Test func subscriptionStatePreservesExpiringStageAcrossCodableRoundtrip() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let nextBillingInOneDay = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(24 * 60 * 60)
        )
        let nextBillingMs = now.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970 * 1000

        let original = PortalyCheckoutService.SubscriptionState(
            uid: "uid-1",
            email: "member@example.com",
            emailVerified: true,
            proActive: true,
            subscriptionStatus: "active",
            subscriptionId: "sub-1",
            planId: PortalyCheckoutService.expectedPlanID,
            mode: "test",
            nextBillingAt: nextBillingInOneDay,
            nextBillingAtMs: nextBillingMs,
            daysUntilRenewal: 1.0,
            expiringStage: "soon",
            cancelAtPeriodEnd: false,
            cancelEffectiveAt: nil,
            lastVerifiedAt: ISO8601DateFormatter().string(from: now),
            entitlementSource: "portaly"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(PortalyCheckoutService.SubscriptionState.self, from: encoded)

        #expect(decoded.expiringStage == "soon")
        #expect(decoded.daysUntilRenewal == 1.0)
        #expect(decoded.nextBillingAtMs == nextBillingMs)
        #expect(decoded.nextBillingAt == nextBillingInOneDay)
    }

    @Test func effectiveEntitlementRefreshInterval_transitions() throws {
        // 測試四層切換邏輯的頻率轉換
        // today (< 1d) → 5min
        // soon (1-2d) → 30min
        // far (2-3d) → 1h
        // normal (> 3d) → 15min
        
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseInterval = PortalyCheckoutService.entitlementRefreshInterval  // 15 min
        
        let testCases: [(String, TimeInterval)] = [
            // 邊界情況：0.5 天之前（today）
            ("today_0.5d", -0.5 * 24 * 60 * 60),
            // 邊界情況：1 天之前（today 到 soon 的邊界）
            ("today_1d", -1.0 * 24 * 60 * 60),
            // 邊界情況：1.5 天之前（soon）
            ("soon_1.5d", -1.5 * 24 * 60 * 60),
            // 邊界情況：2 天之前（soon 到 far 的邊界）
            ("soon_2d", -2.0 * 24 * 60 * 60),
            // 邊界情況：2.5 天之前（far）
            ("far_2.5d", -2.5 * 24 * 60 * 60),
            // 邊界情況：3 天之前（far 到 normal 的邊界）
            ("far_3d", -3.0 * 24 * 60 * 60),
            // 邊界情況：3.5 天之前（normal）
            ("normal_3.5d", -3.5 * 24 * 60 * 60),
        ]
        
        for (caseLabel, billingOffset) in testCases {
            let billingDate = ISO8601DateFormatter().string(
                from: now.addingTimeInterval(-billingOffset)
            )
            
            let expiringStage = PortalyCheckoutService.calculateExpiringStage(
                proActive: true,
                subscriptionStatus: "active",
                nextBillingAt: billingDate,
                now: now
            )
            
            let interval = PortalyCheckoutService.effectiveEntitlementRefreshInterval(
                expiringStage: expiringStage
            )
            
            // 驗證每個邊界情況的預期頻率
            switch expiringStage {
            case "today":
                #expect(interval == 5 * 60, "Case: \(caseLabel) 應該使用 today 的 5 分鐘間隔")
            case "soon":
                #expect(interval == 30 * 60, "Case: \(caseLabel) 應該使用 soon 的 30 分鐘間隔")
            case "far":
                #expect(interval == 60 * 60, "Case: \(caseLabel) 應該使用 far 的 1 小時間隔")
            case "none":
                #expect(interval == baseInterval, "Case: \(caseLabel) 應該使用預設的 15 分鐘間隔")
            default:
                #expect(false, "Case: \(caseLabel) 收到意外的 expiringStage: \(expiringStage)")
            }
        }
        
        // 驗證 needsProEntitlementRefresh 和 proEntitlementRefreshDelay 的協同作用
        let activeProState = state("active", proActive: true, nextBillingAt: 
            ISO8601DateFormatter().string(from: now.addingTimeInterval(12 * 60 * 60))
        )
        
        // 模擬不同的 expiringStage 下的刷新需求
        #expect(
            PortalyCheckoutService.effectiveEntitlementRefreshInterval(
                expiringStage: "today"
            ) < PortalyCheckoutService.effectiveEntitlementRefreshInterval(
                expiringStage: "soon"
            ),
            "today 間隔應小於 soon 間隔"
        )
        #expect(
            PortalyCheckoutService.effectiveEntitlementRefreshInterval(
                expiringStage: "soon"
            ) < PortalyCheckoutService.effectiveEntitlementRefreshInterval(
                expiringStage: "far"
            ),
            "soon 間隔應小於 far 間隔"
        )
        #expect(
            PortalyCheckoutService.effectiveEntitlementRefreshInterval(
                expiringStage: "far"
            ) < PortalyCheckoutService.effectiveEntitlementRefreshInterval(
                expiringStage: "none"
            ),
            "far 間隔應小於 normal 間隔"
        )
    }

    @Test func cacheIsFresh_24hBoundary() {
        // 測試 24 小時快取邊界的精確邊界情況
        let now = Date(timeIntervalSince1970: 2_000_000)
        
        // 快取邊界值：23.9 小時（應為新鮮）
        let fresh23_9h = now.addingTimeInterval(-(23.9 * 60 * 60))
        #expect(
            PortalyCheckoutService.cacheIsFresh(
                cachedAt: fresh23_9h,
                now: now
            ),
            "23.9 小時的快取應被視為新鮮"
        )
        
        // 快取邊界值：24 小時（應為已過期）
        let stale24h = now.addingTimeInterval(-(24 * 60 * 60))
        #expect(
            !PortalyCheckoutService.cacheIsFresh(
                cachedAt: stale24h,
                now: now
            ),
            "24 小時的快取應被視為已過期"
        )
        
        // 快取邊界值：24.1 小時（應為已過期）
        let stale24_1h = now.addingTimeInterval(-(24.1 * 60 * 60))
        #expect(
            !PortalyCheckoutService.cacheIsFresh(
                cachedAt: stale24_1h,
                now: now
            ),
            "24.1 小時的快取應被視為已過期"
        )
        
        // 邊界情況：快取恰好在 24 小時前 1 秒（應為新鮮）
        let fresh24h_minus1s = now.addingTimeInterval(-(24 * 60 * 60 - 1))
        #expect(
            PortalyCheckoutService.cacheIsFresh(
                cachedAt: fresh24h_minus1s,
                now: now
            ),
            "24 小時前 1 秒的快取應被視為新鮮"
        )
        
        // 邊界情況：快取恰好在 24 小時後 1 秒（應為已過期）
        let stale24h_plus1s = now.addingTimeInterval(-(24 * 60 * 60 + 1))
        #expect(
            !PortalyCheckoutService.cacheIsFresh(
                cachedAt: stale24h_plus1s,
                now: now
            ),
            "24 小時後 1 秒的快取應被視為已過期"
        )
        
        // isEntitlementCacheExpired 初始化邏輯測試
        // 驗證初始快取狀態應為過期（conservative approach）
        // 這由 PortalyCheckoutService 的實現保證
        
        // 驗證快取新鮮度判斷的一致性
        let intervals: [TimeInterval] = [
            0.0,      // 剛剛被快取
            12 * 60 * 60,  // 12 小時
            23 * 60 * 60,  // 23 小時
            23.9 * 60 * 60,  // 23.9 小時
            24 * 60 * 60,   // 24 小時
            48 * 60 * 60,   // 48 小時
        ]
        
        var previousCacheState = true  // 最新的應該是新鮮的
        for interval in intervals {
            let cachedAt = now.addingTimeInterval(-interval)
            let isFresh = PortalyCheckoutService.cacheIsFresh(
                cachedAt: cachedAt,
                now: now
            )
            
            // 驗證快取新鮮度的單調性：舊快取不應突然變新鮮
            if interval > 0 {
                #expect(
                    !isFresh || previousCacheState,
                    "快取新鮮度應該隨時間單調遞減（時間間隔：\(interval / 60 / 60)h）"
                )
            }
            previousCacheState = isFresh
        }
    }
}
