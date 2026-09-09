export const collections = Object.freeze({
  users: "users",
  checkoutSessions: "checkoutSessions",
  checkoutLocks: "checkoutLocks",
  entitlementGrants: "entitlementGrants",
  entitlementGrantAudit: "entitlementGrantAudit",
  portalyEvents: "portalyEvents",
  portalyAudit: "portalyAudit",
  portalyCompensations: "portalyCompensations",
});

export function collectionDocRef(db, collectionName, documentId) {
  return db.collection(collectionName).doc(documentId);
}

export function userDocRef(db, uid) {
  return collectionDocRef(db, collections.users, uid);
}

export function entitlementGrantRef(db, uid) {
  return collectionDocRef(db, collections.entitlementGrants, uid);
}

export function checkoutSessionRef(db, sessionId) {
  return collectionDocRef(db, collections.checkoutSessions, sessionId);
}

export function checkoutLocksCollection(db) {
  return db.collection(collections.checkoutLocks);
}

export function portalyAuditDocRef(db) {
  return db.collection(collections.portalyAudit).doc();
}
