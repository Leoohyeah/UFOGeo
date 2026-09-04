const params = new URLSearchParams(window.location.search);
const mode = params.get("mode");
const actionCode = params.get("oobCode");
const continueUrl = safeContinueUrl(params.get("continueUrl"));

const pageTitle = document.querySelector("#pageTitle");
const pageDescription = document.querySelector("#pageDescription");
const status = document.querySelector("#status");
const resetForm = document.querySelector("#resetForm");
const accountEmail = document.querySelector("#accountEmail");
const newPassword = document.querySelector("#newPassword");
const confirmPassword = document.querySelector("#confirmPassword");
const resetButton = document.querySelector("#resetButton");
const continueLink = document.querySelector("#continueLink");

function safeContinueUrl(value) {
  if (!value) return null;
  try {
    const url = new URL(value);
    const allowedHosts = new Set([
      "ufogeo-adac7.web.app",
      "ufogeo-adac7.firebaseapp.com",
    ]);
    return url.protocol === "https:" && allowedHosts.has(url.host) ? url.toString() : null;
  } catch {
    return null;
  }
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[character]));
}

function setPage(title, description) {
  pageTitle.innerHTML = title;
  pageDescription.innerHTML = description;
}

function setStatus(message, kind = "info") {
  status.className = `status ${kind}`;
  status.innerHTML = message;
  status.hidden = !message;
}

function showContinueLink() {
  if (!continueUrl) return;
  continueLink.href = continueUrl;
  continueLink.hidden = false;
}

function errorMessage(error) {
  switch (error?.code) {
    case "auth/expired-action-code":
    case "auth/invalid-action-code":
      return "這個連結無效或已過期。請回到 App 重新取得連結。";
    case "auth/user-disabled":
      return "這個帳號已停用。";
    case "auth/weak-password":
      return "密碼至少需要 6 個字元。";
    case "auth/network-request-failed":
      return "網路連線失敗，請稍後再試。";
    case "auth/too-many-requests":
      return "嘗試次數過多，請稍後再試。";
    default:
      return "無法完成這項操作，請回到 App 重新取得連結。";
  }
}

function createAuth() {
  if (!window.firebase || typeof window.firebase.auth !== "function") {
    throw new Error("Firebase Auth is not available");
  }
  return window.firebase.auth();
}

async function handleVerifyEmail(auth) {
  setPage(
    "驗證電子郵件",
    "正在確認你的電子郵件。",
  );
  try {
    await auth.applyActionCode(actionCode);
    setStatus(
      "電子郵件驗證完成，你現在可以回到 UFOGeo。",
      "success",
    );
    showContinueLink();
  } catch (error) {
    setStatus(errorMessage(error), "error");
  }
}

async function handleResetPassword(auth) {
  setPage(
    "重設密碼",
    "請設定新的登入密碼。",
  );
  try {
    accountEmail.value = await auth.verifyPasswordResetCode(actionCode);
    resetForm.hidden = false;
    setStatus(
      "請輸入新密碼。",
      "info",
    );
  } catch (error) {
    setStatus(errorMessage(error), "error");
  }
}

async function handleRecoverEmail(auth) {
  setPage(
    "恢復電子郵件",
    "正在處理帳號變更。",
  );
  try {
    const info = await auth.checkActionCode(actionCode);
    const restoredEmail = info?.data?.email || "";
    await auth.applyActionCode(actionCode);
    const safeEmail = escapeHTML(restoredEmail);
    const emailText = safeEmail ? `（${safeEmail}）` : "";
    setStatus(
      `電子郵件已恢復${emailText}。`,
      "success",
    );
    showContinueLink();
  } catch (error) {
    setStatus(errorMessage(error), "error");
  }
}

resetForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (newPassword.value.length < 6) {
    setStatus(
      "密碼至少需要 6 個字元。",
      "error",
    );
    return;
  }
  if (newPassword.value !== confirmPassword.value) {
    setStatus(
      "兩次輸入的密碼不一致。",
      "error",
    );
    return;
  }

  resetButton.disabled = true;
  try {
    const auth = createAuth();
    await auth.confirmPasswordReset(actionCode, newPassword.value);
    resetForm.hidden = true;
    setPage(
      "密碼已更新",
      "你現在可以使用新密碼登入 UFOGeo。",
    );
    setStatus(
      "密碼重設完成。",
      "success",
    );
    showContinueLink();
  } catch (error) {
    resetButton.disabled = false;
    setStatus(errorMessage(error), "error");
  }
});

async function start() {
  if (!actionCode || !mode) {
    setPage(
      "連結無效",
      "這個帳號操作連結缺少必要資訊。",
    );
    setStatus(errorMessage({code: "auth/invalid-action-code"}), "error");
    return;
  }

  let auth;
  try {
    auth = createAuth();
  } catch (error) {
    setStatus(errorMessage(error), "error");
    return;
  }

  switch (mode) {
    case "verifyEmail":
      await handleVerifyEmail(auth);
      break;
    case "resetPassword":
      await handleResetPassword(auth);
      break;
    case "recoverEmail":
      await handleRecoverEmail(auth);
      break;
    default:
      setPage(
        "不支援的操作",
        "請回到 App 重新取得連結。",
      );
      setStatus(errorMessage(), "error");
  }
}

start();
