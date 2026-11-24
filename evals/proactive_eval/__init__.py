"""Offline measurement kit for the "proactive first" principle (no model call happens at import).

The rubric, the patterns and the read-only transcript miner ship with the gateway in
``gateway/proactive_scorecard/``, which the scorecard reads live.

- ``fixture_source``: the synthetic sessions the miner's dry run reads.
- ``scenario``: replay scenario schema, validator and the tune / held-out split loader.
- ``models``: bot and judge protocols, stubs, the model-family check and the repo-client adapters.
- ``replay``: simulated owner, scenario runner, scoring, paired comparison, spot-check list, held-out ledger.
- ``variants``: prompt variants under test (``variants.json``).
- ``prompt_surface``: anti-pattern and clarify checks the CI regression test applies.
- ``cli``: ``python -m evals.proactive_eval``.
"""
