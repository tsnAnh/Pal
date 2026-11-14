import asyncio
import re
import time
from pathlib import Path

import perf_common
from perf_common import BOT_CHAT_TITLE, PROFILE_SIZES

REAP_SETTLE_SECONDS = 25
NO_DEFLATE_REPEATS = 8
OPEN_RPCS = ("runtime.describe", "session.list", "session.resume", "bot.thread.links")
IMAGE_URI = re.compile(r"data:image/[a-z]+;base64,[A-Za-z0-9+/=]+")


def image_bytes_in(text):
    return sum(len(match) for match in IMAGE_URI.findall(text))


async def timed_connect(client, gateway, compression="deflate"):
    started = time.perf_counter()
    url, protocols = gateway.socket_url_and_protocols()
    minted = time.perf_counter()
    socket = await client.websockets.connect(url, subprotocols=protocols, max_size=None, compression=compression)
    rpc = perf_common.TimedRpc(socket)
    await asyncio.wait_for(socket.recv(), 30)
    ready = time.perf_counter()
    return socket, rpc, {"login_and_ticket_ms": (minted - started) * 1000, "dial_ms": (ready - minted) * 1000}


async def open_chat_rpcs(rpc, profile, label, resumes):
    rows = {}
    rows["runtime.describe"] = await rpc.call("runtime.describe", {})
    listed = await rpc.call("session.list", {"profile": profile, "title": BOT_CHAT_TITLE, "include_hidden": True})
    row = listed["result"]["sessions"][0]
    stored = row.get("resolved_id") or row["session_id"]
    rows["session.list"] = listed
    resumed = []
    for _ in range(resumes):
        resumed.append(await rpc.call("session.resume", {"profile": profile, "session_id": stored}))
    rows["session.resume"] = resumed[0]
    rows["session.resume.repeat"] = resumed[1:]
    runtime_id = resumed[0]["result"]["session_id"]
    rows["bot.thread.links"] = await rpc.call("bot.thread.links", {"profile": profile, "session_id": runtime_id, "limit": 200})
    return rows


def record_open(store, profile, rows):
    for name in OPEN_RPCS:
        sample = rows[name]
        store.setdefault((profile, name, "cold"), []).append(sample)
    for sample in rows["session.resume.repeat"]:
        store.setdefault((profile, "session.resume", "warm"), []).append(sample)


async def measure_without_compression(client, gateway, store, repeats):
    socket, rpc, _ = await timed_connect(client, gateway, compression=None)
    try:
        stored = {}
        for profile in PROFILE_SIZES:
            listed = await rpc.call("session.list", {"profile": profile, "title": BOT_CHAT_TITLE, "include_hidden": True})
            row = listed["result"]["sessions"][0]
            stored[profile] = row.get("resolved_id") or row["session_id"]
            await rpc.call("session.resume", {"profile": profile, "session_id": stored[profile]})
        for repeat in range(repeats):
            order = list(PROFILE_SIZES) if repeat % 2 == 0 else list(PROFILE_SIZES)[::-1]
            for profile in order:
                sample = await rpc.call("session.resume", {"profile": profile, "session_id": stored[profile]})
                store.setdefault((profile, "session.resume", "warm_no_deflate"), []).append(sample)
    finally:
        await socket.close()


async def measure(runs, resumes_per_open, fixture_dir):
    client = perf_common.load_gateway_client()
    target = perf_common.target_from_environment()
    gateway = client.Gateway(target["base_url"], target["username"], target["password"])
    store = {}
    connects = []
    profiles = list(PROFILE_SIZES)
    for run in range(runs):
        await asyncio.sleep(REAP_SETTLE_SECONDS)
        socket, rpc, connect = await timed_connect(client, gateway)
        connects.append(connect)
        try:
            order = profiles if run % 2 == 0 else profiles[::-1]
            for profile in order:
                rows = await open_chat_rpcs(rpc, profile, "cold", resumes_per_open)
                record_open(store, profile, rows)
                if run == 0:
                    (fixture_dir / f"resume-{profile}-{PROFILE_SIZES[profile]}.frame.json").write_text(rows["session.resume"]["text"])
        finally:
            await socket.close()
    await measure_without_compression(client, gateway, store, NO_DEFLATE_REPEATS)
    return store, connects


def summarize_store(store):
    result = {}
    for (profile, method, state), samples in sorted(store.items()):
        wall = perf_common.summarize([sample["wall_ms"] for sample in samples])
        size = perf_common.summarize([sample["bytes"] for sample in samples])
        entry = {"profile": profile, "rows": PROFILE_SIZES[profile], "method": method, "state": state, "wall_ms": wall, "bytes": size}
        entry["deflated_bytes"] = perf_common.summarize([sample["deflated_bytes"] for sample in samples])
        if method == "session.resume":
            payload = samples[0]["result"]
            entry["messages"] = len(payload.get("messages", []))
            entry["inline_image_bytes"] = image_bytes_in(samples[0]["text"])
        result[f"{profile}:{method}:{state}"] = entry
    return result


def run(runs, resumes_per_open, fixture_dir):
    fixture_dir.mkdir(parents=True, exist_ok=True)
    store, connects = asyncio.run(measure(runs, resumes_per_open, fixture_dir))
    return {
        "runs": runs,
        "reap_settle_seconds": REAP_SETTLE_SECONDS,
        "rpcs": summarize_store(store),
        "connect_login_and_ticket_ms": perf_common.summarize([c["login_and_ticket_ms"] for c in connects]),
        "connect_dial_ms": perf_common.summarize([c["dial_ms"] for c in connects]),
    }
