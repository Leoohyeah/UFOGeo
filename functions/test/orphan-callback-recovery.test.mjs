import assert from "node:assert/strict";
import test from "node:test";

import {
  orphanCallbackRecoveryDecision,
  orphanCheckoutSessionRecord,
} from "../orphan-callback-recovery.mjs";

const planId = "JO5cmDQdqTtb6AkkcnNW";
const payload = {
  event: "creator_subscription.checkout.completed",
  sessionId: "session-orphan-1",
  subscriptionId: "session-orphan-1",
  customerEmail: "Member@Example.com",
  planId,
  mode: "test",
  merchantOrderNumber: "ufogeo-order-1",
  status: "completed",
  metadata: {
    firebaseUid: "firebase-user-1",
    checkoutLeaseId: "lease-1",
  },
};

const lock = {
  uid: "firebase-user-1",
  customerEmail: "member@example.com",
  planId,
  mode: "test",
  status: "uncertain",
  merchantOrderNumber: "ufogeo-order-1",
  checkoutLeaseId: "lease-1",
};

test("recovers an orphan callback only from an exact customer lock", () => {
  const recovery = orphanCallbackRecoveryDecision({payload, lock, expectedMode: "test"});

  assert.deepEqual(recovery, {
    kind: "matched",
    sessionId: "session-orphan-1",
    customerEmail: "member@example.com",
    planId,
    mode: "test",
    merchantOrderNumber: "ufogeo-order-1",
    firebaseUid: "firebase-user-1",
    checkoutLeaseId: "lease-1",
  });
});

test("does not unlock an uncertain checkout by time or accept identity drift", () => {
  const expired = {
    ...lock,
    leaseExpiresAtMs: 0,
    safetyHoldUntilMs: 0,
  };
  assert.equal(
    orphanCallbackRecoveryDecision({payload, lock: expired, expectedMode: "test"}).kind,
    "matched",
  );

  for (const changed of [
    {customerEmail: "other@example.com"},
    {uid: "firebase-user-2"},
    {planId: "other-plan"},
    {mode: "live"},
    {merchantOrderNumber: "other-order"},
    {checkoutLeaseId: "other-lease"},
  ]) {
    assert.equal(
      orphanCallbackRecoveryDecision({payload, lock: {...lock, ...changed}, expectedMode: "test"}).kind,
      "reject",
    );
  }
  assert.equal(
    orphanCallbackRecoveryDecision({payload, lock, expectedMode: "live"}).kind,
    "reject",
  );
});

test("requires all orphan callback identities and preserves failed-checkout semantics", () => {
  for (const field of [
    "sessionId",
    "customerEmail",
    "planId",
    "mode",
    "merchantOrderNumber",
  ]) {
    const changed = {...payload};
    changed[field] = undefined;
    assert.equal(
      orphanCallbackRecoveryDecision({payload: changed, lock, expectedMode: "test"}).kind,
      "reject",
    );
  }
  for (const field of ["firebaseUid", "checkoutLeaseId"]) {
    const changed = {...payload, metadata: {...payload.metadata, [field]: undefined}};
    assert.equal(
      orphanCallbackRecoveryDecision({payload: changed, lock, expectedMode: "test"}).kind,
      "reject",
    );
  }

  const recovery = orphanCallbackRecoveryDecision({payload, lock, expectedMode: "test"});
  const failed = orphanCheckoutSessionRecord({
    payload: {...payload, event: "creator_subscription.checkout.failed", status: "failed"},
    event: "creator_subscription.checkout.failed",
    recovery,
    lockId: "customer-lock-1",
  });
  assert.equal(failed.subscriptionId, undefined);
  assert.equal(failed.reconciliationRequired, true);
  assert.equal(failed.checkoutLockId, "customer-lock-1");
});
