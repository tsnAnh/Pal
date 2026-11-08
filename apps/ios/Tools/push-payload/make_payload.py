import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]


def main() -> None:
    sys.path.insert(0, str(ROOT))
    from gateway.push_notify import Kind, Notice, _payload

    profile, name, reply = sys.argv[1], sys.argv[2], sys.argv[3]
    session_id = sys.argv[4] if len(sys.argv) > 4 else "20261108_000000_push"
    notice = Notice(Kind.FINISHED, session_id, f"{profile}:{session_id}:turn:test", reply)
    print(json.dumps(_payload(notice, profile, name), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
