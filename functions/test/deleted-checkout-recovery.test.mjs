import assert from "node:assert/strict";
import test from "node:test";

import {
  inspectDeletedCheckoutProvider,
  runDeletedCheckoutLease,
} from "../deleted-checkout-recovery.mjs";

test("terminal/refunded provider state CAS-clears the tombstone and acquires once", async () => {
  const events = [];
  let attempts = 0;
  const result = await runDeletedCheckoutLease({
    acquireLease: async () => {
      events.push("lease");
      attempts += 1;
      return attempts === 1 ?
        {kind: "safety_hold", status: "account_deleted"} :
        {kind: "acquire"};
    },
    inspectProvider: async () => {
      events.push("inspect");
      return {kind: "terminal"};
    },
    clearTombstone: async () => {
      events.push("cas_delete");
      return true;
    },
  });

  assert.deepEqual(result, {kind: "acquire"});
  assert.deepEqual(events, ["lease", "inspect", "cas_delete", "lease"]);
});

test("renewable or unavailable provider state preserves the lock and safety hold", async () => {
  for (const inspection of [
    {kind: "renewable"},
    {kind: "uncertain", stage: "list"},
    {kind: "uncertain", stage: "detail"},
  ]) {
    let attempts = 0;
    let inspected = 0;
    let cleared = 0;
    let tombstonePresent = true;
    const result = await runDeletedCheckoutLease({
      acquireLease: async () => {
        attempts += 1;
        return {kind: "safety_hold", status: "account_deleted"};
      },
      inspectProvider: async () => {
        inspected += 1;
        return inspection;
      },
      clearTombstone: async () => {
        cleared += 1;
        tombstonePresent = false;
        return true;
      },
    });
    assert.deepEqual(result, {kind: "safety_hold", status: "account_deleted"});
    assert.equal(attempts, 1);
    assert.equal(inspected, 1);
    assert.equal(cleared, 0);
    assert.equal(tombstonePresent, true);
  }
});

test("provider and CAS exceptions preserve the lock and never acquire twice", async () => {
  for (const failure of ["provider", "cas"]) {
    let attempts = 0;
    let inspected = 0;
    const result = await runDeletedCheckoutLease({
      acquireLease: async () => {
        attempts += 1;
        return {kind: "safety_hold", status: "account_deleted"};
      },
      inspectProvider: async () => {
        inspected += 1;
        if (failure === "provider") throw new Error("provider unavailable");
        return {kind: "terminal"};
      },
      clearTombstone: async () => {
        if (failure === "cas") throw new Error("transaction failed");
        return true;
      },
    });
    assert.deepEqual(result, {kind: "safety_hold", status: "account_deleted"});
    assert.equal(attempts, 1);
    assert.equal(inspected, 1);
  }
});

test("a failed CAS race keeps the tombstone and never reaches a provider POST", async () => {
  let attempts = 0;
  let tombstonePresent = true;
  const result = await runDeletedCheckoutLease({
    acquireLease: async () => {
      attempts += 1;
      return {kind: "safety_hold", status: "account_deleted"};
    },
    inspectProvider: async () => ({kind: "terminal"}),
    clearTombstone: async () => {
      tombstonePresent = true;
      return false;
    },
  });
  assert.deepEqual(result, {kind: "safety_hold", status: "account_deleted"});
  assert.equal(attempts, 1);
  assert.equal(tombstonePresent, true);
});

test("an uncertain checkout hold never enters account-deletion inspection", async () => {
  let inspected = 0;
  const decision = {kind: "safety_hold", status: "uncertain"};
  const result = await runDeletedCheckoutLease({
    acquireLease: async () => decision,
    inspectProvider: async () => {
      inspected += 1;
      return {kind: "terminal"};
    },
    clearTombstone: async () => true,
  });
  assert.equal(result, decision);
  assert.equal(inspected, 0);
});

test("shared provider inspection treats canceled detail as terminal", async () => {
  let detailCalls = 0;
  const result = await inspectDeletedCheckoutProvider({
    fetchSubscriptions: async () => [{id: "sub_1"}],
    selectCandidate: async (subscriptions) => subscriptions[0],
    fetchDetail: async () => {
      detailCalls += 1;
      return {status: "canceled"};
    },
    decodeDetail: async (payload) => ({recoverable: false, status: payload.status}),
    classifyDetail: async (decoded) => decoded.recoverable ?
      {kind: "renewable"} : {kind: "terminal"},
  });
  assert.deepEqual(result, {kind: "terminal"});
  assert.equal(detailCalls, 1);
});
