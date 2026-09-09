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
