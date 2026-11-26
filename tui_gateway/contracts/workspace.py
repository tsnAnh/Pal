from __future__ import annotations

from .library import AssetReadParams, LibraryAssetResult
from .registry import method


class WorkspaceFileParams(AssetReadParams):
    ref: str
    thumbnail: bool = False


method("workspace.file", params=WorkspaceFileParams, result=LibraryAssetResult,
       doc="Bytes, a preview image or one range of a file under the bot's workspace that one of its messages "
           "mentions, named by the `ref` of that message's `file_refs`. The payload, caps and range rules are "
           "`library.asset`'s; `thumbnail` is off unless asked. A ref lives until the gateway restarts; reading "
           "the transcript again issues it again. Errors: 4151 unknown ref or file gone, 4152 larger than the "
           "limit (data: size, limit), 4153 invalid request, 4154 the file is no longer servable, "
           "5151 temporary internal failure.")
