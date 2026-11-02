from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import pytest

from tests.e2e.core.bots._world import ALL_WORLDS


@pytest.fixture(autouse=True, scope="module")
def stop_owner_gateways():
    yield
    homes = [(world, bot) for world in ALL_WORLDS for bot in world.owner_bots()]
    ALL_WORLDS.clear()
    if homes:
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda wb: wb[0].hermes(wb[1], "gateway", "stop", timeout=90), homes))
