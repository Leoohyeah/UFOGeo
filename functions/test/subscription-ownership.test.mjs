import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import test from "node:test";

import {
  refundMarkerOwnershipDecision,
  subscriptionOwnerQueryEntry,
  subscriptionOwnerDecision,
  subscriptionRecoveryOwnershipTransaction,
} from "../subscription-ownership.mjs";

const context = {
  uid: "new-uid",
  email: "Member@example.com",
  planId: "plan_monthly",
  mode: "live",
  subscriptionId: "sub_1",
};

function owner(overrides = {}) {
  return {
    uid: "new-uid",
    email: "member@example.com",
    planId: "plan_monthly",
    mode: "live",
    subscriptionStatus: "active",
    subscriptionId: "sub_1",
    currentCheckoutSessionId: "sub_1",
    ...overrides,
  };
}

function refundMarker(overrides = {}) {
  return {
    uid: "old-uid",
    customerEmail: "member@example.com",
    planId: "plan_monthly",
    mode: "live",
    sessionId: "sub_1",
    subscriptionId: "sub_1",
    status: "pending",
    ...overrides,
  };
}

test("claims an unowned subscription and accepts only the current UID owner", () => {
  assert.deepEqual(subscriptionOwnerDecision([], context), {kind: "claim"});
  assert.deepEqual(subscriptionOwnerDecision([
    {data: owner(), matchedField: "subscriptionId"},
  ], context), {kind: "already_bound", uid: "new-uid"});
  assert.deepEqual(subscriptionOwnerDecision([
    {data: owner({uid: "old-uid"}), matchedField: "currentCheckoutSessionId"},
  ], context), {kind: "conflict", code: "RECOVERY_EXISTING_BINDING_CONFLICT"});
});

test("uses the users document id as owner authority over a historical uid field", () => {
  const currentOwner = subscriptionOwnerQueryEntry({
    id: "new-uid",
    data: owner({uid: "old-uid"}),
    matchedField: "subscriptionId",
  });
  assert.equal(currentOwner.data.uid, "new-uid");
  assert.deepEqual(subscriptionOwnerDecision([currentOwner], context), {
    kind: "already_bound",
    uid: "new-uid",
  });

  const oldOwner = subscriptionOwnerQueryEntry({
    id: "old-uid",
    data: owner({uid: "new-uid"}),
    matchedField: "subscriptionId",
  });
  assert.deepEqual(subscriptionOwnerDecision([oldOwner], context), {
    kind: "conflict",
    code: "RECOVERY_EXISTING_BINDING_CONFLICT",
  });
});

test("fails closed for malformed, deleted, or conflicting owner records", () => {
  for (const [record, code] of [
    [owner({uid: undefined}), "RECOVERY_OWNER_STATE_INVALID"],
    [owner({accountDeleted: true}), "RECOVERY_OWNER_STATE_CONFLICT"],
    [owner({email: "other@example.com"}), "RECOVERY_OWNER_SCOPE_CONFLICT"],
    [owner({subscriptionStatus: "unknown"}), "RECOVERY_OWNER_STATE_INVALID"],
  ]) {
    assert.deepEqual(subscriptionOwnerDecision([
      {data: record, matchedField: "subscriptionId"},
    ], context), {kind: "conflict", code});
  }
  assert.deepEqual(subscriptionOwnerDecision([
    {data: owner(), matchedField: "subscriptionId"},
    {data: owner({subscriptionStatus: "past_due"}), matchedField: "currentCheckoutSessionId"},
  ], context), {kind: "conflict", code: "RECOVERY_OWNER_STATE_CONFLICT"});
});

test("rebinds a deleted UID refund marker only with the tombstone hash", () => {
  const oldUidHash = createHash("sha256").update("old-uid").digest("hex");
  assert.deepEqual(refundMarkerOwnershipDecision({
    marker: refundMarker(),
    currentUid: "new-uid",
    currentEmail: context.email,
    planId: context.planId,
    mode: context.mode,
    subscriptionId: context.subscriptionId,
    deletedAccountUidHash: oldUidHash,
    allowDeletedOwnership: true,
  }), {kind: "rebind", uid: "new-uid", email: context.email});

  assert.deepEqual(refundMarkerOwnershipDecision({
    marker: refundMarker(),
    currentUid: "new-uid",
    currentEmail: context.email,
    planId: context.planId,
    mode: context.mode,
    subscriptionId: context.subscriptionId,
    deletedAccountUidHash: "wrong-hash",
    allowDeletedOwnership: true,
  }), {kind: "conflict", code: "RECOVERY_REFUND_MARKER_OWNERSHIP_CONFLICT"});
});

test("does not rebind a marker owned by another live UID and preserves completion", () => {
  const base = {
    currentUid: "new-uid",
    currentEmail: context.email,
    planId: context.planId,
    mode: context.mode,
    subscriptionId: context.subscriptionId,
  };
  assert.deepEqual(refundMarkerOwnershipDecision({
    marker: refundMarker(),
    ...base,
  }), {kind: "conflict", code: "RECOVERY_REFUND_MARKER_OWNERSHIP_CONFLICT"});
  assert.deepEqual(refundMarkerOwnershipDecision({
    marker: refundMarker({uid: "new-uid", status: "completed"}),
    ...base,
  }), {kind: "completed"});
});

test("finalize transaction blocks stale owners and atomically reclaims refund markers", () => {
  const oldUidHash = createHash("sha256").update("old-uid").digest("hex");
  const staleWrites = [];
  const staleOwnerPlan = subscriptionRecoveryOwnershipTransaction({
    ownerEntries: [subscriptionOwnerQueryEntry({
      id: "old-uid",
      data: owner({uid: "new-uid"}),
      matchedField: "subscriptionId",
    })],
    refundMarkerEntries: [{data: refundMarker()}],
    ...context,
    deletedAccountUidHash: oldUidHash,
    allowDeletedOwnership: true,
    writeRefundMarker: (...args) => staleWrites.push(args),
  });
  assert.deepEqual(staleOwnerPlan, {
    kind: "conflict",
    code: "RECOVERY_EXISTING_BINDING_CONFLICT",
  });
  assert.equal(staleWrites.length, 0);

  const marker = {id: "marker-1", data: refundMarker()};
  const reclaimWrites = [];
  const reclaimPlan = subscriptionRecoveryOwnershipTransaction({
    ownerEntries: [],
    refundMarkerEntries: [marker],
    ...context,
    deletedAccountUidHash: oldUidHash,
    allowDeletedOwnership: true,
    writeRefundMarker: (entry, decision) => reclaimWrites.push({entry, decision}),
  });
  assert.equal(reclaimPlan.kind, "allow");
  assert.deepEqual(reclaimPlan.markerDecisions, [
    {kind: "rebind", uid: "new-uid", email: context.email},
  ]);
  assert.deepEqual(reclaimWrites, [{
    entry: marker,
    decision: {kind: "rebind", uid: "new-uid", email: context.email},
  }]);

  const raceWrites = [];
  const racedMarker = subscriptionRecoveryOwnershipTransaction({
    ownerEntries: [],
    refundMarkerEntries: [{data: refundMarker({uid: "live-uid"})}],
    ...context,
    deletedAccountUidHash: oldUidHash,
    allowDeletedOwnership: true,
    writeRefundMarker: (...args) => raceWrites.push(args),
  });
  assert.deepEqual(racedMarker, {
    kind: "conflict",
    code: "RECOVERY_REFUND_MARKER_OWNERSHIP_CONFLICT",
  });
  assert.equal(raceWrites.length, 0);
});
