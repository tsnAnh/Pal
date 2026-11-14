import json
import sys
from collections import Counter

manifest = json.load(open(sys.argv[1]))["rows"]
print(len(manifest), dict(Counter(row["expect"] for row in manifest)))
low, high = int(sys.argv[2]), int(sys.argv[3])
for row in manifest:
    if row["expect"] == "visible" and row["role"] == "assistant" and row["kind"] == "text" and low < row["index"] < high:
        print(row["index"], repr(row["head"][:60]))
