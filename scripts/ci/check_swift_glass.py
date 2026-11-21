#!/usr/bin/env python3
"""Fail when Pal Swift code breaks the Liquid Glass design rules (table in apps/ios/AGENTS.md).

Text matching only (no Swift toolchain): each rule reads source with a small bracket-aware
scanner, so it sees shapes, not types. Findings already on main are listed in
``apps/ios/.glass-lint-baseline.json`` (matched by rule, file and line text, so edits above a
line do not break it); only a NEW finding fails. Fixing one leaves a stale baseline entry that is
reported and harmless; ``--write-baseline`` rewrites the file. A justified exception carries
``glass-lint: ok`` on the flagged line.

Rules: glass-dark-tint, glass-hand-rolled, glass-pill-button, glass-container, glass-sheet-chrome,
glass-search-field, glass-floating-bar, glass-raw-color, glass-system-tint.

Run: python scripts/ci/check_swift_glass.py [apps_ios_root] [--write-baseline] [--no-baseline]
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

OPT_OUT = "glass-lint: ok"
SKIP_DIRS = {"Tests", "UITests", "Fixtures", ".build"}
BASELINE_NAME = ".glass-lint-baseline.json"
PAL_DESIGN = ("Packages", "PalDesign")
CLOSERS = {"(": ")", "{": "}", "[": "]"}


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    line: int
    text: str
    message: str

    def key(self) -> tuple[str, str, str]:
        return (self.rule, self.path, self.text)

    def render(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.message}"


class Source:
    """Text plus bracket pairing that ignores strings and comments."""

    def __init__(self, original: str) -> None:
        self.original = original.splitlines()
        self.text, plain = blank_comments(original)
        self.lines = self.text.splitlines()
        self.plain = plain.splitlines()
        text = self.text
        self.starts = [0]
        for match in re.finditer(r"\n", text):
            self.starts.append(match.end())
        self.close: dict[int, int] = {}
        self.parent: dict[int, int | None] = {}
        self._pair()

    def line_of(self, index: int) -> int:
        lo, hi = 0, len(self.starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.starts[mid] <= index:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def _pair(self) -> None:
        text, n, i = self.text, len(self.text), 0
        stack: list[int] = []
        while i < n:
            ch = text[i]
            if text.startswith('"""', i):
                end = text.find('"""', i + 3)
                i = n if end < 0 else end + 3
                continue
            if ch == '"':
                i += 1
                while i < n and text[i] not in '"\n':
                    i += 2 if text[i] == "\\" else 1
                i += 1
                continue
            if ch in CLOSERS:
                self.parent[i] = stack[-1] if stack else None
                stack.append(i)
            elif ch in ")}]" and stack:
                self.close[stack.pop()] = i
            i += 1

    def end_of_call(self, open_index: int) -> int:
        """End of ``name(...)`` plus its trailing closures."""
        end = self.close.get(open_index, len(self.text) - 1)
        while True:
            m = re.compile(r"\s*\{").match(self.text, end + 1)
            if not m or (m.end() - 1) not in self.close:
                return end
            end = self.close[m.end() - 1]

    def calls(self, name: str) -> Iterator[tuple[int, int, int]]:
        """(name start, open paren, end including trailing closures) of each ``name(`` call."""
        for m in re.finditer(rf"(?<![A-Za-z0-9_]){re.escape(name)}\(", self.text):
            open_index = m.end() - 1
            if open_index in self.close:
                yield m.start(), open_index, self.end_of_call(open_index)

    def modifier_chain(self, end: int) -> str:
        """Rest of the line at ``end`` plus every following line that starts with ``.``."""
        line = self.line_of(end)
        parts = [self.lines[line - 1][end - self.starts[line - 1] + 1:]]
        for follow in self.lines[line:]:
            if not follow.strip().startswith("."):
                break
            parts.append(follow)
        return "\n".join(parts)

    def enclosing(self, index: int) -> list[int]:
        """Open brackets around ``index``, innermost first."""
        opens = [o for o, c in self.close.items() if o < index < c]
        return sorted(opens, reverse=True)


def blank_comments(text: str) -> tuple[str, str]:
    """``text`` with comments blanked, and again with string contents blanked; same offsets."""
    code, plain = list(text), list(text)
    n, i = len(text), 0

    def blank(buffers: list[list[str]], lo: int, hi: int) -> None:
        for buf in buffers:
            for k in range(lo, hi):
                if buf[k] != "\n":
                    buf[k] = " "

    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank([code, plain], i, end)
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            blank([code, plain], i, end)
            i = end
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            blank([plain], i + 3, max(i + 3, end - 3))
            i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            blank([plain], i + 1, min(j, n))
            i = j + 1
        else:
            i += 1
    return "".join(code), "".join(plain)


@dataclass(frozen=True)
class Scope:
    name: str
    includes: Callable[[tuple[str, ...]], bool]


EVERYWHERE = Scope("everywhere", lambda parts: True)
SCREENS = Scope("screens", lambda parts: parts[0] == "App")
OUTSIDE_DESIGN = Scope("outside PalDesign", lambda parts: parts[:2] != PAL_DESIGN)


@dataclass(frozen=True)
class LineRule:
    rule: str
    pattern: re.Pattern[str]
    scope: Scope
    message: str
    window_must_match: re.Pattern[str] | None = None
    skip: re.Pattern[str] | None = None
    keeps_strings: bool = False

    def scan(self, src: Source) -> Iterator[tuple[int, str]]:
        for i in range(len(src.lines)):
            code = src.lines[i] if self.keeps_strings else src.plain[i]
            if not code.strip() or not self.pattern.search(code) or (self.skip and self.skip.search(code)):
                continue
            if self.window_must_match:
                window = "\n".join(src.lines[max(0, i - 4):i + 5])
                if not self.window_must_match.search(window):
                    continue
            yield i + 1, self.message


LINE_RULES = (
    LineRule(
        "glass-dark-tint",
        re.compile(r"\.tint\(\s*(?:Color\.|UIColor\.|NSColor\.)?\.?(?:black|darkGray)\b|\bdarkTint\b"
                   r"|\.tint\(\s*Color\(white:\s*0?\.[0-3]"),
        EVERYWHERE,
        "dark tint on glass. Liquid Glass takes no black tint; drop .tint(...) or use the system .glass style",
    ),
    LineRule(
        "glass-dark-tint",
        re.compile(r"(?:Color\.|\.)black\.opacity\("),
        EVERYWHERE,
        "black overlay near glass. Liquid Glass takes no black tint; drop it or use the system .glass style",
        window_must_match=re.compile(r"[Gg]lass"),
        skip=re.compile(r"\.shadow\("),
    ),
    LineRule(
        "glass-hand-rolled",
        re.compile(r"\.glassEffect(?:ID|Union|Transition)?\(|\bNSGlassEffectView\b|\bUIGlassEffect\b"),
        OUTSIDE_DESIGN,
        "hand-rolled glass outside PalDesign. Use PalGlass / .palGlass(...) or the system .buttonStyle(.glass)",
    ),
    LineRule(
        "glass-pill-button",
        re.compile(r"\bPillButtonStyle\b|\bPalPillButtonStyle\b|\.pill\(|\.palPill\b|(?<![A-Za-z0-9_])PillButton\("),
        EVERYWHERE,
        "old pill button style. Use the shared glass or capsule button style (.buttonStyle(.glass), no blue)",
    ),
    LineRule(
        "glass-system-tint",
        re.compile(r"\.tint\(\s*(?:Color\.|\.)?(?:blue|systemBlue|accentColor)\b|\.tint\([^)]*\baccentBlue(?:Text)?\b|\.accentColor\("),
        SCREENS,
        "system or blue tint on a control. Controls take the app accent (the Pal ink set once on the root); "
        "delete the .tint/.accentColor, or use PalTokens.textPrimary when a view must restate the ink",
    ),
    LineRule(
        "glass-raw-color",
        re.compile(r"\b(?:Color|UIColor|NSColor)\(\s*(?:\.\w+\s*,\s*)?(?:red|white|hue)\s*:"
                   r"|\"#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?\"|\bColor\(\s*hex"),
        SCREENS,
        "raw colour in a screen. Use PalTokens / theme.palette or a system colour (Color.primary, .secondary)",
        keeps_strings=True,
    ),
)

BEZEL = re.compile(r"\.(?:background|overlay|border|clipShape|cornerRadius|glassEffect)\(|\.textFieldStyle\(\s*\.roundedBorder"
                   r"|palGlass\(")
SEARCH_LABEL = re.compile(r"[Ss]earch|[Ff]ind\b")
BLUE = re.compile(r"\.blue\b|Color\.blue|\bsystemBlue\b|\baccentBlue(?:Text)?\b|\.accentColor\b")
SCROLLING = re.compile(r"\b(?:ScrollView|ScrollViewReader|LazyVStack|LazyVGrid|List|Table)\b")
FLOATING_EDGE = re.compile(r"\.overlay\(\s*alignment:\s*\.(?:top|bottom)\b|\bZStack\(\s*alignment:\s*\.(?:top|bottom)\b")
OWNS_BACKGROUND = re.compile(r"\.background\(|palGlass|glassEffect|Material\b|FloatingSearchBar|GlassEffectContainer"
                             r"|\.buttonStyle\(\s*\.glass|ChatComposer|\.bar\b|\.scrollEdgeEffect")
DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|static|final|nonisolated|"
                  r"override|mutating)\s+)*(?:var|func|init)\b")
CLOSE_SIDE = re.compile(r'"(?:Close|Cancel|Dismiss)"|xmark|role:\s*\.(?:close|cancel)')
TRAILING_PLACEMENT = re.compile(r"placement:\s*\.(?:topBarTrailing|navigationBarTrailing|confirmationAction|primaryAction)\b")
MAGIC_BOTTOM = re.compile(r"\.padding\(\s*\.bottom\s*,\s*\d")


def _decls(src: Source) -> list[tuple[int, int]]:
    spans = []
    for open_index, close_index in src.close.items():
        if src.text[open_index] != "{":
            continue
        line_start = src.starts[src.line_of(open_index) - 1]
        if DECL.match(src.text[line_start:open_index]):
            spans.append((open_index, close_index))
    return spans


def _innermost(spans: list[tuple[int, int]], index: int) -> tuple[int, int] | None:
    inside = [s for s in spans if s[0] < index < s[1]]
    return min(inside, key=lambda s: s[1] - s[0], default=None)


def glass_container(src: Source) -> Iterator[tuple[int, str]]:
    spans = _decls(src)
    uses: dict[tuple[int, int], list[int]] = {}
    for m in re.finditer(r"\.(?:palGlass|glassEffect)\(", src.text):
        decl = _innermost(spans, m.start())
        if decl:
            uses.setdefault(decl, []).append(m.start())
    for decl, hits in uses.items():
        if len(hits) < 2:
            continue
        around = [s for s in spans if s[0] <= decl[0] and decl[1] <= s[1]]
        if any("GlassEffectContainer" in src.text[s[0]:s[1]] for s in around):
            continue
        yield src.line_of(hits[0]), ("several custom glass views outside a GlassEffectContainer. "
                                     "Wrap the group in GlassEffectContainer { ... } so the glass blends and stays cheap")


def glass_blue_button(src: Source) -> Iterator[tuple[int, str]]:
    for start, _, end in src.calls("Button"):
        region = src.text[start:end + 1] + src.modifier_chain(end)
        if BLUE.search(region):
            yield src.line_of(start), ("blue on a button. Buttons are neutral Liquid Glass capsules with no blue: "
                                       ".buttonStyle(.glass), or .glassProminent for the single primary action")


def glass_sheet_chrome(src: Source) -> Iterator[tuple[int, str]]:
    for start, _, end in src.calls("SheetChrome"):
        for m in MAGIC_BOTTOM.finditer(src.text, start, end):
            yield src.line_of(m.start()), ("raw bottom padding on sheet content. The bottom inset comes from SheetChrome "
                                           "(PalMetrics); remove the number")
    for name in ("ToolbarItem", "ToolbarItemGroup"):
        for start, open_index, end in src.calls(name):
            header = src.text[start:open_index + 1 + (src.close[open_index] - open_index)]
            if TRAILING_PLACEMENT.search(header) and CLOSE_SIDE.search(src.text[start:end + 1]):
                yield src.line_of(start), ("Close or Cancel on the trailing side. Close sits on the leading side: "
                                           "SheetChrome, or ToolbarItem(placement: .cancellationAction) with Button(role: .close)")
    for start, open_index, _ in src.calls("Button"):
        args = src.text[open_index:src.close[open_index] + 1]
        if re.match(r'\(\s*(?:String\(localized:\s*)?"Close"', args) and "role:" not in args:
            yield src.line_of(start), "custom Close button. Use Button(role: .close) or SheetChrome's leading Close"
    for name in (".sheet", ".fullScreenCover"):
        for start, _, end in src.calls(name):
            region = src.text[start:end + 1]
            if re.search(r"NavigationStack|\.navigationTitle\(|ToolbarItem", region) and "SheetChrome" not in region:
                yield src.line_of(start), ("sheet without SheetChrome. Host sheet content in SheetChrome "
                                           "(Close on the leading side, shared bottom inset)")


def glass_search_field(src: Source, parts: tuple[str, ...]) -> Iterator[tuple[int, str]]:
    for start, open_index, end in src.calls("TextField"):
        if not SEARCH_LABEL.search(src.text[open_index:src.close[open_index] + 1]):
            continue
        chains = [src.modifier_chain(end)]
        wrappers = [o for o in src.enclosing(start) if src.text[o] == "{"][:2]
        for o in wrappers:
            header = src.lines[src.line_of(o) - 1]
            if re.search(r"\b(?:HStack|ZStack|VStack|Group|label)\b", header):
                chains.append(src.modifier_chain(src.close[o]))
        if any(BEZEL.search(c) for c in chains):
            yield src.line_of(start), ("custom search field chrome. Use .searchable(text:) or the plain system field; "
                                       "no bezel, border or background")
    if parts[:2] != PAL_DESIGN:
        for m in re.finditer(r"\bstruct\s+\w*Search(?:Field|Bar|Box|Input)\w*\s*:\s*View", src.text):
            yield src.line_of(m.start()), ("custom search field view. Use .searchable(text:), the plain system field "
                                           "or PalDesign's FloatingSearchBar")


def glass_floating_bar(src: Source) -> Iterator[tuple[int, str]]:
    spans = _decls(src)
    for i, code in enumerate(src.plain):
        if not FLOATING_EDGE.search(code) or "PalHairline" in code:
            continue
        index = src.starts[i] + FLOATING_EDGE.search(code).start()
        decl = _innermost(spans, index)
        scope = src.text[decl[0]:decl[1]] if decl else src.text
        if SCROLLING.search(scope) and not re.search(r"safeAreaInset\(|contentMargins\(", scope):
            yield i + 1, ("floating bar laid over scrolling content with an overlay or ZStack. Use .safeAreaInset(edge:) "
                          "or .contentMargins so the content is inset by the bar's measured height")
    for _start, open_index, end in src.calls(".safeAreaInset"):
        body = src.text[open_index:end + 1]
        names = re.findall(r"\{\s*(\w+)\s*\}", body)
        resolved = body + "".join(_resolve(src, name) for name in names)
        if not OWNS_BACKGROUND.search(resolved + src.modifier_chain(end)):
            yield src.line_of(open_index), ("bar in safeAreaInset without its own background. The bar owns a background "
                                            "(.background, glass or material) so content scrolls under it cleanly")


def _resolve(src: Source, name: str) -> str:
    m = re.search(rf"\b(?:var|func)\s+{re.escape(name)}\b[^\n{{]*\{{", src.text)
    if not m:
        return ""
    open_index = m.end() - 1
    return src.text[open_index:src.close.get(open_index, open_index) + 1]


BLOCK_RULES: tuple[tuple[str, Scope, Callable[..., Iterator[tuple[int, str]]]], ...] = (
    ("glass-container", EVERYWHERE, glass_container),
    ("glass-pill-button", EVERYWHERE, glass_blue_button),
    ("glass-sheet-chrome", EVERYWHERE, glass_sheet_chrome),
    ("glass-search-field", EVERYWHERE, glass_search_field),
    ("glass-floating-bar", SCREENS, glass_floating_bar),
)


def violations(rel: Path, source: str) -> list[Finding]:
    src = Source(source)
    found: list[Finding] = []

    def add(rule: str, line: int, message: str) -> None:
        text = src.original[line - 1]
        if OPT_OUT not in text:
            found.append(Finding(rule, rel.as_posix(), line, text.strip(), message))

    for lr in LINE_RULES:
        if lr.scope.includes(rel.parts):
            for line, message in lr.scan(src):
                add(lr.rule, line, message)
    for rule, scope, fn in BLOCK_RULES:
        if not scope.includes(rel.parts):
            continue
        hits = fn(src, rel.parts) if fn is glass_search_field else fn(src)
        for line, message in hits:
            add(rule, line, message)
    return found


def scan(root: Path) -> list[Finding]:
    found: list[Finding] = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP_DIRS.intersection(rel.parts):
            continue
        found += violations(rel, path.read_text(encoding="utf-8-sig"))
    return found


def load_baseline(path: Path) -> Counter[tuple[str, str, str]]:
    if not path.is_file():
        return Counter()
    return Counter((e["rule"], e["file"], e["text"]) for e in json.loads(path.read_text(encoding="utf-8-sig")))


def write_baseline(path: Path, found: list[Finding]) -> None:
    entries = sorted(
        ({"rule": f.rule, "file": f.path, "text": f.text} for f in found),
        key=lambda e: (e["file"], e["rule"], e["text"]),
    )
    body = ",\n".join("  " + json.dumps(e, ensure_ascii=False, sort_keys=True) for e in entries)
    path.write_text(f"[\n{body}\n]\n" if entries else "[]\n", encoding="utf-8")


def new_findings(found: list[Finding], baseline: Counter[tuple[str, str, str]]) -> tuple[list[Finding], int]:
    budget = Counter(baseline)
    fresh = []
    for f in found:
        if budget[f.key()] > 0:
            budget[f.key()] -= 1
        else:
            fresh.append(f)
    return fresh, sum(budget.values())


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    baseline_path = root / BASELINE_NAME
    found = scan(root)
    if "--write-baseline" in argv:
        write_baseline(baseline_path, found)
        print(f"wrote {len(found)} entries to {baseline_path}")
        return 0
    baseline = Counter() if "--no-baseline" in argv else load_baseline(baseline_path)
    fresh, stale = new_findings(found, baseline)
    for finding in fresh:
        print(finding.render())
    if fresh:
        print(f"\n{len(fresh)} Liquid Glass design finding(s) (rules: apps/ios/AGENTS.md). Fix the code; "
              f'for a justified exception add "// {OPT_OUT}" on the line. Existing findings live in {BASELINE_NAME}; '
              "never add new ones there.")
        return 1
    if stale:
        print(f"swift-glass: ok; {stale} baseline entr{'y is' if stale == 1 else 'ies are'} fixed "
              "(run --write-baseline to drop them)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
