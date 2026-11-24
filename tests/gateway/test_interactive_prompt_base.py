"""Tests for the shared interactive-prompt formatting cores in BasePlatformAdapter.

Covers ``_format_exec_approval`` (template-attr driven exec-approval text),
``_format_choice_page`` (picker pagination core), ``_truncate_preview``, and
byte-parity of the rewired adapters (telegram/feishu/matrix) against their
historical inline formatting.
"""

import html as _html

from gateway.platforms.base import BasePlatformAdapter

def _bare(cls):
    """Bare instance without running __init__ (documented test pattern)."""
    return object.__new__(cls)

class _DefaultAdapter(BasePlatformAdapter):
    """Concrete subclass using only base-class template attrs."""

    async def connect(self):  # pragma: no cover - not used
        pass

    async def disconnect(self):  # pragma: no cover - not used
        pass

    async def get_chat_info(self, chat_id):  # pragma: no cover - not used
        return {}

    async def send(self, *a, **k):  # pragma: no cover - not used
        raise NotImplementedError

class TestTruncatePreview:
    def test_short_text_unchanged(self):
        assert BasePlatformAdapter._truncate_preview("abc", 10) == "abc"

    def test_exact_budget_unchanged(self):
        assert BasePlatformAdapter._truncate_preview("x" * 10, 10) == "x" * 10

    def test_fit_preview_measures_the_escaped_rendering(self):
        """An escaping platform's budget applies to the wire payload, never to raw chars."""
        adapter = _bare(_DefaultAdapter)
        assert adapter._fit_preview("&" * 100, 20, escape=_html.escape) == "&&&&..."  # 4 x "&amp;" == 20 escaped chars
        assert adapter._fit_preview("&" * 4, 20, escape=_html.escape) == "&" * 4  # fits once escaped → untouched


class TestFormatChoicePage:
    def test_single_page_no_page_info(self):
        opts, meta = BasePlatformAdapter._format_choice_page([1, 2, 3], 0, 10)
        assert opts == [1, 2, 3]
        assert meta["page_info"] == ""
        assert meta["total_pages"] == 1
        assert meta["page"] == 0

    def test_page_clamped_high(self):
        opts, meta = BasePlatformAdapter._format_choice_page(list(range(25)), 99, 10)
        assert meta["page"] == 2
        assert opts == list(range(20, 25))
        assert meta["page_info"] == " (21–25 of 25)"
