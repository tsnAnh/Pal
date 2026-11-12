from __future__ import annotations

from pydantic import Field

from .base import JsonValue, Params, Payload, Result, WireEnum
from .registry import canonical_method, event

DEVICE_ID_PATTERN = r"^[A-Za-z0-9-]{8,64}$"
REQUEST_ID_PATTERN = r"^[A-Za-z0-9-]{8,64}$"


class DeviceConnectorId(WireEnum):
    CALENDAR = "calendar"
    HOME = "home"
    REMINDERS = "reminders"
    CONTACTS = "contacts"
    LOCATION = "location"
    ALARMS = "alarms"
    SHELL = "shell"
    FILES = "files"
    INPUT = "input"
    SCREEN = "screen"
    NOTIFICATIONS = "notifications"
    CLIPBOARD = "clipboard"
    APPS = "apps"


class DeviceConnectorState(WireEnum):
    ALLOWED = "allowed"
    ASK = "ask"
    OFF = "off"


class DeviceOsPermission(WireEnum):
    GRANTED = "granted"
    DENIED = "denied"
    NOT_DETERMINED = "not_determined"
    UNSUPPORTED = "unsupported"


class DeviceToolAction(WireEnum):
    CALENDAR_LIST_EVENTS = "calendar.list_events"
    CALENDAR_ADD_EVENT = "calendar.add_event"
    REMINDERS_LIST = "reminders.list"
    REMINDERS_ADD = "reminders.add"
    REMINDERS_COMPLETE = "reminders.complete"
    CONTACTS_SEARCH = "contacts.search"
    LOCATION_CURRENT = "location.current"
    LOCATION_SEARCH_NEARBY = "location.search_nearby"
    ALARMS_SET = "alarms.set"
    ALARMS_LIST = "alarms.list"
    TIMERS_START = "timers.start"
    HOME_LIST_ACCESSORIES = "home.list_accessories"
    HOME_SET = "home.set"
    SHELL_RUN = "shell.run"
    FILES_READ = "files.read"
    FILES_LIST = "files.list"
    FILES_WRITE = "files.write"
    INPUT_DISPLAYS = "input.displays"
    INPUT_MOVE = "input.move"
    INPUT_CLICK = "input.click"
    INPUT_DRAG = "input.drag"
    INPUT_SCROLL = "input.scroll"
    INPUT_TYPE = "input.type"
    INPUT_KEY = "input.key"
    SCREEN_CAPTURE = "screen.capture"
    SCREEN_READ = "screen.read"
    NOTIFY_POST = "notify.post"
    NOTIFY_CANCEL = "notify.cancel"
    CLIPBOARD_READ = "clipboard.read"
    CLIPBOARD_WRITE = "clipboard.write"
    APPS_LIST = "apps.list"
    APPS_OPEN = "apps.open"
    APPS_QUIT = "apps.quit"
    WINDOWS_LIST = "windows.list"
    WINDOWS_FOCUS = "windows.focus"


class DeviceToolErrorCode(WireEnum):
    PERMISSION_DENIED = "permission_denied"
    CONSENT_DECLINED = "consent_declined"
    UNSUPPORTED = "unsupported"
    INVALID_ARGS = "invalid_args"
    NOT_FOUND = "not_found"
    FAILED = "failed"


class DeviceToolCancelReason(WireEnum):
    TIMEOUT = "timeout"
    INTERRUPTED = "interrupted"
    DISCONNECTED = "disconnected"


class DeviceConnectorStatus(Result):
    id: DeviceConnectorId
    title: str
    subtitle: str
    state: DeviceConnectorState
    os_permission: DeviceOsPermission


class DeviceConnectorsResult(Result):
    device_id: str
    connectors: list[DeviceConnectorStatus]


class DeviceConnectorsListParams(Params):
    device_id: str | None = Field(default=None, pattern=DEVICE_ID_PATTERN)


canonical_method("device_connectors.list", params=DeviceConnectorsListParams, result=DeviceConnectorsResult,
                 doc="The device connectors of one declared device (default: the calling connection's own, set "
                     "by client.hello). state is the user's choice and defaults to ask; os_permission is what the "
                     "phone last reported.")


class DeviceConnectorsSetParams(Params):
    id: DeviceConnectorId
    state: DeviceConnectorState | None = None
    os_permission: DeviceOsPermission | None = None
    device_id: str | None = Field(default=None, pattern=DEVICE_ID_PATTERN)


canonical_method("device_connectors.set", params=DeviceConnectorsSetParams, result=DeviceConnectorsResult,
                 doc="Persist one connector's state and/or the OS permission the phone observed. At least one of "
                     "state or os_permission is required; os_permission may only be reported for the calling "
                     "connection's own device.")


class DeviceToolError(Params):
    code: DeviceToolErrorCode
    message: str = Field(default="", max_length=300)


class DeviceToolRespondParams(Params):
    request_id: str = Field(pattern=REQUEST_ID_PATTERN)
    ok: bool
    result: JsonValue = None
    error: DeviceToolError | None = None


class DeviceToolRespondResult(Result):
    recorded: bool


canonical_method("device.tool.respond", params=DeviceToolRespondParams, result=DeviceToolRespondResult,
                 doc="Answer a device.tool.request from the connection that received it: ok true carries result "
                     "(an object shaped for the action), ok false carries error. recorded is false for an unknown, "
                     "expired, already answered or foreign request.")


class DeviceToolRequestPayload(Payload):
    request_id: str
    action: DeviceToolAction
    connector: DeviceConnectorId
    args: JsonValue
    needs_consent: bool
    profile: str
    session_id: str | None = None
    deadline_seconds: int


event("device.tool.request", DeviceToolRequestPayload,
      doc="The bot asks this iPhone to run one action on the device (EventKit, HomeKit, Contacts, CoreLocation, "
          "AlarmKit). Answer device.tool.respond before deadline_seconds. needs_consent means the connector's "
          "state is ask: show a consent prompt first, persist the choice with device_connectors.set, and answer "
          "consent_declined if the user refuses.")


class DeviceToolCancelPayload(Payload):
    request_id: str
    reason: DeviceToolCancelReason


event("device.tool.cancel", DeviceToolCancelPayload,
      doc="A device.tool.request is no longer wanted; dismiss any prompt for it. A late respond is ignored.")
