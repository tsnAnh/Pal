"""A legacy ``SessionDB`` view of a session authority's store, for Pal's fork-only gateway modules.

Upstream's storage-callers refactor replaced ``SessionAuthority.db`` (a ``SessionDB``) with ``persistence`` (the
storage interface). Pal modules that predate it still read ``authority.db``; this keeps them serving through the
SAME store holder the authority's persistence handle uses (one writer, one generation) until each is ported to the
interface. Upstream later removes ``SessionDB`` altogether: port every ``authority.db`` caller before syncing past it.
"""

from __future__ import annotations


def authority_session_db(authority):
    """The ``SessionDB`` serving through *authority*'s store holder (lent by the process registry, never closed here)."""
    from hermes_state_registry import _lend
    from gateway.session_persistence import authority_persistence
    store = authority_persistence(authority)
    bound = store._bound_store() if hasattr(store, "_bound_store") else store  # an assembly handle, or a bare store
    return _lend(bound.holder())
