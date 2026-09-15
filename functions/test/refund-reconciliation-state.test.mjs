import assert from "node:assert/strict";
import test from "node:test";

import {
  deletedAccountRefundOutcome,
  refundReconciliationDecision,
  refundReconciliationLeaseMatches,
} from "../refund-reconciliation-state.mjs";

test("reopens a completed marker for a distinct refund outcome", () => {
  const decision = refundReconciliationDecision({
    marker: {
      status: "completed",
      sourceEvent: "creator_subscription.payment.refund_failed",
    },
    markerExists: true,
    isDuplicate: false,
  });

  assert.equal(decision.markerIsCompleted, true);
  assert.equal(decision.shouldScheduleReconciliation, true);
  assert.equal(decision.sessionMarkerStatus, "pending");
});

test("explicitly reopens refund_failed completion for a later refunded event", () => {
  const failedEvent = "creator_subscription.payment.refund_failed:order-1";
  const refundedEvent = "creator_subscription.payment.refunded:order-1";
  assert.notEqual(failedEvent, refundedEvent);

  const decision = refundReconciliationDecision({
    marker: {
      status: "completed",
      sourceEvent: "creator_subscription.payment.refund_failed",
      orderId: "order-1",
    },
    markerExists: true,
    isDuplicate: false,
  });

  assert.equal(decision.shouldScheduleReconciliation, true);
  assert.equal(decision.sessionMarkerStatus, "pending");
});

test("keeps same-event replay idempotent while protecting an active lease", () => {
  const decision = refundReconciliationDecision({
    marker: {
      status: "processing",
      leaseExpiresAtMs: 1_001,
    },
    markerExists: true,
    isDuplicate: true,
    now: 1_000,
  });

  assert.equal(decision.markerIsProcessing, true);
  assert.equal(decision.shouldScheduleReconciliation, false);
  assert.equal(decision.sessionMarkerStatus, "processing");
});

test("resets an in-flight marker for a distinct outcome", () => {
  const decision = refundReconciliationDecision({
    marker: {
      status: "processing",
      leaseExpiresAtMs: 1_001,
    },
    markerExists: true,
    isDuplicate: false,
    now: 1_000,
  });

  assert.equal(decision.markerIsProcessing, true);
  assert.equal(decision.shouldScheduleReconciliation, true);
  assert.equal(decision.sessionMarkerStatus, "pending");
});

test("keeps a provider-backed refund marker after account deletion", () => {
  const decision = refundReconciliationDecision({
    markerExists: false,
    isDuplicate: false,
  });

  assert.equal(decision.shouldScheduleReconciliation, true);
});

const refundScope = {
  subscriptionId: "sub_1",
  expectedSubscriptionId: "sub_1",
  planId: "plan_pro",
  expectedPlanId: "plan_pro",
  mode: "live",
  expectedMode: "live",
};

test("keeps a refund marker retryable for every non-terminal provider state", () => {
  for (const subscriptionStatus of [
    "active",
    "past_due",
    "cancel_requested",
    undefined,
    "provider_unknown",
  ]) {
    assert.equal(
      deletedAccountRefundOutcome({
        ...refundScope,
        subscriptionStatus,
        recoverable: subscriptionStatus !== undefined &&
          subscriptionStatus !== "provider_unknown",
        cancelAtPeriodEnd: subscriptionStatus === "cancel_requested",
      }),
      "retry",
      `provider status ${String(subscriptionStatus)} must remain retryable`,
    );
  }
});

test("completes a refund marker only for a scoped canceled subscription", () => {
  assert.equal(
    deletedAccountRefundOutcome({
      ...refundScope,
      subscriptionStatus: "canceled",
      recoverable: false,
      cancelAtPeriodEnd: false,
    }),
    "complete",
  );

  for (const [field, value] of [
    ["subscriptionId", "sub_other"],
    ["expectedSubscriptionId", "sub_other"],
    ["planId", "plan_other"],
    ["expectedPlanId", "plan_other"],
    ["mode", "test"],
    ["expectedMode", "test"],
  ]) {
    assert.equal(
      deletedAccountRefundOutcome({
        ...refundScope,
        [field]: value,
        subscriptionStatus: "canceled",
        recoverable: false,
        cancelAtPeriodEnd: false,
      }),
      "retry",
      `${field} mismatch must not complete a refund marker`,
    );
  }
});

test("refund-first delivery cannot finish reconciliation before canceled delivery", () => {
  const refundFirst = deletedAccountRefundOutcome({
    ...refundScope,
    subscriptionStatus: "active",
    recoverable: true,
    cancelAtPeriodEnd: false,
  });
  assert.equal(refundFirst, "retry");

  const canceledLater = deletedAccountRefundOutcome({
    ...refundScope,
    subscriptionStatus: "canceled",
    recoverable: false,
    cancelAtPeriodEnd: false,
  });
  assert.equal(canceledLater, "complete");
});

test("an older worker cannot clear a newer refund marker", () => {
  const newerMarker = {leaseId: "new-lease", sourceTimestampMs: 2_000};
  assert.equal(
    refundReconciliationLeaseMatches({
      marker: newerMarker,
      leaseId: "old-lease",
      sourceTimestampMs: 1_000,
    }),
    false,
  );
  assert.equal(
    refundReconciliationLeaseMatches({
      marker: newerMarker,
      leaseId: "new-lease",
      sourceTimestampMs: 1_000,
    }),
    false,
  );
  assert.equal(
    refundReconciliationLeaseMatches({
      marker: newerMarker,
      leaseId: "new-lease",
      sourceTimestampMs: 2_000,
    }),
    true,
  );
});
