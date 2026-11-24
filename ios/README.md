# APEX native iOS apps (Swift)

Two real Swift apps, no web views:

| App | Target | Device | What it is |
|---|---|---|---|
| **APEX 9R** | `APEXViewer` | iPad (also iPhone), landscape | SceneKit showroom: the cars from `cars/cars.json`, scissor doors, lights, flames, AVAudioEngine engine sound, launch control |
| **APEX Key** | `APEXKey` | iPhone, portrait | SwiftUI key: Taptic haptics, hold-to-start, gas-pedal throttle, shift lights, QR pairing, car picker |

Both talk to the relay on your server (`wss://<server>/relay`) with the same protocol as the web pages, so any
mix works: iPad app + web key, laptop browser + iPhone app, etc. The default server is set in
`Shared/Relay.swift` (`Server.defaultHost`) and can be changed inside both apps.

## Download

Every push that touches `ios/` builds both apps on GitHub Actions and publishes them here:

- iPad: https://github.com/smallkhk/Porsh/releases/download/ios-latest/APEXViewer-unsigned.ipa
- iPhone: https://github.com/smallkhk/Porsh/releases/download/ios-latest/APEXKey-unsigned.ipa

## Install (free Apple ID)

1. On a Mac or Windows PC, install [Sideloadly](https://sideloadly.io).
2. Plug in the device, drag the `.ipa` in, sign in with your Apple ID, press Start.
3. On the device: Settings → General → VPN & Device Management → trust your Apple ID.

Free Apple IDs re-sign every 7 days. An Apple Developer account removes that (TestFlight).

## Pairing

Open **APEX 9R** on the iPad, tap **Key** to see the QR code, then in **APEX Key** tap **Scan QR code**.
The key remembers the car; **Forget car** (top right) pairs a different one.

## Sound

The engine is synthesized live (`Viewer/EngineSynth.swift`). It uses the `.playback` audio session, so it
plays with the silent switch on. If iOS refuses to start audio, the app retries automatically and the
top-right button shows **Sound ⚠︎ tap** with the reason.

CI runs an offline self-test (`-audioTest` launch argument) on the iPad simulator that renders every car's
engine and prints its loudness per rpm, e.g.
`[apex9r] 1000rpm load0 -28.0 dB | 3000rpm load1 -13.7 dB | 6000rpm load1 -10.2 dB | 9000rpm load1 -7.6 dB`.

## Build locally (Mac)

```bash
brew install xcodegen
cd ios && xcodegen && open APEX.xcodeproj
```
