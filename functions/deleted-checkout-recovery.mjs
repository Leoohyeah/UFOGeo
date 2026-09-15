function requireFunctions(dependencies) {
  for (const [name, dependency] of Object.entries(dependencies)) {
    if (typeof dependency !== "function") {
      throw Object.assign(new Error(`${name} must be a function`), {
        code: "DELETED_CHECKOUT_RECOVERY_DEPENDENCY_INVALID",
      });
    }
  }
}

export async function inspectDeletedCheckoutProvider({
  fetchSubscriptions,
  selectCandidate,
  fetchDetail,
  decodeDetail,
  classifyDetail,
} = {}) {
  requireFunctions({fetchSubscriptions, selectCandidate, fetchDetail, decodeDetail, classifyDetail});
  let subscriptions;
  try {
    subscriptions = await fetchSubscriptions();
  } catch (error) {
    return {kind: "uncertain", stage: "list", error};
  }
  let candidate;
  try {
    candidate = await selectCandidate(subscriptions);
  } catch (error) {
    return {kind: "uncertain", stage: "list", error};
  }
  if (!candidate) return {kind: "terminal"};

  let detail;
  try {
    detail = await fetchDetail(candidate);
  } catch (error) {
    return {kind: "uncertain", stage: "detail", error};
  }
  let decoded;
  try {
    decoded = await decodeDetail(detail, candidate);
  } catch (error) {
    return {kind: "uncertain", stage: "detail_invalid", error};
  }
  let classification;
  try {
    classification = await classifyDetail(decoded, candidate);
  } catch (error) {
    return {kind: "uncertain", stage: "detail_invalid", error};
  }
  if (classification?.kind === "terminal") return {kind: "terminal"};
  if (classification?.kind === "renewable") {
    return {kind: "renewable", candidate, recovered: decoded};
  }
  return {
    kind: "uncertain",
    stage: classification?.stage || "state_changed",
    error: classification?.error || null,
  };
}

export async function runDeletedCheckoutLease({
  acquireLease,
  inspectProvider,
  clearTombstone,
} = {}) {
  requireFunctions({acquireLease, inspectProvider, clearTombstone});
  const firstDecision = await acquireLease();
  if (firstDecision?.kind !== "safety_hold" ||
      firstDecision.status !== "account_deleted") return firstDecision;

  let inspection;
  try {
    inspection = await inspectProvider();
  } catch {
    return firstDecision;
  }
  if (inspection?.kind !== "terminal") return firstDecision;

  let cleared;
  try {
    cleared = await clearTombstone();
  } catch {
    return firstDecision;
  }
  if (cleared !== true) return firstDecision;
  return acquireLease();
}
