"""scripts/ci/check_swift_entitlements.py: the Pal project's entitlements wiring can sign."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_entitlements.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_entitlements as cse

PLIST = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0">\n<dict>\n{body}</dict>\n</plist>\n'
)
APS = "\t<key>aps-environment</key>\n\t<string>development</string>\n"
COMM = "\t<key>com.apple.developer.usernotifications.communication</key>\n\t<true/>\n"
GROUP = (
    "\t<key>com.apple.security.application-groups</key>\n\t<array>\n"
    "\t\t<string>group.dev.example.app</string>\n\t</array>\n"
)
SPEC = """name: Demo
targets:
  App:
    type: application
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: App/App.entitlements
        CODE_SIGN_ENTITLEMENTS[sdk=macosx*]: App/App-macOS.entitlements
    dependencies:
      - target: Service
  Service:
    type: app-extension
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Service/Service.entitlements
"""


def plist(*keys: str) -> str:
    return PLIST.format(body="".join(keys))


def tree(tmp_path: Path, overrides: dict[str, str] | None = None) -> Path:
    files = {
        "project.yml": SPEC,
        "App/App.entitlements": plist(APS, COMM, GROUP),
        "App/App-macOS.entitlements": plist(APS, COMM, GROUP),
        "Service/Service.entitlements": plist(GROUP),
    }
    files.update(overrides or {})
    for name, body in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def test_an_app_with_the_capability_and_an_extension_without_it_passes(tmp_path):
    assert cse.scan(tree(tmp_path)) == []


def test_the_real_pal_project_passes():
    assert cse.scan(REPO / "apps" / "ios") == []


def test_a_tree_without_a_project_spec_is_not_scanned(tmp_path):
    assert cse.scan(tmp_path) == []


def test_a_missing_entitlements_file_fails(tmp_path):
    root = tree(tmp_path)
    (root / "App/App-macOS.entitlements").unlink()
    found = cse.scan(root)
    assert len(found) == 1
    assert found[0].startswith("project.yml:8: entitlements-missing") and "App/App-macOS.entitlements" in found[0]


def test_an_extension_requesting_communication_notifications_fails_with_its_line(tmp_path):
    found = cse.scan(tree(tmp_path, {"Service/Service.entitlements": plist(COMM, GROUP)}))
    assert [entry.split(": ")[1] for entry in found] == ["extension-communication"]
    assert found[0].startswith("Service/Service.entitlements:5:")


def test_an_extension_requesting_it_through_spec_properties_fails(tmp_path):
    spec = SPEC.replace(
        "    type: app-extension\n",
        "    type: app-extension\n    entitlements:\n      path: Service/Service.entitlements\n"
        "      properties:\n        com.apple.developer.usernotifications.communication: true\n",
    )
    found = cse.scan(tree(tmp_path, {"project.yml": spec}))
    assert [entry.split(": ")[1] for entry in found] == ["extension-communication"]
    assert found[0].startswith("project.yml:")


def test_main_exits_nonzero_on_a_finding_and_zero_on_a_clean_tree(tmp_path, capsys):
    bad = tree(tmp_path / "bad", {"Service/Service.entitlements": plist(COMM)})
    assert cse.main(["check", str(bad)]) == 1
    assert "extension-communication" in capsys.readouterr().out
    assert cse.main(["check", str(tree(tmp_path / "clean"))]) == 0
