import {verifyPortalyCallback} from "./portaly-signature.mjs";

const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const CANONICAL_EVENT_ALIASES = new Map([
  ["checkout.completed", "creator_subscription.checkout.completed"],
  ["checkout.failed", "creator_subscription.checkout.failed"],
  ["subscription.payment.succeeded", "creator_subscription.payment.succeeded"],
  ["subscription.payment.failed", "creator_subscription.payment.failed"],
  ["subscription.active", "creator_subscription.active"],
  ["subscription.cancel_requested", "creator_subscription.cancel_requested"],
  ["subscription.canceled", "creator_subscription.canceled"],
]);
const ISO_TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):(\d{2}))$/;
const SUPPORTED_EVENTS = new Set([
  "creator_subscription.checkout.completed",
  "creator_subscription.checkout.failed",
  "creator_subscription.payment.succeeded",
  "creator_subscription.payment.failed",
  "creator_subscription.payment.refunded",
  "creator_subscription.payment.refund_failed",
  "creator_subscription.active",
  "creator_subscription.cancel_requested",
  "creator_subscription.canceled",
]);

export class CallbackError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.statusCode = statusCode;
  }
}

function canonicalEventName(event) {
  if (typeof event !== "string") return null;
  return CANONICAL_EVENT_ALIASES.get(event) || event;
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function requiredPayloadString(payload, field) {
  const value = nonBlankString(payload?.[field]);
  if (!value) throw new CallbackError(400, `Callback ${field} is missing`);
  return value;
}

function requiredPayloadTimestamp(payload, field) {
  const value = requiredPayloadString(payload, field);
  if (!Number.isFinite(strictIsoTimestampMs(value))) {
    throw new CallbackError(422, `Callback ${field} is invalid`);
  }
  return value;
}

function requiredPayloadBoolean(payload, field) {
  if (typeof payload?.[field] !== "boolean") {
    throw new CallbackError(422, `Callback ${field} is invalid`);
  }
  return payload[field];
}

function requiredPayloadNumber(payload, field) {
  const value = payload?.[field];
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new CallbackError(422, `Callback ${field} is invalid`);
  }
  return value;
}

function requiredNullablePayloadString(payload, field) {
  if (payload?.[field] === null) return null;
  return requiredPayloadString(payload, field);
}

function requiredNullablePayloadBoolean(payload, field) {
  if (payload?.[field] === null) return null;
  return requiredPayloadBoolean(payload, field);
}

function validateRefundSharedFields(payload) {
  requiredPayloadString(payload, "subscriptionId");
  const orderId = requiredPayloadString(payload, "orderId");
  validateDocumentIdentifier(orderId, "orderId");

  requiredPayloadString(payload, "paymentId");
  requiredPayloadString(payload, "paymentReference");
  requiredPayloadString(payload, "orderMerchantOrderNumber");

  const amount = requiredPayloadNumber(payload, "amount");
  const refundedAmount = requiredPayloadNumber(payload, "refundedAmount");
  requiredPayloadString(payload, "currency");
  const refundRequestedAt = requiredPayloadTimestamp(payload, "refundRequestedAt");
  requiredPayloadString(payload, "refundRequestedBy");
  requiredPayloadString(payload, "refundReason");
  requiredNullablePayloadString(payload, "refundReasonNote");
  requiredPayloadString(payload, "refundProvider");
  requiredPayloadBoolean(payload, "subscriptionCanceledByRefund");

  return {
    orderId,
    amount,
    refundedAmount,
    refundRequestedAtMs: strictIsoTimestampMs(refundRequestedAt),
  };
}

function validateDocumentIdentifier(value, field) {
  if (value && (value === "." || value === ".." || value.includes("/") ||
      Buffer.byteLength(value, "utf8") > 1500)) {
    throw new CallbackError(400, `Callback ${field} is invalid`);
  }
}

function requiredHeader(headers, name) {
  const raw = headers[name];
  const value = Array.isArray(raw) ? raw[0] : raw;
  if (typeof value !== "string" || value.length === 0) {
    throw new CallbackError(401, `Missing ${name}`);
  }
  return value;
}

function strictIsoTimestampMs(value) {
  const match = ISO_TIMESTAMP.exec(value);
  if (!match) return Number.NaN;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText,
    offsetSign, offsetHourText, offsetMinuteText] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12 || day < 1 || day > daysInMonth[month - 1] ||
      hour > 23 || minute > 59 || second > 59) {
    return Number.NaN;
  }
  if (offsetSign && (Number(offsetHourText) > 23 || Number(offsetMinuteText) > 59)) {
    return Number.NaN;
  }
  return Date.parse(value);
}

export function verifyCallbackEnvelope({headers, payload, secret, now = Date.now()}) {
  const event = canonicalEventName(requiredHeader(headers, "x-portaly-event"));
  const timestamp = requiredHeader(headers, "x-portaly-timestamp");
  const signature = requiredHeader(headers, "x-portaly-signature");
  const timestampMs = strictIsoTimestampMs(timestamp);
  const payloadEvent = canonicalEventName(payload?.event);

  if (!Number.isFinite(timestampMs) || Math.abs(now - timestampMs) > MAX_CLOCK_SKEW_MS) {
    throw new CallbackError(401, "Callback timestamp is outside the allowed window");
  }
  if (!verifyPortalyCallback({secret, payload, timestamp, signature})) {
    throw new CallbackError(401, "Invalid callback signature");
  }
  if (payloadEvent !== event) {
    throw new CallbackError(400, "Callback event header does not match the body");
  }
  if (!SUPPORTED_EVENTS.has(event)) {
    throw new CallbackError(400, "Unsupported callback event");
  }
  return {event, timestamp, timestampMs};
}

/**
 * Validates the signed event body before it is allowed to select or mutate a
 * Firestore document. These checks mirror Portaly Payment 0.11.2's event
 * contract and deliberately fail closed when identities conflict.
 */
export function validateCallbackPayload(event, payload) {
  const canonicalEvent = canonicalEventName(event);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new CallbackError(400, "Callback body must be an object");
  }

  requiredPayloadString(payload, "planId");
  requiredPayloadString(payload, "customerEmail");
  const sessionId = nonBlankString(payload.sessionId);
  const subscriptionId = nonBlankString(payload.subscriptionId);
  validateDocumentIdentifier(sessionId, "sessionId");
  validateDocumentIdentifier(subscriptionId, "subscriptionId");
  if (sessionId && subscriptionId && sessionId !== subscriptionId) {
    throw new CallbackError(400, "Callback sessionId and subscriptionId do not match");
  }

  switch (canonicalEvent) {
  case "creator_subscription.checkout.completed":
    requiredPayloadString(payload, "sessionId");
    requiredPayloadString(payload, "subscriptionId");
    if (payload.status !== "completed") {
      throw new CallbackError(422, "Checkout callback is not completed");
    }
    break;
  case "creator_subscription.checkout.failed":
    requiredPayloadString(payload, "sessionId");
    if (subscriptionId) {
      throw new CallbackError(400, "Failed checkout must not have a subscriptionId");
    }
    break;
  case "creator_subscription.payment.succeeded":
    requiredPayloadString(payload, "subscriptionId");
    if (!nonBlankString(payload.paymentId) && !nonBlankString(payload.paymentReference)) {
      throw new CallbackError(400, "Payment callback has no payment identity");
    }
    if (payload.status !== "active") {
      throw new CallbackError(422, "Successful payment callback is not active");
    }
    break;
  case "creator_subscription.payment.failed":
    requiredPayloadString(payload, "subscriptionId");
    if (!nonBlankString(payload.paymentId) && !nonBlankString(payload.paymentReference)) {
      throw new CallbackError(400, "Payment callback has no payment identity");
    }
    if (!new Set(["past_due", "canceled"]).has(payload.status)) {
      throw new CallbackError(422, "Failed payment callback has an invalid status");
    }
    break;
  case "creator_subscription.payment.refunded":
    {
      const refundFields = validateRefundSharedFields(payload);
      const refundedAt = requiredPayloadTimestamp(payload, "refundedAt");
      if (strictIsoTimestampMs(refundedAt) < refundFields.refundRequestedAtMs) {
        throw new CallbackError(422, "Refund callback timestamps are out of order");
      }
      if (refundFields.amount !== refundFields.refundedAmount) {
        throw new CallbackError(422, "Refund callback amounts do not match");
      }
    }
    requiredPayloadString(payload, "refundReference");
    break;
  case "creator_subscription.payment.refund_failed":
    {
      const refundFields = validateRefundSharedFields(payload);
      const refundFailedAt = requiredPayloadTimestamp(payload, "refundFailedAt");
      if (strictIsoTimestampMs(refundFailedAt) < refundFields.refundRequestedAtMs) {
        throw new CallbackError(422, "Refund callback timestamps are out of order");
      }
    }
    requiredPayloadString(payload, "refundFailureReason");
    requiredNullablePayloadBoolean(payload, "refundFailureRetryable");
    break;
  case "creator_subscription.active":
  case "creator_subscription.cancel_requested":
  case "creator_subscription.canceled":
    requiredPayloadString(payload, "subscriptionId");
    break;
  default:
    throw new CallbackError(400, "Unsupported callback event");
  }

  return payload;
}

export function eventIdentity(payload) {
  switch (canonicalEventName(payload?.event)) {
  case "creator_subscription.checkout.completed":
  case "creator_subscription.checkout.failed":
    return nonBlankString(payload.sessionId) ?
      `${canonicalEventName(payload.event)}:${payload.sessionId.trim()}` : null;
  case "creator_subscription.payment.succeeded":
  case "creator_subscription.payment.failed": {
    const paymentIdentity = nonBlankString(payload.paymentId) ||
      nonBlankString(payload.paymentReference);
    return paymentIdentity ? `${canonicalEventName(payload.event)}:${paymentIdentity}` : null;
  }
  case "creator_subscription.payment.refunded":
  case "creator_subscription.payment.refund_failed": {
    const orderId = nonBlankString(payload.orderId);
    return orderId ? `${canonicalEventName(payload.event)}:${orderId}` : null;
  }
  default:
    return null;
  }
}

export function subscriptionIdentifier(payload) {
  return nonBlankString(payload?.subscriptionId) || nonBlankString(payload?.sessionId);
}

/**
 * Prefer the provider's lifecycle/payment occurrence time over the delivery
 * header time. A retried callback can be delivered after a manual status
 * reconciliation even though the underlying cancellation/payment happened
 * before it.
 */
export function callbackStateTimestampMs(event, payload = {}, fallbackTimestampMs) {
  let value;
  switch (canonicalEventName(event)) {
  case "creator_subscription.checkout.completed":
    value = payload.completedAt;
    break;
  case "creator_subscription.checkout.failed":
  case "creator_subscription.payment.failed":
    value = payload.failedAt;
    break;
  case "creator_subscription.payment.succeeded":
    value = payload.chargedAt;
    break;
  case "creator_subscription.cancel_requested":
    value = payload.cancelRequestedAt;
    break;
  case "creator_subscription.canceled":
    value = payload.canceledAt;
    break;
  default:
    value = undefined;
  }

  const occurredAtMs = typeof value === "string" ? Date.parse(value) : Number.NaN;
  return Number.isFinite(occurredAtMs) ? occurredAtMs : fallbackTimestampMs;
}

function subscriptionStatusPriority(subscriptionStatus) {
  switch (subscriptionStatus) {
  case "checkout_failed":
    return 0;
  case "past_due":
    return 1;
  case "cancel_requested":
    return 2;
  case "active":
    return 3;
  case "canceled":
    return 4;
  default:
    return 0;
  }
}

export function shouldApplyCallbackUpdate(current = {}, incoming = {}, eventTimestampMs) {
  const currentStatus = current.subscriptionStatus || current.status;
  if (currentStatus === "canceled" && incoming.subscriptionStatus !== "canceled") {
    return false;
  }

  const lastReconciledAtMs = Number(current.lastReconciledAtMs);
  if (Number.isFinite(lastReconciledAtMs) && Number.isFinite(eventTimestampMs) &&
      eventTimestampMs <= lastReconciledAtMs) {
    return false;
  }

  const currentTimestampMs = Number(current.lastCallbackAtMs);
  if (Number.isFinite(currentTimestampMs) && Number.isFinite(eventTimestampMs)) {
    if (eventTimestampMs < currentTimestampMs) {
      return false;
    }
    if (eventTimestampMs === currentTimestampMs) {
      return subscriptionStatusPriority(incoming.subscriptionStatus) >=
        subscriptionStatusPriority(currentStatus);
    }
  }

  return true;
}

export function subscriptionStateForEvent(event, payload) {
  switch (canonicalEventName(event)) {
  case "creator_subscription.checkout.completed":
    return {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false};
  case "creator_subscription.checkout.failed":
    return {proActive: false, subscriptionStatus: "checkout_failed", cancelAtPeriodEnd: false};
  case "creator_subscription.payment.succeeded":
  case "creator_subscription.active":
    return {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false};
  case "creator_subscription.payment.failed":
    return {
      proActive: payload.status === "past_due",
      subscriptionStatus: payload.status,
      cancelAtPeriodEnd: false,
    };
  case "creator_subscription.cancel_requested":
    return {proActive: true, subscriptionStatus: "cancel_requested", cancelAtPeriodEnd: true};
  case "creator_subscription.canceled":
    return {proActive: false, subscriptionStatus: "canceled", cancelAtPeriodEnd: false};
  default:
    throw new CallbackError(400, "Unsupported callback event");
  }
}
