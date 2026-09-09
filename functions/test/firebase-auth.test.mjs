import assert from "node:assert/strict";
import test from "node:test";

import {requireFirebaseUser} from "../firebase-auth.mjs";

function requestWithToken(token = "id-token") {
  return {
    get(name) {
      assert.equal(name, "authorization");
      return token ? `Bearer ${token}` : "";
    },
  };
}

function mockAuth(decodedOrError) {
  const calls = [];
  return {
    calls,
    verifyIdToken: async (...args) => {
      calls.push(args);
      if (decodedOrError instanceof Error) throw decodedOrError;
      if (decodedOrError?.error) throw decodedOrError.error;
      return decodedOrError;
    },
  };
}

test("accepts a current Firebase user and always checks revocation", async () => {
  const auth = mockAuth({
    uid: "uid-1",
    email: "member@example.com",
    email_verified: true,
  });

  const user = await requireFirebaseUser(requestWithToken(), {auth});

  assert.deepEqual(user, {
    uid: "uid-1",
    email: "member@example.com",
    emailVerified: true,
  });
  assert.deepEqual(auth.calls, [["id-token", true]]);
});

test("maps revoked, disabled, and missing Auth users to the existing 401", async () => {
  for (const code of ["auth/id-token-revoked", "auth/user-disabled", "auth/user-not-found"]) {
    const auth = mockAuth({error: Object.assign(new Error(code), {code})});

    await assert.rejects(
      () => requireFirebaseUser(requestWithToken(), {auth}),
      (error) => error.statusCode === 401 &&
        error.message === "登入狀態已失效，請重新登入。",
    );
    assert.deepEqual(auth.calls, [["id-token", true]], code);
  }
});

test("maps other token verification failures to 401", async () => {
  const auth = mockAuth(new Error("invalid token"));

  await assert.rejects(
    () => requireFirebaseUser(requestWithToken(), {auth}),
    (error) => error.statusCode === 401 &&
      error.message === "登入狀態已失效，請重新登入。",
  );
});

test("keeps EMAIL_NOT_VERIFIED behavior after token verification", async () => {
  const auth = mockAuth({
    uid: "uid-2",
    email: "unverified@example.com",
    email_verified: false,
  });

  await assert.rejects(
    () => requireFirebaseUser(requestWithToken(), {auth, verifiedEmail: true}),
    (error) => error.statusCode === 403 && error.code === "EMAIL_NOT_VERIFIED" &&
      error.message === "請先完成電子郵件驗證，再開始訂閱。",
  );
  assert.deepEqual(auth.calls, [["id-token", true]]);
});
