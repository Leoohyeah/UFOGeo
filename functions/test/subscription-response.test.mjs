import assert from "node:assert/strict";
import test from "node:test";

import {
  calculateExpiringStage,
  calculateNextBillingFromAnchor,
  portalAccessDecision,
  subscriptionStateResponse,
} from "../subscription-response.mjs";

const identity = {
  uid: "uid-1",
  email: "buyer@example.com",
  emailVerified: true,
  fallbackPlanId: "plan-pro",
};

function providerState(overrides = {}) {
  return {
    proActive: true,
    subscriptionStatus: "cancel_requested",
    subscriptionId: "sub-test",
    currentCheckoutSessionId: "sub-test",
    planId: "plan-pro",
    mode: "test",
    nextBillingAt: "2026-10-01T00:00:00.000Z",
    cancelAtPeriodEnd: true,
    cancelEffectiveAt: "2026-10-01T00:00:00.000Z",
    lastReconciledAtMs: Date.parse("2026-09-03T00:00:00.000Z"),
    ...overrides,
  };
}

test("neutralizes provider fields from the opposite environment", () => {
  const response = subscriptionStateResponse({
    ...identity,
    data: providerState(),
    expectedMode: "live",
  });

  assert.deepEqual(response, {
    uid: "uid-1",
    email: "buyer@example.com",
    emailVerified: true,
    proActive: false,
    subscriptionStatus: "none",
    subscriptionId: null,
    planId: "plan-pro",
    mode: "live",
    nextBillingAt: null,
    nextBillingAtMs: null,
    daysUntilRenewal: null,
    cancelAtPeriodEnd: false,
    cancelEffectiveAt: null,
    lastVerifiedAt: "2026-09-03T00:00:00.000Z",
    entitlementSource: "none",
    expiringStage: "none",
    grant: null,
  });
});

test("keeps matching-mode provider fields and entitlement", () => {
  const response = subscriptionStateResponse({
    ...identity,
    data: providerState(),
    expectedMode: "test",
  });

  assert.equal(response.proActive, true);
  assert.equal(response.entitlementSource, "portaly");
  assert.equal(response.subscriptionStatus, "cancel_requested");
  assert.equal(response.subscriptionId, "sub-test");
  assert.equal(response.mode, "test");
  assert.equal(response.nextBillingAt, "2026-10-01T00:00:00.000Z");
  assert.equal(response.nextBillingAtMs, Date.parse("2026-10-01T00:00:00.000Z"));
  assert.equal(response.cancelAtPeriodEnd, true);
  assert.equal(response.cancelEffectiveAt, "2026-10-01T00:00:00.000Z");
  // daysUntilRenewal and expiringStage are time-dependent, so we only check type
  assert.equal(typeof response.daysUntilRenewal, "number");
  assert.equal(typeof response.expiringStage, "string");
});

test("retains a server grant while hiding opposite-mode provider state", () => {
  const response = subscriptionStateResponse({
    ...identity,
    data: providerState(),
    expectedMode: "live",
    grant: {
      active: true,
      kind: "lifetime_pro",
      expiresAt: null,
      grantedAt: "2026-09-01T00:00:00.000Z",
      grantedBy: "owner@example.com",
      reason: "support grant",
    },
    lastVerifiedAt: null,
  });

  assert.equal(response.proActive, true);
  assert.equal(response.entitlementSource, "server_grant");
  assert.equal(response.subscriptionStatus, "none");
  assert.equal(response.subscriptionId, null);
  assert.equal(response.mode, "live");
});

test("retains a server grant while exposing a matching-mode checkout failure", () => {
  const response = subscriptionStateResponse({
    ...identity,
    data: providerState({
      proActive: false,
      subscriptionStatus: "checkout_failed",
      subscriptionId: null,
      cancelAtPeriodEnd: false,
    }),
    expectedMode: "test",
    grant: {
      active: true,
      kind: "lifetime_pro",
      expiresAt: null,
      grantedAt: "2026-09-01T00:00:00.000Z",
      grantedBy: "owner@example.com",
      reason: "support grant",
    },
  });

  assert.equal(response.proActive, true);
  assert.equal(response.entitlementSource, "server_grant");
  assert.equal(response.subscriptionStatus, "checkout_failed");
  assert.equal(response.subscriptionId, null);
  assert.equal(response.mode, "test");
});

test("projects missing or invalid stored mode as unavailable", () => {
  for (const mode of [undefined, null, "sandbox"]) {
    const response = subscriptionStateResponse({
      ...identity,
      data: providerState({mode}),
      expectedMode: "live",
    });
    assert.equal(response.proActive, false);
    assert.equal(response.entitlementSource, "none");
    assert.equal(response.subscriptionStatus, "unavailable");
    assert.equal(response.subscriptionId, null);
    assert.equal(response.mode, "live");
  }
});

test("projects unknown and contradictory current payment states as unavailable", () => {
  for (const data of [
    providerState({subscriptionStatus: "future_status"}),
    providerState({proActive: false}),
    providerState({currentCheckoutSessionId: "other-subscription"}),
    providerState({planId: "other-plan"}),
    providerState({subscriptionId: "invalid/subscription"}),
    providerState({cancelAtPeriodEnd: false}),
  ]) {
    const response = subscriptionStateResponse({
      ...identity,
      data,
      expectedMode: "test",
    });
    assert.equal(response.proActive, false);
    assert.equal(response.entitlementSource, "none");
    assert.equal(response.subscriptionStatus, "unavailable");
    assert.equal(response.subscriptionId, null);
    assert.equal(response.mode, "test");
  }
});

test("does not neutralize malformed opposite-mode provider state as free", () => {
  for (const data of [
    providerState({mode: "test", subscriptionStatus: "future_status"}),
    providerState({mode: "test", planId: "other-plan"}),
  ]) {
    const response = subscriptionStateResponse({
      ...identity,
      data,
      expectedMode: "live",
    });
    assert.equal(response.proActive, false);
    assert.equal(response.subscriptionStatus, "unavailable");
  }
});

test("treats an absent provider footprint as explicit current-mode free", () => {
  const response = subscriptionStateResponse({
    ...identity,
    data: {email: identity.email, emailVerified: true},
    expectedMode: "live",
  });

  assert.equal(response.proActive, false);
  assert.equal(response.entitlementSource, "none");
  assert.equal(response.subscriptionStatus, "none");
  assert.equal(response.subscriptionId, null);
  assert.equal(response.planId, "plan-pro");
  assert.equal(response.mode, "live");
});

test("invalid server grant cannot collapse to checkout-eligible free", () => {
  const response = subscriptionStateResponse({
    ...identity,
    data: {},
    expectedMode: "live",
    grant: {
      active: "true",
      kind: "lifetime_pro",
      expiresAt: null,
      grantedAt: "2026-09-01T00:00:00.000Z",
      grantedBy: "owner@example.com",
      reason: "support grant",
    },
  });

  assert.equal(response.proActive, false);
  assert.equal(response.entitlementSource, "none");
  assert.equal(response.subscriptionStatus, "unavailable");
});

test("a server grant survives malformed provider lifecycle without enabling payment actions", () => {
  const response = subscriptionStateResponse({
    ...identity,
    data: providerState({subscriptionStatus: "future_status"}),
    expectedMode: "test",
    grant: {
      active: true,
      kind: "lifetime_pro",
      expiresAt: null,
      grantedAt: "2026-09-01T00:00:00.000Z",
      grantedBy: "owner@example.com",
      reason: "support grant",
    },
  });

  assert.equal(response.proActive, true);
  assert.equal(response.entitlementSource, "server_grant");
  assert.equal(response.subscriptionStatus, "unavailable");
  assert.equal(response.subscriptionId, null);
});

test("subscription response ignores a caller-supplied entitlement override", () => {
  const response = subscriptionStateResponse({
    ...identity,
    data: {},
    expectedMode: "live",
    entitlement: {
      proActive: true,
      entitlementSource: "portaly",
      portalyProActive: true,
      grantStateValid: true,
      grant: null,
    },
  });

  assert.equal(response.proActive, false);
  assert.equal(response.entitlementSource, "none");
  assert.equal(response.subscriptionStatus, "none");
});

test("portal access requires a coherent manageable Portaly lifecycle", () => {
  for (const subscriptionStatus of ["active", "past_due", "cancel_requested"]) {
    assert.deepEqual(portalAccessDecision({
      data: providerState({
        subscriptionStatus,
        cancelAtPeriodEnd: subscriptionStatus === "cancel_requested",
      }),
      expectedMode: "test",
      expectedPlanId: "plan-pro",
    }), {kind: "allow", subscriptionId: "sub-test"});
  }

  for (const data of [
    {},
    providerState({subscriptionStatus: "checkout_ready", proActive: false,
      cancelAtPeriodEnd: false}),
    providerState({subscriptionStatus: "canceled", proActive: false,
      cancelAtPeriodEnd: false}),
    providerState({planId: "other-plan"}),
  ]) {
    assert.deepEqual(portalAccessDecision({
      data,
      expectedMode: "test",
      expectedPlanId: "plan-pro",
    }), {kind: "unavailable"});
  }
});

test("calculateExpiringStage returns 'none' when not proActive", () => {
  const now = Date.now();
  const nextBillingAtMs = now + 12 * 60 * 60 * 1000; // 12 hours from now
  const nextBillingAt = new Date(nextBillingAtMs).toISOString();

  assert.equal(
    calculateExpiringStage({
      proActive: false,
      subscriptionStatus: "active",
      nextBillingAt,
      now,
    }),
    "none",
  );
});

test("calculateExpiringStage returns 'none' when subscriptionStatus not eligible", () => {
  const now = Date.now();
  const nextBillingAtMs = now + 12 * 60 * 60 * 1000;
  const nextBillingAt = new Date(nextBillingAtMs).toISOString();

  for (const status of ["none", "checkout_failed", "canceled", "pending"]) {
    assert.equal(
      calculateExpiringStage({
        proActive: true,
        subscriptionStatus: status,
        nextBillingAt,
        now,
      }),
      "none",
    );
  }
});

test("calculateExpiringStage returns 'none' when nextBillingAt is missing or invalid", () => {
  const now = Date.now();

  for (const nextBillingAt of [null, undefined, "", "invalid-date"]) {
    assert.equal(
      calculateExpiringStage({
        proActive: true,
        subscriptionStatus: "active",
        nextBillingAt,
        now,
      }),
      "none",
    );
  }
});

test("calculateExpiringStage returns 'expired' when nextBillingAt is in the past", () => {
  const now = Date.now();
  const nextBillingAtMs = now - 1000; // 1 second ago
  const nextBillingAt = new Date(nextBillingAtMs).toISOString();

  assert.equal(
    calculateExpiringStage({
      proActive: true,
      subscriptionStatus: "active",
      nextBillingAt,
      now,
    }),
    "expired",
  );
});

test("calculateExpiringStage returns 'today' when 0-24 hours until renewal", () => {
  const now = Date.now();

  // Test various times within 0-24 hour window
  for (const hoursUntil of [0.5, 1, 12, 23]) {
    const nextBillingAtMs = now + hoursUntil * 60 * 60 * 1000;
    const nextBillingAt = new Date(nextBillingAtMs).toISOString();

    assert.equal(
      calculateExpiringStage({
        proActive: true,
        subscriptionStatus: "active",
        nextBillingAt,
        now,
      }),
      "today",
    );
  }
});

test("calculateExpiringStage returns 'soon' when 24-48 hours until renewal", () => {
  const now = Date.now();

  // Test various times within 24-48 hour window
  for (const hoursUntil of [24, 30, 47.9]) {
    const nextBillingAtMs = now + hoursUntil * 60 * 60 * 1000;
    const nextBillingAt = new Date(nextBillingAtMs).toISOString();

    assert.equal(
      calculateExpiringStage({
        proActive: true,
        subscriptionStatus: "active",
        nextBillingAt,
        now,
      }),
      "soon",
    );
  }
});

test("calculateExpiringStage returns 'far' when 48-72 hours until renewal", () => {
  const now = Date.now();

  // Test various times within 48-72 hour window (2-3 day window)
  for (const hoursUntil of [48, 60, 71.9]) {
    const nextBillingAtMs = now + hoursUntil * 60 * 60 * 1000;
    const nextBillingAt = new Date(nextBillingAtMs).toISOString();

    assert.equal(
      calculateExpiringStage({
        proActive: true,
        subscriptionStatus: "active",
        nextBillingAt,
        now,
      }),
      "far",
    );
  }
});

test("calculateExpiringStage returns 'none' when more than 72 hours until renewal", () => {
  const now = Date.now();

  // Test various times beyond 72 hour window (> 3 days)
  for (const hoursUntil of [73, 100, 365 * 24]) {
    const nextBillingAtMs = now + hoursUntil * 60 * 60 * 1000;
    const nextBillingAt = new Date(nextBillingAtMs).toISOString();

    assert.equal(
      calculateExpiringStage({
        proActive: true,
        subscriptionStatus: "active",
        nextBillingAt,
        now,
      }),
      "none",
    );
  }
});

test("calculateExpiringStage works for all eligible subscription statuses", () => {
  const now = Date.now();
  const nextBillingAtMs = now + 12 * 60 * 60 * 1000; // 12 hours
  const nextBillingAt = new Date(nextBillingAtMs).toISOString();

  for (const status of ["active", "past_due", "cancel_requested"]) {
    const stage = calculateExpiringStage({
      proActive: true,
      subscriptionStatus: status,
      nextBillingAt,
      now,
    });
    assert.equal(stage, "today", `Expected 'today' for status '${status}'`);
  }
});

test("subscription response with expiring_today stage", () => {
  const now = Date.parse("2026-09-08T20:00:00.000Z");
  const nextBillingAt = "2026-09-09T18:00:00.000Z"; // 22 hours from now
  const nextBillingAtMs = Date.parse(nextBillingAt);

  const data = providerState({
    subscriptionStatus: "active",
    cancelAtPeriodEnd: false,
    nextBillingAt,
  });

  const response = subscriptionStateResponse({
    ...identity,
    data,
    expectedMode: "test",
    now,
  });

  // Debug: check intermediate values
  assert.equal(response.proActive, true, "proActive should be true");
  assert.equal(response.subscriptionStatus, "active", "subscriptionStatus should be active");
  assert.equal(response.nextBillingAt, nextBillingAt, "nextBillingAt should match");
  
  assert.equal(response.expiringStage, "today");
  assert.equal(response.nextBillingAtMs, nextBillingAtMs);
  assert(Math.abs(response.daysUntilRenewal - (22 / 24)) < 0.01,
    `Expected ~0.917 days, got ${response.daysUntilRenewal}`);
});

test("subscription response with expiring_soon stage", () => {
  const now = Date.parse("2026-09-08T20:00:00.000Z");
  const nextBillingAt = "2026-09-10T12:00:00.000Z"; // 40 hours from now (1.667 days)
  const nextBillingAtMs = Date.parse(nextBillingAt);

  const response = subscriptionStateResponse({
    ...identity,
    data: providerState({
      subscriptionStatus: "past_due",
      cancelAtPeriodEnd: false,
      nextBillingAt,
    }),
    expectedMode: "test",
    now,
  });

  assert.equal(response.expiringStage, "soon");
  assert.equal(response.nextBillingAtMs, nextBillingAtMs);
  assert(Math.abs(response.daysUntilRenewal - (40 / 24)) < 0.01);
});

test("subscription response with expiring_far stage", () => {
  const now = Date.parse("2026-09-08T20:00:00.000Z");
  const nextBillingAt = "2026-09-11T18:00:00.000Z"; // 70 hours from now (2.917 days)
  const nextBillingAtMs = Date.parse(nextBillingAt);

  const response = subscriptionStateResponse({
    ...identity,
    data: providerState({
      subscriptionStatus: "cancel_requested",
      nextBillingAt,
    }),
    expectedMode: "test",
    now,
  });

  assert.equal(response.expiringStage, "far");
  assert.equal(response.nextBillingAtMs, nextBillingAtMs);
  assert(Math.abs(response.daysUntilRenewal - (70 / 24)) < 0.01);
});

test("subscription response with expired stage", () => {
  const now = Date.parse("2026-09-08T20:00:00.000Z");
  const nextBillingAt = "2026-09-08T18:00:00.000Z"; // 2 hours in the past
  const nextBillingAtMs = Date.parse(nextBillingAt);

  const response = subscriptionStateResponse({
    ...identity,
    data: providerState({
      subscriptionStatus: "active",
      cancelAtPeriodEnd: false,
      nextBillingAt,
    }),
    expectedMode: "test",
    now,
  });

  assert.equal(response.expiringStage, "expired");
  assert.equal(response.nextBillingAtMs, nextBillingAtMs);
  assert(response.daysUntilRenewal < 0);
});

test("subscription response has null expiring fields when not proActive", () => {
  const now = Date.parse("2026-09-08T20:00:00.000Z");
  const nextBillingAt = "2026-09-09T18:00:00.000Z";

  const response = subscriptionStateResponse({
    ...identity,
    data: providerState({
      proActive: false,
      subscriptionStatus: "none",
      nextBillingAt,
    }),
    expectedMode: "test",
    now,
  });

  assert.equal(response.proActive, false);
  assert.equal(response.expiringStage, "none");
  assert.equal(response.nextBillingAtMs, null);
  assert.equal(response.daysUntilRenewal, null);
});

// Tests for calculateNextBillingFromAnchor
test("calculateNextBillingFromAnchor returns null for invalid inputs", () => {
  const validAnchor = "2026-08-08T00:00:00.000Z";

  // Missing billingCycleAnchor
  assert.equal(calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: 1,
    billingCycleAnchor: null,
  }), null);

  // Invalid billingCycleAnchor format
  assert.equal(calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: 1,
    billingCycleAnchor: "invalid-date",
  }), null);

  // Invalid billingIntervalUnit
  assert.equal(calculateNextBillingFromAnchor({
    billingIntervalUnit: "week",
    billingIntervalCount: 1,
    billingCycleAnchor: validAnchor,
  }), null);

  // Invalid billingIntervalCount
  assert.equal(calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: 0,
    billingCycleAnchor: validAnchor,
  }), null);

  assert.equal(calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: -1,
    billingCycleAnchor: validAnchor,
  }), null);
});

test("calculateNextBillingFromAnchor calculates monthly billing correctly", () => {
  const now = Date.parse("2026-09-08T10:00:00.000Z");
  const anchor = "2026-08-08T00:00:00.000Z"; // 1 month before current date

  const nextBilling = calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: 1,
    billingCycleAnchor: anchor,
    cancelAtPeriodEnd: false,
    now,
  });

  // Should be next month's billing date: 2026-10-08
  const result = new Date(nextBilling);
  assert.equal(result.getFullYear(), 2026);
  assert.equal(result.getMonth(), 9); // October (0-indexed)
  assert.equal(result.getDate(), 8);
});

test("calculateNextBillingFromAnchor respects cancelAtPeriodEnd flag", () => {
  const now = Date.parse("2026-09-08T10:00:00.000Z");
  const anchor = "2026-08-08T00:00:00.000Z"; // 1 month before current date

  // When cancelAtPeriodEnd=true, should be current period end (2026-09-08)
  const withCancel = calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: 1,
    billingCycleAnchor: anchor,
    cancelAtPeriodEnd: true,
    now,
  });

  // When cancelAtPeriodEnd=false, should be next period (2026-10-08)
  const withoutCancel = calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: 1,
    billingCycleAnchor: anchor,
    cancelAtPeriodEnd: false,
    now,
  });

  const cancelDate = new Date(withCancel);
  const nextDate = new Date(withoutCancel);

  // Verify the difference
  assert.equal(cancelDate.getMonth(), 8); // September
  assert.equal(nextDate.getMonth(), 9); // October
});

test("calculateNextBillingFromAnchor calculates yearly billing correctly", () => {
  const now = Date.parse("2026-09-08T10:00:00.000Z");
  const anchor = "2025-09-08T00:00:00.000Z"; // 1 year before current date

  const nextBilling = calculateNextBillingFromAnchor({
    billingIntervalUnit: "year",
    billingIntervalCount: 1,
    billingCycleAnchor: anchor,
    cancelAtPeriodEnd: false,
    now,
  });

  // Should be next year's billing date: 2027-09-08
  const result = new Date(nextBilling);
  assert.equal(result.getFullYear(), 2027);
  assert.equal(result.getMonth(), 8); // September
  assert.equal(result.getDate(), 8);
});

test("calculateNextBillingFromAnchor handles multi-interval subscriptions", () => {
  const now = Date.parse("2026-09-08T10:00:00.000Z");
  const anchor = "2026-05-08T00:00:00.000Z"; // 4 months before current date

  // 12-month billing interval
  const nextBilling = calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: 12,
    billingCycleAnchor: anchor,
    cancelAtPeriodEnd: false,
    now,
  });

  // Should be next 12-month cycle
  const result = new Date(nextBilling);
  assert.equal(result.getFullYear(), 2027);
  assert.equal(result.getMonth(), 4); // May (0-indexed)
  assert.equal(result.getDate(), 8);
});

test("calculateNextBillingFromAnchor preserves time when anchor is in the future", () => {
  // Edge case: anchor is after current time (before first billing)
  const now = Date.parse("2026-08-08T10:00:00.000Z");
  const anchor = "2026-09-08T15:30:00.000Z"; // 1 month in the future

  const nextBilling = calculateNextBillingFromAnchor({
    billingIntervalUnit: "month",
    billingIntervalCount: 1,
    billingCycleAnchor: anchor,
    cancelAtPeriodEnd: false,
    now,
  });

  // Should return the anchor itself (first billing cycle)
  const result = new Date(nextBilling);
  assert.equal(result.toISOString(), anchor);
});

