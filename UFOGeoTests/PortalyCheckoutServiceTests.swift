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
            {"uid":"uid-1","email":"member@example.com","emailVerified":true,"proActive":false,"subscriptionStatus":"none","subscriptionId":null,"planId":"plan-1","mode":null,"nextBillingAt":null,"cancelAtPeriodEnd":false,"cancelEffectiveAt":null}
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
            {"uid":"uid-1","email":"member@example.com","emailVerified":true,"proActive":true,"subscriptionStatus":"active","subscriptionId":"sub-legacy","planId":"plan-1","mode":"test","nextBillingAt":null,"cancelAtPeriodEnd":false,"cancelEffectiveAt":null}
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

    @Test func uidMismatchAndExpiredCacheFailClosedBeforeProjectingPro() throws {
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
}
