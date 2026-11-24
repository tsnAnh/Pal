"""Does this shell command or Python code create, import or install a bot or profile?"""

import itertools
import os
import re
import shlex

from tools.approval_detection import (
    _SHELL_NAMES,
    _command_parser_limit_exceeded,
    _env_split_payload,
    _execution_flag_findings,
    _iter_shell_command_word_spans,
    _scan_backtick_end,
    _scan_dollar_paren_end,
    _scan_shell,
    _shell_command_segment,
    _shell_segment_tokens,
)


_CREATING_VERBS = frozenset({("bot", "create"), ("profile", "create"), ("profile", "import"), ("profile", "install")})
_HELP_FLAGS = frozenset({"-h", "--help"})
_TEXT_ONLY_COMMANDS = frozenset({
    "grep", "egrep", "fgrep", "rg", "ag", "ack", "echo", "printf", "cat", "head", "tail", "less", "more",
    "man", "diff", "wc",
})
_LAUNCHER_LOOKAHEAD = 5
_ENTRY_LOOKAHEAD = 16
_DYNAMIC_ENTRY_LOOKAHEAD = 6
_HERMES_PROGRAMS = frozenset({"hermes", "hermes.exe"})
_HERMES_MODULE = "hermes_cli.main"
_HERMES_MAIN_SUFFIX = "hermes_cli/main.py"
_LAUNCHER_PACKAGE_NAMES = frozenset({"hermes-agent"})
_LAUNCHER_SUBCOMMANDS = frozenset({"run", "tool", "exec", "x", "shell"})
_LAUNCHER_OPTIONS_WITH_VALUE = frozenset({
    "--project", "--directory", "--with", "--with-requirements", "--with-editable", "--from", "--python", "-p",
    "--env-file", "--package", "--spec", "--index", "--index-url", "--extra-index-url", "--cwd", "-C",
    "--config-file", "--group", "--extra", "--only-group", "-w", "--prefix", "--root", "--no-cache-dir",
})
_RUNNER_PROGRAMS = frozenset({
    "xargs", "find", "watch", "parallel", "flock", "doas", "su", "runuser", "caffeinate", "arch", "script",
})
_ALIAS_VERB_WORDS = frozenset(word for pair in _CREATING_VERBS for word in pair)
_CREATING_PYTHON_API = re.compile(
    r'(?:\.|\b)(?:create_profile|import_profile|install_profile|install_distribution)\s*\('
    r'|\.(?:create_profile|import_profile|install_profile|install_distribution)\b')
_PYTHON_LAUNCHER_RE = re.compile(
    r'^(?:python[\d.]*|pypy[\d.]*|ipython[\d.]*|py|uv|uvx|pipx|poetry|pdm|hatch|rye|conda|mamba|micromamba)(?:\.exe)?$')
_PY_STRING_LITERAL_RE = re.compile(r'''(["'])((?:\\.|(?!\1).)*)\1''', re.DOTALL)
_PY_LITERAL_SEQUENCE_RE = re.compile(
    r'''[\[(]\s*(?:(?:"[^"\n]*"|'[^'\n]*')\s*,\s*)*(?:"[^"\n]*"|'[^'\n]*')\s*,?\s*[\])]''')
_PY_LOGGING_CALL_RE = re.compile(r'(?:\bprint|\blog\w*|\b(?:logger|logging|log|warnings)\.\w+|\braise\s+\w+)\s*\(\s*$')
_MAX_CODE_LITERALS = 2000
_HEREDOC_OPERATOR_RE = re.compile(r'''<<(-?)[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|(\\?)([A-Za-z0-9_.-]+))''')
_HEREDOC_LINE_SPLIT_RE = re.compile(r'[\s|;&()<>"\'`$]+')


def _eval_payloads(source: str):
    for start, _, _ in _iter_shell_command_word_spans(source):
        tokens = _shell_segment_tokens(_shell_command_segment(source, start), 0)
        if tokens and os.path.basename(tokens[0]).lower() == "eval" and len(tokens) > 1:
            yield " ".join(tokens[1:])


def _iter_command_argvs(command: str):
    pending, seen = [command], set()
    while pending:
        source = pending.pop()
        if source in seen:
            continue
        seen.add(source)
        for start, _, _ in _iter_shell_command_word_spans(source):
            tokens = _shell_segment_tokens(_shell_command_segment(source, start), 0)
            if tokens:
                yield tokens
                if os.path.basename(tokens[0]).lower() == "env":
                    payload = _env_split_payload(tokens)
                    if payload:
                        pending.append(payload)
        pending.extend(payload for _, payload in _execution_flag_findings(source) if payload)
        pending.extend(_eval_payloads(source))


def _is_hermes_entry_token(token: str, *, package_names: bool = False) -> bool:
    base = os.path.basename(token.replace("\\", "/")).lower()
    return (base in _HERMES_PROGRAMS or token.lower() == _HERMES_MODULE
            or token.replace("\\", "/").lower().endswith(_HERMES_MAIN_SUFFIX)
            or (package_names and base in _LAUNCHER_PACKAGE_NAMES))


def _launcher_entry(argv: list[str]) -> int | None:
    index = 1
    while index < min(len(argv), _ENTRY_LOOKAHEAD):
        token = argv[index]
        if token == "-m":
            return index + 1 if index + 1 < len(argv) and argv[index + 1].lower() == _HERMES_MODULE else None
        if token.startswith("-m") and not token.startswith("--"):
            return index if token[2:].lower() == _HERMES_MODULE else None
        if token.startswith("-"):
            takes_value = token.partition("=")[0] in _LAUNCHER_OPTIONS_WITH_VALUE and "=" not in token
            index += 2 if takes_value else 1
            continue
        if _is_hermes_entry_token(token, package_names=True):
            return index
        base = os.path.basename(token).lower()
        if base in _LAUNCHER_SUBCOMMANDS or _PYTHON_LAUNCHER_RE.match(base):
            index += 1
            continue
        return None
    return None


def _runner_entry(argv: list[str]) -> int | None:
    return next((i for i in range(1, min(len(argv), _ENTRY_LOOKAHEAD)) if _is_hermes_entry_token(argv[i])), None)


def _is_profile_wrapper(program: str) -> bool:
    from hermes_cli.profiles import build_alias_map
    return program in {alias.lower() for alias in build_alias_map().values()}


def _hermes_entries(argv: list[str]) -> list[int]:
    program = os.path.basename(argv[0]).lower()
    if program in _TEXT_ONLY_COMMANDS:
        return []
    if _is_hermes_entry_token(argv[0]):
        return [0]
    if "$" in argv[0] or "`" in argv[0]:
        return list(range(min(len(argv), _DYNAMIC_ENTRY_LOOKAHEAD)))
    if _PYTHON_LAUNCHER_RE.match(program):
        entry = _launcher_entry(argv)
    elif program in _RUNNER_PROGRAMS:
        entry = _runner_entry(argv)
    elif any(token.lower() in _ALIAS_VERB_WORDS for token in argv[1:4]) and _is_profile_wrapper(program):
        entry = 0
    else:
        entry = None
    return [] if entry is None else [entry]


def _argv_creates(argv: list[str]) -> bool:
    pending, seen = [entry + 1 for entry in _hermes_entries(argv)], set()
    while pending:
        position = pending.pop()
        if position in seen or position >= len(argv):
            continue
        seen.add(position)
        verb = tuple(token.lower() for token in argv[position:position + 2])
        if verb in _CREATING_VERBS:
            return not _only_prints_help(argv[position + 2:])
        if argv[position].startswith("-"):
            pending.extend((position + 1, position + 2))
    return False


def _only_prints_help(later_args: list[str]) -> bool:
    options = itertools.takewhile(lambda token: token != "--", later_args)
    return any(token in _HELP_FLAGS for token in options)


def _launches_python(argv: list[str]) -> bool:
    return any(_PYTHON_LAUNCHER_RE.match(os.path.basename(token).lower())
               for token in argv[:_LAUNCHER_LOOKAHEAD + 1])


def _heredoc_terminator_span(text: str, start: int, end: int, delimiter: str, strip_tabs: bool) -> tuple[int, int]:
    position = start
    while position < end:
        line_end = text.find("\n", position, end)
        line_end = end if line_end < 0 else line_end
        line = text[position:line_end]
        if (line.lstrip("\t") if strip_tabs else line) == delimiter:
            return position, min(line_end + 1, end)
        position = line_end + 1
    return end, end


def _heredoc_spans(text: str, start: int = 0, end: int | None = None) -> list[tuple[int, int, int, bool]]:
    limit = len(text) if end is None else end
    spans: list[tuple[int, int, int, bool]] = []
    pending: list[tuple[str, bool, int, bool]] = []
    resume = start
    for kind, i, j, quote in _scan_shell(text, start, limit, subst="uq"):
        if i < resume:
            continue
        if kind == "subst":
            body_start = i + (2 if text.startswith("$(", i) else 1)
            spans.extend(_heredoc_spans(text, body_start, j - 1))
        elif kind == "char" and quote is None and text[i] == "<" and text.startswith("<<", i) \
                and not text.startswith("<<<", i) and not (i and text[i - 1] == "<"):
            match = _HEREDOC_OPERATOR_RE.match(text, i)
            if match:
                delimiter = match.group(2) or match.group(3) or match.group(5)
                quoted = match.group(2) is not None or match.group(3) is not None or bool(match.group(4))
                pending.append((delimiter, match.group(1) == "-", i, quoted))
        elif kind == "char" and quote is None and text[i] == "\n" and pending:
            position = i + 1
            for delimiter, strip_tabs, operator_at, quoted in pending:
                body_end, after = _heredoc_terminator_span(text, position, limit, delimiter, strip_tabs)
                spans.append((operator_at, position, body_end, quoted))
                position = after
            pending, resume = [], position
    return spans


def _expansion_spans(body: str) -> list[tuple[int, int]]:
    spans, index = [], 0
    while index < len(body):
        if body[index] == "\\":
            index += 2
            continue
        close = None
        if body.startswith("$(", index):
            close = _scan_dollar_paren_end(body, index)
        elif body[index] == "`":
            close = _scan_backtick_end(body, index)
        if close is None:
            index += 1
        else:
            spans.append((index, close))
            index = close
    return spans


def _heredoc_consumer(text: str, operator_at: int) -> str | None:
    line_start = text.rfind("\n", 0, operator_at) + 1
    line_end = text.find("\n", operator_at)
    line = text[line_start:len(text) if line_end < 0 else line_end]
    names = {os.path.basename(token).lower() for token in _HEREDOC_LINE_SPLIT_RE.split(line) if token}
    if any(_PYTHON_LAUNCHER_RE.match(name) or name.startswith("python") for name in names):
        return "python"
    return "shell" if names & set(_SHELL_NAMES) else None


def _blank(text: str, start: int, end: int) -> str:
    return "".join(ch if ch == "\n" else " " for ch in text[start:end])


def _split_heredocs(command: str) -> tuple[str, list[str]]:
    if "<<" not in command:
        return command, []
    parts, python_bodies, cursor = [], [], 0
    for operator_at, body_start, body_end, quoted in sorted(_heredoc_spans(command), key=lambda s: s[1]):
        if body_start < cursor:
            continue
        consumer = _heredoc_consumer(command, operator_at)
        if consumer == "shell":
            continue
        body = command[body_start:body_end]
        if consumer == "python":
            python_bodies.append(body)
        keep = [] if quoted or consumer == "python" else _expansion_spans(body)
        parts.append(command[cursor:body_start])
        previous = 0
        for k_start, k_end in keep:
            parts.append(_blank(body, previous, k_start))
            parts.append(body[k_start:k_end])
            previous = k_end
        parts.append(_blank(body, previous, len(body)))
        cursor = body_end
    parts.append(command[cursor:])
    return "".join(parts), python_bodies


def _code_command_candidates(code: str):
    for match in _PY_STRING_LITERAL_RE.finditer(code):
        if not _PY_LOGGING_CALL_RE.search(code[max(0, match.start() - 40):match.start()]):
            yield match.group(2)
    for sequence in _PY_LITERAL_SEQUENCE_RE.finditer(code):
        items = [m.group(2) for m in _PY_STRING_LITERAL_RE.finditer(sequence.group(0))]
        yield shlex.join(items)


def _command_creates(command: str) -> bool:
    if _command_parser_limit_exceeded(command):
        return False
    command, python_bodies = _split_heredocs(command)
    if any(_code_creates(body) for body in python_bodies):
        return True
    launches_python = False
    for argv in _iter_command_argvs(command):
        if _argv_creates(argv):
            return True
        launches_python = launches_python or (
            os.path.basename(argv[0]).lower() not in _TEXT_ONLY_COMMANDS and _launches_python(argv))
    return launches_python and "hermes_cli" in command and bool(_CREATING_PYTHON_API.search(command))


def _code_creates(code: str) -> bool:
    if _command_parser_limit_exceeded(code):
        return False
    if "hermes_cli" in code and _CREATING_PYTHON_API.search(code):
        return True
    return any(_command_creates(candidate)
               for candidate in itertools.islice(_code_command_candidates(code), _MAX_CODE_LITERALS))


def creates_bot_or_profile(text: str, *, code: bool = False) -> bool:
    return _code_creates(text) if code else _command_creates(text)
