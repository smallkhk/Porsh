# APEX 9R — a supercar you start with your phone

A 3D showroom for an original concept car, designed entirely in code. Open the
showroom on a laptop, scan the QR code with your phone, and the phone becomes
the key: unlock it, open the scissor doors, switch the lights on, hold to start
the engine, rev it, and do a full launch run.

No 3D model files, no audio samples, no backend, no API keys.

## What's in it

**Desktop showroom (`index.html`)**
- A procedural supercar built with Three.js. The body is a loft of about 300
  cross-sections generated from profile curves. The doors and glass come out
  of the same vertex grid, so the panels line up and the doors hinge open
  (scissor style) to show the cabin.
- Studio lighting with a custom softbox environment, a clearcoat paint
  material, bloom, and headlights that light the floor with visible beams.
- A full-width LED light bar with welcome and goodbye sweep animations,
  hazard flashes, and brake lights.
- Exhaust flames with pops and crackles when you lift off the throttle and
  when it changes gear.
- Launch control with a 3-2-1 countdown, six gears, a 0–100 km/h timer, and
  a moving floor with speed streaks so the car looks like it's driving.
- A live tachometer, Film mode (letterbox with an auto-orbiting camera),
  paint, wheel colour, wing and stripe options.
- Keyboard controls: `U` unlock/lock, `D` doors, `L` lights, `E` engine,
  `Space`/`W` throttle, `X` launch, `H` horn, `F` film mode.

**Engine sound (`js/engine-audio.js`)**
- A flat-six sound generated live with Web Audio: a custom harmonic waveform
  at the engine's firing frequency, distortion, an rpm-dependent filter,
  intake noise and a high-rpm scream layer.
- Starter motor crank, rev limiter bounce, backfire pops, key-fob chirps,
  door thuds and a horn.

**Phone key (`remote.html`)**
- Unlock, Lock, Doors and Lights buttons.
- An engine START STOP button you hold down to start or stop.
- A throttle pad: hold it to rev, slide your finger up for more.
- Race-style shift lights, a live rpm/speed/gear readout, and a Launch
  button.
- A Garage section: change the paint, toggle the wing or stripe, sound the
  horn.
- Haptic feedback (on Android) on the limiter, gear shifts and refused
  actions. It also keeps the screen awake.

## How the phone connects

`js/link.js` uses WebRTC through [PeerJS](https://peerjs.com) and its free
public signalling server, so there's no server of your own to run. The
showroom makes a 5-letter room code and shows it as a QR code. The phone
connects peer-to-peer.

It also uses a `BroadcastChannel` fallback, so two tabs in the same browser
work even offline. That's handy for testing.

> If the phone can't connect on mobile data, put both devices on the same
> Wi-Fi. Some carrier networks block direct peer-to-peer connections.

## Run it locally

It's a static site, so there's nothing to build:

```bash
npx serve .            # or: python3 -m http.server
```

Open `http://localhost:3000` on the computer. To test without a phone, open
`/remote.html#CODE` in a second tab.

## Deploy (Vercel, Netlify, GitHub Pages…)

1. Import this repo into Vercel.
2. Set **Framework preset** to *Other*. Leave the build command empty and
   the output directory as `.`.
3. Deploy, open the URL on your laptop, and scan the QR code with your phone.

Phones need HTTPS for haptics and wake lock. Every host above gives you HTTPS
automatically.

---

APEX 9R is an original design. It is not affiliated with or endorsed by any
car manufacturer.
