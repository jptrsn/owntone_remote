# tools/retune/

Reference material for the `retune-ux-capture` intent only.

- `Retune_3.5.23_APKPure.apk` — ReTune 3.5.23 (SquallyDoc), the legacy
  Android remote for iTunes / forked-daapd / OwnTone. **Proprietary.**
- `decoded/` (gitignored) — `apktool d` output, regenerable:
  `apktool d Retune_3.5.23_APKPure.apk -o decoded`

## Rules

1. UX reference only: it documents *behaviour* (screens, flows, actions)
   that we re-implement from the spec in Material 3.
2. **No code porting, no asset reuse, no branding.** Decompiled code,
   drawables, layouts, strings and iconography from this APK must never
   enter the app (PLAN D12, AGENTS.md §6). The app is planned as open
   source.
3. Never a build dependency; never redistributed with the app or its
   source.
4. Sideloading it onto the capture AVD (`Retune_API_33`) is allowed and
   expected; the installed instance is a **read-only paired reference**
   (AGENTS.md §3).
