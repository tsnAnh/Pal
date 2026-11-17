"""scripts/ci/check_swift_fault_details.py: gateway-wrapping PalKit error enums keep their GatewayFault."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_fault_details.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_fault_details as csf

NO_FAULT = '''
public enum VaultFailure: Error, Sendable, Equatable {
    case offline
    case failed

    public init(_ error: any Error) {
        guard case GatewayTransportError.rpc(let rpc) = error else { self = .offline; return }
        self = rpc.code == -32601 ? .offline : .failed
    }
}
'''
WITH_FAULT = NO_FAULT.replace("    case failed\n", "    case failed\n    case faulted(GatewayFault)\n\n"
                              "    public var fault: GatewayFault? {\n"
                              "        if case .faulted(let fault) = self { return fault }\n        return nil\n    }\n")
CARRYING = NO_FAULT.replace("Error, Sendable, Equatable {", "Error, Sendable, Equatable, FaultCarrying {")
LOCAL_ONLY = "enum PickerError: Error {\n    case cancelled\n}\n"


def _tree(tmp_path: Path, body: str) -> Path:
    path = tmp_path / csf.SOURCES / "PalVault" / "Vault.swift"
    path.parent.mkdir(parents=True)
    path.write_text(body, encoding="utf-8")
    return tmp_path


def test_a_gateway_wrapping_enum_without_a_fault_fails(tmp_path):
    found = csf.scan(_tree(tmp_path, NO_FAULT), {})
    assert len(found) == 1 and "VaultFailure" in found[0] and "Vault.swift:2" in found[0]


def test_a_fault_accessor_or_fault_carrying_conformance_passes(tmp_path):
    assert csf.scan(_tree(tmp_path / "a", WITH_FAULT), {}) == []
    assert csf.scan(_tree(tmp_path / "b", CARRYING), {}) == []


def test_an_allowlisted_enum_passes(tmp_path):
    assert csf.scan(_tree(tmp_path, NO_FAULT), {"VaultFailure": "local reason"}) == []


def test_an_enum_that_never_touches_the_gateway_is_ignored(tmp_path):
    assert csf.scan(_tree(tmp_path, LOCAL_ONLY), {}) == []


def test_an_allowlist_entry_without_a_reason_is_rejected(tmp_path):
    path = tmp_path / "allow.txt"
    path.write_text("VaultFailure:\n", encoding="utf-8")
    try:
        csf.load_allowlist(path)
    except SystemExit as exit_:
        assert "needs a reason" in str(exit_)
    else:
        raise AssertionError("an entry without a reason was accepted")


def test_the_cli_fails_on_a_finding_and_passes_on_todays_tree(tmp_path):
    run = lambda *args: subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, encoding="utf-8",
                                       timeout=60, check=False)
    failing = run(str(_tree(tmp_path, NO_FAULT)))
    assert failing.returncode == 1 and "VaultFailure" in failing.stdout
    assert run().returncode == 0
