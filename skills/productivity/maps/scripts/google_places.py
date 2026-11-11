import json
import math
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone, UTC

from opening_hours import format_when, unknown_hours

API_KEY_ENV = "GOOGLE_MAPS_API_KEY"
DATA_SOURCE = "Google Places API (New)"
ATTRIBUTION = "Powered by Google. Place data is shown as returned and is not cached."
SEARCH_TEXT_URL = "https://places.googleapis.com/v1/places:searchText"
PLACE_DETAILS_URL = "https://places.googleapis.com/v1/places/"
USER_AGENT = "HermesAgent/1.0"
MAX_RETRIES = 3
RETRY_DELAY = 1.0
MAX_BIAS_RADIUS_M = 50000
MAX_PAGE_SIZE = 20

PLACE_FIELDS = (
    "id",
    "displayName",
    "formattedAddress",
    "location",
    "rating",
    "userRatingCount",
    "googleMapsUri",
    "regularOpeningHours",
    "currentOpeningHours",
    "utcOffsetMinutes",
    "businessStatus",
    "primaryTypeDisplayName",
    "nationalPhoneNumber",
    "websiteUri",
)
SEARCH_FIELD_MASK = ",".join(f"places.{field}" for field in PLACE_FIELDS)
DETAILS_FIELD_MASK = ",".join(PLACE_FIELDS)

GOOGLE_TYPES = {
    "restaurant": "restaurant",
    "cafe": "cafe",
    "bar": "bar",
    "bakery": "bakery",
    "convenience_store": "convenience_store",
    "hospital": "hospital",
    "pharmacy": "pharmacy",
    "dentist": "dentist",
    "doctor": "doctor",
    "veterinary": "veterinary_care",
    "hotel": "hotel",
    "guest_house": "guest_house",
    "camp_site": "campground",
    "supermarket": "supermarket",
    "bookshop": "book_store",
    "laundry": "laundry",
    "atm": "atm",
    "bank": "bank",
    "gas_station": "gas_station",
    "parking": "parking",
    "airport": "airport",
    "train_station": "train_station",
    "car_wash": "car_wash",
    "car_rental": "car_rental",
    "museum": "museum",
    "cinema": "movie_theater",
    "nightclub": "night_club",
    "zoo": "zoo",
    "school": "school",
    "university": "university",
    "library": "library",
    "police": "police",
    "fire_station": "fire_station",
    "post_office": "post_office",
    "church": "church",
    "mosque": "mosque",
    "synagogue": "synagogue",
    "park": "park",
    "gym": "gym",
    "stadium": "stadium",
}


class GooglePlacesError(RuntimeError):
    pass


def get_api_key(environ=None):
    environ = os.environ if environ is None else environ
    key = (environ.get(API_KEY_ENV) or "").strip()
    return key or None


def supports_category(category):
    return category in GOOGLE_TYPES


def _scrub(text, api_key):
    return text.replace(api_key, "[redacted]") if api_key else text


def _error_detail(exc, api_key):
    try:
        payload = json.loads(exc.read().decode("utf-8"))
        message = payload.get("error", {}).get("message") or exc.reason
    except (ValueError, AttributeError, OSError):
        message = exc.reason
    return _scrub(f"HTTP {exc.code}: {message}", api_key)


def _request(url, api_key, field_mask, body=None):
    headers = {
        "User-Agent": USER_AGENT,
        "X-Goog-Api-Key": api_key,
        "X-Goog-FieldMask": field_mask,
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    last_error = "unknown error"
    for attempt in range(1, MAX_RETRIES + 1):
        req = urllib.request.Request(url, data=data, headers=headers,
                                     method="POST" if body is not None else "GET")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            last_error = _error_detail(exc, api_key)
            if exc.code not in {429, 500, 502, 503, 504}:
                raise GooglePlacesError(last_error)
        except urllib.error.URLError as exc:
            last_error = _scrub(f"URL error: {exc.reason}", api_key)
        except json.JSONDecodeError as exc:
            last_error = f"JSON parse error: {exc}"
        if attempt < MAX_RETRIES:
            time.sleep(RETRY_DELAY * attempt)
    raise GooglePlacesError(f"Google Places failed after {MAX_RETRIES} attempts. Last error: {last_error}")


def search_text(api_key, query, lat=None, lon=None, radius_m=None, included_type=None,
                open_now=False, limit=10):
    body = {"textQuery": query, "pageSize": max(1, min(int(limit), MAX_PAGE_SIZE))}
    if lat is not None and lon is not None:
        radius = min(max(int(radius_m or 1000), 1), MAX_BIAS_RADIUS_M)
        body["locationBias"] = {
            "circle": {"center": {"latitude": lat, "longitude": lon}, "radius": float(radius)}
        }
    if included_type:
        body["includedType"] = included_type
    if open_now:
        body["openNow"] = True
    payload = _request(SEARCH_TEXT_URL, api_key, SEARCH_FIELD_MASK, body)
    return payload.get("places", [])


def place_details(api_key, place_id):
    place_id = (place_id or "").strip()
    if not place_id or "/" in place_id or "?" in place_id:
        raise GooglePlacesError("A Google place id such as ChIJ... is required.")
    url = PLACE_DETAILS_URL + urllib.parse.quote(place_id, safe="")
    return _request(url, api_key, DETAILS_FIELD_MASK)


def _parse_time(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _local(moment_utc, offset_minutes):
    return (moment_utc.astimezone(UTC) + timedelta(minutes=offset_minutes)).replace(tzinfo=None)


def _hours_block(place, now_utc):
    business_status = place.get("businessStatus")
    if business_status == "CLOSED_PERMANENTLY":
        return {"state": "closed", "open_now": False, "summary": "Permanently closed", "source": "google"}
    if business_status == "CLOSED_TEMPORARILY":
        return {"state": "closed", "open_now": False, "summary": "Temporarily closed", "source": "google"}

    current = place.get("currentOpeningHours") or {}
    regular = place.get("regularOpeningHours") or {}
    open_now = current.get("openNow")
    if open_now is None:
        open_now = regular.get("openNow")
    weekly = current.get("weekdayDescriptions") or regular.get("weekdayDescriptions") or []
    if open_now is None and not weekly:
        block = unknown_hours("Google has no opening hours for this place.")
        block["source"] = "google"
        return block

    offset = place.get("utcOffsetMinutes")
    now_local = _local(now_utc, offset) if offset is not None else None
    block = {"source": "google", "weekly": weekly}
    if now_local is not None and len(weekly) == 7:
        block["today"] = weekly[now_local.weekday()]
    if open_now is None:
        block.update(state="unknown", open_now=None, summary="Opening hours listed, open-now status unavailable.")
        return block

    boundary_key = "nextCloseTime" if open_now else "nextOpenTime"
    boundary = _parse_time(current.get(boundary_key))
    when = ""
    if boundary is not None and now_local is not None:
        verb = "closes" if open_now else "opens"
        when = f", {verb} {format_when(_local(boundary, offset), now_local)}"
    block.update(
        state="open" if open_now else "closed",
        open_now=bool(open_now),
        summary=("Open now" if open_now else "Closed now") + when,
    )
    return block


def normalize_place(place, now_utc=None, ref_lat=None, ref_lon=None):
    now_utc = now_utc or datetime.now(UTC)
    location = place.get("location") or {}
    lat, lon = location.get("latitude"), location.get("longitude")
    status = _hours_block(place, now_utc)
    result = {
        "name": (place.get("displayName") or {}).get("text", ""),
        "address": place.get("formattedAddress", ""),
        "lat": lat,
        "lon": lon,
        "place_id": place.get("id", ""),
        "maps_url": place.get("googleMapsUri", ""),
        "opening_status": status,
    }
    if status.get("weekly"):
        result["hours"] = "; ".join(status["weekly"])
    for source_key, target_key in (
        ("rating", "rating"),
        ("userRatingCount", "rating_count"),
        ("nationalPhoneNumber", "phone"),
        ("websiteUri", "website"),
    ):
        if place.get(source_key) is not None:
            result[target_key] = place[source_key]
    primary = (place.get("primaryTypeDisplayName") or {}).get("text")
    if primary:
        result["type"] = primary
    if None not in (ref_lat, ref_lon, lat, lon):
        result["distance_m"] = round(_haversine(ref_lat, ref_lon, lat, lon), 1)
    return result


def _haversine(lat1, lon1, lat2, lon2):
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi, dlam = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return 2 * 6_371_000 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


__all__ = [
    "API_KEY_ENV", "ATTRIBUTION", "DATA_SOURCE", "GOOGLE_TYPES",
    "GooglePlacesError", "get_api_key", "normalize_place", "place_details",
    "search_text", "supports_category",
]
