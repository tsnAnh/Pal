from __future__ import annotations

import importlib.util
import io
import json
import sys
import urllib.error
from datetime import datetime, timezone, UTC
from pathlib import Path
from urllib.parse import urlparse

import pytest

SCRIPTS = Path(__file__).resolve().parents[2] / "skills" / "productivity" / "maps" / "scripts"
FAKE_KEY = "dummy-not-a-real-key"
NOW_UTC = datetime(2026, 11, 11, 12, 0, tzinfo=UTC)
ROME = "Europe/Rome"


@pytest.fixture(scope="module")
def maps():
    sys.path.insert(0, str(SCRIPTS))
    spec = importlib.util.spec_from_file_location("maps_client_under_test", SCRIPTS / "maps_client.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    yield module
    sys.path.remove(str(SCRIPTS))


@pytest.fixture(scope="module")
def hours(maps):
    return maps.opening_hours


class FakeResponse:
    def __init__(self, payload):
        self._body = json.dumps(payload).encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeNetwork:
    def __init__(self, monkeypatch, maps, routes):
        self.routes = routes
        self.requests = []
        monkeypatch.setattr(maps.urllib.request, "urlopen", self._urlopen)
        monkeypatch.setattr("time.sleep", lambda *_: None)
        monkeypatch.setattr(maps, "utc_now", lambda: NOW_UTC)

    def _urlopen(self, req, timeout=None):
        url = req.full_url if hasattr(req, "full_url") else str(req)
        host = urlparse(url).netloc
        self.requests.append(req)
        handler = self.routes.get(host)
        if handler is None:
            raise AssertionError(f"unexpected request to {host}")
        result = handler(req)
        if isinstance(result, Exception):
            raise result
        return FakeResponse(result)

    def to(self, host):
        return [r for r in self.requests if urlparse(r.full_url).netloc == host]


COLOSSEUM = [{"lat": "41.8902", "lon": "12.4922", "display_name": "Colosseum, Rome"}]


def overpass_elements():
    base = {"type": "node", "lon": 12.4930}
    return {"elements": [
        {**base, "id": 1, "lat": 41.8905, "tags": {
            "name": "Trattoria Aperta", "amenity": "restaurant", "cuisine": "italian",
            "opening_hours": "Mo-Su 12:00-23:00"}},
        {**base, "id": 2, "lat": 41.8906, "tags": {
            "name": "Pizzeria Chiusa", "amenity": "restaurant", "cuisine": "italian;pizza",
            "opening_hours": "Mo-Fr 18:00-23:00"}},
        {**base, "id": 3, "lat": 41.8907, "tags": {
            "name": "Osteria Senza Orari", "amenity": "restaurant", "cuisine": "italian"}},
    ]}


def osm_routes(overpass=overpass_elements):
    return {
        "nominatim.openstreetmap.org": lambda req: COLOSSEUM,
        "overpass-api.de": lambda req: overpass(),
        "timeapi.io": lambda req: {"timeZone": ROME},
    }


def google_place(**overrides):
    place = {
        "id": "ChIJtrattoria",
        "displayName": {"text": "Trattoria Google"},
        "formattedAddress": "Via dei Fori Imperiali 1, Roma",
        "location": {"latitude": 41.8905, "longitude": 12.4930},
        "rating": 4.6,
        "userRatingCount": 812,
        "googleMapsUri": "https://maps.google.com/?cid=1",
        "utcOffsetMinutes": 60,
        "businessStatus": "OPERATIONAL",
        "primaryTypeDisplayName": {"text": "Italian restaurant"},
        "currentOpeningHours": {
            "openNow": True,
            "nextCloseTime": "2026-11-11T21:00:00Z",
            "weekdayDescriptions": [
                "Monday: 12:00 – 22:00", "Tuesday: 12:00 – 22:00", "Wednesday: 12:00 – 22:00",
                "Thursday: 12:00 – 22:00", "Friday: 12:00 – 23:00", "Saturday: 12:00 – 23:00",
                "Sunday: Closed",
            ],
        },
    }
    place.update(overrides)
    return place


def run(maps, capsys, argv):
    args = maps.build_parser().parse_args(argv)
    handler = {
        "nearby": maps.cmd_nearby, "search": maps.cmd_search, "places": maps.cmd_places,
        "place-details": maps.cmd_place_details, "bbox": maps.cmd_bbox,
    }[args.command]
    handler(args)
    return json.loads(capsys.readouterr().out)


class TestOpeningHoursParsing:
    def at(self, hours, raw, day, hhmm):
        now = datetime.strptime(f"2026-11-{day:02d} {hhmm}", "%Y-%m-%d %H:%M")
        return hours.evaluate_schedule(hours.parse_opening_hours(raw), now)

    def test_24_7_is_always_open(self, hours):
        result = self.at(hours, "24/7", 11, "03:30")
        assert result["open_now"] is True
        assert result["summary"] == "Open now, open around the clock"
        assert result["today"] == "open 24 hours"

    def test_weekday_range_reports_close_time_and_today(self, hours):
        result = self.at(hours, "Mo-Fr 09:00-17:30", 11, "10:00")
        assert (result["state"], result["summary"], result["today"]) == (
            "open", "Open now, closes at 17:30", "09:00-17:30")

    def test_closed_before_opening_says_when_it_opens(self, hours):
        result = self.at(hours, "Mo-Fr 09:00-17:30", 11, "07:00")
        assert result["open_now"] is False
        assert result["summary"] == "Closed now, opens at 09:00"

    def test_unlisted_days_are_closed_and_next_open_is_named(self, hours):
        result = self.at(hours, "Mo-Fr 09:00-17:30", 14, "12:00")
        assert result["today"] == "closed"
        assert result["summary"] == "Closed now, opens Mon at 09:00"

    def test_closed_after_hours_opens_tomorrow(self, hours):
        result = self.at(hours, "Mo-Su 09:00-17:00", 11, "18:00")
        assert result["summary"] == "Closed now, opens tomorrow at 09:00"

    def test_off_rule_overrides_earlier_rule_for_that_day(self, hours):
        raw = "Mo-Su 10:00-22:00; We off"
        assert self.at(hours, raw, 11, "12:00")["open_now"] is False
        assert self.at(hours, raw, 12, "12:00")["open_now"] is True

    def test_closed_keyword_is_off(self, hours):
        assert self.at(hours, "Mo-Fr 10:00-18:00; Sa,Su closed", 14, "12:00")["open_now"] is False

    def test_overnight_range_stays_open_past_midnight(self, hours):
        raw = "Fr,Sa 20:00-02:00"
        late_friday = self.at(hours, raw, 13, "23:00")
        assert late_friday["summary"] == "Open now, closes tomorrow at 02:00"
        saturday_small_hours = self.at(hours, raw, 14, "01:00")
        assert saturday_small_hours["open_now"] is True
        assert saturday_small_hours["summary"] == "Open now, closes at 02:00"
        assert self.at(hours, raw, 14, "03:00")["open_now"] is False

    def test_overnight_rule_does_not_open_the_wrong_morning(self, hours):
        assert self.at(hours, "Fr 20:00-02:00", 11, "01:00")["open_now"] is False

    def test_split_shift(self, hours):
        raw = "Mo-Su 11:00-14:00,18:00-23:00"
        midday = self.at(hours, raw, 11, "15:00")
        assert midday["summary"] == "Closed now, opens at 18:00"
        assert midday["today"] == "11:00-14:00, 18:00-23:00"

    def test_closing_at_24_00_reads_as_midnight(self, hours):
        assert self.at(hours, "Mo-Su 10:00-24:00", 11, "20:00")["summary"] == "Open now, closes at midnight"

    def test_contiguous_days_do_not_report_a_midnight_close(self, hours):
        result = self.at(hours, "Mo-Su 00:00-24:00", 11, "12:00")
        assert result["summary"] == "Open now, open around the clock"

    def test_public_holiday_rules_are_flagged_not_applied(self, hours):
        result = self.at(hours, "Mo-Fr 09:00-17:00; PH off", 11, "10:00")
        assert result["open_now"] is True
        assert "holiday" in result["note"]

    @pytest.mark.parametrize("raw", [
        "sunrise-sunset", "Mar-Oct Mo-Fr 10:00-18:00", "Mo-Fr 10:00+", 'Mo-Fr 10:00-18:00 "by appointment"',
        "Mo-Fr 25:00-26:00", "Mo-Fr 08:00-08:00",
    ])
    def test_unsupported_syntax_is_reported_unknown_with_raw_value(self, hours, raw):
        result = hours.describe_hours(raw, ROME, NOW_UTC)
        assert result["state"] == "unknown"
        assert result["open_now"] is None
        assert result["raw"] == raw

    def test_missing_tag_says_osm_has_no_hours(self, hours):
        result = hours.describe_hours(None, ROME, NOW_UTC)
        assert result["open_now"] is None
        assert "OpenStreetMap has no opening hours" in result["summary"]

    def test_unknown_timezone_refuses_to_guess_open_now(self, hours):
        result = hours.describe_hours("Mo-Su 10:00-22:00", None, NOW_UTC)
        assert result["open_now"] is None
        assert result["raw"] == "Mo-Su 10:00-22:00"
        assert "Timezone" in result["summary"]

    def test_evaluated_in_the_places_timezone_not_utc(self, hours):
        raw = "Mo-Su 09:00-12:30"
        assert hours.describe_hours(raw, ROME, NOW_UTC)["open_now"] is False
        assert hours.describe_hours(raw, "Europe/London", NOW_UTC)["open_now"] is True


class TestOsmRequestToResult:
    def test_italian_restaurants_open_now_returns_hours(self, maps, monkeypatch, capsys):
        net = FakeNetwork(monkeypatch, maps, osm_routes())
        monkeypatch.delenv("GOOGLE_MAPS_API_KEY", raising=False)
        out = run(maps, capsys, [
            "nearby", "--near", "Colosseum", "Rome", "--category", "restaurant",
            "--cuisine", "Italian", "--open-now", "--radius", "800"])

        assert out["provider"] == "osm"
        assert [p["name"] for p in out["results"]] == ["Trattoria Aperta"]
        place = out["results"][0]
        assert place["hours"] == "Mo-Su 12:00-23:00"
        assert place["opening_status"]["open_now"] is True
        assert place["opening_status"]["summary"] == "Open now, closes at 23:00"
        assert place["opening_status"]["timezone"] == ROME
        assert out["excluded_by_open_now"] == {"closed": 1, "unknown_hours": 1}
        assert "hours may be missing" in out["hours_caveat"]
        assert "GOOGLE_MAPS_API_KEY" in out["provider_note"]

        query = net.to("overpass-api.de")[0].data.decode("utf-8")
        assert "cuisine" in query and "italian" in query

    def test_without_open_now_every_place_is_returned_with_plain_hours_status(self, maps, monkeypatch, capsys):
        FakeNetwork(monkeypatch, maps, osm_routes())
        monkeypatch.delenv("GOOGLE_MAPS_API_KEY", raising=False)
        out = run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant"])
        by_name = {p["name"]: p["opening_status"] for p in out["results"]}
        assert by_name["Pizzeria Chiusa"]["summary"] == "Closed now, opens at 18:00"
        assert by_name["Osteria Senza Orari"]["open_now"] is None
        assert "no opening hours" in by_name["Osteria Senza Orari"]["summary"]

    def test_cuisine_cannot_inject_overpass_ql(self, maps, monkeypatch, capsys):
        FakeNetwork(monkeypatch, maps, osm_routes())
        monkeypatch.delenv("GOOGLE_MAPS_API_KEY", raising=False)
        with pytest.raises(SystemExit):
            run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant",
                               "--cuisine", 'x"];out;'])
        assert "cuisine" in json.loads(capsys.readouterr().out)["error"]

    def test_search_returns_hours_for_a_named_place(self, maps, monkeypatch, capsys):
        found = [{"lat": "41.8905", "lon": "12.4930", "display_name": "Trattoria Aperta, Roma",
                  "name": "Trattoria Aperta", "category": "amenity", "type": "restaurant",
                  "extratags": {"opening_hours": "Mo-Su 12:00-23:00"}}]
        routes = osm_routes()
        routes["nominatim.openstreetmap.org"] = lambda req: found
        FakeNetwork(monkeypatch, maps, routes)
        out = run(maps, capsys, ["search", "Trattoria", "Aperta"])
        assert out["results"][0]["opening_status"]["summary"] == "Open now, closes at 23:00"
        assert out["results"][0]["hours"] == "Mo-Su 12:00-23:00"

    def test_search_for_a_city_carries_no_hours(self, maps, monkeypatch, capsys):
        city = [{"lat": "41.9", "lon": "12.5", "display_name": "Roma", "category": "boundary"}]
        routes = osm_routes()
        routes["nominatim.openstreetmap.org"] = lambda req: city
        FakeNetwork(monkeypatch, maps, routes)
        out = run(maps, capsys, ["search", "Roma"])
        assert "opening_status" not in out["results"][0]


class TestGoogleRequestToResult:
    def google_routes(self, places, seen=None):
        def search(req):
            if seen is not None:
                seen.append(req)
            return {"places": places}
        routes = osm_routes()
        routes["places.googleapis.com"] = search
        return routes

    def test_italian_restaurants_open_now_uses_google_with_field_mask(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        net = FakeNetwork(monkeypatch, maps, self.google_routes([google_place()]))
        out = run(maps, capsys, [
            "nearby", "--near", "Colosseum", "Rome", "--category", "restaurant",
            "--cuisine", "italian", "--open-now", "--radius", "800"])

        assert out["provider"] == "google"
        assert "provider_note" not in out
        place = out["results"][0]
        assert place["name"] == "Trattoria Google"
        assert place["rating"] == 4.6 and place["rating_count"] == 812
        assert place["opening_status"]["open_now"] is True
        assert place["opening_status"]["summary"] == "Open now, closes at 22:00"
        assert place["opening_status"]["today"] == "Wednesday: 12:00 – 22:00"
        assert "Powered by Google" in out["attribution"]
        assert not net.to("overpass-api.de")

        request = net.to("places.googleapis.com")[0]
        headers = {k.lower(): v for k, v in request.header_items()}
        mask = headers["x-goog-fieldmask"]
        assert "places.regularOpeningHours" in mask and "places.rating" in mask
        assert "*" not in mask
        assert headers["x-goog-api-key"] == FAKE_KEY
        assert FAKE_KEY not in request.full_url
        body = json.loads(request.data)
        assert body["textQuery"] == "italian restaurant"
        assert body["includedType"] == "restaurant"
        assert body["openNow"] is True
        assert body["locationBias"]["circle"]["radius"] == 800.0

    def test_key_never_appears_in_output(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        FakeNetwork(monkeypatch, maps, self.google_routes([google_place()]))
        run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant"])
        assert FAKE_KEY not in capsys.readouterr().out

    def test_places_far_outside_the_radius_are_dropped(self, maps, monkeypatch, capsys):
        far = google_place(id="ChIJfar", location={"latitude": 41.95, "longitude": 12.6})
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        FakeNetwork(monkeypatch, maps, self.google_routes([far, google_place()]))
        out = run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant"])
        assert [p["place_id"] for p in out["results"]] == ["ChIJtrattoria"]

    def test_closed_and_hoursless_google_places(self, maps, monkeypatch, capsys):
        closed = google_place(id="ChIJclosed", currentOpeningHours={
            "openNow": False, "nextOpenTime": "2026-11-12T10:00:00Z"})
        permanent = google_place(id="ChIJgone", businessStatus="CLOSED_PERMANENTLY")
        nohours = google_place(id="ChIJnone", currentOpeningHours=None)
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        FakeNetwork(monkeypatch, maps, self.google_routes([closed, permanent, nohours]))
        out = run(maps, capsys, ["places", "restaurants", "--near", "Colosseum"])
        status = {p["place_id"]: p["opening_status"] for p in out["results"]}
        assert status["ChIJclosed"]["summary"] == "Closed now, opens tomorrow at 11:00"
        assert status["ChIJgone"]["summary"] == "Permanently closed"
        assert status["ChIJnone"]["open_now"] is None
        assert "no opening hours" in status["ChIJnone"]["summary"]

    def test_place_details_requests_only_the_masked_fields(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        routes = {"places.googleapis.com": lambda req: google_place()}
        net = FakeNetwork(monkeypatch, maps, routes)
        out = run(maps, capsys, ["place-details", "ChIJtrattoria"])
        assert out["place"]["rating"] == 4.6
        assert out["place"]["opening_status"]["state"] == "open"
        request = net.requests[0]
        assert request.full_url.endswith("/v1/places/ChIJtrattoria")
        mask = {k.lower(): v for k, v in request.header_items()}["x-goog-fieldmask"]
        assert mask.startswith("id,") and "regularOpeningHours" in mask and "*" not in mask

    def test_place_details_rejects_path_tricks(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        net = FakeNetwork(monkeypatch, maps, {})
        with pytest.raises(SystemExit):
            run(maps, capsys, ["place-details", "../other"])
        assert not net.requests


class TestMissingKeyAndFallback:
    def test_no_key_never_contacts_google_and_says_hours_may_be_missing(self, maps, monkeypatch, capsys):
        monkeypatch.delenv("GOOGLE_MAPS_API_KEY", raising=False)
        net = FakeNetwork(monkeypatch, maps, osm_routes())
        out = run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant",
                                 "--provider", "google"])
        assert out["provider"] == "osm"
        assert "GOOGLE_MAPS_API_KEY is not set" in out["provider_note"]
        assert "hours may be missing" in out["provider_note"]
        assert not net.to("places.googleapis.com")

    def test_blank_key_counts_as_missing(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", "   ")
        net = FakeNetwork(monkeypatch, maps, osm_routes())
        out = run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant"])
        assert out["provider"] == "osm"
        assert not net.to("places.googleapis.com")

    def test_provider_osm_wins_even_with_a_key(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        net = FakeNetwork(monkeypatch, maps, osm_routes())
        out = run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant",
                                 "--provider", "osm"])
        assert out["provider"] == "osm"
        assert not net.to("places.googleapis.com")

    def test_places_command_without_key_fails_with_osm_pointer(self, maps, monkeypatch, capsys):
        monkeypatch.delenv("GOOGLE_MAPS_API_KEY", raising=False)
        net = FakeNetwork(monkeypatch, maps, {})
        with pytest.raises(SystemExit) as excinfo:
            run(maps, capsys, ["places", "italian", "restaurants"])
        assert excinfo.value.code == 1
        out = json.loads(capsys.readouterr().out)
        assert out["status"] == "error" and "nearby" in out["fallback"]
        assert not net.requests

    def test_google_failure_falls_back_to_osm_without_leaking_the_key(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)

        def denied(req):
            body = io.BytesIO(json.dumps(
                {"error": {"message": f"API key {FAKE_KEY} is not authorized"}}).encode())
            return urllib.error.HTTPError(req.full_url, 403, "Forbidden", {}, body)

        routes = osm_routes()
        routes["places.googleapis.com"] = denied
        net = FakeNetwork(monkeypatch, maps, routes)
        out = run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant"])
        assert out["provider"] == "osm"
        assert "Google Places could not be used" in out["provider_note"]
        assert "403" in out["provider_note"]
        assert FAKE_KEY not in json.dumps(out)
        assert len(net.to("places.googleapis.com")) == 1

    def test_category_without_a_google_type_uses_osm(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        net = FakeNetwork(monkeypatch, maps, osm_routes(lambda: {"elements": []}))
        out = run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "bus_stop"])
        assert out["provider"] == "osm"
        assert "bus_stop" in out["provider_note"]
        assert not net.to("places.googleapis.com")

    def test_transient_google_errors_are_retried(self, maps, monkeypatch, capsys):
        monkeypatch.setenv("GOOGLE_MAPS_API_KEY", FAKE_KEY)
        calls = []

        def flaky(req):
            calls.append(1)
            if len(calls) == 1:
                return urllib.error.HTTPError(req.full_url, 503, "Unavailable", {}, io.BytesIO(b"{}"))
            return {"places": [google_place()]}

        routes = osm_routes()
        routes["places.googleapis.com"] = flaky
        FakeNetwork(monkeypatch, maps, routes)
        out = run(maps, capsys, ["nearby", "--near", "Colosseum", "--category", "restaurant"])
        assert out["provider"] == "google" and len(calls) == 2
