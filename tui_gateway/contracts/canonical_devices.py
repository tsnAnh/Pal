from __future__ import annotations

from typing import Literal

from pydantic import Field

from .base import Params, Result
from .canonical_reach import ClientKind
from .registry import canonical_method

DEVICE_ID_PATTERN = r"^[A-Za-z0-9-]{8,64}$"


class DeviceRow(Result):
    device_id: str
    kind: ClientKind
    label: str
    model: str | None = None
    os: str | None = None
    this_device: bool
    online: bool
    last_seen_at: str
    push_enabled: bool


class DevicesListParams(Params):
    pass


class DevicesListResult(Result):
    devices: list[DeviceRow]


canonical_method("devices.list", params=DevicesListParams, result=DevicesListResult,
                 doc="Every device the user has connected on this install, newest first. online is live "
                     "presence; last_seen_at survives restarts; push_enabled needs a registered token and a "
                     "configured push provider.")


class DevicesForgetParams(Params):
    device_id: str = Field(pattern=DEVICE_ID_PATTERN)
    confirm_self: bool = False


class DevicesForgetResult(Result):
    forgotten: bool
    grants_revoked: int
    push_removed: bool


canonical_method("devices.forget", params=DevicesForgetParams, result=DevicesForgetResult,
                 doc="Revoke the device's sign-in grants and push token, drop its row and close its live "
                     "connections. Forgetting the calling device answers confirm_required unless "
                     "confirm_self is true.")


class PushRegisterParams(Params):
    device_id: str = Field(pattern=DEVICE_ID_PATTERN)
    apns_token: str = Field(pattern=r"^[0-9A-Fa-f]{32,200}$")
    environment: Literal["sandbox", "production"]
    bundle_id: str = Field(pattern=r"^[A-Za-z0-9.-]{3,155}$")


class PushRegisterResult(Result):
    registered: bool
    push_enabled: bool


canonical_method("push.register", params=PushRegisterParams, result=PushRegisterResult,
                 doc="Store this device's APNs token. device_id must be the id declared by client.hello on "
                     "this connection. push_enabled is false while the install has no push credentials.")


class PushUnregisterParams(Params):
    device_id: str = Field(pattern=DEVICE_ID_PATTERN)


class PushUnregisterResult(Result):
    removed: bool


canonical_method("push.unregister", params=PushUnregisterParams, result=PushUnregisterResult,
                 doc="Remove this device's APNs token; removed is false when none was stored.")
