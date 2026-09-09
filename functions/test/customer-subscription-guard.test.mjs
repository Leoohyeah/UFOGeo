import assert from "node:assert/strict";
import test from "node:test";

import {
  customerSubscriptionKey,
  findBlockingCustomerSubscriptionStrict,
  normalizeCustomerEmail,
  portalySubscriptions,
  validatedPortalySubscriptions,
} from "../customer-subscription-guard.mjs";

test("normalizes customer email with trim and case folding", () => {
  assert.equal(normalizeCustomerEmail("  Buyer@Example.COM \n"), "buyer@example.com");
  assert.equal(normalizeCustomerEmail("   "), null);
  assert.equal(normalizeCustomerEmail(null), null);
  assert.equal(normalizeCustomerEmail({email: "buyer@example.com"}), null);
});

test("creates a stable scoped key without exposing plaintext email", () => {
  const input = {email: " Buyer@Example.com ", planId: "plan_pro", mode: "live"};
  const key = customerSubscriptionKey(input);

  assert.match(key, /^customer_[a-f0-9]{64}$/);
  assert.equal(
    key,
    "customer_a8be0bbafb418d8fc96241ab9204e4ea40babf44f7141466223ec303e46c797e",
  );
  assert.equal(key, customerSubscriptionKey({
    email: "buyer@example.COM",
    planId: "plan_pro",
    mode: "live",
  }));
  assert.equal(key.includes("buyer"), false);
  assert.notEqual(key, customerSubscriptionKey({...input, planId: "plan_other"}));
  assert.notEqual(key, customerSubscriptionKey({...input, mode: "test"}));
});

test("rejects malformed customer key inputs", () => {
  for (const input of [
    undefined,
    {},
    {email: "", planId: "plan_pro", mode: "live"},
    {email: "buyer@example.com", planId: "", mode: "live"},
    {email: "buyer@example.com", planId: "plan_pro", mode: "sandbox"},
    {email: ["buyer@example.com"], planId: "plan_pro", mode: "live"},
  ]) {
    assert.equal(customerSubscriptionKey(input), null);
  }
});

test("extracts only documented or already-unwrapped subscription arrays", () => {
  const subscriptions = [{id: "sub_1"}];
  assert.equal(portalySubscriptions({data: subscriptions}), subscriptions);
  assert.equal(portalySubscriptions(subscriptions), subscriptions);
  for (const malformed of [undefined, null, {}, {data: {}}, {data: "bad"}, "bad"]) {
    assert.deepEqual(portalySubscriptions(malformed), []);
  }
});

const strictOptions = {
  email: "buyer@example.com",
  planId: "plan_pro",
  mode: "live",
};

function strictSubscription(overrides = {}) {
  return {
    id: "sub_1",
    customerEmail: "buyer@example.com",
    planId: "plan_pro",
    mode: "live",
    status: "active",
    cancelAtPeriodEnd: false,
    ...overrides,
  };
}

test("strict validation accepts wrapped and bare arrays and normalizes email matching", () => {
  const subscription = strictSubscription({
    customerEmail: " BUYER@EXAMPLE.COM ",
    cancelAtPeriodEnd: true,
  });
  assert.deepEqual(
    validatedPortalySubscriptions({data: [subscription]}, strictOptions),
    [subscription],
  );
  assert.deepEqual(
    validatedPortalySubscriptions([subscription], strictOptions),
    [subscription],
  );
  assert.equal(
    findBlockingCustomerSubscriptionStrict({data: [subscription]}, strictOptions),
    subscription,
  );
});

test("strict validation rejects malformed list payloads with a stable code", () => {
  for (const payload of [undefined, null, {}, {data: null}, {data: {}}, "bad"]) {
    assert.throws(
      () => validatedPortalySubscriptions(payload, strictOptions),
      (error) => error.code === "PORTALY_SUBSCRIPTIONS_PAYLOAD_INVALID",
    );
  }
});

test("strict validation rejects invalid expected scope", () => {
  for (const [options, code] of [
    [{...strictOptions, email: ""}, "EXPECTED_CUSTOMER_EMAIL_INVALID"],
    [{...strictOptions, planId: ""}, "EXPECTED_PLAN_ID_INVALID"],
    [{...strictOptions, mode: "sandbox"}, "EXPECTED_MODE_INVALID"],
  ]) {
    assert.throws(
      () => validatedPortalySubscriptions([], options),
      (error) => error.code === code,
    );
  }
});

test("strict validation rejects missing required fields on an in-scope subscription", () => {
  for (const [field, value, code] of [
    ["id", "", "PORTALY_SUBSCRIPTION_ID_MISSING"],
    ["mode", undefined, "PORTALY_SUBSCRIPTION_MODE_MISSING"],
    ["status", undefined, "PORTALY_SUBSCRIPTION_STATUS_MISSING"],
    ["cancelAtPeriodEnd", undefined, "PORTALY_SUBSCRIPTION_CANCEL_AT_PERIOD_END_INVALID"],
  ]) {
    assert.throws(
      () => validatedPortalySubscriptions({
        data: [strictSubscription({[field]: value})],
      }, strictOptions),
      (error) => error.code === code,
    );
  }
});

test("strict validation rejects records that cannot be proven out of scope", () => {
  for (const [subscription, code] of [
    [null, "PORTALY_SUBSCRIPTION_INVALID"],
    [strictSubscription({planId: undefined}), "PORTALY_SUBSCRIPTION_PLAN_ID_MISSING"],
    [strictSubscription({customerEmail: undefined}), "PORTALY_SUBSCRIPTION_EMAIL_MISSING"],
  ]) {
    assert.throws(
      () => validatedPortalySubscriptions({data: [subscription]}, strictOptions),
      (error) => error.code === code,
    );
  }
});

test("strict validation ignores an explicit opposite mode but rejects invalid provider state", () => {
  assert.deepEqual(
    validatedPortalySubscriptions({
      data: [strictSubscription({
        id: undefined,
        customerEmail: undefined,
        mode: "test",
        status: undefined,
        cancelAtPeriodEnd: undefined,
      })],
    }, strictOptions),
    [],
  );
  assert.equal(
    findBlockingCustomerSubscriptionStrict({
      data: [strictSubscription({id: "sub_test", mode: "test"})],
    }, strictOptions),
    null,
  );

  for (const [subscription, code] of [
    [strictSubscription({mode: "sandbox"}), "PORTALY_SUBSCRIPTION_MODE_INVALID"],
    [strictSubscription({status: "paused"}), "PORTALY_SUBSCRIPTION_STATUS_INVALID"],
    [strictSubscription({cancelAtPeriodEnd: "false"}),
      "PORTALY_SUBSCRIPTION_CANCEL_AT_PERIOD_END_INVALID"],
  ]) {
    assert.throws(
      () => validatedPortalySubscriptions({data: [subscription]}, strictOptions),
      (error) => error.code === code,
    );
  }
});

test("strict validation ignores fully formed records for other emails or plans", () => {
  const canceled = strictSubscription({id: "sub_canceled", status: "canceled"});
  const payload = {data: [
    strictSubscription({id: "other_plan", planId: "plan_other"}),
    strictSubscription({id: "other_email", customerEmail: "other@example.com"}),
    canceled,
  ]};
  assert.deepEqual(validatedPortalySubscriptions(payload, strictOptions), [canceled]);
  assert.equal(findBlockingCustomerSubscriptionStrict(payload, strictOptions), null);
});
