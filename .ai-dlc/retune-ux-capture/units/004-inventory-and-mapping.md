---
name: 004-inventory-and-mapping
status: pending
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

## Result

*(fill: user's pruning decisions verbatim, final in-v1 list, resolved
gaps, open items deferred to spec-authoring)*
