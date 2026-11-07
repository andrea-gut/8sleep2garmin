# Bed Temp — adjust an Eight Sleep Pod from a Garmin fenix

Press **UP** on the watch to make your side of the bed warmer, **DOWN** to make it
cooler, without reaching for a phone. Built so two people can each control their
own side from their own watch through one shared relay.

Each press moves the Eight Sleep level by 10 on its -100..100 scale (roughly
2-3 °F). Quick repeated presses are combined into a single change. The watch
shows the target level, an approximate temperature, and a status line.

```
 fenix ──Bluetooth──▶ Garmin Connect app ──HTTPS──▶ relay (Cloudflare Worker) ──▶ Eight Sleep cloud ──▶ Pod
UP/DOWN               on your phone                 holds the Eight Sleep login,
                                                    picks the side per request
```

## Why a relay

Connect IQ watch apps can only reach the internet through the Garmin Connect
app on the phone, must use HTTPS, and have very little memory. Eight Sleep has
no official API; the community-documented one needs a login, a bearer token,
and a device lookup to learn which user is on which side. The relay does all of
that and gives the watch two trivial calls: `GET /status` and `POST /adjust`.

The relay runs on Cloudflare Workers' free tier, so there is no server to keep
awake at night.

## Repository layout

| Path | What |
|---|---|
| `relay/worker.js` | The relay. Plain JavaScript, no dependencies. |
| `relay/worker.test.mjs` | Unit tests against a fake Eight Sleep API (`npm test`). |
| `relay/wrangler.toml` | Worker config: default side, token-cache KV binding. |
| `relay/probe.py` | Stdlib-only Python script that checks an Eight Sleep login and prints which user id is on which side. |
| `watch/` | The Connect IQ watch app (Monkey C). |
| `watch/source/Config.mc.example` | Template for the per-build config (relay URL, secret, side, step). Copy to `Config.mc`, which is git-ignored. |
| `watch/build.sh` | One-command build: `./build.sh <device-id> <left|right|me>`. |

## Setup

### 1. Check the Eight Sleep login and find the sides

Use the email and password you sign in with in the Eight Sleep app. An invited
partner's own login works and can read and set both sides of a shared Pod.

```bash
EIGHT_EMAIL='you@example.com' EIGHT_PASSWORD='...' python3 relay/probe.py
```

It prints both sides of the Pod with their user ids and marks which one belongs
to the login. Pass `--side right` to read the other side, or
`--side right --set-level 0` to test a write.

### 2. Deploy the relay

Needs Node.js and a free Cloudflare account.

```bash
cd relay
npm install
npx wrangler login                          # opens a browser; sign in and click Allow
npx wrangler kv namespace create TOKENS     # paste the printed id into wrangler.toml
npx wrangler secret put EIGHT_EMAIL         # value: your Eight Sleep email
npx wrangler secret put EIGHT_PASSWORD      # value: your Eight Sleep password
npx wrangler secret put RELAY_SECRET        # value: output of  openssl rand -hex 24
npx wrangler deploy                         # register a workers.dev subdomain when asked
```

The KV namespace caches the Eight Sleep token (valid ~20 h) so the relay does
not log in on every press; Eight Sleep rate-limits logins. The first request to
a brand-new `workers.dev` subdomain can fail the TLS handshake for a minute or
two while the certificate is issued.

Verify:

```bash
curl -H 'Authorization: Bearer <RELAY_SECRET>' 'https://<worker>.workers.dev/status?side=left'
```

Relay endpoints (all need `Authorization: Bearer <RELAY_SECRET>`; `side` is
`left`, `right` or `me` via `?side=` or a JSON `side` field):

| Call | Effect |
|---|---|
| `GET /status` | `{side, userId, level, state}` |
| `POST /adjust {"delta": 10}` | nudges the target level, clamped to -100..100; turns the side on if it was off |
| `POST /set {"level": n}` | sets the target level |
| `POST /on`, `POST /off` | turns the side on (smart mode) or off |
| `GET /debug` | account, device, both sides' user ids and levels |

### 3. Build the watch app

Requirements: the Connect IQ SDK (`brew install --cask connectiq` plus
`brew install --cask connectiq-sdk-manager` to download device files after a
Garmin sign-in), a Java runtime (`brew install openjdk@21`), and a developer key
(`build.sh` generates one at `~/.garmin/developer_key.der` if missing).

```bash
cd watch
cp source/Config.mc.example source/Config.mc    # fill in RELAY_URL and RELAY_SECRET
./build.sh fenix847mm left                      # your watch, your side
./build.sh fenix7 right                         # partner's watch, their side
```

Output: `watch/bin/BedTemp-<device>-<side>.prg`. Device ids are the ones the
SDK Manager lists (`fenix7`, `fenix7x`, `fenix843mm`, `fenix847mm`,
`fenix8solar47mm`, …). The manifest lists most fenix models from the 5 Plus on;
add a product line if yours is missing.

Sideload: copy the `.prg` into the watch's `GARMIN/APPS` folder over USB and
unplug. fenix 7 and 8 use MTP, so on a Mac you need a helper such as
[OpenMTP](https://openmtp.ganeshrvel.com); fenix 5/6 mount as a drive.

Prefer VS Code? Install Garmin's **Monkey C** extension, open `watch/`, and use
**Monkey C: Build for Device**.

## Nightly use

- Open the app before sleep and leave it running. It is a full app, not a
  widget, so it stays in the foreground all night. BACK must be pressed twice
  within two seconds to exit, so a sleepy mis-press doesn't close it. Assign a
  hotkey (Settings → System → Hot Keys) so it's one long press to open.
- Phone on the nightstand with Bluetooth on and Garmin Connect running. On
  iPhone the Connect app must stay open in the background (don't swipe it
  away); on Android it doesn't matter.
- Turn the backlight down for the night so a press doesn't light the room.
- A manual change behaves like changing the temperature in the Eight Sleep app:
  Autopilot keeps running and may move the level at its next schedule step.

Status line meanings: `Ready` all good · `Side is off` the next press turns it
on · `No phone` the watch can't see the phone · `Timeout` the phone or Garmin
Connect didn't answer · `Bad secret` `Config.mc` doesn't match the relay ·
`Bad response` the relay URL is wrong or the relay returned an error ·
`Rate limited` Eight Sleep is throttling logins (check the KV binding).

## Things learned the hard way

- **Button handling on fenix.** With a `BehaviorDelegate`, UP and DOWN arrive
  as `onPreviousPage` / `onNextPage` *before* `onKey`, and returning `true`
  from a behavior method suppresses `onKey` entirely. Handle the buttons in the
  behavior methods.
- **Homebrew's Connect IQ simulator** errors with "can't open file
  /Applications/version.txt" because the cask moves the app out of the SDK
  folder. Fix: `ln -s "<sdk>/bin/version.txt" /Applications/version.txt`.
- **The simulator ignores synthesized clicks**; press the on-screen buttons
  with a real mouse when testing.
- **Device files aren't in the SDK download**; the SDK Manager fetches them
  after a Garmin sign-in.

## Caveats

- Eight Sleep publishes no developer API. These endpoints are the ones the
  mobile app uses, as documented by the
  [Home Assistant integration](https://github.com/lukas-clarke/eight_sleep)
  and the [eightctl CLI](https://github.com/steipete/eightctl), and may change
  without notice. If `/status` starts failing, check those projects.
- Your Eight Sleep password is stored only as a Cloudflare secret. Never put
  it in `wrangler.toml`, `Config.mc`, or this repo.
- Running a Connect IQ app all night costs a few percent of battery on a fenix.

## Testing

```bash
cd relay && npm test          # 11 tests against a fake Eight Sleep API
cd relay && npx wrangler dev  # local relay, needs relay/.dev.vars (see .dev.vars.example)
```

## License

MIT, see `LICENSE`.
