import {createHash, randomUUID} from "node:crypto";

import {initializeApp} from "firebase-admin/app";
import {getAuth} from "firebase-admin/auth";
import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {defineSecret} from "firebase-functions/params";
import {setGlobalOptions} from "firebase-functions/v2";
import {onDocumentWritten} from "firebase-functions/v2/firestore";
import {onRequest} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";

import {
  callbackStateTimestampMs,
  CallbackError,
  eventIdentity,
  subscriptionIdentifier,
  subscriptionStateForEvent,
  shouldApplyCallbackUpdate,
  validateCallbackPayload,
  verifyCallbackEnvelope,
} from "./portaly-callback.mjs";
import {
  callbackMatchesCheckoutSession,
  callbackModeMatchesDeployment,
  CHECKOUT_UNCERTAIN_HOLD_MS,
  classifyCheckoutCreationResult,
  checkoutEntitlementGrantDecision,
  checkoutLockMatchesSession,
  checkoutLockDocumentId,
  checkoutLeaseDecision,
  isReusableCheckoutSession,
  shouldApplyUserSubscriptionUpdate,
} from "./checkout-idempotency.mjs";
import {
  checkoutReconciliationOrchestrationResult,
  checkoutSessionReconciliationTarget,
  reconcileCheckoutSessionPath,
  subscriptionReconciliationLookupId,
  validateStoredCheckoutSession,
  verifiedCheckoutSessionState,
} from "./checkout-session-reconciliation.mjs";
import {
  accountDeletionTombstoneWrite,
  accountDeletionGuardDecision,
  completedAccountDeletionMatches,
  createPortalSessionReservation,
  deletedAccountCallbackNeedsCancellation,
  portalSessionGuardDecision,
  selectSubscriptionIdsToCancel,
  unverifiedDeletionNeedsEmailVerification,
  validatePortalSessionResponse,
  validateSubscriptionCancellationResponse,
} from "./account-deletion.mjs";
import {
  customerSubscriptionKey,
  findBlockingCustomerSubscriptionStrict,
  portalySubscriptions,
} from "./customer-subscription-guard.mjs";
import {
  reconcileSubscription as buildReconciliationPatches,
  SubscriptionReconciliationError,
  subscriptionStateMatchesPatch,
} from "./subscription-reconciliation.mjs";
import {
  ENTITLEMENT_GRANT_CHECKOUT_CODE,
  resolveEntitlement,
  validateEntitlementGrant,
} from "./entitlement-resolver.mjs";
import {
  requirePortalyMode,
  storedPortalyModeRelationship,
} from "./portaly-mode.mjs";
import {
  portalAccessDecision,
  subscriptionStateResponse as buildSubscriptionStateResponse,
} from "./subscription-response.mjs";
import {requireFirebaseUser as authenticateFirebaseUser} from "./firebase-auth.mjs";

initializeApp();

const db = getFirestore();
const auth = getAuth();
const PORTALY_API_KEY = defineSecret("PORTALY_API_KEY");
const PORTALY_CALLBACK_SECRET = defineSecret("PORTALY_CALLBACK_SECRET");

const PROJECT_ID = "ufogeo-adac7";
const PUBLIC_BASE_URL = `https://${PROJECT_ID}.web.app`;
const SUPPORT_EMAIL = "leoohyeah.app@gmail.com";
const PORTALY_PLAN_ID = "JO5cmDQdqTtb6AkkcnNW";
const PORTALY_SKILL_VERSION = "0.11.2";
const API_HOST = (process.env.PORTALY_API_HOST || "https://portaly.ai").replace(/\/$/, "");
const MAX_BODY_BYTES = 128 * 1024;
const CHECKOUT_LEASE_MS = 60 * 1000;
const DELETED_ACCOUNT_CANCELLATION_LEASE_MS = 60 * 1000;
let didReportSkillVersion = false;

setGlobalOptions({
  region: "asia-east1",
  maxInstances: 2,
  minInstances: 0,
  concurrency: 20,
  memory: "256MiB",
  timeoutSeconds: 30,
});

function json(response, status, body) {
  response.set("Cache-Control", "no-store");
  response.set("Content-Type", "application/json; charset=utf-8");
  return response.status(status).send(body);
}

function toEpochMs(value) {
  if (!value) return Number.NaN;
  if (typeof value === "number") return value;
  if (typeof value === "string") return Date.parse(value);
  if (typeof value.toDate === "function") return value.toDate().getTime();
  return Number.NaN;
}

export async function findReusableCheckoutSession(userId, now = Date.now(), mode) {
  const snapshot = await db.collection("checkoutSessions")
    .where("uid", "==", userId)
    .limit(100)
    .get();

  const reusableSessions = snapshot.docs
    .map((doc) => doc.data())
    .filter((session) => isReusableCheckoutSession(session, {
      planId: PORTALY_PLAN_ID,
      mode,
      now,
    }))
    .sort((left, right) => toEpochMs(right.updatedAt || right.createdAt) - toEpochMs(left.updatedAt || left.createdAt));

  return reusableSessions[0] || null;
}

function pathMatches(request, suffix) {
  const path = request.path.replace(/\/$/, "");
  return path === suffix || path.endsWith(suffix);
}

function requireJsonBody(request) {
  const contentLength = Number(request.get("content-length") || 0);
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    throw Object.assign(new Error("Request body is too large"), {statusCode: 413});
  }
  if (!request.body || typeof request.body !== "object" || Array.isArray(request.body)) {
    throw Object.assign(new Error("Request body must be a JSON object"), {statusCode: 400});
  }
  return request.body;
}

function requireFirebaseUser(request, options = {}) {
  return authenticateFirebaseUser(request, {auth, ...options});
}

async function portalyRequest(path, {apiKey, method = "GET", body} = {}) {
  const response = await fetch(`${API_HOST}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${apiKey}`,
      ...(body ? {"content-type": "application/json"} : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(15_000),
  });
  const payload = await response.json().catch(() => ({}));
  return {response, payload};
}

async function listCustomerSubscriptions({apiKey, customerEmail}) {
  const subscriptions = [];
  const seenCursors = new Set();
  let startAfter = null;

  // An ordinary customer has only a handful of subscriptions. The cap keeps
  // a corrupt or cyclic provider cursor from exhausting the function timeout;
  // reaching it fails closed instead of allowing another checkout or deleting
  // an account while renewals may still exist.
  for (let page = 0; page < 10; page += 1) {
    const query = new URLSearchParams({
      customerEmail,
      limit: "100",
    });
    if (startAfter) query.set("startAfter", startAfter);

    const {response, payload} = await portalyRequest(
      `/api/creator-subscription/subscriptions?${query.toString()}`,
      {apiKey},
    );
    if (!response.ok) {
      throw Object.assign(new Error("Portaly subscription list request failed"), {
        code: "PORTALY_SUBSCRIPTION_LIST_FAILED",
        portalyStatus: response.status,
        portalyCode: payload?.code || null,
      });
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload) ||
        !Array.isArray(payload.data) ||
        !payload.pagination || typeof payload.pagination !== "object" ||
        typeof payload.pagination.hasMore !== "boolean") {
      throw Object.assign(new Error("Portaly subscription list response is invalid"), {
        code: "PORTALY_SUBSCRIPTION_LIST_INVALID",
      });
    }

    subscriptions.push(...portalySubscriptions(payload));
    if (!payload.pagination.hasMore) return subscriptions;

    const nextCursor = nonBlankString(payload.pagination.nextCursor);
    if (!nextCursor || seenCursors.has(nextCursor)) {
      throw Object.assign(new Error("Portaly subscription list cursor is invalid"), {
        code: "PORTALY_SUBSCRIPTION_LIST_INVALID",
      });
    }
    seenCursors.add(nextCursor);
    startAfter = nextCursor;
  }

  throw Object.assign(new Error("Portaly subscription list is too large"), {
    code: "PORTALY_SUBSCRIPTION_LIST_TOO_LARGE",
  });
}

function reportSkillVersion(apiKey) {
  if (didReportSkillVersion) return;
  didReportSkillVersion = true;
  void portalyRequest("/api/creator-subscription/skill-version", {
    apiKey,
    method: "POST",
    body: {skillName: "portaly-payment", version: PORTALY_SKILL_VERSION},
  }).catch(() => {});
}

function publicCheckoutError(portalyStatus, payload) {
  switch (payload?.code) {
  case "PLAN_INACTIVE":
    return {status: 422, code: payload.code, message: "此訂閱方案目前沒有開放。"};
  case "PLAN_NOT_FOUND":
    return {status: 503, code: payload.code, message: `訂閱方案設定有誤，請寄信至 ${SUPPORT_EMAIL}。`};
  case "YEARLY_TEMPORARILY_UNSUPPORTED":
    return {status: 422, code: payload.code, message: "年繳方案目前暫時無法使用。"};
  case "INVALID_DISCOUNT_CODE":
    return {status: 400, code: payload.code, message: "折扣碼目前無法套用。"};
  default:
    logger.error("Portaly request failed", {status: portalyStatus, code: payload?.code || null});
    return {status: 502, code: "PORTALY_REQUEST_FAILED", message: "目前無法建立付款流程，請稍後再試。"};
  }
}

function compact(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));
}

function checkoutResponse(session, {duplicate, fallbackMode}) {
  return compact({
    sessionId: session.sessionId,
    checkoutUrl: session.checkoutUrl,
    expiresAt: session.expiresAt,
    amount: session.amount,
    appliedDiscount: session.appliedDiscount ?? null,
    duplicate,
    mode: session.mode || fallbackMode,
  });
}

async function releaseCheckoutLease(lockRef, leaseId) {
  await db.runTransaction(async (transaction) => {
    const lockSnapshot = await transaction.get(lockRef);
    if (lockSnapshot.exists && lockSnapshot.data().leaseId === leaseId) {
      transaction.delete(lockRef);
    }
  });
}

async function releaseAccountDeletionLock(lockRef, userRef, deletionId) {
  await db.runTransaction(async (transaction) => {
    const [lockSnapshot, userSnapshot] = await Promise.all([
      transaction.get(lockRef),
      transaction.get(userRef),
    ]);
    const lock = lockSnapshot.data();
    if (lockSnapshot.exists && lock?.status === "account_deleting" &&
        lock.deletionId === deletionId) {
      transaction.delete(lockRef);
    }
    const user = userSnapshot.data();
    if (userSnapshot.exists && user?.accountDeletionId === deletionId) {
      transaction.set(userRef, {
        accountDeleting: FieldValue.delete(),
        accountDeletionId: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    }
  });
}

async function holdUncertainCheckout({
  lockRef,
  leaseId,
  user,
  mode,
  reason,
  session = {},
  merchantOrderNumber,
}) {
  const sessionId = nonBlankString(session.sessionId);
  const sessionRef = sessionId && !sessionId.includes("/") ?
    db.collection("checkoutSessions").doc(sessionId) : null;

  return db.runTransaction(async (transaction) => {
    const [lockSnapshot, sessionSnapshot] = await Promise.all([
      transaction.get(lockRef),
      sessionRef ? transaction.get(sessionRef) : Promise.resolve(null),
    ]);
    if (!lockSnapshot.exists || lockSnapshot.data().leaseId !== leaseId) {
      return false;
    }

    const transactionNow = Date.now();
    const currentHoldUntilMs = Number(lockSnapshot.data().safetyHoldUntilMs);
    const sessionExpiresAtMs = toEpochMs(session.expiresAt);
    const safetyHoldUntilMs = Math.max(
      Number.isFinite(currentHoldUntilMs) ? currentHoldUntilMs : 0,
      transactionNow + CHECKOUT_UNCERTAIN_HOLD_MS,
      Number.isFinite(sessionExpiresAtMs) ? sessionExpiresAtMs : 0,
    );
    if (sessionRef && !sessionSnapshot?.exists) {
      transaction.create(sessionRef, compact({
        uid: user.uid,
        customerEmail: user.email,
        sessionId,
        subscriptionId: sessionId,
        merchantOrderNumber,
        checkoutUrl: session.checkoutUrl,
        checkoutToken: session.checkoutToken,
        expiresAt: session.expiresAt,
        amount: session.amount,
        appliedDiscount: session.appliedDiscount,
        providerStatus: session.providerStatus,
        lockId: lockRef.id,
        checkoutLockId: lockRef.id,
        planId: PORTALY_PLAN_ID,
        mode,
        status: "response_incomplete",
        reconciliationRequired: true,
        uncertainReason: reason,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }));
    }

    transaction.set(lockRef, compact({
      uid: user.uid,
      planId: PORTALY_PLAN_ID,
      mode,
      status: "uncertain",
      reason,
      safetyHoldUntilMs,
      sessionId,
      merchantOrderNumber,
      checkoutUrl: FieldValue.delete(),
      expiresAt: session.expiresAt,
      leaseId: FieldValue.delete(),
      leaseExpiresAtMs: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    }), {merge: true});
    return true;
  });
}

async function preserveCheckoutSession(sessionRef, sessionRecord) {
  await db.runTransaction(async (transaction) => {
    const sessionSnapshot = await transaction.get(sessionRef);
    if (!sessionSnapshot.exists) {
      transaction.create(sessionRef, {
        ...sessionRecord,
        leaseOwnershipLost: true,
        reconciliationRequired: true,
      });
    }
  });
}

async function createCheckout(request, response) {
  requireJsonBody(request);
  const user = await requireFirebaseUser(request, {verifiedEmail: true});
  const apiKey = PORTALY_API_KEY.value();
  const mode = requirePortalyMode(apiKey);
  // A server-owned grant is authoritative before any provider preflight or
  // checkout request.  The check is repeated around the lease/network
  // boundary below to close the small admin-grant race window.
  enforceCheckoutGrantDecision(await checkoutGrantDecisionForUser(user.uid));
  const now = Date.now();
  const fallbackSession = await findReusableCheckoutSession(user.uid, now, mode);
  const userRef = db.collection("users").doc(user.uid);
  const checkoutLocks = db.collection("checkoutLocks");
  const customerLockId = customerSubscriptionKey({
    email: user.email,
    planId: PORTALY_PLAN_ID,
    mode,
  });
  if (!customerLockId) {
    throw Object.assign(new Error("無法確認訂閱帳號，請重新登入後再試。"), {
      statusCode: 409,
      code: "CUSTOMER_SUBSCRIPTION_KEY_INVALID",
    });
  }
  const lockRef = checkoutLocks.doc(customerLockId);
  const grantRef = entitlementGrantRef(user.uid);
  const legacyLockRefs = [
    checkoutLocks.doc(checkoutLockDocumentId(user.uid, PORTALY_PLAN_ID, mode)),
    checkoutLocks.doc(checkoutLockDocumentId(user.uid, PORTALY_PLAN_ID)),
  ].filter((ref, index, refs) =>
    refs.findIndex((candidate) => candidate.path === ref.path) === index,
  );
  const leaseId = randomUUID();

  const decision = await db.runTransaction(async (transaction) => {
    const transactionNow = Date.now();
    const reads = [
      transaction.get(userRef),
      transaction.get(grantRef),
      transaction.get(lockRef),
      ...legacyLockRefs.map((ref) => transaction.get(ref)),
    ];
    const [userSnapshot, grantSnapshot, lockSnapshot, ...legacyLockSnapshots] = await Promise.all(reads);
    const grantDecision = checkoutEntitlementGrantDecision(
      grantSnapshot.exists ? grantSnapshot.data() : null,
      {now: transactionNow},
    );
    if (grantDecision.kind !== "allow") return grantDecision;
    const value = checkoutLeaseDecision({
      subscription: userSnapshot.data() || {},
      emailLock: lockSnapshot.data() || null,
      legacyLocks: legacyLockSnapshots.map((snapshot) => snapshot.data() || null),
      fallbackSession,
      uid: user.uid,
      planId: PORTALY_PLAN_ID,
      mode,
      now: transactionNow,
    });

    if (value.kind === "acquire") {
      transaction.set(lockRef, {
        uid: user.uid,
        planId: PORTALY_PLAN_ID,
        mode,
        status: "creating",
        leaseId,
        leaseExpiresAtMs: transactionNow + CHECKOUT_LEASE_MS,
        safetyHoldUntilMs: transactionNow + CHECKOUT_UNCERTAIN_HOLD_MS,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    return value;
  });

  if (decision.kind === "blocked") {
    throw Object.assign(new Error("你目前已有有效訂閱，請先管理現有方案再建立新的 checkout。"), {
      statusCode: 409,
      code: "ACTIVE_SUBSCRIPTION_EXISTS",
    });
  }
  if (decision.kind === "server_grant") {
    rejectCheckoutForServerGrant();
  }
  if (decision.kind === "grant_invalid") {
    rejectCheckoutForInvalidGrant(decision.code);
  }
  if (decision.kind === "reuse") {
    return json(response, 200, checkoutResponse(decision.session, {
      duplicate: true,
      fallbackMode: mode,
    }));
  }
  if (decision.kind === "in_progress") {
    throw Object.assign(new Error("付款流程正在建立中，請稍候片刻再試。"), {
      statusCode: 409,
      code: "CHECKOUT_IN_PROGRESS",
    });
  }
  if (decision.kind === "safety_hold") {
    throw Object.assign(new Error("先前付款建立結果尚未確認，為避免重複扣款，暫時無法建立新的付款流程。"), {
      statusCode: 409,
      code: "CHECKOUT_SAFETY_HOLD",
    });
  }
  if (decision.kind === "conflict") {
    throw Object.assign(new Error("此電子郵件已有尚未完成的付款流程，請稍後再試或管理現有訂閱。"), {
      statusCode: 409,
      code: "EMAIL_CHECKOUT_CONFLICT",
    });
  }

  // Re-check immediately before the first Portaly request.  Grant creation is
  // an administrator operation and can race a member's checkout attempt;
  // releasing our lease keeps a newly granted account from entering provider
  // preflight or creating a provider order.
  const beforeProviderGrant = await checkoutGrantDecisionForUser(user.uid);
  if (beforeProviderGrant.kind !== "allow") {
    await releaseCheckoutLease(lockRef, leaseId);
    enforceCheckoutGrantDecision(beforeProviderGrant);
  }

  // Report only after the final server-grant guard; this is the first provider
  // network call and must never happen for an account with effective free Pro.
  reportSkillVersion(apiKey);

  let customerSubscriptions;
  try {
    customerSubscriptions = await listCustomerSubscriptions({
      apiKey,
      customerEmail: user.email,
    });
  } catch (error) {
    await releaseCheckoutLease(lockRef, leaseId);
    logger.error("Portaly customer subscription preflight failed", {
      code: error?.code || null,
      portalyStatus: error?.portalyStatus || null,
      portalyCode: error?.portalyCode || null,
    });
    throw Object.assign(new Error("目前無法確認既有訂閱，請稍後再試。"), {
      statusCode: 502,
      code: "PORTALY_SUBSCRIPTION_PREFLIGHT_FAILED",
    });
  }

  let blockingSubscription;
  try {
    blockingSubscription = findBlockingCustomerSubscriptionStrict(
      customerSubscriptions,
      {email: user.email, planId: PORTALY_PLAN_ID, mode},
    );
  } catch (error) {
    await releaseCheckoutLease(lockRef, leaseId);
    logger.error("Portaly customer subscription validation failed", {
      code: error?.code || null,
    });
    throw Object.assign(new Error("目前無法確認既有訂閱，請稍後再試。"), {
      statusCode: 502,
      code: "PORTALY_SUBSCRIPTION_PREFLIGHT_FAILED",
    });
  }
  if (blockingSubscription) {
    await releaseCheckoutLease(lockRef, leaseId);
    throw Object.assign(new Error("此電子郵件已有有效訂閱，請前往 Portaly 管理現有訂閱。"), {
      statusCode: 409,
      code: "EMAIL_SUBSCRIPTION_EXISTS",
    });
  }

  const beforeCheckoutGrant = await checkoutGrantDecisionForUser(user.uid);
  if (beforeCheckoutGrant.kind !== "allow") {
    await releaseCheckoutLease(lockRef, leaseId);
    enforceCheckoutGrantDecision(beforeCheckoutGrant);
  }

  const merchantOrderNumber = `ufogeo-${user.uid.slice(0, 10)}-${now}-${randomUUID().slice(0, 8)}`;
  const callbackUrl = `${PUBLIC_BASE_URL}/api/portaly/callback`;
  let portalyResult;
  try {
    portalyResult = await portalyRequest(
      "/api/creator-subscription/checkout-sessions",
      {
        apiKey,
        method: "POST",
        body: {
          planId: PORTALY_PLAN_ID,
          successRedirectUrl: `${PUBLIC_BASE_URL}/payment/success/`,
          cancelRedirectUrl: `${PUBLIC_BASE_URL}/payment/cancel/`,
          callbackUrl,
          subscriptionCallbackUrl: callbackUrl,
          merchantOrderNumber,
          customerEmail: user.email,
          emailVerified: true,
          metadata: {firebaseUid: user.uid, source: "ios", checkoutLeaseId: leaseId},
        },
      },
    );
  } catch (error) {
    const classification = classifyCheckoutCreationResult({error});
    await holdUncertainCheckout({
      lockRef,
      leaseId,
      user,
      mode,
      reason: classification.reason,
      session: classification,
      merchantOrderNumber,
    });
    logger.error("Portaly checkout request threw", {
      message: error?.message || "Unknown error",
      leaseId,
    });
    return json(response, 502, {
      error: "付款建立結果尚未確認，為避免重複扣款，暫時無法重試。",
      code: "PORTALY_REQUEST_UNCERTAIN",
    });
  }

  const {response: portalyResponse, payload} = portalyResult;
  const classification = classifyCheckoutCreationResult({
    status: portalyResponse.status,
    payload,
    now: Date.now(),
  });

  if (classification.kind === "definitive_failure") {
    await releaseCheckoutLease(lockRef, leaseId);
    const error = publicCheckoutError(portalyResponse.status, payload);
    return json(response, error.status, {error: error.message, code: error.code});
  }
  if (classification.kind === "uncertain") {
    await holdUncertainCheckout({
      lockRef,
      leaseId,
      user,
      mode,
      reason: classification.reason,
      session: classification,
      merchantOrderNumber,
    });
    logger.error("Portaly checkout result is uncertain", {
      status: portalyResponse.status,
      reason: classification.reason,
      sessionId: classification.sessionId || null,
      leaseId,
    });
    return json(response, 502, {
      error: "付款建立結果尚未確認，為避免重複扣款，暫時無法重試。",
      code: classification.reason === "response_incomplete" ?
        "PORTALY_RESPONSE_INCOMPLETE" : "PORTALY_REQUEST_UNCERTAIN",
    });
  }

  const session = classification.session;
  const sessionRef = db.collection("checkoutSessions").doc(session.sessionId);
  const sessionRecord = compact({
    uid: user.uid,
    customerEmail: user.email,
    sessionId: session.sessionId,
    subscriptionId: session.sessionId,
    merchantOrderNumber,
    checkoutUrl: session.checkoutUrl,
    checkoutToken: session.checkoutToken,
    checkoutLeaseId: leaseId,
    checkoutLockId: lockRef.id,
    planId: PORTALY_PLAN_ID,
    mode,
    status: session.status || "checkout_ready",
    providerStatus: session.providerStatus,
    expiresAt: session.expiresAt,
    amount: session.amount,
    appliedDiscount: session.appliedDiscount ?? null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  let finalized;
  try {
    finalized = await db.runTransaction(async (transaction) => {
      const lockSnapshot = await transaction.get(lockRef);
      if (!lockSnapshot.exists || lockSnapshot.data().leaseId !== leaseId) {
        return false;
      }

      transaction.set(sessionRef, sessionRecord);
      transaction.set(userRef, {
        email: user.email,
        emailVerified: true,
        proActive: false,
        subscriptionStatus: session.status || "checkout_ready",
        subscriptionId: session.sessionId,
        currentCheckoutSessionId: session.sessionId,
        planId: PORTALY_PLAN_ID,
        mode,
        cancelAtPeriodEnd: false,
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(lockRef, compact({
        uid: user.uid,
        planId: PORTALY_PLAN_ID,
        status: session.status || "checkout_ready",
        sessionId: session.sessionId,
        checkoutUrl: session.checkoutUrl,
        expiresAt: session.expiresAt,
        amount: session.amount,
        appliedDiscount: session.appliedDiscount ?? null,
        mode,
        leaseId: FieldValue.delete(),
        leaseExpiresAtMs: FieldValue.delete(),
        safetyHoldUntilMs: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }), {merge: true});
      return true;
    });
  } catch (error) {
    await preserveCheckoutSession(sessionRef, sessionRecord);
    logger.error("Checkout state finalization failed after Portaly creation", {
      sessionId: session.sessionId,
      message: error?.message || "Unknown error",
    });
    throw Object.assign(new Error("付款流程已建立，但狀態同步失敗，請稍後再試。"), {
      statusCode: 503,
      code: "CHECKOUT_STATE_SYNC_FAILED",
    });
  }

  if (!finalized) {
    await preserveCheckoutSession(sessionRef, sessionRecord);
    logger.error("Checkout lease ownership was lost after Portaly creation", {
      sessionId: session.sessionId,
      leaseId,
    });
    throw Object.assign(new Error("付款流程已建立，正在同步狀態，請稍後再試。"), {
      statusCode: 409,
      code: "CHECKOUT_LEASE_LOST",
    });
  }

  return json(response, 201, checkoutResponse({...session, mode}, {
    duplicate: false,
    fallbackMode: mode,
  }));
}

function subscriptionStateResponse(options) {
  return buildSubscriptionStateResponse({
    ...options,
    fallbackPlanId: PORTALY_PLAN_ID,
  });
}

function checkoutLockRefsForSession(session, target) {
  const checkoutLocks = db.collection("checkoutLocks");
  const customerLockId = customerSubscriptionKey({
    email: target.email,
    planId: target.planId,
    mode: target.mode,
  });
  const storedLockId = nonBlankString(session?.checkoutLockId);
  const ids = [
    customerLockId,
    storedLockId && !storedLockId.includes("/") ? storedLockId : null,
    checkoutLockDocumentId(target.uid, target.planId, target.mode),
    checkoutLockDocumentId(target.uid, target.planId),
  ].filter((id, index, values) => id && values.indexOf(id) === index);
  return ids.map((id) => checkoutLocks.doc(id));
}

async function finalizeTerminalCheckoutReconciliation({
  user,
  target,
  providerStatus,
  remote,
}) {
  const userRef = db.collection("users").doc(user.uid);
  const sessionRef = db.collection("checkoutSessions").doc(target.sessionId);
  const grantRef = entitlementGrantRef(user.uid);
  const verifiedAt = new Date().toISOString();
  const result = await db.runTransaction(async (transaction) => {
    const [userSnapshot, sessionSnapshot, grantSnapshot] = await Promise.all([
      transaction.get(userRef),
      transaction.get(sessionRef),
      transaction.get(grantRef),
    ]);
    if (!userSnapshot.exists || !sessionSnapshot.exists) {
      throwReconciliationConflict(
        "CHECKOUT_RECONCILIATION_STATE_CHANGED",
        "付款狀態已變更，請重新整理後再試。",
      );
    }
    const current = userSnapshot.data() || {};
    const session = sessionSnapshot.data() || {};
    const lockRefs = checkoutLockRefsForSession(session, target);
    const lockSnapshots = await Promise.all(lockRefs.map((ref) => transaction.get(ref)));
    const currentLock = lockSnapshots.find((snapshot) =>
      checkoutLockMatchesSession(snapshot.data() || null, target.sessionId, {
        mode: target.mode,
      }))?.data() || null;
    const currentTarget = checkoutSessionReconciliationTarget({
      user: current,
      lock: currentLock,
      uid: user.uid,
      email: user.email,
      planId: PORTALY_PLAN_ID,
      mode: target.mode,
    });
    if (!currentTarget || currentTarget.sessionId !== target.sessionId) {
      throwReconciliationConflict(
        "CHECKOUT_RECONCILIATION_STATE_CHANGED",
        "付款狀態已變更，請重新整理後再試。",
      );
    }
    validateStoredCheckoutSession(session, currentTarget);
    const state = verifiedCheckoutSessionState(
      {data: remote},
      {target: currentTarget, localSession: session},
    );
    if (state.kind !== "terminal" || state.status !== providerStatus) {
      throwReconciliationConflict(
        "CHECKOUT_RECONCILIATION_STATE_CHANGED",
        "付款狀態已變更，請重新整理後再試。",
      );
    }

    const timestamp = FieldValue.serverTimestamp();
    transaction.set(userRef, {
      email: user.email,
      emailVerified: user.emailVerified,
      proActive: false,
      subscriptionStatus: "checkout_failed",
      subscriptionId: FieldValue.delete(),
      currentCheckoutSessionId: target.sessionId,
      planId: target.planId,
      mode: target.mode,
      cancelAtPeriodEnd: false,
      lastReconciledAt: timestamp,
      lastReconciledAtMs: Date.parse(verifiedAt),
      updatedAt: timestamp,
    }, {merge: true});
    transaction.set(sessionRef, {
      status: "checkout_failed",
      providerStatus,
      subscriptionId: FieldValue.delete(),
      reconciliationRequired: false,
      lastReconciledAt: timestamp,
      lastReconciledAtMs: Date.parse(verifiedAt),
      updatedAt: timestamp,
    }, {merge: true});
    for (let index = 0; index < lockRefs.length; index += 1) {
      if (checkoutLockMatchesSession(
        lockSnapshots[index].data() || null,
        target.sessionId,
        {mode: target.mode},
      )) {
        transaction.delete(lockRefs[index]);
      }
    }
    transaction.set(db.collection("portalyAudit").doc(), {
      uid: user.uid,
      event: "creator_subscription.checkout.reconciled",
      sessionId: target.sessionId,
      subscriptionId: null,
      merchantOrderNumber: session.merchantOrderNumber || null,
      status: "checkout_failed",
      providerStatus,
      mode: target.mode,
      appliedToSession: true,
      appliedToCurrentUser: true,
      receivedAt: timestamp,
    });
    return {
      data: {
        ...current,
        email: user.email,
        emailVerified: user.emailVerified,
        proActive: false,
        subscriptionStatus: "checkout_failed",
        subscriptionId: null,
        currentCheckoutSessionId: target.sessionId,
        planId: target.planId,
        mode: target.mode,
        cancelAtPeriodEnd: false,
        lastReconciledAtMs: Date.parse(verifiedAt),
      },
      grant: grantSnapshot.exists ? grantSnapshot.data() : null,
      verifiedAt,
    };
  });
  return subscriptionStateResponse({
    uid: user.uid,
    email: user.email,
    emailVerified: user.emailVerified,
    data: result.data,
    grant: result.grant,
    expectedMode: target.mode,
    lastVerifiedAt: result.verifiedAt,
  });
}

async function reconcilePendingCheckoutForUser({user, initialUser, apiKey, expectedMode}) {
  const customerLockId = customerSubscriptionKey({
    email: user.email,
    planId: PORTALY_PLAN_ID,
    mode: expectedMode,
  });
  if (!customerLockId) {
    throwReconciliationConflict(
      "CUSTOMER_SUBSCRIPTION_KEY_INVALID",
      "無法確認訂閱帳號，請重新登入後再試。",
    );
  }
  const lockSnapshot = await db.collection("checkoutLocks").doc(customerLockId).get();
  const lock = lockSnapshot.data() || null;
  const target = checkoutSessionReconciliationTarget({
    user: initialUser,
    lock,
    uid: user.uid,
    email: user.email,
    planId: PORTALY_PLAN_ID,
    mode: expectedMode,
  });
  if (!target) {
    if (["uncertain", "response_incomplete", "creating"].includes(lock?.status)) {
      return {kind: "held"};
    }
    return null;
  }

  reportSkillVersion(apiKey);
  try {
    const result = await reconcileCheckoutSessionPath({
      user: initialUser,
      lock,
      uid: user.uid,
      email: user.email,
      planId: PORTALY_PLAN_ID,
      mode: expectedMode,
      loadSession: async (sessionId) => {
        const snapshot = await db.collection("checkoutSessions").doc(sessionId).get();
        return snapshot.exists ? snapshot.data() : null;
      },
      queryCheckoutSession: async (sessionId) => {
        const {response, payload} = await portalyRequest(
          `/api/creator-subscription/checkout-sessions/${encodeURIComponent(sessionId)}`,
          {apiKey},
        );
        if (!response.ok) {
          throw Object.assign(new Error("Portaly checkout session request failed"), {
            code: "PORTALY_CHECKOUT_RECONCILE_FAILED",
            portalyStatus: response.status,
            portalyCode: payload?.code || null,
          });
        }
        return payload;
      },
      persistTerminal: (options) => finalizeTerminalCheckoutReconciliation({
        user,
        ...options,
      }),
      reconcileCompleted: async ({trustedLookupId}) => reconcilePortalySubscriptionForUser({
        user,
        initialUser,
        apiKey,
        expectedMode,
        trustedLookupId,
      }),
    });
    return checkoutReconciliationOrchestrationResult(result);
  } catch (error) {
    logger.error("Portaly checkout reconciliation failed", {
      code: error?.code || null,
      portalyStatus: error?.portalyStatus || null,
      portalyCode: error?.portalyCode || null,
      sessionId: target.sessionId,
    });
    throw Object.assign(new Error("目前無法確認付款狀態，請稍後再試。"), {
      statusCode: error?.statusCode === 409 ? 409 : 502,
      code: error?.code || "PORTALY_CHECKOUT_RECONCILE_UNCERTAIN",
    });
  }
}

async function unresolvedCheckoutHoldResponse({user, data, expectedMode}) {
  const grant = await userEntitlementGrant(user.uid);
  return subscriptionStateResponse({
    uid: user.uid,
    email: user.email,
    emailVerified: user.emailVerified,
    data: {
      ...data,
      mode: expectedMode,
      subscriptionStatus: "unavailable",
    },
    grant,
    expectedMode,
  });
}

async function getSubscription(request, response) {
  const user = await requireFirebaseUser(request);
  const apiKey = PORTALY_API_KEY.value();
  const expectedMode = requirePortalyMode(apiKey);
  const snapshot = await db.collection("users").doc(user.uid).get();
  const data = snapshot.data() || {};
  const reconciled = await reconcilePendingCheckoutForUser({
    user,
    initialUser: data,
    apiKey,
    expectedMode,
  });
  if (reconciled?.kind === "resolved") {
    return json(response, 200, reconciled.body);
  }
  if (reconciled?.kind === "held") {
    return json(response, 200, await unresolvedCheckoutHoldResponse({
      user,
      data,
      expectedMode,
    }));
  }
  const grant = await userEntitlementGrant(user.uid);
  return json(response, 200, subscriptionStateResponse({
    uid: user.uid,
    email: user.email,
    emailVerified: user.emailVerified,
    data,
    grant,
    expectedMode,
  }));
}

function nonBlankString(value) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function entitlementGrantRef(uid) {
  return db.collection("entitlementGrants").doc(uid);
}

async function userEntitlementGrant(uid) {
  const snapshot = await entitlementGrantRef(uid).get();
  return snapshot.exists ? snapshot.data() : null;
}

async function checkoutGrantDecisionForUser(uid) {
  return checkoutEntitlementGrantDecision(await userEntitlementGrant(uid));
}

function enforceCheckoutGrantDecision(decision) {
  if (decision.kind === "server_grant") rejectCheckoutForServerGrant();
  if (decision.kind === "grant_invalid") rejectCheckoutForInvalidGrant(decision.code);
}

function rejectCheckoutForServerGrant() {
  throw Object.assign(new Error("此帳號已有免費 Pro 授權，無需訂閱或付款。"), {
    statusCode: 409,
    code: ENTITLEMENT_GRANT_CHECKOUT_CODE,
  });
}

function rejectCheckoutForInvalidGrant(validationCode) {
  logger.error("Checkout blocked by invalid entitlement grant", {
    validationCode: validationCode || null,
  });
  throw Object.assign(new Error("目前無法確認 Pro 授權狀態，請稍後再試。"), {
    statusCode: 409,
    code: "ENTITLEMENT_GRANT_STATE_INVALID",
  });
}

function normalizedStateValue(value) {
  return value === undefined || value === null ? null : value;
}

function throwReconciliationConflict(code, message) {
  throw Object.assign(new Error(message), {statusCode: 409, code});
}

function publicReconciliationError(error) {
  if (error instanceof SubscriptionReconciliationError) {
    const identityMismatch = new Set([
      "CURRENT_SUBSCRIPTION_ID_INVALID",
      "CURRENT_MODE_INVALID",
      "EXPECTED_SUBSCRIPTION_ID_INVALID",
      "EXPECTED_MODE_INVALID",
      "CURRENT_PLAN_ID_MISMATCH",
      "SUBSCRIPTION_ID_MISMATCH",
      "SUBSCRIPTION_MODE_MISMATCH",
      "SUBSCRIPTION_PLAN_MISMATCH",
      "SUBSCRIPTION_STATE_INVALID",
    ]);
    return {
      status: identityMismatch.has(error.code) ? 409 : 502,
      code: error.code,
      message: identityMismatch.has(error.code) ?
        "訂閱資料與目前帳號不一致，請重新整理後再試。" :
        "目前無法確認訂閱狀態，請稍後再試。",
    };
  }
  return null;
}

function portalySubscriptionValue(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return null;
  const value = payload.data;
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  // The documented HTTP response is wrapped in `data`, but accepting an
  // already-unwrapped object keeps the server adapter compatible with a
  // proxy that removes the envelope without weakening the helper checks.
  return nonBlankString(payload.id) || nonBlankString(payload.subscriptionId) ? payload : null;
}

function remotePlanId(value) {
  const direct = nonBlankString(value?.planId);
  if (direct) return direct;
  return nonBlankString(value?.plan?.id);
}

function addRemoteSessionFields(target, remote) {
  const optional = [
    ["nextBillingAt", "nextBillingAt"],
    ["cancelEffectiveAt", "cancelEffectiveAt"],
    ["cancelRequestedAt", "cancelRequestedAt"],
    ["canceledAt", "canceledAt"],
    ["lastChargedAt", "lastChargedAt"],
    ["lastFailureAt", "lastFailureAt"],
    ["failureCount", "failureCount"],
    ["lastFailureReason", "failureReason"],
    ["lastPaymentReference", "lastPaymentReference"],
  ];
  for (const [remoteField, sessionField] of optional) {
    if (remote[remoteField] !== undefined && remote[remoteField] !== null) {
      target[sessionField] = remote[remoteField];
    }
  }
}

function clearResumedCancellationFields(target) {
  for (const field of ["cancelEffectiveAt", "canceledAt", "cancelRequestedAt"]) {
    target[field] = FieldValue.delete();
  }
}

/**
 * Pull the authoritative subscription status after the subscriber returns
 * from Portaly's self-service page.  The GET status endpoint intentionally
 * remains a Firestore-only read; this POST is the only request that polls
 * Portaly on behalf of a signed-in user.
 */
async function reconcilePortalySubscriptionForUser({
  user,
  initialUser,
  apiKey,
  expectedMode,
  trustedLookupId = null,
}) {
  const userRef = db.collection("users").doc(user.uid);
  const grantRef = entitlementGrantRef(user.uid);
  const grant = await userEntitlementGrant(user.uid);
  const storedModeRelationship = storedPortalyModeRelationship(
    initialUser.mode,
    expectedMode,
  );

  // A valid record from the other environment is historical provider state,
  // not a current-key resource. Do not query it with this API key and do not
  // surface it as a conflict to the client.
  if (storedModeRelationship === "opposite") {
    return subscriptionStateResponse({
      uid: user.uid,
      email: user.email,
      emailVerified: user.emailVerified,
      data: initialUser,
      grant,
      expectedMode,
    });
  }
  if (storedModeRelationship !== "matching" && storedModeRelationship !== "missing") {
    throwReconciliationConflict(
      "SUBSCRIPTION_MODE_MISMATCH",
      "訂閱環境與目前付款設定不一致，請稍後再試。",
    );
  }
  for (const field of ["subscriptionId", "currentCheckoutSessionId"]) {
    if (initialUser[field] !== undefined && initialUser[field] !== null &&
        initialUser[field] !== "" && !nonBlankString(initialUser[field])) {
      throwReconciliationConflict(
        "CURRENT_SUBSCRIPTION_ID_INVALID",
        "訂閱資料尚未同步完成，請稍後再試。",
      );
    }
  }
  const initialSubscriptionId = nonBlankString(initialUser.subscriptionId);
  const initialCheckoutSessionId = nonBlankString(initialUser.currentCheckoutSessionId);
  const lookupId = subscriptionReconciliationLookupId({
    initialSubscriptionId,
    initialCheckoutSessionId,
    trustedLookupId,
  });

  // Free users (and users whose failed checkout has no subscription) have no
  // provider resource to query.  Return the same response contract without
  // spending a Portaly read.
  if (!lookupId) {
    return subscriptionStateResponse({
      uid: user.uid,
      email: user.email,
      emailVerified: user.emailVerified,
      data: initialUser,
      grant,
      expectedMode,
    });
  }

  if (initialSubscriptionId && initialCheckoutSessionId &&
      initialSubscriptionId !== initialCheckoutSessionId) {
    throwReconciliationConflict(
      "SUBSCRIPTION_STATE_CONFLICT",
      "訂閱資料尚未同步完成，請稍後再試。",
    );
  }

  reportSkillVersion(apiKey);
  let portalyResult;
  try {
    portalyResult = await portalyRequest(
      `/api/creator-subscription/subscriptions/${encodeURIComponent(lookupId)}`,
      {apiKey},
    );
  } catch (error) {
    logger.error("Portaly subscription reconciliation request threw", {
      message: error?.message || "Unknown error",
      subscriptionId: lookupId,
    });
    throw Object.assign(new Error("目前無法確認訂閱狀態，請稍後再試。"), {
      statusCode: 502,
      code: "PORTALY_RECONCILE_REQUEST_UNCERTAIN",
    });
  }

  const {response: portalyResponse, payload} = portalyResult;
  if (!portalyResponse.ok) {
    logger.error("Portaly subscription reconciliation failed", {
      status: portalyResponse.status,
      code: payload?.code || null,
      subscriptionId: lookupId,
    });
    if (portalyResponse.status === 404) {
      throw Object.assign(new Error(`找不到這筆訂閱，請重新訂閱或寄信至 ${SUPPORT_EMAIL}。`), {
        statusCode: 409,
        code: "PORTALY_SUBSCRIPTION_NOT_FOUND",
      });
    }
    throw Object.assign(new Error("目前無法確認訂閱狀態，請稍後再試。"), {
      statusCode: portalyResponse.status === 401 || portalyResponse.status === 403 ? 503 : 502,
      code: "PORTALY_RECONCILE_FAILED",
    });
  }

  const remote = portalySubscriptionValue(payload);
  if (!remote) {
    logger.error("Portaly subscription reconciliation returned an incomplete response", {
      subscriptionId: lookupId,
    });
    throw Object.assign(new Error("目前無法確認訂閱狀態，請稍後再試。"), {
      statusCode: 502,
      code: "PORTALY_RECONCILE_RESPONSE_INVALID",
    });
  }

  const verifiedAt = new Date().toISOString();
  const initialStateFingerprint = {
    subscriptionId: normalizedStateValue(initialUser.subscriptionId),
    currentCheckoutSessionId: normalizedStateValue(initialUser.currentCheckoutSessionId),
    mode: normalizedStateValue(initialUser.mode),
    subscriptionStatus: normalizedStateValue(initialUser.subscriptionStatus),
    proActive: normalizedStateValue(initialUser.proActive),
    cancelAtPeriodEnd: normalizedStateValue(initialUser.cancelAtPeriodEnd),
    lastCallbackAtMs: normalizedStateValue(initialUser.lastCallbackAtMs),
  };

  let reconciled;
  try {
    reconciled = await db.runTransaction(async (transaction) => {
      const currentSnapshot = await transaction.get(userRef);
      const grantSnapshot = await transaction.get(grantRef);
      if (!currentSnapshot.exists) {
        throwReconciliationConflict(
          "ACCOUNT_STATE_CHANGED",
          "會員資料已變更，請重新整理後再試。",
        );
      }
      const current = currentSnapshot.data() || {};
      const sessionRef = db.collection("checkoutSessions").doc(lookupId);
      const sessionSnapshot = await transaction.get(sessionRef);
      const session = sessionSnapshot.data() || {};
      const reconciliationTarget = {
        sessionId: lookupId,
        uid: user.uid,
        email: user.email,
        planId: PORTALY_PLAN_ID,
        mode: expectedMode,
      };
      const reconciliationLockRefs = checkoutLockRefsForSession(
        session,
        reconciliationTarget,
      );
      const reconciliationLockSnapshots = await Promise.all(
        reconciliationLockRefs.map((ref) => transaction.get(ref)),
      );
      for (const [field, expected] of [
        ["uid", user.uid],
        ["sessionId", lookupId],
        ["subscriptionId", lookupId],
        ["mode", expectedMode],
      ]) {
        const actual = nonBlankString(session[field]);
        if (actual && actual !== expected) {
          throwReconciliationConflict(
            "CHECKOUT_SESSION_STATE_CONFLICT",
            "訂閱資料與目前帳號不一致，請稍後再試。",
          );
        }
      }

      // The helper is pure and returns allow-listed user/session/audit patches.
      // Pass the server-selected ID and mode explicitly so legacy records that
      // predate these fields are still reconciled against this API key only.
      const reconciliation = buildReconciliationPatches({
        currentUser: current,
        subscription: payload,
        expectedSubscriptionId: lookupId,
        expectedMode,
        expectedPlanId: PORTALY_PLAN_ID,
        now: verifiedAt,
      });
      // Keep users.proActive as the Portaly-owned state.  The server grant is
      // resolved only at the API boundary and is never copied into this
      // provider-state field.
      const userPatch = reconciliation.userPatch;

      // A callback can arrive after the Portaly GET but before this
      // transaction.  If it already applied the active state returned by the
      // GET while resuming a pending cancellation, continue idempotently; a
      // different state (or an unrelated renewal race) still aborts so a
      // stale GET cannot overwrite it.
      const accountStateChanged = [
        "subscriptionId",
        "currentCheckoutSessionId",
        "mode",
        "subscriptionStatus",
        "proActive",
        "cancelAtPeriodEnd",
        "lastCallbackAtMs",
      ].some((field) => normalizedStateValue(current[field]) !== initialStateFingerprint[field]);
      const isResumeStateRace =
        initialStateFingerprint.subscriptionStatus === "cancel_requested" &&
        userPatch.subscriptionStatus === "active" &&
        subscriptionStateMatchesPatch(current, userPatch);
      if (accountStateChanged && !isResumeStateRace) {
        throwReconciliationConflict(
          "ACCOUNT_STATE_CHANGED",
          "訂閱資料剛剛已變更，請重新整理後再試。",
        );
      }

      const planId = remotePlanId(remote);
      const timestamp = FieldValue.serverTimestamp();
      const userWritePatch = {
        ...userPatch,
        email: user.email,
        emailVerified: user.emailVerified,
        currentCheckoutSessionId: lookupId,
        planId,
        lastReconciledAt: timestamp,
        lastReconciledAtMs: Date.parse(verifiedAt),
        updatedAt: timestamp,
      };
      const sessionWritePatch = {
        ...reconciliation.sessionPatch,
        uid: user.uid,
        customerEmail: user.email,
        sessionId: lookupId,
        subscriptionId: lookupId,
        planId,
        mode: userPatch.mode,
        status: userPatch.subscriptionStatus,
        providerStatus: remote.status,
        cancelAtPeriodEnd: userPatch.cancelAtPeriodEnd,
        reconciliationRequired: false,
        lastReconciledAt: timestamp,
        lastReconciledAtMs: Date.parse(verifiedAt),
        updatedAt: timestamp,
      };
      addRemoteSessionFields(sessionWritePatch, remote);

      // Portaly's resume action clears the end-of-period cancellation.  Do
      // not let stale local dates keep the UI showing the old canceled state.
      if (remote.status !== "canceled" && remote.cancelAtPeriodEnd === false) {
        clearResumedCancellationFields(userWritePatch);
        clearResumedCancellationFields(sessionWritePatch);
      }
      if (!sessionSnapshot.exists) sessionWritePatch.createdAt = timestamp;
      transaction.set(userRef, userWritePatch, {merge: true});
      transaction.set(sessionRef, sessionWritePatch, {merge: true});
      for (let index = 0; index < reconciliationLockRefs.length; index += 1) {
        if (checkoutLockMatchesSession(
          reconciliationLockSnapshots[index].data() || null,
          lookupId,
          {mode: expectedMode},
        )) {
          transaction.delete(reconciliationLockRefs[index]);
        }
      }

      const auditRef = db.collection("portalyAudit").doc();
      transaction.set(auditRef, {
        ...reconciliation.audit,
        uid: user.uid,
        event: "creator_subscription.reconciled",
        sessionId: lookupId,
        subscriptionId: lookupId,
        merchantOrderNumber: session.merchantOrderNumber || null,
        status: userPatch.subscriptionStatus,
        providerStatus: remote.status,
        mode: userPatch.mode,
        appliedToSession: true,
        appliedToCurrentUser: true,
        previousSubscriptionStatus: current.subscriptionStatus || "none",
        receivedAt: timestamp,
      });

      return {
        data: {
          ...current,
          ...userPatch,
          currentCheckoutSessionId: lookupId,
          planId,
        },
        grant: grantSnapshot.exists ? grantSnapshot.data() : null,
      };
    });
  } catch (error) {
    const publicError = publicReconciliationError(error);
    if (publicError) {
      throw Object.assign(new Error(publicError.message), {
        statusCode: publicError.status,
        code: publicError.code,
      });
    }
    throw error;
  }

  return subscriptionStateResponse({
    uid: user.uid,
    email: user.email,
    emailVerified: user.emailVerified,
    data: reconciled.data,
    grant: reconciled.grant,
    expectedMode,
    lastVerifiedAt: verifiedAt,
  });
}

async function reconcileSubscription(request, response) {
  requireJsonBody(request);
  const user = await requireFirebaseUser(request);
  const initialSnapshot = await db.collection("users").doc(user.uid).get();
  const initialUser = initialSnapshot.data() || {};
  const apiKey = PORTALY_API_KEY.value();
  const expectedMode = requirePortalyMode(apiKey);
  const checkoutReconciled = await reconcilePendingCheckoutForUser({
    user,
    initialUser,
    apiKey,
    expectedMode,
  });
  if (checkoutReconciled?.kind === "resolved") {
    return json(response, 200, checkoutReconciled.body);
  }
  if (checkoutReconciled?.kind === "held") {
    return json(response, 200, await unresolvedCheckoutHoldResponse({
      user,
      data: initialUser,
      expectedMode,
    }));
  }
  if (checkoutReconciled?.kind === "pending") {
    const grant = await userEntitlementGrant(user.uid);
    return json(response, 200, subscriptionStateResponse({
      uid: user.uid,
      email: user.email,
      emailVerified: user.emailVerified,
      data: initialUser,
      grant,
      expectedMode,
    }));
  }
  const body = await reconcilePortalySubscriptionForUser({
    user,
    initialUser,
    apiKey,
    expectedMode,
  });
  return json(response, 200, body);
}

async function createPortal(request, response) {
  requireJsonBody(request);
  const user = await requireFirebaseUser(request, {verifiedEmail: true});
  const userRef = db.collection("users").doc(user.uid);
  const userSnapshot = await userRef.get();
  const currentUser = userSnapshot.data() || {};
  const apiKey = PORTALY_API_KEY.value();
  const mode = requirePortalyMode(apiKey);
  const grant = await userEntitlementGrant(user.uid);
  const initialPortalDecision = portalAccessDecision({
    data: currentUser,
    expectedMode: mode,
    expectedPlanId: PORTALY_PLAN_ID,
  });
  if (initialPortalDecision.kind !== "allow" && validateEntitlementGrant(grant).active) {
    throw Object.assign(new Error("此帳號使用免費 Pro 授權，沒有需要管理的 Portaly 訂閱。"), {
      statusCode: 409,
      code: "SERVER_GRANT_PORTAL_UNAVAILABLE",
    });
  }
  if (initialPortalDecision.kind !== "allow") {
    throw Object.assign(new Error("目前沒有可管理的 Portaly 訂閱，請先重新同步。"), {
      statusCode: 409,
      code: "PORTAL_SUBSCRIPTION_UNAVAILABLE",
    });
  }
  const customerLockId = customerSubscriptionKey({
    email: user.email,
    planId: PORTALY_PLAN_ID,
    mode,
  });
  if (!customerLockId) {
    throw Object.assign(new Error("無法確認訂閱帳號，請重新登入後再試。"), {
      statusCode: 409,
      code: "CUSTOMER_SUBSCRIPTION_KEY_INVALID",
    });
  }
  const customerLockRef = db.collection("checkoutLocks").doc(customerLockId);
  const operationId = randomUUID();
  const reservation = createPortalSessionReservation({operationId, mode});

  await db.runTransaction(async (transaction) => {
    const [latestUserSnapshot, customerLockSnapshot] = await Promise.all([
      transaction.get(userRef),
      transaction.get(customerLockRef),
    ]);
    const latestUser = latestUserSnapshot.data() || {};
    const customerLock = customerLockSnapshot.data() || null;
    const transactionNow = Date.now();
    if (portalAccessDecision({
      data: latestUser,
      expectedMode: mode,
      expectedPlanId: PORTALY_PLAN_ID,
    }).kind !== "allow") {
      throw Object.assign(new Error("目前沒有可管理的 Portaly 訂閱，請先重新同步。"), {
        statusCode: 409,
        code: "PORTAL_SUBSCRIPTION_UNAVAILABLE",
      });
    }
    const deletionStatus = customerLock?.status === "account_deleting" ||
      customerLock?.status === "account_deleted";
    const deletionHoldUntilMs = Number(customerLock?.safetyHoldUntilMs);
    if (deletionStatus &&
        (!Number.isFinite(deletionHoldUntilMs) || deletionHoldUntilMs > transactionNow)) {
      throw Object.assign(new Error("帳號刪除作業正在處理中，無法開啟訂閱管理。"), {
        statusCode: 409,
        code: "ACCOUNT_DELETION_IN_PROGRESS",
      });
    }
    const portalDecision = portalSessionGuardDecision(latestUser.portalSession, {
      mode,
      now: transactionNow,
    });
    if (portalDecision.kind === "pending_portal") {
      throw Object.assign(new Error("訂閱管理頁仍在有效期間內，請使用已開啟的頁面。"), {
        statusCode: 409,
        code: "PORTAL_SESSION_ACTIVE",
      });
    }
    if (portalDecision.kind === "portal_state_invalid") {
      throw Object.assign(new Error("訂閱管理狀態尚未確認，請稍後再試。"), {
        statusCode: 409,
        code: "PORTAL_SESSION_STATE_INVALID",
      });
    }
    transaction.set(userRef, {
      portalSession: {
        ...reservation,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      },
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
  });

  reportSkillVersion(apiKey);
  let portalyResponse;
  let payload;
  try {
    ({response: portalyResponse, payload} = await portalyRequest(
      "/api/creator-subscription/portal-sessions",
      {
        apiKey,
        method: "POST",
        body: {customerEmail: user.email, returnUrl: `${PUBLIC_BASE_URL}/payment/account/`},
      },
    ));
  } catch (error) {
    logger.error("Portaly portal request threw", {
      message: error?.message || "Unknown error",
      operationId,
    });
    throw Object.assign(new Error("目前無法確認訂閱管理頁是否建立，請稍後再試。"), {
      statusCode: 502,
      code: "PORTAL_SESSION_CREATION_UNCERTAIN",
    });
  }
  if (!portalyResponse.ok) {
    logger.error("Portaly portal request failed", {
      status: portalyResponse.status,
      code: payload?.code || null,
      operationId,
    });
    throw Object.assign(new Error("目前無法開啟訂閱管理，請稍後再試。"), {
      statusCode: 502,
      code: "PORTAL_SESSION_CREATION_FAILED",
    });
  }

  let validatedPortal;
  try {
    validatedPortal = validatePortalSessionResponse(payload?.data, {
      operationId,
      mode,
      reservationBlockUntilMs: reservation.blockUntilMs,
    });
  } catch (error) {
    logger.error("Portaly portal response is invalid", {
      code: error?.code || null,
      operationId,
    });
    throw Object.assign(new Error("訂閱管理頁回應格式不正確，請稍後再試。"), {
      statusCode: 502,
      code: "PORTAL_SESSION_RESPONSE_INVALID",
    });
  }

  await db.runTransaction(async (transaction) => {
    const [latestUserSnapshot, customerLockSnapshot] = await Promise.all([
      transaction.get(userRef),
      transaction.get(customerLockRef),
    ]);
    const latestPortal = latestUserSnapshot.data()?.portalSession;
    if (!latestUserSnapshot.exists || latestPortal?.operationId !== operationId ||
        latestPortal?.status !== "creating") {
      throw Object.assign(new Error("訂閱管理狀態已變更，請稍後再試。"), {
        statusCode: 409,
        code: "PORTAL_SESSION_RESERVATION_LOST",
      });
    }
    const customerLock = customerLockSnapshot.data() || null;
    const deletionStatus = customerLock?.status === "account_deleting" ||
      customerLock?.status === "account_deleted";
    const deletionHoldUntilMs = Number(customerLock?.safetyHoldUntilMs);
    if (deletionStatus &&
        (!Number.isFinite(deletionHoldUntilMs) || deletionHoldUntilMs > Date.now())) {
      throw Object.assign(new Error("帳號刪除作業正在處理中，無法開啟訂閱管理。"), {
        statusCode: 409,
        code: "ACCOUNT_DELETION_IN_PROGRESS",
      });
    }
    transaction.set(userRef, {
      portalSession: {
        ...validatedPortal.record,
        createdAt: latestPortal.createdAt || FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      },
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
  });

  return json(response, 201, {
    portalUrl: validatedPortal.portalUrl,
    expiresAt: validatedPortal.record.expiresAt,
  });
}

async function deleteAccount(request, response) {
  const user = await requireFirebaseUser(request);
  const userRef = db.collection("users").doc(user.uid);
  const grantRef = entitlementGrantRef(user.uid);
  const apiKey = PORTALY_API_KEY.value();
  const mode = requirePortalyMode(apiKey);
  const checkoutLocks = db.collection("checkoutLocks");
  const customerLockId = customerSubscriptionKey({
    email: user.email,
    planId: PORTALY_PLAN_ID,
    mode,
  });
  if (!customerLockId) {
    throw Object.assign(new Error("無法確認訂閱帳號，請重新登入後再試。"), {
      statusCode: 409,
      code: "CUSTOMER_SUBSCRIPTION_KEY_INVALID",
    });
  }

  const customerLockRef = checkoutLocks.doc(customerLockId);
  const legacyLockRefs = [
    checkoutLocks.doc(checkoutLockDocumentId(user.uid, PORTALY_PLAN_ID, mode)),
    checkoutLocks.doc(checkoutLockDocumentId(user.uid, PORTALY_PLAN_ID)),
  ].filter((ref, index, refs) =>
    refs.findIndex((candidate) => candidate.path === ref.path) === index,
  );
  const sessionsQuery = db.collection("checkoutSessions")
    .where("uid", "==", user.uid);
  const locksQuery = checkoutLocks
    .where("uid", "==", user.uid);
  const deletionId = randomUUID();
  const accountUidHash = createHash("sha256").update(user.uid).digest("hex");

  const deletionReservation = await db.runTransaction(async (transaction) => {
    const transactionNow = Date.now();
    const [
      userSnapshot,
      customerLockSnapshot,
      sessionsSnapshot,
      locksSnapshot,
      ...legacyLockSnapshots
    ] = await Promise.all([
      transaction.get(userRef),
      transaction.get(customerLockRef),
      transaction.get(sessionsQuery),
      transaction.get(locksQuery),
      ...legacyLockRefs.map((ref) => transaction.get(ref)),
    ]);
    const subscription = userSnapshot.data() || {};
    if (completedAccountDeletionMatches(customerLockSnapshot.data() || null, {
      accountUidHash,
      planId: PORTALY_PLAN_ID,
      mode,
    })) {
      return {kind: "complete_auth_deletion"};
    }
    if (!user.emailVerified && unverifiedDeletionNeedsEmailVerification(
      subscription,
      {expectedMode: mode},
    )) {
      throw Object.assign(new Error("請先完成電子郵件驗證，才能停止 Pro 續訂並刪除會員。"), {
        statusCode: 403,
        code: "EMAIL_NOT_VERIFIED",
      });
    }

    const guard = accountDeletionGuardDecision({
      customerLock: customerLockSnapshot.data() || null,
      legacyLocks: [
        ...legacyLockSnapshots.map((snapshot) => snapshot.data() || null),
        ...locksSnapshot.docs.map((doc) => doc.data()),
      ],
      sessions: sessionsSnapshot.docs.map((doc) => doc.data()),
      portalSession: subscription.portalSession,
      planId: PORTALY_PLAN_ID,
      mode,
      now: transactionNow,
    });
    if (guard.kind === "safety_hold") {
      throw Object.assign(new Error("付款或刪帳狀態尚未確認，為避免重複扣款，暫時無法刪除帳號。"), {
        statusCode: 409,
        code: "CHECKOUT_SAFETY_HOLD",
      });
    }
    if (guard.kind === "pending_checkout") {
      throw Object.assign(new Error("目前仍有尚未完成的付款流程，請完成或等待流程到期後再刪除帳號。"), {
        statusCode: 409,
        code: "PENDING_CHECKOUT_EXISTS",
      });
    }
    if (guard.kind === "pending_portal") {
      throw Object.assign(new Error("訂閱管理頁仍在有效期間內，請等待頁面到期後再刪除帳號。"), {
        statusCode: 409,
        code: "PORTAL_SESSION_ACTIVE",
      });
    }
    if (guard.kind === "portal_state_invalid") {
      throw Object.assign(new Error("訂閱管理狀態尚未確認，因此尚未刪除帳號，請稍後再試。"), {
        statusCode: 409,
        code: "PORTAL_SESSION_STATE_INVALID",
      });
    }

    transaction.set(customerLockRef, {
      uid: user.uid,
      accountUidHash,
      planId: PORTALY_PLAN_ID,
      mode,
      status: "account_deleting",
      deletionId,
      safetyHoldUntilMs: transactionNow + CHECKOUT_UNCERTAIN_HOLD_MS,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.set(userRef, {
      accountDeleting: true,
      accountDeletionId: deletionId,
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    return {kind: "reserved"};
  });

  if (deletionReservation.kind === "complete_auth_deletion") {
    try {
      await auth.deleteUser(user.uid);
    } catch (error) {
      if (error?.code !== "auth/user-not-found") throw error;
    }
    return json(response, 200, {deleted: true, canceledSubscriptions: 0});
  }

  let canceledSubscriptionIds = [];

  if (user.emailVerified) {
    reportSkillVersion(apiKey);
    try {
      const customerSubscriptions = await listCustomerSubscriptions({
        apiKey,
        customerEmail: user.email,
      });
      canceledSubscriptionIds = selectSubscriptionIdsToCancel(customerSubscriptions, {
        email: user.email,
        planId: PORTALY_PLAN_ID,
        mode,
      });

      for (const subscriptionId of canceledSubscriptionIds) {
        const {response: cancelResponse, payload: cancelPayload} = await portalyRequest(
          `/api/creator-subscription/subscriptions/${encodeURIComponent(subscriptionId)}/cancel`,
          {
            apiKey,
            method: "POST",
            body: {
              reason: "customer_requested",
              reasonNote: "UFOGeo account deletion",
            },
          },
        );
        if (!cancelResponse.ok) {
          throw Object.assign(new Error("Portaly cancellation failed"), {
            code: "SUBSCRIPTION_CANCEL_FAILED",
            portalyStatus: cancelResponse.status,
            portalyCode: cancelPayload?.code || null,
            subscriptionId,
          });
        }
        try {
          validateSubscriptionCancellationResponse(
            portalySubscriptionValue(cancelPayload),
            {subscriptionId},
          );
        } catch (error) {
          throw Object.assign(new Error("Portaly cancellation response is invalid"), {
            code: "SUBSCRIPTION_CANCEL_FAILED",
            cancellationValidationCode: error?.code || null,
            portalyStatus: cancelResponse.status,
            portalyCode: cancelPayload?.code || null,
            subscriptionId,
          });
        }
      }
    } catch (error) {
      await releaseAccountDeletionLock(customerLockRef, userRef, deletionId);
      logger.error("Portaly subscriptions could not be canceled before account deletion", {
        code: error?.code || null,
        portalyStatus: error?.portalyStatus || null,
        portalyCode: error?.portalyCode || null,
        subscriptionId: error?.subscriptionId || null,
      });
      const cancellationFailed = error?.code === "SUBSCRIPTION_CANCEL_FAILED";
      throw Object.assign(new Error(cancellationFailed ?
        "目前無法停止所有 Pro 續訂，因此尚未刪除會員，請稍後再試。" :
        "目前無法確認所有 Pro 訂閱，因此尚未刪除會員，請稍後再試。"), {
        statusCode: 502,
        code: cancellationFailed ? "SUBSCRIPTION_CANCEL_FAILED" : "SUBSCRIPTION_LIST_FAILED",
      });
    }
  }

  const finalization = await db.runTransaction(async (transaction) => {
    const [
      customerLockSnapshot,
      latestUserSnapshot,
      sessions,
      locks,
      grantSnapshot,
      ...legacyLockSnapshots
    ] = await Promise.all([
      transaction.get(customerLockRef),
      transaction.get(userRef),
      transaction.get(sessionsQuery),
      transaction.get(locksQuery),
      transaction.get(grantRef),
      ...legacyLockRefs.map((ref) => transaction.get(ref)),
    ]);
    const customerLock = customerLockSnapshot.data();
    if (!customerLockSnapshot.exists || customerLock?.status !== "account_deleting" ||
        customerLock.deletionId !== deletionId) {
      throw Object.assign(new Error("刪帳狀態已變更，尚未刪除會員。"), {
        statusCode: 409,
        code: "ACCOUNT_DELETION_LOCK_LOST",
      });
    }
    const latestUser = latestUserSnapshot.data() || {};
    if (!latestUserSnapshot.exists || latestUser.accountDeleting !== true ||
        latestUser.accountDeletionId !== deletionId) {
      throw Object.assign(new Error("刪帳狀態已變更，尚未刪除會員。"), {
        statusCode: 409,
        code: "ACCOUNT_DELETION_LOCK_LOST",
      });
    }

    const portalDecision = portalSessionGuardDecision(
      latestUser.portalSession,
      {mode, now: Date.now()},
    );
    if (portalDecision.kind !== "safe") {
      transaction.delete(customerLockRef);
      transaction.set(userRef, {
        accountDeleting: FieldValue.delete(),
        accountDeletionId: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
      return {kind: portalDecision.kind};
    }

    transaction.delete(userRef);
    // A server grant is independent of Portaly state but must not survive an
    // account deletion.  Keep it in this same transaction so a partially
    // deleted account cannot retain a free Pro entitlement.
    if (grantSnapshot.exists) transaction.delete(grantRef);
    for (const session of sessions.docs) {
      transaction.set(session.ref, {
        uid: FieldValue.delete(),
        customerEmail: FieldValue.delete(),
        checkoutUrl: FieldValue.delete(),
        checkoutToken: FieldValue.delete(),
        checkoutLeaseId: FieldValue.delete(),
        checkoutLockId: FieldValue.delete(),
        lockId: FieldValue.delete(),
        accountDeleted: true,
        accountDeletionId: deletionId,
        accountDeletedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    const lockRefsToDelete = [
      ...locks.docs.map((doc) => doc.ref),
      ...legacyLockSnapshots.map((snapshot) => snapshot.ref),
    ].filter((ref, index, refs) =>
      ref.path !== customerLockRef.path &&
      refs.findIndex((candidate) => candidate.path === ref.path) === index,
    );
    for (const lockRef of lockRefsToDelete) transaction.delete(lockRef);
    const tombstoneWrite = accountDeletionTombstoneWrite({
      accountUidHash,
      uid: FieldValue.delete(),
      deletionId: FieldValue.delete(),
      planId: PORTALY_PLAN_ID,
      mode,
      status: "account_deleted",
      safetyHoldUntilMs: Date.now() + CHECKOUT_UNCERTAIN_HOLD_MS,
      accountDeletedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.set(customerLockRef, tombstoneWrite.data, tombstoneWrite.options);
    return {kind: "deleted"};
  });

  if (finalization.kind === "pending_portal") {
    throw Object.assign(new Error("訂閱管理頁仍在有效期間內，請等待頁面到期後再刪除帳號。"), {
      statusCode: 409,
      code: "PORTAL_SESSION_ACTIVE",
    });
  }
  if (finalization.kind === "portal_state_invalid") {
    throw Object.assign(new Error("訂閱管理狀態尚未確認，因此尚未刪除帳號，請稍後再試。"), {
      statusCode: 409,
      code: "PORTAL_SESSION_STATE_INVALID",
    });
  }

  try {
    await auth.deleteUser(user.uid);
  } catch (error) {
    if (error?.code !== "auth/user-not-found") throw error;
  }
  return json(response, 200, {
    deleted: true,
    canceledSubscriptions: canceledSubscriptionIds.length,
  });
}

async function compensateDeletedAccountSubscription(compensation) {
  const compensationRef = db.collection("portalyCompensations").doc(compensation.id);
  const leaseId = randomUUID();
  const claim = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(compensationRef);
    if (!snapshot.exists || snapshot.data()?.status === "completed") {
      return {kind: "complete"};
    }
    const current = snapshot.data() || {};
    const leaseExpiresAtMs = Number(current.leaseExpiresAtMs);
    if (current.status === "processing" && Number.isFinite(leaseExpiresAtMs) &&
        leaseExpiresAtMs > Date.now()) {
      return {kind: "in_progress"};
    }
    const verifyFirst = current.requiresStatusCheck === true || current.status === "processing";
    transaction.set(compensationRef, {
      status: "processing",
      leaseId,
      leaseExpiresAtMs: Date.now() + DELETED_ACCOUNT_CANCELLATION_LEASE_MS,
      attempts: Number.isInteger(current.attempts) ? current.attempts + 1 : 1,
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    return {kind: "claimed", verifyFirst};
  });

  if (claim.kind === "complete") return;
  if (claim.kind === "in_progress") {
    throw Object.assign(new Error("Deleted-account cancellation is already processing"), {
      statusCode: 503,
      code: "DELETED_ACCOUNT_CANCELLATION_IN_PROGRESS",
    });
  }

  try {
    const apiKey = PORTALY_API_KEY.value();
    const mode = requirePortalyMode(apiKey);
    if (mode !== compensation.mode) {
      throw Object.assign(new Error("Deleted-account cancellation mode mismatch"), {
        code: "DELETED_ACCOUNT_CANCELLATION_MODE_MISMATCH",
      });
    }
    reportSkillVersion(apiKey);
    if (claim.verifyFirst) {
      const {response: statusResponse, payload: statusPayload} = await portalyRequest(
        `/api/creator-subscription/subscriptions/${encodeURIComponent(compensation.subscriptionId)}`,
        {apiKey},
      );
      if (!statusResponse.ok) {
        throw Object.assign(new Error("Deleted-account subscription status request failed"), {
          code: "DELETED_ACCOUNT_STATUS_FAILED",
          portalyStatus: statusResponse.status,
          portalyCode: statusPayload?.code || null,
        });
      }
      const remote = portalySubscriptionValue(statusPayload);
      const remoteId = nonBlankString(remote?.id) || nonBlankString(remote?.subscriptionId);
      const remoteMode = nonBlankString(remote?.mode);
      const remoteStatus = nonBlankString(remote?.status);
      if (!remote || remoteId !== compensation.subscriptionId ||
          remotePlanId(remote) !== compensation.planId || remoteMode !== compensation.mode ||
          typeof remote.cancelAtPeriodEnd !== "boolean" || !remoteStatus) {
        throw Object.assign(new Error("Deleted-account subscription status is invalid"), {
          code: "DELETED_ACCOUNT_STATUS_INVALID",
        });
      }
      if (remote.cancelAtPeriodEnd === true || remoteStatus === "canceled") {
        await db.runTransaction(async (transaction) => {
          const snapshot = await transaction.get(compensationRef);
          if (!snapshot.exists || snapshot.data()?.leaseId !== leaseId) return;
          transaction.set(compensationRef, {
            status: "completed",
            leaseId: FieldValue.delete(),
            leaseExpiresAtMs: FieldValue.delete(),
            requiresStatusCheck: FieldValue.delete(),
            completedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          }, {merge: true});
        });
        return;
      }
    }
    const {response: cancelResponse, payload: cancelPayload} = await portalyRequest(
      `/api/creator-subscription/subscriptions/${encodeURIComponent(compensation.subscriptionId)}/cancel`,
      {
        apiKey,
        method: "POST",
        body: {
          reason: "customer_requested",
          reasonNote: "UFOGeo deleted-account renewal protection",
        },
      },
    );
    if (!cancelResponse.ok) {
      throw Object.assign(new Error("Deleted-account subscription cancellation failed"), {
        code: "DELETED_ACCOUNT_CANCELLATION_FAILED",
        portalyStatus: cancelResponse.status,
        portalyCode: cancelPayload?.code || null,
      });
    }
    try {
      validateSubscriptionCancellationResponse(
        portalySubscriptionValue(cancelPayload),
        {subscriptionId: compensation.subscriptionId},
      );
    } catch (error) {
      throw Object.assign(new Error("Deleted-account cancellation response is invalid"), {
        code: "DELETED_ACCOUNT_CANCELLATION_RESPONSE_INVALID",
        cancellationValidationCode: error?.code || null,
      });
    }

    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(compensationRef);
      if (!snapshot.exists || snapshot.data()?.leaseId !== leaseId) return;
      transaction.set(compensationRef, {
        status: "completed",
        leaseId: FieldValue.delete(),
        leaseExpiresAtMs: FieldValue.delete(),
        requiresStatusCheck: FieldValue.delete(),
        completedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    });
  } catch (error) {
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(compensationRef);
      if (!snapshot.exists || snapshot.data()?.leaseId !== leaseId) return;
      transaction.set(compensationRef, {
        status: "retry_pending",
        leaseId: FieldValue.delete(),
        leaseExpiresAtMs: FieldValue.delete(),
        requiresStatusCheck: true,
        lastErrorCode: error?.code || "DELETED_ACCOUNT_CANCELLATION_FAILED",
        lastPortalyStatus: error?.portalyStatus || null,
        lastPortalyCode: error?.portalyCode || null,
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    });
    logger.error("Deleted-account subscription could not be canceled", {
      subscriptionId: compensation.subscriptionId,
      mode: compensation.mode,
      code: error?.code || null,
      portalyStatus: error?.portalyStatus || null,
      portalyCode: error?.portalyCode || null,
    });
    throw Object.assign(new Error("Deleted-account cancellation remains pending"), {
      statusCode: 503,
      code: "DELETED_ACCOUNT_CANCELLATION_PENDING",
    });
  }
}

async function processCallback(request, response) {
  const payload = requireJsonBody(request);
  const verified = verifyCallbackEnvelope({
    headers: request.headers,
    payload,
    secret: PORTALY_CALLBACK_SECRET.value(),
  });
  const event = verified.event;
  validateCallbackPayload(event, payload);
  const callbackIdentifier = subscriptionIdentifier(payload);
  if (!callbackIdentifier) {
    throw new CallbackError(400, "Callback has no session or subscription identifier");
  }
  const expectedMode = requirePortalyMode(PORTALY_API_KEY.value());

  const isCheckoutFailure = event === "creator_subscription.checkout.failed";
  const isRefundEvent = event === "creator_subscription.payment.refunded" ||
    event === "creator_subscription.payment.refund_failed";
  const sessionRef = db.collection("checkoutSessions").doc(callbackIdentifier);
  const identity = eventIdentity(payload);
  const eventRef = identity ? db.collection("portalyEvents").doc(
    createHash("sha256").update(identity).digest("hex"),
  ) : null;

  const result = await db.runTransaction(async (transaction) => {
    const [sessionSnapshot, eventSnapshot] = await Promise.all([
      transaction.get(sessionRef),
      eventRef ? transaction.get(eventRef) : Promise.resolve(null),
    ]);
    if (!sessionSnapshot.exists) {
      throw new CallbackError(503, "Checkout session is not available yet");
    }

    const session = sessionSnapshot.data();
    if (!callbackMatchesCheckoutSession(session, payload, {
      expectedPlanId: PORTALY_PLAN_ID,
    })) {
      throw new CallbackError(400, "Callback does not match checkout session");
    }
    const lockPlanId = payload.planId || session.planId;
    const callbackMode = payload.mode || session.mode;
    // Refund outcomes are payment-order facts, not subscription state.  They
    // must be acknowledged and audited independently because Portaly may
    // deliver them before or after a separate canceled callback.
    if (isRefundEvent) {
      if (!eventRef) {
        throw new CallbackError(400, "Refund callback has no order identity");
      }
      if (eventSnapshot?.exists) {
        return {duplicate: true};
      }
      const receivedAt = FieldValue.serverTimestamp();
      const orderId = payload.orderId.trim();
      transaction.create(eventRef, {
        identity,
        event,
        sessionId: payload.sessionId || callbackIdentifier,
        subscriptionId: payload.subscriptionId || callbackIdentifier,
        orderId,
        paymentId: payload.paymentId || null,
        paymentReference: payload.paymentReference || null,
        mode: payload.mode || session.mode || null,
        receivedAt: verified.timestamp,
      });
      transaction.create(db.collection("portalyAudit").doc(), compact({
        uid: session.uid,
        event,
        orderId,
        sessionId: payload.sessionId || callbackIdentifier,
        subscriptionId: payload.subscriptionId || callbackIdentifier,
        planId: payload.planId || session.planId || null,
        merchantOrderNumber: payload.orderMerchantOrderNumber ||
          session.merchantOrderNumber || null,
        paymentId: payload.paymentId || null,
        paymentReference: payload.paymentReference || null,
        amount: payload.amount,
        currency: payload.currency,
        refundedAmount: payload.refundedAmount,
        refundRequestedAt: payload.refundRequestedAt,
        refundRequestedBy: payload.refundRequestedBy,
        refundReason: payload.refundReason,
        refundReasonNote: payload.refundReasonNote,
        refundProvider: payload.refundProvider,
        refundReference: payload.refundReference,
        refundedAt: payload.refundedAt,
        refundFailedAt: payload.refundFailedAt,
        refundFailureReason: payload.refundFailureReason,
        refundFailureRetryable: payload.refundFailureRetryable,
        subscriptionCanceledByRefund: payload.subscriptionCanceledByRefund,
        mode: callbackMode || null,
        receivedAt,
      }));
      return {duplicate: false, refundOnly: true};
    }
    const callbackMatchesDeployment = callbackModeMatchesDeployment(
      callbackMode,
      expectedMode,
    );
    const state = subscriptionStateForEvent(event, payload);
    const stateTimestampMs = callbackStateTimestampMs(
      event,
      payload,
      verified.timestampMs,
    );
    const checkoutLocks = db.collection("checkoutLocks");
    const storedLockId = nonBlankString(session.checkoutLockId);
    const customerLockRef = storedLockId && !storedLockId.includes("/") ? checkoutLocks
      .doc(storedLockId) : null;
    const modeLockRef = session.uid && lockPlanId && callbackMode ? checkoutLocks
      .doc(checkoutLockDocumentId(session.uid, lockPlanId, callbackMode)) : null;
    const legacyLockRef = session.uid && lockPlanId ? checkoutLocks
      .doc(checkoutLockDocumentId(session.uid, lockPlanId)) : null;
    const lockRefs = [customerLockRef, modeLockRef, legacyLockRef].filter((ref, index, refs) =>
      ref && refs.findIndex((candidate) => candidate.path === ref.path) === index,
    );
    const userRef = session.accountDeleted === true || !session.uid ? null :
      db.collection("users").doc(session.uid);
    const grantRef = userRef ? entitlementGrantRef(session.uid) : null;
    const [lockSnapshots, userSnapshot, grantSnapshot] = await Promise.all([
      Promise.all(lockRefs.map((ref) => transaction.get(ref))),
      userRef ? transaction.get(userRef) : Promise.resolve(null),
      grantRef ? transaction.get(grantRef) : Promise.resolve(null),
    ]);
    const currentUser = userSnapshot?.data() || {};
    const accountDeletionId = nonBlankString(session.accountDeletionId) ||
      nonBlankString(currentUser.accountDeletionId) || "legacy-deleted-account";
    const needsDeletedAccountCancellation = deletedAccountCallbackNeedsCancellation({
      accountDeleted: callbackMatchesDeployment &&
        (session.accountDeleted === true || currentUser.accountDeleting === true),
      subscriptionStatus: state.subscriptionStatus,
      cancelAtPeriodEnd: state.cancelAtPeriodEnd,
    });
    const compensationId = needsDeletedAccountCancellation ? createHash("sha256")
      .update(`${callbackIdentifier}:${accountDeletionId}`)
      .digest("hex") : null;
    const compensationRef = compensationId ?
      db.collection("portalyCompensations").doc(compensationId) : null;
    const compensationSnapshot = compensationRef ?
      await transaction.get(compensationRef) : null;
    const matchingLockRefs = callbackMatchesDeployment ? lockRefs.filter((ref, index) =>
      checkoutLockMatchesSession(
        lockSnapshots[index]?.data() || null,
        callbackIdentifier,
      )) : [];
    if (compensationRef && !compensationSnapshot?.exists) {
      transaction.create(compensationRef, {
        subscriptionId: callbackIdentifier,
        planId: lockPlanId,
        mode: callbackMode,
        accountDeletionId,
        sourceEvent: event,
        sourceTimestampMs: stateTimestampMs,
        status: "pending",
        attempts: 0,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    if (eventSnapshot?.exists) {
      for (const lockRef of matchingLockRefs) transaction.delete(lockRef);
      return {duplicate: true};
    }

    const shouldApply = shouldApplyCallbackUpdate(session, state, stateTimestampMs);
    const effectiveState = resolveEntitlement({
      grant: grantSnapshot?.exists ? grantSnapshot.data() : null,
      portalyState: {
        ...state,
        mode: callbackMode,
        planId: payload.planId || session.planId,
      },
      expectedMode,
      expectedPlanId: PORTALY_PLAN_ID,
    });
    const shouldApplyUser = Boolean(
      shouldApply &&
      callbackMatchesDeployment &&
      userRef &&
      userSnapshot?.exists &&
      currentUser.accountDeleting !== true &&
      shouldApplyUserSubscriptionUpdate(currentUser, callbackIdentifier, {
        mode: callbackMode,
      }),
    );
    const now = FieldValue.serverTimestamp();

    if (eventRef) {
      transaction.create(eventRef, {
        identity,
        event,
        sessionId: payload.sessionId || null,
        subscriptionId: payload.subscriptionId || null,
        paymentId: payload.paymentId || null,
        paymentReference: payload.paymentReference || null,
        mode: payload.mode || session.mode || null,
        receivedAt: verified.timestamp,
      });
    }
    if (shouldApply) {
      transaction.set(sessionRef, compact({
        status: state.subscriptionStatus,
        lastEvent: event,
        lastCallbackAtMs: stateTimestampMs,
        paymentReference: payload.paymentReference,
        paymentMethod: payload.paymentMethod,
        nextBillingAt: payload.nextBillingAt,
        cancelAtPeriodEnd: state.cancelAtPeriodEnd,
        cancelEffectiveAt: payload.cancelEffectiveAt,
        failureCount: payload.failureCount,
        failureReason: payload.failureReason,
        failedAt: payload.failedAt,
        mode: callbackMode,
        subscriptionId: isCheckoutFailure ? FieldValue.delete() : callbackIdentifier,
        updatedAt: now,
      }), {merge: true});
    }
    for (const lockRef of matchingLockRefs) transaction.delete(lockRef);
    if (shouldApplyUser) {
      transaction.set(userRef, compact({
        email: session.customerEmail,
        // Callback processing owns only Portaly state.  A server grant is
        // resolved at the API boundary and is never copied into users.proActive
        // or allowed to be revoked by a provider callback.
        proActive: state.proActive,
        subscriptionStatus: state.subscriptionStatus,
        lastCallbackAtMs: stateTimestampMs,
        subscriptionId: isCheckoutFailure ? FieldValue.delete() : callbackIdentifier,
        currentCheckoutSessionId: callbackIdentifier,
        planId: payload.planId || session.planId,
        mode: payload.mode || session.mode,
        nextBillingAt: payload.nextBillingAt,
        cancelAtPeriodEnd: state.cancelAtPeriodEnd,
        cancelEffectiveAt: payload.cancelEffectiveAt,
        lastPaymentAt: payload.chargedAt || payload.completedAt,
        lastFailureReason: payload.failureReason,
        lastFailureAt: payload.failedAt,
        updatedAt: now,
      }), {merge: true});
    }
    transaction.set(db.collection("portalyAudit").doc(), compact({
      uid: session.uid,
      accountDeleted: session.accountDeleted === true ? true : undefined,
      event,
      sessionId: payload.sessionId || null,
      subscriptionId: payload.subscriptionId || null,
      merchantOrderNumber: payload.merchantOrderNumber || session.merchantOrderNumber || null,
      paymentId: payload.paymentId || null,
      paymentReference: payload.paymentReference || null,
      amount: payload.amount,
      currency: payload.currency,
      chargedAt: payload.chargedAt,
      failedAt: payload.failedAt,
      status: state.subscriptionStatus,
      failureReason: payload.failureReason,
      mode: callbackMode || null,
      appliedToSession: shouldApply,
      appliedToCurrentUser: shouldApplyUser,
      entitlementSource: effectiveState.entitlementSource,
      currentSubscriptionId: currentUser.subscriptionId,
      receivedAt: now,
    }));
    return {
      duplicate: !shouldApply,
      userEntitlementSkipped: Boolean(shouldApply && userRef && !shouldApplyUser),
    };
  });

  return json(response, 200, {
    received: true,
    duplicate: result.duplicate,
    userEntitlementSkipped: result.userEntitlementSkipped || undefined,
  });
}

export const retryPortalyCompensation = onDocumentWritten(
  {
    document: "portalyCompensations/{compensationId}",
    secrets: [PORTALY_API_KEY],
    retry: true,
    maxInstances: 2,
    timeoutSeconds: 60,
  },
  async (event) => {
    const value = event.data?.after?.data();
    // Only the first durable `pending` write starts work. Internal processing,
    // completion, and retry bookkeeping writes must not create a hot loop;
    // platform retries re-deliver the original pending event after failures.
    if (value?.status !== "pending") return;
    const compensationId = nonBlankString(event.params?.compensationId);
    const subscriptionId = nonBlankString(value.subscriptionId);
    const planId = nonBlankString(value.planId);
    const mode = nonBlankString(value.mode);
    if (!compensationId || !subscriptionId || !planId ||
        (mode !== "live" && mode !== "test")) {
      logger.error("Portaly compensation record is invalid", {compensationId});
      return;
    }
    await compensateDeletedAccountSubscription({
      id: compensationId,
      subscriptionId,
      planId,
      mode,
    });
  },
);

export const api = onRequest(
  {secrets: [PORTALY_API_KEY, PORTALY_CALLBACK_SECRET]},
  async (request, response) => {
    try {
      if (request.method === "GET" && pathMatches(request, "/api/health")) {
        return json(response, 200, {ok: true, project: PROJECT_ID, region: "asia-east1"});
      }
      if (request.method === "POST" && pathMatches(request, "/api/portaly/checkout")) {
        return await createCheckout(request, response);
      }
      if (request.method === "GET" && pathMatches(request, "/api/portaly/subscription")) {
        return await getSubscription(request, response);
      }
      if (request.method === "POST" && pathMatches(request, "/api/portaly/subscription/reconcile")) {
        return await reconcileSubscription(request, response);
      }
      if (request.method === "POST" && pathMatches(request, "/api/portaly/portal")) {
        return await createPortal(request, response);
      }
      if (request.method === "DELETE" && pathMatches(request, "/api/account")) {
        return await deleteAccount(request, response);
      }
      if (request.method === "POST" && pathMatches(request, "/api/portaly/callback")) {
        return await processCallback(request, response);
      }
      return json(response, 404, {error: "Not found"});
    } catch (error) {
      const status = error?.statusCode || 500;
      if (status >= 500) logger.error("Request failed", {message: error?.message || "Unknown error"});
      return json(response, status, compact({
        error: status >= 500 ? "暫時無法完成操作，請稍後再試。" : error.message,
        code: error?.code,
      }));
    }
  },
);
