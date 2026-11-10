"use strict";

const crypto = require("node:crypto");
const admin = require("firebase-admin");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { setGlobalOptions } = require("firebase-functions/v2");

admin.initializeApp();
setGlobalOptions({ region: "us-central1", maxInstances: 10 });

const db = admin.firestore();
const licenseAdminEmails = defineSecret("LICENSE_ADMIN_EMAILS");
const licenseServerApiKey = defineSecret("LICENSE_SERVER_API_KEY");
const farmIdPattern = /^[A-Za-z0-9_.:-]{1,160}$/;

function requireLicenseServer(request) {
  const expected = Buffer.from(licenseServerApiKey.value(), "utf8");
  const supplied = Buffer.from(
    typeof request.get === "function" ? String(request.get("x-agrogestor-license-key") || "") : "",
    "utf8",
  );
  return expected.length > 0 && expected.length === supplied.length && crypto.timingSafeEqual(expected, supplied);
}

function requireLicenseAdmin(request, secretValue) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Entre com a conta administradora de licenças.");
  }
  const email = String(request.auth.token.email || "").trim().toLowerCase();
  const verified = request.auth.token.email_verified === true;
  const allowed = secretValue.split(",").map((value) => value.trim().toLowerCase()).filter(Boolean);
  if (!verified || !email || !allowed.includes(email)) {
    throw new HttpsError("permission-denied", "Esta conta não está autorizada a administrar licenças.");
  }
  return email;
}

function requireText(value, label, max = 160) {
  if (typeof value !== "string" || value.trim().length < 1 || value.length > max) {
    throw new HttpsError("invalid-argument", `${label} inválido.`);
  }
  return value.trim();
}

function dateValue(value) {
  return value && typeof value.toDate === "function" ? value.toDate().toISOString() : null;
}

const licensePlanDays = Object.freeze({ monthly: 30, quarterly: 90, annual: 365, lifetime: null });

function licenseExpiry(plan, startDate) {
  if (!Object.hasOwn(licensePlanDays, plan)) throw new HttpsError("invalid-argument", "Plano de licença inválido.");
  const days = licensePlanDays[plan];
  return days === null ? null : admin.firestore.Timestamp.fromDate(new Date(startDate.getTime() + days * 24 * 60 * 60 * 1000));
}

exports.issueLicense = onCall({ secrets: [licenseAdminEmails] }, async (request) => {
  const adminEmail = requireLicenseAdmin(request, licenseAdminEmails.value());
  const note = typeof request.data?.note === "string" ? request.data.note.trim().slice(0, 300) : "";
  const plan = request.data?.plan || "lifetime";
  if (!Object.hasOwn(licensePlanDays, plan)) throw new HttpsError("invalid-argument", "Plano de licença inválido.");
  const licenseId = crypto.randomUUID();
  const licenseKey = `AGRO-${crypto.randomBytes(32).toString("base64url")}`;
  const keyHash = crypto.createHash("sha256").update(licenseKey).digest("hex");
  const now = admin.firestore.FieldValue.serverTimestamp();
  await db.collection("licenses").doc(licenseId).create({
    plan,
    status: "issued",
    keyHash,
    issuedAt: now,
    issuedBy: adminEmail,
    note,
    activatedFarmId: null,
    activatedAt: null,
    revokedAt: null,
  });
  return { licenseId, licenseKey, status: "issued", plan };
});

exports.listLicenses = onCall({ secrets: [licenseAdminEmails] }, async (request) => {
  requireLicenseAdmin(request, licenseAdminEmails.value());
  const snapshot = await db.collection("licenses").orderBy("issuedAt", "desc").limit(250).get();
  return {
    licenses: snapshot.docs.map((doc) => {
      const value = doc.data();
      return {
        licenseId: doc.id,
        plan: value.plan,
        status: value.status,
        activatedFarmId: value.activatedFarmId || null,
        issuedAt: dateValue(value.issuedAt),
        activatedAt: dateValue(value.activatedAt),
        expiresAt: dateValue(value.expiresAt),
        revokedAt: dateValue(value.revokedAt),
        note: value.note || "",
      };
    }),
  };
});

exports.listFarms = onCall({ secrets: [licenseAdminEmails] }, async (request) => {
  requireLicenseAdmin(request, licenseAdminEmails.value());
  const [farmsSnapshot, licensesSnapshot] = await Promise.all([
    db.collection("farmRegistry").orderBy("farmName").limit(500).get(),
    db.collection("licenses").limit(1000).get(),
  ]);
  const licensesByFarm = new Map();
  for (const doc of licensesSnapshot.docs) {
    const value = doc.data();
    if (value.activatedFarmId) {
      licensesByFarm.set(value.activatedFarmId, {
        licenseId: doc.id,
        status: value.status,
        plan: value.plan,
        issuedAt: dateValue(value.issuedAt),
        activatedAt: dateValue(value.activatedAt),
        expiresAt: dateValue(value.expiresAt),
      });
    }
  }
  return {
    farms: farmsSnapshot.docs.map((doc) => {
      const value = doc.data();
      const license = licensesByFarm.get(doc.id);
      const trialEndsAt = dateValue(value.trialEndsAt);
      return {
        farmId: doc.id,
        farmName: value.farmName || "Fazenda sem nome",
        lastSeenAt: dateValue(value.lastSeenAt),
        trialEndsAt,
        licenseId: license?.licenseId || null,
        licenseStatus: license?.status || null,
        licensePlan: license?.plan || null,
        activatedAt: license?.activatedAt || null,
        licenseExpiresAt: license?.expiresAt || null,
      };
    }),
  };
});

exports.revokeLicense = onCall({ secrets: [licenseAdminEmails] }, async (request) => {
  const adminEmail = requireLicenseAdmin(request, licenseAdminEmails.value());
  const licenseId = requireText(request.data?.licenseId, "Identificador da licença", 80);
  const ref = db.collection("licenses").doc(licenseId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError("not-found", "Licença não encontrada.");
    const value = snapshot.data();
    if (value.status === "revoked") return;
    transaction.update(ref, {
      status: "revoked",
      revokedAt: admin.firestore.FieldValue.serverTimestamp(),
      revokedBy: adminEmail,
    });
    const event = db.collection("licenseEvents").doc();
    transaction.create(event, {
      licenseId,
      action: "revoke",
      fromFarmId: value.activatedFarmId || null,
      by: adminEmail,
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { revoked: true };
});

exports.suspendLicense = onCall({ secrets: [licenseAdminEmails] }, async (request) => {
  const adminEmail = requireLicenseAdmin(request, licenseAdminEmails.value());
  const licenseId = requireText(request.data?.licenseId, "Identificador da licença", 80);
  const ref = db.collection("licenses").doc(licenseId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError("not-found", "Licença não encontrada.");
    const value = snapshot.data();
    if (value.status === "revoked") throw new HttpsError("failed-precondition", "Uma licença revogada não pode ser suspensa.");
    if (value.status === "suspended") return;
    transaction.update(ref, {
      status: "suspended",
      suspendedAt: admin.firestore.FieldValue.serverTimestamp(),
      changedBy: adminEmail,
    });
    transaction.create(db.collection("licenseEvents").doc(), {
      licenseId,
      action: "suspend",
      farmId: value.activatedFarmId || null,
      by: adminEmail,
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { suspended: true };
});

exports.renewLicense = onCall({ secrets: [licenseAdminEmails] }, async (request) => {
  const adminEmail = requireLicenseAdmin(request, licenseAdminEmails.value());
  const licenseId = requireText(request.data?.licenseId, "Identificador da licença", 80);
  const requestedPlan = request.data?.plan;
  const ref = db.collection("licenses").doc(licenseId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError("not-found", "Licença não encontrada.");
    const value = snapshot.data();
    if (value.status === "revoked") throw new HttpsError("failed-precondition", "Emita uma licença nova para uma licença revogada.");
    const plan = requestedPlan || value.plan || "lifetime";
    if (!Object.hasOwn(licensePlanDays, plan)) throw new HttpsError("invalid-argument", "Plano de licença inválido.");
    const now = new Date();
    const currentExpiry = value.expiresAt?.toDate?.() || null;
    const start = currentExpiry && currentExpiry > now ? currentExpiry : now;
    transaction.update(ref, {
      plan,
      status: "active",
      expiresAt: licenseExpiry(plan, start),
      renewedAt: admin.firestore.FieldValue.serverTimestamp(),
      renewedBy: adminEmail,
    });
    transaction.create(db.collection("licenseEvents").doc(), {
      licenseId,
      action: "renew",
      farmId: value.activatedFarmId || null,
      plan,
      by: adminEmail,
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { renewed: true };
});

exports.transferLicense = onCall({ secrets: [licenseAdminEmails] }, async (request) => {
  const adminEmail = requireLicenseAdmin(request, licenseAdminEmails.value());
  const licenseId = requireText(request.data?.licenseId, "Identificador da licença", 80);
  const newFarmId = requireText(request.data?.newFarmId, "ID da fazenda", 160);
  if (!farmIdPattern.test(newFarmId)) throw new HttpsError("invalid-argument", "ID da fazenda inválido.");
  const ref = db.collection("licenses").doc(licenseId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError("not-found", "Licença não encontrada.");
    const value = snapshot.data();
    if (value.status !== "active" || (value.expiresAt?.toDate?.() && Date.now() >= value.expiresAt.toDate().getTime())) {
      throw new HttpsError("failed-precondition", "Somente licenças ativas e dentro da validade podem ser transferidas.");
    }
    const oldFarmId = value.activatedFarmId;
    if (oldFarmId === newFarmId) throw new HttpsError("failed-precondition", "A licença já está vinculada a esta fazenda.");
    transaction.update(ref, {
      activatedFarmId: newFarmId,
      transferredAt: admin.firestore.FieldValue.serverTimestamp(),
      transferredBy: adminEmail,
    });
    transaction.set(db.collection("farmRegistry").doc(newFarmId), {
      farmName: "Fazenda sem nome",
      lastSeenAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    const event = db.collection("licenseEvents").doc();
    transaction.create(event, {
      licenseId,
      action: "transfer",
      fromFarmId: oldFarmId,
      toFarmId: newFarmId,
      by: adminEmail,
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { transferred: true };
});

exports.activateLicense = onRequest({ cors: false, secrets: [licenseServerApiKey] }, async (request, response) => {
  response.set("Cache-Control", "no-store");
  if (request.method !== "POST") return response.status(405).json({ detail: "Use POST." });
  if (!requireLicenseServer(request)) return response.status(401).json({ detail: "Servidor de fazenda não autenticado." });
  const licenseKey = typeof request.body?.licenseKey === "string" ? request.body.licenseKey.trim() : "";
  const farmId = typeof request.body?.farmId === "string" ? request.body.farmId.trim() : "";
  const farmName = typeof request.body?.farmName === "string" ? request.body.farmName.trim().slice(0, 160) : "";
  if (licenseKey.length < 20 || licenseKey.length > 100 || !farmIdPattern.test(farmId)) {
    return response.status(400).json({ detail: "Chave ou fazenda inválida." });
  }
  const keyHash = crypto.createHash("sha256").update(licenseKey).digest("hex");
  const found = await db.collection("licenses").where("keyHash", "==", keyHash).limit(1).get();
  if (found.empty) return response.status(404).json({ detail: "Chave de licença inválida." });
  const ref = found.docs[0].ref;
  try {
    const result = await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      const value = snapshot.data();
      if (!value || value.status === "revoked") throw new Error("revoked");
      if (value.status === "suspended" || value.status === "expired") throw new Error("inactive");
      if (value.activatedFarmId && value.activatedFarmId !== farmId) throw new Error("already_used");
      const priorExpiry = value.expiresAt?.toDate?.() || null;
      let effectiveExpiry = value.expiresAt || null;
      if (value.activatedFarmId === farmId && priorExpiry && Date.now() >= priorExpiry.getTime()) throw new Error("inactive");
      if (!value.activatedFarmId) {
        const activatedAt = new Date();
        const expiresAt = licenseExpiry(value.plan || "lifetime", activatedAt);
        effectiveExpiry = expiresAt;
        transaction.update(ref, {
          status: "active",
          activatedFarmId: farmId,
          activatedAt: admin.firestore.FieldValue.serverTimestamp(),
          expiresAt,
        });
        const event = db.collection("licenseEvents").doc();
        transaction.create(event, {
          licenseId: ref.id,
          action: "activate",
          toFarmId: farmId,
          at: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      if (farmName) {
        transaction.set(db.collection("farmRegistry").doc(farmId), {
          farmName,
          lastSeenAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
      return { licenseId: ref.id, status: "active", expiresAt: dateValue(effectiveExpiry) };
    });
    return response.status(200).json(result);
  } catch (error) {
    if (error.message === "already_used") {
      return response.status(409).json({ detail: "Esta licença já foi ativada por outra fazenda." });
    }
    if (error.message === "revoked") {
      return response.status(409).json({ detail: "Esta licença foi revogada." });
    }
    if (error.message === "inactive") {
      return response.status(409).json({ detail: "Esta licença está suspensa ou expirada." });
    }
    throw error;
  }
});

exports.checkLicense = onRequest({ cors: false, secrets: [licenseServerApiKey] }, async (request, response) => {
  response.set("Cache-Control", "no-store");
  if (request.method !== "POST") return response.status(405).json({ detail: "Use POST." });
  if (!requireLicenseServer(request)) return response.status(401).json({ detail: "Servidor de fazenda não autenticado." });
  const licenseId = typeof request.body?.licenseId === "string" ? request.body.licenseId.trim() : "";
  const farmId = typeof request.body?.farmId === "string" ? request.body.farmId.trim() : "";
  const farmName = typeof request.body?.farmName === "string" ? request.body.farmName.trim().slice(0, 160) : "";
  if (licenseId.length > 80 || !farmIdPattern.test(farmId)) {
    return response.status(400).json({ detail: "Licença ou fazenda inválida." });
  }
  let resolvedLicenseId = licenseId;
  if (!resolvedLicenseId) {
    const assigned = await db.collection("licenses").where("activatedFarmId", "==", farmId).get();
    const newest = [...assigned.docs].sort((a, b) =>
      (b.data().issuedAt?.toMillis?.() || 0) - (a.data().issuedAt?.toMillis?.() || 0));
    resolvedLicenseId = newest[0]?.id || "";
  }
  if (resolvedLicenseId) {
    const snapshot = await db.collection("licenses").doc(resolvedLicenseId).get();
    const value = snapshot.exists ? snapshot.data() : null;
    if (value?.activatedFarmId === farmId && value.status === "active") {
      const expiresAt = value.expiresAt?.toDate?.() || null;
      if (!expiresAt || Date.now() < expiresAt.getTime()) {
        return response.status(200).json({ status: "active", licenseId: resolvedLicenseId, checkedAt: new Date().toISOString(), expiresAt: expiresAt?.toISOString() || null });
      }
      await db.collection("licenses").doc(resolvedLicenseId).update({ status: "expired" });
      return response.status(200).json({ status: "inactive", checkedAt: new Date().toISOString() });
    }
    return response.status(200).json({ status: "inactive", checkedAt: new Date().toISOString() });
  }
  const trialRef = db.collection("farmTrials").doc(farmId);
  const registryRef = db.collection("farmRegistry").doc(farmId);
  const trial = await db.runTransaction(async (transaction) => {
    const now = admin.firestore.Timestamp.now();
    const [snapshot, registrySnapshot] = await Promise.all([
      transaction.get(trialRef),
      transaction.get(registryRef),
    ]);
    let startedAt;
    let endsAt;
    if (snapshot.exists) {
      const data = snapshot.data();
      startedAt = data.startedAt;
      endsAt = data.endsAt;
    } else {
      startedAt = now;
      endsAt = admin.firestore.Timestamp.fromDate(new Date(now.toDate().getTime() + 30 * 24 * 60 * 60 * 1000));
      transaction.create(trialRef, { startedAt, endsAt });
    }
    const priorRegistry = registrySnapshot.exists ? registrySnapshot.data() : {};
    const lastSeen = priorRegistry.lastSeenAt?.toDate?.() || new Date(0);
    const shouldRefreshRegistry = !registrySnapshot.exists ||
      (farmName && priorRegistry.farmName !== farmName) ||
      now.toMillis() - lastSeen.getTime() >= 24 * 60 * 60 * 1000;
    if (shouldRefreshRegistry) {
      transaction.set(registryRef, {
        farmName: farmName || priorRegistry.farmName || "Fazenda sem nome",
        lastSeenAt: now,
        trialEndsAt: endsAt,
      }, { merge: true });
    }
    return {
      status: now.toMillis() < endsAt.toMillis() ? "trial" : "expired",
      trialStartedAt: startedAt.toDate().toISOString(),
      trialEndsAt: endsAt.toDate().toISOString(),
      checkedAt: now.toDate().toISOString(),
    };
  });
  return response.status(200).json(trial);
});
