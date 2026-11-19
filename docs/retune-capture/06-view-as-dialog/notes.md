# 06 — "View as" dialog

AlertDialog, title "View as"; CheckedTextView options **List** / **Grid**;
Cancel. Selecting persists per app pref (re-opened as dialog, default
reflects current mode).

Behaviour verified: toggled Artists → Grid (07) → restored to List
(ListView re-confirmed via hierarchy). This was the ONLY ReTune setting
mutation made during the walk (transient, reverted).

## Diff-list note
Grid mode with artwork + counts on library views is a candidate
improvement (see 07).
