import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "stub-model"
NORMAL_CHUNKS = 40
NORMAL_DELAY = 0.02
SLOW_CHUNKS = 40
SLOW_DELAY = 0.25
CLARIFY_QUESTION = "Which flavor do you want?"
CLARIFY_CHOICES = ["vanilla", "chocolate"]

log_lock = threading.Lock()


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


def plan(body):
    messages = body.get("messages") or []
    names = tool_names(body)
    last = messages[-1] if messages else {}
    last_role = last.get("role")
    last_user = next((text_of(m.get("content")) for m in reversed(messages) if m.get("role") == "user"), "")
    if "clarify" in names and last_role == "tool":
        return "final", "Clarify answered: " + text_of(last.get("content")), NORMAL_DELAY
    if "clarify" in names and last_role == "user" and "CLARIFY" in last_user:
        return "clarify", None, 0
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
        if self.path.rstrip("/").endswith("/models"):
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

    def complete(self, kind, content):
        message = {"role": "assistant", "content": None}
        finish = "stop"
        if kind == "clarify":
            message["tool_calls"] = [{"id": "call_stub_clarify", "type": "function",
                                      "function": {"name": "clarify", "arguments": self.clarify_arguments()}}]
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
            if kind == "clarify":
                arguments = self.clarify_arguments()
                half = len(arguments) // 2
                call = {"index": 0, "id": "call_stub_clarify", "type": "function",
                        "function": {"name": "clarify", "arguments": arguments[:half]}}
                self.chunk({"tool_calls": [call]}, None)
                self.chunk({"tool_calls": [{"index": 0, "function": {"arguments": arguments[half:]}}]}, None)
                self.chunk({}, "tool_calls")
            else:
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
    args = parser.parse_args()
    Handler.log_path = args.log
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
