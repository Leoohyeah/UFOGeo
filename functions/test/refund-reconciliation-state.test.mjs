import assert from "node:assert/strict";
import test from "node:test";

import {
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
