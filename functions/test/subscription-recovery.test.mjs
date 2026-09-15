import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import test from "node:test";

import {checkoutLeaseDecision} from "../checkout-idempotency.mjs";
import {
  RECOVERY_LEASE_MS,
  RECOVERY_LOCK_STATUS,
  executeRecoveryWithLease,
  recoveredSubscriptionState,
  recoveryBindingDecision,
  recoveryLockDecision,
  recoveryLockIsActive,
  recoveryProviderDetailDecision,
  recoveryResponseData,
  recoveryResponseEnvelope,
  selectRecoverableSubscription,
} from "../subscription-recovery.mjs";
import {subscriptionRecoveryOwnershipPlan} from "../subscription-ownership.mjs";
import {subscriptionStateResponse} from "../subscription-response.mjs";

const planId = "JO5cmDQdqTtb6AkkcnNW";
const scope = {
  email: "Member@example.com",
  planId,
  mode: "test",
};

function subscription(overrides = {}) {
  return {
    id: "sub_123",
    customerEmail: "member@example.com",
    planId,
    mode: "test",
    status: "active",
    cancelAtPeriodEnd: false,
    ...overrides,
  };
}

function detail(overrides = {}) {
  return {
    data: subscription({
      sessionId: "sub_123",
      ...overrides,
    }),
  };
}

function errorCode(fn, code) {
  assert.throws(fn, (error) => error?.code === code);
}

function deletedAccountCancellation(overrides = {}) {
  return {
    id: "cancel-compensation-1",
    subscriptionId: "sub_123",
    planId,
    mode: "test",
    accountDeletionId: "deletion-1",
    status: "pending",
    ...overrides,
  };
}

test("selects the sole active or past_due subscription in the server scope", () => {
  const active = selectRecoverableSubscription([
    subscription({status: "canceled"}),
    subscription({id: "sub_past_due", status: "past_due"}),
  ], scope);
  assert.equal(active.id, "sub_past_due");

  const pastDue = selectRecoverableSubscription([
    subscription({status: "past_due"}),
  ], scope);
  assert.equal(pastDue.status, "past_due");
});

test("ignores well-formed records outside email, plan, or mode scope", () => {
  assert.equal(selectRecoverableSubscription([
    subscription({customerEmail: "other@example.com"}),
    subscription({id: "sub_other_plan", planId: "other-plan"}),
    subscription({id: "sub_live", mode: "live"}),
  ], scope), null);
});

test("fails closed when more than one scoped subscription is recoverable", () => {
  errorCode(() => selectRecoverableSubscription([
    subscription(),
    subscription({id: "sub_456"}),
  ], scope), "SUBSCRIPTION_RECOVERY_AMBIGUOUS");
});

test("collapses identical page duplicates but rejects conflicting duplicate state", () => {
  const selected = selectRecoverableSubscription([
    subscription(),
    subscription(),
  ], scope);
  assert.equal(selected.id, "sub_123");

  errorCode(() => selectRecoverableSubscription([
    subscription(),
    subscription({status: "past_due"}),
  ], scope), "RECOVERY_SUBSCRIPTION_DUPLICATE_CONFLICT");
});

test("fails closed for malformed in-scope records instead of treating them as absent", () => {
  errorCode(() => selectRecoverableSubscription([
    subscription({mode: undefined}),
  ], scope), "PORTALY_SUBSCRIPTION_MODE_MISSING");
  errorCode(() => selectRecoverableSubscription([
    subscription({customerEmail: undefined}),
  ], scope), "PORTALY_SUBSCRIPTION_EMAIL_MISSING");
  errorCode(() => selectRecoverableSubscription([
    subscription({status: "checkout_ready"}),
  ], scope), "PORTALY_SUBSCRIPTION_STATUS_INVALID");
});

test("requires a second authoritative GET response to match required identity fields and validates optional email", () => {
  const result = recoveredSubscriptionState({
    remote: detail(),
    subscriptionId: "sub_123",
    ...scope,
  });
  assert.equal(result.recoverable, true);
  assert.equal(result.state.subscriptionId, "sub_123");
  assert.equal(result.state.proActive, true);

  const detailWithoutEmail = detail();
  delete detailWithoutEmail.data.customerEmail;
  const withoutEmail = recoveredSubscriptionState({
    remote: detailWithoutEmail,
    subscriptionId: "sub_123",
    ...scope,
  });
  assert.equal(withoutEmail.recoverable, true);

  errorCode(() => recoveredSubscriptionState({
    remote: detail({customerEmail: "other@example.com"}),
    subscriptionId: "sub_123",
    ...scope,
  }), "RECOVERY_PROVIDER_EMAIL_MISMATCH");
  errorCode(() => recoveredSubscriptionState({
    remote: detail({id: "sub_other"}),
    subscriptionId: "sub_123",
    ...scope,
  }), "SUBSCRIPTION_ID_MISMATCH");
  errorCode(() => recoveredSubscriptionState({
    remote: detail({planId: "other-plan"}),
    subscriptionId: "sub_123",
    ...scope,
  }), "SUBSCRIPTION_PLAN_MISMATCH");
  errorCode(() => recoveredSubscriptionState({
    remote: detail({mode: "live"}),
    subscriptionId: "sub_123",
    ...scope,
  }), "SUBSCRIPTION_MODE_MISMATCH");
  errorCode(() => recoveredSubscriptionState({
    remote: detail({sessionId: "sub_other"}),
    subscriptionId: "sub_123",
    ...scope,
  }), "RECOVERY_PROVIDER_SESSION_MISMATCH");
});

test("keeps recovery responses clean when an existing user loses optional detail fields", () => {
  const current = {
    mode: "test",
    planId,
    proActive: true,
    subscriptionStatus: "active",
    subscriptionId: "sub_old",
    currentCheckoutSessionId: "sub_old",
    cancelAtPeriodEnd: false,
    nextBillingAt: "2026-10-01T00:00:00.000Z",
    cancelEffectiveAt: "2026-10-01T00:00:00.000Z",
    failureCount: 3,
  };
  const detailWithoutOptionalFields = detail();
  delete detailWithoutOptionalFields.data.customerEmail;
  const recovered = recoveredSubscriptionState({
    remote: detailWithoutOptionalFields,
    subscriptionId: "sub_123",
    ...scope,
  });
  const responseData = recoveryResponseData(current, recovered.state, {planId});
  const value = subscriptionStateResponse({
    uid: "firebase-uid",
    email: scope.email,
    emailVerified: true,
    data: responseData,
    expectedMode: scope.mode,
    fallbackPlanId: planId,
  });

  assert.equal(value.proActive, true);
  assert.equal(value.subscriptionStatus, "active");
  assert.equal(value.subscriptionId, "sub_123");
  assert.equal(value.planId, planId);
  assert.equal(Object.hasOwn(responseData, "nextBillingAt"), false);
  assert.equal(Object.hasOwn(responseData, "cancelEffectiveAt"), false);
  assert.equal(Object.hasOwn(responseData, "failureCount"), false);
  assert.equal(Object.values(responseData).some((entry) =>
    typeof entry === "symbol" || entry?.constructor?.name === "DeleteTransform"), false);
});

test("accepts past_due recovery but not canceled recovery", () => {
  const result = recoveredSubscriptionState({
    remote: detail({status: "past_due"}),
    subscriptionId: "sub_123",
    ...scope,
  });
  assert.equal(result.recoverable, true);
  assert.equal(result.state.subscriptionStatus, "past_due");

  const canceled = recoveredSubscriptionState({
    remote: detail({status: "canceled"}),
    subscriptionId: "sub_123",
    ...scope,
  });
  assert.equal(canceled.recoverable, false);
  assert.equal(canceled.state.proActive, false);

  const canceling = recoveredSubscriptionState({
    remote: detail({status: "active", cancelAtPeriodEnd: true}),
    subscriptionId: "sub_123",
    ...scope,
  });
  assert.equal(canceling.recoverable, true);
  assert.equal(canceling.state.subscriptionStatus, "cancel_requested");
});

test("maps a canceled detail race to not_found instead of a recovery conflict", () => {
  assert.deepEqual(recoveryProviderDetailDecision({
    recoverable: false,
    subscriptionStatus: "canceled",
  }), {kind: "not_found"});
  assert.deepEqual(recoveryProviderDetailDecision({
    recoverable: false,
    subscriptionStatus: "active",
  }), {kind: "state_changed"});
  assert.deepEqual(recoveryProviderDetailDecision({
    recoverable: true,
    subscriptionStatus: "cancel_requested",
  }), {kind: "recoverable"});
});

test("uses the canonical recovery success envelope for every outcome", () => {
  const value = {subscriptionStatus: "none", proActive: false};
  for (const status of ["recovered", "already_bound", "not_found"]) {
    assert.deepEqual(recoveryResponseEnvelope(value, status), {
      value,
      recovery: {status},
    });
  }
  errorCode(() => recoveryResponseEnvelope(value, "unknown"), "RECOVERY_RESPONSE_INVALID");
  errorCode(() => recoveryResponseEnvelope([], "not_found"), "RECOVERY_RESPONSE_INVALID");
});

test("reserves the recovery lease before discovery and releases it on no match", async () => {
  const order = [];
  let recoveryLeaseActive = false;
  let checkoutBlocked = false;
  const result = await executeRecoveryWithLease({
    reserve: async () => {
      order.push("reserve");
      recoveryLeaseActive = true;
      return {lock: {
        planId,
        mode: "test",
        status: RECOVERY_LOCK_STATUS,
        leaseExpiresAtMs: Date.now() + RECOVERY_LEASE_MS,
      }};
    },
    discover: async ({reservation}) => {
      order.push("discover");
      checkoutBlocked = checkoutLeaseDecision({
        subscription: {},
        emailLock: reservation.lock,
        uid: "new-user",
        planId,
        mode: "test",
      }).kind === "in_progress";
      return null;
    },
    finalize: async () => {
      order.push("finalize");
      throw new Error("finalize must not run for no-match");
    },
    release: async () => {
      order.push("release");
      recoveryLeaseActive = false;
    },
  });
  assert.deepEqual(order, ["reserve", "discover", "release"]);
  assert.equal(checkoutBlocked, true);
  assert.equal(recoveryLeaseActive, false);
  assert.equal(result.status, "not_found");
  assert.equal(result.value, null);
});

test("persists the configured plan so a repeated recovery is already_bound", async () => {
  const context = {candidateId: "sub_123", planId, mode: "test"};
  let persistedUser = {};
  const first = await executeRecoveryWithLease({
    reserve: async () => ({lock: "first"}),
    discover: async () => ({id: "sub_123"}),
    finalize: async () => {
      const state = {
        mode: "test",
        planId,
        proActive: true,
        subscriptionStatus: "active",
        subscriptionId: "sub_123",
        currentCheckoutSessionId: "sub_123",
        cancelAtPeriodEnd: false,
      };
      persistedUser = {...state};
      return {status: "recovered", value: state};
    },
    release: async () => {
      throw new Error("successful recovery owns final lock deletion");
    },
  });
  assert.equal(first.status, "recovered");
  assert.equal(persistedUser.planId, planId);

  const binding = recoveryBindingDecision(persistedUser, context);
  assert.deepEqual(binding, {kind: "already_bound"});
  const second = await executeRecoveryWithLease({
    reserve: async () => ({lock: "second"}),
    discover: async () => ({id: "sub_123"}),
    finalize: async () => ({status: binding.kind, value: persistedUser}),
    release: async () => {
      throw new Error("idempotent recovery owns final lock deletion");
    },
  });
  assert.deepEqual(recoveryResponseEnvelope(second.value, second.status), {
    value: persistedUser,
    recovery: {status: "already_bound"},
  });
});

test("releases the recovery lease when provider discovery fails", async () => {
  const order = [];
  await assert.rejects(
    executeRecoveryWithLease({
      reserve: async () => {
        order.push("reserve");
        return {lock: "provider-failure"};
      },
      discover: async () => {
        order.push("discover");
        throw new Error("Portaly unavailable");
      },
      finalize: async () => {
        throw new Error("finalize must not run after discovery failure");
      },
      release: async () => {
        order.push("release");
      },
    }),
    /Portaly unavailable/,
  );
  assert.deepEqual(order, ["reserve", "discover", "release"]);
});

test("recovers past_due even when cancellation is also requested", () => {
  const selected = selectRecoverableSubscription([
    subscription({status: "past_due", cancelAtPeriodEnd: true}),
  ], scope);
  assert.equal(selected.status, "past_due");
  const recovered = recoveredSubscriptionState({
    remote: detail({status: "past_due", cancelAtPeriodEnd: true}),
    subscriptionId: "sub_123",
    ...scope,
  });
  assert.equal(recovered.recoverable, true);
  assert.equal(recovered.state.subscriptionStatus, "past_due");
  assert.equal(recovered.state.proActive, true);
  assert.equal(recovered.state.cancelAtPeriodEnd, true);
});

test("does not overwrite an existing active binding for a different subscription", () => {
  const current = {
    mode: "test",
    planId,
    proActive: true,
    subscriptionStatus: "active",
    subscriptionId: "sub_existing",
    currentCheckoutSessionId: "sub_existing",
    cancelAtPeriodEnd: false,
  };
  assert.deepEqual(recoveryBindingDecision(current, {
    candidateId: "sub_existing",
    planId,
    mode: "test",
  }), {kind: "already_bound"});
  assert.deepEqual(recoveryBindingDecision(current, {
    candidateId: "sub_other",
    planId,
    mode: "test",
  }), {kind: "conflict", code: "RECOVERY_EXISTING_BINDING_CONFLICT"});
});

test("does not steal a pending checkout or mutate malformed local state", () => {
  const context = {candidateId: "sub_123", planId, mode: "test"};
  assert.deepEqual(recoveryBindingDecision({
    subscriptionStatus: "checkout_ready",
    currentCheckoutSessionId: "checkout_1",
    proActive: false,
    cancelAtPeriodEnd: false,
  }, context), {kind: "conflict", code: "RECOVERY_PENDING_CHECKOUT"});
  assert.deepEqual(recoveryBindingDecision({
    subscriptionStatus: "active",
    subscriptionId: "bad/id",
    currentCheckoutSessionId: "bad/id",
    proActive: true,
    cancelAtPeriodEnd: false,
  }, context), {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"});
});

test("recovery lease serializes recovery and checkout races", () => {
  const now = Date.parse("2026-09-07T00:00:00.000Z");
  const active = {
    status: RECOVERY_LOCK_STATUS,
    planId,
    mode: "test",
    leaseExpiresAtMs: now + RECOVERY_LEASE_MS,
  };
  assert.deepEqual(recoveryLockDecision(active, {planId, mode: "test", now}), {
    kind: "in_progress",
    leaseExpiresAtMs: now + RECOVERY_LEASE_MS,
  });
  assert.equal(recoveryLockIsActive(active, {now}), true);
  assert.deepEqual(recoveryLockDecision(active, {
    planId,
    mode: "test",
    now: now + RECOVERY_LEASE_MS,
  }), {kind: "acquire"});
  assert.equal(recoveryLockIsActive(active, {now: now + RECOVERY_LEASE_MS}), false);
});

test("blocks recovery while checkout is creating, pending, or uncertain", () => {
  const now = Date.parse("2026-09-07T00:00:00.000Z");
  for (const lock of [
    {status: "creating", leaseExpiresAtMs: now + 10_000, safetyHoldUntilMs: now + 10_000},
    {status: "pending", expiresAt: new Date(now + 10_000).toISOString()},
    {status: "uncertain"},
  ]) {
    const result = recoveryLockDecision({...lock, planId, mode: "test"}, {
      planId,
      mode: "test",
      now,
    });
    assert.equal(result.kind, "conflict");
  }
});

test("rejects invalid or cross-environment recovery locks", () => {
  const now = Date.parse("2026-09-07T00:00:00.000Z");
  assert.deepEqual(recoveryLockDecision({
    status: RECOVERY_LOCK_STATUS,
    planId,
    mode: "live",
    leaseExpiresAtMs: now + 1_000,
  }, {planId, mode: "test", now}), {
    kind: "conflict",
    code: "RECOVERY_LOCK_SCOPE_CONFLICT",
  });
  assert.deepEqual(recoveryLockDecision({
    status: RECOVERY_LOCK_STATUS,
    planId,
    mode: "test",
  }, {planId, mode: "test", now}), {
    kind: "conflict",
    code: "RECOVERY_LOCK_INVALID",
  });
});

test("allows only a complete account-deletion tombstone to enter provider-backed reclaim", () => {
  const now = Date.parse("2026-09-07T00:00:00.000Z");
  assert.deepEqual(recoveryLockDecision({
    status: "account_deleted",
    accountUidHash: "old-uid-hash",
    safetyHoldUntilMs: now - 1,
    planId,
    mode: "test",
  }, {planId, mode: "test", now}), {
    kind: "reclaimable_tombstone",
    accountUidHash: "old-uid-hash",
  });
  for (const lock of [
    {status: "account_deleted", accountUidHash: "old-uid-hash", planId, mode: "test"},
    {status: "account_deleted", accountUidHash: "old-uid-hash", safetyHoldUntilMs: now - 1, uid: "old-user", planId, mode: "test"},
    {status: "account_deleting", accountUidHash: "old-uid-hash", planId, mode: "test"},
  ]) {
    assert.deepEqual(recoveryLockDecision(lock, {planId, mode: "test", now}), {
      kind: "conflict",
      code: lock.status === "account_deleted" ? "ACCOUNT_DELETION_TOMBSTONE_INVALID" :
        "ACCOUNT_DELETION_IN_PROGRESS",
    });
  }
  assert.deepEqual(recoveryLockDecision({
    status: "account_deleted",
    accountUidHash: "old-uid-hash",
    safetyHoldUntilMs: now + 1,
    planId,
    mode: "test",
  }, {planId, mode: "test", now}), {
    kind: "inspection_only_tombstone",
    accountUidHash: "old-uid-hash",
  });
});

test("blocks deleted-account reclaim until cancellation compensation is complete", () => {
  const deletedSession = {
    uid: "deleted-uid",
    accountDeleted: true,
    sessionId: "sub_123",
    subscriptionId: "sub_123",
    customerEmail: scope.email,
    planId,
    mode: "test",
  };
  const deletedAccountUidHash = createHash("sha256")
    .update(deletedSession.uid)
    .digest("hex");
  const base = {
    ownerEntries: [],
    refundMarkerEntries: [],
    uid: "new-uid",
    email: scope.email,
    planId,
    mode: "test",
    subscriptionId: deletedSession.subscriptionId,
    deletedAccountUidHash,
    allowDeletedOwnership: deletedSession.accountDeleted,
  };

  for (const status of ["pending", "processing", "retry_pending"]) {
    assert.deepEqual(subscriptionRecoveryOwnershipPlan({
      ...base,
      compensationEntries: [{data: deletedAccountCancellation({status})}],
    }), {
      kind: "conflict",
      code: "SUBSCRIPTION_RECOVERY_SAFETY_HOLD",
    });
  }

  const completed = subscriptionRecoveryOwnershipPlan({
    ...base,
    compensationEntries: [{data: deletedAccountCancellation({status: "completed"})}],
    // A refund marker is a separate reconciliation workflow and remains
    // eligible for the existing deleted-UID rebind after cancellation safety.
    refundMarkerEntries: [{data: {
      uid: deletedSession.uid,
      customerEmail: scope.email,
      planId,
      mode: "test",
      sessionId: deletedSession.subscriptionId,
      subscriptionId: deletedSession.subscriptionId,
      status: "pending",
    }}],
  });
  assert.equal(completed.kind, "allow");
  assert.deepEqual(completed.ownerDecision, {kind: "claim"});
  assert.deepEqual(completed.markerDecisions, [{
    kind: "rebind",
    uid: "new-uid",
    email: scope.email,
  }]);
});
