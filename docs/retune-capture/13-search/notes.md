# 13 — Search screen (SearchViewActivity, empty state)

App bar: title "Retune" (drawer toggle), AutoCompleteTextView (hint
"Search"), **Clear query** (X) action, Speakers, More. Mini bar persists.
Empty body until query typed. IME opens on focus.

Behaviour: search is **live** as you type (results replace body); Clear
query empties the field. Back closes IME first, then leaves search.

## JSON mapping
- `GET /api/search` — new app R-13 already builds grouped results; matches
  ReTune's shape (see 13b).
