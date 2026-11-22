# 11 — Genre detail (ArtistsViewActivity, title = genre)

Genre tap → list of ARTISTS in that genre (e.g. "Acoustic" → Daniela
Andrade…). Confirms hierarchy: genre → artists → (artist → songs), i.e.
ReTune does not offer genre→songs directly.

## JSON mapping
- `GET /api/library/artists?cc=genre,id`.
