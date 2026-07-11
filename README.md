# moss-live-ios

Native iOS/iPadOS app (Swift + SwiftUI) that streams live microphone audio over
**Tailscale** to a Fedora backend
(**[moss-live-fedora-backend](https://github.com/4MBs/moss-live-fedora-backend)**)
for local MOSS transcription, shows the live speaker-labeled transcript, and has
one big button: *send the last 30 seconds to Gemini and show the answer*.

**Linux-first by design**: the whole project is developed from Fedora. The Xcode
project is *generated* from [`project.yml`](project.yml) (XcodeGen); every build,
test, signing and packaging step runs on **GitHub-hosted macOS runners**. No Mac,
no local Xcode, ever.

## The development loop (from Fedora)

1. Edit Swift sources in `Sources/MossLive/` (plain text — any editor).
2. `git commit && git push`.
3. GitHub Actions builds & tests on a macOS runner
   ([ci.yml](.github/workflows/ci.yml)); lint runs on cheap ubuntu runners
   ([lint.yml](.github/workflows/lint.yml)).
4. Download the **unsigned IPA artifact** from the run
   (`gh run download -n MossLive-unsigned-ipa-<run>` or via the web UI).
5. Install it on the device with **SideStore** (see below).

`gh run watch` makes step 3–4 comfortable from a terminal.

## Installing on your device without an Apple Developer account

The CI produces an **unsigned IPA**. iOS only runs signed apps, so it must be
signed on-device with a free Apple ID — that is exactly what
[SideStore](https://sidestore.io) (or AltStore) does:

1. Set up SideStore once (needs a one-time pairing with any computer).
2. Import `MossLive-unsigned.ipa` into SideStore → *Install*.
3. **Free-Apple-ID caveats** (Apple's rules, no tool avoids them): apps expire
   after **7 days** (open SideStore to refresh), max 3 sideloaded apps, and the
   first launch needs the developer profile trusted in iOS Settings.
4. **VPN conflict**: SideStore uses a local VPN profile for installs/refreshes,
   and iOS allows one VPN at a time — if a refresh fails, toggle **Tailscale
   off**, refresh in SideStore, then turn Tailscale back on to use the app.

With a paid Apple Developer membership later, [release.yml](.github/workflows/release.yml)
produces properly signed builds and can upload to TestFlight — see
[docs/SIGNING.md](docs/SIGNING.md). Until those secrets exist, the signing jobs
skip themselves and CI states this in the run summary.

## First-run configuration

The app's Settings screen (gear icon; also opens automatically when unconfigured)
needs, from the Fedora server:

| Setting | Where to find it |
|---|---|
| Server address | `tailscale ip -4` on the server (e.g. `100.92.57.51`), or its MagicDNS name |
| Port | `8787` unless changed in the backend config |
| Auth token | `grep TOKEN ~/.config/mosslive/env` on the server |

Values are stored in UserDefaults; the token goes to the iOS Keychain.
[`Config.example.plist`](Config.example.plist) documents the same values —
never commit a real token.

Both devices must be on the same tailnet (Tailscale app installed and connected
on the iPhone/iPad).

## Stealth widget (Home Screen + Lock Screen)

The app ships a widget that answers without opening the app: tap it → the
backend answers the last 30 s → the answer text appears inside the widget.

Setup (once, after installing the app):

1. Long-press the Home Screen → **+** → search "MOSS Live" → add *AI Answer*
   (small or medium). For the Lock Screen: long-press the Lock Screen →
   Customize → add the rectangular widget.
2. Long-press the widget → **Edit Widget** → enter the server address, port
   and auth token (same values as in the app's Settings). The widget is
   configured on itself — SideStore's re-signing breaks shared app storage,
   so it cannot inherit the app's settings automatically.
3. Recording must be running in the app; the widget then works even from the
   Lock Screen while the phone stays otherwise untouched.

## Lesson summary

When you stop a recording, the app keeps the connection open for a few
seconds while the server condenses the whole lesson into a summary (overview,
key points, assignments — in the lesson's language). It appears as a
full-screen sheet with share/copy, can be reopened from the header button,
and is also saved on the server next to the transcript
(`...-summary.txt`).

## What the app does

- **Capture**: `AVAudioEngine` tap → `AVAudioConverter` → 16 kHz mono Int16.
  `.measurement` mode for minimal system processing; `UIBackgroundModes: audio`
  keeps capture alive in the background; interruptions (calls, Siri) and route
  changes (headset plug/unplug) restart the engine or surface a clear banner.
- **Encode**: Opus 20 ms frames, ~24 kbps VBR, FEC on — via libopus built from
  source through SPM (`LocalPackages/OpusShim` wraps the variadic C API for Swift).
  ≈ 11 MiB per hour of streaming; no audio is stored on the device.
- **Stream**: one WebSocket (binary = audio frames, JSON = everything else) to the
  backend; protocol mirrored from the backend's `docs/PROTOCOL.md` in
  [`Protocol.swift`](Sources/MossLive/Network/Protocol.swift). Reconnects use
  jittered exponential backoff and resume the same server session; packet
  sequence numbers keep advancing while offline so the server records the outage
  as silence and "the last 30 s" stays timestamp-true.
- **Status**: disconnected / connecting / connected / recording / reconnecting /
  error, plus live "transcribing" and RTT indicators.
- **Transcript view**: committed segments (speaker-colored) + italic partial tail.
- **Answer button**: each press gets a `request_id` with pending → waiting →
  success/failure states; a late answer can never overwrite a newer press
  (`AnswerTracker`, unit-tested).

## Development commands

```bash
# on Fedora: nothing to install — edit, commit, push. Lint locally if you like:
docker run --rm -v "$PWD:/repo" -w /repo ghcr.io/realm/swiftlint:0.57.1 swiftlint

# on any Mac (optional, not required):
brew install xcodegen && xcodegen generate && open MossLive.xcodeproj

# tests run on CI; trigger manually:
gh workflow run ci.yml && gh run watch
```

## Repository layout

```
project.yml                    XcodeGen project definition (the "real" project file)
Sources/MossLive/              app source (SwiftUI, actors)
  Audio/                       AVAudioEngine capture + Opus streaming encoder
  Network/                     protocol, WebSocket client, backoff policy
  Model/                       app state machine, settings, answer tracking
  Views/                       SwiftUI views
LocalPackages/OpusShim/        C shim over libopus (SPM, depends on alta/swift-opus)
Tests/MossLiveTests/           unit tests (protocol, answer tracker, backoff)
scripts/ci/                    unsigned-IPA packaging, keychain import/cleanup
.github/workflows/             lint (ubuntu) · ci (macOS) · release (signing/TestFlight)
docs/SIGNING.md                every GitHub Secret, step by step
```

## CI cost notes (private repo)

macOS runners bill at **10×** the linux rate against the free 2 000 min/month.
Therefore: lint/format run on ubuntu only; the macOS job is path-filtered (docs
changes never build), superseded runs are cancelled, SPM checkouts are cached,
and release/TestFlight jobs run only on tags or manual dispatch. A typical CI
run is ~8–10 macOS minutes ≈ 80–100 billed minutes — budget accordingly.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Set the server address and token" | Fill in Settings (gear icon) |
| Stuck at *Connecting…* | Tailscale connected on the phone? Server running? Try `http://<ip>:8787/healthz` in Safari |
| Error: server rejected auth token | Token in Settings ≠ `MOSSLIVE_AUTH_TOKEN` on the server |
| *Reconnecting…* loops | Backend down or unreachable — `systemctl --user status mosslive` on the server |
| No transcript while connected | Check server logs; is the model loaded? (`journalctl --user -u mosslive -f`) |
| Answer button fails instantly | Not connected, or two presses within 1 s (server rate limit) |
| Answer error mentions login/quota | Gemini CLI on the *server* needs `gemini` login / quota reset |
| Mic stops after a call | iOS ended the session — banner appears; tap record again |
| App won't install via SideStore | Refresh SideStore first; toggle Tailscale off during install (VPN conflict); free Apple ID allows max 3 apps |
| App expired after 7 days | Free-signing limit — open SideStore and refresh |
| CI: "pinned Xcode missing" warning | GitHub updated the runner image — update `XCODE_PATH` in the workflows |
| CI: simulator `iPhone 16` not found | Runner image changed its simulators — pick one from the run log's device list |

## License

Placeholder — see [LICENSE](LICENSE). Dependencies: swift-opus & libopus (BSD-3-Clause).
