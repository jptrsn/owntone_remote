---
name: 010-artwork-204-filter
status: pending
intent: remote-app
supervised_steps: []
---

# Unit 010 — artwork 204 → no-image (log-noise follow-up)

R-IDs: R-03 (Now playing display — "Artwork (with fallback)"); closes the
follow-up open since remote-app unit 005a (SESSION-LOG 2026-10-26, item
4): `GET /artwork/item/<id>` → **204** (server has no artwork) makes
`flutter_cache_manager` throw `Invalid statusCode: 204` — caught and
benign today, but it is log noise and an exception on the happy path.
A 204 is *not* an error; it is the server saying "this item has no
artwork" and it must be treated as the normal no-image case.

## Goal

1. **Treat HTTP 204 from an artwork URL as 'no image'.** Wherever the
   app fetches server artwork (`lib/src/ui/now_playing_screen.dart:583`
   `ArtworkBox` `Image.network`, and the audio_service notification art
   path via `lib/src/audio/mirror_handler.dart:26` `artUri`), a 204
   response must resolve to the placeholder (`music_note` icon) through
   the normal no-image branch — **without throwing/logging an
   exception**. `Image.network` treats 204 as a decode failure
   (`errorBuilder` shows the placeholder but the underlying
   `flutter_cache_manager`/`Image` layer logs `Invalid statusCode:
   204`); the fix is to short-circuit the 204 before it becomes an
   exception (a custom `HttpClient`/header probe that maps 204 → "no
   image", or a loading/`frameBuilder`/`errorBuilder` path that
   distinguishes 204 from a real failure). Do **not** add a package
   dependency to do it if a small local `HttpClient` HEAD/GET probe
   suffices (open-source + minimal-deps posture, unit 008 precedent).
2. **No new audible/network-heavy behaviour.** Artwork fetches stay
   `?maxwidth=600` (`ArtworkBox.withMaxWidth`, unit 005a contract);
   this unit only changes how a 204 is handled.

## Steps / notes

- Reproduce first: an item with **no** server artwork
  (`artwork_url` null, or `/artwork/...` → 204) currently logs
  `Invalid statusCode: 204` on the console/logcat. The unit is not done
  until that line is gone for the 204 case **and** a genuine image error
  (404/500/garbage bytes) still shows the placeholder.
- The placeholder is unchanged: `music_note`, size 96, grey
  (`now_playing_screen.dart:586-592`) — this unit must not restyle it.
- 404 and other non-204 failures keep today's behaviour (placeholder via
  `errorBuilder`); the change is *specifically* about demoting 204 from
  error to expected.
- Shared server (192.168.1.13): artwork GETs are read-only and safe;
  snapshot/restore is not required (no mutation), but never start
  playback to view art — use the currently-stopped/paused item or a
  library item opened without playback.

## Completion criteria

1. **Unit/widget tests** (test-author authored, `test/fakes/`, no
   network):
   a. `ArtworkBox` given a URL that returns **204** renders the
      `music_note` placeholder and produces **no exception / no
      `Invalid statusCode` log line**;
   b. a **200** with valid bytes renders the image;
   c. a **404**/500 still renders the placeholder (regression —
      non-204 errors unchanged);
   d. a null URL renders the placeholder (regression);
   e. `withMaxWidth` still appends `maxwidth=600` (regression — unit
      005a contract, `test/artwork_url_test.dart`).
2. **The 204 line is gone on-device:** load a no-artwork item on the
   **own disposable AVD** (per-unit create+delete); `logcat` for the
   artwork request shows **no** `Invalid statusCode: 204` / artwork
   exception during render. A real-artwork item still renders its image.
3. **No new dependency** unless justified in `## Result` with why a
   local `HttpClient` probe couldn't work (default: none added —
   `pubspec.yaml` diff empty or dev-dep only).
4. **Gates green + debug APK** (AGENTS.md quality gates verbatim).
5. **AVD deleted**; server left unmutated (GETs only — `GET /api/player`
   start == end, no play/transport actions).
6. **SESSION-LOG entry + commit** `remote-app/010: …`.

## Result

(pending)
