---
name: youtube-content
description: "YouTube search, channel stats, video details, transcripts."
version: 1.1.0
author: Teknium (teknium1), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
required_environment_variables:
  - name: YOUTUBE_API_KEY
    prompt: YouTube Data API v3 key
    help: "Create one at https://console.cloud.google.com/apis/credentials with YouTube Data API v3 enabled"
    required_for: "video search, channel statistics and video metadata; transcripts need no key"
    optional: true
metadata:
  hermes:
    tags: [YouTube, Video, Transcripts, Media]
    related_skills: []
---

# YouTube Content Tool

## When to use

Use when the user shares a YouTube URL or video link, asks to summarize a video, requests a transcript, wants to find YouTube videos on a topic, or asks for a channel's subscriber, view or video counts. Transforms transcripts into structured content (chapters, summaries, threads, blog posts).

Transcripts need no key. Search, channel statistics and video metadata use the official YouTube Data API v3 and need `YOUTUBE_API_KEY`.

## Setup

**Search, channel stats, video metadata** need only the `YOUTUBE_API_KEY` secret and the system Python (standard library only). The owner sets it once from their terminal:

```bash
hermes config set YOUTUBE_API_KEY <key>
```

If it is not set the helper prints `YouTube search needs YOUTUBE_API_KEY; not set`. Relay that to the user and do not guess results. Do not ask the user to paste the key into chat.

**Transcripts** (keyless) need the `youtube` extra. Use `terminal` with the Python from a PM-prepared Hermes source checkout. The
`youtube` extra declares the helper's dependency; do not install packages into
Hermes with raw pip or project-discovering `uv run`.

From that checkout, first follow the isolated development-home setup in
[Package Management](https://hermes-agent.nousresearch.com/docs/reference/package-management#developer-workflow),
then prepare the extra and reactivate before running the helper:

```bash
source ./activate
python -c "import pm; pm.sync_venv(['youtube'], explicit=True)"
source ./activate
python -c "import youtube_transcript_api; print(youtube_transcript_api.__file__)"
```

On Windows, use `. .\activate.ps1` instead of `source ./activate`. If the terminal
runs on a different host or in a sandbox, use an explicitly isolated helper
environment there, not the agent's production environment. Run every command
below with the interpreter whose import check succeeded.

## API Helper

`youtube_api.py` prints one JSON document. Results are bounded (`--max-results` 1-25, transcripts capped at 20,000 characters with `transcript_truncated`).

```bash
python SKILL_DIR/scripts/youtube_api.py search "query" --max-results 10
python SKILL_DIR/scripts/youtube_api.py channel @handle          # or UC... id, or channel URL
python SKILL_DIR/scripts/youtube_api.py video "URL_OR_ID" --transcript
```

Errors come back as `{"error": "..."}` with exit 1. A quota error means the key hit its daily 10,000 units (each search costs 100, other calls 1); tell the user, do not retry in a loop. Without the key, `video --transcript` still returns the transcript with `metadata_error` set.

## Transcript Helper

`SKILL_DIR` is the directory containing this SKILL.md file. The script accepts any standard YouTube URL format, short links (youtu.be), shorts, embeds, live links, or a raw 11-character video ID.

```bash
# JSON output with metadata
python SKILL_DIR/scripts/fetch_transcript.py "https://youtube.com/watch?v=VIDEO_ID"

# Plain text (good for piping into further processing)
python SKILL_DIR/scripts/fetch_transcript.py "URL" --text-only

# With timestamps
python SKILL_DIR/scripts/fetch_transcript.py "URL" --timestamps

# Specific language with fallback chain
python SKILL_DIR/scripts/fetch_transcript.py "URL" --language tr,en
```

## Output Formats

After fetching the transcript, format it based on what the user asks for:

- **Chapters**: Group by topic shifts, output timestamped chapter list
- **Summary**: Concise 5-10 sentence overview of the entire video
- **Chapter summaries**: Chapters with a short paragraph summary for each
- **Thread**: Twitter/X thread format — numbered posts, each under 280 chars
- **Blog post**: Full article with title, sections, and key takeaways
- **Quotes**: Notable quotes with timestamps

### Example — Chapters Output

```
00:00 Introduction — host opens with the problem statement
03:45 Background — prior work and why existing solutions fall short
12:20 Core method — walkthrough of the proposed approach
24:10 Results — benchmark comparisons and key takeaways
31:55 Q&A — audience questions on scalability and next steps
```

## Workflow

1. **Fetch** the transcript using `terminal` and the prepared Python with `--text-only --timestamps`.
2. **Validate**: confirm the output is non-empty and in the expected language. If empty, retry without `--language` to get any available transcript. If still empty, tell the user the video likely has transcripts disabled.
3. **Chunk if needed**: if the transcript exceeds ~50K characters, split into overlapping chunks (~40K with 2K overlap) and summarize each chunk before merging.
4. **Transform** into the requested output format. If the user did not specify a format, default to a summary.
5. **Verify**: re-read the transformed output to check for coherence, correct timestamps, and completeness before presenting.

## Error Handling

- **Transcript disabled**: tell the user; suggest they check if subtitles are available on the video page.
- **Private/unavailable video**: relay the error and ask the user to verify the URL.
- **No matching language**: retry without `--language` to fetch any available transcript, then note the actual language to the user.
- **Dependency missing**: repeat PM preparation and reactivation above, then verify the helper uses that Python. Do not repair the selected generation with pip.
