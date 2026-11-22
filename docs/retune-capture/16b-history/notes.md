# 16b — History (UpNextViewActivity, spinner=History)

Same activity; spinner switches Up Next ⇄ History. Section header
**"Previously Played"**; rows identical template (title + "artist - album").

## Gap analysis
- OwnTone JSON API has **no play-history endpoint** (queue is current
  only). `gap` → recommend DROP (protocol: simpler JSON way or drop) —
  alternative: keep last-N played client-side in the new app (scope
  creep; user gate decision in diff list).
