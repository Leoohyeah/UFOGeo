const PORTALY_MODES = new Set(["live", "test"]);
const CHECKOUT_PENDING_STATUSES = new Set(["pending", "created", "checkout_ready"]);
const CHECKOUT_TERMINAL_STATUSES = new Set(["failed", "canceled", "cancelled", "expired"]);
const CHECKOUT_SUCCESS_STATUSES = new Set(["completed"]);
const LOCAL_HOLD_STATUSES = new Set([
  "pending",
  "created",
  "checkout_ready",
  "response_incomplete",
  "uncertain",
]);

function fail(code, message) {
  throw Object.assign(new Error(message), {code, statusCode: 409});
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizedEmail(value) {
  return nonBlankString(value)?.toLowerCase() || null;
}

function documentId(value) {
  const candidate = nonBlankString(value);
  return candidate && candidate !== "." && candidate !== ".." &&
    !candidate.includes("/") && Buffer.byteLength(candidate, "utf8") <= 1500 ?
    candidate : null;
}

function identityField(value, expected, code, label, {optional = false} = {}) {
  if ((value === undefined || value === null) && optional) return;
  const actual = nonBlankString(value);
  if (!actual || actual !== expected) fail(code, `${label} does not match`);
}

function isExpiredCreatingLock(lock, now) {
  if (lock?.status !== "creating") return false;
  const leaseExpiresAtMs = Number(lock.leaseExpiresAtMs);
  return !Number.isFinite(leaseExpiresAtMs) || leaseExpiresAtMs <= now;
}

/**
 * Select a known checkout session that is safe to query for the authenticated
 * member. Missing provider identifiers deliberately produce no target: an
 * uncertain POST without a session ID must remain locked until a callback or
 * another provider-backed record supplies that identity.
 */
export function checkoutSessionReconciliationTarget({
  user = {},
  lock = null,
  uid,
  email,
  planId,
  mode,
  now = Date.now(),
} = {}) {
  const expectedUid = nonBlankString(uid);
  const expectedEmail = normalizedEmail(email);
  const expectedPlanId = nonBlankString(planId);
  if (!isRecord(user) || (lock !== null && !isRecord(lock)) || !expectedUid ||
      !expectedEmail || !expectedPlanId || !PORTALY_MODES.has(mode) ||
      !Number.isFinite(now)) {
    fail("CHECKOUT_RECONCILIATION_CONTEXT_INVALID", "Checkout reconciliation context is invalid");
  }

  const userHasPendingStatus = CHECKOUT_PENDING_STATUSES.has(user.subscriptionStatus);
  if (userHasPendingStatus && !PORTALY_MODES.has(user.mode)) {
    fail("CHECKOUT_RECONCILIATION_MODE_MISMATCH", "Pending checkout mode is invalid");
  }
  const userIsPending = userHasPendingStatus && user.mode === mode;
  const lockIsHeld = lock && (LOCAL_HOLD_STATUSES.has(lock.status) ||
    isExpiredCreatingLock(lock, now));
  if (!userIsPending && !lockIsHeld) return null;
  if (lock?.status === "creating" && !isExpiredCreatingLock(lock, now)) return null;

  const userSubscriptionId = userIsPending ? documentId(user.subscriptionId) : null;
  const userCheckoutId = userIsPending ? documentId(user.currentCheckoutSessionId) : null;
  if (userIsPending && (!userSubscriptionId || !userCheckoutId ||
      userSubscriptionId !== userCheckoutId)) {
    fail("CHECKOUT_RECONCILIATION_USER_ID_INVALID", "Pending checkout identity is invalid");
  }

  const lockSessionId = lockIsHeld ? documentId(lock.sessionId) : null;
  if (lockIsHeld && lock.sessionId !== undefined && lock.sessionId !== null && !lockSessionId) {
    fail("CHECKOUT_RECONCILIATION_LOCK_ID_INVALID", "Checkout lock identity is invalid");
  }
  const sessionId = userCheckoutId || lockSessionId;
  if (!sessionId) return null;
  if (userCheckoutId && lockSessionId && userCheckoutId !== lockSessionId) {
    fail("CHECKOUT_RECONCILIATION_ID_MISMATCH", "Checkout identities do not match");
  }

  if (userIsPending) {
    identityField(user.mode, mode, "CHECKOUT_RECONCILIATION_MODE_MISMATCH", "User mode");
    identityField(user.planId, expectedPlanId, "CHECKOUT_RECONCILIATION_PLAN_MISMATCH", "User plan");
    if (user.email !== undefined && normalizedEmail(user.email) !== expectedEmail) {
      fail("CHECKOUT_RECONCILIATION_EMAIL_MISMATCH", "User email does not match");
    }
  }
  if (lockIsHeld) {
    identityField(lock.uid, expectedUid, "CHECKOUT_RECONCILIATION_UID_MISMATCH", "Lock UID");
    identityField(lock.mode, mode, "CHECKOUT_RECONCILIATION_MODE_MISMATCH", "Lock mode");
    identityField(lock.planId, expectedPlanId, "CHECKOUT_RECONCILIATION_PLAN_MISMATCH", "Lock plan");
  }

  return {sessionId, uid: expectedUid, email: expectedEmail, planId: expectedPlanId, mode};
}

export function validateStoredCheckoutSession(session, target) {
  if (!isRecord(session) || !target) {
    fail("CHECKOUT_RECONCILIATION_SESSION_MISSING", "Checkout session is missing");
  }
  identityField(session.uid, target.uid, "CHECKOUT_RECONCILIATION_UID_MISMATCH", "Session UID");
  identityField(
    session.sessionId,
    target.sessionId,
    "CHECKOUT_RECONCILIATION_SESSION_ID_MISMATCH",
    "Session ID",
  );
  identityField(
    session.subscriptionId,
    target.sessionId,
    "CHECKOUT_RECONCILIATION_SESSION_ID_MISMATCH",
    "Session subscription ID",
    {optional: true},
  );
  identityField(
    session.planId,
    target.planId,
    "CHECKOUT_RECONCILIATION_PLAN_MISMATCH",
    "Session plan",
  );
  identityField(
    session.mode,
    target.mode,
    "CHECKOUT_RECONCILIATION_MODE_MISMATCH",
    "Session mode",
  );
  if (normalizedEmail(session.customerEmail) !== target.email) {
    fail("CHECKOUT_RECONCILIATION_EMAIL_MISMATCH", "Session email does not match");
  }
  if (!LOCAL_HOLD_STATUSES.has(session.status)) {
    fail("CHECKOUT_RECONCILIATION_SESSION_STATE_CHANGED", "Checkout session is no longer pending");
  }
  return session;
}

function unwrapCheckoutSession(payload) {
  if (!isRecord(payload)) {
    fail("PORTALY_CHECKOUT_RESPONSE_INVALID", "Portaly checkout response is invalid");
  }
  return isRecord(payload.data) ? payload.data : payload;
}

export function verifiedCheckoutSessionState(payload, {target, localSession} = {}) {
  validateStoredCheckoutSession(localSession, target);
  const remote = unwrapCheckoutSession(payload);
  const remoteId = documentId(remote.sessionId ?? remote.id);
  if (!remoteId || remoteId !== target.sessionId) {
    fail("PORTALY_CHECKOUT_ID_MISMATCH", "Portaly checkout session ID does not match");
  }
  if (remote.sessionId !== undefined && remote.id !== undefined &&
      documentId(remote.sessionId) !== documentId(remote.id)) {
    fail("PORTALY_CHECKOUT_ID_MISMATCH", "Portaly checkout session ID aliases do not match");
  }
  if (normalizedEmail(remote.customer?.email) !== target.email) {
    fail("PORTALY_CHECKOUT_EMAIL_MISMATCH", "Portaly checkout email does not match");
  }
  const remotePlanId = nonBlankString(remote.plan?.id ?? remote.planId);
  if (remotePlanId !== target.planId) {
    fail("PORTALY_CHECKOUT_PLAN_MISMATCH", "Portaly checkout plan does not match");
  }
  if (remote.mode !== undefined && remote.mode !== target.mode) {
    fail("PORTALY_CHECKOUT_MODE_MISMATCH", "Portaly checkout mode does not match");
  }
  const expectedOrderNumber = nonBlankString(localSession.merchantOrderNumber);
  if (expectedOrderNumber && nonBlankString(remote.merchantOrderNumber) !== expectedOrderNumber) {
    fail("PORTALY_CHECKOUT_ORDER_MISMATCH", "Portaly checkout order does not match");
  }

  const status = nonBlankString(remote.status);
  if (CHECKOUT_PENDING_STATUSES.has(status)) return {kind: "pending", status, remote};
  if (CHECKOUT_TERMINAL_STATUSES.has(status)) return {kind: "terminal", status, remote};
  if (CHECKOUT_SUCCESS_STATUSES.has(status)) return {kind: "completed", status, remote};
  fail("PORTALY_CHECKOUT_STATUS_UNKNOWN", "Portaly checkout status is unsupported");
}

export function checkoutReconciliationOrchestrationResult(result) {
  if (result?.kind === "pending") return {kind: "held"};
  return {kind: "resolved", body: result};
}

export function subscriptionReconciliationLookupId({
  initialSubscriptionId = null,
  initialCheckoutSessionId = null,
  trustedLookupId = null,
} = {}) {
  if (trustedLookupId !== null && trustedLookupId !== undefined &&
      !documentId(trustedLookupId)) {
    fail("TRUSTED_LOOKUP_ID_INVALID", "Trusted checkout identity is invalid");
  }
  return nonBlankString(initialCheckoutSessionId) ||
    nonBlankString(initialSubscriptionId) || documentId(trustedLookupId);
}

/**
 * Production checkout-recovery path. Network and persistence are injected so
 * the HTTP layer can use the existing Portaly request and subscription
 * reconciliation implementations while this complete branch routing remains
 * regression-testable without Firebase emulators.
 */
export async function reconcileCheckoutSessionPath({
  user,
  lock,
  uid,
  email,
  planId,
  mode,
  now = Date.now(),
  loadSession,
  queryCheckoutSession,
  persistTerminal,
  reconcileCompleted,
} = {}) {
  const target = checkoutSessionReconciliationTarget({
    user,
    lock,
    uid,
    email,
    planId,
    mode,
    now,
  });
  if (!target) return {kind: "not_applicable"};
  if (typeof loadSession !== "function" || typeof queryCheckoutSession !== "function" ||
      typeof persistTerminal !== "function" || typeof reconcileCompleted !== "function") {
    fail("CHECKOUT_RECONCILIATION_ADAPTER_INVALID", "Checkout reconciliation adapter is invalid");
  }

  const localSession = validateStoredCheckoutSession(
    await loadSession(target.sessionId),
    target,
  );
  const state = verifiedCheckoutSessionState(
    await queryCheckoutSession(target.sessionId),
    {target, localSession},
  );
  if (state.kind === "pending") {
    return {kind: "pending", target, localSession, providerStatus: state.status};
  }
  if (state.kind === "terminal") {
    return persistTerminal({target, localSession, providerStatus: state.status, remote: state.remote});
  }
  return reconcileCompleted({
    target,
    localSession,
    remote: state.remote,
    trustedLookupId: target.sessionId,
  });
}
