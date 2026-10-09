---
name: 003-static-analysis
status: pending
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

## Result

*(fill: mapping table highlights, missed layouts + resolution, anything
that changes the inventory)*
