import json
import re
from pathlib import Path

import pytest

from agent.skill_utils import parse_frontmatter
from tools.skills_tool_setup import _get_required_environment_variables

ROOT = Path(__file__).parents[2]
ALLOWLIST = json.loads((Path(__file__).parent / "skill_secret_allowlist.json").read_text())
SECRET = r"[A-Z][A-Z0-9_]*(?:_API_KEY|_TOKEN|_SECRET|_PASSWORD|_KEY)"
PATTERNS = (
    re.compile(rf"^\s*export ({SECRET})=", re.MULTILINE),
    re.compile(rf"hermes config set ({SECRET})", re.IGNORECASE),
    re.compile(rf"^({SECRET})=", re.MULTILINE),
    re.compile(rf"(?:\.hermes/\.env|\$HERMES_HOME/\.env)[^\n]{{0,80}}?\b({SECRET})\b"),
    re.compile(rf"\b({SECRET})\b[^\n]{{0,80}}?(?:\.hermes/\.env|\$HERMES_HOME/\.env)"),
)


def skill_dirs():
    for top in ("skills", "optional-skills"):
        for md in sorted((ROOT / top).rglob("SKILL.md")):
            yield md.parent


def undeclared_secrets(skill: Path) -> set[str]:
    frontmatter, _ = parse_frontmatter((skill / "SKILL.md").read_text())
    declared = {e["name"] for e in _get_required_environment_variables(frontmatter)}
    texts = [skill / "SKILL.md", *sorted((skill / "references").rglob("*.md"))] if (skill / "references").is_dir() \
        else [skill / "SKILL.md"]
    found = {m.group(1) for path in texts for p in PATTERNS for m in p.finditer(path.read_text())}
    return found - declared


@pytest.mark.parametrize("skill", list(skill_dirs()), ids=lambda p: str(p.relative_to(ROOT)))
def test_secret_a_skill_tells_the_user_to_set_is_declared(skill):
    relative = str(skill.relative_to(ROOT))
    allowed = set(ALLOWLIST.get(relative, {}).get("names", []))
    missing = undeclared_secrets(skill) - allowed
    assert not missing, (
        f"{relative} tells the user to set {sorted(missing)} outside the app; declare them under "
        f"required_environment_variables in SKILL.md so the masked prompt opens, or add a reasoned "
        f"entry to tests/skills/skill_secret_allowlist.json")


def test_allowlist_entries_carry_a_reason_and_still_match():
    for relative, entry in ALLOWLIST.items():
        assert entry.get("reason", "").strip(), relative
        assert (ROOT / relative / "SKILL.md").is_file(), relative
        assert undeclared_secrets(ROOT / relative) & set(entry["names"]), f"{relative} no longer needs its entry"
