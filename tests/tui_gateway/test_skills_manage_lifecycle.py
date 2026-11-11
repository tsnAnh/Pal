"""skills.manage installed / check / update / uninstall: each answers its outcome, never a bare success."""

import tui_gateway.server as srv


def _call(params):
    return srv._methods["skills.manage"](1, params)


def test_installed_lists_hub_lock_rows(monkeypatch):
    import tools.skills_hub as hub

    class _Lock:
        def list_installed(self):
            return [{"name": "x", "identifier": "official/x", "source": "official", "trust_level": "builtin",
                     "install_path": "x", "content_hash": "secret-ish"}]

    monkeypatch.setattr(hub, "HubLockFile", _Lock)

    out = _call({"action": "installed"})

    assert out["result"]["installed_skills"] == [
        {"name": "x", "identifier": "official/x", "source": "official", "trust_level": "builtin", "install_path": "x"}]


def test_check_reports_status_per_skill(monkeypatch):
    import tools.skills_hub_install as inst

    monkeypatch.setattr(inst, "check_for_skill_updates", lambda name=None: [
        {"name": "x", "identifier": "official/x", "source": "official", "status": "update_available", "current_hash": "h"}])

    out = _call({"action": "check"})

    assert out["result"]["updates"] == [
        {"name": "x", "identifier": "official/x", "source": "official", "status": "update_available"}]


def test_update_failure_is_an_error_with_the_cli_tail(monkeypatch):
    import hermes_cli.skills_hub as cli_hub

    def fake_update(name=None, console=None, force=False):
        console.print("Not installed: the security scan found 1 high-risk pattern(s).")
        return False

    monkeypatch.setattr(cli_hub, "do_update", fake_update)

    out = _call({"action": "update", "query": "x"})

    assert out["error"]["code"] == 5032
    assert out["error"]["data"]["updated"] is False
    assert "security scan" in out["error"]["message"]


def test_update_success_with_nothing_to_do_is_ok(monkeypatch):
    import hermes_cli.skills_hub as cli_hub

    monkeypatch.setattr(cli_hub, "do_update", lambda name=None, console=None, force=False: None)

    assert _call({"action": "update"})["result"] == {"updated": True, "name": None}


def test_uninstall_refusal_is_an_error_and_requires_a_name(monkeypatch):
    import hermes_cli.skills_hub as cli_hub

    def fake_uninstall(name, console=None, skip_confirm=False, invalidate_cache=True):
        console.print("'x' is not a hub-installed skill.")
        return False

    monkeypatch.setattr(cli_hub, "do_uninstall", fake_uninstall)

    refused = _call({"action": "uninstall", "query": "x"})
    missing = _call({"action": "uninstall"})

    assert refused["error"]["code"] == 5033 and refused["error"]["data"]["removed"] is False
    assert missing["error"]["code"] == 4003


def test_uninstall_success(monkeypatch):
    import hermes_cli.skills_hub as cli_hub

    monkeypatch.setattr(cli_hub, "do_uninstall", lambda name, console=None, skip_confirm=False, invalidate_cache=True: True)

    assert _call({"action": "uninstall", "query": "x"})["result"] == {"removed": True, "name": "x"}


def _skill_with_key(tmp_path, monkeypatch, saved):
    import hermes_cli.config as cfg
    import tools.skills_tool as st

    md = tmp_path / "SKILL.md"
    md.write_text("---\nname: x\nrequired_environment_variables:\n  - name: X_API_KEY\n---\nbody\n")
    monkeypatch.setattr(st, "_scanned_skill_catalog", lambda **kw: [{"name": "x", "path": md}])
    monkeypatch.setattr(cfg, "save_env_value_secure", lambda k, v: saved.append((k, v)))


def test_set_key_saves_only_a_name_the_skill_declares(monkeypatch, tmp_path):
    saved = []
    _skill_with_key(tmp_path, monkeypatch, saved)

    ok = _call({"action": "set_key", "query": "x", "key_name": "X_API_KEY", "value": "abc123"})
    other = _call({"action": "set_key", "query": "x", "key_name": "OPENAI_API_KEY", "value": "abc123"})
    unknown = _call({"action": "set_key", "query": "nope", "key_name": "X_API_KEY", "value": "abc123"})

    assert ok["result"] == {"saved": True, "name": "x"}
    assert saved == [("X_API_KEY", "abc123")]
    assert other["error"]["code"] == 4101
    assert unknown["error"]["code"] == 4004
    assert "abc123" not in str(ok) + str(other) + str(unknown)
