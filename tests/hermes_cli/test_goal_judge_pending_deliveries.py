import tools.process_registry as module
from hermes_cli.goals import gather_background_processes
from tools.process_registry import ProcessRegistry, ProcessSession


def _runner(owner: str) -> ProcessSession:
    return ProcessSession(id="proc_runner", command="deliver", task_id=owner, owner_task_id=owner,
                          started_at=1_000_000.0, internal=True, max_lifetime_seconds=3420)


def test_judge_sees_a_pending_delivery_runner(monkeypatch):
    registry = ProcessRegistry()
    registry._running["proc_runner"] = _runner("goal-owner")
    monkeypatch.setattr(module, "process_registry", registry)

    seen = gather_background_processes(owner_task_id="goal-owner")

    assert [entry["session_id"] for entry in seen] == ["proc_runner"]
    assert registry.list_sessions() == []
