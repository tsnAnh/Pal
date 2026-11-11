---
name: deep-search
description: "Run capped multi-query web research with cited sources."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [Research, Web, Search, Deep Search, Citations]
    category: research
    related_skills: [grounded-citations, arxiv]
---

# Deep Search Skill

Fans one question out into several `web_search` queries, merges and de-duplicates the hits,
reads the best pages with `web_extract`, and returns numbered evidence plus a `Sources:` list.
Every limit is a hard cap, and a run cut short by a cap, a timeout or a provider error says so
instead of returning nothing. It adds no tool: it drives the web tools you already have.

## When to Use

- The user asks for research, a comparison, "everything about X", a literature or market scan,
  or a question one search cannot settle.
- Several angles, sources or pages must be read, not just one answer.

For a single fact or one known page, call `web_search` or `web_extract` directly.

## Prerequisites

A web backend (`hermes tools`; any of the supported providers). Without one `web_search` is not
offered: tell the user "deep search needs a web provider; none set" and stop. If a run returns that
message, repeat it to the user. Never fake results from memory.

## How to Run

1. Write 3-6 queries that cover different angles, wordings and source types (official docs, news,
   forums, papers). Use operators such as `site:` where the backend supports them.
2. Run the helper inside `execute_code`:

```python
import os, sys
sys.path.insert(0, os.path.expanduser("~/.hermes/skills/research/deep-search/scripts"))
from deep_search import Caps, deep_search
from hermes_tools import web_search, web_extract

result = deep_search(
    ["query one", "query two", "query three"],
    lambda q, n: web_search(q, n),
    lambda urls: web_extract(urls),
    Caps(),
)
print(result.render())
```

3. Answer from the printed evidence only. Cite each claim with its `[n]`, end with the `Sources:`
   list, and state any "Limits and failures" line that affects confidence.
4. For a large question, split it into sub-topics and call `delegate_task` with a `tasks` batch,
   one sub-topic per task, each running step 2. Merge the children's cited answers yourself.

## Quick Reference

| Cap | Default | `Caps` field |
|---|---|---|
| Queries run | 6 | `max_queries` |
| Results kept per query | 5 | `results_per_query` |
| Distinct sources kept | 12 | `max_sources` |
| Pages read | 8 | `max_pages` |
| Characters per page | 4000 | `page_chars` |
| Characters of page text in total | 24000 | `total_chars` |
| Wall-clock seconds | 90 | `deadline_s` |
| Parallel workers | 4 | `workers` |

Status: `complete` (no cap or error hit), `partial` (usable evidence plus a note on what was cut),
`failed` (no sources; the message says why).

## Procedure

- Raise a cap only when the user asks for deeper coverage, and never past what the answer needs.
- On `partial`, report what was read, what was not, and why. Offer one narrower follow-up run.
- Pages listed under "Found but not read" are snippet-only: cite them as such or read one with
  `web_extract`, and do not present them as read.
- Pages that need login, JavaScript or clicks fail in `web_extract`; use `browser_exec` for a
  specific one only when the user needs it.
- Respect each site's terms: the helper only calls the configured providers, and the
  private-network and website-policy gates stay in force.

## Pitfalls

- Over the sandbox transport tool calls run one at a time, so the worker pool speeds up only
  backends that answer concurrently. The 90 s cap still bounds the run.
- Search results are snippets. Never quote a claim that only a snippet supports as if the page said it.
- Duplicate URLs collapse to one source with every query that found it.
- A non-English or niche topic may need queries in the source language.

## Verification

- The output begins with `DEEP SEARCH COMPLETE`, `PARTIAL` or `FAILED` and is never empty.
- Every `[n]` in your answer exists in `Sources:`.
- Any cap or error line was passed on to the user.
