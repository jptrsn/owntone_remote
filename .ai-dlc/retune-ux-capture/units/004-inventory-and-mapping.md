---
name: 004-inventory-and-mapping
status: done
intent: retune-ux-capture
supervised_steps: [4]
---

# Unit 004 — feature inventory + JSON mapping + user pruning

## Goal

The decision artifact: `docs/retune-capture/feature-inventory.md` — every
ReTune feature mapped to the JSON surface or explicitly cut — pruned and
approved by the user. This is the gate for `spec-authoring`.

## Steps

1. Assemble `feature-inventory.md` from the walk (002) + static pass
   (003): one row per feature/screen —
   `# | Feature/screen | Screens (refs) | Elements | Actions (user →
   effect) | ReTune behaviour notes | JSON API mapping (endpoint) |
   Status`.
2. Apply the status rules (protocol doc § Inventory):
   - `in-v1` — maps cleanly to JSON, keep;
   - `out: itunes-only` — radio, movies/TV, iTunes U, podcasts,
     audiobooks, courses, classes, Genius, home sharing. **One line each,
     no further documentation** (AGENTS.md §5);
   - `out: scope` — in-scope protocol-wise, cut for v1 (rationale inline);
   - `gap` — no obvious JSON equivalent → recommend the simpler JSON
     way or drop. Never "reverse-engineer the DAAP call".
3. Add the coverage table (walked screens + layouts → covered/out/missed).
4. `supervised: true` — **user pruning session**: walk the inventory with
   the user; the user sets the final status per row (in-v1 vs out),
   resolves every `gap`, and confirms browse depth (genres? composers?
   playlist folders? grid views?) and queue-reordering. Record the user's
   decisions verbatim in `## Result` (they feed REQUIREMENTS.md).
5. Update `docs/REQUIREMENTS.md` scope notes (S7/S8/S10) to match the
   pruned inventory — draft only; `spec-authoring` finalizes.

## Completion criteria

1. Inventory complete: every walked feature + every mapping-table action
   present; zero iTunes-only features documented in depth.
2. Every row has a JSON mapping or an explicit out/gap + recommendation.
3. Coverage table honest (misses listed, not hidden).
4. `supervised: true` — user has pruned + approved (recorded verbatim in
   `## Result`); REQUIREMENTS.md scope notes updated to match.

## Result — IN PROGRESS (awaiting user pruning gate)

Inventory written: `docs/retune-capture/feature-inventory.md` (per-screen
features → JSON endpoints → status; ITUNES-ONLY-LISTED section; gap
candidates). Actionable diff list: `docs/retune-capture/diff-list.md`
(D-01…D-19, each with evidence, current-code reference, effort,
recommendation; **Decision column awaiting the user**). Criterion 4
(user pruning, verbatim) + REQUIREMENTS.md scope-note updates land on the
user's pass over the diff list.

**Gate closed 2026-11-19** — user pruning decision verbatim:
*"confirm drops, save everything to the project using the ai-dlc
approach, then we need to draft a series of github issues that report
each change that is required to the existing project."*

**Final in-v1.1 list (accepted):** D-01→R-20, D-02→R-15, D-04→R-17,
D-05→R-16, D-06→R-19, D-09→R-18 (`docs/REQUIREMENTS.md` § v1.1
additions). **Dropped (confirmed):** D-11 widgets, D-12 visualizer/peak
meter, D-13 default-view/restore-last, D-14 playlist sort-by,
D-15 screen-off-disconnect + screen-lock (pause-on-call → verification
item for next dv pass), D-16 half-stars, D-17 history, D-18 drag-confirm
dialog. **Deferred (taste):** D-03 grid mode, D-10 theme setting.
Issues drafted: `.ai-dlc/retune-ux-capture/issues/` (6) — publish via
`gh issue create` on user go.

Pre-gate user decisions recorded verbatim:
- 2026-11-19: skip pairing UI ("owntone_remote already has IP/port
  dialog; **only improvement: auto-discovery**"); Composers/Radio/
  Audiobooks/Libraries **out of scope**; Genius **drop entirely**;
  ask before playback (honored — supervised window used, incidents
  logged).
