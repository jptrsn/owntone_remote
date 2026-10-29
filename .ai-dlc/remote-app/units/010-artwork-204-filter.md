---
name: 010-artwork-204-filter
status: done
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

**DONE 2026-10-28** (opencode, unattended overnight build session). c1a
RED→GREEN; all pre-green guards held; 204 demoted at both fetch sites;
zero new packages.

### What was built (commits `620bb69` + docs/refine)

1. **`lib/src/core/artwork_probe.dart` — `ArtworkProbe.isNoArtwork(Uri)`.**
   A shared, lazily-created `dart:io` `HttpClient` issues ONE GET per URL
   for the process lifetime (concurrent callers share the cached Future —
   no retry storm; error/timeout entries are evicted so the next screen
   entry re-checks, probed verdicts stick — server artwork is static per
   library entry). Only a **probed 204** answers `true`; every other
   outcome — 200, 404, 500, probe failure, 3 s timeout — answers `false`
   so today's `errorBuilder` stays the decider for genuine failures. GET
   (not HEAD): the endpoint's HEAD behaviour is unverified and the
   executable contract's dart:io fake speaks GET. Body drained so the
   keep-alive socket survives for the image fetch that follows a `false`.
2. **`ArtworkBox` → StatefulWidget.** `initState`/`didUpdateWidget` (URL
   change) probe `withMaxWidth(url)`; `true` unmounts the Image entirely —
   the placeholder renders from the same `else` no-image branch as a null
   URL (the c1a branch-identity oracle). During the probe's unknown window
   the box renders exactly as before the unit (Image mounted) — tried
   deferring the mount until the probe says serve, and **reverted**: the
   frozen `now_playing_screen_test` 404 test's fixed pump budget can't
   afford the extra frame (test is immutable; the unknown-window Image GET
   is silent — NetworkImageLoadException consumed by errorBuilder, verified
   logcat-clean on-device). `withMaxWidth` untouched (c1e green).
3. **`mirror_handler.dart` artUri gate.** `_sync()` awaits
   `isNoArtwork(item.artworkUrl)` and publishes with
   `mediaItemFor(hideArtwork: true)` → `artUri: null` on a probed 204, so
   audio_service's flutter_cache_manager never fetches a 204 (the device
   log line's adjudicated source). `mediaItemFor` gained the optional
   `hideArtwork` param (default `false` — its pure-function tests
   unchanged); stale-publish guard `_sameNowPlaying` across the await
   (every `_nowPlaying` replacement is followed by notify→_sync, so
   skipping never drops metadata). Timeout/failure → keep artUri (today's
   behaviour on a flaky endpoint).

### Criterion 1 — tests (test-author contract, never edited)

`git diff 67d45eb..HEAD -- test/` **empty** (verified, 0 lines).
Baseline before implementation: `400 +1` — the one failure was exactly
c1a. After: **`401 All tests passed`** — c1a (204 → placeholder via the
no-Image branch, `find.byType(Image)` findsNothing, quiet) GREEN;
c1b (200+bytes → RawImage), c1c (404/500 → placeholder via errorBuilder,
garbage-200 → placeholder), c1d (null URL → placeholder, no fetch),
c1e (fetch carries `maxwidth=600`) all held — including
`test/artwork_url_test.dart` (unit-005a contract).

### Criterion 2 — on-device (disposable `OwnToneNight_010_API_36`)

Created by this unit (android-36 google_apis arm64, pixel_6,
`disk.dataPartition.size=8192M` replacing the single partition line —
dv-002 gotcha), booted headless, serial `emulator-5554` **verified via
`getprop ro.boot.qemu.avd_name`** before every device phase, `svc power
stayon true`. **Deleted at the end**; `adb devices` afterwards: empty
(none of ours). Screenshots/dumps/scratch under `.night/night-010/`
(gitignored).

**Constraint (documented deviation, not a shortcut):** the shared
server's now-playing item belongs to the other active session. It was
`pause / item 197444 / track 2660 / ./artwork/item/2660 → 200` for the
whole window and provably immovable without a forbidden transport action:
(i) `?id=now_playing` is **item-id anchored** (probed: inserting a 204
track at the current position did not change it; the added item was
deleted and the queue re-verified field-identical), (ii)
`PUT /api/queue/items/{id}?artwork_url=…` is ignored — the server
regenerates artwork_url from the track (probed; title edit persisted
then restored). No natural 204-now-playing window occurred (GET-only
poller, `poll.log`: current item never changed). The 204 rows therefore
ran on a loopback mock OwnTone (`adb reverse` → host `127.0.0.1:3689/
3688`) serving the **real saved snapshots** (config/player/outputs) and
the **real queue item** `197928` verbatim, with **every /artwork request
proxied byte-for-byte to the real 192.168.1.13** — the 204/200 statuses
and bytes are OwnTone's own answers; both app fetch sites run
unmodified. Zero audio risk (the app's transport pointed at the mock).

| Row | Evidence |
|---|---|
| Harness sees the line (BEFORE fix, pid 5265) | logcat `-v epoch`: `1793244632.426 I flutter : Error loading artUri: HttpException: Invalid statusCode: 204, uri = http://127.0.0.1:3689/artwork/item/3130` + `#0 WebHelper._manageResponse (package:flutter_cache_manager/src/web/web_helper.dart:137:7)` — and cache_manager's **retry storm**: same line at `652.025`, `673.036`, `704.077` (~20 s cadence) |
| BEFORE: both fetch sites fire (mock access log) | `1793244632.256 GET /artwork/item/3130?maxwidth=600 -> 204` (Image.network, carries maxwidth) + `1793244632.351 GET /artwork/item/3130 -> 204` (flutter_cache_manager artUri) + refetches 651.951/672.962/704.003 |
| BEFORE: 204 placeholder renders | `b08_before_204_placeholder.png` — artwork region 386 distinct colours / stdev ≈22 (grey music_note; vs 217 000+ for a real image); dump `b08_before_204.xml`: `She Loves Control`, `sync: live` |
| BEFORE: real-server 200 renders (control) | `b01_real200.png` — `Invincible`, artwork region 217 256 distinct colours / stdev ≈100 (album photo); dump `b01_real200.xml` `sync: live`, `Queue · 1514`, `Playing via: Volumio Kitchen` |
| AFTER: 204 line gone (pid 6698) | clean window **1793245557 → 1793245633 (76 s** — spans the old 20/40/60 s retry points): `logcat -d -v epoch` grep `Invalid statusCode|Error loading artUri|WebHelper|flutter_cache_manager|NetworkImageLoadException` → **no hits** (grep exit 1) |
| AFTER: fetch profile (mock access log) | launch = exactly 3 artwork GETs: `5560.421 ?maxwidth=600` (ArtworkBox probe), `5560.629 ?maxwidth=600` (unknown-window Image — silent), `5560.842` plain (mirror artUri probe) — then **zero** artwork GETs for the rest of the window: cache_manager never fetched the 204 (artUri published null) and the probe cache held across the 76 s / multiple WS cycles |
| AFTER: 204 placeholder renders | `a01_after_204_placeholder.png` (same placeholder profile as BEFORE: 386 colours, stdev ≈22) |
| AFTER: item WITH artwork still renders | mock 200 item 197444 (real track): `a02_after_200_image.png` — 217 228 distinct colours / stdev ≈98; access log artUri **is** fetched when served (`5681.423` mirror probe 200 + `5681.678` cache_manager 200). Real server: `a06_real_after_200.png` — `Invincible` image renders (217 256 colours), `sync: live`, logcat window clean |
| WS stability (fixed mock pong handling) | single `WS handshake+notify -> 101` at `1793245559.067`, no churn for 76 s (earlier 21 s reconnect churn = mock frame-parser bug, fixed; the app itself pinged and got pongs) |
| Stability | `logcat -b crash` grep owntone = **0** |

### Criterion 3 — no new dependency

`git diff 67d45eb -- pubspec.yaml` → **0 lines** (byte-identical). Local
`HttpClient` probe only.

### Criterion 4 — gates (verbatim tails, final tree)

```
$ flutter analyze
No issues found! (ran in 3.2s)

$ dart format --output=none --set-exit-if-changed .
Formatted 89 files (0 changed) in 0.29 seconds.

$ flutter test --exclude-tags live
01:22 +401: All tests passed!

$ flutter build apk --debug
✓ Built build/app/outputs/flutter-apk/app-debug.apk
```

### Criterion 5 — server left as found; AVD deleted

Start (1793243xxx curls) vs end snapshots in `.night/night-010/`:
`player` and `outputs` **byte-identical** (`cmp`; `pause / vol 42 / item
197444 / prog 111908`; selected [Volumio Kitchen 42]). Queue:
count 1514→1514, **items array field-identical** (`items[i] ==
ref[i]`, incl. position 85), `version` 2306→2313 = self-delta of the
six sanctioned queue edits (two no-op artwork_url PUTs, title edit +
restore, insert + delete — all replayed/verified mid-run); no other
session movement. **Zero transport actions**: no play/pause/stop/next/
prev/seek/volume/output calls were issued (GETs + queue edits without
`playback=start` only; `state == pause` re-verified via `GET /api/player`
before and after every queue edit). `avdmanager delete avd -n
OwnToneNight_010_API_36` ✓ (config files gone); final `adb devices`
empty.

### Criterion 6 — log + commit

SESSION-LOG entry appended; implementation `620bb69` + this
docs/refinement commit, pushed `origin/remote-app/010-artwork-204-filter`.

### Harness notes (for the next device run)

- The **IME re-tap tap-adjacent-button trap** fired again: tapping the
  Connect coordinate while Gboard was open hit **Disconnect** (layout
  shifts when the keyboard shows). Always re-dump and tap **live**
  bounds after closing the IME (`keyevent 111` + settle).
- Reconfiguring the app's server host is one `pm clear` + first-run
  Settings typing — cheaper and more deterministic than editing the
  existing fields (clears focus-state surprises).
- `adb reverse tcp:3689/tcp:3688` makes a host-loopback mock the app's
  "server" with no firewall exposure and no real-server transport risk.
- A hand-rolled WS server must read **masked frames as mask(4)+payload
  (ln)** — consuming `ln` bytes total corrupts the stream and surfaces
  to the client as a silent-drop reconnect every ~20 s (dart:io
  pingInterval 10 s + pong timeout), which looks exactly like an app bug.
- zsh `===` in an unquoted echo aborts the command line (`= cmd`
  expansion) — quote it.
- The `poll_natural.py` first artwork curl logged `status=000` once
  (transient curl timeout) — re-check statuses before concluding absence.

## Adversary round

**DONE 2026-10-29** (fix cycle after test-adversary commit `bad97c1`).
The adversary's hunt (13 new tests, one genuine violation) pinned **V1**:
`ArtworkBox._probe`'s awaited continuation checked only `mounted`, so a
URL swap mid-probe (the real now-playing path — same State,
`didUpdateWidget`) let the stale verdict clobber the current URL **both
ways**: a late 204 hid the swapped-in 200's rendered image (contract
c1b), and a late `false` re-mounted the current URL's `Image` onto the
failure branch of an already-probed 204 (Goal 1 / c1a oracle). Both reds
reproduced verbatim.

**The guard** (`lib/src/ui/now_playing_screen.dart`, `_probe`): capture
`widget.url` at probe-schedule time; after the await, discard the
verdict unless `mounted` **and** `widget.url` still matches — the same
discipline as `mirror_handler._sameNowPlaying`. No ArtworkProbe redesign.

**Second defect the guard exposed** (same violation site, adjudicated as
part of V1): discarding a stale verdict unmounts nothing, but the swap
*does* unmount the replaced URL's unknown-window `Image` — and that
frozen fetch (the green profile tests pin its existence: `requestCount
== 2` per entry: probe + unknown-window Image GET) can reject **after**
the swap with zero listeners on its completer, so Flutter's
`ImageStreamCompleter.reportError` escalates the late
`NetworkImageLoadException` (e.g. the 204) to `FlutterError.onError` —
an uncaught framework error. The URL-scope guard alone left red (a)
failing on that escalation, not on state. Fix: `_absorbLateFailure` —
for each probed URL the box attaches one `ImageStreamListener` (with
`onError`) to the **same** `NetworkImage` key `Image.network` uses, so
the `ImageCache` hands out the same completer (still exactly ONE GET per
URL) and a late rejection lands as handled; the listener detaches when
the load settles or the State disposes. Do not remove it when
"simplifying" — it is what makes the V1 discard safe.

Now-green tails (full suite, final tree):

```
$ flutter analyze
No issues found! (ran in 2.6s)

$ dart format --output=none --set-exit-if-changed .
Formatted 92 files (0 changed) in 0.27 seconds.

$ flutter test --exclude-tags live
01:20 +419: All tests passed!
```

(`test/artwork_204_adversarial_test.dart` 13/13 including both race
reds; `git diff bad97c1..HEAD -- test/` empty — lib-only fix.)
