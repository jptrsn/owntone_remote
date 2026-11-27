# OwnTone Remote

A Flutter + Android remote control for a self-hosted
[OwnTone](https://owntone.github.io/owntone-server/) music server.

It is a clean-room re-implementation of the **UX** of
[ReTune](https://github.com/izzysoft/retune) (the legacy Android remote for
iTunes, 2014 era) in modern **Material 3**, speaking **exclusively** to
OwnTone's JSON API and websocket notifications. No DACP/DAAP, no
iTunes-specific features (radio, movies/TV, podcasts, Genius, …) — OwnTone's
feature set is the only relevant feature set.

**Current release: [v0.3.0](https://github.com/jptrsn/owntone_remote/releases/latest)**
· License: [GPL-3.0-only](LICENSE) · Requires Android 8.0+ (API 26) ·
Verified against OwnTone 29.3.

## Install

You need an OwnTone server reachable from your phone's network.

### Obtainium (recommended)

Add this repository as an app in
[Obtainium](https://github.com/ImranR98/Obtainium)
(`https://github.com/jptrsn/owntone_remote`) and enable
**“Attempt to filter APKs by CPU architecture if possible”** in the app's
settings — releases ship one APK per ABI, and without the filter you get a
manual pick prompt on every update.

### Manual

Download the APK for your device from the
[latest release](https://github.com/jptrsn/owntone_remote/releases/latest):

| ABI | Devices |
|---|---|
| `arm64-v8a` | virtually all modern phones |
| `armeabi-v7a` | older 32-bit ARM devices |
| `x86_64` | emulators |

Releases from **v0.1.1** onward are signed with the project's dedicated
release key — `release.sh` refuses to publish APKs not carrying that
certificate, and the key is anchored by its public checksum in
[`tools/keystore/checksum.sha256`](tools/keystore/checksum.sha256); every
release also ships a `SHA256SUMS.txt` so you can verify the bits yourself.
Installs from 0.1.1+ update in place; a device still on the debug-signed
v0.1.0 needs a one-time uninstall + reinstall (flagged in the release
notes). No store distribution — this GitHub-release/Obtainium channel is
the channel.

## What it does

- Now playing, play/pause/next/previous, seek; queue management with
  drag-reorder, per-row Remove / Play Next
- Library browse (playlists / artists / albums / songs / genres, with
  alphabetical section headers), search, and Play All / Shuffle /
  Play Next / Add to Up Next on detail screens
- Server volume slider + physical volume-key routing (configurable step,
  foreground-only by design) with a transient volume toaster; output
  selection (server-listed outputs; AirPlay + ALSA verified, Chromecast
  depends on server-side support — see Known limitations in the release
  notes)
- Track ratings, shuffle/repeat/consume modes, theme choice
- Navigation drawer + persistent mini transport bar on every screen
- Server auto-discovery over mDNS (manual host/port always available)
- Live updates over the OwnTone websocket with resilient reconnect —
  offline banner in ~1.4 s, backoff to a 30 s cap, silent-drop detection
- Media notification / lock-screen controls (Android media session that
  stays present while paused, so Bluetooth head-unit transport keys
  reach the server)

## Privacy

The app talks **only to your own OwnTone server** on your LAN: HTTP to
`http://<host>:3689` plus a websocket on the port reported by
`/api/config` (`3688` usually). Cleartext is deliberate — OwnTone has no
built-in TLS and the trust boundary is your network. No analytics, no
accounts, no third-party servers, no ad SDKs. Nothing leaves your LAN
except the update check your app store (Obtainium) performs.

## Build from source

Flutter **3.47.9** (the CI pin, `.github/workflows/gates.yml`) on any host
with the Android SDK:

```sh
flutter pub get
flutter analyze                                 # must report 0 issues
dart format --output=none --set-exit-if-changed .
flutter test --exclude-tags live                # network-free test suite
flutter build apk --release --split-per-abi
```

APKs land in `build/app/outputs/flutter-apk/`. Maintainers cut releases
from `main` with `./release.sh` (it re-runs the gates, builds, tags, and
publishes; see its header for the full contract).

## Documentation

- [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) — features and acceptance
  criteria (R-IDs)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — layers and state flow
- [`docs/API.md`](docs/API.md) — the OwnTone endpoints this app uses
- [`docs/RELEASE-NOTES.md`](docs/RELEASE-NOTES.md) — what each release
  covers, including the documented-untested list
- [`docs/SESSION-LOG.md`](docs/SESSION-LOG.md) — append-only development
  log; every change carries a rationale entry
- [`.ai-dlc/`](.ai-dlc/) — unit specs with completion criteria
- [`AGENTS.md`](AGENTS.md) — contribution rules for AI-assisted
  development sessions (this project is developed agent-first; the file
  doubles as the contributor contract for automation)

## License

Copyright (C) 2026 the OwnTone Remote authors.

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, version 3 of the License
([GPL-3.0-only](LICENSE)). It is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the LICENSE file
for details.

The in-app **About → Open-source licenses** screen lists the third-party
dependencies and their licenses.
