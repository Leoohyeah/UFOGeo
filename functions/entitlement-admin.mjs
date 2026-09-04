#!/usr/bin/env node

import {randomUUID} from "node:crypto";
import {fileURLToPath} from "node:url";

import {getAuth} from "firebase-admin/auth";
import {FieldValue, getFirestore, Timestamp} from "firebase-admin/firestore";
import {applicationDefault, initializeApp} from "firebase-admin/app";

import {
  checkoutGrantDecision,
  checkoutLockDocumentId,
} from "./checkout-idempotency.mjs";
import {customerSubscriptionKey} from "./customer-subscription-guard.mjs";
import {
  ENTITLEMENT_SOURCES,
  grantKinds,
  resolveEntitlement,
  validateEntitlementGrant,
} from "./entitlement-resolver.mjs";

const MAX_REASON_LENGTH = 500;
const SENSITIVE_ARGUMENT = /(secret|token|password|credential|private[-_]?key)/i;
const PORTALY_PLAN_ID = "JO5cmDQdqTtb6AkkcnNW";
const PORTALY_MODES = ["live", "test"];

function fail(message) {
  throw new Error(message);
}

function nonBlank(value, label) {
  if (typeof value !== "string" || value.trim().length === 0) {
    fail(`${label} must be a non-empty value`);
  }
  return value.trim();
}

function parseTimestamp(value, label) {
  const normalized = nonBlank(value, label);
  const parsed = Date.parse(normalized);
  if (!Number.isFinite(parsed)) fail(`${label} must be a valid ISO date`);
  return new Date(parsed);
}

export function entitlementGrantCheckoutGuardDecision(options = {}) {
  return checkoutGrantDecision({...options, planId: options.planId || PORTALY_PLAN_ID});
}

function usage() {
  return [
    "Usage:",
    "  node entitlement-admin.mjs grant --project ufogeo-adac7 --email member@example.com --kind lifetime_pro --granted-by operator --reason \"support grant\" [--apply]",
    "  node entitlement-admin.mjs grant --project ufogeo-adac7 --email member@example.com --kind temporary_pro --expires-at 2026-12-31T00:00:00Z --granted-by operator --reason \"promotion\" [--apply]",
    "  node entitlement-admin.mjs revoke --project ufogeo-adac7 --email member@example.com --revoked-by operator [--reason \"requested\"] [--apply]",
    "  node entitlement-admin.mjs status --project ufogeo-adac7 --email member@example.com",
    "",
    "grant/revoke default to dry-run. Add --apply only after reviewing the output.",
    "Credentials are read from Application Default Credentials; never pass secrets or tokens as arguments.",
  ].join("\n");
}

/** Parse CLI arguments without touching Firebase, for safe syntax checks. */
export function parseEntitlementAdminArgs(argv = []) {
  const options = {
    command: null,
    project: null,
    email: null,
    kind: null,
    expiresAt: null,
    grantedBy: null,
    revokedBy: null,
    reason: null,
    apply: false,
    help: false,
  };
  const valueFlags = new Map([
    ["--project", "project"],
    ["--email", "email"],
    ["--kind", "kind"],
    ["--expires-at", "expiresAt"],
    ["--granted-by", "grantedBy"],
    ["--revoked-by", "revokedBy"],
    ["--reason", "reason"],
  ]);
  const commands = new Set(["grant", "revoke", "status"]);

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    if (argument === "--apply") {
      options.apply = true;
      continue;
    }
    if (typeof argument !== "string" || SENSITIVE_ARGUMENT.test(argument)) {
      fail("Secret, token, password, or credential arguments are not accepted");
    }
    if (commands.has(argument) && !options.command) {
      options.command = argument;
      continue;
    }
    const [flag, inlineValue] = argument.split(/=(.*)/s, 2);
    const key = valueFlags.get(flag);
    if (!key) fail(`Unknown argument: ${argument}`);
    const value = inlineValue ?? argv[++index];
    if (value === undefined || value.startsWith("--")) {
      fail(`${flag} requires a value`);
    }
    if (SENSITIVE_ARGUMENT.test(value)) {
      fail("Secret, token, password, or credential values are not accepted");
    }
    options[key] = value;
  }

  if (options.help) return options;
  if (!options.command) fail("Choose one command: grant, revoke, or status");
  options.project = nonBlank(options.project, "--project");
  options.email = nonBlank(options.email, "--email").toLowerCase();
  if (!options.email.includes("@")) fail("--email must be a valid email address");
  if (options.command === "grant") {
    options.kind = nonBlank(options.kind, "--kind");
    if (!grantKinds().includes(options.kind)) {
      fail(`--kind must be one of: ${grantKinds().join(", ")}`);
    }
    options.grantedBy = nonBlank(options.grantedBy, "--granted-by");
    options.reason = nonBlank(options.reason, "--reason");
    if (options.reason.length > MAX_REASON_LENGTH) {
      fail(`--reason must be at most ${MAX_REASON_LENGTH} characters`);
    }
    if (options.expiresAt !== null) parseTimestamp(options.expiresAt, "--expires-at");
  }
  if (options.command === "revoke") {
    options.revokedBy = nonBlank(options.revokedBy, "--revoked-by");
    options.reason = options.reason === null ? "revoked by administrator" :
      nonBlank(options.reason, "--reason");
    if (options.reason.length > MAX_REASON_LENGTH) {
      fail(`--reason must be at most ${MAX_REASON_LENGTH} characters`);
    }
  }
  if (options.command === "status" && options.apply) {
    fail("--apply is only valid for grant or revoke");
  }
  return options;
}

function outputGrant(grant) {
  const validated = validateEntitlementGrant(grant);
  return {
    valid: validated.valid,
    active: validated.active,
    code: validated.code,
    grant: validated.grant,
  };
}

function serializeGrantForWrite(options, now) {
  return {
    active: true,
    kind: options.kind,
    expiresAt: options.expiresAt === null ? null : Timestamp.fromDate(
      parseTimestamp(options.expiresAt, "--expires-at"),
    ),
    grantedAt: Timestamp.fromDate(now),
    grantedBy: options.grantedBy,
    reason: options.reason,
    revokedAt: FieldValue.delete(),
    revokedBy: FieldValue.delete(),
    updatedAt: Timestamp.fromDate(now),
  };
}

function grantMatchesRequest(current, options) {
  const validated = validateEntitlementGrant(current);
  if (!validated.valid || !validated.active || current.kind !== options.kind ||
      current.grantedBy !== options.grantedBy || current.reason !== options.reason) {
    return false;
  }
  const currentExpiry = validated.grant.expiresAt === null ? null :
    Date.parse(validated.grant.expiresAt);
  const requestedExpiry = options.expiresAt === null ? null : parseTimestamp(options.expiresAt, "--expires-at").getTime();
  return currentExpiry === requestedExpiry && current.revokedAt == null && current.revokedBy == null;
}

async function findVerifiedUser(auth, email) {
  const user = await auth.getUserByEmail(email);
  if (user.emailVerified !== true) {
    fail("The target Firebase account email is not verified");
  }
  return user;
}

async function runGrant({db, options, user}) {
  const ref = db.collection("entitlementGrants").doc(user.uid);
  const existing = await ref.get();
  const proposal = {
    active: true,
    kind: options.kind,
    expiresAt: options.expiresAt,
    grantedBy: options.grantedBy,
    reason: options.reason,
  };
  if (!options.apply) {
    return {
      dryRun: true,
      action: "grant",
      uid: user.uid,
      emailVerified: user.emailVerified === true,
      existing: outputGrant(existing.exists ? existing.data() : null),
      proposed: proposal,
      wouldWrite: !grantMatchesRequest(existing.data(), options),
    };
  }

  const now = new Date();
  const auditRef = db.collection("entitlementGrantAudit").doc(randomUUID());
  const checkoutLocks = db.collection("checkoutLocks");
  const customerLockRefs = PORTALY_MODES.map((mode) => {
    const lockId = customerSubscriptionKey({
      email: user.email,
      planId: PORTALY_PLAN_ID,
      mode,
    });
    if (!lockId) fail("Unable to derive the customer checkout lock");
    return checkoutLocks.doc(lockId);
  });
  // Keep all known UID documents explicit: a legacy lock may omit `uid` and
  // therefore be invisible to the UID query below.
  const uidLockRefs = [
    ...PORTALY_MODES.map((mode) =>
      checkoutLocks.doc(checkoutLockDocumentId(user.uid, PORTALY_PLAN_ID, mode))),
    checkoutLocks.doc(checkoutLockDocumentId(user.uid, PORTALY_PLAN_ID)),
  ];
  const lockRefs = [...customerLockRefs, ...uidLockRefs].filter((lockRef, index, refs) =>
    refs.findIndex((candidate) => candidate.path === lockRef.path) === index,
  );
  const uidLocksQuery = checkoutLocks.where("uid", "==", user.uid);
  let changed = false;
  await db.runTransaction(async (transaction) => {
    const [snapshot, userSnapshot, ...lockSnapshotsAndQuery] = await Promise.all([
      transaction.get(ref),
      transaction.get(db.collection("users").doc(user.uid)),
      ...lockRefs.map((lockRef) => transaction.get(lockRef)),
      transaction.get(uidLocksQuery),
    ]);
    const current = snapshot.exists ? snapshot.data() : null;
    if (grantMatchesRequest(current, options)) return;

    const lockSnapshots = lockSnapshotsAndQuery.slice(0, lockRefs.length);
    const uidLocksSnapshot = lockSnapshotsAndQuery[lockRefs.length];
    const transactionNow = Date.now();
    const guard = entitlementGrantCheckoutGuardDecision({
      uid: user.uid,
      user: userSnapshot.exists ? userSnapshot.data() : {},
      locks: [
        ...lockSnapshots.filter((lockSnapshot) => lockSnapshot.exists)
          .map((lockSnapshot) => lockSnapshot.data()),
        ...uidLocksSnapshot.docs.map((lockSnapshot) => lockSnapshot.data()),
      ],
      now: transactionNow,
    });
    if (guard.kind !== "safe") {
      throw Object.assign(new Error(
        guard.kind === "blocked" ?
          "目前有尚未完成的付款或刪帳流程，為避免重複扣款，暫時無法授予 Pro。" :
          "付款或刪帳狀態尚未確認，為避免重複扣款，暫時無法授予 Pro。",
      ), {
        statusCode: 409,
        code: guard.code,
      });
    }
    changed = true;
    transaction.set(ref, serializeGrantForWrite(options, now), {merge: true});
    transaction.create(auditRef, {
      action: "grant",
      uid: user.uid,
      kind: options.kind,
      expiresAt: options.expiresAt === null ? null : Timestamp.fromDate(
        parseTimestamp(options.expiresAt, "--expires-at"),
      ),
      grantedBy: options.grantedBy,
      reason: options.reason,
      createdAt: Timestamp.fromDate(now),
    });
  });
  return {
    dryRun: false,
    action: "grant",
    uid: user.uid,
    changed,
    source: ENTITLEMENT_SOURCES.SERVER_GRANT,
  };
}

async function runRevoke({db, options, user}) {
  const ref = db.collection("entitlementGrants").doc(user.uid);
  const existing = await ref.get();
  if (!options.apply) {
    return {
      dryRun: true,
      action: "revoke",
      uid: user.uid,
      emailVerified: user.emailVerified === true,
      existing: outputGrant(existing.exists ? existing.data() : null),
      wouldWrite: existing.exists && existing.data()?.active === true,
    };
  }

  const now = new Date();
  const auditRef = db.collection("entitlementGrantAudit").doc(randomUUID());
  let changed = false;
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    const current = snapshot.exists ? snapshot.data() : null;
    if (!current || current.active !== true) return;
    changed = true;
    transaction.set(ref, {
      active: false,
      revokedAt: Timestamp.fromDate(now),
      revokedBy: options.revokedBy,
      revokeReason: options.reason,
      updatedAt: Timestamp.fromDate(now),
    }, {merge: true});
    transaction.create(auditRef, {
      action: "revoke",
      uid: user.uid,
      revokedBy: options.revokedBy,
      reason: options.reason,
      createdAt: Timestamp.fromDate(now),
    });
  });
  return {dryRun: false, action: "revoke", uid: user.uid, changed};
}

async function runStatus({db, options, user}) {
  const snapshot = await db.collection("entitlementGrants").doc(user.uid).get();
  const grant = snapshot.exists ? snapshot.data() : null;
  const validation = validateEntitlementGrant(grant);
  const resolution = resolveEntitlement({grant, now: Date.now()});
  return {
    dryRun: true,
    action: "status",
    uid: user.uid,
    emailVerified: user.emailVerified === true,
    grant: outputGrant(grant),
    effective: {
      proActive: resolution.proActive,
      entitlementSource: resolution.entitlementSource,
      grant: resolution.grant,
    },
    validationCode: validation.code,
  };
}

export async function runEntitlementAdmin(options) {
  const app = initializeApp({
    projectId: options.project,
    credential: applicationDefault(),
  });
  const auth = getAuth(app);
  const db = getFirestore(app);
  const user = await findVerifiedUser(auth, options.email);
  if (options.command === "grant") return runGrant({db, options, user});
  if (options.command === "revoke") return runRevoke({db, options, user});
  return runStatus({db, options, user});
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseEntitlementAdminArgs(argv);
  if (options.help) {
    console.log(usage());
    return 0;
  }
  const result = await runEntitlementAdmin(options);
  console.log(JSON.stringify(result, null, 2));
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((error) => {
    console.error(`entitlement-admin: ${error.message}`);
    process.exitCode = 1;
  });
}
