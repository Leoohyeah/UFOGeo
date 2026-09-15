import {
  normalizeCustomerEmail,
  validatedPortalySubscriptions,
} from "./customer-subscription-guard.mjs";
import {
  reconciledSubscriptionState,
} from "./subscription-reconciliation.mjs";
import {isPortalyMode} from "./portaly-mode.mjs";

export const RECOVERY_LOCK_STATUS = "recovery_in_progress";
// The provider reads are bounded by the 15-second Portaly request timeout. A
// recovery lease is intentionally longer than one request/page sequence, but
// it is still short enough that a crashed read does not block checkout
// indefinitely. The final transaction always re-checks the lease owner.
export const RECOVERY_LEASE_MS = 5 * 60 * 1000;

const RECOVERABLE_STATUSES = new Set(["active", "past_due", "cancel_requested"]);
const TERMINAL_STATUSES = new Set(["canceled", "checkout_failed", "none"]);
const PENDING_STATUSES = new Set(["pending", "created", "checkout_ready"]);
const ACTIVE_STATUSES = new Set(["active", "past_due", "cancel_requested"]);
const RECOVERY_OUTCOME_STATUSES = new Set(["recovered", "already_bound", "not_found"]);
const PORTALY_STATUSES = new Set([
  "none",
  "pending",
  "created",
  "checkout_ready",
  "checkout_failed",
  "active",
  "past_due",
  "cancel_requested",
  "canceled",
]);
const RECOVERY_OPTIONAL_PROVIDER_FIELDS = [
  "nextBillingAt",
  "cancelEffectiveAt",
  "cancelRequestedAt",
  "canceledAt",
  "lastChargedAt",
  "lastFailureAt",
  "failureCount",
];

function fail(code, message) {
  throw Object.assign(new Error(message), {code});
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function documentId(value) {
  const candidate = nonBlankString(value);
  return candidate && candidate !== "." && candidate !== ".." &&
    !candidate.includes("/") && Buffer.byteLength(candidate, "utf8") <= 1500 ?
    candidate : null;
}

function timestampMs(value) {
  if (typeof value === "number") return Number.isFinite(value) ? value : Number.NaN;
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

function requiredExpectedScope({email, planId, mode} = {}) {
  const normalizedEmail = normalizeCustomerEmail(email);
  const normalizedPlanId = nonBlankString(planId);
  if (!normalizedEmail) fail("RECOVERY_EMAIL_INVALID", "Recovery email is invalid");
  if (!normalizedPlanId) fail("RECOVERY_PLAN_INVALID", "Recovery plan is invalid");
  if (!isPortalyMode(mode)) fail("RECOVERY_MODE_INVALID", "Recovery mode is invalid");
  return {email: normalizedEmail, planId: normalizedPlanId, mode};
}

function candidateFingerprint(subscription) {
  return JSON.stringify([
    subscription.id,
    normalizeCustomerEmail(subscription.customerEmail),
    subscription.planId,
    subscription.mode,
    subscription.status,
    subscription.cancelAtPeriodEnd,
  ]);
}

/**
 * Select the only current-environment subscription that may restore Pro.
 *
 * The list response is validated strictly for the requested customer, plan,
 * and API-key mode. Canceled records are valid history but are not recovery
 * candidates. Repeated pages may contain the same id; identical repeats are
 * collapsed, while conflicting copies fail closed.
 */
export function selectRecoverableSubscription(
  subscriptions,
  {email, planId, mode} = {},
) {
  if (!Array.isArray(subscriptions)) {
    fail("RECOVERY_SUBSCRIPTIONS_INVALID", "Recovery subscriptions must be an array");
  }
  const scope = requiredExpectedScope({email, planId, mode});
  const validated = validatedPortalySubscriptions(subscriptions, scope);
  const byId = new Map();
  for (const subscription of validated) {
    const id = documentId(subscription.id);
    if (!id) fail("RECOVERY_SUBSCRIPTION_ID_INVALID", "Recovery subscription id is invalid");
    const prior = byId.get(id);
    if (prior && candidateFingerprint(prior) !== candidateFingerprint(subscription)) {
      fail(
        "RECOVERY_SUBSCRIPTION_DUPLICATE_CONFLICT",
        "Recovery subscription appears with conflicting provider state",
      );
    }
    if (!prior) byId.set(id, subscription);
  }

  const candidates = [...byId.values()].filter((subscription) => {
    if (!RECOVERABLE_STATUSES.has(subscription.status)) return false;
    // The canonical product projection represents an active subscription with
    // cancelAtPeriodEnd=true as cancel_requested. A past_due subscription is
    // still entitled to Pro during the provider retry/grace period, including
    // when cancellation has also been requested.
    return true;
  });
  if (candidates.length > 1) {
    fail(
      "SUBSCRIPTION_RECOVERY_AMBIGUOUS",
      "More than one active Portaly subscription matches this email and plan",
    );
  }
  return candidates[0] || null;
}

function unwrapSubscription(remote) {
  if (!isRecord(remote)) {
    fail("RECOVERY_PROVIDER_RESPONSE_INVALID", "Portaly recovery response is invalid");
  }
  const value = isRecord(remote.data) ? remote.data : remote;
  if (!isRecord(value)) {
    fail("RECOVERY_PROVIDER_RESPONSE_INVALID", "Portaly recovery response is invalid");
  }
  return value;
}

/**
 * Validate the authoritative GET /subscriptions/{id} response and produce
 * the existing allow-listed reconciliation patch. The list response is the
 * ownership proof because Portaly's documented subscription detail response
 * does not promise a customerEmail field. If a deployment includes that
 * optional field, validate it too; never require or infer a nested email.
 */
export function recoveredSubscriptionState({
  remote,
  subscriptionId,
  email,
  planId,
  mode,
} = {}) {
  const scope = requiredExpectedScope({email, planId, mode});
  const expectedId = documentId(subscriptionId);
  if (!expectedId) fail("RECOVERY_SUBSCRIPTION_ID_INVALID", "Recovery subscription id is invalid");
  const value = unwrapSubscription(remote);
  if (value.customerEmail !== undefined && value.customerEmail !== null) {
    const providerEmail = normalizeCustomerEmail(value.customerEmail);
    if (!providerEmail) {
      fail("RECOVERY_PROVIDER_EMAIL_INVALID", "Portaly recovery subscription email is invalid");
    }
    if (providerEmail !== scope.email) {
      fail("RECOVERY_PROVIDER_EMAIL_MISMATCH", "Portaly recovery subscription email does not match");
    }
  }
  for (const field of ["sessionId", "checkoutSessionId"]) {
    if (value[field] !== undefined && value[field] !== null) {
      const actual = documentId(value[field]);
      if (!actual || actual !== expectedId) {
        fail("RECOVERY_PROVIDER_SESSION_MISMATCH", "Portaly recovery session does not match");
      }
    }
  }

  const state = reconciledSubscriptionState({
    current: {},
    remote,
    expectedSubscriptionId: expectedId,
    expectedMode: scope.mode,
    expectedPlanId: scope.planId,
  });
  return {
    value,
    state,
    recoverable: state.proActive === true && ACTIVE_STATUSES.has(state.subscriptionStatus),
  };
}

/**
 * A list response can race a detail response: Portaly may list a subscription
 * as active while the detail endpoint already reports it canceled.  Treat the
 * provider's terminal detail as a normal no-match result, while preserving a
 * distinct state-change error for any non-terminal inconsistency.
 */
export function recoveryProviderDetailDecision({recoverable = false, subscriptionStatus} = {}) {
  if (recoverable === true) return {kind: "recoverable"};
  if (subscriptionStatus === "canceled") return {kind: "not_found"};
  return {kind: "state_changed"};
}

/**
 * Build the logical user state used for a recovery response.  The Firestore
 * write patch may contain FieldValue.delete() transforms for optional fields
 * omitted by the latest provider response; those transforms must never be
 * passed to subscriptionStateResponse.  Start from the persisted snapshot and
 * the plain reconciliation state, then remove stale optional fields that the
 * provider did not return.
 */
export function recoveryResponseData(
  current = {},
  state = {},
  {planId} = {},
) {
  if (!isRecord(current) || !isRecord(state)) {
    fail("RECOVERY_RESPONSE_STATE_INVALID", "Recovery response state is invalid");
  }
  const response = {...current, ...state};
  if (planId !== undefined) response.planId = planId;
  for (const field of RECOVERY_OPTIONAL_PROVIDER_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(state, field)) delete response[field];
  }
  return response;
}

function idOrNull(value) {
  if (value === undefined || value === null || value === "") return null;
  return documentId(value);
}

function providerFootprint(data) {
  return [
    "mode",
    "subscriptionStatus",
    "proActive",
    "subscriptionId",
    "currentCheckoutSessionId",
    "planId",
    "cancelAtPeriodEnd",
  ].some((field) => Object.prototype.hasOwnProperty.call(data, field));
}

/**
 * Decide whether an existing local user record can be replaced by a verified
 * email recovery. Active/pending bindings are never silently stolen by a
 * different provider id. Terminal history may be replaced by the one
 * authoritative current subscription selected from Portaly.
 */
export function recoveryBindingDecision(
  data = {},
  {candidateId, planId, mode} = {},
) {
  if (!isRecord(data) || Array.isArray(data)) {
    return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
  }
  if (data.accountDeleted === true || data.accountDeleting === true ||
      nonBlankString(data.accountDeletionId)) {
    return {kind: "conflict", code: "ACCOUNT_DELETION_IN_PROGRESS"};
  }
  const expectedId = documentId(candidateId);
  if (!expectedId || !isPortalyMode(mode) || !nonBlankString(planId)) {
    return {kind: "conflict", code: "RECOVERY_CONTEXT_INVALID"};
  }

  if (!providerFootprint(data)) return {kind: "allow"};

  const status = data.subscriptionStatus;
  const subscriptionId = idOrNull(data.subscriptionId);
  const checkoutId = idOrNull(data.currentCheckoutSessionId);
  const hasSubscriptionId = data.subscriptionId !== undefined &&
    data.subscriptionId !== null && data.subscriptionId !== "";
  const hasCheckoutId = data.currentCheckoutSessionId !== undefined &&
    data.currentCheckoutSessionId !== null && data.currentCheckoutSessionId !== "";
  if ((hasSubscriptionId && !subscriptionId) || (hasCheckoutId && !checkoutId) ||
      (subscriptionId && checkoutId && subscriptionId !== checkoutId)) {
    return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
  }

  const storedMode = data.mode;
  if (storedMode !== undefined && storedMode !== null && !isPortalyMode(storedMode)) {
    return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
  }
  const storedPlan = data.planId;
  if (storedPlan !== undefined && storedPlan !== null &&
      (typeof storedPlan !== "string" || storedPlan.trim() !== storedPlan ||
       storedPlan.length === 0)) {
    return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
  }
  if (storedPlan && storedPlan !== planId && status !== "none") {
    return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_CONFLICT"};
  }

  // A known opposite environment is historical. It must not block recovery
  // for the API-key's current mode, but a malformed current-mode record does.
  const historicalOpposite = storedMode && storedMode !== mode;
  if (status === "none") {
    if (data.proActive !== false || subscriptionId || checkoutId ||
        data.cancelAtPeriodEnd !== false) {
      return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
    }
    return {kind: "allow", historicalOpposite};
  }
  if (status === "checkout_failed") {
    if (data.proActive !== false || subscriptionId || !checkoutId ||
        data.cancelAtPeriodEnd !== false) {
      return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
    }
    return {kind: "allow", historicalOpposite};
  }
  if (PENDING_STATUSES.has(status)) {
    return {kind: "conflict", code: "RECOVERY_PENDING_CHECKOUT"};
  }
  if (TERMINAL_STATUSES.has(status) && status === "canceled") {
    if (!subscriptionId || checkoutId !== subscriptionId || data.proActive !== false ||
        data.cancelAtPeriodEnd !== false) {
      return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
    }
    return {kind: "allow", historicalOpposite};
  }
  if (ACTIVE_STATUSES.has(status)) {
    if (!subscriptionId || checkoutId !== subscriptionId || data.proActive !== true ||
        typeof data.cancelAtPeriodEnd !== "boolean") {
      return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
    }
    if (data.cancelAtPeriodEnd !== (status === "cancel_requested")) {
      return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
    }
    if (historicalOpposite) return {kind: "allow", historicalOpposite: true};
    if (storedMode !== mode || storedPlan !== planId) {
      return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_CONFLICT"};
    }
    if (subscriptionId !== expectedId) {
      return {kind: "conflict", code: "RECOVERY_EXISTING_BINDING_CONFLICT"};
    }
    return {kind: "already_bound"};
  }

  return {kind: "conflict", code: "RECOVERY_LOCAL_STATE_INVALID"};
}

/**
 * Validate the email-scoped recovery lease before a recovery or checkout
 * operation uses it. Expired read-only recovery leases may be replaced; an
 * active lease blocks checkout and another recovery attempt.
 */
export function recoveryLockDecision(
  lock,
  {planId, mode, now = Date.now()} = {},
) {
  if (!Number.isFinite(now) || !nonBlankString(planId) || !isPortalyMode(mode)) {
    return {kind: "conflict", code: "RECOVERY_CONTEXT_INVALID"};
  }
  if (lock === undefined || lock === null) return {kind: "acquire"};
  if (!isRecord(lock)) return {kind: "conflict", code: "RECOVERY_LOCK_INVALID"};
  if (lock.planId !== planId || lock.mode !== mode) {
    return {kind: "conflict", code: "RECOVERY_LOCK_SCOPE_CONFLICT"};
  }
  if (lock.status === "account_deleting") {
    return {kind: "conflict", code: "ACCOUNT_DELETION_IN_PROGRESS"};
  }
  if (lock.status === "account_deleted") {
    // Account deletion intentionally leaves one email-scoped tombstone so a
    // new Firebase UID cannot silently reuse the old checkout.  The bounded
    // deletion safety window must elapse before a verified recovery may
    // inspect the provider for that email.  Only a complete tombstone proves
    // that the old UID was deleted; legacy or malformed copies remain
    // fail-closed rather than becoming an ownership shortcut.
    const accountUidHash = nonBlankString(lock.accountUidHash);
    const safetyHoldUntilMs = timestampMs(lock.safetyHoldUntilMs);
    if (!accountUidHash || Object.prototype.hasOwnProperty.call(lock, "uid") ||
        !Number.isFinite(safetyHoldUntilMs)) {
      return {kind: "conflict", code: "ACCOUNT_DELETION_TOMBSTONE_INVALID"};
    }
    if (safetyHoldUntilMs > now) {
      // The hold prevents an immediate same-email reclaim, but a verified
      // account may perform a read-only provider inspection.  The caller must
      // restore this tombstone on any provider error or renewable result.
      return {kind: "inspection_only_tombstone", accountUidHash};
    }
    return {kind: "reclaimable_tombstone", accountUidHash};
  }
  if (lock.status === RECOVERY_LOCK_STATUS) {
    const leaseExpiresAtMs = timestampMs(lock.leaseExpiresAtMs);
    if (!Number.isFinite(leaseExpiresAtMs)) {
      return {kind: "conflict", code: "RECOVERY_LOCK_INVALID"};
    }
    return leaseExpiresAtMs > now ?
      {kind: "in_progress", leaseExpiresAtMs} : {kind: "acquire"};
  }
  if (["uncertain"].includes(lock.status)) {
    return {kind: "conflict", code: "CHECKOUT_SAFETY_HOLD"};
  }
  if (["creating"].includes(lock.status)) {
    const leaseExpiresAtMs = timestampMs(lock.leaseExpiresAtMs);
    const safetyHoldUntilMs = timestampMs(lock.safetyHoldUntilMs);
    if (!Number.isFinite(leaseExpiresAtMs) || !Number.isFinite(safetyHoldUntilMs)) {
      return {kind: "conflict", code: "CHECKOUT_SAFETY_HOLD"};
    }
    if (leaseExpiresAtMs > now || safetyHoldUntilMs > now) {
      return {kind: "conflict", code: "CHECKOUT_IN_PROGRESS"};
    }
    return {kind: "acquire"};
  }
  if (PENDING_STATUSES.has(lock.status)) {
    const expiresAtMs = timestampMs(lock.expiresAt);
    if (!Number.isFinite(expiresAtMs)) {
      return {kind: "conflict", code: "CHECKOUT_SAFETY_HOLD"};
    }
    return expiresAtMs > now ?
      {kind: "conflict", code: "PENDING_CHECKOUT_EXISTS"} : {kind: "acquire"};
  }
  if (new Set(["completed", "failed", "expired", "canceled", "cancelled"]).has(lock.status)) {
    return {kind: "acquire"};
  }
  return {kind: "conflict", code: "RECOVERY_LOCK_INVALID"};
}

export function recoveryLockIsActive(lock, {now = Date.now()} = {}) {
  if (!isRecord(lock) || lock.status !== RECOVERY_LOCK_STATUS) return false;
  const expiry = timestampMs(lock.leaseExpiresAtMs);
  return Number.isFinite(expiry) && expiry > now;
}

/**
 * The recovery endpoint has one stable success envelope. Keeping this as a
 * pure helper prevents a no-match response from accidentally falling back to
 * the ordinary subscription endpoint shape.
 */
export function recoveryResponseEnvelope(value, status) {
  if (!isRecord(value) || !RECOVERY_OUTCOME_STATUSES.has(status)) {
    fail("RECOVERY_RESPONSE_INVALID", "Recovery response envelope is invalid");
  }
  return {value, recovery: {status}};
}

/**
 * Run discovery while holding the email-scoped recovery lease. The provider
 * lookup must never happen before `reserve`; otherwise a concurrent checkout
 * could win the lock while recovery is still paging Portaly. A no-match or
 * failed lookup releases the lease exactly once.
 */
export async function executeRecoveryWithLease({
  reserve,
  discover,
  finalize,
  release,
} = {}) {
  if (typeof reserve !== "function" || typeof discover !== "function" ||
      typeof finalize !== "function" || typeof release !== "function") {
    fail("RECOVERY_WORKFLOW_INVALID", "Recovery workflow dependencies are invalid");
  }
  const reservation = await reserve();
  let released = false;
  const releaseOnce = async () => {
    if (released) return;
    released = true;
    await release(reservation);
  };
  try {
    const recovered = await discover({reservation});
    if (!recovered) {
      await releaseOnce();
      return {status: "not_found", value: null, reservation};
    }
    const finalized = await finalize({reservation, recovered});
    const status = finalized?.status === "already_bound" ? "already_bound" : "recovered";
    return {
      status,
      value: finalized?.value ?? finalized,
      reservation,
    };
  } catch (error) {
    try {
      await releaseOnce();
    } catch (releaseError) {
      // The original error remains the externally visible cause. Retaining the
      // release failure gives the HTTP layer an opportunity to log it; an
      // uncleared lease is safe because checkout remains blocked until expiry.
      if (error && (typeof error === "object" || typeof error === "function")) {
        error.recoveryReleaseError = releaseError;
      }
    }
    throw error;
  }
}
