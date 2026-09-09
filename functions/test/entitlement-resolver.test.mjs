import assert from "node:assert/strict";
import test from "node:test";

import {
  ENTITLEMENT_GRANT_CHECKOUT_CODE,
  ENTITLEMENT_SOURCES,
  resolveEntitlement,
  validateEntitlementGrant,
} from "../entitlement-resolver.mjs";

const NOW = Date.parse("2026-09-01T00:00:00.000Z");

function grant(overrides = {}) {
  return {
    active: true,
    kind: "lifetime_pro",
    expiresAt: null,
    grantedAt: "2026-08-01T00:00:00.000Z",
    grantedBy: "owner@example.com",
    reason: "support grant",
    ...overrides,
  };
}

function portaly(overrides = {}) {
  return {
    proActive: true,
    subscriptionStatus: "active",
    mode: "live",
    ...overrides,
  };
}

test("resolves a lifetime server grant without a provider entitlement", () => {
  const value = resolveEntitlement({grant: grant(), now: NOW});

  assert.deepEqual(value, {
    proActive: true,
    entitlementSource: ENTITLEMENT_SOURCES.SERVER_GRANT,
    grant: {
      kind: "lifetime_pro",
      expiresAt: null,
      grantedAt: "2026-08-01T00:00:00.000Z",
    },
    portalyProActive: false,
    grantStateValid: true,
  });
  assert.equal(ENTITLEMENT_GRANT_CHECKOUT_CODE, "SERVER_GRANT_ACTIVE");
});

test("resolves an unexpired time-limited grant and rejects an expired grant", () => {
  const current = grant({kind: "temporary_pro", expiresAt: "2026-09-02T00:00:00.000Z"});
  assert.equal(resolveEntitlement({grant: current, now: NOW}).proActive, true);
  assert.equal(
    resolveEntitlement({grant: current, now: Date.parse("2026-09-02T00:00:00.000Z")}).proActive,
    false,
  );
  assert.equal(validateEntitlementGrant(current, {now: NOW}).grant.expiresAt, "2026-09-02T00:00:00.000Z");
});

test("fails closed for malformed grant records", () => {
  for (const [overrides, code] of [
    [{active: "true"}, "ENTITLEMENT_GRANT_ACTIVE_INVALID"],
    [{kind: "unknown"}, "ENTITLEMENT_GRANT_KIND_INVALID"],
    [{expiresAt: undefined}, "ENTITLEMENT_GRANT_EXPIRY_MISSING"],
    [{expiresAt: "not-a-date"}, "ENTITLEMENT_GRANT_EXPIRY_INVALID"],
    [{grantedAt: undefined}, "ENTITLEMENT_GRANT_GRANTED_AT_MISSING"],
    [{grantedAt: "not-a-date"}, "ENTITLEMENT_GRANT_GRANTED_AT_INVALID"],
    [{grantedAt: "2026-09-01T00:00:00.001Z"}, "ENTITLEMENT_GRANT_GRANTED_AT_FUTURE"],
    [{kind: "temporary_pro", expiresAt: "2026-07-31T23:59:59.999Z"},
      "ENTITLEMENT_GRANT_PERIOD_INVALID"],
    [{grantedBy: " "}, "ENTITLEMENT_GRANT_GRANTED_BY_INVALID"],
    [{reason: " "}, "ENTITLEMENT_GRANT_REASON_INVALID"],
    [{revokedAt: "not-a-date", active: false}, "ENTITLEMENT_GRANT_REVOKED_AT_INVALID"],
    [{revokedAt: "2026-08-20T00:00:00.000Z", revokedBy: " "}, "ENTITLEMENT_GRANT_REVOKED_BY_INVALID"],
    [{active: false, revokedAt: "2026-07-31T23:59:59.999Z", revokedBy: "owner@example.com"},
      "ENTITLEMENT_GRANT_REVOCATION_INVALID"],
    [{revokedBy: "owner@example.com"}, "ENTITLEMENT_GRANT_REVOKED_AT_MISSING"],
  ]) {
    const result = validateEntitlementGrant(grant(overrides), {now: NOW});
    assert.equal(result.valid, false, code);
    assert.equal(result.active, false, code);
    assert.equal(result.code, code);
    assert.equal(resolveEntitlement({grant: grant(overrides), now: NOW}).proActive, false);
  }
});

test("revoked or inactive grants never remain effective", () => {
  for (const value of [
    grant({active: false}),
    grant({active: false, revokedAt: "2026-08-20T00:00:00.000Z", revokedBy: "owner@example.com"}),
  ]) {
    assert.equal(resolveEntitlement({grant: value, now: NOW}).entitlementSource, "none");
    assert.equal(resolveEntitlement({grant: value, now: NOW}).grant, null);
  }
});

test("combines Portaly and server grant sources without collapsing metadata", () => {
  const value = resolveEntitlement({
    grant: grant(),
    portalyState: portaly(),
    expectedMode: "live",
    now: NOW,
  });
  assert.equal(value.proActive, true);
  assert.equal(value.entitlementSource, ENTITLEMENT_SOURCES.PORTALY_AND_SERVER_GRANT);
  assert.equal(value.portalyProActive, true);
  assert.deepEqual(value.grant, {
    kind: "lifetime_pro",
    expiresAt: null,
    grantedAt: "2026-08-01T00:00:00.000Z",
  });
});

test("Portaly terminal states do not grant access, while valid grant survives them", () => {
  assert.equal(
    resolveEntitlement({
      portalyState: portaly({proActive: false, subscriptionStatus: "canceled"}),
      expectedMode: "live",
      now: NOW,
    }).entitlementSource,
    ENTITLEMENT_SOURCES.NONE,
  );
  assert.equal(
    resolveEntitlement({
      grant: grant(),
      portalyState: portaly({proActive: false, subscriptionStatus: "canceled"}),
      expectedMode: "live",
      now: NOW,
    }).entitlementSource,
    ENTITLEMENT_SOURCES.SERVER_GRANT,
  );
  assert.equal(
    resolveEntitlement({
      grant: grant(),
      portalyState: portaly({proActive: true, subscriptionStatus: "canceled"}),
      expectedMode: "live",
      now: NOW,
    }).portalyProActive,
    false,
  );
});

test("Portaly missing or unknown lifecycle states fail closed", () => {
  for (const subscriptionStatus of [undefined, null, "", "unknown"]) {
    const value = resolveEntitlement({
      portalyState: portaly({subscriptionStatus}),
      expectedMode: "live",
      now: NOW,
    });
    assert.equal(value.proActive, false);
    assert.equal(value.portalyProActive, false);
    assert.equal(value.entitlementSource, ENTITLEMENT_SOURCES.NONE);
  }
});

test("Portaly entitlement requires explicit matching live or test modes", () => {
  for (const expectedMode of ["live", "test"]) {
    const value = resolveEntitlement({
      portalyState: portaly({mode: expectedMode}),
      expectedMode,
      now: NOW,
    });
    assert.equal(value.proActive, true);
    assert.equal(value.portalyProActive, true);
    assert.equal(value.entitlementSource, ENTITLEMENT_SOURCES.PORTALY);
  }

  for (const [storedMode, expectedMode] of [
    ["test", "live"],
    ["live", "test"],
    [undefined, "live"],
    [null, "live"],
    ["sandbox", "live"],
    ["live", undefined],
    ["live", null],
    ["live", "sandbox"],
  ]) {
    const value = resolveEntitlement({
      portalyState: portaly({mode: storedMode}),
      expectedMode,
      now: NOW,
    });
    assert.equal(value.proActive, false, `${String(storedMode)} -> ${String(expectedMode)}`);
    assert.equal(value.portalyProActive, false);
    assert.equal(value.entitlementSource, ENTITLEMENT_SOURCES.NONE);
  }
});

test("Portaly entitlement requires the configured plan when one is supplied", () => {
  assert.equal(resolveEntitlement({
    portalyState: portaly({planId: "plan-pro"}),
    expectedMode: "live",
    expectedPlanId: "plan-pro",
    now: NOW,
  }).portalyProActive, true);

  for (const storedPlanId of [undefined, null, "", "other-plan"]) {
    const value = resolveEntitlement({
      portalyState: portaly({planId: storedPlanId}),
      expectedMode: "live",
      expectedPlanId: "plan-pro",
      now: NOW,
    });
    assert.equal(value.proActive, false, String(storedPlanId));
    assert.equal(value.portalyProActive, false, String(storedPlanId));
  }
});

test("server grants remain active when Portaly mode is absent or mismatched", () => {
  for (const [storedMode, expectedMode] of [
    [undefined, undefined],
    ["test", "live"],
    ["live", "test"],
  ]) {
    const value = resolveEntitlement({
      grant: grant(),
      portalyState: portaly({mode: storedMode}),
      expectedMode,
      now: NOW,
    });
    assert.equal(value.proActive, true);
    assert.equal(value.portalyProActive, false);
    assert.equal(value.entitlementSource, ENTITLEMENT_SOURCES.SERVER_GRANT);
  }
});

test("separate users are evaluated independently by their own grant document", () => {
  const grants = new Map([
    ["uid-granted", grant()],
    ["uid-free", null],
  ]);
  assert.equal(resolveEntitlement({grant: grants.get("uid-granted"), now: NOW}).proActive, true);
  assert.equal(resolveEntitlement({grant: grants.get("uid-free"), now: NOW}).proActive, false);
});

// P0-2: Grant expiry validation with millisecond precision boundary testing
test("rejects grant at precise expiry boundary with millisecond accuracy", () => {
  const expiresAtDate = new Date("2026-09-01T00:00:00.000Z");
  const expiresAtMs = expiresAtDate.getTime();
  
  // Test boundary: 1ms before expiry should be valid (grant still active)
  const oneMsBefore = expiresAtMs - 1;
  const grantBeforeExpiry = grant({kind: "temporary_pro", expiresAt: expiresAtDate.toISOString()});
  const resultBefore = validateEntitlementGrant(grantBeforeExpiry, {now: oneMsBefore});
  assert.equal(resultBefore.valid, true, "Grant valid 1ms before expiry");
  assert.equal(resultBefore.grant.expiresAt, expiresAtDate.toISOString());
  
  // Test boundary: exactly at expiry should be invalid (grant expired)
  const resultExact = validateEntitlementGrant(grantBeforeExpiry, {now: expiresAtMs});
  assert.equal(resultExact.valid, false, "Grant invalid at exact expiry time");
  assert.equal(resultExact.code, "ENTITLEMENT_GRANT_EXPIRED");
  
  // Test boundary: 1ms after expiry should be invalid (grant expired)
  const oneMsAfter = expiresAtMs + 1;
  const resultAfter = validateEntitlementGrant(grantBeforeExpiry, {now: oneMsAfter});
  assert.equal(resultAfter.valid, false, "Grant invalid 1ms after expiry");
  assert.equal(resultAfter.code, "ENTITLEMENT_GRANT_EXPIRED");
  
  // Verify resolveEntitlement respects the millisecond precision
  const resolvedBefore = resolveEntitlement({grant: grantBeforeExpiry, now: oneMsBefore});
  assert.equal(resolvedBefore.proActive, true, "Pro active 1ms before expiry");
  
  const resolvedExact = resolveEntitlement({grant: grantBeforeExpiry, now: expiresAtMs});
  assert.equal(resolvedExact.proActive, false, "Pro inactive at exact expiry");
  
  const resolvedAfter = resolveEntitlement({grant: grantBeforeExpiry, now: oneMsAfter});
  assert.equal(resolvedAfter.proActive, false, "Pro inactive 1ms after expiry");
});
