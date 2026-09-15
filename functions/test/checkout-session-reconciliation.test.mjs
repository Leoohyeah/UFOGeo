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

test("a terminal old checkout cannot block a newer completed checkout for the same member", async () => {
  let oldSessionStatus = "response_incomplete";
  let oldLockPresent = true;
  const oldUser = pendingUser({
    subscriptionId: "session-old",
    currentCheckoutSessionId: "session-old",
  });
  const oldPath = productionPath({
    user: oldUser,
    lock: uncertainLock({sessionId: "session-old"}),
    loadSession: async () => localSession({
      sessionId: "session-old",
      subscriptionId: "session-old",
      status: oldSessionStatus,
    }),
    queryCheckoutSession: async () => providerSession("expired", {
      sessionId: "session-old",
    }),
    persistTerminal: async ({providerStatus}) => {
      oldSessionStatus = "checkout_failed";
      oldLockPresent = false;
      return {kind: "terminal_persisted", status: providerStatus};
    },
  });

  assert.deepEqual(await oldPath.run(), {
    kind: "terminal_persisted",
    status: "expired",
  });
  assert.equal(oldSessionStatus, "checkout_failed");
  assert.equal(oldLockPresent, false);
  assert.equal(checkoutSessionReconciliationTarget({
    ...context,
    user: {
      ...oldUser,
      proActive: false,
      subscriptionStatus: "checkout_failed",
      subscriptionId: null,
    },
    lock: null,
  }), null);

  const newUser = pendingUser({
    subscriptionId: "session-new",
    currentCheckoutSessionId: "session-new",
  });
  let newState;
  const newPath = productionPath({
    user: newUser,
    lock: uncertainLock({sessionId: "session-new"}),
    loadSession: async () => localSession({
      sessionId: "session-new",
      subscriptionId: "session-new",
      merchantOrderNumber: "order-2",
    }),
    queryCheckoutSession: async (sessionId) => providerSession("completed", {
      sessionId,
      merchantOrderNumber: "order-2",
    }),
    reconcileCompleted: async ({target, localSession}) => {
      newState = {
        subscriptionId: target.sessionId,
        currentCheckoutSessionId: target.sessionId,
        subscriptionStatus: "active",
        proActive: true,
        oldSessionStatus,
        newSessionStatus: "active",
        oldLockPresent,
      };
      assert.equal(localSession.sessionId, "session-new");
      return {kind: "subscription_reconciled", lookupId: target.sessionId};
    },
  });

  assert.deepEqual(await newPath.run(), {
    kind: "subscription_reconciled",
    lookupId: "session-new",
  });
  assert.deepEqual(newState, {
    subscriptionId: "session-new",
    currentCheckoutSessionId: "session-new",
    subscriptionStatus: "active",
    proActive: true,
    oldSessionStatus: "checkout_failed",
    newSessionStatus: "active",
    oldLockPresent: false,
  });
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

test("callback-resolved local sessions bypass stale pending snapshots and reconcile the subscription", async () => {
  for (const [status, user] of [
    ["active", pendingUser()],
    ["completed", pendingUser()],
    ["active", {}],
  ]) {
    const path = productionPath({
      user,
      loadSession: async (sessionId) => {
        path.calls.push(["load", sessionId]);
        return localSession({status});
      },
      queryCheckoutSession: async () => {
        throw new Error("resolved checkout must not be queried as pending");
      },
    });

    const result = await path.run();

    assert.deepEqual(result, {
      kind: "subscription_reconciled",
      lookupId: "session-1",
    });
    assert.deepEqual(path.calls, [
      ["load", "session-1"],
      ["subscription", "session-1"],
    ]);
  }
});

test("regression: timeout-retry flow should still reconcile when the local checkout session is missing", async () => {
  const path = productionPath({
    loadSession: async (sessionId) => {
      path.calls.push(["load", sessionId]);
      return null;
    },
    queryCheckoutSession: async (sessionId) => {
      path.calls.push(["query", sessionId]);
      return providerSession("completed", {sessionId});
    },
    reconcileCompleted: async ({target}) => {
      path.calls.push(["subscription", target.sessionId]);
      return {kind: "subscription_reconciled", lookupId: target.sessionId};
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

test("missing local session with provider pending still fails closed", async () => {
  const path = productionPath({
    loadSession: async (sessionId) => {
      path.calls.push(["load", sessionId]);
      return null;
    },
    queryCheckoutSession: async (sessionId) => {
      path.calls.push(["query", sessionId]);
      return providerSession("checkout_ready", {sessionId});
    },
  });

  await assert.rejects(path.run(), (error) =>
    error?.code === "CHECKOUT_RECONCILIATION_SESSION_MISSING");
  assert.deepEqual(path.calls, [
    ["load", "session-1"],
    ["query", "session-1"],
  ]);
  assert.equal(path.calls.some(([kind]) => kind === "terminal"), false);
  assert.equal(path.calls.some(([kind]) => kind === "subscription"), false);
});

test("missing local session with provider identity mismatch still fails closed", async () => {
  const path = productionPath({
    loadSession: async (sessionId) => {
      path.calls.push(["load", sessionId]);
      return null;
    },
    queryCheckoutSession: async (sessionId) => {
      path.calls.push(["query", sessionId]);
      return providerSession("completed", {
        sessionId,
        customer: {email: "other@example.com"},
      });
    },
  });

  await assert.rejects(path.run(), (error) =>
    error?.code === "PORTALY_CHECKOUT_EMAIL_MISMATCH");
  assert.deepEqual(path.calls, [
    ["load", "session-1"],
    ["query", "session-1"],
  ]);
  assert.equal(path.calls.some(([kind]) => kind === "terminal"), false);
  assert.equal(path.calls.some(([kind]) => kind === "subscription"), false);
});

test("callback-resolved sessions still fail closed for a different UID or session", async () => {
  for (const session of [
    localSession({status: "active", uid: "uid-other"}),
    localSession({status: "completed", sessionId: "session-other"}),
    localSession({status: "active", accountDeleted: true}),
  ]) {
    const path = productionPath({loadSession: async () => session});
    await assert.rejects(path.run(), (error) => [
      "CHECKOUT_RECONCILIATION_UID_MISMATCH",
      "CHECKOUT_RECONCILIATION_SESSION_ID_MISMATCH",
      "CHECKOUT_RECONCILIATION_SESSION_STATE_CHANGED",
    ].includes(error.code));
    assert.equal(path.calls.some(([kind]) => kind === "query"), false);
    assert.equal(path.calls.some(([kind]) => kind === "subscription"), false);
  }
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
