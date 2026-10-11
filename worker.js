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
    if (request.method === "GET") return json({ ok: true, service: "lcs-api", message: "Worker is running" }, 200, cors);
    if (request.method !== "POST") return json({ error: "Use POST for tracking." }, 405, cors);

    try {
      if (!env.LCS_API_KEY || !env.LCS_API_PASSWORD || !env.FIREBASE_PROJECT_ID) {
        console.error("Required Worker configuration is missing.");
        return json({ error: "Server configuration error." }, 500, cors);
      }
      const auth = request.headers.get("Authorization") || "";
      const match = auth.match(/^Bearer\s+(.+)$/i);
      if (!match) return json({ error: "Missing Firebase ID token." }, 401, cors);
      const user = await verifyFirebaseToken(match[1].trim(), env.FIREBASE_PROJECT_ID);
      if (!user) return json({ error: "Invalid or expired Firebase token." }, 401, cors);

      const contentType = request.headers.get("Content-Type") || "";
      if (!contentType.toLowerCase().includes("application/json")) return json({ error: "Content-Type must be application/json." }, 415, cors);
      const raw = await request.text();
      if (raw.length > 32000) return json({ error: "Request body too large." }, 413, cors);
      let body;
      try { body = JSON.parse(raw); } catch { return json({ error: "Invalid JSON body." }, 400, cors); }
      if (!body || !Array.isArray(body.track_numbers)) return json({ error: 'Expected {"track_numbers":["CN_NUMBER"]}.' }, 400, cors);
      if (body.track_numbers.length < 1 || body.track_numbers.length > MAX_CNS) return json({ error: `Send between 1 and ${MAX_CNS} CN numbers.` }, 400, cors);

      const numbers = body.track_numbers.map(v => typeof v === "string" ? v.trim() : "");
      if (numbers.some(v => v.length < 4 || v.length > 40 || !/^[A-Za-z0-9-]+$/.test(v))) return json({ error: "Invalid CN number format." }, 400, cors);
      const upstream = await fetch(LCS_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify({ api_key: env.LCS_API_KEY, api_password: env.LCS_API_PASSWORD, track_numbers: numbers })
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
        return json({ error: "LCS tracking service returned an error.", upstream_status: upstream.status, details: result }, 502, cors);
      }
      return json(result, 200, cors);
    } catch (error) {
      console.error("Worker failed:", error?.message || String(error));
      return json({ error: "Worker request failed. Check Cloudflare logs." }, 500, cors);
    }
  }
};

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
