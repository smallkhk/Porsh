# APEX 9R — a supercar you start with your phone

A 3D showroom for an original concept car, designed entirely in code. Show it
on an iPad or laptop and use your iPhone as the key: unlock it, open the
scissor doors, switch the lights on, hold to start the engine, rev it, and do
a full launch run.

There are three ways to run it:

| | What | Needs |
|---|---|---|
| **Your VPS** (recommended) | Your own domain, your own realtime relay | Any Linux VPS + a domain |
| **iOS apps** | "APEX 9R" viewer for iPad + "APEX Key" for iPhone | GitHub Actions (built for you) |
| Static host | Vercel / Netlify / GitHub Pages | Nothing, but uses a public pairing service |

---

## 1. Run it on your VPS

The VPS runs `server/server.js`. It serves the site and also relays messages
between the iPad and the iPhone over a WebSocket. That's more reliable than
peer-to-peer: it works on mobile data and through strict networks, with no
third-party service involved.

**Step 1 — DNS.** Create an `A` record for your domain (e.g.
`apex.example.com`) pointing to your VPS's IP address.

**Step 2 — Start it.** Docker gives you HTTPS automatically through Caddy:

```bash
git clone <this repo> apex9r && cd apex9r
DOMAIN=apex.example.com docker compose up -d --build
```

Then open `https://apex.example.com`.

To update later: `git pull && DOMAIN=apex.example.com docker compose up -d --build`.

**Without Docker** (Node 20+ behind your existing nginx):

```bash
npm ci --omit=dev
PORT=8080 node server/server.js          # or: deploy/apex9r.service for systemd
```

Then use `deploy/nginx.conf` for the proxy (it includes the WebSocket upgrade)
and `certbot --nginx` for HTTPS.

**Small VPS is fine.** The server only serves files and forwards tiny
messages; the 3D rendering happens on the iPad. 512 MB RAM is plenty.

**Endpoints:** `/` showroom · `/remote.html` key · `/relay` WebSocket · `/healthz`.

## 2. Native iOS apps (built by GitHub Actions)

`.github/workflows/ios.yml` builds two apps with
[Capacitor](https://capacitorjs.com):

- **APEX 9R** (viewer): landscape, full screen, for the iPad.
- **APEX Key** (controller): portrait, for the iPhone. It has real Taptic
  Engine haptics, an in-app QR scanner, and remembers your car.

**To build them:**

1. In GitHub, go to **Settings → Secrets and variables → Actions →
   Variables** and add `APEX_DOMAIN` = `apex.example.com`. The apps connect
   to your VPS's relay, so deploy the VPS first.
2. Go to **Actions → iOS apps → Run workflow**. Pushing a `v*` tag also
   triggers it.
3. Download `APEX-viewer-ipa` and `APEX-key-ipa` from the run's
   **Artifacts**.

**To install them:**
- **Free:** the `.ipa` files are unsigned. Install them with
  [Sideloadly](https://sideloadly.io) or AltStore using your normal Apple ID.
  With a free Apple ID, the apps must be re-signed every 7 days.
- **Paid:** with an Apple Developer account ($99/yr), they can go to
  TestFlight instead and last 90 days per build. The workflow will need your
  signing certificate added as secrets for that.

**No-install alternative:** open your domain in Safari on each device and tap
**Share → Add to Home Screen**. Both pages are set up as full-screen web apps
with their own icons.

Note: macOS GitHub runners use more of your Actions minutes than Linux ones
(10× on private repos), so the workflow only runs when you start it.

## Pairing

1. Open the showroom on the iPad. The **Key** panel shows a QR code and a
   5-letter code.
2. On the iPhone, scan the QR code (with the camera or inside APEX Key), or
   type the code.
3. That's it. Both sides remember the pairing, so next time the key
   reconnects by itself. Use **New code** in the showroom to revoke old keys.

## Features

**The car**
- A procedural loft body: about 300 cross-sections built from profile curves.
  The doors and glass come from the same vertex grid, so the panels line up.
- Scissor doors that open to show the cabin, with courtesy lighting: an
  interior glow and APEX logo puddle lamps on the floor.
- Headlights with DRLs and low and high beams that light up the floor.
- A full-width LED light bar with welcome and goodbye sweeps, hazard
  flashes, and brake lights.
- Exhaust flames with pops and crackles when you lift off and when it changes
  gear. Paint, wheel colour, wing and stripe options.

**The sound**
The flat-six sound is generated live with Web Audio, not recorded, so it
responds instantly and never loops:
- Pitch follows rpm exactly.
- Loudness rises about 20 dB from idle to redline, plus about 10 dB more
  under throttle.
- Also: starter crank, rev-limiter bounce, backfire pops, a high-rpm scream
  layer, key-fob chirps, door thuds and a horn.
- On iPhone and iPad it plays even when the silent switch is on.

**Driving**
Launch control with a countdown, six gears and a 0–100 km/h timer (about
3.0 s). The floor moves underneath so it looks like the car is driving.
There's a live tachometer, race shift lights on the phone, and Film mode for
recording.

**Desktop keys:** `U` unlock/lock · `D` doors · `L` lights · `E` engine ·
`Space` throttle · `X` launch · `H` horn · `F` film mode.

## Local development

```bash
npm install
npm start               # http://localhost:8080 (site + relay)
```

To test without a phone, open `/remote.html#CODE` in a second tab.

## Project layout

```
index.html, remote.html     showroom + key pages
js/car.js                   the procedural car
js/engine-audio.js          engine synthesizer
js/showroom.js, js/remote.js
js/link.js                  relay → PeerJS → BroadcastChannel transports
server/server.js            static files + WebSocket relay
scripts/                    iOS app bundling + Xcode project patching
deploy/                     Caddy, nginx, systemd
```

---

APEX 9R is an original design. It is not affiliated with or endorsed by any
car manufacturer.
