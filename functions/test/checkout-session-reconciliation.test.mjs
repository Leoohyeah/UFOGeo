import assert from "node:assert/strict";
import test from "node:test";

import {
  checkoutReconciliationOrchestrationResult,
  checkoutSessionReconciliationTarget,
  reconcileCheckoutSessionPath,
  subscriptionReconciliationLookupId,
} from "../checkout-session-reconciliation.mjs";

const planId = "JO5cmDQdqTtb6AkkcnNW";
const context = {
  uid: "uid-1",
  email: "Member@Example.com",
  planId,
  mode: "test",
};

function pendingUser(overrides = {}) {
  return {
    email: "member@example.com",
    mode: "test",
    proActive: false,
    subscriptionStatus: "checkout_ready",
    subscriptionId: "session-1",
    currentCheckoutSessionId: "session-1",
    planId,
    cancelAtPeriodEnd: false,
    ...overrides,
  };
}

function uncertainLock(overrides = {}) {
  return {
    uid: "uid-1",
    mode: "test",
    planId,
    status: "uncertain",
    sessionId: "session-1",
    ...overrides,
  };
}

function localSession(overrides = {}) {
  return {
    uid: "uid-1",
    customerEmail: "member@example.com",
    sessionId: "session-1",
    subscriptionId: "session-1",
    merchantOrderNumber: "order-1",
    mode: "test",
    planId,
    status: "response_incomplete",
    ...overrides,
  };
}

function providerSession(status, overrides = {}) {
  return {data: {
    sessionId: "session-1",
    status,
    merchantOrderNumber: "order-1",
    customer: {email: "MEMBER@example.com"},
    plan: {id: planId},
    mode: "test",
    ...overrides,
  }};
}

function productionPath(overrides = {}) {
  const calls = [];
  const options = {
    ...context,
    user: pendingUser(),
    lock: uncertainLock(),
    loadSession: async (sessionId) => {
      calls.push(["load", sessionId]);
      return localSession();
    },
    queryCheckoutSession: async (sessionId) => {
      calls.push(["query", sessionId]);
      return providerSession("checkout_ready");
    },
    persistTerminal: async (value) => {
      calls.push(["terminal", value.providerStatus]);
      return {kind: "terminal_persisted", status: value.providerStatus};
    },
    reconcileCompleted: async (value) => {
      calls.push(["subscription", value.trustedLookupId]);
      return {
        kind: "subscription_reconciled",
        lookupId: subscriptionReconciliationLookupId({
          trustedLookupId: value.trustedLookupId,
        }),
      };
    },
    ...overrides,
  };
  return {calls, run: () => reconcileCheckoutSessionPath(options)};
}

test("production refresh path verifies and finalizes only provider checkout terminal states", async () => {
  for (const status of ["failed", "canceled", "cancelled", "expired"]) {
    const path = productionPath({
      queryCheckoutSession: async (sessionId) => {
        path.calls.push(["query", sessionId]);
        return providerSession(status);
      },
    });

    const result = await path.run();

    assert.deepEqual(result, {kind: "terminal_persisted", status});
    assert.deepEqual(path.calls, [
      ["load", "session-1"],
      ["query", "session-1"],
      ["terminal", status],
    ]);
  }
});

test("lock-only completed checkout supplies its verified target as subscription lookup fallback", async () => {
  const path = productionPath({
    user: {},
    queryCheckoutSession: async (sessionId) => {
      path.calls.push(["query", sessionId]);
      return providerSession("completed");
    },
  });

  const result = await path.run();

  assert.deepEqual(result, {
    kind: "subscription_reconciled",
    lookupId: "session-1",
  });
  assert.deepEqual(path.calls, [
    ["load", "session-1"],
    ["query", "session-1"],
    ["subscription", "session-1"],
  ]);
});

test("production refresh path keeps pending checkout and lock untouched", async () => {
  const path = productionPath();

  const result = await path.run();

  assert.equal(result.kind, "pending");
  assert.equal(result.providerStatus, "checkout_ready");
  assert.deepEqual(path.calls, [
    ["load", "session-1"],
    ["query", "session-1"],
  ]);
});

test("getSubscription orchestration maps provider pending to the existing held response", async () => {
  const path = productionPath();

  const result = checkoutReconciliationOrchestrationResult(await path.run());

  assert.deepEqual(result, {kind: "held"});
  assert.deepEqual(path.calls, [
    ["load", "session-1"],
    ["query", "session-1"],
  ]);
});

test("provider failures, unknown states, and identity mismatches never reach a write adapter", async () => {
  const unsafeResponses = [
    providerSession("unknown"),
    providerSession("expired", {sessionId: "session-other"}),
    providerSession("expired", {customer: {email: "other@example.com"}}),
    providerSession("expired", {plan: {id: "plan-other"}}),
    providerSession("expired", {mode: "live"}),
    providerSession("expired", {merchantOrderNumber: "order-other"}),
  ];

  for (const response of unsafeResponses) {
    const path = productionPath({queryCheckoutSession: async () => response});
    await assert.rejects(path.run());
    assert.equal(path.calls.some(([kind]) => kind === "terminal"), false);
    assert.equal(path.calls.some(([kind]) => kind === "subscription"), false);
  }

  const failedQuery = productionPath({
    queryCheckoutSession: async () => {
      throw new Error("provider unavailable");
    },
  });
  await assert.rejects(failedQuery.run(), /provider unavailable/);
  assert.deepEqual(failedQuery.calls, [["load", "session-1"]]);
});

test("an uncertain POST without a verified session ID remains held and is not queried", () => {
  assert.equal(checkoutSessionReconciliationTarget({
    ...context,
    user: {},
    lock: uncertainLock({sessionId: undefined}),
  }), null);
});

test("stored session identity must match UID, email, plan, mode, and session before provider query", async () => {
  for (const session of [
    localSession({uid: "uid-other"}),
    localSession({customerEmail: "other@example.com"}),
    localSession({planId: "plan-other"}),
    localSession({mode: "live"}),
    localSession({sessionId: "session-other"}),
  ]) {
    const path = productionPath({loadSession: async () => session});
    await assert.rejects(path.run());
    assert.equal(path.calls.some(([kind]) => kind === "query"), false);
    assert.equal(path.calls.some(([kind]) => kind === "terminal"), false);
  }
});

test("opposite-mode historical pending state is not queried with the current API key", () => {
  assert.equal(checkoutSessionReconciliationTarget({
    ...context,
    mode: "live",
    user: pendingUser({mode: "test"}),
    lock: null,
  }), null);
});
