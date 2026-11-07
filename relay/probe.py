#!/usr/bin/env python3
"""Check your Eight Sleep login and see which user id is on which side of the bed.

Run before deploying anything:

    EIGHT_EMAIL=you@example.com EIGHT_PASSWORD='...' python3 relay/probe.py

Add --set-level N --side left|right|me to actually nudge a side (test the write path).
Uses only the Python standard library.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

AUTH_URL = "https://auth-api.8slp.net/v1/tokens"
CLIENT_API = "https://client-api.8slp.net/v1"
APP_API = "https://app-api.8slp.net/v1"
CLIENT_ID = "0894c7f33bb94800a03f1f4df13a4f38"
CLIENT_SECRET = "f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76"


def call(method, url, token=None, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("content-type", "application/json")
    req.add_header("accept", "application/json")
    req.add_header("user-agent", "okhttp/4.9.3")
    if token:
        req.add_header("authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            text = r.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        sys.exit(f"{method} {url} -> HTTP {e.code}: {detail}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set-level", type=int, help="write this target level (-100..100)")
    ap.add_argument("--side", default="me", choices=["me", "left", "right"])
    args = ap.parse_args()

    email, password = os.environ.get("EIGHT_EMAIL"), os.environ.get("EIGHT_PASSWORD")
    if not email or not password:
        sys.exit("set EIGHT_EMAIL and EIGHT_PASSWORD in the environment")

    auth = call("POST", AUTH_URL, data={
        "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET,
        "grant_type": "password", "username": email, "password": password,
    })
    token, my_id = auth["access_token"], auth["userId"]
    print(f"login OK  userId={my_id}  token expires in {auth.get('expires_in')}s")

    me = call("GET", f"{CLIENT_API}/users/me", token)["user"]
    dev = me.get("currentDevice") or {}
    print(f"account: {me.get('firstName')}  currentDevice={dev}")
    if not dev.get("id"):
        sys.exit("no current device on this account")

    flt = ("leftUserId,rightUserId,leftTargetHeatingLevel,rightTargetHeatingLevel,"
           "leftHeatingLevel,rightHeatingLevel,leftNowHeating,rightNowHeating")
    d = call("GET", f"{CLIENT_API}/devices/{dev['id']}?filter={flt}", token)["result"]
    print("\nPod sides:")
    for side in ("left", "right"):
        uid = d.get(f"{side}UserId")
        tag = "  <-- the login you used" if uid == my_id else ""
        print(f"  {side:5}: userId={uid}  target={d.get(side + 'TargetHeatingLevel')}"
              f"  current={d.get(side + 'HeatingLevel')}  heating={d.get(side + 'NowHeating')}{tag}")

    target = {"me": my_id, "left": d.get("leftUserId"), "right": d.get("rightUserId")}[args.side]
    if not target:
        sys.exit(f"no user on side {args.side}")
    t = call("GET", f"{APP_API}/users/{target}/temperature", token)
    print(f"\n{args.side} side temperature endpoint: level={t.get('currentLevel')} "
          f"state={(t.get('currentState') or {}).get('type')}")

    if args.set_level is not None:
        lvl = max(-100, min(100, args.set_level))
        if (t.get("currentState") or {}).get("type") != "smart":
            call("PUT", f"{APP_API}/users/{target}/temperature", token,
                 {"currentState": {"type": "smart"}})
        call("PUT", f"{APP_API}/users/{target}/temperature", token, {"currentLevel": lvl})
        print(f"set {args.side} side target level to {lvl}")


if __name__ == "__main__":
    main()
