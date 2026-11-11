import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "skills" / "media" / "youtube-content" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import fetch_transcript
import youtube_api

FAKE_KEY = "fake-test-key"


class FakeYouTube:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, url):
        from urllib.parse import parse_qs, urlparse

        parsed = urlparse(url)
        endpoint = parsed.path.rsplit("/", 1)[-1]
        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        self.calls.append((endpoint, params))
        status, payload = self.routes[endpoint]
        return status, json.dumps(payload).encode()


@pytest.fixture
def keyed(monkeypatch):
    monkeypatch.setenv("YOUTUBE_API_KEY", FAKE_KEY)


def run_cli(capsys, *argv):
    code = youtube_api.main(list(argv))
    return code, json.loads(capsys.readouterr().out)


def test_search_request_to_result(keyed, capsys):
    fake = FakeYouTube({"search": (200, {"items": [
        {"id": {"videoId": "dQw4w9WgXcQ"}, "snippet": {
            "title": "Song", "channelTitle": "Chan", "channelId": "UC" + "a" * 22,
            "publishedAt": "2009-10-25T06:57:33Z", "description": "d" * 900}},
        {"id": {"channelId": "UCnotavideo"}, "snippet": {}},
    ]})})
    with patch.object(youtube_api, "_http_get", fake):
        code, out = run_cli(capsys, "search", "never gonna", "--max-results", "500")
    assert code == 0
    assert out["count"] == 1
    hit = out["results"][0]
    assert hit["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    assert hit["title"] == "Song"
    assert len(hit["description"]) <= youtube_api.DESCRIPTION_LIMIT + 3
    endpoint, params = fake.calls[0]
    assert endpoint == "search"
    assert params["maxResults"] == str(youtube_api.MAX_RESULTS)
    assert params["q"] == "never gonna" and params["type"] == "video"


@pytest.mark.parametrize("ref,expected", [
    ("@Handle", {"forHandle": "@Handle"}),
    ("https://www.youtube.com/@Handle/videos", {"forHandle": "@Handle"}),
    ("UC" + "a" * 22, {"id": "UC" + "a" * 22}),
    ("https://www.youtube.com/channel/UC" + "a" * 22, {"id": "UC" + "a" * 22}),
])
def test_channel_stats_request_to_result(keyed, capsys, ref, expected):
    fake = FakeYouTube({"channels": (200, {"items": [{
        "id": "UC" + "a" * 22,
        "snippet": {"title": "Chan", "customUrl": "@handle", "description": "about"},
        "statistics": {"subscriberCount": "1200", "viewCount": "987654", "videoCount": "42"},
    }]})})
    with patch.object(youtube_api, "_http_get", fake):
        code, out = run_cli(capsys, "channel", ref)
    assert code == 0
    assert (out["subscribers"], out["total_views"], out["video_count"]) == (1200, 987654, 42)
    _, params = fake.calls[0]
    assert {k: params[k] for k in expected} == expected


def test_channel_hidden_subscribers_and_not_found(keyed, capsys):
    hidden = FakeYouTube({"channels": (200, {"items": [{
        "id": "UC" + "a" * 22, "snippet": {},
        "statistics": {"hiddenSubscriberCount": True, "viewCount": "5", "videoCount": "1"}}]})})
    with patch.object(youtube_api, "_http_get", hidden):
        _, out = run_cli(capsys, "channel", "@somebody")
    assert out["subscribers"] is None and out["subscribers_hidden"] is True
    with patch.object(youtube_api, "_http_get", FakeYouTube({"channels": (200, {})})):
        code, out = run_cli(capsys, "channel", "@nobody")
    assert code == 1 and "No YouTube channel found" in out["error"]


def test_video_details_with_transcript(keyed, capsys):
    fake = FakeYouTube({"videos": (200, {"items": [{
        "snippet": {"title": "Talk", "channelTitle": "Chan", "channelId": "UC" + "a" * 22,
                    "publishedAt": "2020-01-01T00:00:00Z", "description": "desc", "tags": ["a", "b"]},
        "contentDetails": {"duration": "PT3M5S"},
        "statistics": {"viewCount": "10", "likeCount": "2", "commentCount": "1"},
    }]})})
    segments = [{"text": "hello", "start": 0.0, "duration": 1.0}, {"text": "world", "start": 1.0, "duration": 1.0}]
    with patch.object(youtube_api, "_http_get", fake), \
            patch.object(fetch_transcript, "fetch_transcript", return_value=segments):
        code, out = run_cli(capsys, "video", "https://youtu.be/dQw4w9WgXcQ", "--transcript")
    assert code == 0
    assert out["video_id"] == "dQw4w9WgXcQ" and out["title"] == "Talk"
    assert out["duration_iso8601"] == "PT3M5S" and out["views"] == 10
    assert out["transcript"] == "hello world" and out["transcript_truncated"] is False
    assert fake.calls[0][1]["id"] == "dQw4w9WgXcQ"


def test_transcript_is_bounded(monkeypatch):
    segments = [{"text": "x" * 100, "start": 0.0, "duration": 1.0}] * 5
    with patch.object(fetch_transcript, "fetch_transcript", return_value=segments):
        out = youtube_api.transcript_for("dQw4w9WgXcQ", char_limit=150)
    assert len(out["transcript"]) == 150 and out["transcript_truncated"] is True


def test_missing_key_says_so_and_makes_no_request(monkeypatch, capsys):
    monkeypatch.delenv("YOUTUBE_API_KEY", raising=False)
    fake = FakeYouTube({})
    with patch.object(youtube_api, "_http_get", fake):
        for argv in (("search", "q"), ("channel", "@someone"), ("video", "dQw4w9WgXcQ")):
            code, out = run_cli(capsys, *argv)
            assert code == 1
            assert out["error"] == "YouTube search needs YOUTUBE_API_KEY; not set"
    assert fake.calls == []


def test_transcripts_keep_working_without_key(monkeypatch, capsys):
    monkeypatch.delenv("YOUTUBE_API_KEY", raising=False)
    segments = [{"text": "still here", "start": 0.0, "duration": 1.0}]
    with patch.object(fetch_transcript, "fetch_transcript", return_value=segments):
        code, out = run_cli(capsys, "video", "dQw4w9WgXcQ", "--transcript")
    assert code == 0
    assert out["transcript"] == "still here"
    assert out["metadata_error"] == youtube_api.MISSING_KEY_MESSAGE


def test_quota_exceeded_message_and_no_key_leak(keyed, capsys):
    body = {"error": {"code": 403, "message": "quota", "errors": [{"reason": "quotaExceeded"}]}}
    with patch.object(youtube_api, "_http_get", FakeYouTube({"search": (403, body)})):
        code, out = run_cli(capsys, "search", "q")
    assert code == 1
    assert "quota exceeded" in out["error"] and "10,000" in out["error"]
    assert FAKE_KEY not in json.dumps(out)


def test_invalid_key_and_network_failure(keyed, capsys):
    body = {"error": {"code": 400, "message": "API key not valid.", "errors": [{"reason": "badRequest"}]}}
    with patch.object(youtube_api, "_http_get", FakeYouTube({"search": (400, body)})):
        code, out = run_cli(capsys, "search", "q")
    assert code == 1 and "rejected YOUTUBE_API_KEY" in out["error"]

    def boom(url):
        raise youtube_api.YouTubeApiError("Could not reach the YouTube API: URLError")

    with patch.object(youtube_api, "_http_get", boom):
        code, out = run_cli(capsys, "search", "q")
    assert code == 1 and "Could not reach" in out["error"] and FAKE_KEY not in out["error"]
