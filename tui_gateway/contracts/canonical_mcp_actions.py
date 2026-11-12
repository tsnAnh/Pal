from __future__ import annotations

from pydantic import Field

from .base import Params, Result
from .registry import canonical_method

MCP_SERVER_NAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"


class McpAutoApproveGetParams(Params):
    session_id: str = Field(min_length=1)
    server: str = Field(pattern=MCP_SERVER_NAME_PATTERN)


class McpAutoApproveGetResult(Result):
    enabled: bool
    eligible: bool


class McpAutoApproveSetParams(McpAutoApproveGetParams):
    enabled: bool


class McpAutoApproveSetResult(Result):
    enabled: bool


canonical_method("mcp.actions.auto_approve.get", params=McpAutoApproveGetParams, result=McpAutoApproveGetResult,
                 doc="Whether actions on an action-gated MCP server skip the approval card in this chat. eligible: "
                     "the chat is one of the owner's own app chats and the server is action-gated; enabled is false "
                     "whenever it is not eligible.")

canonical_method("mcp.actions.auto_approve.set", params=McpAutoApproveSetParams, result=McpAutoApproveSetResult,
                 doc="Turn the per-chat auto-approve switch on or off. Off by default, kept in memory for this chat "
                     "only (a new chat, a reset or a gateway restart starts off), and the only way to set it. "
                     "Refused with permission_denied unless the caller may approve in this chat and the chat is "
                     "eligible (see mcp.actions.auto_approve.get). Money steps are never auto-approved.")
