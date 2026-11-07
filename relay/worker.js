// Eight Sleep relay — a Cloudflare Worker that holds the Eight Sleep login and
// exposes a few tiny HTTPS endpoints for the Garmin watch app.
//
// Endpoints (all require header  Authorization: Bearer <RELAY_SECRET>):
//   GET  /status            -> { side, userId, level, state }
//   POST /adjust {delta}    -> nudges the target level by delta (clamped -100..100), turns side on
//   POST /set    {level}    -> sets the target level exactly, turns side on
//   POST /on                -> turns the side on (smart mode)
//   POST /off               -> turns the side off
//   GET  /debug             -> who you are, your device, left/right user ids and current levels
//
// Env (wrangler vars / secrets):
//   EIGHT_EMAIL, EIGHT_PASSWORD   (secrets) the login used in the Eight Sleep app
//   RELAY_SECRET                  (secret)  random string the watch must present
//   SIDE                          (var)     default side when the watch doesn't say:
//                                           "left" | "right" | "me"   (default "me")
//
// Each watch says which side it controls with  ?side=left  (GET) or  {"side":"left"}
// (POST), so one relay serves both people in the bed.
//   EIGHT_CLIENT_ID / EIGHT_CLIENT_SECRET (optional) override the public app client
//   TOKENS                        (KV binding, optional) caches the Eight Sleep token
//
// The Eight Sleep API is unofficial and undocumented; endpoints mirror the
// Home Assistant integration (lukas-clarke/eight_sleep) and may change.

const AUTH_URL = "https://auth-api.8slp.net/v1/tokens";
const CLIENT_API = "https://client-api.8slp.net/v1";
const APP_API = "https://app-api.8slp.net/v1";
const KNOWN_CLIENT_ID = "0894c7f33bb94800a03f1f4df13a4f38";
const KNOWN_CLIENT_SECRET =
  "f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76";
const CACHE_KEY = "eight_session_v1";
const TOKEN_BUFFER_MS = 2 * 60 * 1000;

const SIDES = ["me", "left", "right"];
const memCache = new Map(); // side -> session; survives while the worker isolate is warm

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch (err) {
      const status = err.status || 502;
      return json({ error: String(err.message || err) }, status);
    }
  },
  _resetCache() {
    memCache.clear();
  },
};

async function handle(request, env) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";

  if (path === "/") {
    return json({ ok: true, service: "eight-sleep-relay" });
  }

  requireSecret(request, env);

  const method = request.method.toUpperCase();
  const body = method === "POST" ? await readJson(request) : {};
  const side = pickSide(body.side ?? url.searchParams.get("side"), env);

  switch (`${method} ${path}`) {
    case "GET /status": {
      const s = await session(env, side);
      const t = await getTemperature(env, s);
      return json(summarize(s, t));
    }
    case "GET /debug": {
      const s = await session(env, side);
      const me = await api(env, s, "GET", `${CLIENT_API}/users/me`);
      const deviceId = me?.user?.currentDevice?.id;
      let device = null;
      if (deviceId) {
        const filter =
          "leftUserId,rightUserId,leftTargetHeatingLevel,rightTargetHeatingLevel," +
          "leftHeatingLevel,rightHeatingLevel,leftNowHeating,rightNowHeating";
        device = await api(
          env,
          s,
          "GET",
          `${CLIENT_API}/devices/${deviceId}?filter=${filter}`
        );
      }
      return json({
        loginUserId: s.userId,
        controllingUserId: s.sideUserId,
        side: s.side,
        me: me?.user
          ? {
              userId: me.user.userId,
              firstName: me.user.firstName,
              currentDevice: me.user.currentDevice,
            }
          : me,
        device: device?.result ?? device,
      });
    }
    case "POST /adjust": {
      const delta = toInt(body.delta, "delta");
      const s = await session(env, side);
      const t = await getTemperature(env, s);
      const current = Number.isFinite(Number(t.currentLevel))
        ? Number(t.currentLevel)
        : 0;
      const level = clamp(current + delta);
      await ensureOn(env, s, t);
      await setLevel(env, s, level);
      return json({ side: s.side, level, state: "smart", previous: current });
    }
    case "POST /set": {
      const level = clamp(toInt(body.level, "level"));
      const s = await session(env, side);
      const t = await getTemperature(env, s);
      await ensureOn(env, s, t);
      await setLevel(env, s, level);
      return json({ side: s.side, level, state: "smart" });
    }
    case "POST /on": {
      const s = await session(env, side);
      await setState(env, s, "smart");
      return json({ side: s.side, state: "smart" });
    }
    case "POST /off": {
      const s = await session(env, side);
      await setState(env, s, "off");
      return json({ side: s.side, state: "off" });
    }
    default:
      return json({ error: `no route for ${method} ${path}` }, 404);
  }
}

// ---------- auth to the relay ----------

function requireSecret(request, env) {
  if (!env.RELAY_SECRET) throw httpError(500, "RELAY_SECRET is not configured");
  const header = request.headers.get("authorization") || "";
  const presented = header.replace(/^Bearer\s+/i, "").trim();
  if (!presented || !timingSafeEqual(presented, env.RELAY_SECRET)) {
    throw httpError(401, "unauthorized");
  }
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ---------- Eight Sleep session (token + which user/side we control) ----------

function pickSide(requested, env) {
  const side = String(requested || env.SIDE || "me").toLowerCase();
  if (!SIDES.includes(side)) {
    throw httpError(400, `side must be one of ${SIDES.join(", ")}`);
  }
  return side;
}

async function session(env, side, forceLogin = false) {
  const now = Date.now();
  const cacheKey = `${CACHE_KEY}:${side}`;

  if (!forceLogin) {
    let cached = memCache.get(side);
    if (!cached && env.TOKENS) {
      const raw = await env.TOKENS.get(cacheKey);
      if (raw) cached = JSON.parse(raw);
    }
    if (
      cached &&
      cached.side === side &&
      cached.expiresAt - TOKEN_BUFFER_MS > now &&
      cached.sideUserId
    ) {
      memCache.set(side, cached);
      return cached;
    }
  }

  if (!env.EIGHT_EMAIL || !env.EIGHT_PASSWORD) {
    throw httpError(500, "EIGHT_EMAIL / EIGHT_PASSWORD secrets are not set");
  }

  const res = await fetch(AUTH_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      "user-agent": "okhttp/4.9.3",
    },
    body: JSON.stringify({
      client_id: env.EIGHT_CLIENT_ID || KNOWN_CLIENT_ID,
      client_secret: env.EIGHT_CLIENT_SECRET || KNOWN_CLIENT_SECRET,
      grant_type: "password",
      username: env.EIGHT_EMAIL,
      password: env.EIGHT_PASSWORD,
    }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw httpError(
      res.status === 429 ? 429 : 502,
      `Eight Sleep login failed (${res.status}): ${text.slice(0, 200)}`
    );
  }
  const auth = await res.json();
  const s = {
    accessToken: auth.access_token,
    userId: auth.userId,
    expiresAt: now + Number(auth.expires_in || 3600) * 1000,
    side,
    sideUserId: null,
  };

  s.sideUserId = await resolveSideUser(env, s);

  memCache.set(side, s);
  if (env.TOKENS) {
    const ttl = Math.max(60, Math.floor((s.expiresAt - now) / 1000));
    await env.TOKENS.put(cacheKey, JSON.stringify(s), { expirationTtl: ttl });
  }
  return s;
}

async function resolveSideUser(env, s) {
  if (s.side !== "left" && s.side !== "right") return s.userId;
  const me = await api(env, s, "GET", `${CLIENT_API}/users/me`);
  const deviceId = me?.user?.currentDevice?.id;
  if (!deviceId) throw httpError(502, "could not find a current device on this account");
  const dev = await api(
    env,
    s,
    "GET",
    `${CLIENT_API}/devices/${deviceId}?filter=leftUserId,rightUserId`
  );
  const id = s.side === "left" ? dev?.result?.leftUserId : dev?.result?.rightUserId;
  if (!id) {
    throw httpError(
      502,
      `no user is assigned to the ${s.side} side; call /debug to see the device`
    );
  }
  return id;
}

// ---------- Eight Sleep temperature calls ----------

function tempUrl(s) {
  return `${APP_API}/users/${s.sideUserId}/temperature`;
}

async function getTemperature(env, s) {
  return api(env, s, "GET", tempUrl(s));
}

async function setLevel(env, s, level) {
  return api(env, s, "PUT", tempUrl(s), { currentLevel: level });
}

async function setState(env, s, type) {
  return api(env, s, "PUT", tempUrl(s), { currentState: { type } });
}

async function ensureOn(env, s, t) {
  const type = t?.currentState?.type;
  if (type !== "smart") await setState(env, s, "smart");
}

function summarize(s, t) {
  return {
    side: s.side,
    userId: s.sideUserId,
    level: Number.isFinite(Number(t?.currentLevel)) ? Number(t.currentLevel) : null,
    state: t?.currentState?.type ?? null,
  };
}

// One authenticated call to the Eight Sleep API; re-logs in once on 401.
async function api(env, s, method, url, data, retried = false) {
  const res = await fetch(url, {
    method,
    headers: {
      authorization: `Bearer ${s.accessToken}`,
      "content-type": "application/json",
      accept: "application/json",
      "user-agent": "okhttp/4.9.3",
    },
    body: data === undefined ? undefined : JSON.stringify(data),
  });
  if (res.status === 401 && !retried) {
    memCache.delete(s.side);
    if (env.TOKENS) await env.TOKENS.delete(`${CACHE_KEY}:${s.side}`);
    const fresh = await session(env, s.side, true);
    Object.assign(s, fresh);
    return api(env, s, method, url, data, true);
  }
  if (!res.ok) {
    const text = await res.text();
    throw httpError(
      res.status === 429 ? 429 : 502,
      `Eight Sleep ${method} ${url} -> ${res.status}: ${text.slice(0, 200)}`
    );
  }
  const text = await res.text();
  return text ? JSON.parse(text) : {};
}

// ---------- helpers ----------

function clamp(n) {
  return Math.max(-100, Math.min(100, Math.round(n)));
}

function toInt(v, name) {
  const n = Number(v);
  if (!Number.isFinite(n)) throw httpError(400, `${name} must be a number`);
  return Math.round(n);
}

async function readJson(request) {
  const text = await request.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    // Connect IQ may send url-encoded bodies if the content type is lost.
    const params = new URLSearchParams(text);
    return Object.fromEntries(params.entries());
  }
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function httpError(status, message) {
  const e = new Error(message);
  e.status = status;
  return e;
}
