"""scripts/ci/check_swift_entitlements.py: the default Pal project signs without the Communication Notifications capability."""

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
include:
  - path: Variants/CommNotifications/comm-notifications.yml
    relativePaths: false
    enable: ${PAL_COMM_NOTIFICATIONS}
targets:
  App:
    type: application
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: App/App.entitlements
        CODE_SIGN_ENTITLEMENTS[sdk=macosx*]: App/App-macOS.entitlements
"""
FRAGMENT = """targets:
  App:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Variants/CommNotifications/App.entitlements
    dependencies:
      - target: Service
  Service:
    type: app-extension
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Variants/CommNotifications/Service.entitlements
"""


def plist(*keys: str) -> str:
    return PLIST.format(body="".join(keys))


def tree(tmp_path: Path, overrides: dict[str, str | None] | None = None) -> Path:
    files: dict[str, str | None] = {
        "project.yml": SPEC,
        "App/App.entitlements": plist(APS),
        "App/App-macOS.entitlements": plist(APS),
        "Variants/CommNotifications/comm-notifications.yml": FRAGMENT,
        "Variants/CommNotifications/App.entitlements": plist(APS, COMM, GROUP),
        "Variants/CommNotifications/Service.entitlements": plist(COMM, GROUP),
    }
    files.update(overrides or {})
    for name, body in files.items():
        if body is None:
            continue
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def test_the_default_tree_with_a_switched_variant_passes(tmp_path):
    assert cse.scan(tree(tmp_path)) == []


def test_the_real_pal_project_passes():
    assert cse.scan(REPO / "apps" / "ios") == []


def test_a_tree_without_a_project_spec_is_not_scanned(tmp_path):
    assert cse.scan(tmp_path) == []


def test_the_capability_keys_in_the_default_entitlements_fail_with_their_lines(tmp_path):
    found = cse.scan(tree(tmp_path, {"App/App.entitlements": plist(APS, COMM, GROUP)}))
    assert [entry.split(": ")[0] for entry in found] == ["App/App.entitlements:7", "App/App.entitlements:9"]
    assert all("switched-key" in entry and "PAL_COMM_NOTIFICATIONS" in entry and "Variants/CommNotifications" in entry for entry in found)


def test_an_unknown_key_in_a_default_entitlements_file_fails_and_names_the_switch(tmp_path):
    key = "\t<key>com.apple.developer.associated-domains</key>\n\t<array/>\n"
    found = cse.scan(tree(tmp_path, {"App/App-macOS.entitlements": plist(APS, key)}))
    assert len(found) == 1
    assert found[0].startswith("App/App-macOS.entitlements:7: entitlement-key") and "PAL_COMM_NOTIFICATIONS" in found[0] and "ALLOWED_KEYS" in found[0]


def test_an_extension_target_in_the_default_spec_fails(tmp_path):
    spec = SPEC + "  Service:\n    type: app-extension\n"
    found = cse.scan(tree(tmp_path, {"project.yml": spec}))
    assert len(found) == 1 and found[0].startswith("project.yml:13: extension-target") and "PAL_COMM_NOTIFICATIONS" in found[0]


def test_an_extension_target_inside_the_switched_fragment_passes(tmp_path):
    assert cse.scan(tree(tmp_path)) == []
    assert "app-extension" in (tmp_path / "Variants/CommNotifications/comm-notifications.yml").read_text()


def test_entitlement_properties_in_the_default_spec_are_checked(tmp_path):
    spec = SPEC.replace(
        "    type: application\n",
        "    type: application\n    entitlements:\n      path: App/App.entitlements\n"
        "      properties:\n        com.apple.security.application-groups:\n          - group.dev.example.app\n",
    )
    found = cse.scan(tree(tmp_path, {"project.yml": spec}))
    assert len(found) == 1 and "project.yml:" in found[0] and "switched-key" in found[0]


def test_an_include_without_the_switch_fails(tmp_path):
    for spec in (
        SPEC.replace("    enable: ${PAL_COMM_NOTIFICATIONS}\n", ""),
        SPEC.replace("${PAL_COMM_NOTIFICATIONS}", "true"),
    ):
        found = cse.scan(tree(tmp_path, {"project.yml": spec}))
        assert len(found) == 1 and found[0].startswith("project.yml:3: switch-wiring") and "enable:" in found[0]


def test_a_fragment_nobody_includes_fails(tmp_path):
    spec = SPEC.split("include:")[0] + "targets:" + SPEC.split("targets:")[1]
    found = cse.scan(tree(tmp_path, {"project.yml": spec}))
    assert len(found) == 1 and "never included" in found[0]


def test_a_variant_that_drops_a_default_key_fails(tmp_path):
    found = cse.scan(tree(tmp_path, {"Variants/CommNotifications/App.entitlements": plist(COMM, GROUP)}))
    assert len(found) == 1
    assert found[0].startswith("Variants/CommNotifications/App.entitlements:1: variant-parity") and "aps-environment" in found[0]


def test_a_variant_may_add_keys_the_default_lacks(tmp_path):
    extra = "\t<key>com.apple.developer.associated-domains</key>\n\t<array/>\n"
    assert cse.scan(tree(tmp_path, {"Variants/CommNotifications/App.entitlements": plist(APS, COMM, GROUP, extra)})) == []


def test_a_missing_entitlements_file_fails(tmp_path):
    root = tree(tmp_path)
    (root / "App/App-macOS.entitlements").unlink()
    found = cse.scan(root)
    assert len(found) == 1 and "entitlements-missing" in found[0] and "App/App-macOS.entitlements" in found[0]


def test_main_exits_nonzero_and_names_the_switch(tmp_path, capsys):
    root = tree(tmp_path, {"App/App.entitlements": plist(APS, COMM)})
    assert cse.main(["check", str(root)]) == 1
    assert "PAL_COMM_NOTIFICATIONS=1" in capsys.readouterr().out
    clean = tree(tmp_path / "clean")
    assert cse.main(["check", str(clean)]) == 0
