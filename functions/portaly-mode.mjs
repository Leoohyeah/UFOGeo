const PORTALY_MODES = new Set(["live", "test"]);
const PORTALY_API_KEY_PREFIXES = Object.freeze([
  ["pcs_live_", "live"],
  ["pcs_test_", "test"],
]);

export function isPortalyMode(value) {
  return PORTALY_MODES.has(value);
}

/**
 * Portaly binds the environment to the API key. No independent deployment
 * parameter may override or disagree with this prefix.
 */
export function portalyModeFromApiKey(apiKey) {
  if (typeof apiKey !== "string") return null;
  for (const [prefix, mode] of PORTALY_API_KEY_PREFIXES) {
    if (apiKey.startsWith(prefix) && apiKey === apiKey.trim() &&
        apiKey.slice(prefix.length).trim().length > 0) {
      return mode;
    }
  }
  return null;
}

export function requirePortalyMode(apiKey) {
  const mode = portalyModeFromApiKey(apiKey);
  if (!mode) {
    throw Object.assign(new Error("付款功能暫時無法使用，請稍後再試。"), {
      statusCode: 503,
      code: "PORTALY_MODE_MISMATCH",
    });
  }
  return mode;
}

/**
 * Distinguish a legacy missing mode from corrupt data and from a valid record
 * belonging to the other Portaly environment.
 */
export function storedPortalyModeRelationship(storedMode, expectedMode) {
  if (!isPortalyMode(expectedMode)) return "invalid_expected";
  if (storedMode === undefined || storedMode === null) return "missing";
  if (!isPortalyMode(storedMode)) return "invalid";
  return storedMode === expectedMode ? "matching" : "opposite";
}
