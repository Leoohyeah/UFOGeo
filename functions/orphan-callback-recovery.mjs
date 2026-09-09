const PORTALY_MODES = new Set(["live", "test"]);
const RECOVERABLE_CHECKOUT_LOCK_STATUSES = new Set([
  "creating",
  "uncertain",
  "response_incomplete",
  "pending",
  "created",
  "checkout_ready",
]);

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizedEmail(value) {
  return nonBlankString(value)?.toLowerCase().normalize("NFC") || null;
}

function documentId(value) {
  const candidate = nonBlankString(value);
  return candidate && candidate !== "." && candidate !== ".." &&
    !candidate.includes("/") && Buffer.byteLength(candidate, "utf8") <= 1500 ?
    candidate : null;
}

function identityValue(value) {
  const candidate = nonBlankString(value);
  return candidate && Buffer.byteLength(candidate, "utf8") <= 1500 ? candidate : null;
}

function reject(code) {
  return {kind: "reject", code};
}

/**
 * Decide whether a signed callback may recreate a missing checkout session.
 *
 * This is intentionally stricter than the normal callback/session matcher:
 * the callback must carry every identity that was persisted before the
 * non-idempotent provider POST, and all of those identities must match one
 * customer lock.  No time-based expiry is used here.
 */
export function orphanCallbackRecoveryDecision({payload, lock, expectedMode} = {}) {
  if (!isRecord(payload)) return reject("ORPHAN_CALLBACK_PAYLOAD_INVALID");

  const sessionId = documentId(payload.sessionId);
  const subscriptionId = payload.subscriptionId === undefined || payload.subscriptionId === null ?
    null : documentId(payload.subscriptionId);
  const customerEmail = normalizedEmail(payload.customerEmail);
  const planId = identityValue(payload.planId);
  const mode = identityValue(payload.mode);
  const merchantOrderNumber = identityValue(payload.merchantOrderNumber);
  const metadata = payload.metadata;
  const firebaseUid = isRecord(metadata) ? identityValue(metadata.firebaseUid) : null;
  const checkoutLeaseId = isRecord(metadata) ? identityValue(metadata.checkoutLeaseId) : null;

  if (!sessionId || (payload.subscriptionId !== undefined && payload.subscriptionId !== null &&
      !subscriptionId) || (subscriptionId && subscriptionId !== sessionId)) {
    return reject("ORPHAN_CALLBACK_SESSION_ID_INVALID");
  }
  if (!customerEmail || !planId || !mode || !PORTALY_MODES.has(mode) ||
      mode !== expectedMode || !merchantOrderNumber || !firebaseUid || !checkoutLeaseId) {
    return reject("ORPHAN_CALLBACK_IDENTITY_INVALID");
  }
  if (!isRecord(lock)) return reject("ORPHAN_CALLBACK_LOCK_MISSING");
  if (!RECOVERABLE_CHECKOUT_LOCK_STATUSES.has(lock.status)) {
    return reject("ORPHAN_CALLBACK_LOCK_STATE_INVALID");
  }

  const lockEmail = normalizedEmail(lock.customerEmail);
  const lockUid = identityValue(lock.uid);
  const lockPlanId = identityValue(lock.planId);
  const lockMode = identityValue(lock.mode);
  const lockOrderNumber = identityValue(lock.merchantOrderNumber);
  const lockCheckoutLeaseId = identityValue(lock.checkoutLeaseId);
  const lockSessionId = lock.sessionId === undefined || lock.sessionId === null ?
    null : documentId(lock.sessionId);
  if (!lockEmail || !lockUid || !lockPlanId || !lockMode || !lockOrderNumber ||
      !lockCheckoutLeaseId || (lock.sessionId !== undefined && lock.sessionId !== null &&
      !lockSessionId) || lockSessionId && lockSessionId !== sessionId) {
    return reject("ORPHAN_CALLBACK_LOCK_IDENTITY_INVALID");
  }
  if (lockEmail !== customerEmail || lockUid !== firebaseUid ||
      lockPlanId !== planId || lockMode !== mode ||
      lockOrderNumber !== merchantOrderNumber ||
      lockCheckoutLeaseId !== checkoutLeaseId) {
    return reject("ORPHAN_CALLBACK_LOCK_IDENTITY_MISMATCH");
  }

  return {
    kind: "matched",
    sessionId,
    customerEmail,
    planId,
    mode,
    merchantOrderNumber,
    firebaseUid,
    checkoutLeaseId,
  };
}

/**
 * Build the Firestore-safe portion of a session recreated from a verified
 * callback.  Server timestamps and the lock reference are added by the
 * transaction caller.
 */
export function orphanCheckoutSessionRecord({payload, event, recovery, lockId} = {}) {
  if (!isRecord(payload) || typeof event !== "string" ||
      !recovery || recovery.kind !== "matched" || !identityValue(lockId)) {
    throw new Error("Orphan checkout session context is invalid");
  }

  const record = {
    uid: recovery.firebaseUid,
    customerEmail: recovery.customerEmail,
    sessionId: recovery.sessionId,
    merchantOrderNumber: recovery.merchantOrderNumber,
    checkoutLeaseId: recovery.checkoutLeaseId,
    checkoutLockId: lockId,
    planId: recovery.planId,
    mode: recovery.mode,
    status: "response_incomplete",
    reconciliationRequired: true,
    orphanRecovered: true,
  };
  if (event !== "creator_subscription.checkout.failed") {
    record.subscriptionId = recovery.sessionId;
  }
  if (typeof payload.status === "string" && payload.status.trim().length > 0) {
    record.providerStatus = payload.status.trim();
  }
  return record;
}

