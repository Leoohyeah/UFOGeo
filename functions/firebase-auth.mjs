function authError(message, statusCode, code) {
  const error = Object.assign(new Error(message), {statusCode});
  if (code) error.code = code;
  return error;
}

/**
 * Authenticate a Firebase ID token for every member API.
 *
 * The second verifyIdToken argument is intentional: Firebase Admin then
 * checks the current Auth user record, rejecting disabled users, revoked
 * sessions, and users that no longer exist.  Portaly callbacks do not call
 * this helper; they use their independent signed-envelope verification.
 */
export async function requireFirebaseUser(request, {auth, verifiedEmail = false} = {}) {
  const authorization = request.get("authorization") || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    throw authError("請先登入 UFOGeo 帳號。", 401);
  }

  let decoded;
  try {
    decoded = await auth.verifyIdToken(match[1], true);
  } catch {
    // Keep all token verification failures indistinguishable to clients.
    throw authError("登入狀態已失效，請重新登入。", 401);
  }

  if (!decoded.email) {
    throw authError("此帳號沒有電子郵件。", 403);
  }
  if (verifiedEmail && decoded.email_verified !== true) {
    throw authError("請先完成電子郵件驗證，再開始訂閱。", 403, "EMAIL_NOT_VERIFIED");
  }
  return {
    uid: decoded.uid,
    email: decoded.email,
    emailVerified: decoded.email_verified === true,
  };
}
