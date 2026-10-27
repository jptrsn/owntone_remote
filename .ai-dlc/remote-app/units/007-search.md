---
name: 007-search
status: pending
intent: remote-app
supervised_steps: []
---

# Unit 007 — search (R-13)

R-IDs: R-13. Opened by device-verification unit 001: no search UI ever
existed (`SCREENS.md:28` — `Search | TBD | R-13`), so the R-13
acceptance rows were recorded FAIL there; this unit builds the feature
and those rows are re-run there afterwards.

## Goal

Search the OwnTone library: `GET /api/search?type=tracks,artists,albums,playlists&query=`,
results grouped by type, tap-through to the existing detail screens
(album tracks / artist albums / playlist tracks), "load more" per group.

## Steps / notes

- Entry point: search affordance on the library home (and/or app bar) —
  keep the 360-logical-px viewport rule from unit 004 (no overflow).
- Reuse the paged-browse row widgets (`browse_rows.dart`) so row visuals
  and semantics labels don't drift; track rows show rating stars per
  R-12 rules.
- Debounced query; empty-query state (no search yet) and no-results
  state are distinct; offline/error states like the other lists.
- Pagination per group (server `offset`/`limit`); no duplication across
  pages.
- Tests from REQUIREMENTS R-13 rows (not the impl): grouped parse,
  pagination, empty/no-results, tap-through routing; use `test/fakes/`
  for the HTTP layer. No `live`-tagged test needs the server.

## Completion criteria

1. R-13 acceptance rows (REQUIREMENTS.md) verified on-device
   (own per-unit AVD or `RemoteDev_API_36` if free — never another
   session's emulator); evidence in `## Result`.
2. Gates green (`analyze`, `format`, `test --exclude-tags live`, debug
   build).
3. `SCREENS.md` Search row updated from TBD.
4. device-verification/001 table R-13 rows updated with the new evidence.
5. SESSION-LOG entry + commit `remote-app/007: ...`.

## Result

*(fill)*
