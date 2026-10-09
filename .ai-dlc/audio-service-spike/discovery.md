# Discovery — audio-service-spike (2026-10-08, planning session)

## Environment

- Flutter 3.41.7 stable / Dart 3.11.5 (`/opt/homebrew/bin/{flutter,dart}`).
- Android SDK `~/Library/Android/sdk`; `ANDROID_HOME` not set in shells —
  use absolute paths (emulator, cmdline-tools/latest/bin/{sdkmanager,
  avdmanager}).
- System images present: android-35 (google_apis_playstore), android-36
  (google_apis, google_apis_playstore). **android-33 must be downloaded**
  (capture AVD, separate intent).
- AVDs present: `Pixel_9_Pro_API_36` (other session's — hands off),
  `Pixel_9_API_35`, `Pixel_9_Pro_XL_API_35`, `Medium_Tablet_API_35`,
  `Small_Tablet_API_36`.
- `flutter_agent_lens` MCP deployed + verified (UI debug loop, AGENTS.md).

## Server (verified live 2026-10-08)

- OwnTone 29.3 at 192.168.1.13:3689, WS :3688. No auth. 10 outputs.
  `allow_modifying_stored_playlists: false`. Live responses: docs/API.md
  § "Verified live".

## Prior art in this stack

- `~/Documents/owntone_sync` (same user, same host): Flutter, dio,
  provider, `just_audio` + `audio_service` 0.18.13, clean
  data/domain/presentation. Its `audio_service` usage = local playback
  pattern (not remote-mirror). Conventions to copy: package layout,
  dependency choices, AGENTS.md style.
- `audio_service` remote-volume API (from docs-mcp, planning): publish
  `RemoteAndroidPlaybackInfo(max, current)` + implement
  `androidSetRemoteVolume`/`androidAdjustRemoteVolume` — this is the
  volume-rocker hook.
- Call state: no first-party Flutter API → small Kotlin
  `TelephonyCallback` channel (~30 lines).

## Known risks entering the spike

1. FGS survival while paused / no local audio (the central question).
2. FGS type choice: `mediaPlayback` (media session exists) vs
   `dataSync` (6 h limit on 14+ — non-starter for an all-day remote).
3. Remote volume events with screen off + app backgrounded.
4. Notification churn on WS reconnect (duplicate notifications).
5. `next`/`previous` semantics while paused (stays paused? verify).
