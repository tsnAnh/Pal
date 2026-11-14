import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path

SWIFT_TIMEOUT_SECONDS = 1500
SWIFT_REAP_SECONDS = 30
T3_START_SECONDS = 40
T3_STOP_SECONDS = 15
CONTROL_POLL_SECONDS = 0.1
LOG_SECRET_SHAPES = (
    re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r'("?(?:access_token|refresh_token|credential|ticket|password|secret)"?\s*[:=]\s*"?)[A-Za-z0-9._~+/=-]{8,}'),
)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def now_iso():
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class T3:
    def __init__(self, binary, base):
        self.binary = binary
        self.base = Path(base)
        self.runtime_file = self.base / "userdata" / "server-runtime.json"
        self.done_file = self.base / "serve.done"
        self.log_file = self.base / "serve.log"
        self.port = None

    def runtime(self):
        try:
            return json.loads(self.runtime_file.read_text())
        except (OSError, ValueError):
            return None

    def pid(self):
        runtime = self.runtime()
        return runtime.get("pid") if runtime else None

    def start(self):
        self.done_file.unlink(missing_ok=True)
        self.runtime_file.unlink(missing_ok=True)
        self.port = free_port()
        command = f'"{self.binary}" serve --base-dir "{self.base}" --no-browser --port {self.port} >>"{self.log_file}" 2>&1; echo $? >"{self.done_file}"'
        subprocess.Popen(["bash", "-c", command], start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(T3_START_SECONDS * 2):
            if self.runtime() and self._answers():
                return self.runtime()
            if self.done_file.exists():
                raise RuntimeError(f"t3 exited early with {self.done_file.read_text().strip()}")
            time.sleep(0.5)
        raise RuntimeError("t3 never became ready")

    def _answers(self):
        import urllib.request
        origin = self.runtime()["origin"]
        try:
            with urllib.request.urlopen(f"{origin}/.well-known/oauth-authorization-server", timeout=2) as response:
                return response.status == 200
        except OSError:
            return False

    def stop(self):
        pid = self.pid()
        if pid is None or not pid_alive(pid):
            return
        os.kill(pid, signal.SIGTERM)
        for _ in range(T3_STOP_SECONDS * 2):
            if not pid_alive(pid):
                return
            time.sleep(0.5)
        os.kill(pid, signal.SIGKILL)
        for _ in range(10):
            if not pid_alive(pid):
                return
            time.sleep(0.5)
        raise RuntimeError(f"t3 pid {pid} would not stop")

    def cli(self, *args):
        result = subprocess.run([self.binary, *args, "--base-dir", str(self.base), "--json"], capture_output=True,
                                text=True, timeout=60, check=True, stdin=subprocess.DEVNULL)
        return json.loads(result.stdout)

    def pairing_code(self):
        return self.cli("auth", "pairing", "create")["credential"]

    def revoke_all_sessions(self):
        sessions = self.cli("auth", "session", "list")
        for session in sessions:
            subprocess.run([self.binary, "auth", "session", "revoke", session["sessionId"], "--base-dir", str(self.base)],
                           capture_output=True, text=True, timeout=60, check=True, stdin=subprocess.DEVNULL)
        return len(sessions)


class Control:
    def __init__(self, directory, t3, steps):
        self.directory = Path(directory)
        self.t3 = t3
        self.steps = steps
        self.handled = set()

    def serve_pending(self):
        for request in sorted(self.directory.glob("req-*.json")):
            if request.name in self.handled:
                continue
            self.handled.add(request.name)
            action = json.loads(request.read_text()).get("action")
            response = self.directory / request.name.replace("req-", "res-")
            try:
                detail = self.perform(action)
                payload = {"ok": True, "detail": detail}
            except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
                payload = {"ok": False, "detail": f"{type(error).__name__}: {error}"}
            self.steps.append({"source": "harness", "name": f"control.{action}", "pass": payload["ok"], "at": now_iso(),
                               "observed": {"detail": payload["detail"] if action != "t3.pairing" else "issued"}})
            staging = response.with_suffix(".tmp")
            staging.write_text(json.dumps(payload))
            staging.rename(response)

    def perform(self, action):
        if action == "t3.stop":
            self.t3.stop()
            return "stopped"
        if action == "t3.start":
            return f"port {self.t3.start()['port']}"
        if action == "t3.revoke":
            return f"revoked {self.t3.revoke_all_sessions()} session(s)"
        if action == "t3.pairing":
            return self.t3.pairing_code()
        raise ValueError(f"unknown action {action}")


def redact(text, secrets):
    for secret in secrets:
        if secret:
            text = text.replace(secret, "[redacted]")
    for shape in LOG_SECRET_SHAPES:
        text = shape.sub(lambda match: (match.group(1) if match.lastindex else "Bearer ") + "[redacted]", text)
    return text


def read_jsonl(path):
    if not path.exists():
        return []
    rows = []
    for line in path.read_text().splitlines():
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def stub_requests(path):
    return read_jsonl(Path(path))


def gateway_checks(env):
    home = Path(env["HERMES_IOS_E2E_HOME"])
    logs = [Path(env["HERMES_IOS_E2E_GATEWAY_LOG"]), *sorted(home.glob("profiles/*/logs/*.log")), *sorted((home / "logs").glob("*.log"))]
    relay_errors = []
    for log in logs:
        if not log.exists():
            continue
        lines = log.read_text(errors="replace").splitlines()
        for index, line in enumerate(lines):
            if "Traceback" in line:
                window = "\n".join(lines[index:index + 40])
                if "device_mcp" in window or "mcp_tool_device" in window:
                    relay_errors.append(f"{log.name}:{index + 1}")
    requests = stub_requests(env["HERMES_IOS_E2E_STUB_LOG"])
    wanted = {"mcp__t3code__t3_project_list", "mcp__t3code__t3_thread_list"}
    searched = {name for name in wanted for entry in requests
                if any(message.get("role") == "tool" and name in message.get("content", "") for message in entry.get("messages", []))}
    bridged = sum(1 for entry in requests if {"tool_search", "tool_call"} <= set(entry.get("tools", [])))
    tool_results = [entry for entry in requests if entry.get("messages") and entry["messages"][-1].get("role") == "tool"]
    return [
        {"source": "harness", "name": "gateway.logs-have-no-device-mcp-tracebacks", "pass": not relay_errors, "at": now_iso(),
         "observed": {"tracebacks": relay_errors}},
        {"source": "harness", "name": "llm.boundary-was-offered-the-t3-tools", "pass": searched == wanted and bridged > 0, "at": now_iso(),
         "observed": {"t3_tools_found_by_tool_search": sorted(searched), "requests_with_the_search_bridge": bridged,
                      "total_llm_requests": len(requests)}},
        {"source": "harness", "name": "llm.boundary-received-tool-results", "pass": len(tool_results) > 0, "at": now_iso(),
         "observed": {"requests_carrying_a_tool_result": len(tool_results)}},
    ]


def copy_evidence(env, artifacts, secrets):
    home = Path(env["HERMES_IOS_E2E_HOME"])
    logs = artifacts / "gateway-logs"
    logs.mkdir(exist_ok=True)
    sources = [Path(env["HERMES_IOS_E2E_GATEWAY_LOG"]), *sorted((home / "logs").glob("*.log")),
               *sorted(home.glob("profiles/*/logs/*.log"))]
    for source in sources:
        if source.exists():
            label = source.relative_to(home) if home in source.parents else Path(source.name)
            (logs / "__".join(label.parts)).write_text(redact(source.read_text(errors="replace"), secrets))
    summary = [{"at": entry.get("ts"), "tools": entry.get("tools", []),
                "last_message": (entry.get("messages") or [{}])[-1].get("content", "")[:600],
                "last_role": (entry.get("messages") or [{}])[-1].get("role")}
               for entry in stub_requests(env["HERMES_IOS_E2E_STUB_LOG"])]
    (artifacts / "llm-requests.json").write_text(redact(json.dumps(summary, indent=1), secrets))


def digest(steps):
    lines = [f"{step['name']}:{'pass' if step['pass'] else 'fail'}" for step in steps]
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--t3-bin", required=True)
    args = parser.parse_args()

    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="pal-t3-relay-e2e."))
    base = work / "t3"
    control_dir = work / "ctl"
    base.mkdir()
    control_dir.mkdir()
    steps_file = work / "steps-swift.jsonl"
    mac_log = work / "mac.log"
    harness_steps = []
    t3 = T3(args.t3_bin, base)
    swift = None
    secrets = [os.environ.get("HERMES_IOS_TEST_PASSWORD", "")]
    started = now_iso()
    swift_status = 1

    def terminate(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    try:
        runtime = t3.start()
        harness_steps.append({"source": "harness", "name": "t3.isolated-server-started", "pass": True, "at": now_iso(),
                              "observed": {"origin": runtime["origin"], "base_dir_is_temp": str(base).startswith(tempfile.gettempdir())}})
        code = t3.pairing_code()
        secrets.append(code)
        env = {**os.environ, "PAL_T3_E2E_BASE_DIR": str(base), "PAL_T3_E2E_PAIRING_CODE": code,
               "PAL_T3_RELAY_E2E_CTL": str(control_dir), "PAL_T3_RELAY_E2E_STEPS": str(steps_file),
               "PAL_T3_RELAY_E2E_MAC_LOG": str(mac_log)}
        log = (artifacts / "swift-test.log").open("w")
        swift = subprocess.Popen(["swift", "test", "--filter", "T3RelayE2ETests"], cwd=args.package, env=env,
                                 stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        control = Control(control_dir, t3, harness_steps)
        deadline = time.monotonic() + SWIFT_TIMEOUT_SECONDS
        while swift.poll() is None:
            control.serve_pending()
            if time.monotonic() > deadline:
                swift.kill()
                harness_steps.append({"source": "harness", "name": "swift.finished-in-time", "pass": False, "at": now_iso(),
                                      "observed": {"limit_seconds": SWIFT_TIMEOUT_SECONDS}})
                break
            time.sleep(CONTROL_POLL_SECONDS)
        swift.wait(timeout=SWIFT_REAP_SECONDS)
        swift_status = swift.returncode
        log.close()
    finally:
        if swift is not None and swift.poll() is None:
            swift.kill()
            swift.wait(timeout=SWIFT_REAP_SECONDS)
        try:
            t3.stop()
        except RuntimeError as error:
            harness_steps.append({"source": "harness", "name": "t3.stopped-at-end", "pass": False, "at": now_iso(),
                                  "observed": {"error": str(error)}})
        else:
            pid = t3.pid()
            harness_steps.append({"source": "harness", "name": "t3.stopped-at-end", "pass": pid is None or not pid_alive(pid),
                                  "at": now_iso(), "observed": {}})

    swift_steps = read_jsonl(steps_file)
    gateway_steps = gateway_checks(os.environ)
    steps = sorted([*swift_steps, *harness_steps, *gateway_steps], key=lambda step: step["at"])
    steps.append({"source": "harness", "name": "swift.test-exit", "pass": swift_status == 0, "at": now_iso(),
                  "observed": {"exit_code": swift_status}})
    for position, step in enumerate(steps, 1):
        step["seq"] = position
    failed = [step["name"] for step in steps if not step["pass"]]
    transcript = {"started": started, "finished": now_iso(), "steps": steps,
                  "passed": len(steps) - len(failed), "failed": failed, "digest": digest(steps)}
    (artifacts / "transcript.json").write_text(json.dumps(transcript, indent=2, sort_keys=True))
    copy_evidence(os.environ, artifacts, secrets)
    if mac_log.exists():
        (artifacts / "mac.log").write_text(redact(mac_log.read_text(errors="replace"), secrets))
    (artifacts / "swift-test.log").write_text(redact((artifacts / "swift-test.log").read_text(errors="replace"), secrets))
    shutil.rmtree(work, ignore_errors=True)
    print(f"steps: {len(steps)} passed: {transcript['passed']} failed: {failed or 'none'}")
    print(f"artifacts: {artifacts}")
    print(f"DIGEST sha256:{transcript['digest']}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
