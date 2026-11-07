// Exercises the relay against a fake Eight Sleep API. Run:  node --test relay/
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.js";

const SECRET = "s3cret";

beforeEach(() => worker._resetCache());

function fakeEight(opts = {}) {
  const calls = [];
  const state = { level: 20, type: "smart", ...opts.state };
  let tokenNo = 0;
  globalThis.fetch = async (url, init = {}) => {
    const method = init.method || "GET";
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ method, url, body, auth: init.headers?.authorization });
    const ok = (obj, status = 200) =>
      new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });

    if (url.endsWith("/v1/tokens")) {
      if (opts.loginStatus) return new Response("nope", { status: opts.loginStatus });
      tokenNo++;
      return ok({ access_token: `tok${tokenNo}`, userId: "me123", expires_in: 3600 });
    }
    if (opts.expireFirstToken && init.headers.authorization === "Bearer tok1") {
      return new Response("expired", { status: 401 });
    }
    if (url.endsWith("/users/me")) return ok({ user: { userId: "me123", currentDevice: { id: "dev1", side: "left" } } });
    if (url.includes("/devices/dev1")) return ok({ result: { leftUserId: "me123", rightUserId: "partner456" } });
    if (url.endsWith("/temperature")) {
      if (method === "GET") return ok({ currentLevel: state.level, currentState: { type: state.type } });
      if (method === "PUT") {
        if (body.currentLevel !== undefined) state.level = body.currentLevel;
        if (body.currentState) state.type = body.currentState.type;
        return ok({});
      }
    }
    return new Response("not found", { status: 404 });
  };
  return { calls, state };
}

function env(extra = {}) {
  return { EIGHT_EMAIL: "a@b.c", EIGHT_PASSWORD: "pw", RELAY_SECRET: SECRET, SIDE: "me", ...extra };
}

async function call(e, method, path, body) {
  const req = new Request(`https://relay.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const res = await worker.fetch(req, e);
  return { status: res.status, json: await res.json() };
}

test("rejects a missing or wrong secret", async () => {
  fakeEight();
  const res = await worker.fetch(new Request("https://relay.test/status"), env());
  assert.equal(res.status, 401);
  const bad = await worker.fetch(
    new Request("https://relay.test/status", { headers: { authorization: "Bearer wrong" } }), env());
  assert.equal(bad.status, 401);
});

test("status logs in once and reports the level", async () => {
  const f = fakeEight();
  const e = env();
  const a = await call(e, "GET", "/status");
  assert.deepEqual(a, { status: 200, json: { side: "me", userId: "me123", level: 20, state: "smart" } });
  await call(e, "GET", "/status");
  assert.equal(f.calls.filter((c) => c.url.endsWith("/tokens")).length, 1, "token reused from memory");
});

test("adjust nudges the level and clamps", async () => {
  const f = fakeEight({ state: { level: 95 } });
  const e = env({ SIDE: "me" });
  const r = await call(e, "POST", "/adjust", { delta: 10 });
  assert.equal(r.status, 200);
  assert.equal(r.json.level, 100);
  assert.equal(f.state.level, 100);
  const puts = f.calls.filter((c) => c.method === "PUT");
  assert.equal(puts.length, 1, "side already on: only the level is written");
});

test("adjust turns the side on when it was off", async () => {
  const f = fakeEight({ state: { level: 0, type: "off" } });
  const r = await call(env(), "POST", "/adjust", { delta: -10 });
  assert.equal(r.json.level, -10);
  assert.equal(f.state.type, "smart");
  const puts = f.calls.filter((c) => c.method === "PUT").map((c) => c.body);
  assert.deepEqual(puts, [{ currentState: { type: "smart" } }, { currentLevel: -10 }]);
});

test("a side in a smart phase counts as on: no extra state write", async () => {
  const f = fakeEight({ state: { level: 20, type: "smart:bedtime" } });
  const r = await call(env(), "POST", "/adjust", { delta: 10 });
  assert.equal(r.json.level, 30);
  assert.equal(r.json.state, "smart:bedtime");
  const puts = f.calls.filter((c) => c.method === "PUT").map((c) => c.body);
  assert.deepEqual(puts, [{ currentLevel: 30 }]);
});

test("SIDE=right controls the partner's user id", async () => {
  const f = fakeEight();
  const r = await call(env({ SIDE: "right" }), "GET", "/status");
  assert.equal(r.json.userId, "partner456");
  assert.ok(f.calls.some((c) => c.url.includes("/users/partner456/temperature")));
});

test("re-logs in once on a 401 from Eight Sleep", async () => {
  const f = fakeEight({ expireFirstToken: true });
  const r = await call(env({ SIDE: "left" }), "GET", "/status");
  assert.equal(r.status, 200);
  assert.equal(f.calls.filter((c) => c.url.endsWith("/tokens")).length, 2);
});

test("login failure surfaces as an error, 429 passes through", async () => {
  fakeEight({ loginStatus: 429 });
  const r = await call(env(), "GET", "/status");
  assert.equal(r.status, 429);
  assert.match(r.json.error, /login failed/);
});

test("accepts url-encoded bodies and rejects non-numeric delta", async () => {
  fakeEight();
  const e = env();
  const req = new Request("https://relay.test/adjust", {
    method: "POST",
    headers: { authorization: `Bearer ${SECRET}` },
    body: "delta=10",
  });
  const res = await worker.fetch(req, e);
  assert.equal(res.status, 200);
  const bad = await call(e, "POST", "/adjust", { delta: "hot" });
  assert.equal(bad.status, 400);
});

test("each watch picks its own side per request; one relay serves both", async () => {
  const f = fakeEight();
  const e = env({ SIDE: "me" });
  const left = await call(e, "GET", "/status?side=left");
  const right = await call(e, "POST", "/adjust", { delta: 10, side: "right" });
  assert.equal(left.json.userId, "me123");
  assert.equal(right.json.side, "right");
  assert.ok(f.calls.some((c) => c.method === "PUT" && c.url.includes("/users/partner456/")));
  assert.equal(f.calls.filter((c) => c.url.endsWith("/tokens")).length, 2, "one login per side, then cached");
  await call(e, "GET", "/status?side=right");
  assert.equal(f.calls.filter((c) => c.url.endsWith("/tokens")).length, 2);
});

test("an unknown side is a 400", async () => {
  fakeEight();
  const r = await call(env(), "GET", "/status?side=middle");
  assert.equal(r.status, 400);
});

test("unknown route is 404, root is a health check", async () => {
  fakeEight();
  const r = await call(env(), "GET", "/nothing");
  assert.equal(r.status, 404);
  const root = await worker.fetch(new Request("https://relay.test/"), env());
  assert.equal(root.status, 200);
});
