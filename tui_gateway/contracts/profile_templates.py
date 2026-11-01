from __future__ import annotations

from pydantic import Field

from .base import JsonValue, Result
from .common import ProfileParams
from .profiles_vault_complete_foreign_subagents import ProfileMirrored
from .registry import method


class ProfilesTemplateExportParams(ProfileParams):
    name: str | None = None


class ProfilesTemplateExportResult(Result):
    filename: str
    data: str
    size: int
    sha256: str


method("profiles.template.export", params=ProfilesTemplateExportParams, result=ProfilesTemplateExportResult,
       doc="A bot's shareable template (.hermesbot, base64): setup only, never history or secrets.")


class TemplateModelPin(Result):
    provider: str = ""
    default: str = ""


class TemplateSkill(Result):
    name: str
    files: int = 0
    has_scripts: bool = False


class TemplateMcpServer(Result):
    name: str
    transport: str = "stdio"
    command: str = ""
    url: str = ""
    enabled: bool = True
    needs: list[str] = Field(default_factory=list)


class TemplateRoutine(Result):
    name: str
    schedule: str
    prompt: str


class BotTemplateReview(Result):
    format_version: int
    created_at: str
    app_version: str
    digest: str
    size: int
    display_name: str
    description: str = ""
    suggested_name: str
    suggested_display_name: str
    soul: str = ""
    model: TemplateModelPin | None = None
    toolsets: list[str] | None = None
    skills: list[TemplateSkill] = Field(default_factory=list)
    mcp_servers: list[TemplateMcpServer] = Field(default_factory=list)
    routines: list[TemplateRoutine] = Field(default_factory=list)
    skipped_routines: list[str] = Field(default_factory=list)
    has_avatar: bool = False
    look: dict[str, JsonValue] = Field(default_factory=dict)


class ProfilesTemplateImportParams(ProfileParams):
    data: str | None = None
    dry_run: bool | str | None = None
    reviewed_digest: str | None = None
    name: str | None = None
    display_name: str | None = None
    no_alias: bool | str | None = None
    share_auth: bool | str | None = None
    mirror_credentials: bool | str | None = None


class ProfilesTemplateImportResult(Result):
    dry_run: bool
    review: BotTemplateReview | None = None
    name: str | None = None
    path: str | None = None
    display_name: str | None = None
    skills_imported: int = 0
    routines_imported: int = 0
    routines_skipped: list[str] = Field(default_factory=list)
    has_avatar: bool = False
    model_set: bool = False
    mirrored: ProfileMirrored | None = None


method("profiles.template.import", params=ProfilesTemplateImportParams, result=ProfilesTemplateImportResult,
       doc="Review a .hermesbot template (dry_run) or create the bot from the exact reviewed bytes; routines arrive paused.")
