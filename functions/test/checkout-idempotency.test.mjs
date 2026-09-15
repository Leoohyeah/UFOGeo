import assert from "node:assert/strict";
import test from "node:test";

import {
  callbackMatchesCheckoutSession,
  callbackModeMatchesDeployment,
  callbackModeMatchesSession,
  CHECKOUT_UNCERTAIN_HOLD_MS,
  canReuseOrphanLockSnapshot,
  classifyCheckoutCreationResult,
  checkoutEntitlementGrantDecision,
  checkoutLockDocumentId,
  checkoutLockMatchesSession,
  checkoutLeaseDecision,
  checkoutSessionReuseDecision,
  hasBlockingSubscription,
  isReusableCheckoutSession,
  shouldApplyUserSubscriptionUpdate,
} from "../checkout-idempotency.mjs";

test("blocks every still-chargeable subscription state before creating checkout", () => {
  for (const subscriptionStatus of ["active", "past_due", "cancel_requested"]) {
    assert.equal(hasBlockingSubscription({subscriptionStatus}), true);
  }
  assert.equal(
    hasBlockingSubscription({proActive: true, subscriptionStatus: "none"}),
    true,
  );
  for (const subscriptionStatus of ["none", "checkout_ready", "checkout_failed", "canceled"]) {
    assert.equal(
      hasBlockingSubscription({proActive: false, subscriptionStatus}),
      false,
    );
  }
  for (const malformed of [null, "active", 42, []]) {
    assert.equal(hasBlockingSubscription(malformed), false);
  }
});

test("blocks renewable subscriptions only in the current Portaly mode", () => {
  for (const subscriptionStatus of ["active", "past_due", "cancel_requested"]) {
    assert.equal(hasBlockingSubscription({
      mode: "live",
      subscriptionStatus,
    }, {mode: "live"}), true);
    assert.equal(hasBlockingSubscription({
      mode: "test",
      subscriptionStatus,
    }, {mode: "live"}), false);
  }

  assert.equal(hasBlockingSubscription({
    mode: "test",
    proActive: true,
    subscriptionStatus: "none",
  }, {mode: "live"}), false);
  assert.equal(hasBlockingSubscription({
    proActive: true,
    subscriptionStatus: "active",
  }, {mode: "live"}), true);
  assert.equal(hasBlockingSubscription({
    mode: "sandbox",
    subscriptionStatus: "active",
  }, {mode: "live"}), true);
});

test("allows live checkout past a test subscription but holds unknown legacy state", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {
      mode: "test",
      proActive: true,
      subscriptionStatus: "active",
      subscriptionId: "sub_test",
      currentCheckoutSessionId: "sub_test",
      planId,
      cancelAtPeriodEnd: false,
    },
    planId,
    mode: "live",
  }), {kind: "acquire"});

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {
      proActive: true,
      subscriptionStatus: "active",
      subscriptionId: "sub_legacy_active",
    },
    planId,
    mode: "live",
  }), {kind: "blocked"});

  for (const subscriptionStatus of ["pending", "checkout_ready", "created"]) {
    assert.deepEqual(checkoutLeaseDecision({
      subscription: {
        subscriptionStatus,
        currentCheckoutSessionId: "session_legacy_pending",
      },
      planId,
      mode: "live",
    }), {kind: "safety_hold", status: "legacy_mode_unknown"});
  }

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {
      mode: "test",
      proActive: false,
      subscriptionStatus: "checkout_ready",
      subscriptionId: "session_test_pending",
      currentCheckoutSessionId: "session_test_pending",
      planId,
      cancelAtPeriodEnd: false,
    },
    planId,
    mode: "live",
  }), {kind: "acquire"});
});

test("holds unknown current-mode membership state instead of opening a second checkout", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  for (const subscription of [
    {mode: "live", subscriptionStatus: "unknown"},
    {mode: "live", subscriptionId: "sub-without-status"},
    {mode: "sandbox", subscriptionStatus: "none", proActive: false},
    {subscriptionStatus: "checkout_failed", proActive: false},
    {mode: "live", subscriptionStatus: "none", proActive: "false"},
  ]) {
    assert.deepEqual(checkoutLeaseDecision({
      subscription,
      planId,
      mode: "live",
    }), {kind: "safety_hold", status: "subscription_state_unknown"});
  }

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {mode: "test", subscriptionStatus: "provider_future_status"},
    planId,
    mode: "live",
  }), {kind: "safety_hold", status: "subscription_state_unknown"});

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {
      mode: "test",
      subscriptionStatus: "canceled",
      proActive: false,
      subscriptionId: "sub-test",
      currentCheckoutSessionId: "sub-test",
      planId,
      cancelAtPeriodEnd: false,
    },
    planId,
    mode: "live",
  }), {kind: "acquire"});
});

test("holds invalid plan and document identifiers instead of opening checkout", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  for (const subscription of [
    {
      mode: "live",
      proActive: false,
      subscriptionStatus: "none",
      subscriptionId: null,
      currentCheckoutSessionId: null,
      planId: "other-plan",
      cancelAtPeriodEnd: false,
    },
    {
      mode: "live",
      proActive: false,
      subscriptionStatus: "checkout_failed",
      subscriptionId: null,
      currentCheckoutSessionId: "invalid/session",
      planId,
      cancelAtPeriodEnd: false,
    },
  ]) {
    assert.deepEqual(checkoutLeaseDecision({
      subscription,
      planId,
      mode: "live",
    }), {kind: "safety_hold", status: "subscription_state_unknown"});
  }
});

test("invalid grants block checkout instead of collapsing to free", () => {
  const now = Date.parse("2026-09-04T00:00:00.000Z");
  const validGrant = {
    active: true,
    kind: "lifetime_pro",
    expiresAt: null,
    grantedAt: "2026-09-01T00:00:00.000Z",
    grantedBy: "owner@example.com",
    reason: "support grant",
  };

  assert.deepEqual(checkoutEntitlementGrantDecision(null, {now}), {kind: "allow"});
  assert.deepEqual(checkoutEntitlementGrantDecision(validGrant, {now}), {
    kind: "server_grant",
  });
  assert.deepEqual(checkoutEntitlementGrantDecision({...validGrant, active: false}, {now}), {
    kind: "allow",
  });
  assert.deepEqual(checkoutEntitlementGrantDecision({...validGrant, active: "true"}, {now}), {
    kind: "grant_invalid",
    code: "ENTITLEMENT_GRANT_ACTIVE_INVALID",
  });
});

test("holds a current unfinished checkout until the existing session is confirmed expired", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const subscription = {
    mode: "live",
    proActive: false,
    subscriptionStatus: "checkout_ready",
    subscriptionId: "session-pending",
    currentCheckoutSessionId: "session-pending",
    planId,
    cancelAtPeriodEnd: false,
  };

  assert.deepEqual(checkoutLeaseDecision({subscription, planId, mode: "live", now}), {
    kind: "safety_hold",
    status: "checkout_ready",
  });
  assert.deepEqual(checkoutLeaseDecision({
    subscription,
    emailLock: {
      uid: "uid-1",
      planId,
      mode: "live",
      sessionId: "session-pending",
      status: "checkout_ready",
      checkoutUrl: "https://portaly.ai/checkout/session-pending",
      expiresAt: now,
    },
    uid: "uid-1",
    planId,
    mode: "live",
    now,
  }), {kind: "safety_hold", status: "checkout_ready"});
});

test("holds contradictory current-mode state instead of reporting an active subscription", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {
      mode: "live",
      proActive: false,
      subscriptionStatus: "active",
      subscriptionId: "sub-1",
      currentCheckoutSessionId: "sub-1",
      planId,
      cancelAtPeriodEnd: false,
    },
    planId,
    mode: "live",
  }), {kind: "safety_hold", status: "subscription_state_unknown"});
});

test("reuses an unexpired checkout session for the requested plan", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const session = {
    planId,
    sessionId: "session-reusable",
    status: "checkout_ready",
    checkoutUrl: "https://example.com/checkout",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  assert.equal(isReusableCheckoutSession(session, {planId, now}), true);
});

test("reuses a checkout only in the same Portaly mode", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const session = {
    planId,
    sessionId: "session-mode",
    mode: "test",
    status: "checkout_ready",
    checkoutUrl: "https://example.com/checkout",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  assert.equal(isReusableCheckoutSession(session, {planId, mode: "test", now}), true);
  assert.equal(isReusableCheckoutSession(session, {planId, mode: "live", now}), false);
  assert.equal(isReusableCheckoutSession({...session, mode: undefined}, {
    planId,
    mode: "test",
    now,
  }), false);
});

test("uses mode-specific lock ids and leaves the legacy id available for migration", () => {
  const uid = "user-123";
  const planId = "JO5cmDQdqTtb6AkkcnNW";

  assert.equal(checkoutLockDocumentId(uid, planId, "test"), `${uid}_${planId}_test`);
  assert.equal(checkoutLockDocumentId(uid, planId, "live"), `${uid}_${planId}_live`);
  assert.equal(checkoutLockDocumentId(uid, planId), `${uid}_${planId}`);
});

test("does not reuse expired, active, or wrong-plan checkout sessions", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const session = {
    planId: "JO5cmDQdqTtb6AkkcnNW",
    sessionId: "session-filtered",
    status: "pending",
    checkoutUrl: "https://example.com/checkout",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  assert.equal(isReusableCheckoutSession({
    ...session,
    expiresAt: "2026-08-26T04:00:00.000Z",
  }, {planId, now}), false);
  assert.equal(isReusableCheckoutSession({...session, status: "active"}, {planId, now}), false);
  assert.equal(isReusableCheckoutSession({...session, planId: "other"}, {planId, now}), false);
});

test("reuses only pending checkout statuses with a future parseable expiry", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const base = {
    planId,
    sessionId: "session-status",
    checkoutUrl: "https://example.com/checkout",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  for (const status of ["pending", "checkout_ready", "created"]) {
    assert.equal(isReusableCheckoutSession({...base, status}, {planId, now}), true);
  }
  for (const status of ["completed", "failed", "expired", "canceled", "active"]) {
    assert.equal(isReusableCheckoutSession({...base, status}, {planId, now}), false);
  }
  assert.equal(
    isReusableCheckoutSession({...base, status: "pending", expiresAt: "invalid"}, {planId, now}),
    false,
  );
  assert.equal(
    isReusableCheckoutSession({
      ...base,
      status: "pending",
      expiresAt: {toDate: () => new Date("2026-08-26T04:10:00.000Z")},
    }, {planId, now}),
    true,
  );
  assert.equal(
    isReusableCheckoutSession({...base, status: "pending", checkoutUrl: 42}, {planId, now}),
    false,
  );
  assert.equal(
    isReusableCheckoutSession({...base, status: "pending", checkoutUrl: ""}, {planId, now}),
    false,
  );
});

test("serializes two parallel checkout attempts with a creating lease", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");

  assert.deepEqual(
    checkoutLeaseDecision({subscription: {}, lock: null, planId, now}),
    {kind: "acquire"},
  );

  const lockAfterFirstAcquire = {
    uid: "user-123",
    planId,
    status: "creating",
    leaseId: "lease-1",
    leaseExpiresAtMs: now + 60_000,
  };
  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {},
      lock: lockAfterFirstAcquire,
      planId,
      now: now + 1,
    }),
    {kind: "in_progress"},
  );
});

test("accepts only a complete future Portaly checkout response", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  for (const status of ["pending", "checkout_ready", "created"]) {
    const payload = {data: {
      sessionId: "session-complete",
      status,
      checkoutUrl: "https://portaly.ai/checkout/session-complete",
      checkoutToken: "token-complete",
      expiresAt: "2026-08-26T04:10:00.000Z",
    }};

    const result = classifyCheckoutCreationResult({status: 201, payload, now});
    assert.equal(result.kind, "success");
    assert.equal(result.retryAllowed, false);
    assert.equal(result.session.sessionId, "session-complete");
    assert.equal(result.session.status, "checkout_ready");
    assert.equal(result.session.providerStatus, status);
  }
});

test("treats throw, timeout-equivalent errors, and every 5xx as uncertain", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  for (const input of [
    {error: new Error("network failure")},
    {error: Object.assign(new Error("timeout"), {name: "TimeoutError"})},
    {error: Object.assign(new Error("aborted"), {name: "AbortError"})},
    {status: 500, payload: {error: "internal"}},
    {status: 599, payload: {error: "upstream timeout"}},
    {status: 503, payload: {data: {
      sessionId: "session-maybe-created",
      checkoutUrl: "https://portaly.ai/checkout/session-maybe-created",
      expiresAt: "2026-08-26T04:10:00.000Z",
    }}},
  ]) {
    const result = classifyCheckoutCreationResult({...input, now});
    assert.equal(result.kind, "uncertain");
    assert.equal(result.retryAllowed, false);
  }
});

test("treats only documented rejection statuses as safe to retry", () => {
  for (const [status, code] of [
    [400, "INVALID_DISCOUNT_CODE"],
    [401, undefined],
    [403, undefined],
    [404, "PLAN_NOT_FOUND"],
    [422, "PLAN_INACTIVE"],
    [422, "YEARLY_TEMPORARILY_UNSUPPORTED"],
  ]) {
    assert.deepEqual(
      classifyCheckoutCreationResult({status, payload: {error: "rejected", code}}),
      {kind: "definitive_failure", retryAllowed: true, reason: "http_4xx", status},
    );
  }
});

test("keeps ambiguous 4xx checkout responses under the safety hold", () => {
  for (const [status, payload] of [
    [400, {}],
    [400, {error: "rejected", code: "UNKNOWN_CODE"}],
    [404, {error: "rejected"}],
    [422, {error: "rejected", code: "UNKNOWN_CODE"}],
    [422, {error: "rejected", code: "PLAN_INACTIVE", data: {sessionId: "maybe"}}],
    ...[402, 405, 408, 409, 418, 429, 499].map((status) =>
      [status, {error: "rejected"}]),
  ]) {
    const result = classifyCheckoutCreationResult({status, payload});
    assert.equal(result.kind, "uncertain");
    assert.equal(result.retryAllowed, false);
    assert.equal(result.reason, "ambiguous_http_4xx");
  }
});

test("fails closed for every incomplete 2xx checkout response", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const complete = {
    sessionId: "session-incomplete",
    status: "checkout_ready",
    checkoutUrl: "https://portaly.ai/checkout/session-incomplete",
    checkoutToken: "token-incomplete",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };
  const incomplete = [
    {...complete, sessionId: undefined},
    {...complete, sessionId: ""},
    {...complete, sessionId: "."},
    {...complete, sessionId: ".."},
    {...complete, sessionId: "session/child"},
    {...complete, sessionId: "x".repeat(1501)},
    {...complete, checkoutUrl: undefined},
    {...complete, checkoutUrl: ""},
    {...complete, checkoutUrl: "https://"},
    {...complete, checkoutUrl: "http://portaly.ai/checkout/session-incomplete"},
    {...complete, checkoutUrl: "ftp://portaly.ai/checkout/session-incomplete"},
    {...complete, checkoutUrl: "not-a-url"},
    {...complete, checkoutToken: undefined},
    {...complete, checkoutToken: ""},
    {...complete, expiresAt: undefined},
    {...complete, expiresAt: "invalid"},
    {...complete, expiresAt: "2026-08-26T03:59:59.999Z"},
    {...complete, expiresAt: "2026-08-26T04:00:00.000Z"},
  ];

  for (const data of incomplete) {
    const result = classifyCheckoutCreationResult({status: 200, payload: {data}, now});
    assert.equal(result.kind, "uncertain");
    assert.equal(result.retryAllowed, false);
    assert.equal(result.reason, "response_incomplete");
  }
  for (const [status, payload] of [
    [200, {}],
    [204, {data: null}],
    [299, {data: []}],
  ]) {
    const result = classifyCheckoutCreationResult({status, payload, now});
    assert.equal(result.kind, "uncertain");
    assert.equal(result.retryAllowed, false);
    assert.equal(result.reason, "response_incomplete");
  }
  const knownSession = classifyCheckoutCreationResult({
    status: 200,
    payload: {data: {...complete, checkoutUrl: null}},
    now,
  });
  assert.equal(knownSession.sessionId, "session-incomplete");
  assert.equal("checkoutUrl" in knownSession, false);
});

test("fails closed when a 2xx response has a terminal or malformed initial status", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const complete = {
    sessionId: "session-terminal",
    checkoutUrl: "https://portaly.ai/checkout/session-terminal",
    checkoutToken: "token-terminal",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  // Persisting any of these as the lock status makes the future session
  // non-reusable, so the next request would acquire a second provider order.
  for (const status of [undefined, 42, " ", "unexpected", "completed", "canceled"]) {
    const result = classifyCheckoutCreationResult({
      status: 200,
      payload: {data: {...complete, status}},
      now,
    });
    assert.equal(result.kind, "uncertain", `provider status ${JSON.stringify(status)}`);
    assert.equal(result.retryAllowed, false, `provider status ${JSON.stringify(status)}`);
  }
});

test("never ages an uncertain checkout POST into a retry", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  assert.ok(CHECKOUT_UNCERTAIN_HOLD_MS >= 24 * 60 * 60 * 1000);

  const emailLock = {
    uid: "old-user",
    planId,
    mode: "live",
    status: "uncertain",
    safetyHoldUntilMs: now,
  };
  for (const uid of ["old-user", "new-user"]) {
    assert.deepEqual(checkoutLeaseDecision({
      subscription: {},
      emailLock,
      uid,
      planId,
      mode: "live",
      now,
    }), {
      kind: "safety_hold",
      status: "uncertain",
      safetyHoldUntilMs: now,
    });
  }
});

test("keeps account-deletion holds bounded", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  for (const status of ["account_deleting", "account_deleted"]) {
    const emailLock = {
      uid: "old-user",
      planId,
      mode: "live",
      status,
      safetyHoldUntilMs: now + CHECKOUT_UNCERTAIN_HOLD_MS,
    };
    for (const uid of ["old-user", "new-user"]) {
      assert.deepEqual(checkoutLeaseDecision({
        subscription: {},
        emailLock,
        uid,
        planId,
        mode: "live",
        now,
      }), {
        kind: "safety_hold",
        status,
        safetyHoldUntilMs: now + CHECKOUT_UNCERTAIN_HOLD_MS,
      });
      assert.deepEqual(checkoutLeaseDecision({
        subscription: {},
        emailLock: {...emailLock, safetyHoldUntilMs: now},
        uid,
        planId,
        mode: "live",
        now,
      }), {kind: "acquire"});
    }
  }
});

test("keeps an abandoned pre-armed checkout locked until reconciliation", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const lock = {
    uid: "user-A",
    planId,
    mode: "test",
    status: "creating",
    leaseId: "lease-A",
    leaseExpiresAtMs: now,
    safetyHoldUntilMs: now + CHECKOUT_UNCERTAIN_HOLD_MS,
  };

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {}, emailLock: lock, uid: "user-B", planId, mode: "test", now,
  }), {
    kind: "safety_hold",
    status: "creating",
    safetyHoldUntilMs: now + CHECKOUT_UNCERTAIN_HOLD_MS,
  });
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {},
    emailLock: {...lock, safetyHoldUntilMs: now},
    uid: "user-B",
    planId,
    mode: "test",
    now,
  }), {
    kind: "safety_hold",
    status: "creating",
    safetyHoldUntilMs: now,
  });
});

test("reuses an email lock only for the same Firebase uid", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const emailLock = {
    uid: "user-A",
    planId,
    mode: "live",
    status: "checkout_ready",
    sessionId: "session-A",
    checkoutUrl: "https://example.com/checkout/a",
    expiresAt: now + 60_000,
  };

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {}, emailLock, uid: "user-A", planId, mode: "live", now,
  }), {kind: "reuse", session: emailLock});
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {}, emailLock, uid: "user-B", planId, mode: "live", now,
  }), {kind: "conflict"});
});

test("serializes a different-uid race on the email lock as in progress", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const emailLock = {
    uid: "user-A",
    planId,
    mode: "live",
    status: "creating",
    leaseId: "lease-A",
    leaseExpiresAtMs: now + 60_000,
  };

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {}, emailLock, uid: "user-B", planId, mode: "live", now,
  }), {kind: "in_progress"});
});

test("checks multiple legacy UID locks without crossing owners", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const expired = {
    uid: "old-user",
    planId,
    mode: "live",
    status: "creating",
    leaseExpiresAtMs: now,
  };
  const ready = {
    uid: "current-user",
    planId,
    mode: "live",
    status: "checkout_ready",
    sessionId: "session-current",
    checkoutUrl: "https://example.com/current",
    expiresAt: now + 60_000,
  };

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {},
    legacyLocks: [expired, ready],
    uid: "current-user",
    planId,
    mode: "live",
    now,
  }), {kind: "reuse", session: ready});
});

test("ignores creating locks for another plan or Portaly mode", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  for (const lock of [
    {planId: "other", mode: "live", status: "creating", leaseExpiresAtMs: now + 60_000},
    {planId, mode: "test", status: "creating", leaseExpiresAtMs: now + 60_000},
  ]) {
    assert.deepEqual(checkoutLeaseDecision({
      subscription: {}, emailLock: lock, uid: "user-B", planId, mode: "live", now,
    }), {kind: "acquire"});
  }
});

test("shares the email-scoped recovery lease with checkout idempotency", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const recoveryLock = {
    planId,
    mode: "test",
    status: "recovery_in_progress",
    leaseExpiresAtMs: now + 60_000,
  };
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {},
    emailLock: recoveryLock,
    uid: "new-user",
    planId,
    mode: "test",
    now,
  }), {kind: "in_progress"});
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {},
    emailLock: {...recoveryLock, leaseExpiresAtMs: now + 60_000},
    uid: "new-user",
    planId,
    mode: "test",
    now,
  }), {kind: "in_progress"});
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {},
    emailLock: {...recoveryLock, leaseExpiresAtMs: now},
    uid: "new-user",
    planId,
    mode: "test",
    now,
  }), {kind: "acquire"});
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {},
    emailLock: {...recoveryLock, leaseExpiresAtMs: "invalid"},
    uid: "new-user",
    planId,
    mode: "test",
    now,
  }), {kind: "safety_hold", status: "recovery_state_unknown"});
});

test("does not retry an abandoned checkout after its creating lease expires", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const expiredLock = {
    planId,
    status: "creating",
    leaseId: "expired-lease",
    leaseExpiresAtMs: now,
  };

  assert.deepEqual(
    checkoutLeaseDecision({subscription: {}, lock: expiredLock, planId, now}),
    {kind: "safety_hold", status: "creating"},
  );
});

test("blocks active subscriptions before considering reusable checkout state", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const readyLock = {
    planId,
    sessionId: "session-active-block",
    status: "checkout_ready",
    checkoutUrl: "https://example.com/checkout",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {subscriptionStatus: "active"},
      lock: readyLock,
      planId,
      now,
    }),
    {kind: "blocked"},
  );
});

test("reuses a ready lock before a legacy fallback session", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const readyLock = {
    planId,
    mode: "test",
    status: "checkout_ready",
    sessionId: "session-from-lock",
    checkoutUrl: "https://example.com/checkout/from-lock",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };
  const fallbackSession = {
    planId,
    mode: "test",
    status: "checkout_ready",
    sessionId: "legacy-session",
    checkoutUrl: "https://example.com/checkout/legacy",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {},
      lock: readyLock,
      fallbackSession,
      planId,
      mode: "test",
      now,
    }),
    {kind: "reuse", session: readyLock},
  );
  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {},
      lock: null,
      fallbackSession,
      planId,
      mode: "test",
      now,
    }),
    {kind: "reuse", session: fallbackSession},
  );
});

test("holds an unexpired legacy checkout when its mode is unknown", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const legacyReady = {
    planId,
    status: "checkout_ready",
    sessionId: "legacy-session",
    checkoutUrl: "https://example.com/checkout/legacy",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {},
      lock: null,
      legacyLock: legacyReady,
      fallbackSession: legacyReady,
      planId,
      mode: "live",
      now,
    }),
    {
      kind: "safety_hold",
      status: "legacy_mode_unknown",
      safetyHoldUntilMs: Date.parse("2026-08-26T04:10:00.000Z"),
    },
  );
});

test("allows a legacy checkout to be retried after its unknown-mode session expires", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const legacyReady = {
    planId,
    status: "checkout_ready",
    sessionId: "legacy-session",
    checkoutUrl: "https://example.com/checkout/legacy",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {},
      legacyLock: legacyReady,
      fallbackSession: legacyReady,
      planId,
      mode: "live",
      now: now + 10 * 60 * 1000,
    }),
    {kind: "acquire"},
  );
});

test("honors an active legacy creating lease during mode migration", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {},
      lock: null,
      legacyLock: {
        planId,
        status: "creating",
        leaseExpiresAtMs: now + 30_000,
      },
      planId,
      mode: "live",
      now,
    }),
    {kind: "in_progress"},
  );
});

test("does not reuse an older pending session after a newer checkout is assigned", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const olderSession = {
    planId,
    mode: "test",
    sessionId: "session-A",
    status: "checkout_ready",
    checkoutUrl: "https://example.com/checkout/a",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };

  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {
        mode: "test",
        proActive: false,
        currentCheckoutSessionId: "session-B",
        subscriptionStatus: "checkout_failed",
        planId,
        cancelAtPeriodEnd: false,
      },
      fallbackSession: olderSession,
      planId,
      mode: "test",
      now,
    }),
    {kind: "acquire"},
  );
});

test("invalidates only the matching lock so checkout failure can be retried", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const sessionId = "session-failed";
  const readyLock = {
    planId,
    mode: "live",
    status: "checkout_ready",
    sessionId,
    checkoutUrl: "https://example.com/checkout/failed",
    expiresAt: "2026-08-26T04:10:00.000Z",
  };
  const failedSession = {
    ...readyLock,
    status: "checkout_failed",
  };

  assert.equal(checkoutLockMatchesSession(readyLock, sessionId), true);
  assert.equal(checkoutLockMatchesSession(readyLock, "newer-session"), false);
  assert.equal(checkoutLockMatchesSession({...readyLock, mode: "test"}, sessionId, {mode: "test"}), true);
  assert.equal(checkoutLockMatchesSession({...readyLock, mode: "test"}, sessionId, {mode: "live"}), false);
  assert.deepEqual(
    checkoutLeaseDecision({
      subscription: {
        mode: "live",
        proActive: false,
        subscriptionStatus: "checkout_failed",
        currentCheckoutSessionId: sessionId,
        planId,
        cancelAtPeriodEnd: false,
      },
      lock: null,
      fallbackSession: failedSession,
      planId,
      mode: "live",
      now: Date.parse("2026-08-26T04:01:00.000Z"),
    }),
    {kind: "acquire"},
  );
});

test("authoritative terminal checkout sessions invalidate stale reusable locks", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const lock = {
    uid: "user-A",
    planId,
    mode: "live",
    status: "checkout_ready",
    sessionId: "session-stale",
    checkoutUrl: "https://example.com/checkout/stale",
    expiresAt: now + 60_000,
  };
  const terminalSession = {
    uid: "user-A",
    planId,
    mode: "live",
    sessionId: "session-stale",
    status: "checkout_failed",
    providerStatus: "checkout_ready",
  };

  assert.deepEqual(checkoutSessionReuseDecision(lock, {
    authoritativeSessions: new Map([[
      lock.sessionId,
      terminalSession,
    ]]),
    uid: "user-A",
    planId,
    mode: "live",
    now,
  }), {kind: "terminal"});
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {
      mode: "live",
      proActive: false,
      subscriptionStatus: "checkout_failed",
      currentCheckoutSessionId: lock.sessionId,
      planId,
      cancelAtPeriodEnd: false,
    },
    emailLock: lock,
    authoritativeSessions: new Map([[
      lock.sessionId,
      terminalSession,
    ]]),
    uid: "user-A",
    planId,
    mode: "live",
    now,
  }), {kind: "acquire"});
});

test("authoritative pending and uncertain sessions remain protected", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const lock = {
    uid: "user-A",
    planId,
    mode: "live",
    status: "checkout_ready",
    sessionId: "session-pending",
    checkoutUrl: "https://example.com/checkout/pending",
    expiresAt: now + 60_000,
  };
  const base = {
    uid: "user-A",
    planId,
    mode: "live",
    sessionId: lock.sessionId,
  };

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {},
    emailLock: lock,
    authoritativeSessions: new Map([[
      lock.sessionId,
      {...base, status: "checkout_ready"},
    ]]),
    uid: "user-A",
    planId,
    mode: "live",
    now,
  }), {kind: "reuse", session: lock});
  assert.deepEqual(checkoutLeaseDecision({
    subscription: {},
    emailLock: lock,
    authoritativeSessions: new Map([[
      lock.sessionId,
      {...base, status: "response_incomplete"},
    ]]),
    uid: "user-A",
    planId,
    mode: "live",
    now,
  }), {kind: "safety_hold", status: "response_incomplete"});
});

test("authoritative paid, missing, and mismatched sessions fail closed", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const lock = {
    uid: "user-A",
    planId,
    mode: "live",
    status: "checkout_ready",
    sessionId: "session-paid",
    checkoutUrl: "https://example.com/checkout/paid",
    expiresAt: now + 60_000,
  };
  const decision = (entry) => checkoutLeaseDecision({
    subscription: {},
    emailLock: lock,
    authoritativeSessions: new Map([[lock.sessionId, entry]]),
    uid: "user-A",
    planId,
    mode: "live",
    now,
  });

  assert.deepEqual(decision({...lock, status: "active"}), {kind: "blocked"});
  assert.deepEqual(decision(null), {
    kind: "safety_hold",
    status: "checkout_session_state_unknown",
  });
  assert.deepEqual(decision({...lock, uid: "user-B", status: "checkout_ready"}), {
    kind: "safety_hold",
    status: "checkout_session_identity_mismatch",
  });
});

test("a fallback session that becomes terminal is not reused", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const fallbackSession = {
    uid: "user-A",
    planId,
    mode: "live",
    status: "checkout_ready",
    sessionId: "session-raced",
    checkoutUrl: "https://example.com/checkout/raced",
    expiresAt: now + 60_000,
  };

  assert.deepEqual(checkoutLeaseDecision({
    subscription: {
      mode: "live",
      proActive: false,
      subscriptionStatus: "checkout_failed",
      currentCheckoutSessionId: fallbackSession.sessionId,
      planId,
      cancelAtPeriodEnd: false,
    },
    fallbackSession,
    authoritativeSessions: new Map([[
      fallbackSession.sessionId,
      {...fallbackSession, status: "expired"},
    ]]),
    uid: "user-A",
    planId,
    mode: "live",
    now,
  }), {kind: "acquire"});
});

test("releases terminal old-owner sessions but protects their pending sessions", () => {
  const planId = "JO5cmDQdqTtb6AkkcnNW";
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const lock = {
    uid: "user-A",
    planId,
    mode: "live",
    status: "checkout_ready",
    sessionId: "session-old-owner",
    checkoutUrl: "https://example.com/checkout/old-owner",
    expiresAt: now + 60_000,
  };
  const decide = (session) => checkoutLeaseDecision({
    subscription: {},
    emailLock: lock,
    authoritativeSessions: new Map([[lock.sessionId, session]]),
    uid: "user-B",
    planId,
    mode: "live",
    now,
  });

  assert.deepEqual(decide({...lock, status: "checkout_failed"}), {kind: "acquire"});
  assert.deepEqual(decide({...lock, status: "checkout_ready"}), {kind: "conflict"});
  assert.deepEqual(decide({...lock, uid: "user-C", status: "checkout_failed"}), {
    kind: "safety_hold",
    status: "checkout_session_identity_mismatch",
  });
});

test("does not let an older callback change the user's newer subscription", () => {
  assert.equal(
    shouldApplyUserSubscriptionUpdate({subscriptionId: "newer-session"}, "older-session"),
    false,
  );
  assert.equal(
    shouldApplyUserSubscriptionUpdate({subscriptionId: "same-session"}, "same-session"),
    true,
  );
  assert.equal(shouldApplyUserSubscriptionUpdate({}, "first-session"), true);
  assert.equal(shouldApplyUserSubscriptionUpdate({}, ""), false);
});

test("only reuses a fetched orphan lock snapshot for the same reference", () => {
  assert.equal(canReuseOrphanLockSnapshot({
    orphanLockPath: "checkoutLocks/customer-1",
    refPath: "checkoutLocks/customer-1",
    snapshotFetched: false,
  }), false);
  assert.equal(canReuseOrphanLockSnapshot({
    orphanLockPath: "checkoutLocks/customer-1",
    refPath: "checkoutLocks/customer-1",
    snapshotFetched: true,
  }), true);
  assert.equal(canReuseOrphanLockSnapshot({
    orphanLockPath: "checkoutLocks/customer-1",
    refPath: "checkoutLocks/session-1",
    snapshotFetched: true,
  }), false);
});

test("prefers the current checkout id after a failed checkout clears subscriptionId", () => {
  const userAfterNewCheckoutFailed = {
    currentCheckoutSessionId: "session-B",
    subscriptionStatus: "checkout_failed",
  };

  assert.equal(
    shouldApplyUserSubscriptionUpdate(userAfterNewCheckoutFailed, "session-A"),
    false,
  );
  assert.equal(
    shouldApplyUserSubscriptionUpdate(userAfterNewCheckoutFailed, "session-B"),
    true,
  );
});

test("callback user updates respect explicit modes and backfill only missing modes", () => {
  const incomingSubscriptionId = "session-current";
  for (const mode of [undefined, null, "live"]) {
    assert.equal(shouldApplyUserSubscriptionUpdate({
      currentCheckoutSessionId: incomingSubscriptionId,
      mode,
    }, incomingSubscriptionId, {mode: "live"}), true);
  }
  for (const mode of ["test", "sandbox", ""]) {
    assert.equal(shouldApplyUserSubscriptionUpdate({
      currentCheckoutSessionId: incomingSubscriptionId,
      mode,
    }, incomingSubscriptionId, {mode: "live"}), false);
  }
  assert.equal(shouldApplyUserSubscriptionUpdate({
    currentCheckoutSessionId: incomingSubscriptionId,
  }, incomingSubscriptionId, {mode: "sandbox"}), false);
});

test("rejects callback mode mismatches while allowing documented live omission", () => {
  assert.equal(callbackModeMatchesSession("test", "live"), false);
  assert.equal(callbackModeMatchesSession("live", "test"), false);
  assert.equal(callbackModeMatchesSession("test", undefined), false);
  assert.equal(callbackModeMatchesSession("live", undefined), true);
  assert.equal(callbackModeMatchesSession("live", null), false);
  assert.equal(callbackModeMatchesSession(undefined, "test"), true);
  assert.equal(callbackModeMatchesSession(undefined, undefined), false);
  assert.equal(callbackModeMatchesSession(undefined, "sandbox"), false);
  assert.equal(callbackModeMatchesSession("test", ""), false);
});

test("matches callbacks only to the configured checkout identity", () => {
  const session = {
    sessionId: "session-1",
    subscriptionId: "session-1",
    customerEmail: "Buyer@Example.com",
    planId: "plan-pro",
    mode: "live",
  };
  const payload = {
    sessionId: "session-1",
    subscriptionId: "session-1",
    customerEmail: "buyer@example.com",
    planId: "plan-pro",
  };
  const options = {expectedPlanId: "plan-pro"};

  assert.equal(callbackMatchesCheckoutSession(session, payload, options), true);
  assert.equal(
    callbackMatchesCheckoutSession(session, {...payload, subscriptionId: undefined}, options),
    true,
  );
  for (const invalidPayload of [
    {...payload, subscriptionId: undefined, sessionId: "session-2"},
    {...payload, subscriptionId: undefined, planId: "other-plan"},
    {...payload, subscriptionId: undefined, customerEmail: "other@example.com"},
    {...payload, subscriptionId: undefined, mode: "test"},
  ]) {
    assert.equal(callbackMatchesCheckoutSession(session, invalidPayload, options), false);
  }
  for (const invalidPayload of [
    {...payload, sessionId: "session-2", subscriptionId: "session-2"},
    {...payload, planId: "other-plan"},
    {...payload, customerEmail: "other@example.com"},
    {...payload, mode: "test"},
  ]) {
    assert.equal(callbackMatchesCheckoutSession(session, invalidPayload, options), false);
  }
  assert.equal(callbackMatchesCheckoutSession(
    {...session, sessionId: "invalid/session"},
    payload,
    options,
  ), false);
  assert.equal(callbackMatchesCheckoutSession(
    {...session, accountDeleted: true, customerEmail: undefined},
    payload,
    options,
  ), true);
});

test("applies callbacks to current users only in the deployment API-key mode", () => {
  assert.equal(callbackModeMatchesDeployment("live", "live"), true);
  assert.equal(callbackModeMatchesDeployment("test", "test"), true);
  assert.equal(callbackModeMatchesDeployment("test", "live"), false);
  assert.equal(callbackModeMatchesDeployment("live", "test"), false);
  assert.equal(callbackModeMatchesDeployment(undefined, "live"), false);
  assert.equal(callbackModeMatchesDeployment("live", undefined), false);
  assert.equal(callbackModeMatchesDeployment("sandbox", "live"), false);
});
