import argparse
import json
import re
import sys
import threading
import time
import uuid
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "stub-model"
NORMAL_CHUNKS = 40
NORMAL_DELAY = 0.02
SLOW_CHUNKS = 40
SLOW_DELAY = 0.25
HOLD_SECONDS = 12
CLARIFY_QUESTION = "Which flavor do you want?"
CLARIFY_CHOICES = ["vanilla", "chocolate"]
DM_PROMPT_PREFIX = "MESSAGE_AGENT "
DM_BODY_MARKER = " :: "
DM_STAMP_PREFIX = "Message from \U0001f916 "
DM_STAMP = re.compile(r"\AMessage from \U0001f916 .+? \(@[A-Za-z0-9_-]+\): ?(.*)\Z", re.DOTALL)
DM_REPLY_FIELD = re.compile(r'"reply":\s*("(?:[^"\\]|\\.)*")')
DM_DEFAULT_REPLY = "Đã nhận, em xử lý ngay."
DM_SENT_REPLY = "Đã nhắn."
dm_replies_path = None
IPHONE_TRIGGER = "IPHONE"
IPHONE_RESULT_LIMIT = 600
TOOL_FINAL_PREFIX = "stub-tool-final "
TOOL_COMMANDS = {
    "TOOLCALL": "sleep 6",
    "APPROVE": 'cd "$(mktemp -d)" && git reset --hard',
    "STEER": "echo hermes-stub-steer-probe",
}
TOOL_PREAMBLE_CHUNKS = {"STEER": 60}

log_lock = threading.Lock()

CODEX_USAGE_PATH = "/backend-api/wham/usage"
COPILOT_USAGE_PATH = "/copilot_internal/user"


def provider_usage(path, now=None):
    now = now or datetime.now(UTC)
    iso = lambda delta: (now + delta).strftime("%Y-%m-%dT%H:%M:%SZ")
    route = path.split("?", 1)[0]
    if route == CODEX_USAGE_PATH:
        return {"plan_type": "plus", "rate_limit": {
            "primary_window": {"used_percent": 18, "limit_window_seconds": 18000,
                               "reset_at": int((now + timedelta(hours=3, minutes=20)).timestamp())},
            "secondary_window": {"used_percent": 42, "limit_window_seconds": 604800,
                                 "reset_at": int((now + timedelta(days=6, hours=2)).timestamp())},
        }}
    if route == COPILOT_USAGE_PATH:
        return {"access_type_sku": "free_limited_copilot", "quota_reset_date_utc": iso(timedelta(days=9, hours=4)),
                "quota_snapshots": {"chat": {"percent_remaining": 40, "entitlement": 50, "remaining": 20},
                                    "completions": {"percent_remaining": 75, "entitlement": 2000, "remaining": 1500}}}
    return None


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


def tool_names(body):
    names = []
    for tool in body.get("tools") or []:
        function = tool.get("function") if isinstance(tool, dict) else None
        if isinstance(function, dict) and function.get("name"):
            names.append(function["name"])
    return names


def image_parts(body):
    found = []
    for message in body.get("messages") or []:
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for part in content:
            if not isinstance(part, dict) or part.get("type") not in ("image_url", "input_image"):
                continue
            url = part.get("image_url")
            url = url.get("url") if isinstance(url, dict) else url
            if isinstance(url, str):
                found.append({"mime": url.split(";")[0].removeprefix("data:"), "length": len(url)})
    return found


def dm_replies():
    if not dm_replies_path:
        return {}
    try:
        with open(dm_replies_path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def dm_plan(last_role, last, last_user, names):
    if last_role == "tool" and "delivery_id" in text_of(last.get("content")):
        return "final", DM_SENT_REPLY, NORMAL_DELAY
    if last_role != "user":
        return None
    if last_user.startswith(DM_PROMPT_PREFIX) and "message_agent" in names:
        target, _, message = last_user[len(DM_PROMPT_PREFIX):].partition(DM_BODY_MARKER)
        return "tool", {"name": "message_agent", "arguments": {"target": target.strip(), "message": message}}, 0
    stamped = DM_STAMP.match(last_user[last_user.rfind(DM_STAMP_PREFIX):].strip()) if DM_STAMP_PREFIX in last_user else None
    if stamped:
        return "final", dm_replies().get(stamped.group(1).strip(), DM_DEFAULT_REPLY), NORMAL_DELAY
    if last_user.lstrip().startswith("[IMPORTANT: Background process") and '"reply"' in last_user:
        found = DM_REPLY_FIELD.search(last_user)
        reply = json.loads(found.group(1)) if found else ""
        return "final", reply or DM_SENT_REPLY, NORMAL_DELAY
    return None


def last_tool_name(messages):
    for message in reversed(messages):
        calls = message.get("tool_calls") if message.get("role") == "assistant" else None
        if calls:
            return (calls[-1].get("function") or {}).get("name")
    return None


def iphone_arguments(user_text):
    after = (user_text.split(IPHONE_TRIGGER, 1)[1].strip().splitlines() or [""])[0].split()
    kind, rest = (after[0].upper() if after else ""), " ".join(after[1:])
    now = datetime.now(UTC)
    window = {
        "start": (now - timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "end": (now + timedelta(hours=36)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    actions = {
        "CALENDAR": {"action": "calendar.list_events", "args": window},
        "REMINDERS": {"action": "reminders.list", "args": {}},
        "CONTACTS": {"action": "contacts.search", "args": {"query": rest[:80] or "a"}},
        "LOCATION": {"action": "location.current", "args": {}},
    }
    return actions.get(kind)


def iphone_answer(tool_content):
    try:
        payload = json.loads(tool_content)
    except ValueError:
        return "iPhone answered with something unreadable"
    if payload.get("success"):
        return "iPhone data: " + json.dumps(payload.get("data"), ensure_ascii=False)[:IPHONE_RESULT_LIMIT]
    return "iPhone refused: " + str(payload.get("code") or "unknown")


def plan(body):
    messages = body.get("messages") or []
    names = tool_names(body)
    last = messages[-1] if messages else {}
    last_role = last.get("role")
    last_user = next((text_of(m.get("content")) for m in reversed(messages) if m.get("role") == "user"), "")
    scripted = dm_plan(last_role, last, last_user, names)
    if scripted:
        return scripted
    if "iphone" in names and last_role == "tool" and last_tool_name(messages) == "iphone":
        return "final", iphone_answer(text_of(last.get("content"))), NORMAL_DELAY
    if "iphone" in names and last_role == "user" and IPHONE_TRIGGER in last_user and (call := iphone_arguments(last_user)):
        return "iphone", call, 0
    tool_trigger = next((key for key in TOOL_COMMANDS if key in last_user), None)
    if "terminal" in names and tool_trigger and last_role == "tool":
        return "text", [TOOL_FINAL_PREFIX + text_of(last.get("content"))], NORMAL_DELAY
    if "terminal" in names and tool_trigger and last_role == "user":
        call = {"name": "terminal", "arguments": {"command": TOOL_COMMANDS[tool_trigger]}}
        if tool_trigger in TOOL_PREAMBLE_CHUNKS:
            preamble = words(tool_trigger.lower(), TOOL_PREAMBLE_CHUNKS[tool_trigger])
            return "tool", {**call, "preamble": preamble}, SLOW_DELAY
        return "tool", call, 0
    if "clarify" in names and last_role == "tool":
        return "final", "Clarify answered: " + text_of(last.get("content")), NORMAL_DELAY
    if "clarify" in names and last_role == "user" and "CLARIFY" in last_user:
        return "clarify", None, 0
    if names and last_role == "user" and "HOLD" in last_user:
        return "hold", words("hold", 6), NORMAL_DELAY
    if names and last_role == "user" and "SLOW" in last_user:
        return "text", words("slow", SLOW_CHUNKS), SLOW_DELAY
    return "text", words("stub", NORMAL_CHUNKS), NORMAL_DELAY


def words(prefix, count):
    return [f"{prefix}-{index:02d} " for index in range(count)]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    log_path = None

    def log_message(self, *_):
        pass

    def do_GET(self):
        usage = provider_usage(self.path)
        if usage is not None:
            authorized = bool(self.headers.get("Authorization"))
            self.reply_json(usage if authorized else {"error": "unauthorized"}, status=200 if authorized else 401)
        elif self.path.rstrip("/").endswith("/models"):
            self.reply_json({"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "stub"}]})
        else:
            self.reply_json({"ok": True})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        kind, content, delay = plan(body)
        self.record(body, kind)
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self.reply_json({"error": {"message": "unsupported"}}, status=404)
            return
        if body.get("stream"):
            self.stream(kind, content, delay)
        else:
            self.complete(kind, content)

    def record(self, body, kind):
        entry = {
            "ts": time.time(),
            "path": self.path,
            "stream": bool(body.get("stream")),
            "plan": kind,
            "tools": tool_names(body),
            "images": image_parts(body),
            "messages": [{"role": m.get("role"), "content": text_of(m.get("content"))} for m in body.get("messages") or []],
        }
        with log_lock, open(self.log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")

    def reply_json(self, payload, status=200):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def clarify_arguments(self):
        return json.dumps({"questions": [{"question": CLARIFY_QUESTION, "choices": CLARIFY_CHOICES}]})

    def scripted_call(self, call):
        return {"id": "call_stub_" + uuid.uuid4().hex[:8], "type": "function",
                "function": {"name": call["name"], "arguments": json.dumps(call["arguments"])}}
    def tool_call(self, kind, content):
        if kind == "iphone":
            return "call_stub_iphone", "iphone", json.dumps(content)
        return "call_stub_clarify", "clarify", self.clarify_arguments()

    def complete(self, kind, content):
        message = {"role": "assistant", "content": None}
        finish = "stop"
        if kind in ("clarify", "iphone"):
            call_id, name, arguments = self.tool_call(kind, content)
            message["tool_calls"] = [{"id": call_id, "type": "function", "function": {"name": name, "arguments": arguments}}]
            finish = "tool_calls"
        elif kind == "tool":
            message["content"] = "".join(content.get("preamble", [])) or None
            message["tool_calls"] = [self.scripted_call(content)]
            finish = "tool_calls"
        else:
            message["content"] = content if isinstance(content, str) else "".join(content)
        self.reply_json({
            "id": "chatcmpl-stub", "object": "chat.completion", "created": int(time.time()), "model": MODEL,
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20},
        })

    def stream(self, kind, content, delay):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            self.chunk({"role": "assistant", "content": ""}, None)
            if kind in ("clarify", "iphone"):
                call_id, name, arguments = self.tool_call(kind, content)
                half = len(arguments) // 2
                call = {"index": 0, "id": call_id, "type": "function",
                        "function": {"name": name, "arguments": arguments[:half]}}
                self.chunk({"tool_calls": [call]}, None)
                self.chunk({"tool_calls": [{"index": 0, "function": {"arguments": arguments[half:]}}]}, None)
                self.chunk({}, "tool_calls")
            elif kind == "tool":
                for piece in content.get("preamble", []):
                    self.chunk({"content": piece}, None)
                    time.sleep(delay)
                self.chunk({"tool_calls": [{"index": 0, **self.scripted_call(content)}]}, None)
                self.chunk({}, "tool_calls")
            else:
                if kind == "hold":
                    time.sleep(HOLD_SECONDS)
                pieces = [content] if isinstance(content, str) else content
                for piece in pieces:
                    self.chunk({"content": piece}, None)
                    time.sleep(delay)
                self.chunk({}, "stop")
            self.raw(b"data: [DONE]\n\n")
            self.raw_end()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def chunk(self, delta, finish):
        payload = {"id": "chatcmpl-stub", "object": "chat.completion.chunk", "created": int(time.time()),
                   "model": MODEL, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        self.raw(b"data: " + json.dumps(payload).encode() + b"\n\n")

    def raw(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def raw_end(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--log", required=True)
    parser.add_argument("--dm-replies", help="JSON file mapping a bot message body to the reply the receiving bot gives")
    args = parser.parse_args()
    Handler.log_path = args.log
    global dm_replies_path
    dm_replies_path = args.dm_replies
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"listening {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
