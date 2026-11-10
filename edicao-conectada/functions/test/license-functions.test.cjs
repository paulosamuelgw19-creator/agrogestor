const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
const DAY_MS = 24 * 60 * 60 * 1000;

class FakeTimestamp {
  constructor(value) {
    this.value = new Date(value);
  }
  toDate() { return new Date(this.value); }
  toMillis() { return this.value.getTime(); }
  static now() { return new FakeTimestamp(fakeClock.value); }
  static fromDate(value) { return new FakeTimestamp(value); }
}

function clone(value) {
  if (value instanceof FakeTimestamp) return new FakeTimestamp(value.toDate());
  if (value instanceof Date) return new Date(value);
  if (Array.isArray(value)) return value.map(clone);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, clone(item)]));
  }
  return value;
}

function compare(left, right) {
  const value = (entry) => entry instanceof FakeTimestamp ? entry.toMillis() : entry;
  const a = value(left);
  const b = value(right);
  if (a instanceof Date && b instanceof Date) return a - b;
  return a < b ? -1 : a > b ? 1 : 0;
}

class FakeSnapshot {
  constructor(ref, data) {
    this.ref = ref;
    this.id = ref.id;
    this.exists = data !== undefined;
    this._data = data === undefined ? undefined : clone(data);
  }
  data() { return this._data === undefined ? undefined : clone(this._data); }
}

class FakeDocumentReference {
  constructor(database, collection, id) {
    this.database = database;
    this.collectionName = collection;
    this.id = id;
  }
  async get() {
    return new FakeSnapshot(this, this.database.get(this.collectionName, this.id));
  }
  async set(data, options = {}) {
    const prior = options.merge ? this.database.get(this.collectionName, this.id) || {} : {};
    this.database.set(this.collectionName, this.id, { ...prior, ...clone(data) });
  }
  async create(data) {
    if (this.database.get(this.collectionName, this.id) !== undefined) {
      throw new Error("already-exists");
    }
    this.database.set(this.collectionName, this.id, data);
  }
  async update(data) {
    const prior = this.database.get(this.collectionName, this.id);
    if (prior === undefined) throw new Error("not-found");
    this.database.set(this.collectionName, this.id, { ...prior, ...clone(data) });
  }
}

class FakeQuery {
  constructor(database, collection, filters = [], ordering = null, maxItems = Infinity) {
    this.database = database;
    this.collectionName = collection;
    this.filters = filters;
    this.ordering = ordering;
    this.maxItems = maxItems;
  }
  where(field, operator, expected) {
    assert.equal(operator, "==");
    return new FakeQuery(this.database, this.collectionName, [...this.filters, [field, expected]], this.ordering, this.maxItems);
  }
  orderBy(field, direction = "asc") {
    return new FakeQuery(this.database, this.collectionName, this.filters, [field, direction], this.maxItems);
  }
  limit(count) {
    return new FakeQuery(this.database, this.collectionName, this.filters, this.ordering, count);
  }
  async get() {
    let entries = [...(this.database.collections.get(this.collectionName) || new Map()).entries()]
      .filter(([, value]) => this.filters.every(([field, expected]) => value[field] === expected));
    if (this.ordering) {
      const [field, direction] = this.ordering;
      entries.sort((left, right) => compare(left[1][field], right[1][field]) * (direction === "desc" ? -1 : 1));
    }
    entries = entries.slice(0, this.maxItems);
    const docs = entries.map(([id, value]) => new FakeSnapshot(
      new FakeDocumentReference(this.database, this.collectionName, id), value,
    ));
    return { docs, empty: docs.length === 0 };
  }
}

class FakeCollection extends FakeQuery {
  doc(id = crypto.randomUUID()) {
    return new FakeDocumentReference(this.database, this.collectionName, id);
  }
}

class FakeFirestore {
  constructor() {
    this.collections = new Map();
  }
  collection(name) { return new FakeCollection(this, name); }
  get(collection, id) { return this.collections.get(collection)?.get(id); }
  set(collection, id, data) {
    if (!this.collections.has(collection)) this.collections.set(collection, new Map());
    this.collections.get(collection).set(id, clone(data));
  }
  async runTransaction(callback) {
    const writes = [];
    const transaction = {
      get: (ref) => ref.get(),
      update: (ref, data) => writes.push(["update", ref, data]),
      create: (ref, data) => writes.push(["create", ref, data]),
      set: (ref, data, options) => writes.push(["set", ref, data, options]),
    };
    const result = await callback(transaction);
    for (const [operation, ref, data, options] of writes) await ref[operation](data, options);
    return result;
  }
}

let fakeClock;

function loadFunctions() {
  fakeClock = { value: new Date("2026-10-09T12:00:00.000Z") };
  const database = new FakeFirestore();
  const secrets = {
    LICENSE_ADMIN_EMAILS: "owner@example.invalid",
    LICENSE_SERVER_API_KEY: "temporary-test-server-key-001",
  };
  const firestore = () => database;
  firestore.FieldValue = { serverTimestamp: () => new FakeTimestamp(fakeClock.value) };
  firestore.Timestamp = FakeTimestamp;

  class FakeHttpsError extends Error {
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }
  const admin = { initializeApp() {}, firestore };
  const https = {
    onCall: (_options, handler) => handler,
    onRequest: (_options, handler) => handler,
    HttpsError: FakeHttpsError,
  };
  const params = { defineSecret: (name) => ({ value: () => secrets[name] || "" }) };
  const modules = {
    "node:crypto": crypto,
    "firebase-admin": admin,
    "firebase-functions/v2/https": https,
    "firebase-functions/params": params,
    "firebase-functions/v2": { setGlobalOptions() {} },
  };
  const exports = {};
  class ControlledDate extends Date {
    constructor(...args) { super(...(args.length ? args : [fakeClock.value.getTime()])); }
    static now() { return fakeClock.value.getTime(); }
  }
  vm.runInNewContext(source, {
    Date: ControlledDate,
    exports,
    Buffer,
    require(name) {
      if (!(name in modules)) throw new Error(`Unexpected module request: ${name}`);
      return modules[name];
    },
  }, { filename: "functions/index.js" });
  return { functions: exports, database, secrets };
}

function adminRequest(data = {}) {
  return { auth: { token: { email: "owner@example.invalid", email_verified: true } }, data };
}

function responseRecorder() {
  return {
    statusCode: 200,
    headers: {},
    body: undefined,
    set(name, value) { this.headers[name] = value; return this; },
    status(value) { this.statusCode = value; return this; },
    json(value) { this.body = value; return this; },
  };
}

async function callHttp(handler, method, body, apiKey = "") {
  const response = responseRecorder();
  await handler({ method, body, get: (name) => name.toLowerCase() === "x-agrogestor-license-key" ? apiKey : undefined }, response);
  return response;
}

test("emite chaves vitais e exige administrador verificado", async () => {
  const { functions, database } = loadFunctions();
  const issued = await functions.issueLicense(adminRequest({ note: "venda 42" }));
  assert.match(issued.licenseKey, /^AGRO-[A-Za-z0-9_-]+$/);
  assert.equal(issued.plan, "lifetime");
  const stored = database.get("licenses", issued.licenseId);
  assert.equal(stored.status, "issued");
  assert.equal(stored.plan, "lifetime");
  assert.equal(stored.keyHash, crypto.createHash("sha256").update(issued.licenseKey).digest("hex"));
  assert.equal(JSON.stringify(stored).includes(issued.licenseKey), false);

  await assert.rejects(
    functions.issueLicense({ auth: { token: { email: "intruder@example.invalid", email_verified: true } }, data: {} }),
    (error) => error.code === "permission-denied",
  );
  await assert.rejects(
    functions.listLicenses({ auth: { token: { email: "owner@example.invalid", email_verified: false } }, data: {} }),
    (error) => error.code === "permission-denied",
  );
});

test("vincula cada licença a uma fazenda, permite transferência e respeita revogação", async () => {
  const { functions, database, secrets } = loadFunctions();
  const issued = await functions.issueLicense(adminRequest());
  const anonymousTrial = await callHttp(functions.checkLicense, "POST", { farmId: "farm-anonymous" });
  assert.equal(anonymousTrial.statusCode, 401);
  assert.equal(database.collections.has("farmTrials"), false);

  const anonymousActivation = await callHttp(functions.activateLicense, "POST", {
    licenseKey: issued.licenseKey,
    farmId: "farm-alpha",
  });
  assert.equal(anonymousActivation.statusCode, 401);

  const firstActivation = await callHttp(functions.activateLicense, "POST", {
    licenseKey: issued.licenseKey,
    farmId: "farm-alpha",
  }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(firstActivation.statusCode, 200);
  assert.equal(firstActivation.body.status, "active");
  assert.equal(firstActivation.body.licenseId, issued.licenseId);

  const repeatActivation = await callHttp(functions.activateLicense, "POST", {
    licenseKey: issued.licenseKey,
    farmId: "farm-alpha",
  }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(repeatActivation.statusCode, 200);
  const otherFarmActivation = await callHttp(functions.activateLicense, "POST", {
    licenseKey: issued.licenseKey,
    farmId: "farm-beta",
  }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(otherFarmActivation.statusCode, 409);

  await assert.rejects(
    functions.transferLicense(adminRequest({
      licenseId: issued.licenseId,
      newFarmId: "farm-alpha",
    })),
    (error) => error.code === "failed-precondition",
  );

  const transfer = await functions.transferLicense(adminRequest({
    licenseId: issued.licenseId,
    newFarmId: "farm-beta",
  }));
  assert.equal(transfer.transferred, true);
  const newFarmStatus = await callHttp(functions.checkLicense, "POST", {
    farmId: "farm-beta",
    licenseId: issued.licenseId,
  }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(newFarmStatus.body.status, "active");

  const revoked = await functions.revokeLicense(adminRequest({ licenseId: issued.licenseId }));
  assert.equal(revoked.revoked, true);
  const reactivation = await callHttp(functions.activateLicense, "POST", {
    licenseKey: issued.licenseKey,
    farmId: "farm-beta",
  }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(reactivation.statusCode, 409);
  const afterRevocation = await callHttp(functions.checkLicense, "POST", {
    farmId: "farm-beta",
    licenseId: issued.licenseId,
  }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(afterRevocation.body.status, "inactive");
  const withoutId = await callHttp(functions.checkLicense, "POST", { farmId: "farm-beta" }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(withoutId.body.status, "inactive");

  const listing = await functions.listLicenses(adminRequest());
  assert.equal(listing.licenses.length, 1);
  assert.equal(listing.licenses[0].status, "revoked");
  assert.equal(listing.licenses[0].activatedFarmId, "farm-beta");
  assert.equal(database.collections.get("licenseEvents").size, 3);
});

test("mantém um único trial de 30 dias por fazenda", async () => {
  const { functions, database, secrets } = loadFunctions();
  const first = await callHttp(functions.checkLicense, "POST", { farmId: "farm-trial" }, secrets.LICENSE_SERVER_API_KEY);
  const second = await callHttp(functions.checkLicense, "POST", { farmId: "farm-trial" }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(first.body.status, "trial");
  assert.equal(second.body.status, "trial");
  assert.equal(first.body.trialStartedAt, second.body.trialStartedAt);
  assert.equal(Date.parse(first.body.trialEndsAt) - Date.parse(first.body.trialStartedAt), 30 * DAY_MS);
  assert.equal(database.collections.get("farmTrials").size, 1);

  fakeClock.value = new Date(fakeClock.value.getTime() + 31 * DAY_MS);
  const afterDeadline = await callHttp(functions.checkLicense, "POST", { farmId: "farm-trial" }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(afterDeadline.body.status, "expired");
  assert.equal(afterDeadline.body.trialStartedAt, first.body.trialStartedAt);
});

test("permite revogar uma chave emitida antes da ativação", async () => {
  const { functions, secrets } = loadFunctions();
  const issued = await functions.issueLicense(adminRequest());
  const result = await functions.revokeLicense(adminRequest({ licenseId: issued.licenseId }));
  assert.equal(result.revoked, true);

  const activation = await callHttp(functions.activateLicense, "POST", {
    licenseKey: issued.licenseKey,
    farmId: "farm-not-activated",
  }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(activation.statusCode, 409);
  assert.match(activation.body.detail, /revogada/i);
});

test("não transforma uma falha do Firestore em licença revogada", async () => {
  const { functions, database, secrets } = loadFunctions();
  const issued = await functions.issueLicense(adminRequest());
  database.runTransaction = async () => { throw new Error("firestore unavailable"); };

  await assert.rejects(
    callHttp(functions.activateLicense, "POST", {
      licenseKey: issued.licenseKey,
      farmId: "farm-alpha",
    }, secrets.LICENSE_SERVER_API_KEY),
    /firestore unavailable/,
  );
});


test("ativação mensal é idempotente e não reabre teste após expiração", async () => {
  const { functions, secrets } = loadFunctions();
  const issued = await functions.issueLicense(adminRequest({ plan: "monthly" }));
  const body = { licenseKey: issued.licenseKey, farmId: "farm-monthly" };
  const first = await callHttp(functions.activateLicense, "POST", body, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(first.statusCode, 200);
  fakeClock.value = new Date(fakeClock.value.getTime() + 10 * DAY_MS);
  const repeated = await callHttp(functions.activateLicense, "POST", body, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(repeated.body.expiresAt, first.body.expiresAt);
  fakeClock.value = new Date(fakeClock.value.getTime() + 21 * DAY_MS);
  assert.equal((await callHttp(functions.activateLicense, "POST", body, secrets.LICENSE_SERVER_API_KEY)).statusCode, 409);
  const expired = await callHttp(functions.checkLicense, "POST", { farmId: "farm-monthly" }, secrets.LICENSE_SERVER_API_KEY);
  assert.equal(expired.body.status, "inactive");
});
