import {
  hasActiveCheckoutSafetyHold,
  isReusableCheckoutSession,
} from "./checkout-idempotency.mjs";

const ACTIVE_SUBSCRIPTION_STATUSES = new Set([
  "active",
  "past_due",
  "cancel_requested",
]);

const PORTALY_SUBSCRIPTION_STATUSES = new Set([
  "active",
  "past_due",
  "canceled",
]);

const PORTALY_MODES = new Set(["live", "test"]);
const PORTAL_SESSION_STATES = new Set(["creating", "ready", "uncertain"]);

export const PORTAL_SESSION_EXPIRY_GRACE_MS = 5 * 60 * 1000;
export const PORTAL_SESSION_SAFETY_WINDOW_MS = 30 * 60 * 1000 +
  PORTAL_SESSION_EXPIRY_GRACE_MS;

function fail(code, message) {
  throw Object.assign(new Error(message), {code});
}

function requiredString(value, code, label) {
  if (typeof value !== "string" || value.trim() === "") {
    fail(code, `${label} must be a non-empty string`);
  }
  return value.trim();
}

function normalizedEmail(value, code, label) {
  return requiredString(value, code, label).toLowerCase();
}

/**
 * Firestore delete sentinels are legal in set() only when the write is a
 * merge. Keeping the options beside the tombstone data makes that invariant
 * unit-testable without requiring a Firestore emulator.
 */
export function accountDeletionTombstoneWrite(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    fail("ACCOUNT_DELETION_TOMBSTONE_INVALID", "account deletion tombstone must be an object");
  }
  return {data: {...data}, options: {merge: true}};
}

/**
 * Validates the unwrapped subscription resource returned by Portaly's cancel
 * endpoint. A normal end-of-period cancellation must explicitly set
 * cancelAtPeriodEnd=true. The only terminal alternative is the documented
 * exact `canceled` status, and even then the boolean field must be present.
 */
export function validateSubscriptionCancellationResponse(
  value,
  {subscriptionId} = {},
) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("SUBSCRIPTION_CANCEL_RESPONSE_INVALID", "cancellation response must be an object");
  }
  const expectedId = requiredString(
    subscriptionId,
    "EXPECTED_SUBSCRIPTION_ID_INVALID",
    "expected subscription id",
  );
  const identityFields = ["id", "subscriptionId"].filter((field) =>
    Object.prototype.hasOwnProperty.call(value, field));
  if (identityFields.length === 0) {
    fail("SUBSCRIPTION_CANCEL_ID_MISSING", "cancellation response subscription id is missing");
  }
  for (const field of identityFields) {
    const actualId = requiredString(
      value[field],
      "SUBSCRIPTION_CANCEL_ID_INVALID",
      `cancellation response ${field}`,
    );
    if (actualId !== expectedId) {
      fail("SUBSCRIPTION_CANCEL_ID_MISMATCH", "cancellation response subscription id does not match");
    }
  }
  if (typeof value.cancelAtPeriodEnd !== "boolean") {
    fail(
      "SUBSCRIPTION_CANCEL_CONFIRMATION_MISSING",
      "cancellation response cancelAtPeriodEnd must be a boolean",
    );
  }

  const status = requiredString(
    value.status,
    "SUBSCRIPTION_CANCEL_STATUS_INVALID",
    "cancellation response status",
  );
  if (!PORTALY_SUBSCRIPTION_STATUSES.has(status)) {
    fail("SUBSCRIPTION_CANCEL_STATUS_INVALID", "cancellation response status is unsupported");
  }
  if (status === "canceled" && value.cancelAtPeriodEnd !== false) {
    fail(
      "SUBSCRIPTION_CANCEL_STATE_INVALID",
      "a canceled subscription cannot remain scheduled for cancellation",
    );
  }
  if (status !== "canceled" && value.cancelAtPeriodEnd !== true) {
    fail(
      "SUBSCRIPTION_CANCEL_NOT_CONFIRMED",
      "cancellation response does not confirm cancellation",
    );
  }
  return value;
}

function validHttpsURL(value) {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (!normalized) return null;
  try {
    const url = new URL(normalized);
    return url.protocol === "https:" && url.hostname ? url : null;
  } catch {
    return null;
  }
}

export function createPortalSessionReservation({operationId, mode, now = Date.now()} = {}) {
  const normalizedOperationId = requiredString(
    operationId,
    "PORTAL_OPERATION_ID_INVALID",
    "portal operation id",
  );
  const normalizedMode = requiredString(mode, "EXPECTED_MODE_INVALID", "expected mode");
  if (!PORTALY_MODES.has(normalizedMode)) {
    fail("EXPECTED_MODE_INVALID", "expected mode must be live or test");
  }
  if (!Number.isFinite(now)) {
    fail("PORTAL_RESERVATION_TIME_INVALID", "portal reservation time must be finite");
  }
  return {
    status: "creating",
    operationId: normalizedOperationId,
    mode: normalizedMode,
    blockUntilMs: now + PORTAL_SESSION_SAFETY_WINDOW_MS,
  };
}

export function validatePortalSessionResponse(
  value,
  {operationId, mode, now = Date.now(), reservationBlockUntilMs} = {},
) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("PORTAL_SESSION_RESPONSE_INVALID", "portal session response must be an object");
  }
  const normalizedOperationId = requiredString(
    operationId,
    "PORTAL_OPERATION_ID_INVALID",
    "portal operation id",
  );
  const normalizedMode = requiredString(mode, "EXPECTED_MODE_INVALID", "expected mode");
  if (!PORTALY_MODES.has(normalizedMode)) {
    fail("EXPECTED_MODE_INVALID", "expected mode must be live or test");
  }
  const portalSessionId = requiredString(
    value.portalSessionId,
    "PORTAL_SESSION_ID_MISSING",
    "portal session id",
  );
  const portalURL = validHttpsURL(value.portalUrl);
  if (!portalURL) {
    fail("PORTAL_SESSION_URL_INVALID", "portal URL must be an HTTPS URL");
  }
  const expiresAt = requiredString(
    value.expiresAt,
    "PORTAL_SESSION_EXPIRY_MISSING",
    "portal session expiry",
  );
  const expiresAtMs = Date.parse(expiresAt);
  if (!Number.isFinite(expiresAtMs) || !Number.isFinite(now) || expiresAtMs <= now) {
    fail("PORTAL_SESSION_EXPIRY_INVALID", "portal session expiry must be in the future");
  }
  const minimumBlockUntilMs = expiresAtMs + PORTAL_SESSION_EXPIRY_GRACE_MS;
  const blockUntilMs = Number.isFinite(reservationBlockUntilMs) ?
    Math.max(reservationBlockUntilMs, minimumBlockUntilMs) : minimumBlockUntilMs;
  return {
    record: {
      status: "ready",
      operationId: normalizedOperationId,
      portalSessionId,
      mode: normalizedMode,
      expiresAt,
      expiresAtMs,
      blockUntilMs,
    },
    portalUrl: portalURL.toString(),
  };
}

export function portalSessionGuardDecision(
  portalSession,
  {mode, now = Date.now()} = {},
) {
  if (portalSession === undefined || portalSession === null) return {kind: "safe"};
  if (!portalSession || typeof portalSession !== "object" || Array.isArray(portalSession)) {
    return {kind: "portal_state_invalid"};
  }
  const blockUntilMs = Number(portalSession.blockUntilMs);
  if (!Number.isFinite(blockUntilMs)) return {kind: "portal_state_invalid"};
  if (blockUntilMs <= now) return {kind: "safe"};

  const operationId = typeof portalSession.operationId === "string" ?
    portalSession.operationId.trim() : "";
  if (!operationId || !PORTAL_SESSION_STATES.has(portalSession.status) ||
      !PORTALY_MODES.has(portalSession.mode) ||
      (mode !== undefined && portalSession.mode !== mode)) {
    return {kind: "portal_state_invalid"};
  }
  if (portalSession.status === "ready") {
    const portalSessionId = typeof portalSession.portalSessionId === "string" ?
      portalSession.portalSessionId.trim() : "";
    const expiresAtMs = Number(portalSession.expiresAtMs);
    const parsedExpiryMs = typeof portalSession.expiresAt === "string" ?
      Date.parse(portalSession.expiresAt) : Number.NaN;
    if (!portalSessionId || !Number.isFinite(expiresAtMs) ||
        !Number.isFinite(parsedExpiryMs) || parsedExpiryMs !== expiresAtMs ||
        blockUntilMs < expiresAtMs) {
      return {kind: "portal_state_invalid"};
    }
  }
  return {kind: "pending_portal", blockUntilMs};
}

export function needsSubscriptionCancellation(subscription = {}) {
  // `proActive` is the effective flag and may now be true solely because of
  // a server-owned grant.  An explicit Portaly terminal/empty status must not
  // trigger a provider cancellation for a grant-only account.  Keep the
  // status-less fallback for legacy records created before status was stored.
  const isActive = ACTIVE_SUBSCRIPTION_STATUSES.has(subscription.subscriptionStatus) ||
    (subscription.subscriptionStatus === undefined && subscription.proActive === true);
  return isActive && subscription.cancelAtPeriodEnd !== true;
}

export function unverifiedDeletionNeedsEmailVerification(
  subscription = {},
  {expectedMode} = {},
) {
  // A renewable subscription with no trustworthy mode could belong to the
  // active payment environment, so an unverified account must still stop.
  // Only an explicit valid opposite mode proves that no current-key
  // cancellation is required.
  if (PORTALY_MODES.has(expectedMode) &&
      PORTALY_MODES.has(subscription?.mode) &&
      subscription.mode !== expectedMode) {
    return false;
  }
  return needsSubscriptionCancellation(subscription);
}

export function deletedAccountCallbackNeedsCancellation({
  accountDeleted = false,
  subscriptionStatus,
  cancelAtPeriodEnd,
} = {}) {
  return accountDeleted === true &&
    ["active", "past_due"].includes(subscriptionStatus) &&
    cancelAtPeriodEnd !== true;
}

export function completedAccountDeletionMatches(
  lock,
  {accountUidHash, planId, mode} = {},
) {
  return Boolean(
    lock?.status === "account_deleted" &&
    requiredString(accountUidHash, "ACCOUNT_UID_HASH_INVALID", "account uid hash") ===
      lock.accountUidHash &&
    requiredString(planId, "EXPECTED_PLAN_ID_INVALID", "expected planId") === lock.planId &&
    requiredString(mode, "EXPECTED_MODE_INVALID", "expected mode") === lock.mode,
  );
}

export function accountDeletionGuardDecision({
  customerLock = null,
  legacyLocks = [],
  sessions = [],
  portalSession = null,
  planId,
  mode,
  now = Date.now(),
} = {}) {
  const portalDecision = portalSessionGuardDecision(portalSession, {mode, now});
  if (portalDecision.kind !== "safe") return portalDecision;

  const locks = [customerLock, ...(Array.isArray(legacyLocks) ? legacyLocks : [])]
    .filter((lock, index, values) => lock && values.indexOf(lock) === index);
  const scoped = (record) => mode !== undefined && record?.mode === undefined ?
    {...record, mode} : record;

  // Customer locks are intentionally email-scoped. Ownership by another UID
  // does not bypass a hold, which also protects an immediately re-registered
  // account using the same verified email.
  for (const lock of locks) {
    if (hasActiveCheckoutSafetyHold(scoped(lock), {planId, mode, now})) {
      return {kind: "safety_hold"};
    }
  }

  for (const lock of locks) {
    if (isReusableCheckoutSession(scoped(lock), {planId, mode, now})) {
      return {kind: "pending_checkout"};
    }
    const leaseExpiresAtMs = Number(lock?.leaseExpiresAtMs);
    const modeMatches = mode === undefined || lock?.mode === undefined || lock?.mode === mode;
    if (lock?.planId === planId && modeMatches && lock?.status === "creating" &&
        Number.isFinite(leaseExpiresAtMs) && leaseExpiresAtMs > now) {
      return {kind: "pending_checkout"};
    }
  }

  for (const session of Array.isArray(sessions) ? sessions : []) {
    if (isReusableCheckoutSession(scoped(session), {planId, mode, now})) {
      return {kind: "pending_checkout"};
    }
  }

  return {kind: "safe"};
}

/**
 * Selects every renewable Portaly subscription belonging to one account and
 * plan. The caller is expected to merge all list pages before calling this.
 *
 * Records for other customers or plans are ignored. Once a record is in scope,
 * however, it is validated strictly so an unexpected provider response cannot
 * make account deletion silently skip a renewal.
 */
export function selectSubscriptionIdsToCancel(
  subscriptions,
  {email, planId, mode} = {},
) {
  if (!Array.isArray(subscriptions)) {
    fail("SUBSCRIPTION_LIST_INVALID", "subscriptions must be an array");
  }

  const expectedEmail = normalizedEmail(
    email,
    "EXPECTED_EMAIL_INVALID",
    "expected email",
  );
  const expectedPlanId = requiredString(
    planId,
    "EXPECTED_PLAN_ID_INVALID",
    "expected planId",
  );
  const expectedMode = requiredString(
    mode,
    "EXPECTED_MODE_INVALID",
    "expected mode",
  );
  if (!PORTALY_MODES.has(expectedMode)) {
    fail("EXPECTED_MODE_INVALID", "expected mode must be live or test");
  }

  const ids = new Set();
  for (const subscription of subscriptions) {
    if (!subscription || typeof subscription !== "object" || Array.isArray(subscription)) {
      fail("SUBSCRIPTION_INVALID", "subscription must be an object");
    }

    const customerEmail = normalizedEmail(
      subscription.customerEmail,
      "SUBSCRIPTION_EMAIL_MISSING",
      "subscription customerEmail",
    );
    const subscriptionPlanId = requiredString(
      subscription.planId,
      "SUBSCRIPTION_PLAN_ID_MISSING",
      "subscription planId",
    );

    if (customerEmail !== expectedEmail || subscriptionPlanId !== expectedPlanId) {
      continue;
    }

    const subscriptionMode = requiredString(
      subscription.mode,
      "SUBSCRIPTION_MODE_MISSING",
      "subscription mode",
    );
    if (!PORTALY_MODES.has(subscriptionMode)) {
      fail("SUBSCRIPTION_MODE_INVALID", "subscription mode must be live or test");
    }
    if (subscriptionMode !== expectedMode) {
      fail(
        "SUBSCRIPTION_MODE_MISMATCH",
        "Portaly subscription mode does not match the API key mode",
      );
    }

    const status = requiredString(
      subscription.status,
      "SUBSCRIPTION_STATUS_MISSING",
      "subscription status",
    );
    if (!PORTALY_SUBSCRIPTION_STATUSES.has(status)) {
      fail("SUBSCRIPTION_STATUS_INVALID", "subscription status is not supported");
    }
    if (typeof subscription.cancelAtPeriodEnd !== "boolean") {
      fail(
        "CANCEL_AT_PERIOD_END_MISSING",
        "subscription cancelAtPeriodEnd must be a boolean",
      );
    }

    const id = requiredString(
      subscription.id,
      "SUBSCRIPTION_ID_MISSING",
      "subscription id",
    );
    if (status !== "canceled" && subscription.cancelAtPeriodEnd === false) {
      ids.add(id);
    }
  }

  return [...ids];
}
