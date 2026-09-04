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
    cancelAtPeriodEnd: paymentIsUnavailable ? false : payment.cancelAtPeriodEnd,
    cancelEffectiveAt: paymentIsUnavailable ? null : payment.cancelEffectiveAt,
    lastVerifiedAt: lastVerifiedAt ?? subscriptionVerificationTimestamp(data),
    entitlementSource: resolved.entitlementSource,
    grant: resolved.grant,
  };
}
