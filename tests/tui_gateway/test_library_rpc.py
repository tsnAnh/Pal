from __future__ import annotations

import base64
import io
import json
import sqlite3
import threading
from pathlib import Path

import pytest

from hermes_cli.profiles import create_profile, get_profile_dir
from hermes_state import SessionDB
from tui_gateway import server

BASE_TS = 1_700_000_000.0


@pytest.fixture
def bots(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    create_profile("alpha", no_alias=True, no_skills=True)
    create_profile("beta", no_alias=True, no_skills=True)
    launch_db = SessionDB(home / "state.db")
    monkeypatch.setattr(server, "_db", launch_db, raising=False)
    yield {"launch": home, "alpha": get_profile_dir("alpha"), "beta": get_profile_dir("beta"), "tmp": tmp_path}
    launch_db.close()


def _call(method: str, params: dict) -> dict:
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})


def _ok(method: str, params: dict) -> dict:
    response = _call(method, params)
    assert "error" not in response, response.get("error")
    return response["result"]


def _error(method: str, params: dict) -> int:
    response = _call(method, params)
    assert "error" in response, response
    return response["error"]["code"]


class Seed:

    def __init__(self, db_path: Path):
        self.db = SessionDB(db_path)
        self.clock = 0
        self.sessions: set[str] = set()

    def message(self, session: str, role: str, content, *, tool_calls=None, tool_name=None, ts=None):
        if session not in self.sessions:
            self.db.create_session(session, "cli")
            self.sessions.add(session)
        self.clock += 1
        return self.db.append_message(
            session, role, content, tool_calls=tool_calls, tool_name=tool_name,
            tool_call_id="call-1" if role == "tool" else None, timestamp=BASE_TS + self.clock if ts is None else ts)

    def close(self):
        self.db.close()


def _seed(home: Path) -> Seed:
    return Seed(home / "state.db")


def _png(path: Path, size=(1200, 800)) -> bytes:
    from PIL import Image
    path.parent.mkdir(parents=True, exist_ok=True)
    buffer = io.BytesIO()
    Image.new("RGB", size, (200, 30, 30)).save(buffer, format="PNG")
    path.write_bytes(buffer.getvalue())
    return buffer.getvalue()


def _titles(result: dict) -> list[str]:
    return [item["title"] for item in result["items"]]


def test_lists_links_media_and_files_newest_first_deduped(bots):
    alpha = bots["alpha"]
    image = alpha / "cache" / "images" / "cat.png"
    _png(image)
    seed = _seed(alpha)
    seed.message("s1", "user", "see https://payments.google.com/checkout?id=7 and https://example.com/a.")
    seed.message("s1", "user", f"look\n@image:{image}")
    seed.message("s1", "assistant", "Saved it. MEDIA:" + str(alpha / "cache" / "documents" / "report.pdf"))
    seed.message("s2", "assistant", "again https://example.com/a and [docs](https://docs.python.org/3/library/json.html)")
    seed.close()

    result = _ok("library.list", {"profile": "alpha"})
    by_title = {item["title"]: item for item in result["items"]}
    assert _titles(result) == [
        "docs.python.org/3/library/json.html", "example.com/a", "report.pdf", "cat.png",
        "payments.google.com/checkout?id=7"]
    assert by_title["payments.google.com/checkout?id=7"]["subtitle"] == "payments.google.com"
    assert by_title["payments.google.com/checkout?id=7"]["kind"] == "link"
    assert by_title["payments.google.com/checkout?id=7"]["url"] == "https://payments.google.com/checkout?id=7"
    assert by_title["example.com/a"]["session_id"] == "s2"
    assert by_title["cat.png"]["kind"] == "media" and by_title["cat.png"]["subtitle"] == "Image"
    assert by_title["cat.png"]["mime"] == "image/png" and by_title["cat.png"]["asset_ref"]
    assert by_title["cat.png"]["url"] is None and by_title["cat.png"]["size"] == image.stat().st_size
    assert by_title["report.pdf"]["kind"] == "file" and by_title["report.pdf"]["subtitle"] == "PDF"
    assert by_title["report.pdf"]["asset_ref"] is None
    assert result["next_before"] is None and result["index_complete"] is True
    stamps = [item["occurred_at"] for item in result["items"]]
    assert stamps == sorted(stamps, reverse=True) and len(set(stamps)) == len(stamps)


def test_tool_calls_and_results_feed_the_library(bots):
    alpha = bots["alpha"]
    shot = alpha / "cache" / "screenshots" / "page.png"
    _png(shot, (300, 200))
    speech = alpha / "cache" / "audio" / "hello.mp3"
    speech.parent.mkdir(parents=True)
    speech.write_bytes(b"ID3")
    seed = _seed(alpha)
    seed.message("s1", "assistant", "", tool_calls=[
        {"id": "c1", "type": "function", "function": {
            "name": "web_extract", "arguments": json.dumps({"urls": ["https://news.ycombinator.com/item?id=1"]})}},
        {"id": "c2", "type": "function", "function": {
            "name": "write_file", "arguments": json.dumps({"path": "/work/notes/plan.md", "content": "x"})}},
        {"id": "c3", "type": "function", "function": {
            "name": "browser_exec", "arguments": json.dumps({"code": "goto('https://en.wikipedia.org/wiki/SQLite')"})}},
        {"id": "c4", "type": "function", "function": {
            "name": "read_file", "arguments": json.dumps({"path": "/work/ignored.txt"})}}])
    seed.message("s1", "tool", json.dumps({"screenshot_path": str(shot), "stdout": "ok"}), tool_name="browser_exec")
    seed.message("s1", "tool", json.dumps({"success": True, "file_path": str(speech)}), tool_name="text_to_speech")
    seed.message("s1", "tool", json.dumps({"results": [{"url": "https://search-noise.example.org/x"}]}), tool_name="web_search")
    seed.close()

    items = {item["title"]: item for item in _ok("library.list", {"profile": "alpha"})["items"]}
    assert set(items) == {
        "news.ycombinator.com/item?id=1", "plan.md", "en.wikipedia.org/wiki/SQLite", "page.png", "hello.mp3"}
    assert items["plan.md"]["kind"] == "file" and items["plan.md"]["subtitle"] == "MD"
    assert items["hello.mp3"]["subtitle"] == "Audio" and items["hello.mp3"]["mime"] == "audio/mpeg"
    assert items["page.png"]["asset_ref"] and items["hello.mp3"]["asset_ref"]


@pytest.mark.parametrize("text", [
    "http://localhost:8080/admin", "http://127.0.0.1/x", "http://10.0.0.5/x", "http://192.168.1.2/x",
    "http://172.16.0.9/x", "http://169.254.169.254/latest/meta-data", "http://[::1]/x", "http://[::ffff:127.0.0.1]/x",
    "http://0x7f.0.0.1/x", "http://2130706433/x", "http://intranet/wiki", "http://printer.local/x",
    "http://service.internal/x", "https://user:secret@example.com/private", "file:///etc/passwd",
    "data:text/html;base64,PGgxPg==", "javascript:alert(1)", "ftp://example.com/file",
])
def test_unshareable_links_never_enter_the_library(bots, text):
    seed = _seed(bots["alpha"])
    seed.message("s1", "user", f"open {text} now")
    seed.message("s1", "assistant", f"<{text}>")
    seed.close()
    assert _ok("library.list", {"profile": "alpha"})["items"] == []


def test_fenced_code_is_skipped_inline_code_and_markdown_links_are_kept(bots):
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", (
        "Run this:\n```bash\ncurl https://sample.example.com/in-fence\n```\n"
        "Docs at `https://kept.example.com/inline` and [guide](https://guide.example.com/a_(b)).\n"
        "~~~\nhttps://tilde.example.com/in-fence\n~~~\nDone: https://done.example.com/end."))
    seed.close()
    assert sorted(_titles(_ok("library.list", {"profile": "alpha"}))) == [
        "done.example.com/end", "guide.example.com/a_(b)", "kept.example.com/inline"]


def test_same_url_in_different_spellings_is_one_item_at_its_latest_mention(bots):
    seed = _seed(bots["alpha"])
    seed.message("s1", "user", "https://Example.com/a/")
    seed.message("s1", "user", "https://example.com:443/a/#top")
    seed.message("s2", "assistant", "later https://example.com/a/")
    seed.close()
    items = _ok("library.list", {"profile": "alpha"})["items"]
    assert [(item["title"], item["session_id"]) for item in items] == [("example.com/a/", "s2")]


def test_kind_filter_and_before_cursor_paging(bots):
    alpha = bots["alpha"]
    image = alpha / "images" / "p.png"
    _png(image, (40, 40))
    seed = _seed(alpha)
    for index in range(5):
        seed.message("s1", "user", f"https://site{index}.example.com/")
    seed.message("s1", "user", f"@image:{image}")
    seed.message("s1", "assistant", "MEDIA:/work/out/data.csv")
    seed.close()

    assert [item["kind"] for item in _ok("library.list", {"profile": "alpha", "kind": "media"})["items"]] == ["media"]
    assert [item["kind"] for item in _ok("library.list", {"profile": "alpha", "kind": "files"})["items"]] == ["file"]
    links = _ok("library.list", {"profile": "alpha", "kind": "links"})
    assert len(links["items"]) == 5 and {item["kind"] for item in links["items"]} == {"link"}

    seen, cursor, pages = [], None, 0
    while True:
        page = _ok("library.list", {"profile": "alpha", "limit": 3, **({"before": cursor} if cursor else {})})
        seen += [item["id"] for item in page["items"]]
        pages += 1
        cursor = page["next_before"]
        if cursor is None:
            break
    everything = [item["id"] for item in _ok("library.list", {"profile": "alpha", "limit": 200})["items"]]
    assert pages == 3 and seen == everything and len(set(seen)) == 7


def test_items_sharing_one_timestamp_page_without_loss_or_repeat(bots):
    seed = _seed(bots["alpha"])
    for index in range(4):
        seed.message("s1", "user", f"https://tie{index}.example.com/", ts=BASE_TS)
    seed.close()
    ids, cursor = [], None
    while True:
        page = _ok("library.list", {"profile": "alpha", "limit": 1, **({"before": cursor} if cursor else {})})
        ids += [item["id"] for item in page["items"]]
        cursor = page["next_before"]
        if cursor is None:
            break
    assert len(ids) == 4 and len(set(ids)) == 4


def test_limit_is_clamped_and_bad_requests_are_refused(bots):
    seed = _seed(bots["alpha"])
    for index in range(3):
        seed.message("s1", "user", f"https://clamp{index}.example.com/")
    seed.close()
    assert len(_ok("library.list", {"profile": "alpha", "limit": 10_000})["items"]) == 3
    assert len(_ok("library.list", {"profile": "alpha", "limit": 0})["items"]) == 1
    assert _error("library.list", {"profile": "alpha", "before": "yesterday"}) == 4150
    assert _error("library.list", {"profile": "alpha", "kind": "everything"}) == 4153
    assert _error("library.list", {"profile": "alpha", "limit": "many"}) == 4153
    assert _error("library.list", {"profile": "ghost"}) == 4064
    assert _error("library.list", {"profile": "alpha", "surprise": 1}) == 4000


def test_a_profiles_items_never_reach_another_profile(bots):
    alpha_image = bots["alpha"] / "images" / "alpha.png"
    beta_image = bots["beta"] / "images" / "beta.png"
    _png(alpha_image, (20, 20))
    _png(beta_image, (20, 20))
    for name, url, image in (("alpha", "https://only-alpha.example.com/", alpha_image),
                             ("beta", "https://only-beta.example.com/", beta_image),
                             ("launch", "https://only-launch.example.com/", None)):
        seed = _seed(bots[name])
        seed.message("s1", "user", url + (f"\n@image:{image}" if image else ""))
        seed.close()

    alpha = _ok("library.list", {"profile": "alpha"})
    beta = _ok("library.list", {"profile": "beta"})
    launch = _ok("library.list", {})
    assert sorted(_titles(alpha)) == ["alpha.png", "only-alpha.example.com"]
    assert sorted(_titles(beta)) == ["beta.png", "only-beta.example.com"]
    assert _titles(launch) == ["only-launch.example.com"]

    alpha_ref = next(item["asset_ref"] for item in alpha["items"] if item["kind"] == "media")
    assert _ok("library.asset", {"profile": "alpha", "asset_ref": alpha_ref})["size"] > 0
    assert _error("library.asset", {"profile": "beta", "asset_ref": alpha_ref}) == 4151
    assert _error("library.asset", {"asset_ref": alpha_ref}) == 4151


def test_asset_serves_an_indexed_image_as_a_bounded_thumbnail_or_the_original(bots):
    from PIL import Image
    alpha = bots["alpha"]
    image = alpha / "cache" / "images" / "big.png"
    original = _png(image)
    seed = _seed(alpha)
    seed.message("s1", "user", f"@image:{image}")
    seed.close()
    ref = _ok("library.list", {"profile": "alpha"})["items"][0]["asset_ref"]

    thumb = _ok("library.asset", {"profile": "alpha", "asset_ref": ref})
    data = base64.b64decode(thumb["data_base64"])
    assert thumb["size"] == len(data) and thumb["mime"] == "image/jpeg"
    assert max(Image.open(io.BytesIO(data)).size) <= 512

    full = _ok("library.asset", {"profile": "alpha", "asset_ref": ref, "thumbnail": False})
    assert full["mime"] == "image/png" and base64.b64decode(full["data_base64"]) == original
    assert _error("library.asset", {"profile": "alpha", "asset_ref": ref, "thumbnail": False, "max_bytes": 100}) == 4152


def test_asset_refuses_forged_unindexed_and_unsafe_references(bots):
    alpha = bots["alpha"]
    outside = bots["tmp"] / "outside"
    outside.mkdir()
    secret = outside / "secret.png"
    _png(secret, (10, 10))
    (outside / "notes.txt").write_text("private")
    inside_link = alpha / "cache" / "images" / "escape.png"
    inside_link.parent.mkdir(parents=True)
    inside_link.symlink_to(secret)
    (alpha / ".env").write_text("OPENAI_API_KEY=sk-secret\n")
    seed = _seed(alpha)
    seed.message("s1", "user", f"@image:{secret}\n@file:{outside / 'notes.txt'}\n@image:{inside_link}\n@file:{alpha / '.env'}")
    seed.message("s1", "assistant", f"MEDIA:{alpha / '.env'} MEDIA:{alpha / 'state.db'} https://example.com/page")
    seed.close()

    items = _ok("library.list", {"profile": "alpha", "limit": 200})["items"]
    assert items and all(item["asset_ref"] is None for item in items)
    link = next(item for item in items if item["kind"] == "link")
    forged = ["../../etc/passwd", "../" * 4 + "etc/passwd", "/etc/passwd", str(secret), "0" * 32, "f" * 32,
              "g" * 32, "", " ", "A" * 32, link["id"], "0" * 31, "0" * 33]
    for ref in forged:
        assert _error("library.asset", {"profile": "alpha", "asset_ref": ref}) == 4151, ref
    for item in items:
        assert _error("library.asset", {"profile": "alpha", "asset_ref": item["id"]}) == 4151, item["title"]


def test_asset_refuses_a_file_that_left_its_media_directory_or_whose_conversation_was_deleted(bots):
    alpha = bots["alpha"]
    image = alpha / "images" / "gone.png"
    _png(image, (30, 30))
    seed = _seed(alpha)
    seed.message("s1", "user", f"@image:{image}")
    ref = _ok("library.list", {"profile": "alpha"})["items"][0]["asset_ref"]
    assert _ok("library.asset", {"profile": "alpha", "asset_ref": ref})["size"] > 0

    image.unlink()
    assert _error("library.asset", {"profile": "alpha", "asset_ref": ref}) == 4151
    assert _ok("library.list", {"profile": "alpha"})["items"][0]["asset_ref"] is None

    _png(image, (30, 30))
    assert seed.db.delete_session("s1")
    seed.close()
    assert _error("library.asset", {"profile": "alpha", "asset_ref": ref}) == 4151
    assert _ok("library.list", {"profile": "alpha"})["items"] == []


def test_a_deleted_conversation_leaves_the_library(bots):
    seed = _seed(bots["alpha"])
    seed.message("keep", "user", "https://kept.example.com/")
    seed.message("drop", "user", "https://dropped.example.com/")
    assert _titles(_ok("library.list", {"profile": "alpha"})) == ["dropped.example.com", "kept.example.com"]
    assert seed.db.delete_session("drop")
    seed.close()
    assert _titles(_ok("library.list", {"profile": "alpha"})) == ["kept.example.com"]


def test_first_call_backfills_an_existing_store_and_repeats_are_stable(bots):
    alpha = bots["alpha"]
    seed = _seed(alpha)
    for index in range(30):
        seed.message(f"s{index % 3}", "user", f"https://old{index}.example.com/path")
    seed.close()
    state_db = alpha / "state.db"
    tables_before = _tables(state_db)
    rows_before = _count(state_db, "messages")

    first = _ok("library.list", {"profile": "alpha", "limit": 200})
    second = _ok("library.list", {"profile": "alpha", "limit": 200})
    assert len(first["items"]) == 30 and first == second

    reopened = _seed(alpha)
    reopened.message("s0", "user", "https://new.example.com/", ts=BASE_TS + 1000)
    reopened.close()
    third = _ok("library.list", {"profile": "alpha", "limit": 200})
    assert third["items"][0]["title"] == "new.example.com" and len(third["items"]) == 31
    assert third["items"][1:] == first["items"]
    assert _tables(state_db) == tables_before and _count(state_db, "messages") == rows_before + 1


def test_a_replaced_store_rebuilds_the_index_instead_of_serving_the_old_one(bots):
    alpha = bots["alpha"]
    seed = _seed(alpha)
    seed.message("s1", "user", "https://before-restore.example.com/")
    seed.close()
    assert _titles(_ok("library.list", {"profile": "alpha"})) == ["before-restore.example.com"]

    for sidecar in alpha.glob("state.db*"):
        sidecar.unlink()
    restored = _seed(alpha)
    for index in range(3):
        restored.message("r1", "user", f"https://after-restore{index}.example.com/")
    restored.close()
    assert sorted(_titles(_ok("library.list", {"profile": "alpha"}))) == [
        f"after-restore{index}.example.com" for index in range(3)]


def test_a_profile_without_a_store_has_an_empty_library_and_creates_none(bots):
    assert _ok("library.list", {"profile": "beta"}) == {"items": [], "next_before": None, "index_complete": True}
    assert not (bots["beta"] / "state.db").exists()
    assert _error("library.asset", {"profile": "beta", "asset_ref": "a" * 32}) == 4151


def test_concurrent_lists_agree_and_do_not_duplicate(bots):
    seed = _seed(bots["alpha"])
    for index in range(40):
        seed.message("s1", "user", f"https://parallel{index}.example.com/")
    seed.close()
    results, failures = [], []

    def run():
        try:
            results.append(_ok("library.list", {"profile": "alpha", "limit": 200}))
        except BaseException as exc:
            failures.append(exc)

    threads = [threading.Thread(target=run) for _ in range(6)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert not failures
    assert all(result == results[0] and len(result["items"]) == 40 for result in results)


def _tables(db_path: Path) -> list[str]:
    with sqlite3.connect(db_path) as conn:
        return sorted(row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'"))


def _count(db_path: Path, table: str) -> int:
    with sqlite3.connect(db_path) as conn:
        return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
