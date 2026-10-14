/**
 * LCS Tracker - Cloudflare Worker
 * POST / { "track_numbers": ["SR7543384211"] }
 * Header: Authorization: Bearer <Firebase ID token>
 * Secrets: LCS_API_KEY, LCS_API_PASSWORD
 * Variable: FIREBASE_PROJECT_ID
 */
const LCS_URL = "https://merchantapi.leopardscourier.com/api/trackBookedPacket/format/json/";
const FIREBASE_KEYS_URL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
const MAX_CNS = 20;
let jwksCache = null;
let jwksCacheTime = 0;

export default {
  async fetch(request, env) {
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Authorization, Content-Type",
      "Access-Control-Max-Age": "86400",
    };
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (request.method === "GET") {
      const url = new URL(request.url);
      if (url.pathname === "/push") return json({ ok: true, endpoint: "lcs-push", message: "Push endpoint is deployed; configure secrets before registering in LCS." }, 200);
      return json({ ok: true, service: "lcs-api", message: "Worker is running" }, 200, cors);
    }
    const url = new URL(request.url);
    if (url.pathname === "/push") {
      if (request.method !== "POST") return json({ error: "Use POST for LCS push events." }, 405);
      return handleLcsPush(request, env);
    }

    if (request.method !== "POST") return json({ error: "Use POST for tracking." }, 405, cors);

    try {
      if (!env.LCS_API_KEY || !env.LCS_API_PASSWORD || !env.FIREBASE_PROJECT_ID) {
        console.error("Required Worker configuration is missing.");
        return json({ error: "Server configuration error." }, 500, cors);
      }
      const auth = request.headers.get("Authorization") || "";
      const match = auth.match(/^Bearer\s+(.+)$/i);
      if (!match) return json({ error: "Missing Firebase ID token." }, 401, cors);
      const idToken = match[1].trim();
      const user = await verifyFirebaseToken(idToken, env.FIREBASE_PROJECT_ID);
      if (!user) return json({ error: "Invalid or expired Firebase token." }, 401, cors);

      // Verify the user's Firestore profile and active state server-side.
      // A valid Firebase token alone must not grant access to the courier API.
      const profile = await loadUserProfile(env.FIREBASE_PROJECT_ID, idToken, user.uid);
      if (!profile) return json({ error: "User profile unavailable or access denied." }, 403, cors);
      if (profile.active === false) return json({ error: "Account is disabled." }, 403, cors);
      if (profile.role !== "admin" && profile.role !== "worker") {
        return json({ error: "Account role is not authorized." }, 403, cors);
      }

      const contentType = request.headers.get("Content-Type") || "";
      if (!contentType.toLowerCase().includes("application/json")) return json({ error: "Content-Type must be application/json." }, 415, cors);
      const raw = await request.text();
      if (raw.length > 32000) return json({ error: "Request body too large." }, 413, cors);
      let body;
      try { body = JSON.parse(raw); } catch { return json({ error: "Invalid JSON body." }, 400, cors); }
      if (!body || !Array.isArray(body.track_numbers)) return json({ error: 'Expected {"track_numbers":["CN_NUMBER"]}.' }, 400, cors);
      if (body.track_numbers.length < 1 || body.track_numbers.length > MAX_CNS) return json({ error: `Send between 1 and ${MAX_CNS} CN numbers.` }, 400, cors);

      // LCS_SECURITY_IDEMPOTENCY_LOGGING_V1
      const submittedNumbers = body.track_numbers.map(v => typeof v === "string" ? v.trim() : "");
      if (submittedNumbers.some(v => v.length < 4 || v.length > 40 || !/^[A-Za-z0-9-]+$/.test(v))) {
        console.warn("LCS tracking request rejected: invalid CN format.", { uid: user.uid, submittedCount: submittedNumbers.length });
        return json({ error: "Invalid CN number format." }, 400, cors);
      }
      const numbers = [...new Set(submittedNumbers)];

      // Workers may track only CNs assigned to their own orders. Admins retain
      // organization-wide lookup access. Firestore security rules must permit
      // workers to query orders where workerUid equals their authenticated UID.
      if (profile.role !== "admin") {
        for (const cn of numbers) {
          const owned = await userOwnsOrder(env.FIREBASE_PROJECT_ID, idToken, user.uid, cn);
          if (!owned) {
            return json({ error: "One or more tracking numbers are not assigned to this account." }, 403, cors);
          }
        }
      }
      console.log("LCS tracking request accepted.", { uid: user.uid, requestedCount: submittedNumbers.length, uniqueCount: numbers.length });

      const upstream = await fetch(LCS_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify({ api_key: env.LCS_API_KEY, api_password: env.LCS_API_PASSWORD, track_numbers: numbers.join(",") })
      });
      const responseText = await upstream.text();
      console.log("LCS upstream HTTP status:", upstream.status);
      let result;
      try { result = JSON.parse(responseText); }
      catch {
        console.error("LCS returned non-JSON response.");
        return json({ error: "LCS returned a non-JSON response.", upstream_status: upstream.status }, 502, cors);
      }
      if (!upstream.ok) {
        console.error("LCS upstream HTTP error:", upstream.status);
        return json({ error: "LCS tracking service returned an error.", upstream_status: upstream.status }, 502, cors);
      }

      // Do not log CN numbers, customer data, or courier status payloads.
      return json(result, 200, cors);
    } catch (error) {
      console.error("Worker failed:", error?.message || String(error));
      return json({ error: "Worker request failed. Check Cloudflare logs." }, 500, cors);
    }
  }
};

async function loadUserProfile(projectId, idToken, uid) {
  try {
    const path = `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/databases/(default)/documents/users/${encodeURIComponent(uid)}`;
    const response = await fetch(path, {
      headers: { Authorization: `Bearer ${idToken}`, Accept: "application/json" },
    });
    if (!response.ok) return null;
    const document = await response.json();
    const fields = document?.fields || {};
    const role = fields.role?.stringValue;
    const activeField = fields.active;
    const active = activeField == null
      ? true
      : activeField.booleanValue === true ||
        (activeField.stringValue != null && activeField.stringValue.toLowerCase() === "true");
    if (typeof role !== "string" || !role.trim()) return null;
    return { role: role.trim().toLowerCase(), active };
  } catch {
    return null;
  }
}

async function userOwnsOrder(projectId, idToken, uid, cn) {
  try {
    const endpoint = `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/databases/(default)/documents:runQuery`;
    const query = {
      structuredQuery: {
        from: [{ collectionId: "orders" }],
        where: {
          compositeFilter: {
            op: "AND",
            filters: [
              { fieldFilter: { field: { fieldPath: "workerUid" }, op: "EQUAL", value: { stringValue: uid } } },
              { fieldFilter: { field: { fieldPath: "cn" }, op: "EQUAL", value: { stringValue: cn } } },
            ],
          },
        },
        limit: 1,
      },
    };
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${idToken}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(query),
    });
    if (!response.ok) return false;
    const rows = await response.json();
    return Array.isArray(rows) && rows.some(row => typeof row?.document?.name === "string");
  } catch {
    return false;
  }
}

async function handleLcsPush(request, env) {
  try {
    if (!env.LCS_PUSH_SECRET || !env.FIREBASE_SERVICE_ACCOUNT_JSON || !env.FIREBASE_PROJECT_ID) {
      console.error("Push endpoint configuration is missing.");
      return json([{ status: 0, errors: ["Push endpoint is not configured."] }], 503);
    }
    const supplied = request.headers.get("X-LCS-Push-Secret") || "";
    if (!constantTimeEqual(supplied, env.LCS_PUSH_SECRET)) {
      return json([{ status: 0, errors: ["Unauthorized"] }], 401);
    }
    const raw = await request.text();
    if (raw.length > 256000) return json([{ status: 0, errors: ["Payload too large"] }], 413);
    let body;
    try { body = JSON.parse(raw); } catch { return json([{ status: 0, errors: ["Invalid JSON"] }], 400); }
    if (!body || !Array.isArray(body.data) || body.data.length === 0) {
      return json([{ status: 0, errors: ["Expected non-empty data array"] }], 400);
    }
    const serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT_JSON);
    if (serviceAccount.project_id !== env.FIREBASE_PROJECT_ID || !serviceAccount.client_email || !serviceAccount.private_key) {
      return json([{ status: 0, errors: ["Firebase service account configuration invalid"] }], 503);
    }
    const accessToken = await getGoogleAccessToken(serviceAccount);
    // Bound batch size and report aggregate outcomes without logging payload/secrets.
    if (body.data.length > 100) return json([{ status: 0, errors: ["Too many events in one request"] }], 413);
    const results = [];
    const seenEvents = new Set();
    for (const item of body.data) {
      const cn = String(item?.cn_number ?? "").trim();
      const status = String(item?.status ?? "").trim();
      const reason = String(item?.reason ?? "").trim();
      const receiverName = String(item?.receiver_name ?? "").trim();
      const activityDate = String(item?.activity_date ?? "").trim();
      if (!cn || !status) {
        results.push({ cn_number: cn, ok: false, error: "Missing cn_number or status" });
        continue;
      }
      const matched = await findOrderByCn(env.FIREBASE_PROJECT_ID, accessToken, cn);
      if (!matched) {
        results.push({ cn_number: cn, ok: false, error: "Order not found" });
        continue;
      }
      const eventKey = [cn, status, activityDate, reason].join("|");
      if (seenEvents.has(eventKey)) {
        results.push({ cn_number: cn, ok: true });
        continue;
      }
      seenEvents.add(eventKey);
      const event = { cn_number: cn, status, reason, receiver_name: receiverName, activity_date: activityDate, received_at: new Date().toISOString() };
      await writeOrderStatus(env.FIREBASE_PROJECT_ID, accessToken, matched.name, event);
      results.push({ cn_number: cn, ok: true });
    }
    const failed = results.some(r => !r.ok);
    console.log("LCS push batch processed.", { eventCount: body.data.length, successCount: results.filter(r => r.ok).length, failureCount: results.filter(r => !r.ok).length });
    // LCS expects HTTP 202 and status=1 for successful processing.
    // Return a failure when any event could not be matched/saved so it can be investigated.
    if (failed) return json([{ status: 0, errors: results.filter(r => !r.ok) }], 400);
    return json([{ status: 1, errors: [] }], 202);
  } catch (error) {
    console.error("LCS push processing failed:", error?.message || String(error));
    return json([{ status: 0, errors: ["Internal processing error"] }], 500);
  }
}

function summarizeStatusEvents(packet) {
  const events = [];
  const statusKey = /^(status|bookedpacketstatus|activity|trackingstatus|statusdescription|eventstatus|description|remarks?|eventdescription|trackingstatusdescription)$/i;
  const dateKey = /(date|time|datetime)$/i;
  const allowedStatus = /(return|rts|deliver|arriv|dispatch|picked|out for delivery|pending|hold|cancel|attempt|consign|received|transit|booked|collected|undelivered)/i;
  const seen = new Set();
  function visit(value, depth = 0) {
    if (depth > 7 || events.length >= 30 || value == null) return;
    if (typeof value === "string") {
      try {
        const parsed = JSON.parse(value);
        if (parsed && typeof parsed === "object") visit(parsed, depth + 1);
      } catch (_) {}
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) visit(item, depth + 1);
      return;
    }
    if (typeof value !== "object") return;
    const entries = Object.entries(value);
    let status = "";
    let date = "";
    for (const [key, raw] of entries) {
      if (typeof raw !== "string" && typeof raw !== "number") continue;
      const text = String(raw).trim();
      if (!text) continue;
      if (statusKey.test(key.replace(/[^a-z]/gi, "")) && allowedStatus.test(text)) status = text;
      if (dateKey.test(key.replace(/[^a-z]/gi, "")) && /\d{4}|\d{1,2}[/-]\d{1,2}[/-]\d{4}/.test(text)) date = text;
    }
    if (status) {
      const key = status + "|" + date;
      if (!seen.has(key)) {
        seen.add(key);
        events.push({ status: status.slice(0, 120), date: date.slice(0, 40) });
      }
    }
    for (const [key, child] of entries) {
      if (child && typeof child === "object") visit(child, depth + 1);
      else if (typeof child === "string" && /tracking|history|detail|activity|event|status/i.test(key)) visit(child, depth + 1);
    }
  }
  visit(packet);
  return events;
}

function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
function b64urlBytes(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function b64url(value) { return b64urlBytes(new TextEncoder().encode(JSON.stringify(value))); }
async function getGoogleAccessToken(sa) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url({ alg: "RS256", typ: "JWT" });
  const claim = b64url({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/datastore", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 });
  const unsigned = header + "." + claim;
  const pem = sa.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const keyBytes = decode64url(pem.replace(/\+/g, "-").replace(/\//g, "_"));
  const key = await crypto.subtle.importKey("pkcs8", keyBytes, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)));
  const assertion = unsigned + "." + b64urlBytes(signature);
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion })
  });
  const data = await response.json();
  if (!response.ok || !data.access_token) throw new Error("Google OAuth token exchange failed.");
  return data.access_token;
}
async function findOrderByCn(projectId, token, cn) {
  const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:runQuery`;
  const response = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ structuredQuery: {
      from: [{ collectionId: "orders" }],
      where: { fieldFilter: { field: { fieldPath: "cn" }, op: "EQUAL", value: { stringValue: cn } } },
      limit: 2
    } })
  });
  const data = await response.json();
  if (!response.ok) throw new Error("Firestore order lookup failed.");
  const docs = data.filter(row => row.document).map(row => row.document);
  if (docs.length !== 1) return null; // Avoid updating an ambiguous duplicate CN.
  return docs[0];
}
async function writeOrderStatus(projectId, token, documentName, event) {
  const base = `https://firestore.googleapis.com/v1/${documentName}`;
  const statusDate = parseLcsDate(event.activity_date);
  const fields = {
    status: { stringValue: event.status },
    lcsRawStatus: { stringValue: event.status },
    lastApiSyncAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
    lcsPushReason: { stringValue: event.reason },
    lcsReceiverName: { stringValue: event.receiver_name }
  };
  if (statusDate) fields.statusDate = { timestampValue: statusDate };
  const patchUrl = base + "?updateMask.fieldPaths=status&updateMask.fieldPaths=lcsRawStatus&updateMask.fieldPaths=lastApiSyncAt&updateMask.fieldPaths=updatedAt&updateMask.fieldPaths=lcsPushReason&updateMask.fieldPaths=lcsReceiverName" + (statusDate ? "&updateMask.fieldPaths=statusDate" : "");
  const patch = await fetch(patchUrl, {
    method: "PATCH", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ fields })
  });
  if (!patch.ok) throw new Error("Firestore order update failed.");
  const eventId = await sha256Hex(JSON.stringify([event.cn_number, event.status, event.activity_date, event.reason]));
  const historyUrl = `https://firestore.googleapis.com/v1/${documentName}/lcsStatusHistory?documentId=${eventId}`;
  const history = await fetch(historyUrl, {
    method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ fields: {
      cn_number: { stringValue: event.cn_number }, status: { stringValue: event.status },
      reason: { stringValue: event.reason }, receiver_name: { stringValue: event.receiver_name },
      activity_date: { stringValue: event.activity_date }, received_at: { timestampValue: event.received_at }
    }})
  });
  if (!history.ok && history.status !== 409) throw new Error("Firestore status history write failed.");
}
function parseLcsDate(value) {
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!m) return null;
  const date = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)));
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}
async function sha256Hex(value) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return [...digest].map(b => b.toString(16).padStart(2, "0")).join("");
}

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers }
  });
}
function decode64url(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - base64.length % 4) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
function decode64urlText(value) { return new TextDecoder().decode(decode64url(value)); }
async function getFirebaseKeys(forceRefresh = false) {
  if (!forceRefresh && jwksCache && Date.now() - jwksCacheTime < 3600000) return jwksCache;
  const response = await fetch(FIREBASE_KEYS_URL, { headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error("Unable to fetch Firebase signing keys.");
  const data = await response.json();
  if (!Array.isArray(data.keys)) throw new Error("Invalid Firebase signing keys.");
  jwksCache = data.keys;
  jwksCacheTime = Date.now();
  return jwksCache;
}
async function verifyFirebaseToken(token, projectId) {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const header = JSON.parse(decode64urlText(parts[0]));
    const claims = JSON.parse(decode64urlText(parts[1]));
    const now = Math.floor(Date.now() / 1000);
    if (header.alg !== "RS256" || typeof header.kid !== "string" ||
        claims.aud !== projectId || claims.iss !== `https://securetoken.google.com/${projectId}` ||
        typeof claims.sub !== "string" || claims.sub.length === 0 ||
        !Number.isFinite(claims.exp) || claims.exp <= now ||
        !Number.isFinite(claims.iat) || claims.iat > now + 300) return null;
    let keys = await getFirebaseKeys();
    let jwk = keys.find(k => k.kid === header.kid && k.kty === "RSA");
    if (!jwk) {
      keys = await getFirebaseKeys(true);
      jwk = keys.find(k => k.kid === header.kid && k.kty === "RSA");
    }
    if (!jwk) return null;
    const publicKey = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    const signedData = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, decode64url(parts[2]), signedData);
    return valid ? claims : null;
  } catch (error) {
    console.error("Firebase verification failed:", error?.message || String(error));
    return null;
  }
}
