import * as logger from "firebase-functions/logger";

const DEFAULT_API_HOST = (process.env.PORTALY_API_HOST || "https://portaly.ai").replace(/\/$/, "");

export const PORTALY_SKILL_VERSION = "0.11.3";

export async function portalyRequest(path, {apiKey, method = "GET", body, timeoutMs = 15_000, host = DEFAULT_API_HOST} = {}) {
  const response = await fetch(`${host}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${apiKey}`,
      ...(body ? {"content-type": "application/json"} : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(timeoutMs),
  });
  const payload = await response.json().catch(() => ({}));
  return {response, payload};
}

export function publicCheckoutError(portalyStatus, payload) {
  switch (payload?.code) {
  case "PLAN_INACTIVE":
    return {status: 422, code: payload.code, message: "此訂閱方案目前沒有開放。"};
  case "PLAN_NOT_FOUND":
    return {status: 503, code: payload.code, message: `訂閱方案設定有誤，請寄信至 leoohyeah.app@gmail.com。`};
  case "YEARLY_TEMPORARILY_UNSUPPORTED":
    return {status: 422, code: payload.code, message: "年繳方案目前暫時無法使用。"};
  case "INVALID_DISCOUNT_CODE":
    return {status: 400, code: payload.code, message: "折扣碼目前無法套用。"};
  default:
    logger.error("Portaly request failed", {status: portalyStatus, code: payload?.code || null});
    return {status: 502, code: "PORTALY_REQUEST_FAILED", message: "目前無法建立付款流程，請稍後再試。"};
  }
}

export async function listCustomerSubscriptions({apiKey, customerEmail, host = DEFAULT_API_HOST}) {
  const subscriptions = [];
  const seenCursors = new Set();
  let startAfter = null;

  for (let page = 0; page < 10; page += 1) {
    const query = new URLSearchParams({
      customerEmail,
      limit: "100",
    });
    if (startAfter) query.set("startAfter", startAfter);

    const {response, payload} = await portalyRequest(
      `/api/creator-subscription/subscriptions?${query.toString()}`,
      {apiKey, host},
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

export function reportSkillVersion(apiKey, {host = DEFAULT_API_HOST, skillVersion = PORTALY_SKILL_VERSION} = {}) {
  return portalyRequest("/api/creator-subscription/skill-version", {
    apiKey,
    host,
    method: "POST",
    body: {skillName: "portaly-payment", version: skillVersion},
  }).catch(() => {});
}

function nonBlankString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function portalySubscriptions(payload) {
  if (Array.isArray(payload)) return payload;
  if (payload && typeof payload === "object" && Array.isArray(payload.data)) {
    return payload.data;
  }
  return [];
}
