import {createHash} from "node:crypto";

const PORTALY_MODES = new Set(["test", "live"]);
const BLOCKING_STATUSES = new Set(["active", "past_due"]);
const PORTALY_SUBSCRIPTION_STATUSES = new Set(["active", "past_due", "canceled"]);

function fail(code, message) {
  throw Object.assign(new Error(message), {code});
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export function normalizeCustomerEmail(email) {
  return nonBlankString(email)?.toLowerCase() || null;
}

/**
 * Produces a Firestore-safe, non-reversible key without retaining an email in
 * the document id. Plan and Portaly mode are part of the hash namespace so a
 * customer can independently own different plans and test/live checkouts.
 */
export function customerSubscriptionKey({email, planId, mode} = {}) {
  const normalizedEmail = normalizeCustomerEmail(email);
  const normalizedPlanId = nonBlankString(planId);
  if (!normalizedEmail || !normalizedPlanId || !PORTALY_MODES.has(mode)) return null;

  const digest = createHash("sha256")
    .update(JSON.stringify(["ufogeo-customer-subscription-v1", mode, normalizedPlanId, normalizedEmail]))
    .digest("hex");
  return `customer_${digest}`;
}

/**
 * Accepts the documented Portaly list response as well as a bare array, which
 * is convenient for callers that have already extracted `data`.
 */
export function portalySubscriptions(payload) {
  if (Array.isArray(payload)) return payload;
  if (payload && typeof payload === "object" && Array.isArray(payload.data)) {
    return payload.data;
  }
  return [];
}

function requiredString(value, code, label) {
  const normalized = nonBlankString(value);
  if (!normalized) fail(code, `${label} must be a non-empty string`);
  return normalized;
}

/**
 * Strict checkout boundary for a Portaly subscription-list response.
 *
 * Returns only records for the requested customer and plan. Out-of-scope
 * records are ignored, but records that cannot be proven out of scope, and
 * malformed records in scope, throw an Error carrying a stable `code`.
 */
export function validatedPortalySubscriptions(payload, {email, planId, mode} = {}) {
  const isWrappedList = payload &&
    typeof payload === "object" &&
    !Array.isArray(payload) &&
    Array.isArray(payload.data);
  if (!Array.isArray(payload) && !isWrappedList) {
    fail(
      "PORTALY_SUBSCRIPTIONS_PAYLOAD_INVALID",
      "Portaly subscription response must be an array or an object containing a data array",
    );
  }

  const expectedEmail = normalizeCustomerEmail(email);
  if (!expectedEmail) {
    fail("EXPECTED_CUSTOMER_EMAIL_INVALID", "expected customer email must be a non-empty string");
  }
  const expectedPlanId = requiredString(
    planId,
    "EXPECTED_PLAN_ID_INVALID",
    "expected planId",
  );
  if (!PORTALY_MODES.has(mode)) {
    fail("EXPECTED_MODE_INVALID", "expected mode must be live or test");
  }

  const matches = [];
  for (const subscription of portalySubscriptions(payload)) {
    if (!subscription || typeof subscription !== "object" || Array.isArray(subscription)) {
      fail("PORTALY_SUBSCRIPTION_INVALID", "Portaly subscription must be an object");
    }

    // A missing plan cannot be safely classified as out of scope.
    const subscriptionPlanId = requiredString(
      subscription.planId,
      "PORTALY_SUBSCRIPTION_PLAN_ID_MISSING",
      "Portaly subscription planId",
    );
    if (subscriptionPlanId !== expectedPlanId) continue;

    const subscriptionMode = requiredString(
      subscription.mode,
      "PORTALY_SUBSCRIPTION_MODE_MISSING",
      "Portaly subscription mode",
    );
    if (!PORTALY_MODES.has(subscriptionMode)) {
      fail(
        "PORTALY_SUBSCRIPTION_MODE_INVALID",
        "Portaly subscription mode must be live or test",
      );
    }
    if (subscriptionMode !== mode) {
      // Plans are shared across environments and the provider list may still
      // contain a customer's historical sandbox subscription. An explicit
      // opposite mode cannot renew through the current API key, so it must not
      // block a new checkout. Missing/invalid modes still fail closed above.
      continue;
    }

    // Once the plan and mode match, a missing email could be the target
    // customer and therefore must fail closed instead of being ignored.
    const subscriptionEmail = normalizeCustomerEmail(subscription.customerEmail);
    if (!subscriptionEmail) {
      fail(
        "PORTALY_SUBSCRIPTION_EMAIL_MISSING",
        "Portaly subscription customerEmail must be a non-empty string",
      );
    }
    if (subscriptionEmail !== expectedEmail) continue;

    requiredString(
      subscription.id,
      "PORTALY_SUBSCRIPTION_ID_MISSING",
      "Portaly subscription id",
    );

    const status = requiredString(
      subscription.status,
      "PORTALY_SUBSCRIPTION_STATUS_MISSING",
      "Portaly subscription status",
    );
    if (!PORTALY_SUBSCRIPTION_STATUSES.has(status)) {
      fail(
        "PORTALY_SUBSCRIPTION_STATUS_INVALID",
        "Portaly subscription status is unsupported",
      );
    }
    if (typeof subscription.cancelAtPeriodEnd !== "boolean") {
      fail(
        "PORTALY_SUBSCRIPTION_CANCEL_AT_PERIOD_END_INVALID",
        "Portaly subscription cancelAtPeriodEnd must be a boolean",
      );
    }
    matches.push(subscription);
  }
  return matches;
}

export function findBlockingCustomerSubscriptionStrict(payload, options) {
  return validatedPortalySubscriptions(payload, options).find((subscription) =>
    BLOCKING_STATUSES.has(subscription.status)) || null;
}
