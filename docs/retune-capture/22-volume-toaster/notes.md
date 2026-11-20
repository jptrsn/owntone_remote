# 22 — Volume toaster (playing-state overlay) — MACHINE-VERIFIED 2026-11-19

ReTune uses hardware volume keys → server volume + a custom Toast
(`master_volume_toaster.xml`). Verified by rapid screencap + byte-diff of
screen bands (audit, `23-playing-audit/notes.md`): overlay appears in the
**center band (y≈900–1500)** and **auto-hides after ~1–2.5 s**; no a11y
node (pure Toast). Keys intercepted **app-wide** (np AND library both
drive `dmcp.volume`; step **5**/press). `screen.png` is the caught frame
(`/tmp/t1.png`). Volume changes during audits were restored each time
(31→41→31, 100→95→100).
