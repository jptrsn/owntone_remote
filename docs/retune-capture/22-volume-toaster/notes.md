# 22 — Volume toaster (playing-state overlay) — DEFERRED (visual)

ReTune uses hardware volume keys → server volume + a custom Toast
(`master_volume_toaster.xml`). During capture, volume keys raised server
volume 31→41 (step **5**/press — R-14 datum) and the Toast is a transient
non-a11y overlay: not machine-verifiable (screencap saved as `screen.png`
but its content is unconfirmed — taken at 1 s delay, Toast may have
auto-dismissed; hierarchy.xml at that moment caught a leftover popup, not
the Toast). Marked **deferred: visual — human check** (and layout
existence confirmed by static pass). Restored 41→31 via API (204).
