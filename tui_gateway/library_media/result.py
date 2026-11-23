from __future__ import annotations

from dataclasses import dataclass

from tui_gateway.contracts.library import LibraryPreviewReason as Reason


@dataclass(frozen=True, slots=True)
class PreviewResult:
    data: bytes | None = None
    mime: str = ""
    reason: Reason | None = None
    width: int | None = None
    height: int | None = None
    duration_seconds: float | None = None

    @property
    def cacheable(self) -> bool:
        return self.data is not None or self.reason is Reason.RENDER_FAILED
