---
title: "Outputs should be one tap from every browse screen (app-bar action)"
labels: enhancement, area:outputs, area:ui
---

## Change
Outputs are reachable only from Now Playing
(`now_playing_screen.dart:329`). ReTune puts a **Speakers** action in the
app bar of *every* screen — switching outputs mid-browse is a core remote
gesture (`docs/retune-capture/14-speakers/`).

## Expected
`BrowseScreenScaffold` gains an outputs icon action (same destination as
now-playing's `OutputsScreen`). **Viewport constraint:** the unit-004
finding applies — at 360 logical px the app bar already overflows with
three actions on some titles; verify no overflow at 360 dp (the library
home has no other actions; paged lists have at most title + back, so the
icon fits — confirm with a widget test pumping at 360 dp).

## Where
`lib/src/ui/browse_screen_scaffold.dart` (add `actions:` support),
`lib/src/ui/browse_screens.dart`, `lib/src/ui/paged_browse_screen.dart`.

## Requirements
R-18. Diff-list D-09; evidence `docs/retune-capture/14-speakers/`.

## Repro / verification
Widget test: browse screen at 360×800 pumps without RenderFlex/desk overflow
and finds the outputs icon (semantics label); tap pushes `OutputsScreen`
(fake provider). Gates green.
