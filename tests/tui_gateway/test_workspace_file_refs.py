from __future__ import annotations

import base64
import json
import os
import re
import time
from pathlib import Path

import pytest

from hermes_cli.profiles import create_profile, get_profile_dir
from tui_gateway import server, workspace_files
from tui_gateway.library_assets import CHUNK_MAX_BYTES, DOWNLOAD_MAX_BYTES, AssetNotAllowed, AssetUnavailable

PRIVATE_KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n"


@pytest.fixture
def bots(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("HERMES_HOME", str(home))
    create_profile("alpha", no_alias=True, no_skills=True)
    create_profile("beta", no_alias=True, no_skills=True)
    alpha, beta = get_profile_dir("alpha"), get_profile_dir("beta")
    yield {"root": home, "alpha": alpha, "beta": beta, "tmp": tmp_path, "workspace": alpha / "workspace"}


def _write(path: Path, content: str | bytes = "# note\n") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode() if isinstance(content, str) else content)
    return path


def _project(home: Path, *texts: str, role: str = "assistant") -> list[dict]:
    history = [{"role": role, "content": text} for text in texts]
    return server._history_to_messages(history, profile_home=str(home))


def _refs(home: Path, text: str) -> list[dict]:
    return _project(home, text)[0].get("file_refs", [])


def _only_ref(home: Path, path: Path) -> str:
    [found] = _refs(home, f"saved to {path}")
    return found["ref"]


def _call(params: dict) -> dict:
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": "workspace.file", "params": params})


def _ok(**params) -> dict:
    response = _call(params)
    assert "error" not in response, response.get("error")
    return response["result"]


def _refused(**params) -> dict:
    response = _call(params)
    assert "error" in response, response
    return response["error"]


@pytest.mark.parametrize("mention", [
    "I saved it to {path} for you.",
    "I saved it to {path}.",
    "See `{path}`",
    "See [the note]({path})",
    "See [the note](<{path}>)",
    "See [the note](file://{path})",
    "Line {path}:12 has it",
    "**{path}**",
    "Ghi chú ở ({path}), xem nhé",
    "Ghi chú: “{path}”.",
    "MEDIA:{path}",
])
def test_a_mentioned_workspace_file_gets_one_ref_without_its_path(bots, mention):
    note = _write(bots["workspace"] / "notes" / "plan.md")
    text = mention.format(path=note)

    [message] = _project(bots["alpha"], text)

    [found] = message["file_refs"]
    assert set(found) == {"ref", "name", "mime", "size"}
    assert found["name"] == "plan.md" and found["size"] == note.stat().st_size
    assert found["mime"] in {"text/markdown", "text/plain"}
    assert re.fullmatch(r"[0-9a-f]{32}", found["ref"])
    assert str(bots["tmp"]) not in json.dumps(message["file_refs"])
    assert message["text"] == text


def test_a_path_with_spaces_is_found_in_inline_code_and_a_percent_encoded_link(bots):
    note = _write(bots["workspace"] / "My Notes" / "to do.md")
    encoded = str(note).replace(" ", "%20")
    for text in (f"`{note}`", f"[x]({encoded})", f"[x](<{note}>)"):
        assert [found["name"] for found in _refs(bots["alpha"], text)] == ["to do.md"], text


@pytest.mark.parametrize("mention", [
    "workspace/notes/plan.md",
    "./notes/plan.md",
    "../workspace/notes/plan.md",
    "~/.hermes/profiles/alpha/workspace/notes/plan.md",
    "$HOME{path}",
    "${{HOME}}{path}",
    "https://example.com{path}",
    "```\n{path}\n```",
    "~~~sh\ncat {path}\n~~~",
])
def test_relative_tilde_url_and_fenced_paths_stay_plain_text(bots, mention):
    note = _write(bots["workspace"] / "notes" / "plan.md")
    assert _refs(bots["alpha"], mention.format(path=note)) == []


def test_only_assistant_messages_are_annotated(bots):
    note = _write(bots["workspace"] / "plan.md")
    [message] = _project(bots["alpha"], f"read {note}", role="user")
    assert "file_refs" not in message


def test_a_path_outside_the_workspace_and_traversal_get_no_ref(bots):
    outside = _write(bots["tmp"] / "elsewhere" / "plan.md")
    _write(bots["workspace"] / "real.md")
    traversal = f"{bots['workspace']}/../../../elsewhere/plan.md"
    soul = _write(bots["alpha"] / "SOUL.md")
    sibling = _write(bots["alpha"] / "workspace-private" / "plan.md")
    text = f"{outside} {traversal} {bots['workspace']}/../SOUL.md {soul} {sibling} /etc/hosts"
    assert _refs(bots["alpha"], text) == []


@pytest.mark.parametrize("name", [
    ".env", ".env.local", "prod.env", ".envrc", ".ssh/id_rsa", "keys/id_ed25519", ".gnupg/secring.gpg",
    ".aws/credentials", "credentials.json", "credentials/db.txt", "google_token.json", "tokens/a.txt",
    "client_secret.json", "secrets.yaml", "Keychains/login.keychain-db", "auth.json", "server.pem",
    "server.KEY", "app.p12", ".git/config", ".git/objects/ab/cd", ".hidden/plan.md", ".netrc",
    "notes/.secretrc", "prod.env.bak", "auth.json.bak", "auth.json~", "server.key.bak", "credentials.json.bak",
    "secrets.yaml.bak", "credentials_prod.json", "tokens-prod.json", "tokens-prod/list.json", "netrc", "kubeconfig",
    "htpasswd", "api_keys.json", "id_rsa_backup", "service private key.txt",
])
def test_secret_and_hidden_files_inside_the_workspace_get_no_ref(bots, name):
    path = _write(bots["workspace"] / name)
    assert _refs(bots["alpha"], f"see `{path}`") == []


@pytest.mark.parametrize("padding", [0, 10_000])
def test_a_private_key_under_an_innocent_name_gets_no_ref(bots, padding):
    path = _write(bots["workspace"] / "deploy.txt", "x" * padding + "\n" + PRIVATE_KEY)
    assert _refs(bots["alpha"], f"see {path}") == []


@pytest.mark.parametrize("name", ["token-economics.md", "tokenizer.py", "passage.json", "report.2024.md"])
def test_ordinary_names_near_secret_words_are_offered(bots, name):
    path = _write(bots["workspace"] / name)
    assert [found["name"] for found in _refs(bots["alpha"], f"see {path}")] == [name]


def test_a_hidden_note_is_allowed(bots):
    path = _write(bots["workspace"] / ".scratch.md")
    assert [found["name"] for found in _refs(bots["alpha"], f"see {path}")] == [".scratch.md"]


@pytest.mark.parametrize("target", ["outside", "secret", "auth", "other_profile", "directory"])
def test_a_symlink_that_leaves_the_workspace_or_hits_a_secret_gets_no_ref(bots, target):
    targets = {
        "outside": _write(bots["tmp"] / "elsewhere" / "plan.md"),
        "secret": _write(bots["workspace"] / ".env", "A=1"),
        "auth": _write(bots["alpha"] / "auth.json", "{}"),
        "other_profile": _write(bots["beta"] / "workspace" / "plan.md"),
        "directory": bots["tmp"] / "elsewhere",
    }
    targets["directory"].mkdir(exist_ok=True)
    _write(targets["directory"] / "inner.md")
    link = bots["workspace"] / "link.md"
    link.symlink_to(targets[target])
    mention = f"{link}/inner.md" if target == "directory" else str(link)
    assert _refs(bots["alpha"], f"see {mention}") == []


def test_a_hermes_secret_linked_into_a_workspace_under_a_plain_name_gets_no_ref(bots, monkeypatch):
    from gateway.platforms import base
    monkeypatch.setattr(base, "_HERMES_ROOT", bots["root"])
    project = bots["tmp"] / "project"
    stored = _write(project / "settings" / "main.yaml", "model: {}\n")
    (bots["beta"] / "config.yaml").unlink(missing_ok=True)
    (bots["beta"] / "config.yaml").symlink_to(stored)
    note = _write(project / "plan.md")
    _write(bots["alpha"] / "config.yaml", f"terminal:\n  cwd: {project}\n")
    assert [found["name"] for found in _refs(bots["alpha"], f"{stored} {note}")] == ["plan.md"]


def test_a_hard_link_to_a_secret_gets_no_ref(bots):
    secret = _write(bots["alpha"] / "auth.json", "{}")
    link = bots["workspace"] / "innocent.json"
    os.link(secret, link)
    assert _refs(bots["alpha"], f"see {link}") == []


def test_another_profile_and_the_profile_stores_get_no_ref(bots):
    other = _write(bots["beta"] / "workspace" / "plan.md")
    config = _write(bots["alpha"] / "config.yaml", "{}")
    database = _write(bots["alpha"] / "state.db", b"SQLite format 3\x00")
    default_note = _write(bots["root"] / "workspace" / "plan.md")
    assert _refs(bots["alpha"], f"{other} {config} {database} {default_note}") == []
    assert _refs(bots["root"], f"{other} {_write(bots['alpha'] / 'workspace' / 'x.md')}") == []
    assert [found["name"] for found in _refs(bots["root"], f"{default_note}")] == ["plan.md"]


def test_a_directory_and_a_missing_file_get_no_ref(bots):
    folder = bots["workspace"] / "folder.md"
    folder.mkdir()
    assert _refs(bots["alpha"], f"{folder} {bots['workspace']} {bots['workspace']}/gone.md") == []


@pytest.mark.platforms("linux", "macos")
def test_a_fifo_gets_no_ref(bots):
    pipe = bots["workspace"] / "pipe.txt"
    os.mkfifo(pipe)
    assert _refs(bots["alpha"], f"see {pipe}") == []


def test_a_configured_terminal_cwd_is_a_second_root(bots):
    project = bots["tmp"] / "project"
    note = _write(project / "report.md")
    assert _refs(bots["alpha"], f"see {note}") == []

    _write(bots["alpha"] / "config.yaml", f"terminal:\n  cwd: {project}\n")

    assert [found["name"] for found in _refs(bots["alpha"], f"see {note}")] == ["report.md"]
    assert _refs(bots["beta"], f"see {note}") == []


@pytest.mark.parametrize("cwd", ["{tmp}", "/", "{alpha}", "{root}", "{beta}", "{beta}/workspace", "."])
def test_a_cwd_that_is_a_home_or_another_profile_opens_nothing_more(bots, cwd):
    _write(bots["alpha"] / "config.yaml", f"terminal:\n  cwd: '{cwd.format(**bots)}'\n")
    private = _write(bots["tmp"] / "private.md")
    soul = _write(bots["alpha"] / "SOUL.md")
    other = _write(bots["beta"] / "workspace" / "plan.md")
    mine = _write(bots["workspace"] / "mine.md")
    assert [found["name"] for found in _refs(bots["alpha"], f"{private} {soul} {other} {mine}")] == ["mine.md"]


def _mine_among_strangers(bots, cwd: str, spell) -> list[str]:
    _write(bots["alpha"] / "config.yaml", f"terminal:\n  cwd: '{cwd}'\n")
    strangers = [
        _write(bots["tmp"] / "private.md"), _write(bots["alpha"] / "SOUL.md"),
        _write(bots["beta"] / "workspace" / "plan.md"), _write(bots["tmp"] / ".config" / "gh" / "hosts.yml")]
    mine = _write(bots["workspace"] / "mine.md")
    mentions = [str(path) for path in strangers] + [spell(str(path)) for path in strangers]
    return [found["name"] for found in _refs(bots["alpha"], " ".join([*mentions, str(mine)]))]


@pytest.mark.platforms("macos")
@pytest.mark.parametrize("wide", ["{tmp}", "{alpha}", "{beta}/workspace", "{tmp}/.config"])
def test_another_spelling_of_a_closed_folder_opens_nothing_on_a_case_blind_disk(bots, wide):
    real = wide.format(**bots)
    shouted = str(bots["tmp"].parent / bots["tmp"].name.upper()) + real.removeprefix(str(bots["tmp"]))
    shouted = shouted.replace("/.hermes/profiles/", "/.HERMES/Profiles/")
    if not os.path.isdir(shouted):
        Path(real).mkdir(parents=True, exist_ok=True)
    spell = lambda path: path.replace(real, shouted)
    assert _mine_among_strangers(bots, shouted, spell) == ["mine.md"]


@pytest.mark.platforms("macos")
@pytest.mark.parametrize("wide", ["", "{tmp}", "{alpha}", "{beta}/workspace", "{tmp}/.config"])
def test_the_data_volume_spelling_of_a_closed_folder_opens_nothing(bots, wide):
    real = wide.format(**bots)
    if real:
        Path(real).mkdir(parents=True, exist_ok=True)
    aliased = f"/System/Volumes/Data{real}"
    assert os.path.isdir(aliased)
    assert _mine_among_strangers(bots, aliased, lambda path: f"/System/Volumes/Data{path}") == ["mine.md"]


def test_a_backend_set_only_in_the_launch_environment_keeps_the_host_cwd_closed(bots, monkeypatch):
    project = bots["tmp"] / "project"
    note = _write(project / "report.md")
    _write(bots["root"] / "config.yaml", f"terminal:\n  cwd: {project}\n")
    assert [found["name"] for found in _refs(bots["root"], f"see {note}")] == ["report.md"]
    monkeypatch.setenv("TERMINAL_ENV", "docker")
    assert _refs(bots["root"], f"see {note}") == []


def test_a_policy_that_cannot_be_built_never_breaks_the_history_read(bots):
    note = _write(bots["workspace"] / "plan.md")
    _write(bots["alpha"] / "config.yaml", "terminal:\n  docker_env:\n    WHEN: 2020-01-01\n")
    [message] = _project(bots["alpha"], f"see {note}")
    assert message["text"] == f"see {note}" and "file_refs" not in message


def test_a_read_that_failed_once_is_tried_again(bots):
    note = _write(bots["workspace"] / "plan.md")
    note.chmod(0)
    try:
        assert _refs(bots["alpha"], f"see {note}") == []
    finally:
        note.chmod(0o644)
    assert [found["name"] for found in _refs(bots["alpha"], f"see {note}")] == ["plan.md"]


@pytest.mark.platforms("linux")
def test_a_name_that_is_not_utf8_never_reaches_the_wire(bots):
    odd = os.fsencode(str(bots["workspace"])) + b"/bad-\xff.md"
    with open(odd, "wb") as handle:
        handle.write(b"# odd\n")
    link = bots["workspace"] / "plain.md"
    os.symlink(odd, link)
    assert _refs(bots["alpha"], f"see {link}") == []


def test_a_remote_backend_does_not_open_its_cwd_on_this_host(bots):
    project = bots["tmp"] / "project"
    note = _write(project / "report.md")
    _write(bots["alpha"] / "config.yaml", f"terminal:\n  backend: ssh\n  cwd: {project}\n")
    assert _refs(bots["alpha"], f"see {note}") == []


def test_an_unreadable_profile_policy_serves_nothing(bots):
    note = _write(bots["workspace"] / "plan.md")
    ref = _only_ref(bots["alpha"], note)
    _write(bots["alpha"] / "config.yaml", "terminal: [unclosed\n")
    assert _refs(bots["alpha"], f"see {note}") == []
    assert _refused(profile="alpha", ref=ref)["code"] in {4151, 4154}


def test_type_and_size_decide_whether_a_binary_or_huge_file_is_offered(bots):
    small = _write(bots["workspace"] / "small.bin", b"\0\1\2" * 100)
    large = _write(bots["workspace"] / "large.bin", b"\0" * (CHUNK_MAX_BYTES + 1))
    huge = _write(bots["workspace"] / "huge.txt", "text\n")
    os.truncate(huge, DOWNLOAD_MAX_BYTES + 1)
    pdf = _write(bots["workspace"] / "paper.pdf", b"%PDF-1.7\n" + b"\0" * (CHUNK_MAX_BYTES + 1))
    table = _write(bots["workspace"] / "data.csv", "a,b\n1,2\n")
    names = [found["name"] for found in _refs(bots["alpha"], f"{small} {large} {huge} {pdf} {table}")]
    assert names == ["small.bin", "paper.pdf", "data.csv"]


def test_a_huge_run_of_closing_brackets_is_scanned_quickly(bots):
    note = _write(bots["workspace"] / "plan.md")
    text = f"{note}{')' * 400_000} and {note}"
    started = time.monotonic()
    assert [found["name"] for found in _refs(bots["alpha"], text)] == ["plan.md"]
    assert time.monotonic() - started < 10


def test_refs_are_deduplicated_ordered_and_capped_per_message(bots):
    notes = [_write(bots["workspace"] / f"n{index:02}.md") for index in range(25)]
    text = " ".join(str(path) for path in [notes[0], notes[0], *notes])
    assert [found["name"] for found in _refs(bots["alpha"], text)] == [f"n{index:02}.md" for index in range(20)]


def test_a_long_history_stays_within_its_check_budget(bots):
    shared = _write(bots["workspace"] / "shared.md")
    repeated = _project(bots["alpha"], *[f"see {shared}"] * 2000)
    assert all(len(message["file_refs"]) == 1 for message in repeated)

    notes = [_write(bots["workspace"] / "many" / f"n{index}.md") for index in range(2000)]
    started = time.monotonic()
    messages = _project(bots["alpha"], *[f"see {path}" for path in notes])
    assert time.monotonic() - started < 30
    annotated = [index for index, message in enumerate(messages) if "file_refs" in message]
    assert annotated == list(range(2000 - workspace_files.PATH_CHECK_BUDGET, 2000))


def test_the_verb_returns_the_library_payload_shapes(bots):
    content = "# Plan\n" * 100
    note = _write(bots["workspace"] / "plan.md", content)
    ref = _only_ref(bots["alpha"], note)

    whole = _ok(profile="alpha", ref=ref)
    assert base64.b64decode(whole["data_base64"]).decode() == content
    assert whole["size"] == whole["total"] == len(content) and whole["kind"] == "document"
    assert whole["previewable"] is True

    chunk = _ok(profile="alpha", ref=ref, offset=2, length=5)
    assert base64.b64decode(chunk["data_base64"]).decode() == content[2:7]
    assert chunk["offset"] == 2 and chunk["length"] == 5 and chunk["total"] == len(content)

    preview = _ok(profile="alpha", ref=ref, preview=True)
    assert preview["data_base64"] == "" and preview["preview_reason"] == "unsupported_kind"


def test_the_verb_returns_image_bytes_unless_a_thumbnail_is_asked(bots):
    from PIL import Image
    picture = bots["workspace"] / "shot.png"
    Image.new("RGB", (1200, 800), (200, 30, 30)).save(picture)
    ref = _only_ref(bots["alpha"], picture)

    assert base64.b64decode(_ok(profile="alpha", ref=ref)["data_base64"]) == picture.read_bytes()
    thumb = _ok(profile="alpha", ref=ref, thumbnail=True)
    assert 0 < thumb["size"] < thumb["total"]
    preview = _ok(profile="alpha", ref=ref, preview=True)
    assert preview["mime"] in {"image/png", "image/jpeg"} and 0 < preview["size"] < preview["total"]


def test_a_current_ref_serves_the_current_file_and_a_new_projection_renames_it(bots):
    note = _write(bots["workspace"] / "plan.md", "one\n")
    first = _only_ref(bots["alpha"], note)
    _write(note, "two two\n")
    os.utime(note, ns=(1, 1))
    assert base64.b64decode(_ok(profile="alpha", ref=first)["data_base64"]) == b"two two\n"
    assert _only_ref(bots["alpha"], note) != first


def test_the_verb_caps_whole_reads_and_chunked_downloads(bots):
    big = _write(bots["workspace"] / "big.txt", "x" * 9_000_000)
    ref = _only_ref(bots["alpha"], big)
    over = _refused(profile="alpha", ref=ref)
    assert over["code"] == 4152 and over["data"] == {"size": 9_000_000, "limit": 8_000_000}
    assert _ok(profile="alpha", ref=ref, max_bytes=16_000_000)["size"] == 9_000_000
    assert _refused(profile="alpha", ref=ref, max_bytes=100)["code"] == 4152
    assert _ok(profile="alpha", ref=ref, offset=0)["length"] == CHUNK_MAX_BYTES

    os.truncate(big, 16_000_001)
    assert _refused(profile="alpha", ref=ref, max_bytes=10**9)["data"]["limit"] == 16_000_000
    os.truncate(big, DOWNLOAD_MAX_BYTES + 1)
    assert _refused(profile="alpha", ref=ref, offset=0)["code"] == 4152


def test_the_verb_refuses_unknown_gone_and_foreign_refs(bots):
    note = _write(bots["workspace"] / "plan.md")
    ref = _only_ref(bots["alpha"], note)

    assert _refused(profile="beta", ref=ref)["code"] == 4151
    assert _refused(ref=ref)["code"] == 4151
    assert _refused(profile="alpha", ref="0" * 32)["code"] == 4151
    assert _refused(profile="alpha", ref=str(note))["code"] == 4151
    assert _refused(profile="alpha", ref=ref, preview=True, offset=0)["code"] == 4153
    assert _refused(profile="alpha", ref=ref, offset=-1)["code"] == 4153
    note.unlink()
    assert _refused(profile="alpha", ref=ref)["code"] == 4151


@pytest.mark.parametrize("swap", ["outside", "secret", "missing_outside", "private_key", "large_binary"])
def test_a_file_swapped_after_annotation_is_refused_without_naming_a_path(bots, swap):
    note = _write(bots["workspace"] / "plan.md")
    ref = _only_ref(bots["alpha"], note)
    note.unlink()
    if swap == "private_key":
        _write(note, PRIVATE_KEY)
    elif swap == "large_binary":
        _write(note, b"\0" * (CHUNK_MAX_BYTES + 1))
    else:
        targets = {
            "outside": _write(bots["tmp"] / "elsewhere.md", "private"),
            "secret": _write(bots["workspace"] / ".env", "A=1"),
            "missing_outside": bots["tmp"] / "no-such-file",
        }
        note.symlink_to(targets[swap])
    for extra in ({}, {"offset": 0}, {"preview": True}):
        error = _refused(profile="alpha", ref=ref, **extra)
        assert error["code"] == 4154, (extra, error)
        assert str(bots["tmp"]) not in json.dumps(error) and "plan" not in json.dumps(error)


@pytest.mark.parametrize("swap", ["parent_symlink", "other_file"])
def test_a_swap_between_the_check_and_the_open_is_refused(bots, swap):
    note = _write(bots["workspace"] / "notes" / "plan.md", "mine")
    vetted = workspace_files.confine(workspace_files.workspace_roots(bots["alpha"]), str(note))
    if swap == "parent_symlink":
        elsewhere = _write(bots["tmp"] / "elsewhere" / "plan.md", "private").parent
        note.parent.rename(bots["workspace"] / "moved")
        note.parent.symlink_to(elsewhere)
    else:
        os.replace(_write(bots["workspace"] / "next.md", "next"), note)
    with pytest.raises((AssetUnavailable, AssetNotAllowed)):
        with workspace_files.open_vetted(vetted):
            pass
