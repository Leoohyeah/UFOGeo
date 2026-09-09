import assert from "node:assert/strict";
import test from "node:test";

import {
  portalyModeFromApiKey,
  requirePortalyMode,
  storedPortalyModeRelationship,
} from "../portaly-mode.mjs";

test("derives Portaly mode only from a valid API-key prefix", () => {
  assert.equal(portalyModeFromApiKey("pcs_live_secret"), "live");
  assert.equal(portalyModeFromApiKey("pcs_test_secret"), "test");

  for (const value of [
    undefined,
    null,
    "",
    "pcs_live_",
    "pcs_test_",
    "pcs_live_ ",
    "pcs_test_secret ",
    "PCS_LIVE_secret",
    "live_secret",
    " pcs_test_secret",
  ]) {
    assert.equal(portalyModeFromApiKey(value), null);
  }
});

test("keeps the existing mode-mismatch service error for invalid API keys", () => {
  assert.throws(
    () => requirePortalyMode("invalid-key"),
    (error) => error.statusCode === 503 && error.code === "PORTALY_MODE_MISMATCH",
  );
});

test("classifies stored subscription modes without backfilling corrupt data", () => {
  assert.equal(storedPortalyModeRelationship("live", "live"), "matching");
  assert.equal(storedPortalyModeRelationship("test", "live"), "opposite");
  assert.equal(storedPortalyModeRelationship(undefined, "live"), "missing");
  assert.equal(storedPortalyModeRelationship(null, "test"), "missing");
  assert.equal(storedPortalyModeRelationship("sandbox", "live"), "invalid");
  assert.equal(storedPortalyModeRelationship("live", "sandbox"), "invalid_expected");
});
