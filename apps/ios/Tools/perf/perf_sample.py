import re
import signal
import subprocess
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import perf_tour

SAMPLES_DIR = "samples"
WINDOW_SECONDS = 2
INTERVAL_MS = 1
IDLE_SYMBOLS = frozenset({"mach_msg2_trap", "__semwait_signal", "__psynch_cvwait", "kevent_id", "__workq_kernreturn"})
APP_MODULES = re.compile(r"^(Pal|Pal\.debug\.dylib|Pal[A-Z]\w*)$")
NODE = re.compile(r"^(?P<lead>[\s+!:|]*)(?P<count>\d+)\s+(?P<symbol>.+?)(?:\s+\(in (?P<module>[^)]+)\))?(?:\s+\+\s+\d+)?(?:\s+\[[^\]]*\])?(?:\s+\S+:\d+)?\s*$")
THREAD = re.compile(r"^\s*\d+\s+Thread_\d+")
ACCESSIBILITY = re.compile(r"XCTAutomation|XCTAccessibility|XCTElement|AXSerializ|_AXXMIG|AXRemote|NSAccessibility|accessibilityAttributeValue|AXElement|_AXUIElement")


class SampleError(ValueError):
    pass


class Sampler:
    def __init__(self, run_dir):
        self.directory = Path(run_dir) / SAMPLES_DIR
        self.directory.mkdir(parents=True, exist_ok=True)
        self.process = None

    def step(self, pid):
        if pid is None or (self.process is not None and self.process.poll() is None):
            return
        target = self.directory / f"{time.time():.3f}-{pid}.txt"
        self.process = subprocess.Popen(
            ["sample", str(pid), str(WINDOW_SECONDS), str(INTERVAL_MS), "-mayDie", "-file", str(target)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            try:
                self.process.wait(timeout=WINDOW_SECONDS * 5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


class InstrumentsTrace:
    LIMIT_SECONDS = 1800
    SETTLE_SECONDS = 300
    STABLE_STEPS = 6

    def __init__(self, run_dir, template):
        self.output = Path(run_dir) / f"{template.lower().replace(' ', '-')}.trace"
        self.log = Path(run_dir) / "xctrace.out"
        self.template = template
        self.process = None
        self.seen = (None, 0)

    def step(self, pid):
        if self.process is not None or pid is None:
            return
        last, count = self.seen
        self.seen = (pid, count + 1 if pid == last else 1)
        if self.seen[1] < self.STABLE_STEPS:
            return
        self.process = subprocess.Popen(
            ["xctrace", "record", "--template", self.template, "--attach", str(pid), "--time-limit", f"{self.LIMIT_SECONDS}s",
             "--output", str(self.output), "--no-prompt"],
            stdout=self.log.open("w"), stderr=subprocess.STDOUT)
        (self.output.parent / "trace-start.txt").write_text(f"{time.time():.3f}\n")

    def stop(self):
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
        try:
            self.process.wait(timeout=self.SETTLE_SECONDS)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


@dataclass
class Node:
    count: int
    symbol: str
    module: str
    depth: int
    children: list = field(default_factory=list)


def main_thread_lines(text):
    lines = text.splitlines()
    try:
        start = next(index for index, line in enumerate(lines) if line.strip() == "Call graph:")
    except StopIteration:
        raise SampleError("no call graph in the sample") from None
    selected, inside = [], False
    for line in lines[start + 1:]:
        if not line.strip():
            break
        if THREAD.match(line):
            if inside:
                break
            inside = "Main Thread" in line or "com.apple.main-thread" in line
            continue
        if inside:
            selected.append(line)
    return selected


def parse_tree(lines):
    roots, stack = [], []
    for line in lines:
        match = NODE.match(line)
        if not match:
            continue
        node = Node(int(match["count"]), match["symbol"].strip(), match["module"] or "?", len(match["lead"]))
        while stack and stack[-1].depth >= node.depth:
            stack.pop()
        (stack[-1].children if stack else roots).append(node)
        stack.append(node)
    return roots


@dataclass
class Profile:
    total: int = 0
    idle: int = 0
    accessibility: int = 0
    self_time: Counter = field(default_factory=Counter)
    inclusive: Counter = field(default_factory=Counter)

    def add(self, roots):
        for root in roots:
            self.total += root.count
            self.walk(root, frozenset(), False)

    def walk(self, node, ancestors, serving):
        if not serving and ACCESSIBILITY.search(node.symbol):
            self.accessibility += node.count
            serving = True
        key = f"{node.symbol}  [{node.module}]"
        own = node.count - sum(child.count for child in node.children)
        if own > 0:
            self.self_time[key] += own
            if node.symbol in IDLE_SYMBOLS:
                self.idle += own
        if APP_MODULES.match(node.module) and key not in ancestors:
            self.inclusive[key] += node.count
        for child in node.children:
            self.walk(child, ancestors | {key}, serving)


def window_start(path):
    return float(path.name.split("-", 1)[0])


def profiles_by_phase(run_dir):
    directory = perf_tour.perf_directory(run_dir)
    phases = [phase for phase in perf_tour.read_phases(directory / perf_tour.PHASES_FILE) if not phase.get("skipped")]
    files = sorted((Path(run_dir) / SAMPLES_DIR).glob("*.txt"))
    if not files:
        raise SampleError(f"no samples in {Path(run_dir) / SAMPLES_DIR}; run the tour with --trace sample")
    result = {}
    for path in files:
        start = window_start(path)
        end = start + WINDOW_SECONDS
        overlaps = [(min(end, phase["end"]) - max(start, phase["start"]), phase["surface"]) for phase in phases]
        best, surface = max(overlaps, default=(0, None))
        if best <= WINDOW_SECONDS / 2:
            continue
        result.setdefault(surface, Profile()).add(parse_tree(main_thread_lines(path.read_text(errors="replace"))))
    return result


def render(run_dir, only=None, top=12):
    profiles = profiles_by_phase(run_dir)
    lines = []
    for surface, profile in profiles.items():
        if only and surface not in only or profile.total == 0:
            continue
        busy = 100 * (profile.total - profile.idle) / profile.total
        serving = 100 * profile.accessibility / profile.total
        lines.append(f"== {surface}: {profile.total} main-thread samples, busy {busy:.0f}%, accessibility serving {serving:.0f}% (UI-test queries)")
        lines.append("  inclusive, app code:")
        lines += [f"    {count * 100 / profile.total:5.1f}%  {key}" for key, count in profile.inclusive.most_common(top)]
        lines.append("  self, any module (idle waits excluded):")
        busy_self = [(key, count) for key, count in profile.self_time.most_common() if key.split("  [")[0] not in IDLE_SYMBOLS][:top]
        lines += [f"    {count * 100 / profile.total:5.1f}%  {key}" for key, count in busy_self]
    if not lines:
        raise SampleError("no sample window fell inside a measured phase")
    return "\n".join(lines) + "\n"
