import json
import subprocess

import perf_common

PACKAGE = perf_common.PERF_DIR / "PalPerf"
CONFIGURATIONS = ("release", "debug")


def build(configuration, log_path):
    with open(log_path, "ab") as log:
        subprocess.run(["swift", "build", "-c", configuration, "--package-path", str(PACKAGE)], check=True, stdout=log, stderr=log)


def run(fixtures, iterations, out_dir):
    results = {}
    for configuration in CONFIGURATIONS:
        build(configuration, out_dir / f"swift-build-{configuration}.log")
        binary = PACKAGE / ".build" / configuration / "palperf"
        for label, frame in fixtures.items():
            completed = subprocess.run([str(binary), label, str(frame), str(iterations)], check=True, capture_output=True, text=True)
            results[f"{configuration}:{label}"] = json.loads(completed.stdout)
    return results
