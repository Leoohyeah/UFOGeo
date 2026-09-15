import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";

import {
  callbackStateTimestampMs,
  CallbackError,
  eventIdentity,
  subscriptionIdentifier,
  subscriptionStateForEvent,
  shouldApplyCallbackUpdate,
  validateCallbackPayload,
  verifyCallbackEnvelope,
} from "../portaly-callback.mjs";
import {
  callbackMatchesCheckoutSession,
  shouldApplyUserSubscriptionUpdate,
} from "../checkout-idempotency.mjs";
import {signPortalyCallback} from "../portaly-signature.mjs";

const signatureVectors = JSON.parse(readFileSync(
  new URL(
    "./fixtures/callback-signature-v1-vectors.json",
    import.meta.url,
  ),
  "utf8",
)).vectors;

function fixture(overrides = {}) {
  const now = Date.parse("2026-08-26T04:00:00.000Z");
  const timestamp = "2026-08-26T04:00:00.000Z";
  const secret = "fixture-secret-only";
  const payload = {
    event: "creator_subscription.checkout.completed",
    mode: "test",
    planId: "plan_fixture",
    customerEmail: "buyer@example.com",
    sessionId: "session_fixture",
    subscriptionId: "session_fixture",
    status: "completed",
    ...overrides,
  };
  return {
    now,
    secret,
    payload,
    headers: {
      "x-portaly-event": payload.event,
      "x-portaly-timestamp": timestamp,
      "x-portaly-signature": signPortalyCallback({secret, payload, timestamp}),
    },
  };
}

function refundFixture(event, overrides = {}) {
  const isSuccess = event === "creator_subscription.payment.refunded";
  return fixture({
    event,
    sessionId: "session_fixture",
    subscriptionId: "session_fixture",
    orderId: "creatorSubscription_pay_456",
    paymentId: "pay_456",
    paymentReference: "txn_456",
    orderMerchantOrderNumber: "ufogeo-order-456",
    amount: 249,
    currency: "TWD",
    refundedAmount: 249,
    refundRequestedAt: "2026-08-26T04:01:00.000Z",
    refundRequestedBy: "api",
    refundReason: "customer_requested",
    refundReasonNote: null,
    refundProvider: "tappay",
    subscriptionCanceledByRefund: true,
    refundReference: isSuccess ? "refund_789" : undefined,
    refundedAt: isSuccess ? "2026-08-26T04:02:00.000Z" : undefined,
    refundFailureReason: isSuccess ? undefined : "provider rejected refund",
    refundFailedAt: isSuccess ? undefined : "2026-08-26T04:02:00.000Z",
    refundFailureRetryable: isSuccess ? undefined : null,
    ...overrides,
  });
}

test("accepts a signed, fresh callback", () => {
  const value = fixture();
  assert.equal(verifyCallbackEnvelope(value).event, value.payload.event);
});

test("matches committed production-derived callback signature vectors", () => {
  for (const vector of signatureVectors) {
    assert.equal(
      signPortalyCallback({
        secret: vector.secret,
        payload: vector.payload,
        timestamp: vector.timestamp,
      }),
      vector.signature,
      vector.id,
    );
  }
});

test("normalizes legacy event aliases in the verified callback envelope", () => {
  const value = fixture({event: "subscription.active", status: "active"});
  value.headers["x-portaly-event"] = "subscription.active";
  assert.equal(verifyCallbackEnvelope(value).event, "creator_subscription.active");
});

test("rejects invalid signature, stale timestamp, and event mismatch", () => {
  const invalid = fixture();
  invalid.headers["x-portaly-signature"] = "0".repeat(64);
  assert.throws(() => verifyCallbackEnvelope(invalid), CallbackError);

  for (const offset of [-301_000, 301_000]) {
    const stale = fixture();
    assert.throws(
      () => verifyCallbackEnvelope({...stale, now: stale.now + offset}),
      (error) => error instanceof CallbackError && error.statusCode === 401,
    );
  }

  for (const offset of [-300_000, 300_000]) {
    const boundary = fixture();
    assert.equal(
      verifyCallbackEnvelope({...boundary, now: boundary.now + offset}).event,
      boundary.payload.event,
    );
  }

  const mismatch = fixture();
  mismatch.headers["x-portaly-event"] = "creator_subscription.canceled";
  assert.throws(() => verifyCallbackEnvelope(mismatch), CallbackError);

  const malformed = fixture();
  malformed.headers["x-portaly-timestamp"] = "not-a-timestamp";
  assert.throws(() => verifyCallbackEnvelope(malformed), CallbackError);

  for (const timestamp of [
    "2026-02-29T00:00:00.000Z",
    "2026-04-31T00:00:00.000Z",
  ]) {
    const impossible = fixture();
    impossible.now = Date.parse(timestamp);
    impossible.headers["x-portaly-timestamp"] = timestamp;
    impossible.headers["x-portaly-signature"] = signPortalyCallback({
      secret: impossible.secret,
      payload: impossible.payload,
      timestamp,
    });
    assert.throws(
      () => verifyCallbackEnvelope(impossible),
      (error) => error instanceof CallbackError && error.statusCode === 401,
    );
  }
});

test("rejects every missing callback header and signed unsupported events", () => {
  for (const header of [
    "x-portaly-event",
    "x-portaly-timestamp",
    "x-portaly-signature",
  ]) {
    const value = fixture();
    delete value.headers[header];
    assert.throws(
      () => verifyCallbackEnvelope(value),
      (error) => error instanceof CallbackError && error.statusCode === 401,
    );
  }

  const unsupported = fixture({event: "creator_subscription.unknown"});
  assert.throws(
    () => verifyCallbackEnvelope(unsupported),
    (error) => error instanceof CallbackError && error.statusCode === 400,
  );
});

test("uses event-specific idempotency keys for checkout, payment, and refund callbacks", () => {
  assert.equal(
    eventIdentity(fixture().payload),
    "creator_subscription.checkout.completed:session_fixture",
  );
  assert.equal(eventIdentity({
    event: "creator_subscription.payment.succeeded",
    paymentId: "pay_1",
  }), "creator_subscription.payment.succeeded:pay_1");
  assert.equal(eventIdentity({
    event: "creator_subscription.checkout.failed",
    sessionId: "session_failed",
  }), "creator_subscription.checkout.failed:session_failed");
  assert.equal(eventIdentity({
    event: "creator_subscription.payment.failed",
    paymentReference: "txn_failed_1",
  }), "creator_subscription.payment.failed:txn_failed_1");
  assert.equal(eventIdentity({
    event: "checkout.failed",
    sessionId: "session_failed",
  }), "creator_subscription.checkout.failed:session_failed");
  assert.equal(eventIdentity({
    event: "subscription.payment.succeeded",
    paymentReference: "txn_legacy_1",
  }), "creator_subscription.payment.succeeded:txn_legacy_1");
  assert.equal(eventIdentity({
    event: "creator_subscription.payment.refunded",
    orderId: "order_1",
  }), "creator_subscription.payment.refunded:order_1");
  assert.equal(eventIdentity({
    event: "creator_subscription.payment.refund_failed",
    orderId: "order_1",
  }), "creator_subscription.payment.refund_failed:order_1");
  assert.notEqual(
    eventIdentity({event: "creator_subscription.payment.refunded", orderId: "order_1"}),
    eventIdentity({event: "creator_subscription.payment.refunded", orderId: "order_2"}),
  );
  assert.equal(eventIdentity({
    event: "payment.refunded",
    orderId: "order_1",
  }), null);
  assert.equal(eventIdentity({
    event: "creator_subscription.checkout.completed",
  }), null);
  assert.equal(eventIdentity({
    event: "creator_subscription.payment.succeeded",
  }), null);
  assert.equal(subscriptionIdentifier({event: "creator_subscription.active"}), null);
  assert.equal(subscriptionIdentifier({event: "creator_subscription.checkout.completed"}), null);
});

test("treats distinct successful renewals as separate payments, not duplicate orders", () => {
  const first = {
    event: "creator_subscription.payment.succeeded",
    subscriptionId: "session_fixture",
    paymentId: "payment_renewal_1",
    chargedAt: "2026-08-26T04:00:00.000Z",
  };
  const second = {
    ...first,
    paymentId: "payment_renewal_2",
    chargedAt: "2026-09-26T04:00:00.000Z",
  };

  assert.notEqual(eventIdentity(first), eventIdentity(second));
  assert.equal(
    shouldApplyCallbackUpdate(
      {
        subscriptionStatus: "active",
        lastCallbackAtMs: Date.parse(first.chargedAt),
      },
      subscriptionStateForEvent(second.event, second),
      callbackStateTimestampMs(second.event, second, 0),
    ),
    true,
  );
});

test("keeps lifecycle callback replays eligible for idempotent state assignment", () => {
  const lifecycleEvents = [
    "creator_subscription.active",
    "creator_subscription.cancel_requested",
    "creator_subscription.canceled",
    "subscription.active",
    "subscription.cancel_requested",
    "subscription.canceled",
  ];

  for (const event of lifecycleEvents) {
    assert.equal(eventIdentity({event, subscriptionId: "sub_1", sessionId: "sub_1"}), null);
  }

  const timestamp = Date.parse("2026-08-26T04:00:00.000Z");
  assert.equal(shouldApplyCallbackUpdate(
    {subscriptionStatus: "cancel_requested", lastCallbackAtMs: timestamp},
    {subscriptionStatus: "cancel_requested"},
    timestamp,
  ), true);
});

test("applies two cancel-and-resume callback cycles in chronological order", () => {
  let current = {
    subscriptionStatus: "active",
    proActive: true,
    cancelAtPeriodEnd: false,
  };
  const lifecycle = [
    ["creator_subscription.cancel_requested", "2026-08-26T04:00:00.000Z"],
    ["creator_subscription.active", "2026-08-26T04:00:10.000Z"],
    ["creator_subscription.cancel_requested", "2026-09-26T04:00:00.000Z"],
    ["creator_subscription.active", "2026-09-26T04:00:10.000Z"],
  ];

  for (const [event, occurredAt] of lifecycle) {
    const incoming = subscriptionStateForEvent(event, {});
    const timestampMs = Date.parse(occurredAt);
    assert.equal(shouldApplyCallbackUpdate(current, incoming, timestampMs), true);
    current = {...current, ...incoming, lastCallbackAtMs: timestampMs};
  }

  assert.deepEqual(current, {
    subscriptionStatus: "active",
    proActive: true,
    cancelAtPeriodEnd: false,
    lastCallbackAtMs: Date.parse("2026-09-26T04:00:10.000Z"),
  });
});

test("accepts checkout failure without a subscription and keeps Pro disabled", () => {
  const value = fixture({
    event: "creator_subscription.checkout.failed",
    subscriptionId: undefined,
    status: undefined,
    failureReason: "fixture decline",
    failedAt: "2026-08-26T04:00:00.000Z",
  });

  assert.equal(verifyCallbackEnvelope(value).event, value.payload.event);
  assert.equal(validateCallbackPayload(value.payload.event, value.payload), value.payload);
  assert.deepEqual(
    subscriptionStateForEvent(value.payload.event, value.payload),
    {proActive: false, subscriptionStatus: "checkout_failed", cancelAtPeriodEnd: false},
  );
});

test("accepts a production-shaped completed checkout without subscriptionId", () => {
  const value = fixture({
    mode: "live",
    merchantOrderNumber: "ufogeo-order-production-1",
    amount: 149,
    currency: "TWD",
    paymentReference: "txn-production-1",
    paymentMethod: "tappay",
    completedAt: "2026-08-26T04:00:00.000Z",
  });
  delete value.payload.subscriptionId;
  value.headers["x-portaly-signature"] = signPortalyCallback({
    secret: value.secret,
    payload: value.payload,
    timestamp: value.headers["x-portaly-timestamp"],
  });

  assert.equal(verifyCallbackEnvelope(value).event, value.payload.event);
  assert.equal(validateCallbackPayload(value.payload.event, value.payload), value.payload);
  assert.equal(subscriptionIdentifier(value.payload), value.payload.sessionId);
});

test("applies a new session-only completion after an old failed checkout", () => {
  const value = fixture({
    mode: "live",
    sessionId: "session-new",
    subscriptionId: undefined,
    status: "completed",
    completedAt: "2026-08-26T04:00:00.000Z",
  });
  value.headers["x-portaly-signature"] = signPortalyCallback({
    secret: value.secret,
    payload: value.payload,
    timestamp: value.headers["x-portaly-timestamp"],
  });
  const newSession = {
    sessionId: "session-new",
    subscriptionId: "session-new",
    customerEmail: "buyer@example.com",
    planId: "plan_fixture",
    mode: "live",
    status: "checkout_ready",
  };
  const currentUser = {
    currentCheckoutSessionId: "session-new",
    subscriptionId: "session-new",
    mode: "live",
  };

  // The callback remains signed and is accepted when Portaly omits the
  // subscriptionId (the contract aliases it to sessionId).
  assert.equal(verifyCallbackEnvelope(value).event, value.payload.event);
  assert.equal(validateCallbackPayload(value.payload.event, value.payload), value.payload);
  assert.equal(subscriptionIdentifier(value.payload), "session-new");
  assert.equal(callbackMatchesCheckoutSession(newSession, value.payload, {
    expectedPlanId: "plan_fixture",
  }), true);
  assert.deepEqual(
    subscriptionStateForEvent(value.payload.event, value.payload),
    {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false},
  );
  assert.equal(
    shouldApplyUserSubscriptionUpdate(currentUser, "session-new", {mode: "live"}),
    true,
  );

  // A late callback for the expired/failed first checkout may update its own
  // history, but must not overwrite the user's newer checkout entitlement.
  assert.equal(
    shouldApplyUserSubscriptionUpdate(currentUser, "session-old", {mode: "live"}),
    false,
  );

  const mismatched = fixture({
    mode: "live",
    sessionId: "session-new",
    subscriptionId: "session-old",
    status: "completed",
  });
  mismatched.headers["x-portaly-signature"] = signPortalyCallback({
    secret: mismatched.secret,
    payload: mismatched.payload,
    timestamp: mismatched.headers["x-portaly-timestamp"],
  });
  assert.doesNotThrow(() => verifyCallbackEnvelope(mismatched));
  assert.throws(
    () => validateCallbackPayload(mismatched.payload.event, mismatched.payload),
    (error) => error instanceof CallbackError && error.statusCode === 400,
  );
  assert.equal(callbackMatchesCheckoutSession(newSession, mismatched.payload, {
    expectedPlanId: "plan_fixture",
  }), false);
});

test("accepts every documented callback identity and payment status", () => {
  const validPayloads = [
    fixture().payload,
    fixture({
      event: "creator_subscription.checkout.failed",
      subscriptionId: undefined,
      status: undefined,
    }).payload,
    fixture({
      event: "creator_subscription.payment.succeeded",
      sessionId: undefined,
      status: "active",
      paymentId: "pay_1",
    }).payload,
    fixture({
      event: "creator_subscription.payment.failed",
      sessionId: undefined,
      status: "past_due",
      paymentReference: "txn_1",
    }).payload,
    fixture({
      event: "creator_subscription.payment.failed",
      sessionId: undefined,
      status: "canceled",
      paymentReference: "txn_2",
    }).payload,
    ...[
      "creator_subscription.active",
      "creator_subscription.cancel_requested",
      "creator_subscription.canceled",
    ].map((event) => fixture({event, sessionId: undefined}).payload),
    refundFixture("creator_subscription.payment.refunded").payload,
    refundFixture("creator_subscription.payment.refund_failed").payload,
  ];

  for (const payload of validPayloads) {
    assert.equal(validateCallbackPayload(payload.event, payload), payload);
  }
});

test("accepts refund terminal callbacks without projecting subscription state", () => {
  for (const event of [
    "creator_subscription.payment.refunded",
    "creator_subscription.payment.refund_failed",
  ]) {
    const value = refundFixture(event);
    assert.equal(verifyCallbackEnvelope(value).event, event);
    assert.equal(validateCallbackPayload(event, value.payload), value.payload);
    assert.equal(subscriptionIdentifier(value.payload), "session_fixture");
    assert.throws(
      () => subscriptionStateForEvent(event, value.payload),
      (error) => error instanceof CallbackError && error.statusCode === 400,
    );
  }
});

test("rejects refund callbacks without order identity or terminal proof", () => {
  const invalidCases = [
    ["creator_subscription.payment.refunded", {orderId: undefined}],
    ["creator_subscription.payment.refunded", {orderId: "order/child"}],
    ["creator_subscription.payment.refunded", {subscriptionId: undefined}],
    ["creator_subscription.payment.refunded", {paymentId: undefined}],
    ["creator_subscription.payment.refunded", {paymentReference: undefined}],
    ["creator_subscription.payment.refunded", {orderMerchantOrderNumber: undefined}],
    ["creator_subscription.payment.refunded", {amount: undefined}],
    ["creator_subscription.payment.refunded", {amount: 0}],
    ["creator_subscription.payment.refunded", {refundedAmount: undefined}],
    ["creator_subscription.payment.refunded", {refundedAmount: 0}],
    ["creator_subscription.payment.refunded", {currency: undefined}],
    ["creator_subscription.payment.refunded", {refundRequestedAt: undefined}],
    ["creator_subscription.payment.refunded", {refundRequestedBy: undefined}],
    ["creator_subscription.payment.refunded", {refundReason: undefined}],
    ["creator_subscription.payment.refunded", {refundReasonNote: undefined}],
    ["creator_subscription.payment.refunded", {refundProvider: undefined}],
    ["creator_subscription.payment.refunded", {subscriptionCanceledByRefund: undefined}],
    ["creator_subscription.payment.refunded", {refundReference: undefined}],
    ["creator_subscription.payment.refunded", {refundedAt: undefined}],
    ["creator_subscription.payment.refunded", {refundedAmount: 248}],
    ["creator_subscription.payment.refund_failed", {orderId: undefined}],
    ["creator_subscription.payment.refund_failed", {subscriptionId: undefined}],
    ["creator_subscription.payment.refund_failed", {amount: 0}],
    ["creator_subscription.payment.refund_failed", {refundedAmount: 0}],
    ["creator_subscription.payment.refund_failed", {refundFailureReason: undefined}],
    ["creator_subscription.payment.refund_failed", {refundFailedAt: undefined}],
    ["creator_subscription.payment.refund_failed", {refundFailureRetryable: undefined}],
    ["creator_subscription.payment.refund_failed", {refundFailureRetryable: "yes"}],
    ["creator_subscription.payment.refund_failed", {refundFailedAt: "not-a-date"}],
  ];

  for (const [event, overrides] of invalidCases) {
    const value = refundFixture(event, overrides);
    assert.throws(
      () => validateCallbackPayload(event, value.payload),
      (error) => error instanceof CallbackError,
    );
  }
});

test("rejects missing or conflicting callback identifiers", () => {
  for (const payload of [
    fixture({sessionId: undefined}).payload,
    fixture({subscriptionId: "different_subscription"}).payload,
    fixture({
      event: "creator_subscription.checkout.failed",
      subscriptionId: "must_not_exist",
      status: undefined,
    }).payload,
    fixture({
      event: "creator_subscription.active",
      sessionId: undefined,
      subscriptionId: undefined,
    }).payload,
  ]) {
    assert.throws(
      () => validateCallbackPayload(payload.event, payload),
      (error) => error instanceof CallbackError && error.statusCode === 400,
    );
  }
});

test("rejects missing common callback identity fields", () => {
  for (const field of ["planId", "customerEmail"]) {
    const payload = fixture({[field]: undefined}).payload;
    assert.throws(
      () => validateCallbackPayload(payload.event, payload),
      (error) => error instanceof CallbackError && error.statusCode === 400,
    );
  }
});

test("rejects callback identifiers that cannot be Firestore document IDs", () => {
  for (const sessionId of [".", "..", "session/child", "x".repeat(1501)]) {
    const payload = fixture({sessionId, subscriptionId: sessionId}).payload;
    assert.throws(
      () => validateCallbackPayload(payload.event, payload),
      (error) => error instanceof CallbackError && error.statusCode === 400,
    );
  }
});

test("rejects payment callbacks without a unique payment identity", () => {
  for (const event of [
    "creator_subscription.payment.succeeded",
    "creator_subscription.payment.failed",
  ]) {
    const payload = fixture({
      event,
      sessionId: undefined,
      status: event.endsWith("succeeded") ? "active" : "past_due",
      paymentId: undefined,
      paymentReference: undefined,
    }).payload;
    assert.throws(
      () => validateCallbackPayload(event, payload),
      (error) => error instanceof CallbackError && error.statusCode === 400,
    );
  }
});

test("rejects callback statuses that contradict their event", () => {
  for (const [event, status] of [
    ["creator_subscription.checkout.completed", "pending"],
    ["creator_subscription.payment.succeeded", "past_due"],
    ["creator_subscription.payment.failed", "active"],
    ["creator_subscription.payment.failed", undefined],
  ]) {
    const payload = fixture({
      event,
      sessionId: event.includes("payment.") ? undefined : "session_fixture",
      status,
      paymentReference: event.includes("payment.") ? "txn_status" : undefined,
    }).payload;
    assert.throws(
      () => validateCallbackPayload(event, payload),
      (error) => error instanceof CallbackError && error.statusCode === 422,
    );
  }
});

test("maps active, retry, cancel requested, and canceled states correctly", () => {
  assert.deepEqual(
    subscriptionStateForEvent("creator_subscription.checkout.completed", {status: "completed"}),
    {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false},
  );
  assert.deepEqual(
    subscriptionStateForEvent("creator_subscription.payment.succeeded", {status: "active"}),
    {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false},
  );
  assert.deepEqual(
    subscriptionStateForEvent("creator_subscription.active", {}),
    {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false},
  );
  assert.deepEqual(
    subscriptionStateForEvent("creator_subscription.payment.failed", {status: "past_due"}),
    {proActive: true, subscriptionStatus: "past_due", cancelAtPeriodEnd: false},
  );
  assert.deepEqual(
    subscriptionStateForEvent("creator_subscription.payment.failed", {status: "canceled"}),
    {proActive: false, subscriptionStatus: "canceled", cancelAtPeriodEnd: false},
  );
  assert.deepEqual(
    subscriptionStateForEvent("creator_subscription.cancel_requested", {}),
    {proActive: true, subscriptionStatus: "cancel_requested", cancelAtPeriodEnd: true},
  );
  assert.deepEqual(
    subscriptionStateForEvent("creator_subscription.canceled", {}),
    {proActive: false, subscriptionStatus: "canceled", cancelAtPeriodEnd: false},
  );
});

test("rejects checkout completion before it reaches completed status", () => {
  assert.throws(
    () => validateCallbackPayload(
      "creator_subscription.checkout.completed",
      {
        planId: "plan_fixture",
        customerEmail: "buyer@example.com",
        sessionId: "session_1",
        subscriptionId: "session_1",
        status: "pending",
      },
    ),
    (error) => error instanceof CallbackError && error.statusCode === 422,
  );
});

test("ignores out-of-order callbacks and preserves canceled state", () => {
  const cancelRequestedAt = Date.parse("2026-08-26T04:00:00.000Z");
  const activeLater = Date.parse("2026-08-26T04:00:10.000Z");
  const activeOlder = Date.parse("2026-08-26T03:59:50.000Z");

  assert.equal(shouldApplyCallbackUpdate(
    {subscriptionStatus: "cancel_requested", lastCallbackAtMs: cancelRequestedAt},
    {subscriptionStatus: "active"},
    activeOlder,
  ), false);
  assert.equal(shouldApplyCallbackUpdate(
    {subscriptionStatus: "cancel_requested", lastCallbackAtMs: cancelRequestedAt},
    {subscriptionStatus: "active"},
    activeLater,
  ), true);
  assert.equal(shouldApplyCallbackUpdate(
    {subscriptionStatus: "canceled", lastCallbackAtMs: activeLater},
    {subscriptionStatus: "active"},
    Date.parse("2026-08-26T04:00:20.000Z"),
  ), false);
});

test("preserves canceled state using the persisted checkout session field name", () => {
  assert.equal(shouldApplyCallbackUpdate(
    {
      status: "canceled",
      lastCallbackAtMs: Date.parse("2026-08-26T04:00:10.000Z"),
    },
    {subscriptionStatus: "active"},
    Date.parse("2026-08-26T04:00:20.000Z"),
  ), false);
});

test("uses the provider occurrence time instead of a later retry delivery time", () => {
  const deliveredAt = Date.parse("2026-08-26T04:10:00.000Z");
  const requestedAt = "2026-08-26T03:59:00.000Z";

  assert.equal(
    callbackStateTimestampMs(
      "creator_subscription.cancel_requested",
      {cancelRequestedAt: requestedAt},
      deliveredAt,
    ),
    Date.parse(requestedAt),
  );
  assert.equal(
    callbackStateTimestampMs(
      "creator_subscription.active",
      {},
      deliveredAt,
    ),
    deliveredAt,
  );
});

test("does not let a delayed lifecycle callback overwrite a newer reconciliation", () => {
  const reconciledAt = Date.parse("2026-08-26T04:05:00.000Z");
  const oldCancellation = Date.parse("2026-08-26T03:59:00.000Z");
  const newCancellation = Date.parse("2026-08-26T04:06:00.000Z");
  const current = {
    subscriptionStatus: "active",
    lastReconciledAtMs: reconciledAt,
  };

  assert.equal(shouldApplyCallbackUpdate(
    current,
    {subscriptionStatus: "cancel_requested"},
    oldCancellation,
  ), false);
  assert.equal(shouldApplyCallbackUpdate(
    current,
    {subscriptionStatus: "cancel_requested"},
    newCancellation,
  ), true);
});

test("subscriptionStateForEvent includes nextBillingAt when provided in payload", () => {
  const nextBillingAt = "2026-10-08T00:00:00.000Z";

  const stateWithBilling = subscriptionStateForEvent("creator_subscription.payment.succeeded", {
    status: "active",
    nextBillingAt,
  });

  assert.equal(stateWithBilling.proActive, true);
  assert.equal(stateWithBilling.subscriptionStatus, "active");
  assert.equal(stateWithBilling.cancelAtPeriodEnd, false);
  assert.equal(stateWithBilling.nextBillingAt, nextBillingAt);
});

test("subscriptionStateForEvent handles missing nextBillingAt gracefully", () => {
  const stateWithoutBilling = subscriptionStateForEvent("creator_subscription.active", {});

  assert.equal(stateWithoutBilling.proActive, true);
  assert.equal(stateWithoutBilling.subscriptionStatus, "active");
  assert.equal(stateWithoutBilling.cancelAtPeriodEnd, false);
  assert(!("nextBillingAt" in stateWithoutBilling));
});

test("subscriptionStateForEvent preserves null nextBillingAt from payload", () => {
  const stateWithNullBilling = subscriptionStateForEvent("creator_subscription.canceled", {
    nextBillingAt: null,
  });

  assert.equal(stateWithNullBilling.proActive, false);
  assert.equal(stateWithNullBilling.subscriptionStatus, "canceled");
  assert.equal(stateWithNullBilling.nextBillingAt, null);
});

test("subscriptionStateForEvent works correctly for all event types with nextBillingAt", () => {
  const nextBillingAt = "2026-10-08T00:00:00.000Z";

  for (const [event, expectedBase] of [
    ["creator_subscription.checkout.completed", {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false}],
    ["creator_subscription.payment.succeeded", {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false}],
    ["creator_subscription.active", {proActive: true, subscriptionStatus: "active", cancelAtPeriodEnd: false}],
    ["creator_subscription.cancel_requested", {proActive: true, subscriptionStatus: "cancel_requested", cancelAtPeriodEnd: true}],
  ]) {
    const state = subscriptionStateForEvent(event, {nextBillingAt});
    assert.equal(state.proActive, expectedBase.proActive, `proActive mismatch for ${event}`);
    assert.equal(state.subscriptionStatus, expectedBase.subscriptionStatus, `subscriptionStatus mismatch for ${event}`);
    assert.equal(state.cancelAtPeriodEnd, expectedBase.cancelAtPeriodEnd, `cancelAtPeriodEnd mismatch for ${event}`);
    assert.equal(state.nextBillingAt, nextBillingAt, `nextBillingAt mismatch for ${event}`);
  }
});

// P0-2: Webhook signature clock skew validation
test("accepts callbacks within the symmetric 5-minute clock skew window", () => {
  const baseFixture = fixture();
  const now = baseFixture.now;
  
  // Test both edges of the acceptable 5-minute window (300 seconds)
  const withinWindow = {
    ...baseFixture,
    now: now + 300 * 1000,
  };
  assert.doesNotThrow(() => {
    verifyCallbackEnvelope(withinWindow);
  }, "Should accept callback at the positive 5-minute boundary");

  const negativeBoundary = {
    ...baseFixture,
    now: now - 300 * 1000,
  };
  assert.doesNotThrow(() => {
    verifyCallbackEnvelope(negativeBoundary);
  }, "Should accept callback at the negative 5-minute boundary");
  
  // Test just outside the acceptable window
  const outsideWindow = {
    ...baseFixture,
    now: now + 301 * 1000,
  };
  assert.throws(() => {
    verifyCallbackEnvelope(outsideWindow);
  }, /Callback timestamp is outside the allowed window/, "Should reject callback outside 5-minute window");
  
  // Test negative skew (callback from the future)
  const futureCallback = {
    ...baseFixture,
    now: now - 301 * 1000,
  };
  assert.throws(() => {
    verifyCallbackEnvelope(futureCallback);
  }, /Callback timestamp is outside the allowed window/, "Should reject future callback outside window");
});

// P0-1: Webhook deduplication - eventIdentity generates deterministic idempotency keys
test("generates deterministic eventIdentity for deduplication across webhook replays", () => {
  const checkoutCompletedPayload = {
    event: "creator_subscription.checkout.completed",
    sessionId: "session_abc123",
  };
  
  // Same payload should always generate same eventIdentity
  const identity1 = eventIdentity(checkoutCompletedPayload);
  const identity2 = eventIdentity(checkoutCompletedPayload);
  assert.equal(identity1, identity2, "eventIdentity must be deterministic for replay deduplication");
  assert.equal(identity1, "creator_subscription.checkout.completed:session_abc123");
  
  // Different sessionId should generate different eventIdentity
  const differentSessionPayload = {
    event: "creator_subscription.checkout.completed",
    sessionId: "session_def456",
  };
  const differentIdentity = eventIdentity(differentSessionPayload);
  assert.notEqual(identity1, differentIdentity, "Different sessionIds must produce different identities");
  
  // Payment events use paymentId for identity
  const paymentSucceededPayload = {
    event: "creator_subscription.payment.succeeded",
    paymentId: "pay_789",
  };
  const paymentIdentity = eventIdentity(paymentSucceededPayload);
  assert.equal(paymentIdentity, "creator_subscription.payment.succeeded:pay_789");
  
  // Payment events can use paymentReference as fallback
  const paymentWithRefPayload = {
    event: "creator_subscription.payment.succeeded",
    paymentReference: "txn_456",
  };
  const paymentRefIdentity = eventIdentity(paymentWithRefPayload);
  assert.equal(paymentRefIdentity, "creator_subscription.payment.succeeded:txn_456");
  
  // Refund events use orderId for identity
  const refundPayload = {
    event: "creator_subscription.payment.refunded",
    orderId: "order_xyz",
  };
  const refundIdentity = eventIdentity(refundPayload);
  assert.equal(refundIdentity, "creator_subscription.payment.refunded:order_xyz");
  
  // Missing required identity fields should return null (will be rejected at Firestore transaction level)
  const missingIdentityPayload = {
    event: "creator_subscription.checkout.completed",
    // Missing sessionId
  };
  const nullIdentity = eventIdentity(missingIdentityPayload);
  assert.equal(nullIdentity, null, "Missing identity field must return null for safe rejection");
  
  // Lifecycle events (active, cancel_requested, canceled) return null as they are idempotent
  assert.equal(
    eventIdentity({event: "creator_subscription.active"}),
    null,
    "Lifecycle events do not need deduplication"
  );
  assert.equal(
    eventIdentity({event: "creator_subscription.cancel_requested"}),
    null
  );
  assert.equal(
    eventIdentity({event: "creator_subscription.canceled"}),
    null
  );
});

// P0-1: Webhook deduplication - transaction-level idempotency check
test("describes transaction-level webhook deduplication flow for Firestore idempotency", () => {
  // This test documents the transaction-level deduplication that occurs in processCallback (index.js)
  // The actual Firestore transaction test requires mocking Firebase Admin SDK
  
  // Transaction flow for P0-1 webhook deduplication:
  // 1. Generate eventIdentity from payload → "event:uniqueId" hash
  // 2. Check if portalyEvents.doc(eventIdHash) exists in transaction
  // 3. If EXISTS (duplicate) → return {duplicate: true} immediately
  // 4. If NOT EXISTS (first occurrence) → continue processing
  // 5. Create portalyEvents document with identity → marks event as processed
  // 6. Update subscription state atomically within same transaction
  
  // Prevention guarantees:
  // - Webhook replay with identical payload → same eventIdentity → duplicate detection
  // - Concurrent webhook delivery → transaction guarantees atomicity
  // - Graceful degradation → duplicate webhook returns early without state update
  
  // Example flow documented:
  const eventPayload = fixture().payload;
  const identity = eventIdentity(eventPayload);
  
  assert.ok(identity, "Valid webhook must have non-null eventIdentity for deduplication");
  assert.equal(
    typeof identity,
    "string",
    "eventIdentity must be string for Firestore document ID use",
  );
  assert.ok(
    identity.includes(":"),
    "eventIdentity format must be 'event:uniqueId' for clarity",
  );
  
  // Deduplication logic is transaction-safe in processCallback:
  // const eventRef = db.collection("portalyEvents").doc(createHash("sha256").update(identity).digest("hex"));
  // const eventSnapshot = await transaction.get(eventRef);
  // if (eventSnapshot?.exists) {
  //   return {duplicate: true};  // Webhook was already processed
  // }
  // ...continue to create event and update subscription state...
});
