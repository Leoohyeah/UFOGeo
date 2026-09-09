import assert from "node:assert/strict";
import test from "node:test";

import {
  reconcileSubscription,
  reconciledSubscriptionState,
  SubscriptionReconciliationError,
  subscriptionStateMatchesPatch,
  subscriptionVerificationTimestamp,
} from "../subscription-reconciliation.mjs";

const subscription = {
  id: "sub_123",
  profileId: "profile_123",
  planId: "plan_pro",
  mode: "test",
  billingPeriod: "monthly",
  status: "active",
  cancelAtPeriodEnd: false,
  nextBillingAt: "2026-09-26T00:00:00.000Z",
};

function remote(overrides = {}) {
  return {data: {...subscription, ...overrides}};
}

function errorCode(fn, code) {
  assert.throws(
    fn,
    (error) => error instanceof SubscriptionReconciliationError && error.code === code,
  );
}

test("maps an active subscription to an active Pro entitlement", () => {
  assert.deepEqual(
    reconciledSubscriptionState({
      current: {subscriptionId: "sub_123", mode: "test"},
      remote: remote(),
      expectedSubscriptionId: "sub_123",
      expectedMode: "test",
      expectedPlanId: "plan_pro",
    }),
    {
      subscriptionId: "sub_123",
      currentCheckoutSessionId: "sub_123",
      mode: "test",
      proActive: true,
      subscriptionStatus: "active",
      cancelAtPeriodEnd: false,
      nextBillingAt: "2026-09-26T00:00:00.000Z",
    },
  );
});

test("maps an active subscription pending cancellation to cancel_requested while retaining Pro", () => {
  const value = reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "test"},
    remote: remote({cancelAtPeriodEnd: true, cancelEffectiveAt: "2026-09-26T00:00:00.000Z"}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });

  assert.equal(value.proActive, true);
  assert.equal(value.subscriptionStatus, "cancel_requested");
  assert.equal(value.cancelAtPeriodEnd, true);
  assert.equal(value.cancelEffectiveAt, "2026-09-26T00:00:00.000Z");
});

test("keeps explicit nulls so a resumed subscription clears stale cancellation dates", () => {
  const value = reconciledSubscriptionState({
    current: {
      subscriptionId: "sub_123",
      mode: "test",
      cancelAtPeriodEnd: true,
      cancelEffectiveAt: "2026-09-26T00:00:00.000Z",
    },
    remote: remote({cancelAtPeriodEnd: false, cancelEffectiveAt: null}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });

  assert.equal(value.proActive, true);
  assert.equal(value.subscriptionStatus, "active");
  assert.equal(value.cancelEffectiveAt, null);
});

test("reconciles two cancel-and-resume cycles for the same subscription", () => {
  const firstCancel = reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "test"},
    remote: remote({
      cancelAtPeriodEnd: true,
      cancelEffectiveAt: "2026-09-26T00:00:00.000Z",
    }),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });
  const firstResume = reconciledSubscriptionState({
    current: {...firstCancel, cancelEffectiveAt: "2026-09-26T00:00:00.000Z"},
    remote: remote({cancelAtPeriodEnd: false, cancelEffectiveAt: null}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });
  const secondCancel = reconciledSubscriptionState({
    current: {...firstResume},
    remote: remote({
      cancelAtPeriodEnd: true,
      cancelEffectiveAt: "2026-10-26T00:00:00.000Z",
    }),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });
  const secondResume = reconciledSubscriptionState({
    current: {...secondCancel},
    remote: remote({cancelAtPeriodEnd: false, cancelEffectiveAt: null}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });

  assert.equal(firstCancel.subscriptionStatus, "cancel_requested");
  assert.equal(firstResume.subscriptionStatus, "active");
  assert.equal(secondCancel.subscriptionStatus, "cancel_requested");
  assert.equal(secondResume.subscriptionStatus, "active");
  assert.equal(secondResume.cancelAtPeriodEnd, false);
  assert.equal(secondResume.cancelEffectiveAt, null);
});

test("accepts a callback-applied resume state after the Portaly GET race", () => {
  const patch = reconciledSubscriptionState({
    current: {
      subscriptionId: "sub_123",
      currentCheckoutSessionId: "sub_123",
      mode: "test",
      subscriptionStatus: "cancel_requested",
      proActive: true,
      cancelAtPeriodEnd: true,
    },
    remote: remote({cancelAtPeriodEnd: false, cancelEffectiveAt: null}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });

  assert.equal(subscriptionStateMatchesPatch({
    subscriptionId: "sub_123",
    currentCheckoutSessionId: "sub_123",
    mode: "test",
    subscriptionStatus: "active",
    proActive: true,
    cancelAtPeriodEnd: false,
    lastCallbackAtMs: Date.parse("2026-09-01T00:00:01.000Z"),
  }, patch), true);
  assert.equal(subscriptionStateMatchesPatch({
    subscriptionId: "sub_123",
    currentCheckoutSessionId: "sub_123",
    mode: "test",
    subscriptionStatus: "canceled",
    proActive: false,
    cancelAtPeriodEnd: false,
  }, patch), false);
});

test("maps a past_due renewal to Pro grace access", () => {
  const value = reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "test"},
    remote: remote({status: "past_due"}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });

  assert.deepEqual(
    {
      proActive: value.proActive,
      subscriptionStatus: value.subscriptionStatus,
      cancelAtPeriodEnd: value.cancelAtPeriodEnd,
    },
    {proActive: true, subscriptionStatus: "past_due", cancelAtPeriodEnd: false},
  );
});

test("maps a fully canceled subscription to a disabled Pro entitlement", () => {
  const value = reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "test"},
    remote: remote({status: "canceled", cancelAtPeriodEnd: false, canceledAt: "2026-09-26T00:00:00.000Z"}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });

  assert.equal(value.subscriptionId, "sub_123");
  assert.equal(value.mode, "test");
  assert.equal(value.proActive, false);
  assert.equal(value.subscriptionStatus, "canceled");
  assert.equal(value.cancelAtPeriodEnd, false);
  assert.equal(value.canceledAt, "2026-09-26T00:00:00.000Z");
});

test("accepts a direct subscription object as well as the Portaly data wrapper", () => {
  const value = reconciledSubscriptionState({
    current: {},
    remote: {...subscription},
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  });
  assert.equal(value.subscriptionId, "sub_123");
  assert.equal(value.mode, "test");
});

test("rejects a different requested subscription before producing a patch", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "test"},
    remote: remote({id: "sub_other"}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  }), "SUBSCRIPTION_ID_MISMATCH");
});

test("rejects a different current subscription even when no expected id is supplied", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {subscriptionId: "sub_current", mode: "test"},
    remote: remote({id: "sub_other"}),
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  }), "SUBSCRIPTION_ID_MISMATCH");
});

test("uses currentCheckoutSessionId as a guard after a failed newer checkout", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {currentCheckoutSessionId: "session_new", mode: "test"},
    remote: remote({id: "session_old"}),
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  }), "SUBSCRIPTION_ID_MISMATCH");
});

test("rejects mode mismatch with the API-key environment", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "test"},
    remote: remote({mode: "live"}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  }), "SUBSCRIPTION_MODE_MISMATCH");
});

test("rejects mode mismatch with the current user record", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "live"},
    remote: remote(),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  }), "SUBSCRIPTION_MODE_MISMATCH");
});

test("rejects a Portaly subscription from a different plan", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "test"},
    remote: remote({planId: "plan_other"}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  }), "SUBSCRIPTION_PLAN_MISMATCH");
});

test("rejects a current user plan that differs from the configured plan", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {subscriptionId: "sub_123", mode: "test", planId: "plan_other"},
    remote: remote(),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  }), "CURRENT_PLAN_ID_MISMATCH");
});

test("rejects invalid expected mode rather than silently mixing environments", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {},
    remote: remote(),
    expectedSubscriptionId: "sub_123",
    expectedMode: "sandbox",
    expectedPlanId: "plan_pro",
  }), "EXPECTED_MODE_INVALID");
});

test("rejects missing or malformed identity and state fields", () => {
  const cases = [
    [remote({id: undefined}), "SUBSCRIPTION_ID_MISSING"],
    [remote({mode: undefined}), "SUBSCRIPTION_MODE_MISSING"],
    [remote({status: undefined}), "SUBSCRIPTION_STATUS_MISSING"],
    [remote({status: "paused"}), "SUBSCRIPTION_STATUS_INVALID"],
    [remote({cancelAtPeriodEnd: undefined}), "CANCEL_AT_PERIOD_END_MISSING"],
    [remote({cancelAtPeriodEnd: "false"}), "CANCEL_AT_PERIOD_END_MISSING"],
  ];

  for (const [value, code] of cases) {
    errorCode(() => reconciledSubscriptionState({
      current: {},
      remote: value,
      expectedSubscriptionId: "sub_123",
      expectedMode: "test",
      expectedPlanId: "plan_pro",
    }), code);
  }
});

test("rejects contradictory canceled and cancel-at-period-end state", () => {
  errorCode(() => reconciledSubscriptionState({
    current: {},
    remote: remote({status: "canceled", cancelAtPeriodEnd: true}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
  }), "SUBSCRIPTION_STATE_INVALID");
});

test("returns user, session, and audit patches through the API adapter", () => {
  const value = reconcileSubscription({
    currentUser: {subscriptionId: "sub_123", mode: "test"},
    subscription: remote({cancelAtPeriodEnd: true}),
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
    now: "2026-08-29T00:00:00.000Z",
  });

  assert.equal(value.userPatch.subscriptionStatus, "cancel_requested");
  assert.equal(value.sessionPatch.status, "cancel_requested");
  assert.equal(value.sessionPatch.subscriptionId, "sub_123");
  assert.equal(value.audit.type, "subscription_reconciliation");
  assert.equal(value.audit.reconciledAtMs, Date.parse("2026-08-29T00:00:00.000Z"));
});

test("repeating the same Portaly snapshot is an idempotent reconciliation", () => {
  const currentUser = {
    subscriptionId: "sub_123",
    currentCheckoutSessionId: "sub_123",
    mode: "test",
    subscriptionStatus: "active",
    proActive: true,
    cancelAtPeriodEnd: false,
  };
  const remoteSnapshot = remote({
    lastChargedAt: "2026-08-26T04:00:00.000Z",
    lastPaymentReference: "txn_renewal_1",
  });
  const reconciledAt = "2026-08-29T00:00:00.000Z";
  const first = reconcileSubscription({
    currentUser,
    subscription: remoteSnapshot,
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
    now: reconciledAt,
  });
  const persistedUser = {...currentUser, ...first.userPatch};
  const second = reconcileSubscription({
    currentUser: persistedUser,
    subscription: remoteSnapshot,
    expectedSubscriptionId: "sub_123",
    expectedMode: "test",
    expectedPlanId: "plan_pro",
    now: reconciledAt,
  });

  assert.deepEqual(second, first);
  assert.deepEqual(currentUser, {
    subscriptionId: "sub_123",
    currentCheckoutSessionId: "sub_123",
    mode: "test",
    subscriptionStatus: "active",
    proActive: true,
    cancelAtPeriodEnd: false,
  });
});

test("does not accept an invalid reconciliation timestamp", () => {
  assert.throws(
    () => reconcileSubscription({
      currentUser: {subscriptionId: "sub_123", mode: "test"},
      subscription: remote(),
      expectedSubscriptionId: "sub_123",
      expectedMode: "test",
      expectedPlanId: "plan_pro",
      now: "not-a-date",
    }),
    (error) => error instanceof SubscriptionReconciliationError &&
      error.code === "RECONCILIATION_TIME_INVALID",
  );
});

test("returns only the latest real callback or reconciliation timestamp", () => {
  assert.equal(subscriptionVerificationTimestamp({}), null);
  assert.equal(subscriptionVerificationTimestamp({lastVerifiedAt: "2099-01-01T00:00:00.000Z"}), null);
  assert.equal(
    subscriptionVerificationTimestamp({
      lastCallbackAtMs: Date.parse("2026-08-29T00:00:00.000Z"),
      lastReconciledAtMs: Date.parse("2026-08-30T00:00:00.000Z"),
    }),
    "2026-08-30T00:00:00.000Z",
  );
});
