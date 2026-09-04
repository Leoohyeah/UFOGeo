import crypto from "node:crypto";

// Portaly callback v1 signs stableJson(JSON.parse(wireBody)), not the raw body.
// Keep this byte-identical to the production signer contract bundled with
// Portaly Payment Skill 0.10.0: localeCompare key ordering and JSON.stringify
// semantics for undefined values are both significant.
export function stableJson(value) {
  if (Array.isArray(value)) {
    return `[${value
      .map((item) =>
        typeof item === "undefined" ? "null" : stableJson(item)
      )
      .join(",")}]`;
  }

  if (value && typeof value === "object") {
    const entries = Object.entries(value)
      .filter(([, val]) => typeof val !== "undefined")
      .sort(([a], [b]) => a.localeCompare(b));

    return `{${entries
      .map(([key, val]) => `${JSON.stringify(key)}:${stableJson(val)}`)
      .join(",")}}`;
  }

  return JSON.stringify(value);
}

export function signPortalyCallback({secret, payload, timestamp}) {
  return crypto
    .createHmac("sha256", secret)
    .update(`${timestamp}.${stableJson(payload)}`)
    .digest("hex");
}

export function verifyPortalyCallback({secret, payload, timestamp, signature}) {
  const expected = signPortalyCallback({secret, payload, timestamp});
  const expectedBuffer = Buffer.from(expected, "utf8");
  const signatureBuffer = Buffer.from(signature, "utf8");

  if (expectedBuffer.byteLength !== signatureBuffer.byteLength) {
    return false;
  }

  return crypto.timingSafeEqual(expectedBuffer, signatureBuffer);
}
