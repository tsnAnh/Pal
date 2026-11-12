from __future__ import annotations

from typing import Literal

from .base import Params, Result, WireEnum
from .registry import method


class KitErrorCode(WireEnum):
    kit_unavailable = "kit_unavailable"
    kit_unsupported = "kit_unsupported"
    timeout = "timeout"
    failed = "failed"
    invalid_output = "invalid_output"
    request_refused = "request_refused"
    busy = "busy"
    credential_missing = "credential_missing"
    credential_unreadable = "credential_unreadable"


class KitCredential(Result):
    present: bool | None = None
    created: bool | None = None
    rotated: bool | None = None
    created_at: str | None = None


class KitReport(Result):
    """The known fields of the kit's JSON; unknown fields are ignored."""

    version: str | None = None
    status: str | None = None
    message: str | None = None
    next_action: str | None = None
    credential: KitCredential | None = None


class KitError(Result):
    code: KitErrorCode
    message: str
    subcommand: str | None = None
    tail: str | None = None
    kit_code: str | None = None
    next_action: str | None = None


class KitJobParams(Params):
    job_id: str


class KitReloadParams(Params):
    target: Literal["routes", "gateway"]


class KitJob(Result):
    job_id: str
    operation: Literal["update", "reload", "rotate"]
    state: Literal["running", "succeeded", "failed"]
    report: KitReport | None = None
    error: KitError | None = None


method("host.kit.status", params=Params, result=KitReport,
       doc="Run `faker-kit host status --json --secret-stdin` and return its known fields; the app's credential is read "
           "from the host's secret file on every call and sent on stdin, never returned. Owner-only. Error 5321 carries "
           "data (KitError): kit_unavailable, kit_unsupported, timeout, failed, invalid_output, credential_missing "
           "(the first update creates it), credential_unreadable or request_refused (this machine is not set up for the "
           "app; not retried). 4409 busy (the kit is updating), 4403 secondary profile.")
method("host.kit.update", params=Params, result=KitJob,
       doc="Start `faker-kit host update --json --secret-stdin` (update to latest) as the one running kit job, or return "
           "the identical running job. With no credential file yet the first update runs without it and the kit creates "
           "one (report.credential.created). 4409 busy, 4403 secondary profile.")
method("host.kit.reload", params=KitReloadParams, result=KitJob,
       doc="Start `faker-kit host reload <routes|gateway> --json --secret-stdin`. 4409 busy, 4403 secondary profile.")
method("host.kit.rotate", params=Params, result=KitJob,
       doc="Start `faker-kit host rotate --json --secret-stdin`: replace the app's credential. The report carries "
           "credential.rotated and created_at, never the value. credential_missing before the first update. 4409 busy, "
           "4403 secondary profile.")
method("host.kit.job", params=KitJobParams, result=KitJob,
       doc="State of a kit job. A finished job stays readable until the next job starts. 4404 unknown job. "
           "A job cannot be cancelled.")
