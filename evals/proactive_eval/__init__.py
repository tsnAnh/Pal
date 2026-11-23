"""Offline measurement kit for the "proactive first" principle (no model call happens at import).

- ``rubric``: the versioned rubric (``rubric.json``) and the deterministic label from criteria.
- ``patterns``: question detection, criterion lexicons and owner-correction pattern classes.
- ``mining``: read-only transcript miner that emits counts and pattern ids per bot and week.
- ``scenario``: replay scenario schema, validator and the tune / held-out split loader.
- ``models``: bot and judge protocols, stubs, the model-family check and the repo-client adapters.
- ``replay``: simulated owner, scenario runner, scoring, paired comparison, spot-check list, held-out ledger.
- ``variants``: prompt variants under test (``variants.json``).
- ``prompt_surface``: anti-pattern and clarify checks the CI regression test applies.
- ``cli``: ``python -m evals.proactive_eval``.
"""
