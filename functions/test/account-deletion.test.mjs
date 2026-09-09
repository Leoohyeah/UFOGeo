import assert from "node:assert/strict";
import test from "node:test";

import {
  accountDeletionTombstoneWrite,
  accountDeletionGuardDecision,
  completedAccountDeletionMatches,
  createPortalSessionReservation,
  deletedAccountCallbackNeedsCancellation,
  needsSubscriptionCancellation,
  PORTAL_SESSION_EXPIRY_GRACE_MS,
  PORTAL_SESSION_SAFETY_WINDOW_MS,
  portalSessionGuardDecision,
  selectSubscriptionIdsToCancel,
  unverifiedDeletionNeedsEmailVerification,
  validatePortalSessionResponse,
  validateSubscriptionCancellationResponse,
} from "../account-deletion.mjs";

const target = {
  email: "leo2601673@gmail.com",
  planId: "plan_monthly",
  mode: "live",
};

function remoteSubscription(overrides = {}) {
  return {
    id: "sub_active",
    customerEmail: "leo2601673@gmail.com",
    planId: "plan_monthly",
    mode: "live",
    status: "active",
    cancelAtPeriodEnd: false,
    ...overrides,
  };
}

function localCheckout(overrides = {}) {
  return {
    uid: "user-old",
    sessionId: "session-pending",
    planId: target.planId,
    mode: target.mode,
    status: "checkout_ready",
    checkoutUrl: "https://portaly.ai/checkout/session-pending",
    expiresAt: "2026-08-26T04:10:00.000Z",
    ...overrides,
  };
}

test("uses a merge set for an account-deletion tombstone containing delete sentinels", () => {
  const deleteSentinel = Symbol("FieldValue.delete");
  const timestampSentinel = Symbol("FieldValue.serverTimestamp");
  const write = accountDeletionTombstoneWrite({
    accountUidHash: "uid-hash-1",
    uid: deleteSentinel,
    deletionId: deleteSentinel,
    status: "account_deleted",
    updatedAt: timestampSentinel,
  });

  assert.deepEqual(write.options, {merge: true});
  assert.equal(write.data.uid, deleteSentinel);
  assert.equal(write.data.deletionId, deleteSentinel);
  assert.equal(write.data.updatedAt, timestampSentinel);
});

test("accepts only a matching and confirmed Portaly cancellation response", () => {
  const expected = {subscriptionId: "sub_expected"};
  for (const value of [
    {id: "sub_expected", status: "active", cancelAtPeriodEnd: true},
    {subscriptionId: "sub_expected", status: "past_due", cancelAtPeriodEnd: true},
    // A fully canceled resource is the sole strict terminal alternative.
    {id: "sub_expected", status: "canceled", cancelAtPeriodEnd: false},
    {
      id: "sub_expected",
      subscriptionId: "sub_expected",
      status: "canceled",
      cancelAtPeriodEnd: false,
    },
  ]) {
    assert.equal(validateSubscriptionCancellationResponse(value, expected), value);
  }
});

test("rejects wrong, missing, false, or malformed cancellation confirmations", () => {
  const expected = {subscriptionId: "sub_expected"};
  for (const [value, code] of [
    [{id: "sub_other", status: "active", cancelAtPeriodEnd: true}, "SUBSCRIPTION_CANCEL_ID_MISMATCH"],
    [{status: "active", cancelAtPeriodEnd: true}, "SUBSCRIPTION_CANCEL_ID_MISSING"],
    [{id: "sub_expected", status: "active"}, "SUBSCRIPTION_CANCEL_CONFIRMATION_MISSING"],
    [{id: "sub_expected", status: "active", cancelAtPeriodEnd: false}, "SUBSCRIPTION_CANCEL_NOT_CONFIRMED"],
    [{id: "sub_expected", status: "past_due", cancelAtPeriodEnd: false}, "SUBSCRIPTION_CANCEL_NOT_CONFIRMED"],
    [{id: "sub_expected", cancelAtPeriodEnd: true}, "SUBSCRIPTION_CANCEL_STATUS_INVALID"],
    [{id: "sub_expected", status: "cancel_requested", cancelAtPeriodEnd: false}, "SUBSCRIPTION_CANCEL_STATUS_INVALID"],
    [{id: "sub_expected", status: "CANCELED", cancelAtPeriodEnd: false}, "SUBSCRIPTION_CANCEL_STATUS_INVALID"],
    [{id: "sub_expected", status: "canceled"}, "SUBSCRIPTION_CANCEL_CONFIRMATION_MISSING"],
    [{id: "sub_expected", status: "canceled", cancelAtPeriodEnd: "false"}, "SUBSCRIPTION_CANCEL_CONFIRMATION_MISSING"],
    [{id: "sub_expected", status: "canceled", cancelAtPeriodEnd: true}, "SUBSCRIPTION_CANCEL_STATE_INVALID"],
    [{
      id: "sub_expected",
      subscriptionId: "sub_other",
      status: "active",
      cancelAtPeriodEnd: true,
    }, "SUBSCRIPTION_CANCEL_ID_MISMATCH"],
  ]) {
    assert.throws(
      () => validateSubscriptionCancellationResponse(value, expected),
      (error) => error.code === code,
    );
  }
});

test("cancels renewal before deleting an account with an active subscription", () => {
  assert.equal(needsSubscriptionCancellation({proActive: true, subscriptionStatus: "active"}), true);
  assert.equal(needsSubscriptionCancellation({proActive: false, subscriptionStatus: "past_due"}), true);
});

test("does not cancel twice or call Portaly for a free account", () => {
  assert.equal(needsSubscriptionCancellation({
    proActive: true,
    subscriptionStatus: "cancel_requested",
    cancelAtPeriodEnd: true,
  }), false);
  assert.equal(needsSubscriptionCancellation({proActive: false, subscriptionStatus: "canceled"}), false);
  assert.equal(needsSubscriptionCancellation({proActive: false, subscriptionStatus: "none"}), false);
  assert.equal(needsSubscriptionCancellation({}), false);
  // `proActive` can be true because of a server-owned grant.  A canceled
  // Portaly record must not cause the grant-only account deletion path to call
  // Portaly again.
  assert.equal(needsSubscriptionCancellation({
    proActive: true,
    subscriptionStatus: "canceled",
    cancelAtPeriodEnd: false,
  }), false);
  assert.equal(needsSubscriptionCancellation({
    proActive: true,
    subscriptionStatus: "none",
    cancelAtPeriodEnd: false,
  }), false);
});

test("requires verification for renewable current or unknown modes, not an explicit opposite mode", () => {
  const renewable = {
    proActive: true,
    subscriptionStatus: "active",
    cancelAtPeriodEnd: false,
  };

  assert.equal(unverifiedDeletionNeedsEmailVerification({
    ...renewable,
    mode: "live",
  }, {expectedMode: "live"}), true);
  assert.equal(unverifiedDeletionNeedsEmailVerification({
    ...renewable,
    mode: "test",
  }, {expectedMode: "live"}), false);
  assert.equal(unverifiedDeletionNeedsEmailVerification(renewable, {
    expectedMode: "live",
  }), true);
  assert.equal(unverifiedDeletionNeedsEmailVerification({
    ...renewable,
    mode: "sandbox",
  }, {expectedMode: "live"}), true);
});

test("recognizes only the original account's completed deletion tombstone", () => {
  const lock = {
    accountUidHash: "uid-hash-1",
    planId: target.planId,
    mode: target.mode,
    status: "account_deleted",
  };
  assert.equal(completedAccountDeletionMatches(lock, {
    accountUidHash: "uid-hash-1",
    planId: target.planId,
    mode: target.mode,
  }), true);
  for (const input of [
    {...lock, status: "account_deleting"},
    {...lock, accountUidHash: "another-user"},
    {...lock, planId: "another-plan"},
    {...lock, mode: "test"},
  ]) {
    assert.equal(completedAccountDeletionMatches(input, {
      accountUidHash: "uid-hash-1",
      planId: target.planId,
      mode: target.mode,
    }), false);
  }
});

test("reserves a conservative portal safety window without storing its bearer URL", () => {
  const now = Date.parse("2026-09-02T04:00:00.000Z");
  assert.deepEqual(createPortalSessionReservation({
    operationId: "portal-operation-1",
    mode: "live",
    now,
  }), {
    status: "creating",
    operationId: "portal-operation-1",
    mode: "live",
    blockUntilMs: now + PORTAL_SESSION_SAFETY_WINDOW_MS,
  });
});

test("validates a Portaly portal response and keeps a five-minute expiry grace", () => {
  const now = Date.parse("2026-09-02T04:00:00.000Z");
  const expiresAt = "2026-09-02T04:30:00.000Z";
  const result = validatePortalSessionResponse({
    portalSessionId: "portal_abc123",
    portalUrl: "https://portaly.ai/portal/portal_abc123?token=secret",
    expiresAt,
  }, {
    operationId: "portal-operation-1",
    mode: "live",
    now,
  });

  assert.equal(result.portalUrl, "https://portaly.ai/portal/portal_abc123?token=secret");
  assert.deepEqual(result.record, {
    status: "ready",
    operationId: "portal-operation-1",
    portalSessionId: "portal_abc123",
    mode: "live",
    expiresAt,
    expiresAtMs: Date.parse(expiresAt),
    blockUntilMs: Date.parse(expiresAt) + PORTAL_SESSION_EXPIRY_GRACE_MS,
  });
  assert.equal("portalUrl" in result.record, false);
});

test("fails closed for malformed or expired Portaly portal responses", () => {
  const now = Date.parse("2026-09-02T04:00:00.000Z");
  const valid = {
    portalSessionId: "portal_abc123",
    portalUrl: "https://portaly.ai/portal/portal_abc123?token=secret",
    expiresAt: "2026-09-02T04:30:00.000Z",
  };
  for (const [value, code] of [
    [{...valid, portalSessionId: ""}, "PORTAL_SESSION_ID_MISSING"],
    [{...valid, portalUrl: "http://portaly.ai/portal/portal_abc123"}, "PORTAL_SESSION_URL_INVALID"],
    [{...valid, expiresAt: "not-a-date"}, "PORTAL_SESSION_EXPIRY_INVALID"],
    [{...valid, expiresAt: "2026-09-02T04:00:00.000Z"}, "PORTAL_SESSION_EXPIRY_INVALID"],
  ]) {
    assert.throws(
      () => validatePortalSessionResponse(value, {
        operationId: "portal-operation-1",
        mode: "live",
        now,
      }),
      (error) => error.code === code,
    );
  }
});

test("blocks account deletion until a valid portal session safety window expires", () => {
  const now = Date.parse("2026-09-02T04:00:00.000Z");
  const ready = validatePortalSessionResponse({
    portalSessionId: "portal_abc123",
    portalUrl: "https://portaly.ai/portal/portal_abc123?token=secret",
    expiresAt: "2026-09-02T04:30:00.000Z",
  }, {
    operationId: "portal-operation-1",
    mode: "live",
    now,
  }).record;

  assert.deepEqual(portalSessionGuardDecision(ready, {mode: "live", now}), {
    kind: "pending_portal",
    blockUntilMs: ready.blockUntilMs,
  });
  assert.deepEqual(accountDeletionGuardDecision({
    portalSession: ready,
    planId: target.planId,
    mode: target.mode,
    now,
  }), {
    kind: "pending_portal",
    blockUntilMs: ready.blockUntilMs,
  });
  assert.deepEqual(portalSessionGuardDecision(ready, {
    mode: "live",
    now: ready.blockUntilMs,
  }), {kind: "safe"});
});

test("blocks creating and uncertain portal sessions, and rejects corrupted active records", () => {
  const now = Date.parse("2026-09-02T04:00:00.000Z");
  const reservation = createPortalSessionReservation({
    operationId: "portal-operation-1",
    mode: "live",
    now,
  });
  for (const status of ["creating", "uncertain"]) {
    assert.equal(portalSessionGuardDecision({...reservation, status}, {
      mode: "live",
      now,
    }).kind, "pending_portal");
  }
  for (const corrupted of [
    {...reservation, operationId: ""},
    {...reservation, mode: "test"},
    {...reservation, blockUntilMs: "invalid"},
    {...reservation, status: "ready"},
  ]) {
    assert.deepEqual(portalSessionGuardDecision(corrupted, {
      mode: "live",
      now,
    }), {kind: "portal_state_invalid"});
  }
});

test("requests compensation only when a deleted account becomes renewable again", () => {
  for (const subscriptionStatus of ["active", "past_due"]) {
    assert.equal(deletedAccountCallbackNeedsCancellation({
      accountDeleted: true,
      subscriptionStatus,
      cancelAtPeriodEnd: false,
    }), true);
  }
  for (const value of [
    {accountDeleted: false, subscriptionStatus: "active", cancelAtPeriodEnd: false},
    {accountDeleted: true, subscriptionStatus: "cancel_requested", cancelAtPeriodEnd: true},
    {accountDeleted: true, subscriptionStatus: "canceled", cancelAtPeriodEnd: false},
    {accountDeleted: true, subscriptionStatus: "checkout_failed", cancelAtPeriodEnd: false},
  ]) {
    assert.equal(deletedAccountCallbackNeedsCancellation(value), false);
  }
});

test("blocks account deletion for an unexpired reusable checkout session", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  assert.deepEqual(accountDeletionGuardDecision({
    sessions: [localCheckout()],
    planId: target.planId,
    mode: target.mode,
    now,
  }), {kind: "pending_checkout"});

  // The shared email lock must also block a newly registered Firebase UID;
  // lock ownership is deliberately irrelevant to account deletion safety.
  assert.deepEqual(accountDeletionGuardDecision({
    customerLock: localCheckout({uid: "deleted-user"}),
    planId: target.planId,
    mode: target.mode,
    now,
  }), {kind: "pending_checkout"});
});

test("allows account deletion after checkout expiry or definitive failure", () => {
  const now = Date.parse("2026-08-26T04:10:00.000Z");
  for (const session of [
    localCheckout({expiresAt: "2026-08-26T04:10:00.000Z"}),
    localCheckout({status: "expired", expiresAt: "2026-08-26T04:20:00.000Z"}),
    localCheckout({status: "checkout_failed", expiresAt: "2026-08-26T04:20:00.000Z"}),
    localCheckout({status: "failed", expiresAt: "2026-08-26T04:20:00.000Z"}),
  ]) {
    assert.deepEqual(accountDeletionGuardDecision({
      sessions: [session],
      planId: target.planId,
      mode: target.mode,
      now,
    }), {kind: "safe"});
  }
});

test("blocks account deletion until an abandoned checkout is reconciled", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const creating = localCheckout({
    sessionId: undefined,
    status: "creating",
    leaseExpiresAtMs: now + 60_000,
    expiresAt: undefined,
    checkoutUrl: undefined,
  });
  for (const locks of [
    {customerLock: creating},
    {legacyLocks: [creating]},
  ]) {
    assert.deepEqual(accountDeletionGuardDecision({
      ...locks,
      planId: target.planId,
      mode: target.mode,
      now,
    }), {kind: "pending_checkout"});
    assert.deepEqual(accountDeletionGuardDecision({
      ...locks,
      customerLock: locks.customerLock ? {...locks.customerLock, leaseExpiresAtMs: now} : null,
      legacyLocks: locks.legacyLocks?.map((lock) => ({...lock, leaseExpiresAtMs: now})),
      planId: target.planId,
      mode: target.mode,
      now,
    }), {kind: "safety_hold"});
  }
});

test("keeps uncertain checkout holds until reconciliation and bounds deletion holds", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  for (const status of ["uncertain", "account_deleting", "account_deleted"]) {
    const customerLock = localCheckout({
      uid: "deleted-user",
      sessionId: undefined,
      status,
      safetyHoldUntilMs: now + 24 * 60 * 60 * 1000,
      expiresAt: undefined,
      checkoutUrl: undefined,
    });
    for (const uid of ["deleted-user", "new-user-with-same-email"]) {
      assert.deepEqual(accountDeletionGuardDecision({
        customerLock: {...customerLock, uid},
        planId: target.planId,
        mode: target.mode,
        now,
      }), {kind: "safety_hold"});
      assert.deepEqual(accountDeletionGuardDecision({
        customerLock: {...customerLock, uid, safetyHoldUntilMs: now},
        planId: target.planId,
        mode: target.mode,
        now,
      }), status === "uncertain" ? {kind: "safety_hold"} : {kind: "safe"});
    }
  }
});

test("blocks account deletion while the shared email recovery lease is live", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const recoveryLock = {
    planId: target.planId,
    mode: target.mode,
    status: "recovery_in_progress",
    leaseExpiresAtMs: now + 60_000,
  };
  assert.deepEqual(accountDeletionGuardDecision({
    customerLock: recoveryLock,
    planId: target.planId,
    mode: target.mode,
    now,
  }), {kind: "safety_hold"});
  assert.deepEqual(accountDeletionGuardDecision({
    customerLock: {...recoveryLock, leaseExpiresAtMs: now},
    planId: target.planId,
    mode: target.mode,
    now,
  }), {kind: "safe"});
});

test("fails closed for a legacy pending checkout whose Portaly mode is absent", () => {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  assert.deepEqual(accountDeletionGuardDecision({
    sessions: [localCheckout({mode: undefined})],
    planId: target.planId,
    mode: target.mode,
    now,
  }), {kind: "pending_checkout"});
});

test("selects only the renewable subscription from the three-card portal scenario", () => {
  const subscriptions = [
    remoteSubscription({id: "sub_renewing"}),
    remoteSubscription({id: "sub_canceling_1", cancelAtPeriodEnd: true}),
    remoteSubscription({id: "sub_canceling_2", cancelAtPeriodEnd: true}),
  ];

  assert.deepEqual(selectSubscriptionIdsToCancel(subscriptions, target), ["sub_renewing"]);
});

test("selects past-due subscriptions and ignores canceled subscriptions", () => {
  const subscriptions = [
    remoteSubscription({id: "sub_past_due", status: "past_due"}),
    remoteSubscription({id: "sub_canceled", status: "canceled"}),
  ];

  assert.deepEqual(selectSubscriptionIdsToCancel(subscriptions, target), ["sub_past_due"]);
});

test("normalizes email case and ignores subscriptions for other customers or plans", () => {
  const subscriptions = [
    remoteSubscription({customerEmail: " LEO2601673@GMAIL.COM "}),
    remoteSubscription({id: "sub_other_email", customerEmail: "other@example.com"}),
    remoteSubscription({id: "sub_other_plan", planId: "plan_yearly"}),
  ];

  assert.deepEqual(selectSubscriptionIdsToCancel(subscriptions, target), ["sub_active"]);
});

test("deduplicates a subscription repeated across merged pages", () => {
  const repeated = remoteSubscription({id: "sub_page_boundary", status: "past_due"});

  assert.deepEqual(
    selectSubscriptionIdsToCancel([repeated, {...repeated}], target),
    ["sub_page_boundary"],
  );
});

test("fails closed for malformed in-scope subscriptions", () => {
  for (const [subscription, code] of [
    [null, "SUBSCRIPTION_INVALID"],
    [remoteSubscription({id: ""}), "SUBSCRIPTION_ID_MISSING"],
    [remoteSubscription({status: "unknown"}), "SUBSCRIPTION_STATUS_INVALID"],
    [remoteSubscription({cancelAtPeriodEnd: "false"}), "CANCEL_AT_PERIOD_END_MISSING"],
  ]) {
    assert.throws(
      () => selectSubscriptionIdsToCancel([subscription], target),
      (error) => error.code === code,
    );
  }
});

test("fails closed when a matching subscription conflicts with the API-key mode", () => {
  assert.throws(
    () => selectSubscriptionIdsToCancel([
      remoteSubscription({mode: "test"}),
    ], target),
    (error) => error.code === "SUBSCRIPTION_MODE_MISMATCH",
  );
});
