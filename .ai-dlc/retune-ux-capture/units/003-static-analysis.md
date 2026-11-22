---
name: 003-static-analysis
status: done
intent: retune-ux-capture
supervised_steps: []
---

# Unit 003 — static APK pass (fills walk gaps)

## Goal

Extract what the walk cannot see: the full strings/settings surface, all
layouts (→ missed screens), and DAAP path constants (→ action mapping
table). Purely offline work — no server, no device, no audio risk.

## Steps

1. Decode:
   ```sh
   apktool d tools/retune/Retune_3.5.23_APKPure.apk -o tools/retune/decoded
   ```
   (`tools/retune/decoded/` is gitignored — regenerable.)
2. From `decoded/`, extract into `docs/retune-capture/static-notes.md`:
   - `res/values/strings.xml` — feature names, preference labels, action
     labels.
   - `res/xml/preferences.xml` — full settings surface (keys + defaults).
   - `AndroidManifest.xml` — permissions, activities, receivers, widget
     providers (surface confirmation; widgets = out of scope, noted).
   - DAAP/DACP constants in smali (URL paths, DMAP tag names) → **mapping
     table**: "ReTune action → DAAP path → JSON endpoint (or none → drop /
     simpler JSON way)". Mapping only — never an implementation source.
3. Layout reconciliation: list every `res/layout/*.xml` that corresponds
   to a screen **the walk never reached**; for each: cheap re-walk (if the
   AVD is up and it's read-only navigation) or mark `missed` with a reason.
4. Write `static-notes.md` with the four sections above + the
   layout-reconciliation list.

## Completion criteria

1. `decoded/` produced (evidence: `apktool` output tail).
2. `static-notes.md` contains: strings summary, preferences surface,
   manifest summary, DAAP→JSON mapping table.
3. Every layout either walked, marked out (itunes-only/widget), or marked
   `missed` with a reason — zero unexplained layouts.

## Result — DONE 2026-11-19

Full write-up: `docs/retune-capture/static-notes.md`. Tooling: REA
`rea-agents` 6.7.0 (`decode-android-resources`, evidence
`ev_86fc59ef…`, subject sha256 `b1279ad6…4b98`; apktool lane client 3.0.3)
+ `apktool d -s` → `tools/retune/decoded/` (gitignored).
Manifest inventory (activities incl. exported trio NowPlaying/Speakers/
VideoDevice; MEDIA_BUTTON + VolumeChange receivers; 4 home-screen widgets
→ out: scope; permissions incl. CHANGE_WIFI_MULTICAST_STATE = discovery
evidence). Preferences: 12 keys w/ defaults — all match runtime capture
(no hidden prefs). Layout reconciliation: **132 layouts, zero unexplained**
(covered ≈40 incl. row templates; 46 `out: itunes-only`; 4 widget; 2
pairing-out; deferred 3: connecting/ratings_dialog/select_library).
Mapping-table highlights + drops feed `feature-inventory.md`; nothing found
that requires a DAAP-only capability (D5 holds — no fallback spike needed).
