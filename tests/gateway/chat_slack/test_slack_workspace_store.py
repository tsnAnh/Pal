from __future__ import annotations

import threading

from agent.vault_store import VaultStore
from gateway.chat_slack.records import SlackRecords
from gateway.chat_slack.workspace_store import WorkspaceRecords
from tests.gateway.chat_slack.fake_slack import REFRESH

PROCESSES = 8


def test_concurrent_processes_adopt_a_profiles_workspace_credential_exactly_once(tmp_path):
    profile_vault = VaultStore(tmp_path / "bot" / "vault")
    item = profile_vault.add_item("api_key", "Slack configuration token", {"api_key": REFRESH}).id
    profile_path = tmp_path / "bot" / "chat_slack" / "records.json"
    SlackRecords(profile_path).update_workspace("w1", config_item_id=item, capabilities={"set_icon": "automatic"})
    root_vault = VaultStore(tmp_path / "root" / "vault")
    root_path = tmp_path / "root" / "chat_slack" / "workspaces.json"
    start = threading.Barrier(PROCESSES)
    seen: list[dict] = []
    failures: list[BaseException] = []

    def process():
        records = WorkspaceRecords(root_path, root_vault, lambda: [(SlackRecords(profile_path), profile_vault)])
        try:
            start.wait(10)
            seen.append(records.workspace("w1"))
        except BaseException as exc:
            failures.append(exc)

    threads = [threading.Thread(target=process) for _ in range(PROCESSES)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(30)
    assert not failures, failures
    assert len({entry["config_item_id"] for entry in seen}) == 1
    assert [i.label for i in root_vault.list_items()] == ["Slack configuration token"]
    assert root_vault.resolve_secret(seen[0]["config_item_id"])["api_key"] == REFRESH
    assert seen[0]["capabilities"] == {"set_icon": "automatic"}
    assert SlackRecords(profile_path).workspace("w1") == {} and profile_vault.list_items() == []
