from __future__ import annotations

from typing import Optional, Sequence

from tools.connectors import hosted_surface
from tools.connectors.contract import TargetState, allowed
from tools.connectors.operation import ConnectionOperation
from tools.connectors.run import (
    LINK_STILL_VALID,
    MIXED_KINDS,
    NOT_ALLOWED,
    REFUSED,
    SETTLED,
    UNKNOWN_TARGET,
)


def reissue(operation: ConnectionOperation, names: Sequence[str], *, initiator: Optional[str] = None) -> Optional[str]:
    targets = [operation.target(name) for name in names]
    if any(target is None for target in targets):
        return UNKNOWN_TARGET
    if len({target.kind for target in targets}) != 1:
        return MIXED_KINDS
    stale = [target.name for target in targets if target.state in (TargetState.failed, TargetState.expired)]
    if len(stale) != len(targets):
        return LINK_STILL_VALID
    if operation.settled:
        return SETTLED
    if any(allowed(target.kind, target.state, TargetState.initiated) is None for target in targets):
        return NOT_ALLOWED
    if targets[0].kind == "connector":
        if not hosted_surface.installed():
            return NOT_ALLOWED
        hosted_surface.reissue(operation, stale, initiator)
        return None
    from tools.connectors import catalog
    from tools.connectors.mcp import retry

    rerun = catalog.retry if catalog.owns(operation.op_id) else retry
    return REFUSED if rerun(operation, stale) else None
