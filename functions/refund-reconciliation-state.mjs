export function refundReconciliationDecision({
  marker = null,
  markerExists = false,
  isDuplicate = false,
  now = Date.now(),
} = {}) {
  const markerIsProcessing = marker?.status === "processing" &&
    Number(marker.leaseExpiresAtMs) > now;
  const markerIsCompleted = marker?.status === "completed";
  // A replay of the same event is idempotent. A distinct outcome for the
  // same order must reopen reconciliation, including after completion.
  const shouldScheduleReconciliation = !isDuplicate || !markerExists;
  return {
    markerIsProcessing,
    markerIsCompleted,
    shouldScheduleReconciliation,
    sessionMarkerStatus: markerIsProcessing && !shouldScheduleReconciliation ?
      "processing" : "pending",
  };
}

/**
 * Decide whether a refund marker can be completed after the provider detail
 * read.  Redirect/refund callbacks are not terminal proof: only a scoped
 * Portaly subscription whose authoritative status is `canceled` is safe to
 * finish.  Renewable, cancel-requested, and unknown states stay retryable.
 */
export function deletedAccountRefundOutcome({
  subscriptionId,
  expectedSubscriptionId,
  planId,
  expectedPlanId,
  mode,
  expectedMode,
  subscriptionStatus,
} = {}) {
  const sameNonBlank = (actual, expected) => typeof actual === "string" &&
    typeof expected === "string" && actual.trim().length > 0 &&
    expected.trim().length > 0 && actual === expected;
  const scoped = sameNonBlank(subscriptionId, expectedSubscriptionId) &&
    sameNonBlank(planId, expectedPlanId) &&
    sameNonBlank(mode, expectedMode);
  return scoped && subscriptionStatus === "canceled" ? "complete" : "retry";
}

export function refundReconciliationLeaseMatches({
  marker = null,
  leaseId,
  sourceTimestampMs,
} = {}) {
  return Boolean(
    marker &&
    marker.leaseId === leaseId &&
    Number(marker.sourceTimestampMs) === sourceTimestampMs,
  );
}
