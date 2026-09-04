/**
 * Server-owned entitlement grants are intentionally kept separate from the
 * provider-owned subscription state.  This module has no Firebase or network
 * dependencies so every caller (API, admin tooling, and tests) uses the same
 * fail-closed decision.
 */

import {isPortalyMode} from "./portaly-mode.mjs";

const GRANT_KINDS = new Set([
  "lifetime_pro",
  "owner_pro",
  "temporary_pro",
  "promotional_pro",
]);

const PORTALY_ACTIVE_STATUSES = new Set([
  "active",
  "past_due",
  "cancel_requested",
]);
export const ENTITLEMENT_SOURCES = Object.freeze({
  NONE: "none",
  PORTALY: "portaly",
  SERVER_GRANT: "server_grant",
  PORTALY_AND_SERVER_GRANT: "portaly_and_server_grant",
});

export const ENTITLEMENT_GRANT_CHECKOUT_CODE = "SERVER_GRANT_ACTIVE";

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function timestampMs(value) {
  if (value instanceof Date) {
    return Number.isFinite(value.getTime()) ? value.getTime() : Number.NaN;
  }
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : Number.NaN;
  }
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : Number.NaN;
  }
  if (typeof value?.toDate === "function") {
    try {
      const date = value.toDate();
      return date instanceof Date && Number.isFinite(date.getTime()) ?
        date.getTime() : Number.NaN;
    } catch {
      return Number.NaN;
    }
  }
  return Number.NaN;
}

function isoTimestamp(value) {
  const ms = timestampMs(value);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

function invalid(code, message) {
  return {valid: false, active: false, grant: null, code, message};
}

/**
 * Validate and normalize one entitlement grant document.
 *
 * A missing document is a valid "no grant" state.  A present malformed
 * document is invalid and never grants access.  Only the minimum normalized
 * metadata is returned to API clients; actor and reason remain server-side.
 */
export function validateEntitlementGrant(grant, {now = Date.now()} = {}) {
  if (grant === undefined || grant === null) {
    return {valid: true, active: false, grant: null, code: null, message: null};
  }
  if (!isRecord(grant)) {
    return invalid("ENTITLEMENT_GRANT_INVALID", "Entitlement grant must be an object");
  }
  if (typeof grant.active !== "boolean") {
    return invalid("ENTITLEMENT_GRANT_ACTIVE_INVALID", "Entitlement grant active must be a boolean");
  }

  const kind = nonBlankString(grant.kind);
  if (!kind || !GRANT_KINDS.has(kind)) {
    return invalid("ENTITLEMENT_GRANT_KIND_INVALID", "Entitlement grant kind is unsupported");
  }

  if (grant.expiresAt === undefined) {
    return invalid("ENTITLEMENT_GRANT_EXPIRY_MISSING", "Entitlement grant expiresAt is required");
  }
  const expiresAt = grant.expiresAt === null ? null : isoTimestamp(grant.expiresAt);
  if (grant.expiresAt !== null && !expiresAt) {
    return invalid("ENTITLEMENT_GRANT_EXPIRY_INVALID", "Entitlement grant expiresAt is invalid");
  }

  if (grant.grantedAt === undefined) {
    return invalid("ENTITLEMENT_GRANT_GRANTED_AT_MISSING", "Entitlement grant grantedAt is required");
  }
  const grantedAt = isoTimestamp(grant.grantedAt);
  if (!grantedAt) {
    return invalid("ENTITLEMENT_GRANT_GRANTED_AT_INVALID", "Entitlement grant grantedAt is invalid");
  }

  const nowMs = timestampMs(now);
  if (!Number.isFinite(nowMs)) {
    return invalid("ENTITLEMENT_GRANT_NOW_INVALID", "Entitlement grant evaluation time is invalid");
  }
  const grantedAtMs = Date.parse(grantedAt);
  if (grantedAtMs > nowMs) {
    return invalid("ENTITLEMENT_GRANT_GRANTED_AT_FUTURE", "Entitlement grant grantedAt cannot be in the future");
  }
  const expiresAtMs = expiresAt === null ? null : Date.parse(expiresAt);
  if (expiresAtMs !== null && expiresAtMs <= grantedAtMs) {
    return invalid("ENTITLEMENT_GRANT_PERIOD_INVALID", "Entitlement grant expiration must follow grantedAt");
  }

  const grantedBy = nonBlankString(grant.grantedBy);
  if (!grantedBy) {
    return invalid("ENTITLEMENT_GRANT_GRANTED_BY_INVALID", "Entitlement grant grantedBy is required");
  }
  const reason = nonBlankString(grant.reason);
  if (!reason) {
    return invalid("ENTITLEMENT_GRANT_REASON_INVALID", "Entitlement grant reason is required");
  }

  const hasRevokedAt = grant.revokedAt !== undefined && grant.revokedAt !== null;
  const revokedAt = hasRevokedAt ? isoTimestamp(grant.revokedAt) : null;
  if (hasRevokedAt && !revokedAt) {
    return invalid("ENTITLEMENT_GRANT_REVOKED_AT_INVALID", "Entitlement grant revokedAt is invalid");
  }
  if (grant.revokedAt !== undefined && grant.revokedAt !== null && !nonBlankString(grant.revokedBy)) {
    return invalid("ENTITLEMENT_GRANT_REVOKED_BY_INVALID", "Entitlement grant revokedBy is required");
  }
  if (grant.revokedBy !== undefined && grant.revokedBy !== null && !nonBlankString(grant.revokedBy)) {
    return invalid("ENTITLEMENT_GRANT_REVOKED_BY_INVALID", "Entitlement grant revokedBy is invalid");
  }
  if (grant.revokedBy !== undefined && grant.revokedBy !== null && !hasRevokedAt) {
    return invalid("ENTITLEMENT_GRANT_REVOKED_AT_MISSING", "Entitlement grant revokedAt is required with revokedBy");
  }
  if (hasRevokedAt && Date.parse(revokedAt) < grantedAtMs) {
    return invalid("ENTITLEMENT_GRANT_REVOCATION_INVALID", "Entitlement grant revocation cannot precede grantedAt");
  }
  if (grant.active && hasRevokedAt) {
    return invalid("ENTITLEMENT_GRANT_REVOKED_ACTIVE", "A revoked entitlement grant cannot be active");
  }

  const active = grant.active && !hasRevokedAt &&
    (expiresAtMs === null || expiresAtMs > nowMs);

  return {
    valid: true,
    active,
    grant: {
      kind,
      expiresAt,
      grantedAt,
    },
    code: null,
    message: null,
  };
}

function portalyIsActive(portalyState, expectedMode, expectedPlanId) {
  if (!isRecord(portalyState) || portalyState.proActive !== true) return false;
  // Provider-owned access is environment-bound. Omitting either side, using
  // an unknown value, or crossing test/live must fail closed. Server grants
  // are evaluated separately and therefore remain mode-independent.
    if (!isPortalyMode(expectedMode) ||
      !isPortalyMode(portalyState.mode) ||
      portalyState.mode !== expectedMode) {
    return false;
  }
  if (expectedPlanId !== undefined &&
      (!nonBlankString(expectedPlanId) || portalyState.planId !== expectedPlanId)) {
    return false;
  }
  // Missing or unknown provider state is not sufficient evidence of an
  // active paid entitlement. Only explicitly supported lifecycle states pass.
  return PORTALY_ACTIVE_STATUSES.has(portalyState.subscriptionStatus);
}

/**
 * Resolve the effective entitlement from independently owned sources.
 * Invalid grants intentionally collapse to no grant instead of throwing or
 * allowing a malformed server document to unlock Pro.
 */
export function resolveEntitlement({
  grant,
  portalyState,
  expectedMode,
  expectedPlanId,
  now = Date.now(),
} = {}) {
  const validated = validateEntitlementGrant(grant, {now});
  const hasServerGrant = validated.valid && validated.active;
  const hasPortalyEntitlement = portalyIsActive(
    portalyState,
    expectedMode,
    expectedPlanId,
  );
  const entitlementSource = hasServerGrant && hasPortalyEntitlement ?
    ENTITLEMENT_SOURCES.PORTALY_AND_SERVER_GRANT :
    hasServerGrant ? ENTITLEMENT_SOURCES.SERVER_GRANT :
    hasPortalyEntitlement ? ENTITLEMENT_SOURCES.PORTALY :
    ENTITLEMENT_SOURCES.NONE;

  return {
    proActive: hasServerGrant || hasPortalyEntitlement,
    entitlementSource,
    grant: hasServerGrant ? validated.grant : null,
    portalyProActive: hasPortalyEntitlement,
    grantStateValid: validated.valid,
  };
}

export function grantKinds() {
  return [...GRANT_KINDS];
}
