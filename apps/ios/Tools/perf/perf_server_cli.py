import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import perf_server_profile


def main():
    repo, profile_dir, session_id, iterations = sys.argv[1:5]
    print(json.dumps(perf_server_profile.profile_session(Path(repo), Path(profile_dir), session_id, int(iterations))))


if __name__ == "__main__":
    main()
