---
title: "Server auto-discovery (mDNS) in connection setup"
labels: enhancement, area:ui
---

## Change
Connection setup is manual IP/port only. The ReTune reference found the
server in **0.4 s** on the LAN via mDNS (`docs/retune-capture/` unit-001
notes) — the user's approved improvement to the pairing/config flow
("only improvement: auto-discovery", 2026-11-19).

## Expected
Server-config screen gains a **Scan** affordance: browse the LAN for the
OwnTone service and list hits (name + host + port) for one-tap selection,
which pre-fills/validates through the existing R-01 connect flow.
Manual host/port entry stays the default path and always usable —
**discovery must never block it** (scan is a side panel with its own
timeout/error state). No pairing ceremony (OwnTone JSON has none).

**Pre-flight (do first):** verify the real advertisement on the live
server — `dns-sd -B _owntone-server._tcp` (and `_http._tcp`
cross-check) against 192.168.1.13; record the exact service type +
instance format here before coding. (OwnTone advertises via Avahi;
check `/api/config` + avahi publish. Do NOT copy ReTune's `_dacp._tcp` —
that's DAAP.)

## Where
`lib/src/settings/` (server-config screen), new `lib/src/discovery/`
(mDNS client — pick a maintained plugin, e.g. `mdns_query`/`network_info_plus`
combo; justify choice in the PR); Android mDNS permissions note
(CHANGE_WIFI_MULTICAST_STATE equivalent — verify whether needed on
Android for *query*, it typically is not).

## Requirements
R-20. Diff-list D-01 (approved 2026-11-19).

## Repro / verification
`live`-tagged discovery test (LAN server) asserting the instance resolves
to host:port matching `/api/config`; widget test with a fake discovery
source: scan lists fakes, tap pre-fills config, scan failure shows the
error state with manual entry still enabled. Gates green. On-device check
on the Pixel 6 (same-LAN) with evidence in the unit.
