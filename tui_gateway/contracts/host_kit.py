from __future__ import annotations

from typing import Literal

from pydantic import Field

from .base import Params, Result, WireEnum
from .registry import method


class KitErrorCode(WireEnum):
    kit_unavailable = "kit_unavailable"
    kit_unsupported = "kit_unsupported"
    timeout = "timeout"
    failed = "failed"
    invalid_output = "invalid_output"
    busy = "busy"


class KitReport(Result):
    """The known fields of the kit's JSON; unknown fields are ignored."""

    version: str | None = None
    status: str | None = None
    message: str | None = None


class KitError(Result):
    code: KitErrorCode
    message: str
    subcommand: str | None = None
    tail: str | None = None


class KitJobParams(Params):
    job_id: str


class KitAddProjectParams(Params):
    repo: str = Field(max_length=100)


class KitReloadParams(Params):
    target: Literal["routes", "gateway"]


class KitJob(Result):
    job_id: str
    operation: Literal["refresh", "update", "add_project", "reload"]
    state: Literal["running", "succeeded", "failed"]
    report: KitReport | None = None
    error: KitError | None = None


method("host.kit.status", params=Params, result=KitReport,
       doc="Run `faker-kit status --json` and return its known fields. Owner-only. Error 5321 carries data "
           "(KitError): kit_unavailable, kit_unsupported, timeout, failed or invalid_output. 4403 secondary profile.")
method("host.kit.refresh", params=Params, result=KitJob,
       doc="Start `faker-kit refresh --json` as the one running kit job, or return the identical running job. "
           "Poll host.kit.job. Error 4409 (data.code busy) while a different kit job runs. 4403 secondary profile.")
method("host.kit.update", params=Params, result=KitJob,
       doc="Start `faker-kit update --json` (update to latest) as the one running kit job, or return the "
           "identical running job. 4409 busy, 4403 secondary profile.")
method("host.kit.add_project", params=KitAddProjectParams, result=KitJob,
       doc="Start `faker-kit add-project <owner/repo> --json`. The repo must be owner/repo (letters, digits, "
           "dot, dash, underscore). 4101 invalid repo, 4409 busy, 4403 secondary profile.")
method("host.kit.reload", params=KitReloadParams, result=KitJob,
       doc="Start `faker-kit reload <routes|gateway> --json`. 4409 busy, 4403 secondary profile.")
method("host.kit.job", params=KitJobParams, result=KitJob,
       doc="State of a kit job. A finished job stays readable until the next job starts. 4404 unknown job. "
           "A job cannot be cancelled.")
