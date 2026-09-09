import assert from "node:assert/strict";
import test from "node:test";

import {
  entitlementGrantCheckoutGuardDecision,
  parseEntitlementAdminArgs,
} from "../entitlement-admin.mjs";

const PLAN_ID = "JO5cmDQdqTtb6AkkcnNW";
const NOW = Date.parse("2026-09-04T00:00:00.000Z");

function lock(overrides = {}) {
  return {
    uid: "user-1",
    planId: PLAN_ID,
    mode: "live",
    status: "checkout_ready",
    expiresAt: NOW + 60_000,
    ...overrides,
  };
}

test("admin CLI defaults grant and revoke to dry-run", () => {
  const grant = parseEntitlementAdminArgs([
    "grant",
    "--project", "ufogeo-adac7",
    "--email", "member@example.com",
    "--kind", "lifetime_pro",
    "--granted-by", "owner",
    "--reason", "support grant",
  ]);
  assert.equal(grant.apply, false);
  assert.equal(grant.project, "ufogeo-adac7");
  assert.equal(grant.email, "member@example.com");

  const revoke = parseEntitlementAdminArgs([
    "revoke",
    "--project=ufogeo-adac7",
    "--email=member@example.com",
    "--revoked-by=owner",
  ]);
  assert.equal(revoke.apply, false);
  assert.equal(revoke.reason, "revoked by administrator");
});

test("admin CLI requires explicit apply for a real mutation but accepts it when requested", () => {
  const options = parseEntitlementAdminArgs([
    "grant",
    "--project", "ufogeo-adac7",
    "--email", "member@example.com",
    "--kind", "temporary_pro",
    "--expires-at", "2026-12-31T00:00:00Z",
    "--granted-by", "owner",
    "--reason", "promotion",
    "--apply",
  ]);
  assert.equal(options.apply, true);
  assert.equal(options.kind, "temporary_pro");
});

test("admin CLI rejects secrets, unsupported kinds, and incomplete mutations", () => {
  assert.throws(() => parseEntitlementAdminArgs([
    "status", "--project", "ufogeo-adac7", "--email", "member@example.com", "--token", "secret",
  ]), /secret|token/i);
  assert.throws(() => parseEntitlementAdminArgs([
    "grant", "--project", "ufogeo-adac7", "--email", "member@example.com",
    "--kind", "pro", "--granted-by", "owner", "--reason", "test",
  ]), /kind/i);
  assert.throws(() => parseEntitlementAdminArgs([
    "revoke", "--project", "ufogeo-adac7", "--email", "member@example.com",
  ]), /revoked-by/i);
});

test("admin CLI help is parse-only and does not require credentials", () => {
  assert.equal(parseEntitlementAdminArgs(["--help"]).help, true);
});

test("grant guard blocks every active checkout and deletion lock", () => {
  for (const status of [
    "pending",
    "checkout_ready",
    "created",
    "creating",
    "uncertain",
    "account_deleting",
    "account_deleted",
  ]) {
    const fields = ["creating"].includes(status) ? {
      leaseExpiresAtMs: NOW + 60_000,
      safetyHoldUntilMs: NOW + 86_400_000,
    } : ["uncertain", "account_deleting", "account_deleted"].includes(status) ? {
      safetyHoldUntilMs: NOW + 86_400_000,
    } : {};
    assert.deepEqual(
      entitlementGrantCheckoutGuardDecision({
        uid: "user-1",
        locks: [lock({status, ...fields})],
        now: NOW,
      }),
      {
        kind: "blocked",
        status,
        code: "ENTITLEMENT_GRANT_CHECKOUT_CONFLICT",
      },
      `status ${status}`,
    );
  }
});

test("grant guard blocks email-lock ownership conflicts and pending user state", () => {
  assert.deepEqual(
    entitlementGrantCheckoutGuardDecision({
      uid: "new-user",
      locks: [lock({uid: "old-user"})],
      now: NOW,
    }),
    {kind: "blocked", status: "checkout_ready", code: "ENTITLEMENT_GRANT_CHECKOUT_CONFLICT"},
  );
  assert.deepEqual(
    entitlementGrantCheckoutGuardDecision({
      uid: "user-1",
      user: {currentCheckoutSessionId: "session-1", subscriptionStatus: "pending"},
      now: NOW,
    }),
    {kind: "blocked", status: "checkout_pending", code: "ENTITLEMENT_GRANT_CHECKOUT_CONFLICT"},
  );
  assert.deepEqual(
    entitlementGrantCheckoutGuardDecision({
      uid: "user-1",
      user: {accountDeleting: true},
      now: NOW,
    }),
    {kind: "blocked", status: "account_deleting", code: "ACCOUNT_DELETION_IN_PROGRESS"},
  );
});

test("grant guard fails closed for unknown lock state and allows only expired valid locks", () => {
  assert.deepEqual(
    entitlementGrantCheckoutGuardDecision({
      uid: "user-1",
      locks: [lock({status: "creating", leaseExpiresAtMs: NOW - 1, safetyHoldUntilMs: NOW - 1})],
      now: NOW,
    }),
    {kind: "safe"},
  );
  assert.deepEqual(
    entitlementGrantCheckoutGuardDecision({
      uid: "user-1",
      locks: [lock({status: "uncertain", safetyHoldUntilMs: undefined})],
      now: NOW,
    }),
    {kind: "unsafe", status: "checkout_lock_expiry_unknown", code: "ENTITLEMENT_GRANT_CHECKOUT_STATE_UNKNOWN"},
  );
  assert.deepEqual(
    entitlementGrantCheckoutGuardDecision({
      uid: "user-1",
      locks: [lock({mode: undefined, expiresAt: NOW - 1})],
      now: NOW,
    }),
    {kind: "safe"},
  );
  assert.deepEqual(
    entitlementGrantCheckoutGuardDecision({
      uid: "user-1",
      locks: [lock({mode: undefined})],
      now: NOW,
    }),
    {kind: "blocked", status: "checkout_ready", code: "ENTITLEMENT_GRANT_CHECKOUT_CONFLICT"},
  );
  for (const status of [
    "checkout_completed",
    "checkout_failed",
    "completed",
    "failed",
    "expired",
    "canceled",
    "cancelled",
  ]) {
    assert.deepEqual(
      entitlementGrantCheckoutGuardDecision({
        uid: "user-1",
        locks: [lock({mode: undefined, status, expiresAt: undefined})],
        now: NOW,
      }),
      {kind: "safe"},
      `terminal status ${status}`,
    );
  }
  assert.deepEqual(
    entitlementGrantCheckoutGuardDecision({
      uid: "user-1",
      locks: [lock({planId: "other-plan"})],
      now: NOW,
    }),
    {kind: "safe"},
  );
});
