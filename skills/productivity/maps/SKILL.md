---
name: maps
description: "Find places with opening hours, geocode, route, timezones."
version: 1.3.0
author: Mibayy
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [maps, geocoding, places, routing, distance, directions, nearby, location, openstreetmap, nominatim, overpass, osrm]
    category: productivity
    requires_toolsets: [terminal]
    supersedes: [find-nearby]
required_environment_variables:
  - name: GOOGLE_MAPS_API_KEY
    prompt: Google Places API key
    help: "Create one in the Google Cloud console with Places API (New) enabled"
    required_for: "Google Places search; the OpenStreetMap lookups need no key"
    optional: true
---

# Maps Skill

Location intelligence using free, open data sources. 10 commands, 44 POI
categories, zero dependencies (Python stdlib only), no API key required.
Place results carry opening hours with a computed open-now status.

Data sources: OpenStreetMap/Nominatim, Overpass API, OSRM, TimeAPI.io. Google
Places (New) is used only when `GOOGLE_MAPS_API_KEY` is set; OpenStreetMap is
the default and the fallback.

This skill supersedes the old `find-nearby` skill — all of find-nearby's
functionality is covered by the `nearby` command below, with the same
`--near "<place>"` shortcut and multi-category support.

## When to Use

- User sends a Telegram location pin (latitude/longitude in the message) → `nearby`
- User wants coordinates for a place name → `search`
- User has coordinates and wants the address → `reverse`
- User asks for nearby restaurants, hospitals, pharmacies, hotels, etc. → `nearby`
- User asks whether a place is open, or for opening hours → `nearby --open-now`, or the `opening_status` field of `nearby` / `search`
- User wants ratings or Google place details and a key is configured → `places` / `place-details`
- User wants driving/walking/cycling distance or travel time → `distance`
- User wants turn-by-turn directions between two places → `directions`
- User wants timezone information for a location → `timezone`
- User wants to search for POIs within a geographic area → `area` + `bbox`

## Prerequisites

Python 3.11+ (stdlib only — no pip installs needed).

Script path: `~/.hermes/skills/maps/scripts/maps_client.py`

Optional Google Places: put `GOOGLE_MAPS_API_KEY=<key>` in `~/.hermes/.env`
(secrets live only there, never in the repo or `config.yaml`). When the
terminal backend is sandboxed or remote, also add the name to
`terminal.env_passthrough` in `~/.hermes/config.yaml`:

```yaml
terminal:
  env_passthrough: [GOOGLE_MAPS_API_KEY]
```

The key needs the Places API (New) enabled. Without it everything below
works through OpenStreetMap.

## Commands

```bash
MAPS=~/.hermes/skills/maps/scripts/maps_client.py
```

### search — Geocode a place name

```bash
python $MAPS search "Eiffel Tower"
python $MAPS search "1600 Pennsylvania Ave, Washington DC"
```

Returns: lat, lon, display name, type, bounding box, importance score.

### reverse — Coordinates to address

```bash
python $MAPS reverse 48.8584 2.2945
```

Returns: full address breakdown (street, city, state, country, postcode).

### nearby — Find places by category

```bash
# By coordinates (from a Telegram location pin, for example)
python $MAPS nearby 48.8584 2.2945 restaurant --limit 10
python $MAPS nearby 40.7128 -74.0060 hospital --radius 2000

# By address / city / zip / landmark — --near auto-geocodes
python $MAPS nearby --near "Times Square, New York" --category cafe
python $MAPS nearby --near "90210" --category pharmacy

# Multiple categories merged into one query
python $MAPS nearby --near "downtown austin" --category restaurant --category bar --limit 10
```

46 categories: restaurant, cafe, bar, hospital, pharmacy, hotel, guest_house,
camp_site, supermarket, atm, gas_station, parking, museum, park, school,
university, bank, police, fire_station, library, airport, train_station,
bus_stop, church, mosque, synagogue, dentist, doctor, cinema, theatre, gym,
swimming_pool, post_office, convenience_store, bakery, bookshop, laundry,
car_wash, car_rental, bicycle_rental, taxi, veterinary, zoo, playground,
stadium, nightclub.

```bash
# "Italian restaurants near the Colosseum, open now?"
python $MAPS nearby --near "Colosseum Rome" --category restaurant --cuisine italian --open-now
```

Each result includes: `name`, `address`, `lat`/`lon`, `distance_m`,
`maps_url` (clickable Google Maps link), `directions_url` (Google Maps
directions from the search point), and promoted tags when available —
`cuisine`, `hours` (raw opening_hours), `phone`, `website`.

Every result also has `opening_status`: `state` (`open`, `closed`,
`unknown`), `open_now` (true, false, or null), a ready-to-quote `summary`
("Open now, closes at 23:00" / "Closed now, opens tomorrow at 09:00"),
`today`, and `timezone` (the place's own). `unknown` means OpenStreetMap has
no hours for the place, the syntax could not be evaluated, or the timezone
was not found: say so plainly and suggest calling or checking the website.
Public and school holiday rules are not applied (`note` says so).

`--open-now` keeps only places that are open and reports how many were
dropped in `excluded_by_open_now` (`closed`, `unknown_hours`); tell the user
when unknown-hours places were left out. `--cuisine` filters on the OSM
`cuisine` tag.

`--provider auto` (default) uses Google Places when `GOOGLE_MAPS_API_KEY` is
set and OpenStreetMap otherwise; `osm` forces OpenStreetMap. The result's
`provider` names the source, `provider_note` explains any fallback (missing
key, Google error, a category Google has no type for), and `hours_caveat`
warns that OSM hours may be missing. Google results use the same
`opening_status` shape plus `rating`, `rating_count`, `place_id`, and
`attribution`; show the attribution when presenting Google data and do not
store the data.

### places / place-details — Google Places (key required)

```bash
python $MAPS places italian restaurants --near "Times Square" --open-now --limit 5
python $MAPS place-details ChIJ...   # place_id from a places or nearby result
```

Text search biased to a location, then details by id: opening hours, rating,
rating count, phone, website. Requests ask Google only for the fields
shown, which bounds cost. Without `GOOGLE_MAPS_API_KEY` both exit with an
error that points back to `nearby` / `search`.

### distance — Travel distance and time

```bash
python $MAPS distance "Paris" --to "Lyon"
python $MAPS distance "New York" --to "Boston" --mode driving
python $MAPS distance "Big Ben" --to "Tower Bridge" --mode walking
```

Modes: driving (default), walking, cycling. Returns road distance, duration,
and straight-line distance for comparison.

### directions — Turn-by-turn navigation

```bash
python $MAPS directions "Eiffel Tower" --to "Louvre Museum" --mode walking
python $MAPS directions "JFK Airport" --to "Times Square" --mode driving
```

Returns numbered steps with instruction, distance, duration, road name, and
maneuver type (turn, depart, arrive, etc.).

### timezone — Timezone for coordinates

```bash
python $MAPS timezone 48.8584 2.2945
python $MAPS timezone 35.6762 139.6503
```

Returns timezone name, UTC offset, and current local time.

### area — Bounding box and area for a place

```bash
python $MAPS area "Manhattan, New York"
python $MAPS area "London"
```

Returns bounding box coordinates, width/height in km, and approximate area.
Useful as input for the bbox command.

### bbox — Search within a bounding box

```bash
python $MAPS bbox 40.75 -74.00 40.77 -73.98 restaurant --limit 20
```

Finds POIs within a geographic rectangle. Use `area` first to get the
bounding box coordinates for a named place.

## Working With Telegram Location Pins

When a user sends a location pin, the message contains `latitude:` and
`longitude:` fields. Extract those and pass them straight to `nearby`:

```bash
# User sent a pin at 36.17, -115.14 and asked "find cafes nearby"
python $MAPS nearby 36.17 -115.14 cafe --radius 1500
```

Present results as a numbered list with names, distances, and the
`maps_url` field so the user gets a tap-to-open link in chat. For "open
now?" questions, read `opening_status.summary`; if `open_now` is null, say
the hours are unavailable and verify with `web_search` since OSM hours are
community-maintained and not always current.

## Workflow Examples

**"Find Italian restaurants near the Colosseum":**
1. `nearby --near "Colosseum Rome" --category restaurant --radius 500`
   — one command, auto-geocoded

**"Italian restaurants near the Colosseum, open now?":**
1. `nearby --near "Colosseum Rome" --category restaurant --cuisine italian --open-now`
2. Quote each `opening_status.summary`; mention `excluded_by_open_now.unknown_hours`
   and the `hours_caveat` or `provider_note` when present

**"What's near this location pin they sent?":**
1. Extract lat/lon from the Telegram message
2. `nearby LAT LON cafe --radius 1500`

**"How do I walk from hotel to conference center?":**
1. `directions "Hotel Name" --to "Conference Center" --mode walking`

**"What restaurants are in downtown Seattle?":**
1. `area "Downtown Seattle"` → get bounding box
2. `bbox S W N E restaurant --limit 30`

## Pitfalls

- Nominatim ToS: max 1 req/s (handled automatically by the script)
- Never print or log `GOOGLE_MAPS_API_KEY`; the script sends it only in a request header
- Google Places terms apply: show `attribution`, no scraping of maps.google.com, no caching of place data beyond `place_id`
- Google requests with hours are billed per call; use `--provider osm` when hours are not needed
- `nearby` requires lat/lon OR `--near "<address>"` — one of the two is needed
- OSRM routing coverage is best for Europe and North America
- Overpass API can be slow during peak hours; the script automatically
  falls back between mirrors (overpass-api.de → overpass.kumi.systems)
- `distance` and `directions` use `--to` flag for the destination (not positional)
- If a zip code alone gives ambiguous results globally, include country/state

## Verification

```bash
python ~/.hermes/skills/maps/scripts/maps_client.py search "Statue of Liberty"
# Should return lat ~40.689, lon ~-74.044

python ~/.hermes/skills/maps/scripts/maps_client.py nearby --near "Times Square" --category restaurant --limit 3
# Should return a list of restaurants within ~500m of Times Square
```
