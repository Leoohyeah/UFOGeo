import {resolveEntitlement} from "./entitlement-resolver.mjs";
import {isPortalyMode} from "./portaly-mode.mjs";
import {subscriptionVerificationTimestamp} from "./subscription-reconciliation.mjs";

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
const PENDING_STATUSES = new Set(["pending", "created", "checkout_ready"]);
const ACTIVE_STATUSES = new Set(["active", "past_due", "cancel_requested"]);
const EXPIRING_ELIGIBLE_STATUSES = new Set(["active", "past_due", "cancel_requested"]);
const PROVIDER_FIELDS = [
  "mode",
  "subscriptionStatus",
  "proActive",
  "subscriptionId",
  "currentCheckoutSessionId",
  "planId",
  "cancelAtPeriodEnd",
  "nextBillingAt",
  "cancelEffectiveAt",
];

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function validDocumentId(value) {
  const identifier = nonBlankString(value);
  return identifier && identifier !== "." && identifier !== ".." &&
    !identifier.includes("/") && Buffer.byteLength(identifier, "utf8") <= 1500 ?
    identifier : null;
}

function unavailablePaymentState(expectedMode, fallbackPlanId) {
  return {
    valid: false,
    subscriptionStatus: "unavailable",
    subscriptionId: null,
    planId: fallbackPlanId,
    mode: isPortalyMode(expectedMode) ? expectedMode : null,
    nextBillingAt: null,
    cancelAtPeriodEnd: false,
    cancelEffectiveAt: null,
  };
}

function emptyPaymentState(expectedMode, fallbackPlanId) {
  return {
    valid: true,
    subscriptionStatus: "none",
    subscriptionId: null,
    planId: fallbackPlanId,
    mode: expectedMode,
    nextBillingAt: null,
    cancelAtPeriodEnd: false,
    cancelEffectiveAt: null,
  };
}

function optionalIsoField(data, field) {
  if (data[field] === undefined || data[field] === null) {
    return {valid: true, value: null};
  }
  const value = toIso(data[field]);
  return value ? {valid: true, value} : {valid: false, value: null};
}

/**
 * Validate the provider-owned fields as one coherent payment state. Explicit
 * opposite-mode data is historical and projects to `none`; malformed or
 * contradictory current-mode data projects to `unavailable`.
 */
export function paymentStateProjection({
  data = {},
  expectedMode,
  expectedPlanId = null,
} = {}) {
  const configuredPlanId = nonBlankString(expectedPlanId);
  if (!isRecord(data) || !isPortalyMode(expectedMode) || !configuredPlanId) {
    return unavailablePaymentState(expectedMode, expectedPlanId);
  }
  const hasProviderState = PROVIDER_FIELDS.some((field) =>
    Object.prototype.hasOwnProperty.call(data, field));
  if (!hasProviderState) return emptyPaymentState(expectedMode, configuredPlanId);

  const status = data.subscriptionStatus;
  const subscriptionId = data.subscriptionId === undefined || data.subscriptionId === null ?
    null : validDocumentId(data.subscriptionId);
  const checkoutId = data.currentCheckoutSessionId === undefined ||
    data.currentCheckoutSessionId === null ? null :
    validDocumentId(data.currentCheckoutSessionId);
  const idsAreValid = (data.subscriptionId === undefined || data.subscriptionId === null ||
      subscriptionId !== null) &&
    (data.currentCheckoutSessionId === undefined ||
      data.currentCheckoutSessionId === null || checkoutId !== null);
  const hasPlanId = data.planId !== undefined && data.planId !== null;
  const planMatches = status === "none" ?
    (!hasPlanId || data.planId === configuredPlanId) :
    data.planId === configuredPlanId;
  const nextBillingAt = optionalIsoField(data, "nextBillingAt");
  const cancelEffectiveAt = optionalIsoField(data, "cancelEffectiveAt");
  const baseIsValid = isPortalyMode(data.mode) &&
    typeof status === "string" && PORTALY_STATUSES.has(status) &&
    typeof data.proActive === "boolean" &&
    typeof data.cancelAtPeriodEnd === "boolean" &&
    idsAreValid && planMatches && nextBillingAt.valid && cancelEffectiveAt.valid;
  if (!baseIsValid) return unavailablePaymentState(expectedMode, expectedPlanId);

  let coherent = false;
  if (status === "none") {
    coherent = !data.proActive && !subscriptionId && !checkoutId && !data.cancelAtPeriodEnd;
  } else if (PENDING_STATUSES.has(status)) {
    coherent = !data.proActive && Boolean(subscriptionId) &&
      checkoutId === subscriptionId && !data.cancelAtPeriodEnd;
  } else if (status === "checkout_failed") {
    coherent = !data.proActive && !subscriptionId && Boolean(checkoutId) &&
      !data.cancelAtPeriodEnd;
  } else if (ACTIVE_STATUSES.has(status)) {
    coherent = data.proActive && Boolean(subscriptionId) &&
      checkoutId === subscriptionId &&
      data.cancelAtPeriodEnd === (status === "cancel_requested");
  } else if (status === "canceled") {
    coherent = !data.proActive && Boolean(subscriptionId) &&
      checkoutId === subscriptionId && !data.cancelAtPeriodEnd;
  }
  if (!coherent) return unavailablePaymentState(expectedMode, expectedPlanId);

  // A complete, coherent record from the other known environment is
  // historical for this API key. Malformed opposite-mode records still fail
  // closed rather than becoming checkout-eligible Free state.
  if (data.mode !== expectedMode) {
    return emptyPaymentState(expectedMode, configuredPlanId);
  }

  return {
    valid: true,
    subscriptionStatus: status,
    subscriptionId,
    planId: data.planId || configuredPlanId,
    mode: expectedMode,
    nextBillingAt: nextBillingAt.value,
    cancelAtPeriodEnd: data.cancelAtPeriodEnd,
    cancelEffectiveAt: cancelEffectiveAt.value,
  };
}

function toIso(value) {
  if (typeof value === "string") {
    return Number.isFinite(Date.parse(value)) ? value : null;
  }
  if (value instanceof Date) {
    return Number.isFinite(value.getTime()) ? value.toISOString() : null;
  }
  if (typeof value?.toDate === "function") {
    try {
      const date = value.toDate();
      return date instanceof Date && Number.isFinite(date.getTime()) ? date.toISOString() : null;
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Calculate the next billing date from a billing cycle anchor and interval.
 *
 * Given a billingCycleAnchor (reference date), billingIntervalUnit (month/year),
 * and billingIntervalCount (number of intervals), compute the next billing date.
 *
 * If cancelAtPeriodEnd is true, the returned date is the last billing date
 * (the current period end). Otherwise, it is the next period's billing date.
 *
 * Returns ISO 8601 string, or null if inputs are invalid.
 */
export function calculateNextBillingFromAnchor({
  billingIntervalUnit = null,
  billingIntervalCount = null,
  billingCycleAnchor = null,
  cancelAtPeriodEnd = false,
  now = Date.now(),
} = {}) {
  // Validate inputs
  if (!billingCycleAnchor || typeof billingCycleAnchor !== "string") {
    return null;
  }
  if (!billingIntervalUnit || !["month", "year"].includes(billingIntervalUnit)) {
    return null;
  }
  if (typeof billingIntervalCount !== "number" || billingIntervalCount <= 0) {
    return null;
  }

  // Parse anchor date
  const anchorMs = Date.parse(billingCycleAnchor);
  if (!Number.isFinite(anchorMs)) {
    return null;
  }

  const anchorDate = new Date(anchorMs);
  const nowDate = new Date(now);

  // If anchor is in the future, it's the first billing cycle
  if (anchorDate > nowDate) {
    return billingCycleAnchor;
  }

  // Calculate how many complete periods have passed since anchor
  let periodsSinceAnchor = 0;
  let currentDate = new Date(anchorDate);

  // Count complete periods
  while (currentDate <= nowDate) {
    const nextPeriodDate = new Date(currentDate);
    if (billingIntervalUnit === "month") {
      nextPeriodDate.setMonth(nextPeriodDate.getMonth() + billingIntervalCount);
    } else if (billingIntervalUnit === "year") {
      nextPeriodDate.setFullYear(nextPeriodDate.getFullYear() + billingIntervalCount);
    }
    if (nextPeriodDate > nowDate) {
      break;
    }
    periodsSinceAnchor += 1;
    currentDate = nextPeriodDate;
  }

  // Calculate next billing date
  const nextBillingDate = new Date(anchorDate);
  if (billingIntervalUnit === "month") {
    nextBillingDate.setMonth(nextBillingDate.getMonth() + billingIntervalCount * (periodsSinceAnchor + (cancelAtPeriodEnd ? 0 : 1)));
  } else if (billingIntervalUnit === "year") {
    nextBillingDate.setFullYear(nextBillingDate.getFullYear() + billingIntervalCount * (periodsSinceAnchor + (cancelAtPeriodEnd ? 0 : 1)));
  }

  return nextBillingDate.toISOString();
}

/**
 * Calculate the expiring stage based on nextBillingAt and current time.
 *
 * Returns the stage of an upcoming subscription renewal:
 * - "expired": nextBillingAt is in the past
 * - "today": 0 to 24 hours (< 1 day) until renewal
 * - "soon": 24 to 48 hours (1-2 days) until renewal
 * - "far": 48 to 72 hours (2-3 days) until renewal
 * - "none": more than 72 hours or no nextBillingAt
 *
 * Only applies when proActive is true and subscriptionStatus is in
 * {active, past_due, cancel_requested}.
 */
export function calculateExpiringStage({
  proActive = false,
  subscriptionStatus = null,
  nextBillingAt = null,
  now = Date.now(),
} = {}) {
  // Not eligible for expiring stage if not proActive or wrong status
  if (!proActive || !EXPIRING_ELIGIBLE_STATUSES.has(subscriptionStatus)) {
    return "none";
  }

  // Must have a valid nextBillingAt
  if (!nextBillingAt || typeof nextBillingAt !== "string") {
    return "none";
  }

  const nextBillingAtMs = Date.parse(nextBillingAt);
  if (!Number.isFinite(nextBillingAtMs)) {
    return "none";
  }

  const daysUntil = (nextBillingAtMs - now) / (24 * 60 * 60 * 1000);

  if (daysUntil < 0) {
    return "expired";
  }
  if (daysUntil < 1) {
    return "today";
  }
  if (daysUntil < 2) {
    return "soon";
  }
  if (daysUntil < 3) {
    return "far";
  }
  return "none";
}

export function portalAccessDecision({
  data = {},
  expectedMode,
  expectedPlanId,
} = {}) {
  const payment = paymentStateProjection({data, expectedMode, expectedPlanId});
  if (!payment.valid || !ACTIVE_STATUSES.has(payment.subscriptionStatus) ||
      !payment.subscriptionId) {
    return {kind: "unavailable"};
  }
  return {kind: "allow", subscriptionId: payment.subscriptionId};
}

/**
 * Builds the public subscription response for the API-key environment. A
 * provider record from the opposite environment remains stored for audit and
 * possible future use, but is never exposed as the current provider state.
 */
export function subscriptionStateResponse({
  uid,
  email,
  emailVerified,
  data = {},
  grant,
  expectedMode,
  lastVerifiedAt,
  fallbackPlanId = null,
  now = Date.now(),
} = {}) {
  const payment = paymentStateProjection({
    data,
    expectedMode,
    expectedPlanId: fallbackPlanId,
  });
  const resolved = resolveEntitlement({
    grant,
    portalyState: payment.valid ? {
      proActive: ACTIVE_STATUSES.has(payment.subscriptionStatus),
      subscriptionStatus: payment.subscriptionStatus,
      mode: payment.mode,
      planId: payment.planId,
    } : {},
    expectedMode,
    expectedPlanId: fallbackPlanId,
  });
  const paymentIsUnavailable = !payment.valid ||
    (resolved.grantStateValid === false && !resolved.portalyProActive);

  // Calculate nextBillingAtMs and daysUntilRenewal
  let nextBillingAtMs = null;
  let daysUntilRenewal = null;
  if (!paymentIsUnavailable && payment.nextBillingAt) {
    const ms = Date.parse(payment.nextBillingAt);
    if (Number.isFinite(ms)) {
      nextBillingAtMs = ms;
      daysUntilRenewal = (ms - now) / (24 * 60 * 60 * 1000);
    }
  }

  // Calculate expiring stage
  const expiringStage = calculateExpiringStage({
    proActive: resolved.proActive,
    subscriptionStatus: paymentIsUnavailable ? null : payment.subscriptionStatus,
    nextBillingAt: paymentIsUnavailable ? null : payment.nextBillingAt,
    now,
  });

  return {
    uid,
    email,
    emailVerified,
    proActive: resolved.proActive,
    subscriptionStatus: paymentIsUnavailable ? "unavailable" : payment.subscriptionStatus,
    subscriptionId: paymentIsUnavailable ? null : payment.subscriptionId,
    planId: payment.planId,
    mode: payment.mode,
    nextBillingAt: paymentIsUnavailable ? null : payment.nextBillingAt,
    nextBillingAtMs,
    daysUntilRenewal,
    cancelAtPeriodEnd: paymentIsUnavailable ? false : payment.cancelAtPeriodEnd,
    cancelEffectiveAt: paymentIsUnavailable ? null : payment.cancelEffectiveAt,
    lastVerifiedAt: lastVerifiedAt ?? subscriptionVerificationTimestamp(data),
    entitlementSource: resolved.entitlementSource,
    expiringStage,
    grant: resolved.grant,
  };
}
