import {validateEntitlementGrant} from "./entitlement-resolver.mjs";
import {isPortalyMode} from "./portaly-mode.mjs";
import {paymentStateProjection} from "./subscription-response.mjs";

export function hasBlockingSubscription(subscription = {}, {mode} = {}) {
  if (!subscription || typeof subscription !== "object" || Array.isArray(subscription)) {
    return false;
  }
  const isRenewable = subscription.proActive === true ||
    ["active", "past_due", "cancel_requested"].includes(subscription.subscriptionStatus);
  if (!isRenewable) return false;
  // Preserve the helper's legacy behavior when no mode is requested. Formal
  // checkout callers always pass a valid mode. A missing/invalid stored mode
  // remains blocking because its charge environment cannot be proven.
  if (mode === undefined || mode === null) return true;
  if (!isPortalyMode(mode) || !isPortalyMode(subscription.mode)) return true;
  return subscription.mode === mode;
}

export const CHECKOUT_UNCERTAIN_HOLD_MS = 24 * 60 * 60 * 1000;

const CHECKOUT_INITIAL_STATUSES = new Set(["pending", "checkout_ready", "created"]);
const CHECKOUT_DEFINITIVE_FAILURE_CODES = new Map([
  [400, new Set([null, "INVALID_DISCOUNT_CODE"])],
  [401, new Set([null])],
  [403, new Set([null])],
  [404, new Set(["PLAN_NOT_FOUND"])],
  [422, new Set(["PLAN_INACTIVE", "YEARLY_TEMPORARILY_UNSUPPORTED"])],
]);
const CHECKOUT_SAFETY_HOLD_STATUSES = new Set([
  "uncertain",
  "account_deleting",
  "account_deleted",
]);
const CHECKOUT_TERMINAL_STATUSES = new Set([
  "checkout_completed",
  "checkout_failed",
  "completed",
  "failed",
  "expired",
  "canceled",
  "cancelled",
]);

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

const GRANT_CHECKOUT_CONFLICT_CODE = "ENTITLEMENT_GRANT_CHECKOUT_CONFLICT";
const GRANT_CHECKOUT_UNKNOWN_CODE = "ENTITLEMENT_GRANT_CHECKOUT_STATE_UNKNOWN";

function grantCheckoutUnsafe(status) {
  return {kind: "unsafe", status, code: GRANT_CHECKOUT_UNKNOWN_CODE};
}

function grantCheckoutBlocked(status) {
  return {kind: "blocked", status, code: GRANT_CHECKOUT_CONFLICT_CODE};
}

function epochMs(value) {
  if (typeof value === "number") return value;
  if (typeof value === "string") return Date.parse(value);
  if (typeof value?.toDate === "function") {
    try {
      return value.toDate().getTime();
    } catch {
      return Number.NaN;
    }
  }
  return Number.NaN;
}

function validSessionId(value) {
  const sessionId = nonBlankString(value);
  return sessionId && sessionId !== "." && sessionId !== ".." &&
    !sessionId.includes("/") && Buffer.byteLength(sessionId, "utf8") <= 1500 ?
    sessionId : null;
}

function validHttpsUrl(value) {
  const candidate = nonBlankString(value);
  if (!candidate) return null;
  try {
    const parsed = new URL(candidate);
    return parsed.protocol === "https:" && parsed.hostname ? candidate : null;
  } catch {
    return null;
  }
}

function uncertainCheckoutResult(reason, data) {
  const result = {kind: "uncertain", retryAllowed: false, reason};
  const sessionId = validSessionId(data?.sessionId);
  const checkoutUrl = validHttpsUrl(data?.checkoutUrl);
  const checkoutToken = nonBlankString(data?.checkoutToken);
  const providerStatus = CHECKOUT_INITIAL_STATUSES.has(data?.status) ? data.status : null;
  const expiresAtMs = epochMs(data?.expiresAt);
  if (sessionId) result.sessionId = sessionId;
  if (checkoutUrl) result.checkoutUrl = checkoutUrl;
  if (checkoutToken) result.checkoutToken = checkoutToken;
  if (providerStatus) result.providerStatus = providerStatus;
  if (Number.isFinite(expiresAtMs)) result.expiresAt = data.expiresAt;
  if (typeof data?.amount === "number" && Number.isFinite(data.amount)) {
    result.amount = data.amount;
  }
  if (data?.appliedDiscount === null ||
      (data?.appliedDiscount && typeof data.appliedDiscount === "object" &&
       !Array.isArray(data.appliedDiscount))) {
    result.appliedDiscount = data.appliedDiscount;
  }
  return result;
}

function isDefinitiveCheckoutFailure(status, payload) {
  if (!CHECKOUT_DEFINITIVE_FAILURE_CODES.has(status) ||
      !payload || typeof payload !== "object" || Array.isArray(payload) ||
      !nonBlankString(payload.error) ||
      (payload.data !== undefined && payload.data !== null)) {
    return false;
  }
  const code = payload.code === undefined || payload.code === null ? null : payload.code;
  return CHECKOUT_DEFINITIVE_FAILURE_CODES.get(status)?.has(code) === true;
}

/**
 * Classifies the non-idempotent Portaly checkout POST. Only documented
 * rejection statuses prove that no session was created. Transport errors,
 * ambiguous 4xx/5xx responses, and malformed successes remain uncertain and
 * must retain a safety hold.
 */
export function classifyCheckoutCreationResult({error, status, payload, now = Date.now()} = {}) {
  const data = payload?.data && typeof payload.data === "object" && !Array.isArray(payload.data) ?
    payload.data : null;
  if (error) return uncertainCheckoutResult("transport_error", data);

  const httpStatus = Number(status);
  if (isDefinitiveCheckoutFailure(httpStatus, payload)) {
    return {
      kind: "definitive_failure",
      retryAllowed: true,
      reason: "http_4xx",
      status: httpStatus,
    };
  }
  if (Number.isInteger(httpStatus) && httpStatus >= 400 && httpStatus < 500) {
    return uncertainCheckoutResult("ambiguous_http_4xx", data);
  }
  if (Number.isInteger(httpStatus) && httpStatus >= 500) {
    return uncertainCheckoutResult("http_5xx", data);
  }
  if (!Number.isInteger(httpStatus) || httpStatus < 200 || httpStatus >= 300) {
    return uncertainCheckoutResult("unexpected_http_status", data);
  }

  if (!data) return uncertainCheckoutResult("response_incomplete", data);
  if (!CHECKOUT_INITIAL_STATUSES.has(data.status)) {
    return uncertainCheckoutResult("response_status_invalid", data);
  }

  const sessionId = validSessionId(data?.sessionId);
  const checkoutUrl = validHttpsUrl(data?.checkoutUrl);
  const checkoutToken = nonBlankString(data?.checkoutToken);
  const expiresAtMs = epochMs(data?.expiresAt);
  if (!sessionId || !checkoutUrl || !checkoutToken ||
      !Number.isFinite(expiresAtMs) || expiresAtMs <= now) {
    return uncertainCheckoutResult("response_incomplete", data);
  }

  return {
    kind: "success",
    retryAllowed: false,
    session: {
      ...data,
      sessionId,
      checkoutUrl,
      checkoutToken,
      providerStatus: data.status,
      status: "checkout_ready",
    },
  };
}

function modeMatches(record, mode) {
  if (mode === undefined || mode === null) return true;
  return isPortalyMode(mode) && record?.mode === mode;
}

function planMatches(record, planId) {
  if (planId === undefined || planId === null) return true;
  return typeof planId === "string" && planId.length > 0 && record?.planId === planId;
}

function unknownModeCheckoutHold(record, {planId, now} = {}) {
  if (!record || isPortalyMode(record.mode) || !planMatches(record, planId) ||
      !CHECKOUT_INITIAL_STATUSES.has(record.status)) {
    return null;
  }
  const expiresAtMs = epochMs(record.expiresAt);
  return Number.isFinite(expiresAtMs) && expiresAtMs > now ? expiresAtMs : null;
}

function hasUnknownModePendingSubscription(subscription, mode) {
  return isPortalyMode(mode) &&
    subscription && typeof subscription === "object" && !Array.isArray(subscription) &&
    !isPortalyMode(subscription.mode) &&
    CHECKOUT_INITIAL_STATUSES.has(subscription.subscriptionStatus);
}

function lockOwnerMatches(lock, uid) {
  // uid was not part of the original function contract. Keeping undefined as
  // an unrestricted owner preserves existing callers while new email-scoped
  // callers must prove that the pending checkout belongs to this Firebase UID.
  if (uid === undefined || uid === null) return true;
  return typeof uid === "string" && uid.length > 0 && lock?.uid === uid;
}

export function hasActiveCheckoutSafetyHold(
  lock,
  {planId, mode, now = Date.now()} = {},
) {
  if (!lock || !planMatches(lock, planId) || !modeMatches(lock, mode)) return false;
  const safetyHoldUntilMs = Number(lock.safetyHoldUntilMs);
  // An uncertain checkout POST cannot become safe merely because time passed.
  // A callback, provider reconciliation, or explicit terminal state must clear
  // it before another non-idempotent POST is allowed.
  if (lock.status === "uncertain") return true;
  if (["account_deleting", "account_deleted"].includes(lock.status)) {
    return Number.isFinite(safetyHoldUntilMs) && safetyHoldUntilMs > now;
  }

  // Before the provider POST, the owner pre-arms the hold while retaining the
  // short creating lease. If the process dies during the POST, the hold takes
  // over as soon as that short lease expires and remains until reconciled.
  if (lock.status === "creating") {
    const leaseExpiresAtMs = Number(lock.leaseExpiresAtMs);
    return !Number.isFinite(leaseExpiresAtMs) || leaseExpiresAtMs <= now;
  }
  return false;
}

export function checkoutEntitlementGrantDecision(grant, options) {
  const validated = validateEntitlementGrant(grant, options);
  if (!validated.valid) {
    return {kind: "grant_invalid", code: validated.code};
  }
  return validated.active ? {kind: "server_grant"} : {kind: "allow"};
}

export function checkoutLockDocumentId(uid, planId, mode) {
  const baseId = `${uid}_${planId}`;
  return isPortalyMode(mode) ? `${baseId}_${mode}` : baseId;
}

export function isReusableCheckoutSession(session, {planId, mode, now = Date.now()} = {}) {
  if (!session || session.planId !== planId) return false;
  // A mode is required by the production caller. Records from before mode was
  // persisted are intentionally not reusable when a mode is supplied: their
  // environment cannot be proven, so reusing them could cross test/live data.
  if (!modeMatches(session, mode)) return false;
  if (!validSessionId(session.sessionId) || !validHttpsUrl(session.checkoutUrl)) return false;
  if (!["pending", "checkout_ready", "created"].includes(session.status)) return false;

  const expiresAtMs = epochMs(session.expiresAt);
  return Number.isFinite(expiresAtMs) && expiresAtMs > now;
}

export function checkoutLockMatchesSession(lock, sessionId, {mode} = {}) {
  return Boolean(
    lock &&
    typeof sessionId === "string" &&
    sessionId.length > 0 &&
    lock.sessionId === sessionId &&
    modeMatches(lock, mode)
  );
}

export function callbackModeMatchesSession(sessionMode, callbackMode) {
  // Only live callbacks may omit mode according to the Portaly contract. Test
  // sessions must explicitly prove their mode so sandbox events cannot be
  // accepted through the live omission rule.
  const hasSessionMode = sessionMode !== undefined && sessionMode !== null;
  const hasCallbackMode = callbackMode !== undefined;
  if (!hasCallbackMode) return sessionMode === "live";
  if (!isPortalyMode(callbackMode)) return false;
  if (!hasSessionMode) return true;
  return isPortalyMode(sessionMode) && sessionMode === callbackMode;
}

export function callbackModeMatchesDeployment(callbackMode, expectedMode) {
  return isPortalyMode(callbackMode) &&
    isPortalyMode(expectedMode) &&
    callbackMode === expectedMode;
}

export function callbackMatchesCheckoutSession(
  session,
  payload,
  {expectedPlanId} = {},
) {
  if (!session || typeof session !== "object" || Array.isArray(session) ||
      !payload || typeof payload !== "object" || Array.isArray(payload)) {
    return false;
  }
  const callbackId = validSessionId(payload.subscriptionId) ||
    validSessionId(payload.sessionId);
  const sessionId = validSessionId(session.sessionId);
  const storedSubscriptionId = session.subscriptionId === undefined ||
    session.subscriptionId === null ? null : validSessionId(session.subscriptionId);
  const planId = nonBlankString(expectedPlanId);
  if (!callbackId || !sessionId || sessionId !== callbackId ||
      (session.subscriptionId !== undefined && session.subscriptionId !== null &&
       storedSubscriptionId !== callbackId) ||
      !planId || session.planId !== planId || payload.planId !== planId ||
      !callbackModeMatchesSession(session.mode, payload.mode)) {
    return false;
  }

  if (session.accountDeleted === true) return true;
  const sessionEmail = nonBlankString(session.customerEmail)?.toLowerCase();
  const callbackEmail = nonBlankString(payload.customerEmail)?.toLowerCase();
  return Boolean(sessionEmail && callbackEmail && sessionEmail === callbackEmail);
}

export function shouldApplyUserSubscriptionUpdate(
  currentUser = {},
  incomingSubscriptionId,
  {mode} = {},
) {
  if (typeof incomingSubscriptionId !== "string" || incomingSubscriptionId.length === 0) {
    return false;
  }
  if (mode !== undefined) {
    if (!isPortalyMode(mode)) return false;
    // A signed callback may backfill a legacy missing mode, but it must never
    // overwrite a user explicitly assigned to the other environment (or one
    // whose stored mode is corrupt).
    if (currentUser?.mode !== undefined && currentUser?.mode !== null &&
        currentUser.mode !== mode) {
      return false;
    }
  }

  const currentCheckoutSessionId = currentUser?.currentCheckoutSessionId;
  if (typeof currentCheckoutSessionId === "string" && currentCheckoutSessionId.length > 0) {
    return currentCheckoutSessionId === incomingSubscriptionId;
  }

  const currentSubscriptionId = currentUser?.subscriptionId;
  // A user without an assigned subscription can still receive the first
  // callback for a checkout that was created before the user document was
  // populated. Once a newer checkout is assigned, older callbacks must remain
  // audit/session history only and must never change current entitlements.
  return !currentSubscriptionId || currentSubscriptionId === incomingSubscriptionId;
}

export function checkoutLeaseDecision({
  subscription = {},
  lock = null,
  emailLock = null,
  legacyLock = null,
  legacyLocks = [],
  fallbackSession = null,
  uid,
  planId,
  mode,
  now = Date.now(),
} = {}) {
  if ((mode === undefined || mode === null || !isPortalyMode(subscription?.mode)) &&
      hasBlockingSubscription(subscription, {mode})) {
    return {kind: "blocked"};
  }
  if (hasUnknownModePendingSubscription(subscription, mode)) {
    return {kind: "safety_hold", status: "legacy_mode_unknown"};
  }

  let paymentStatus = subscription?.subscriptionStatus;
  if (mode !== undefined && mode !== null) {
    const payment = paymentStateProjection({
      data: subscription,
      expectedMode: mode,
      expectedPlanId: planId,
    });
    if (!payment.valid) {
      return {kind: "safety_hold", status: "subscription_state_unknown"};
    }
    paymentStatus = payment.subscriptionStatus;
  }
  if (hasBlockingSubscription(subscription, {mode})) {
    return {kind: "blocked"};
  }

  const legacyCandidates = Array.isArray(legacyLocks) ? legacyLocks : [];
  const candidates = [emailLock, lock, legacyLock, ...legacyCandidates]
    .filter((candidate, index, values) => candidate && values.indexOf(candidate) === index);
  const allCandidates = [...candidates, fallbackSession];

  for (const candidate of candidates) {
    const currentCheckoutSessionId = subscription?.currentCheckoutSessionId;
    if (
      lockOwnerMatches(candidate, uid) &&
      (!currentCheckoutSessionId || candidate?.sessionId === currentCheckoutSessionId) &&
      isReusableCheckoutSession(candidate, {planId, mode, now})
    ) {
      return {kind: "reuse", session: candidate};
    }
  }
  const currentCheckoutSessionId = subscription?.currentCheckoutSessionId;
  if (
    lockOwnerMatches(fallbackSession, uid) &&
    (!currentCheckoutSessionId || fallbackSession?.sessionId === currentCheckoutSessionId) &&
    isReusableCheckoutSession(fallbackSession, {planId, mode, now})
  ) {
    return {kind: "reuse", session: fallbackSession};
  }

  for (const candidate of allCandidates) {
    if (hasActiveCheckoutSafetyHold(candidate, {planId, mode, now})) {
      const decision = {
        kind: "safety_hold",
        status: candidate.status,
      };
      const safetyHoldUntilMs = Number(candidate.safetyHoldUntilMs);
      if (Number.isFinite(safetyHoldUntilMs)) decision.safetyHoldUntilMs = safetyHoldUntilMs;
      return decision;
    }
  }

  for (const candidate of allCandidates) {
    const safetyHoldUntilMs = unknownModeCheckoutHold(candidate, {planId, now});
    if (safetyHoldUntilMs) {
      return {
        kind: "safety_hold",
        status: "legacy_mode_unknown",
        safetyHoldUntilMs,
      };
    }
  }

  // A checkout URL created for a previous Firebase account must not be handed
  // to the new account, even when both accounts verified the same email.
  for (const candidate of allCandidates) {
    if (
      candidate &&
      !lockOwnerMatches(candidate, uid) &&
      isReusableCheckoutSession(candidate, {planId, mode, now})
    ) {
      return {kind: "conflict"};
    }
  }

  for (const candidate of candidates) {
    const leaseExpiresAtMs = Number(candidate?.leaseExpiresAtMs);
    const isLegacyCandidate = candidate === legacyLock || legacyCandidates.includes(candidate);
    const isUnknownLegacyLease = isLegacyCandidate &&
      candidate?.mode === undefined && candidate?.status === "creating";
    if (
      planMatches(candidate, planId) &&
      (modeMatches(candidate, mode) || isUnknownLegacyLease) &&
      candidate?.status === "creating" &&
      Number.isFinite(leaseExpiresAtMs) &&
      leaseExpiresAtMs > now
    ) {
      return {kind: "in_progress"};
    }
  }

  if (CHECKOUT_INITIAL_STATUSES.has(paymentStatus)) {
    return {kind: "safety_hold", status: subscription.subscriptionStatus};
  }

  return {kind: "acquire"};
}

/**
 * Decide whether an administrator may grant Pro while checkout state exists.
 * This shares the checkout lock status and timestamp rules with checkout and
 * account deletion. Unknown or malformed matching records fail closed; known
 * terminal or expired legacy records do not block forever.
 */
export function checkoutGrantDecision({uid, user = {}, locks = [], planId, now = Date.now()} = {}) {
  if (!nonBlankString(uid) || !Array.isArray(locks) || typeof planId !== "string" ||
      planId.length === 0 || !Number.isFinite(now) ||
      !user || typeof user !== "object" || Array.isArray(user)) {
    return grantCheckoutUnsafe("request_invalid");
  }
  if (user.accountDeleting === true || nonBlankString(user.accountDeletionId)) {
    return {
      ...grantCheckoutBlocked("account_deleting"),
      code: "ACCOUNT_DELETION_IN_PROGRESS",
    };
  }
  if (user.accountDeleting !== undefined && typeof user.accountDeleting !== "boolean") {
    return grantCheckoutUnsafe("account_deletion_state_unknown");
  }
  if (user.accountDeletionId !== undefined && user.accountDeletionId !== null &&
      !nonBlankString(user.accountDeletionId)) {
    return grantCheckoutUnsafe("account_deletion_state_unknown");
  }
  const hasCheckoutSessionId = user.currentCheckoutSessionId !== undefined &&
    user.currentCheckoutSessionId !== null;
  if (hasCheckoutSessionId && !nonBlankString(user.currentCheckoutSessionId)) {
    return grantCheckoutUnsafe("checkout_state_unknown");
  }
  if (hasCheckoutSessionId && (user.subscriptionStatus === undefined ||
      user.subscriptionStatus === null || typeof user.subscriptionStatus !== "string")) {
    return grantCheckoutUnsafe("checkout_state_unknown");
  }
  if (hasCheckoutSessionId && CHECKOUT_INITIAL_STATUSES.has(user.subscriptionStatus)) {
    return grantCheckoutBlocked("checkout_pending");
  }

  for (const lock of locks) {
    if (!lock || typeof lock !== "object" || Array.isArray(lock)) {
      return grantCheckoutUnsafe("checkout_lock_invalid");
    }
    if (lock.planId !== planId) {
      if (typeof lock.planId === "string" && lock.planId.trim() === lock.planId &&
          lock.planId.length > 0) continue;
      return grantCheckoutUnsafe("checkout_lock_plan_unknown");
    }

    const status = lock.status;
    if (CHECKOUT_TERMINAL_STATUSES.has(status)) continue;

    if (status === "creating") {
      const leaseExpiresAtMs = Number(lock.leaseExpiresAtMs);
      const safetyHoldUntilMs = Number(lock.safetyHoldUntilMs);
      if (!Number.isFinite(leaseExpiresAtMs) || !Number.isFinite(safetyHoldUntilMs)) {
        return grantCheckoutUnsafe("checkout_lock_expiry_unknown");
      }
      if (leaseExpiresAtMs > now || safetyHoldUntilMs > now) {
        return grantCheckoutBlocked(status);
      }
      continue;
    }

    if (CHECKOUT_SAFETY_HOLD_STATUSES.has(status)) {
      const safetyHoldUntilMs = Number(lock.safetyHoldUntilMs);
      if (!Number.isFinite(safetyHoldUntilMs)) {
        return grantCheckoutUnsafe("checkout_lock_expiry_unknown");
      }
      if (safetyHoldUntilMs > now) {
        return grantCheckoutBlocked(status);
      }
      continue;
    }

    if (CHECKOUT_INITIAL_STATUSES.has(status)) {
      const expiresAtMs = epochMs(lock.expiresAt);
      if (!Number.isFinite(expiresAtMs)) {
        return grantCheckoutUnsafe("checkout_lock_expiry_unknown");
      }
      if (expiresAtMs > now) {
        return grantCheckoutBlocked(status);
      }
      continue;
    }

    return grantCheckoutUnsafe("checkout_lock_status_unknown");
  }

  return {kind: "safe"};
}
