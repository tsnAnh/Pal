#!/usr/bin/env python3

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://www.googleapis.com/youtube/v3"
KEY_ENV = "YOUTUBE_API_KEY"
MISSING_KEY_MESSAGE = "YouTube search needs YOUTUBE_API_KEY; not set"
DEFAULT_RESULTS = 10
MAX_RESULTS = 25
DESCRIPTION_LIMIT = 500
TRANSCRIPT_CHAR_LIMIT = 20000
HTTP_TIMEOUT_SECONDS = 15

CHANNEL_ID_RE = re.compile(r"^UC[A-Za-z0-9_-]{22}$")
HANDLE_RE = re.compile(r"^@?([A-Za-z0-9._-]{3,30})$")
QUOTA_REASONS = {"quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded", "userRateLimitExceeded"}
INVALID_KEY_REASONS = {"keyInvalid", "API_KEY_INVALID", "ipRefererBlocked", "accessNotConfigured"}


class YouTubeApiError(Exception):
    pass


def _http_get(url: str) -> tuple[int, bytes]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise YouTubeApiError(f"Could not reach the YouTube API: {type(exc).__name__}") from None


def _api_key() -> str:
    key = os.environ.get(KEY_ENV, "").strip()
    if not key:
        raise YouTubeApiError(MISSING_KEY_MESSAGE)
    return key


def _error_reason(body: bytes) -> tuple[str, str]:
    try:
        error = json.loads(body).get("error", {})
        first = (error.get("errors") or [{}])[0]
        return str(first.get("reason", "")), str(error.get("message", ""))
    except (ValueError, AttributeError, IndexError):
        return "", ""


def _raise_for_status(status: int, body: bytes) -> None:
    if status == 200:
        return
    reason, message = _error_reason(body)
    if reason in QUOTA_REASONS:
        raise YouTubeApiError(
            "YouTube API quota exceeded for this key (default 10,000 units/day, search costs 100). "
            "Retry after the daily reset (midnight Pacific) or use a key with more quota."
        )
    if reason in INVALID_KEY_REASONS or (status == 400 and "API key" in message):
        raise YouTubeApiError(f"YouTube rejected {KEY_ENV}; check the key and that YouTube Data API v3 is enabled for it.")
    if status == 403:
        raise YouTubeApiError(f"YouTube denied the request ({reason or 'forbidden'}).")
    if status == 404:
        raise YouTubeApiError("YouTube could not find that resource.")
    raise YouTubeApiError(f"YouTube API error (HTTP {status}{', ' + reason if reason else ''}).")


def api_get(endpoint: str, params: dict) -> dict:
    query = urllib.parse.urlencode({**params, "key": _api_key()})
    status, body = _http_get(f"{API_BASE}/{endpoint}?{query}")
    _raise_for_status(status, body)
    try:
        return json.loads(body)
    except ValueError:
        raise YouTubeApiError("YouTube returned an unreadable response.") from None


def clamp_results(value: int) -> int:
    return max(1, min(int(value), MAX_RESULTS))


def _trim(text: str, limit: int = DESCRIPTION_LIMIT) -> str:
    return text if len(text) <= limit else text[:limit].rstrip() + "..."


def _count(value) -> int | None:
    return int(value) if isinstance(value, (str, int)) and str(value).isdigit() else None


def search_videos(query: str, max_results: int = DEFAULT_RESULTS) -> dict:
    query = query.strip()
    if not query:
        raise YouTubeApiError("Search query is empty.")
    limit = clamp_results(max_results)
    data = api_get("search", {"part": "snippet", "type": "video", "q": query, "maxResults": limit})
    results = []
    for item in data.get("items", [])[:limit]:
        video_id = (item.get("id") or {}).get("videoId")
        if not video_id:
            continue
        snippet = item.get("snippet", {})
        results.append({
            "video_id": video_id,
            "url": f"https://www.youtube.com/watch?v={video_id}",
            "title": snippet.get("title", ""),
            "channel_title": snippet.get("channelTitle", ""),
            "channel_id": snippet.get("channelId", ""),
            "published_at": snippet.get("publishedAt", ""),
            "description": _trim(snippet.get("description", "")),
        })
    return {"query": query, "count": len(results), "results": results}


def parse_channel_ref(ref: str) -> dict:
    ref = ref.strip()
    if ref.startswith(("http://", "https://")):
        parsed = urllib.parse.urlparse(ref)
        parts = [p for p in parsed.path.split("/") if p]
        if parts and parts[0].startswith("@"):
            ref = parts[0]
        elif len(parts) >= 2 and parts[0] == "channel":
            ref = parts[1]
        else:
            raise YouTubeApiError("Use a channel id (UC...), an @handle, or a youtube.com/@handle or /channel/ URL.")
    if CHANNEL_ID_RE.match(ref):
        return {"id": ref}
    match = HANDLE_RE.match(ref)
    if not match:
        raise YouTubeApiError("Use a channel id (UC...), an @handle, or a youtube.com/@handle or /channel/ URL.")
    return {"forHandle": "@" + match.group(1)}


def channel_stats(ref: str) -> dict:
    data = api_get("channels", {"part": "snippet,statistics", **parse_channel_ref(ref)})
    items = data.get("items") or []
    if not items:
        raise YouTubeApiError(f"No YouTube channel found for {ref.strip()!r}.")
    item = items[0]
    snippet = item.get("snippet", {})
    stats = item.get("statistics", {})
    return {
        "channel_id": item.get("id", ""),
        "title": snippet.get("title", ""),
        "handle": snippet.get("customUrl", ""),
        "description": _trim(snippet.get("description", "")),
        "published_at": snippet.get("publishedAt", ""),
        "subscribers": None if stats.get("hiddenSubscriberCount") else _count(stats.get("subscriberCount")),
        "subscribers_hidden": bool(stats.get("hiddenSubscriberCount")),
        "total_views": _count(stats.get("viewCount")),
        "video_count": _count(stats.get("videoCount")),
        "url": f"https://www.youtube.com/channel/{item.get('id', '')}",
    }


def video_details(url_or_id: str) -> dict:
    from fetch_transcript import extract_video_id

    video_id = extract_video_id(url_or_id)
    data = api_get("videos", {"part": "snippet,contentDetails,statistics", "id": video_id})
    items = data.get("items") or []
    if not items:
        raise YouTubeApiError(f"No YouTube video found for {url_or_id.strip()!r} (private, removed, or wrong id).")
    item = items[0]
    snippet = item.get("snippet", {})
    stats = item.get("statistics", {})
    return {
        "video_id": video_id,
        "url": f"https://www.youtube.com/watch?v={video_id}",
        "title": snippet.get("title", ""),
        "channel_title": snippet.get("channelTitle", ""),
        "channel_id": snippet.get("channelId", ""),
        "published_at": snippet.get("publishedAt", ""),
        "description": _trim(snippet.get("description", ""), 2000),
        "tags": (snippet.get("tags") or [])[:20],
        "duration_iso8601": (item.get("contentDetails") or {}).get("duration", ""),
        "views": _count(stats.get("viewCount")),
        "likes": _count(stats.get("likeCount")),
        "comments": _count(stats.get("commentCount")),
    }


def transcript_for(video_id: str, languages: list | None = None, char_limit: int = TRANSCRIPT_CHAR_LIMIT) -> dict:
    from fetch_transcript import fetch_transcript

    try:
        segments = fetch_transcript(video_id, languages)
    except SystemExit:
        return {"transcript_error": "Transcript dependency missing; follow the Setup section of youtube-content/SKILL.md."}
    except Exception as exc:  # health: allow BLE001 -- the transcript library and its HTTP stack raise varied types; this boundary reports them to the bot as data
        return {"transcript_error": str(exc) or type(exc).__name__}
    text = " ".join(seg["text"] for seg in segments)
    return {
        "transcript": text[:char_limit],
        "transcript_truncated": len(text) > char_limit,
        "transcript_chars": len(text),
    }


def video_content(url_or_id: str, include_transcript: bool, languages: list | None = None) -> dict:
    from fetch_transcript import extract_video_id

    video_id = extract_video_id(url_or_id)
    try:
        result = video_details(url_or_id)
    except YouTubeApiError as exc:
        if not include_transcript or str(exc) != MISSING_KEY_MESSAGE:
            raise
        result = {"video_id": video_id, "url": f"https://www.youtube.com/watch?v={video_id}",
                  "metadata_error": MISSING_KEY_MESSAGE}
    if include_transcript:
        result.update(transcript_for(video_id, languages))
    return result


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description="YouTube Data API v3 helper (JSON output)")
    sub = parser.add_subparsers(dest="command", required=True)
    search = sub.add_parser("search", help="Search videos")
    search.add_argument("query")
    search.add_argument("--max-results", "-n", type=int, default=DEFAULT_RESULTS,
                        help=f"1-{MAX_RESULTS} (default {DEFAULT_RESULTS})")
    channel = sub.add_parser("channel", help="Channel statistics")
    channel.add_argument("channel", help="Channel id (UC...), @handle, or channel URL")
    video = sub.add_parser("video", help="Video details, optionally with transcript")
    video.add_argument("video", help="YouTube URL or video id")
    video.add_argument("--transcript", "-t", action="store_true", help="Include the transcript")
    video.add_argument("--language", "-l", default=None, help="Comma-separated transcript languages")
    args = parser.parse_args(argv)

    try:
        if args.command == "search":
            result = search_videos(args.query, args.max_results)
        elif args.command == "channel":
            result = channel_stats(args.channel)
        else:
            languages = [x.strip() for x in args.language.split(",")] if args.language else None
            result = video_content(args.video, args.transcript, languages)
    except YouTubeApiError as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
