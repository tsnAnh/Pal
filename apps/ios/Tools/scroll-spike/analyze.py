import json
import sys
from pathlib import Path



def residual(ev):
    tr = ev["trace"]
    k = ev["mutateAt"]
    ys = [y for _, y, _ in tr]
    if ys[k - 1] < -9000:
        return None, None, None
    v = ys[k - 1] - ys[k - 2]
    jumps = []
    for i in range(k, min(k + 6, len(ys))):
        if ys[i] < -9000:
            return float("inf"), float("inf"), v
        jumps.append(ys[i] - ys[i - 1] - v)
    first = max(jumps, key=abs)
    post = [ys[i] - ys[i - 1] for i in range(k + 6, min(k + 12, len(ys))) if ys[i] > -9000 and ys[i - 1] > -9000]
    post_v = sum(post) / len(post) if post else 0
    return first, post_v, v


def main(paths):
    print(f"{'file':34} {'loads':>5} {'inflight':>8} {'maxjump':>8} {'p50':>6} {'skipped':>7} {'momentum':>9}")
    for p in paths:
        lines = [json.loads(line) for line in Path(p).read_text().splitlines() if line.strip()]
        apps = [e for e in lines if e["event"] == "append"]
        if apps:
            drift = [max(abs(t[1] - a["before"]) if t[1] > -9000 else float("inf") for t in a["trace"]) for a in apps]
            print(f"{Path(p).name:34} appends {len(apps)} max_drift {max(drift):.1f} p50 {sorted(drift)[len(drift) // 2]:.1f}")
        evs = [e for e in lines if e["event"] == "prepend"]
        done = next((e for e in lines if e["event"] == "done"), None)
        jumps, keep = [], []
        inflight = 0
        for e in evs:
            j, post_v, v = residual(e)
            if j is None:
                continue
            if e["phase"] != "idle":
                inflight += 1
                if abs(v) > 4 and post_v is not None:
                    keep.append(post_v / v)
            jumps.append(abs(j))
        jumps.sort()
        mx = max(jumps) if jumps else 0
        p50 = jumps[len(jumps) // 2] if jumps else 0
        if done:
            seen = set(done["materialized"])
            skipped = sum(1 for i in range(min(seen), max(seen)) if i not in seen)
        else:
            skipped = "n/a"
        mom = f"{sum(keep) / len(keep):.2f}" if keep else "n/a"
        print(f"{Path(p).name:34} {len(evs):5} {inflight:8} {mx:8.1f} {p50:6.1f} {skipped!s:>7} {mom:>9}")


if __name__ == "__main__":
    main(sys.argv[1:])
