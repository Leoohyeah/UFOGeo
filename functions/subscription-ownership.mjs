import {createHash} from "node:crypto";

const PORTALY_MODES = new Set(["live", "test"]);
const OWNERSHIP_STATUSES = new Set([
  "active",
  "past_due",
  "cancel_requested",
  "canceled",
  "checkout_failed",
]);

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeEmail(value) {
  return nonBlankString(value)?.toLowerCase().normalize("NFC") || null;
}

function conflict(code) {
  return {kind: "conflict", code};
}

/**
 * Fence deleted-account cancellation against a concurrent subscription
 * reclaim.  The caller must evaluate this from the same Firestore
 * transaction that claims the compensation marker (or writes the recovered
 * session).  A missing or contradictory tombstone is never treated as proof
 * that a cancellation is safe.
 */
export function deletedAccountCompensationOwnershipDecision({
  marker = null,
  session = null,
} = {}) {
  if (!isRecord(marker) || !isRecord(session)) {
    return {kind: "uncertain", code: "SUBSCRIPTION_RECOVERY_SAFETY_HOLD"};
  }
  const markerSubscriptionId = nonBlankString(marker.subscriptionId);
  const sessionSubscriptionId = nonBlankString(session.subscriptionId) ||
    nonBlankString(session.sessionId);
  const markerDeletionId = nonBlankString(marker.accountDeletionId);
  const sessionDeletionId = nonBlankString(session.accountDeletionId);
  const markerPlanId = nonBlankString(marker.planId);
  const sessionPlanId = nonBlankString(session.planId);
  const markerMode = nonBlankString(marker.mode);
  const sessionMode = nonBlankString(session.mode);
  if (!markerSubscriptionId || !sessionSubscriptionId ||
      markerSubscriptionId !== sessionSubscriptionId ||
      !markerDeletionId || !sessionDeletionId ||
      markerDeletionId !== sessionDeletionId ||
      !markerPlanId || !sessionPlanId || markerPlanId !== sessionPlanId ||
      !markerMode || !sessionMode || markerMode !== sessionMode) {
    return {kind: "uncertain", code: "SUBSCRIPTION_RECOVERY_SAFETY_HOLD"};
  }

  const sessionUid = nonBlankString(session.uid);
  if (session.accountDeleted === true && !sessionUid) {
    return {kind: "deleted_owner"};
  }
  // A session with a current UID is no longer owned by the deleted account;
  // the compensation marker must become obsolete without a provider POST.
  if (session.accountDeleted !== true && sessionUid) {
    return {kind: "reclaimed", uid: sessionUid};
  }
  return {kind: "uncertain", code: "SUBSCRIPTION_RECOVERY_SAFETY_HOLD"};
}

/**
 * A recovery transaction must not rebind a provider subscription while a
 * normal deleted-account cancellation marker is still pending.  Refund
 * reconciliation markers are handled by their own ownership plan and are
 * intentionally ignored here.
 */
export function normalCompensationRecoveryDecision(entries = []) {
  if (!Array.isArray(entries)) return conflict("SUBSCRIPTION_RECOVERY_SAFETY_HOLD");
  for (const entry of entries) {
    const record = isRecord(entry?.data) ? entry.data : entry;
    if (!isRecord(record)) return conflict("SUBSCRIPTION_RECOVERY_SAFETY_HOLD");
    if (record.kind === "refund_reconciliation") continue;
    if (record.status !== "completed") {
      return conflict("SUBSCRIPTION_RECOVERY_SAFETY_HOLD");
    }
  }
  return {kind: "allow"};
}

/**
 * Adapt a users query document without trusting a copied historical uid field.
 * Firestore's document id is the only authoritative owner identity.
 */
export function subscriptionOwnerQueryEntry({id, data, matchedField} = {}) {
  return {
    data: {...(isRecord(data) ? data : {}), uid: id},
    matchedField,
  };
}

/**
 * Check every user document returned by a candidate subscription ownership
 * query.  The caller must run this decision inside the same Firestore
 * transaction that creates the recovered session/user binding.  The query is
 * deliberately targeted by provider subscription identity; no collection
 * scan or email-only ownership lookup is used.
 *
 * Entries may be raw user data or `{data, matchedField}` wrappers. The latter
 * lets the caller combine the subscriptionId and currentCheckoutSessionId
 * single-field queries without losing which identity matched.
 */
export function subscriptionOwnerDecision(
  entries = [],
  {uid, email, planId, mode, subscriptionId} = {},
) {
  const expectedUid = nonBlankString(uid);
  const expectedEmail = normalizeEmail(email);
  const expectedPlanId = nonBlankString(planId);
  const expectedSubscriptionId = nonBlankString(subscriptionId);
  if (!Array.isArray(entries) || !expectedUid || !expectedEmail || !expectedPlanId ||
      !PORTALY_MODES.has(mode) || !expectedSubscriptionId) {
    return conflict("RECOVERY_OWNER_CONTEXT_INVALID");
  }

  const owners = new Map();
  for (const entry of entries) {
    const record = isRecord(entry?.data) ? entry.data : entry;
    if (!isRecord(record)) return conflict("RECOVERY_OWNER_STATE_INVALID");
    const ownerUid = nonBlankString(record.uid);
    const ownerEmail = normalizeEmail(record.email);
    const ownerPlanId = nonBlankString(record.planId);
    const ownerMode = nonBlankString(record.mode);
    const ownerStatus = nonBlankString(record.subscriptionStatus);
    const matchedField = nonBlankString(entry?.matchedField) || "subscriptionId";
    const matchedValue = nonBlankString(record[matchedField]);
    if (!ownerUid || !ownerEmail || !ownerPlanId || !PORTALY_MODES.has(ownerMode) ||
        !ownerStatus || !OWNERSHIP_STATUSES.has(ownerStatus) ||
        (matchedField !== "subscriptionId" && matchedField !== "currentCheckoutSessionId") ||
        matchedValue !== expectedSubscriptionId) {
      return conflict("RECOVERY_OWNER_STATE_INVALID");
    }
    if (ownerEmail !== expectedEmail || ownerPlanId !== expectedPlanId || ownerMode !== mode) {
      return conflict("RECOVERY_OWNER_SCOPE_CONFLICT");
    }
    if (record.accountDeleted === true || record.accountDeleting === true) {
      return conflict("RECOVERY_OWNER_STATE_CONFLICT");
    }
    const existing = owners.get(ownerUid);
    if (!existing) {
      owners.set(ownerUid, {uid: ownerUid, status: ownerStatus});
    } else if (existing.status !== ownerStatus) {
      // Two copies of one UID disagree about lifecycle state. Do not let a
      // recovery transaction choose one arbitrarily.
      return conflict("RECOVERY_OWNER_STATE_CONFLICT");
    }
  }

  if (owners.size === 0) return {kind: "claim"};
  if (owners.size === 1 && owners.has(expectedUid)) {
    return {kind: "already_bound", uid: expectedUid};
  }
  return conflict("RECOVERY_EXISTING_BINDING_CONFLICT");
}

/**
 * Keep a refund marker attached to the same provider identity while recovery
 * migrates a deleted session. Only an old UID proven by the deleted-session
 * path, or an ownerless marker on that tombstone, may be rebound.
 */
export function refundMarkerOwnershipDecision({
  marker = null,
  currentUid,
  currentEmail,
  planId,
  mode,
  subscriptionId,
  deletedAccountUidHash = null,
  allowDeletedOwnership = false,
} = {}) {
  if (!isRecord(marker) || !nonBlankString(currentUid) ||
      !normalizeEmail(currentEmail) || !nonBlankString(planId) ||
      !PORTALY_MODES.has(mode) || !nonBlankString(subscriptionId)) {
    return conflict("RECOVERY_REFUND_MARKER_INVALID");
  }
  const markerSubscriptionId = nonBlankString(marker.subscriptionId);
  const markerSessionId = nonBlankString(marker.sessionId);
  const markerPlanId = nonBlankString(marker.planId);
  const markerMode = nonBlankString(marker.mode);
  const markerEmail = normalizeEmail(marker.customerEmail);
  const markerUid = nonBlankString(marker.uid);
  if (!markerSubscriptionId || markerSubscriptionId !== subscriptionId ||
      !markerSessionId || markerSessionId !== subscriptionId ||
      markerPlanId !== planId || markerMode !== mode ||
      markerEmail !== normalizeEmail(currentEmail)) {
    return conflict("RECOVERY_REFUND_MARKER_SCOPE_CONFLICT");
  }
  if (marker.status === "completed") return {kind: "completed"};
  if (markerUid && markerUid !== currentUid && !allowDeletedOwnership) {
    return conflict("RECOVERY_REFUND_MARKER_OWNERSHIP_CONFLICT");
  }
  if (markerUid && markerUid !== currentUid && allowDeletedOwnership) {
    const expectedHash = nonBlankString(deletedAccountUidHash);
    const markerUidHash = createHash("sha256").update(markerUid).digest("hex");
    if (!expectedHash || markerUidHash !== expectedHash) {
      return conflict("RECOVERY_REFUND_MARKER_OWNERSHIP_CONFLICT");
    }
  }
  if (!markerUid && !allowDeletedOwnership) {
    return conflict("RECOVERY_REFUND_MARKER_OWNERSHIP_CONFLICT");
  }
  return {kind: "rebind", uid: currentUid, email: currentEmail};
}

/**
 * Evaluate all ownership records that finalizeSubscriptionRecovery reads in
 * one Firestore transaction.  The caller applies the returned marker
 * decisions only after this whole plan is allowed, so a race or stale owner
 * cannot leave a partially migrated refund marker behind.
 */
export function subscriptionRecoveryOwnershipPlan({
  ownerEntries = [],
  refundMarkerEntries = [],
  compensationEntries = [],
  uid,
  email,
  planId,
  mode,
  subscriptionId,
  deletedAccountUidHash = null,
  allowDeletedOwnership = false,
} = {}) {
  const compensationDecision = normalCompensationRecoveryDecision(compensationEntries);
  if (compensationDecision.kind === "conflict") return compensationDecision;
  const ownerDecision = subscriptionOwnerDecision(ownerEntries, {
    uid,
    email,
    planId,
    mode,
    subscriptionId,
  });
  if (ownerDecision.kind === "conflict") return ownerDecision;
  if (!Array.isArray(refundMarkerEntries)) {
    return conflict("RECOVERY_REFUND_MARKER_INVALID");
  }

  const markerDecisions = [];
  for (const entry of refundMarkerEntries) {
    const marker = isRecord(entry?.data) ? entry.data : entry;
    const decision = refundMarkerOwnershipDecision({
      marker,
      currentUid: uid,
      currentEmail: email,
      planId,
      mode,
      subscriptionId,
      deletedAccountUidHash,
      allowDeletedOwnership,
    });
    if (decision.kind === "conflict") return decision;
    markerDecisions.push(decision);
  }
  return {
    kind: "allow",
    ownerDecision,
    markerDecisions,
  };
}

/**
 * Run the ownership plan inside the caller's Firestore transaction. The
 * injected writer is called only after every owner and marker has passed, so
 * a failed race cannot partially rebind refund markers.
 */
export function subscriptionRecoveryOwnershipTransaction({
  writeRefundMarker = null,
  ...options
} = {}) {
  const plan = subscriptionRecoveryOwnershipPlan(options);
  if (plan.kind === "conflict") return plan;
  const entries = Array.isArray(options.refundMarkerEntries) ?
    options.refundMarkerEntries : [];
  if (entries.length > 0 && typeof writeRefundMarker !== "function") {
    return conflict("RECOVERY_REFUND_MARKER_INVALID");
  }
  for (const [index, entry] of entries.entries()) {
    if (plan.markerDecisions[index].kind !== "completed") {
      writeRefundMarker(entry, plan.markerDecisions[index]);
    }
  }
  return plan;
}
