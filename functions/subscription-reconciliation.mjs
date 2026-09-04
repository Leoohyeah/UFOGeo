/**
 * Convert the authoritative Portaly subscription response into the small,
 * allow-listed patch that may be merged into a UFOGeo user document.
 *
 * This module deliberately has no Firebase or network dependencies.  The
 * caller is responsible for fetching Portaly and for writing the returned
 * object in a transaction.  Keeping the reconciliation decision pure makes it
 * possible to test the safety checks without a live subscription or database.
 */

const PORTALY_MODES = new Set(["test", "live"]);
const SUBSCRIPTION_STATUSES = new Set(["active", "past_due", "canceled"]);

const OPTIONAL_DATE_FIELDS = [
  "nextBillingAt",
  "cancelEffectiveAt",
  "cancelRequestedAt",
  "canceledAt",
  "lastChargedAt",
  "lastFailureAt",
];

const OPTIONAL_NUMBER_FIELDS = ["failureCount"];

function epochMs(value) {
  if (typeof value === "number") return Number.isFinite(value) ? value : Number.NaN;
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : Number.NaN;
  }
  if (value instanceof Date) return value.getTime();
  if (typeof value?.toDate === "function") {
    try {
      return value.toDate().getTime();
    } catch {
      return Number.NaN;
    }
  }
  return Number.NaN;
}

/**
 * Return the latest provider verification marker without inventing a current
 * timestamp for records that have never received a callback or reconciliation.
 */
export function subscriptionVerificationTimestamp(data = {}) {
  if (!isRecord(data)) return null;
  const timestamps = [
    data.lastCallbackAtMs,
    data.lastReconciledAtMs,
    data.lastReconciledAt,
  ].map(epochMs).filter(Number.isFinite);
  return timestamps.length > 0 ? new Date(Math.max(...timestamps)).toISOString() : null;
}

/**
 * An unsafe reconciliation is a caller/data-contract error, not a Portaly
 * outage.  `code` is stable so the HTTP layer can turn a mismatch into a
 * conflict response without exposing provider details to the app.
 */
export class SubscriptionReconciliationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "SubscriptionReconciliationError";
    this.code = code;
    this.statusCode = 409;
  }
}

function fail(code, message) {
  throw new SubscriptionReconciliationError(code, message);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requiredString(value, code, label) {
  if (typeof value !== "string" || value.trim().length === 0) {
    fail(code, `Portaly subscription ${label} is missing or invalid`);
  }
  return value.trim();
}

function unwrapSubscriptionResponse(remote) {
  if (!isRecord(remote)) {
    fail("SUBSCRIPTION_RESPONSE_INVALID", "Portaly subscription response is not an object");
  }

  // Portaly API responses are normally `{data: {...}}`; accepting the direct
  // object as well keeps this helper usable with a response already unwrapped
  // by the HTTP layer.  Do not accept an arbitrary nested object: the caller
  // must pass the subscription returned by the documented endpoint.
  if (isRecord(remote.data)) return remote.data;
  return remote;
}

function validateExpected(value, code, label) {
  if (value === undefined || value === null) return undefined;
  return requiredString(value, code, label);
}

function validateMode(value, code, label) {
  const mode = requiredString(value, code, label);
  if (!PORTALY_MODES.has(mode)) {
    fail(code, `Portaly subscription ${label} must be 'test' or 'live'`);
  }
  return mode;
}

function validateBoolean(value, code, label) {
  if (typeof value !== "boolean") {
    fail(code, `Portaly subscription ${label} is missing or invalid`);
  }
  return value;
}

function currentIdentifiers(current) {
  const identifiers = [];
  for (const [field, value] of [
    ["subscriptionId", current.subscriptionId],
    ["currentCheckoutSessionId", current.currentCheckoutSessionId],
  ]) {
    if (value === undefined || value === null || value === "") continue;
    if (typeof value !== "string" || value.trim().length === 0) {
      fail("CURRENT_SUBSCRIPTION_ID_INVALID", `Current user ${field} is invalid`);
    }
    identifiers.push({field, value: value.trim()});
  }
  return identifiers;
}

function copyOptionalFields(target, source) {
  for (const field of OPTIONAL_DATE_FIELDS) {
    if (source[field] !== undefined) {
      if (source[field] === null) {
        // An explicit null from Portaly is meaningful: for example, resume
        // clears cancelEffectiveAt.  Preserve it so a merge patch removes a
        // stale value left by the preceding cancel_requested state.
        target[field] = null;
        continue;
      }
      // Portaly returns ISO strings.  Preserve only scalar date values so no
      // provider object or prototype can be written to Firestore.
      if (typeof source[field] !== "string" || source[field].trim().length === 0) {
        fail("SUBSCRIPTION_FIELD_INVALID", `Portaly subscription ${field} is invalid`);
      }
      target[field] = source[field];
    }
  }
  for (const field of OPTIONAL_NUMBER_FIELDS) {
    if (source[field] !== undefined) {
      if (source[field] === null) {
        target[field] = null;
        continue;
      }
      if (!Number.isFinite(source[field]) || source[field] < 0) {
        fail("SUBSCRIPTION_FIELD_INVALID", `Portaly subscription ${field} is invalid`);
      }
      target[field] = source[field];
    }
  }
}

/**
 * Return whether the entitlement fields in a current user record already
 * represent the state described by a freshly fetched Portaly subscription.
 *
 * A callback can win the race between the Portaly GET and the reconciliation
 * transaction.  In that case the callback has already applied the same state
 * that the GET returned; allowing the transaction to finish is idempotent,
 * while a genuinely different state must still abort to avoid overwriting a
 * newer provider event.
 */
export function subscriptionStateMatchesPatch(current = {}, patch = {}) {
  if (!isRecord(current) || !isRecord(patch)) return false;
  for (const [field, expected] of [
    ["subscriptionId", patch.subscriptionId],
    ["currentCheckoutSessionId", patch.currentCheckoutSessionId],
    ["mode", patch.mode],
    ["subscriptionStatus", patch.subscriptionStatus],
    ["proActive", patch.proActive],
    ["cancelAtPeriodEnd", patch.cancelAtPeriodEnd],
  ]) {
    const actual = current[field] === undefined || current[field] === null ? null : current[field];
    const normalizedExpected = expected === undefined || expected === null ? null : expected;
    if (actual !== normalizedExpected) return false;
  }
  return true;
}

/**
 * Reconcile one Portaly GET subscription response.
 *
 * `expectedSubscriptionId` and `expectedMode` should be the values selected by
 * the authenticated user's current Firestore record / server configuration.
 * If omitted, an existing current user identifier or mode is still enforced;
 * omitting both is only allowed for an unassigned user.  This prevents a
 * response for another subscription or another Portaly environment from being
 * merged into the current member document.
 *
 * @param {object} options
 * @param {object} [options.current] Existing UFOGeo user subscription fields.
 * @param {object} options.remote Portaly GET response, wrapped or unwrapped.
 * @param {string} [options.expectedSubscriptionId] ID used in the GET request.
 * @param {"test"|"live"} [options.expectedMode] Mode derived from the API key.
 * @returns {object} A plain, allow-listed Firestore merge patch.
 */
export function reconciledSubscriptionState({
  current = {},
  remote,
  expectedSubscriptionId,
  expectedMode,
  expectedPlanId,
} = {}) {
  if (!isRecord(current)) {
    fail("CURRENT_USER_INVALID", "Current user subscription state is not an object");
  }

  const currentIds = currentIdentifiers(current);
  const expectedId = validateExpected(
    expectedSubscriptionId,
    "EXPECTED_SUBSCRIPTION_ID_INVALID",
    "expected subscription ID",
  );
  const expectedPortalyMode = expectedMode === undefined || expectedMode === null ? undefined :
    validateMode(expectedMode, "EXPECTED_MODE_INVALID", "expected mode");
  const expectedPortalyPlanId = validateExpected(
    expectedPlanId,
    "EXPECTED_PLAN_ID_INVALID",
    "expected plan ID",
  );
  const value = unwrapSubscriptionResponse(remote);

  const remoteId = requiredString(
    value.id ?? value.subscriptionId,
    "SUBSCRIPTION_ID_MISSING",
    "ID",
  );
  // If both aliases are present, they are two claims about the same resource;
  // accepting conflicting aliases could reconcile the wrong subscription.
  if (value.id !== undefined && value.subscriptionId !== undefined) {
    const aliasId = requiredString(
      value.subscriptionId,
      "SUBSCRIPTION_ID_INVALID",
      "subscription ID",
    );
    if (aliasId !== remoteId) {
      fail("SUBSCRIPTION_ID_MISMATCH", "Portaly subscription ID fields do not match");
    }
  }

  if (expectedId && remoteId !== expectedId) {
    fail("SUBSCRIPTION_ID_MISMATCH", "Portaly subscription ID does not match the requested subscription");
  }
  for (const currentId of currentIds) {
    if (remoteId !== currentId.value) {
      fail("SUBSCRIPTION_ID_MISMATCH", `Portaly subscription ID does not match current ${currentId.field}`);
    }
  }

  const remoteMode = validateMode(value.mode, "SUBSCRIPTION_MODE_MISSING", "mode");
  if (expectedPortalyMode && remoteMode !== expectedPortalyMode) {
    fail("SUBSCRIPTION_MODE_MISMATCH", "Portaly subscription mode does not match the API key mode");
  }
  if (current.mode !== undefined && current.mode !== null) {
    const currentMode = validateMode(current.mode, "CURRENT_MODE_INVALID", "current mode");
    if (remoteMode !== currentMode) {
      fail("SUBSCRIPTION_MODE_MISMATCH", "Portaly subscription mode does not match current user mode");
    }
  }

  const remotePlanId = requiredString(
    value.planId ?? value.plan?.id,
    "SUBSCRIPTION_PLAN_ID_MISSING",
    "plan ID",
  );
  const currentPlanId = validateExpected(
    current.planId,
    "CURRENT_PLAN_ID_INVALID",
    "current plan ID",
  );
  if (expectedPortalyPlanId && currentPlanId && currentPlanId !== expectedPortalyPlanId) {
    fail("CURRENT_PLAN_ID_MISMATCH", "Current user plan does not match the configured plan");
  }
  if (expectedPortalyPlanId && remotePlanId !== expectedPortalyPlanId) {
    fail("SUBSCRIPTION_PLAN_MISMATCH", "Portaly subscription plan does not match the configured plan");
  }
  if (currentPlanId && remotePlanId !== currentPlanId) {
    fail("SUBSCRIPTION_PLAN_MISMATCH", "Portaly subscription plan does not match the current user plan");
  }

  const status = requiredString(value.status, "SUBSCRIPTION_STATUS_MISSING", "status");
  if (!SUBSCRIPTION_STATUSES.has(status)) {
    fail("SUBSCRIPTION_STATUS_INVALID", "Portaly subscription status is unsupported");
  }
  const cancelAtPeriodEnd = validateBoolean(
    value.cancelAtPeriodEnd,
    "CANCEL_AT_PERIOD_END_MISSING",
    "cancelAtPeriodEnd",
  );
  if (status === "canceled" && cancelAtPeriodEnd) {
    fail("SUBSCRIPTION_STATE_INVALID", "A canceled Portaly subscription cannot cancel at period end");
  }

  // `past_due` is a grace state: the subscription remains entitled to Pro
  // while Portaly retries the renewal.  A cancellation request also keeps Pro
  // active until the period ends.
  const patch = {
    subscriptionId: remoteId,
    currentCheckoutSessionId: remoteId,
    mode: remoteMode,
    proActive: status !== "canceled",
    subscriptionStatus: status === "active" && cancelAtPeriodEnd ?
      "cancel_requested" : status,
    cancelAtPeriodEnd,
  };
  copyOptionalFields(patch, value);

  return patch;
}

/**
 * Convenience adapter for the HTTP/API layer.  It keeps the reconciliation
 * decision above as the single source of truth while returning the three
 * independent Firestore-safe records commonly needed by a status refresh:
 * the user entitlement, the checkout-session snapshot, and an audit record.
 *
 * The adapter intentionally does not add Firestore sentinels or server
 * timestamps.  The caller can add `FieldValue.serverTimestamp()` at write time
 * and can choose the document references transactionally.
 *
 * `expectedSubscriptionId` and `expectedMode` are optional overrides for
 * callers that already resolved the request target from the URL/API key.  If
 * omitted, they are derived from the current user record.
 */
export function reconcileSubscription({
  currentUser = {},
  subscription,
  expectedSubscriptionId,
  expectedMode,
  expectedPlanId,
  now,
} = {}) {
  if (!isRecord(currentUser)) {
    fail("CURRENT_USER_INVALID", "Current user subscription state is not an object");
  }

  const currentSubscriptionId = typeof currentUser.subscriptionId === "string" &&
    currentUser.subscriptionId.trim().length > 0 ? currentUser.subscriptionId :
    typeof currentUser.currentCheckoutSessionId === "string" &&
    currentUser.currentCheckoutSessionId.trim().length > 0 ?
      currentUser.currentCheckoutSessionId : undefined;

  const userPatch = reconciledSubscriptionState({
    current: currentUser,
    remote: subscription,
    expectedSubscriptionId: expectedSubscriptionId ?? currentSubscriptionId,
    expectedMode: expectedMode ?? currentUser.mode,
    expectedPlanId,
  });

  const sessionPatch = {
    subscriptionId: userPatch.subscriptionId,
    mode: userPatch.mode,
    status: userPatch.subscriptionStatus,
    cancelAtPeriodEnd: userPatch.cancelAtPeriodEnd,
  };
  for (const field of OPTIONAL_DATE_FIELDS) {
    if (userPatch[field] !== undefined) sessionPatch[field] = userPatch[field];
  }
  if (userPatch.failureCount !== undefined) sessionPatch.failureCount = userPatch.failureCount;

  const audit = {
    type: "subscription_reconciliation",
    subscriptionId: userPatch.subscriptionId,
    mode: userPatch.mode,
    status: userPatch.subscriptionStatus,
    proActive: userPatch.proActive,
    cancelAtPeriodEnd: userPatch.cancelAtPeriodEnd,
    source: "portaly_subscription_query",
  };
  if (now !== undefined && now !== null) {
    const nowMs = now instanceof Date ? now.getTime() :
      typeof now === "number" ? now :
      typeof now === "string" ? Date.parse(now) : Number.NaN;
    if (!Number.isFinite(nowMs)) {
      fail("RECONCILIATION_TIME_INVALID", "Reconciliation time is invalid");
    }
    audit.reconciledAtMs = nowMs;
  }

  return {userPatch, sessionPatch, audit};
}
