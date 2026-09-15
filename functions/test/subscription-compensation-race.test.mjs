import assert from "node:assert/strict";
import test from "node:test";

import {
  deletedAccountCompensationOwnershipDecision,
  subscriptionRecoveryOwnershipPlan,
} from "../subscription-ownership.mjs";
import {deletedAccountRefundOutcome} from "../refund-reconciliation-state.mjs";

const scope = {
  uid: "new-uid",
  email: "member@example.com",
  planId: "plan_monthly",
  mode: "live",
  subscriptionId: "sub_1",
};

const compensation = {
  kind: "deleted_account_cancellation",
  subscriptionId: "sub_1",
  accountDeletionId: "deletion_1",
  planId: "plan_monthly",
  mode: "live",
  status: "pending",
};

const deletedSession = {
  accountDeleted: true,
  accountDeletionId: "deletion_1",
  subscriptionId: "sub_1",
  planId: "plan_monthly",
  mode: "live",
};

const reclaimedSession = {
  ...deletedSession,
  accountDeleted: false,
  uid: "new-uid",
};

test("recovery and deleted-account cancellation fence the same subscription", () => {
  // If recovery reaches its transaction first, an outstanding cancellation
  // marker blocks the new UID from being bound to the provider subscription.
  assert.deepEqual(
    subscriptionRecoveryOwnershipPlan({
      ...scope,
      ownerEntries: [],
      refundMarkerEntries: [],
      compensationEntries: [{data: compensation}],
    }),
    {kind: "conflict", code: "SUBSCRIPTION_RECOVERY_SAFETY_HOLD"},
  );

  // If recovery has already rebound the session, the compensation worker must
  // observe the new owner and finish locally; it must not POST /cancel.
  assert.deepEqual(
    deletedAccountCompensationOwnershipDecision({
      marker: compensation,
      session: reclaimedSession,
    }),
    {kind: "reclaimed", uid: "new-uid"},
  );

  // Before reclaim, the same marker is valid only for the deleted owner.
  assert.deepEqual(
    deletedAccountCompensationOwnershipDecision({
      marker: compensation,
      session: deletedSession,
    }),
    {kind: "deleted_owner"},
  );
});

test("refund reconciliation stays retryable until the scoped subscription is canceled", () => {
  const refundScope = {
    subscriptionId: "sub_1",
    expectedSubscriptionId: "sub_1",
    planId: "plan_monthly",
    expectedPlanId: "plan_monthly",
    mode: "live",
    expectedMode: "live",
  };

  assert.equal(
    deletedAccountRefundOutcome({
      ...refundScope,
      subscriptionStatus: "active",
    }),
    "retry",
  );
  assert.equal(
    deletedAccountRefundOutcome({
      ...refundScope,
      subscriptionStatus: "canceled",
    }),
    "complete",
  );
});
