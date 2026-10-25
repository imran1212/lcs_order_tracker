const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

initializeApp();

const db = getFirestore();
const auth = getAuth();

function requireInput(value, label, maxLength = 128) {
  if (typeof value !== "string" || !value.trim() || value.trim().length > maxLength) {
    throw new HttpsError("invalid-argument", `Invalid ${label}.`);
  }
  return value.trim();
}

async function requireAdmin(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "Please sign in again.");
  }
  const profile = await db.collection("users").doc(request.auth.uid).get();
  const data = profile.data() || {};
  if (!profile.exists || String(data.role || "").toLowerCase() !== "admin" || data.active === false) {
    throw new HttpsError("permission-denied", "Only an active admin can perform this action.");
  }
  return request.auth.uid;
}

async function requireWorker(uid) {
  const profileRef = db.collection("users").doc(uid);
  const profile = await profileRef.get();
  if (!profile.exists || String(profile.get("role") || "").toLowerCase() !== "worker") {
    throw new HttpsError("not-found", "Worker account not found.");
  }
  return { profileRef, data: profile.data() || {} };
}

function usernameEmail(username) {
  const normalized = username.toLowerCase();
  if (!/^[a-z0-9._-]+$/.test(normalized)) {
    throw new HttpsError("invalid-argument", "Username may contain letters, numbers, dot, underscore or hyphen.");
  }
  return `${normalized}@lcs-tracker.local`;
}

exports.adminUpdateWorkerName = onCall(async (request) => {
  await requireAdmin(request);
  const uid = requireInput(request.data?.uid, "worker UID");
  const name = requireInput(request.data?.name, "worker name", 100);
  const { profileRef } = await requireWorker(uid);
  await profileRef.update({ name, updatedAt: FieldValue.serverTimestamp(), updatedBy: request.auth.uid });
  return { ok: true, name };
});

exports.adminUpdateWorkerUsername = onCall(async (request) => {
  await requireAdmin(request);
  const uid = requireInput(request.data?.uid, "worker UID");
  const username = requireInput(request.data?.username, "username", 64).toLowerCase();
  const email = usernameEmail(username);
  const { profileRef, data } = await requireWorker(uid);

  // Update Firebase Authentication and the user profile together as safely as possible.
  // If the Auth update fails, Firestore remains unchanged.
  const user = await auth.getUser(uid);
  await auth.updateUser(uid, { email });
  try {
    await profileRef.update({
      username,
      email,
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: request.auth.uid,
    });
  } catch (error) {
    // Roll back the Auth email if the Firestore profile write fails.
    try { await auth.updateUser(uid, { email: user.email }); } catch (_) {}
    throw new HttpsError("internal", "Username update failed; no profile change was saved.");
  }
  return { ok: true, username };
});

exports.adminResetWorkerPassword = onCall(async (request) => {
  await requireAdmin(request);
  const uid = requireInput(request.data?.uid, "worker UID");
  const password = requireInput(request.data?.password, "temporary password", 128);
  if (password.length < 8) {
    throw new HttpsError("invalid-argument", "Temporary password must be at least 8 characters.");
  }
  await requireWorker(uid);
  await auth.updateUser(uid, { password, emailVerified: false });
  await db.collection("users").doc(uid).update({
    passwordResetAt: FieldValue.serverTimestamp(),
    passwordResetBy: request.auth.uid,
    mustChangePassword: true,
  });
  return { ok: true };
});

exports.adminDeleteWorker = onCall(async (request) => {
  const adminUid = await requireAdmin(request);
  const uid = requireInput(request.data?.uid, "worker UID");
  if (uid === adminUid) {
    throw new HttpsError("failed-precondition", "You cannot delete your own admin account.");
  }
  const { profileRef, data } = await requireWorker(uid);

  // Preserve order history: orders stay in place, including workerUid/workerName
  // fields for historical reporting. Only the worker login and profile are deleted.
  await db.collection("adminAuditLog").add({
    action: "delete_worker",
    targetUid: uid,
    targetUsername: data.username || null,
    targetName: data.name || null,
    performedBy: adminUid,
    createdAt: FieldValue.serverTimestamp(),
  });
  await profileRef.delete();
  try {
    await auth.deleteUser(uid);
  } catch (error) {
    // Restore the profile if the Auth user could not be deleted.
    await profileRef.set({ ...data, deletionFailedAt: FieldValue.serverTimestamp() });
    throw new HttpsError("internal", "Firebase login could not be deleted; worker profile was restored.");
  }
  return { ok: true };
});
