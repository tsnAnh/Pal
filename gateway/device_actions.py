from __future__ import annotations

import json
import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Annotated, Any, ClassVar, Literal

from pydantic import AfterValidator, BaseModel, BeforeValidator, ConfigDict, Field, model_validator

from tools.ansi_strip import strip_unicode_tags
from tui_gateway.contracts.canonical_device import DeviceConnectorId as Connector

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f  ‪-‮⁦-⁩]")


APPLE_KINDS = frozenset({"ios", "mac"})
MAC_ONLY = frozenset({"mac"})
MAX_PATH_CHARS = 1000
MAX_APPS = 200
MAX_WINDOWS = 200
SHELL_DEFAULT_TIMEOUT_SECONDS = 30
SHELL_MAX_TIMEOUT_SECONDS = 300
INPUT_MAX_TYPED_CHARS = 500
INPUT_MAX_SCROLL_LINES = 50
INPUT_MAX_COORDINATE = 100_000
INPUT_MAX_CALLS_PER_MINUTE = 60
CLIPBOARD_TEXT_CHARS = 24_000
CLIPBOARD_WRITE_CHARS = 100_000
CLIPBOARD_IMAGE_BASE64_CHARS = 65_536
TEXT_MARKER = "\n…[truncated, {omitted} characters omitted]"


@dataclass(frozen=True, slots=True)
class ConnectorInfo:
    connector: Connector
    title: str
    subtitle: str
    kinds: frozenset[str] = APPLE_KINDS
    on_by_default: bool = True


CONNECTOR_CATALOG: tuple[ConnectorInfo, ...] = (
    ConnectorInfo(Connector.CALENDAR, "Calendar", "See your day and add events"),
    ConnectorInfo(Connector.HOME, "Home", "Control lights, locks and more"),
    ConnectorInfo(Connector.REMINDERS, "Reminders", "Set and check reminders"),
    ConnectorInfo(Connector.CONTACTS, "Contacts", "Look up people you know"),
    ConnectorInfo(Connector.LOCATION, "Location", "Find places near you"),
    ConnectorInfo(Connector.ALARMS, "Alarms", "Set alarms and timers"),
    ConnectorInfo(Connector.SHELL, "Run commands", "Let bots run commands on this Mac", MAC_ONLY, False),
    ConnectorInfo(Connector.FILES, "Files", "Let bots read and change files on this Mac", MAC_ONLY, False),
    ConnectorInfo(Connector.INPUT, "Mouse and keyboard", "Let bots control this Mac's mouse and keyboard", MAC_ONLY, False),
    ConnectorInfo(Connector.CLIPBOARD, "Clipboard", "Let bots read and change this Mac's clipboard", MAC_ONLY, False),
    ConnectorInfo(Connector.APPS, "Apps", "Let bots open and switch apps on this Mac", MAC_ONLY, False),
)


def connector_info(connector: Connector) -> ConnectorInfo:
    return next(info for info in CONNECTOR_CATALOG if info.connector is connector)


def clean_text(value: str, limit: int) -> str:
    text = _CONTROL.sub("", strip_unicode_tags(value)).replace("\r\n", "\n").replace("\r", "\n")
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def cap_text(value: str, limit: int) -> tuple[str, bool]:
    text = _CONTROL.sub("", strip_unicode_tags(value)).replace("\r\n", "\n").replace("\r", "\n")
    if len(text) <= limit:
        return text, False
    return text[:limit] + TEXT_MARKER.format(omitted=len(text) - limit), True


def _clipped(limit: int):
    return BeforeValidator(lambda value: clean_text(value, limit) if isinstance(value, str) else value)


def _first(limit: int):
    return BeforeValidator(lambda value: value[:limit] if isinstance(value, list) else value)


def _iso(value: str) -> str:
    datetime.fromisoformat(value)
    return value


def _absolute_path(value: str) -> str:
    if "\x00" in value:
        raise ValueError("path must not contain a NUL character")
    if not (value.startswith("/") or value == "~" or value.startswith("~/")):
        raise ValueError("path must be absolute or start with ~/")
    return value


Short = Annotated[str, _clipped(200)]
FilePath = Annotated[str, Field(min_length=1, max_length=MAX_PATH_CHARS), AfterValidator(_absolute_path)]
Long = Annotated[str, _clipped(1000)]
Identifier = Annotated[str, Field(min_length=1, max_length=200)]
IsoDateTime = Annotated[str, Field(min_length=10, max_length=40), AfterValidator(_iso)]
Weekday = Literal["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


class _Args(BaseModel):
    model_config = ConfigDict(extra="forbid")


class _Data(BaseModel):
    model_config = ConfigDict(extra="ignore")


class CalendarListEventsArgs(_Args):
    start: IsoDateTime
    end: IsoDateTime
    limit: int = Field(default=50, ge=1, le=100)

    @model_validator(mode="after")
    def _ordered(self):
        start, end = datetime.fromisoformat(self.start), datetime.fromisoformat(self.end)
        if (start.tzinfo is None) == (end.tzinfo is None) and end <= start:
            raise ValueError("end must be after start")
        return self


class CalendarAddEventArgs(_Args):
    title: str = Field(min_length=1, max_length=200)
    start: IsoDateTime
    end: IsoDateTime | None = None
    all_day: bool = False
    location: str | None = Field(default=None, max_length=200)
    notes: str | None = Field(default=None, max_length=2000)
    calendar: str | None = Field(default=None, max_length=100)
    alert_minutes_before: int | None = Field(default=None, ge=0, le=10080)


class RemindersListArgs(_Args):
    list: str | None = Field(default=None, max_length=100)
    include_completed: bool = False
    limit: int = Field(default=50, ge=1, le=100)


class RemindersAddArgs(_Args):
    title: str = Field(min_length=1, max_length=200)
    due: IsoDateTime | None = None
    notes: str | None = Field(default=None, max_length=2000)
    list: str | None = Field(default=None, max_length=100)
    priority: Literal["none", "low", "medium", "high"] = "none"


class RemindersCompleteArgs(_Args):
    reminder_id: Identifier


class ContactsSearchArgs(_Args):
    query: str = Field(min_length=1, max_length=100)
    limit: int = Field(default=10, ge=1, le=25)


class LocationCurrentArgs(_Args):
    accuracy: Literal["approximate", "precise"] = "approximate"


class LocationSearchNearbyArgs(_Args):
    query: str = Field(min_length=1, max_length=100)
    radius_meters: int = Field(default=2000, ge=100, le=50000)
    limit: int = Field(default=10, ge=1, le=25)


class AlarmsSetArgs(_Args):
    at: IsoDateTime
    label: str | None = Field(default=None, max_length=100)
    repeat_weekdays: list[Weekday] = Field(default_factory=list, max_length=7)


class AlarmsListArgs(_Args):
    pass


class TimersStartArgs(_Args):
    seconds: int = Field(ge=1, le=86400)
    label: str | None = Field(default=None, max_length=100)


class HomeListAccessoriesArgs(_Args):
    room: str | None = Field(default=None, max_length=100)


class HomeSetArgs(_Args):
    accessory_id: Identifier
    characteristic: Literal["power", "brightness", "lock", "target_temperature"]
    value: bool | int | float

    @model_validator(mode="after")
    def _fits_characteristic(self):
        boolean = isinstance(self.value, bool)
        if self.characteristic in ("power", "lock") and not boolean:
            raise ValueError(f"{self.characteristic} takes true or false")
        if self.characteristic == "brightness" and (boolean or not 0 <= self.value <= 100):
            raise ValueError("brightness takes a number from 0 to 100")
        if self.characteristic == "target_temperature" and (boolean or not 5 <= self.value <= 40):
            raise ValueError("target_temperature takes degrees Celsius from 5 to 40")
        return self


class ShellRunArgs(_Args):
    command: str = Field(min_length=1, max_length=8000)
    cwd: FilePath | None = None
    timeout_seconds: int = Field(default=SHELL_DEFAULT_TIMEOUT_SECONDS, ge=1, le=SHELL_MAX_TIMEOUT_SECONDS)

    @model_validator(mode="after")
    def _has_command(self):
        if not self.command.strip() or "\x00" in self.command:
            raise ValueError("command must be a non-empty string without NUL characters")
        return self


class FilesReadArgs(_Args):
    path: FilePath


class FilesListArgs(_Args):
    path: FilePath
    limit: int = Field(default=200, ge=1, le=500)


class FilesWriteArgs(_Args):
    path: FilePath
    content: str = Field(max_length=200_000)
    append: bool = False
    create_dirs: bool = False


Coordinate = Annotated[float, Field(ge=-INPUT_MAX_COORDINATE, le=INPUT_MAX_COORDINATE, allow_inf_nan=False)]
MouseButton = Literal["left", "right", "middle"]


class _Point(_Args):
    x: Coordinate | None = None
    y: Coordinate | None = None
    display: int | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def _both_or_neither(self):
        if (self.x is None) != (self.y is None):
            raise ValueError("pass x and y together")
        return self


class InputDisplaysArgs(_Args):
    pass


class InputMoveArgs(_Point):
    dx: Coordinate | None = None
    dy: Coordinate | None = None

    @model_validator(mode="after")
    def _absolute_or_relative(self):
        relative = self.dx is not None or self.dy is not None
        if relative and (self.dx is None or self.dy is None or self.x is not None):
            raise ValueError("pass either x and y, or dx and dy")
        if not relative and self.x is None:
            raise ValueError("pass x and y, or dx and dy")
        return self


class InputClickArgs(_Point):
    button: MouseButton = "left"
    clicks: Literal[1, 2] = 1


class InputDragArgs(_Args):
    from_x: Coordinate
    from_y: Coordinate
    to_x: Coordinate
    to_y: Coordinate
    display: int | None = Field(default=None, ge=0)
    button: MouseButton = "left"


class InputScrollArgs(_Point):
    dx: int = Field(default=0, ge=-INPUT_MAX_SCROLL_LINES, le=INPUT_MAX_SCROLL_LINES)
    dy: int = Field(default=0, ge=-INPUT_MAX_SCROLL_LINES, le=INPUT_MAX_SCROLL_LINES)

    @model_validator(mode="after")
    def _scrolls(self):
        if self.dx == 0 and self.dy == 0:
            raise ValueError("dx or dy must not be 0")
        return self


class InputTypeArgs(_Args):
    text: str = Field(min_length=1, max_length=INPUT_MAX_TYPED_CHARS)

    @model_validator(mode="after")
    def _printable(self):
        if "\x00" in self.text:
            raise ValueError("text must not contain NUL characters")
        return self


class InputKeyArgs(_Args):
    key: str = Field(min_length=1, max_length=40, pattern=r"^\S+$")


class ClipboardReadArgs(_Args):
    include_image: bool = False


class ClipboardWriteArgs(_Args):
    text: str | None = Field(default=None, min_length=1, max_length=CLIPBOARD_WRITE_CHARS)
    image_base64: str | None = Field(default=None, min_length=1, max_length=CLIPBOARD_IMAGE_BASE64_CHARS)

    @model_validator(mode="after")
    def _one_kind(self):
        if (self.text is None) == (self.image_base64 is None):
            raise ValueError("pass exactly one of text or image_base64")
        return self


class AppsListArgs(_Args):
    limit: int = Field(default=MAX_APPS, ge=1, le=MAX_APPS)


class AppsOpenArgs(_Args):
    app: str = Field(min_length=1, max_length=200)
    target: str | None = Field(default=None, min_length=1, max_length=MAX_PATH_CHARS)


class AppsQuitArgs(_Args):
    app: str = Field(min_length=1, max_length=200)


class WindowsListArgs(_Args):
    app: str | None = Field(default=None, min_length=1, max_length=200)
    on_screen_only: bool = False
    limit: int = Field(default=MAX_WINDOWS, ge=1, le=MAX_WINDOWS)


class WindowsFocusArgs(_Args):
    window_id: int | None = Field(default=None, ge=0)
    app: str | None = Field(default=None, min_length=1, max_length=200)

    @model_validator(mode="after")
    def _names_a_target(self):
        if self.window_id is None and self.app is None:
            raise ValueError("pass window_id or app")
        return self


class CalendarEvent(_Data):
    id: Identifier
    title: Short
    start: IsoDateTime
    end: IsoDateTime | None = None
    all_day: bool = False
    location: Short | None = None
    calendar: Short | None = None
    notes: Long | None = None


class Reminder(_Data):
    id: Identifier
    title: Short
    due: IsoDateTime | None = None
    completed: bool = False
    list: Short | None = None
    notes: Long | None = None
    priority: Literal["none", "low", "medium", "high"] = "none"


class Contact(_Data):
    id: Identifier
    name: Short
    organization: Short | None = None
    phones: Annotated[list[Annotated[str, _clipped(40)]], _first(5)] = Field(default_factory=list)
    emails: Annotated[list[Annotated[str, _clipped(120)]], _first(5)] = Field(default_factory=list)


class Place(_Data):
    name: Short
    address: Short | None = None
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    distance_meters: float | None = Field(default=None, ge=0)
    category: Short | None = None
    phone: Annotated[str, _clipped(40)] | None = None


class Alarm(_Data):
    id: Identifier
    label: Short | None = None
    at: IsoDateTime
    enabled: bool = True
    repeat_weekdays: list[Weekday] = Field(default_factory=list, max_length=7)


class Timer(_Data):
    id: Identifier
    label: Short | None = None
    seconds: int = Field(ge=1, le=86400)
    ends_at: IsoDateTime


class Accessory(_Data):
    id: Identifier
    name: Short
    room: Short | None = None
    category: Short | None = None
    reachable: bool = True
    state: dict[Annotated[str, _clipped(40)], bool | int | float | Annotated[str, _clipped(80)]] = Field(
        default_factory=dict, max_length=12)


class CalendarEventsResult(_Data):
    events: Annotated[list[CalendarEvent], _first(100)]


class CalendarEventResult(_Data):
    event: CalendarEvent


class RemindersResult(_Data):
    reminders: Annotated[list[Reminder], _first(100)]


class ReminderResult(_Data):
    reminder: Reminder


class ContactsResult(_Data):
    contacts: Annotated[list[Contact], _first(25)]


class LocationCurrentResult(_Data):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    accuracy_meters: float | None = Field(default=None, ge=0)
    place: Short | None = None
    timestamp: IsoDateTime | None = None


class PlacesResult(_Data):
    places: Annotated[list[Place], _first(25)]


class AlarmResult(_Data):
    alarm: Alarm


class AlarmsResult(_Data):
    alarms: Annotated[list[Alarm], _first(50)]


class TimerResult(_Data):
    timer: Timer


class AccessoriesResult(_Data):
    accessories: Annotated[list[Accessory], _first(100)]


class AccessoryResult(_Data):
    accessory: Accessory


class InputDisplay(_Data):
    id: int = Field(ge=0)
    name: Short | None = None
    main: bool = False
    x: float
    y: float
    width: float = Field(ge=0)
    height: float = Field(ge=0)
    scale: float = Field(gt=0)


class InputDisplaysResult(_Data):
    displays: Annotated[list[InputDisplay], _first(16)]
    pointer_x: float
    pointer_y: float


class InputResult(_Data):
    events: int = Field(ge=0)
    pointer_x: float | None = None
    pointer_y: float | None = None


class _Capped(_Data):
    text_limits: ClassVar[dict[str, int]] = {}
    truncated: bool = False

    @model_validator(mode="before")
    @classmethod
    def _cap(cls, raw):
        if not isinstance(raw, dict):
            return raw
        data, cut = dict(raw), raw.get("truncated") is True
        for name, limit in cls.text_limits.items():
            if isinstance(data.get(name), str):
                data[name], clipped = cap_text(data[name], limit)
                cut = cut or clipped
        data["truncated"] = cut
        return data


class ShellRunResult(_Capped):
    text_limits: ClassVar[dict[str, int]] = {"stdout": 48_000, "stderr": 48_000}
    exit_code: int | None = None
    stdout: str = ""
    stderr: str = ""
    timed_out: bool = False


class FilesReadResult(_Capped):
    text_limits: ClassVar[dict[str, int]] = {"content": 96_000}
    path: Long
    content: str
    size_bytes: int = Field(ge=0)


class FileEntry(_Data):
    name: Short
    kind: Literal["file", "directory", "symlink", "other"] = "other"
    size_bytes: int | None = Field(default=None, ge=0)
    modified_at: IsoDateTime | None = None


class FilesListResult(_Capped):
    path: Long
    entries: Annotated[list[FileEntry], _first(500)]


class FilesWriteResult(_Data):
    path: Long
    bytes_written: int = Field(ge=0)


class ClipboardReadResult(_Capped):
    text_limits: ClassVar[dict[str, int]] = {"text": CLIPBOARD_TEXT_CHARS}
    types: Annotated[list[Annotated[str, _clipped(40)]], _first(20)] = Field(default_factory=list)
    concealed: bool = False
    text: str | None = None
    image_base64: str | None = Field(default=None, max_length=CLIPBOARD_IMAGE_BASE64_CHARS)
    image_mime: Annotated[str, _clipped(40)] | None = None
    image_bytes: int | None = Field(default=None, ge=0)


class ClipboardWriteResult(_Data):
    kind: Literal["text", "image"]
    size: int = Field(ge=0)


class AppInfo(_Data):
    name: Short
    bundle_id: Short | None = None
    pid: int = Field(ge=0)
    frontmost: bool = False


class AppsResult(_Data):
    apps: Annotated[list[AppInfo], _first(MAX_APPS)]
    truncated: bool = False


class AppOpenResult(_Data):
    app: AppInfo
    launched: bool = False


class AppQuitResult(_Data):
    app: AppInfo
    quit_requested: bool = True


class WindowFrame(_Data):
    x: float
    y: float
    width: float = Field(ge=0)
    height: float = Field(ge=0)


class WindowInfo(_Data):
    window_id: int = Field(ge=0)
    app: Short
    pid: int = Field(ge=0)
    title: Short | None = None
    frame: WindowFrame | None = None
    on_screen: bool = True


class WindowsResult(_Data):
    windows: Annotated[list[WindowInfo], _first(MAX_WINDOWS)]
    titles_available: bool = False
    truncated: bool = False
    note: Short | None = None


class WindowsFocusResult(_Data):
    app: AppInfo
    window_id: int | None = Field(default=None, ge=0)
    raised: bool = False
    note: Short | None = None


def fit_result(data: dict, limit: int) -> dict:
    fitted = dict(data)
    while len(json.dumps(fitted, ensure_ascii=False)) > limit:
        names = [name for name, value in fitted.items() if isinstance(value, str) and len(value) > 64]
        if not names:
            break
        name = max(names, key=lambda key: len(fitted[key]))
        fitted[name] = cap_text(fitted[name], len(fitted[name]) * 3 // 4)[0]
        fitted["truncated"] = True
    return fitted


def _quoted(text: str) -> str:
    return f'"{clean_text(text, 80)}"'


@dataclass(frozen=True, slots=True)
class ActionSpec:
    name: str
    connector: Connector
    write: bool
    purpose: str
    args: type[_Args]
    result: type[_Data]
    describe: Callable[[Any], str]
    kinds: frozenset[str] = APPLE_KINDS

    @property
    def truncates(self) -> bool:
        return issubclass(self.result, _Capped)


def _spec(name: str, connector: Connector, write: bool, purpose: str, args: type[_Args], result: type[_Data],
          describe: Callable[[Any], str], kinds: frozenset[str] = APPLE_KINDS) -> tuple[str, ActionSpec]:
    return name, ActionSpec(name, connector, write, purpose, args, result, describe, kinds)


ACTIONS: dict[str, ActionSpec] = dict([
    _spec("calendar.list_events", Connector.CALENDAR, False, "list events between start and end",
          CalendarListEventsArgs, CalendarEventsResult, lambda a: f"Read calendar events from {a.start} to {a.end}"),
    _spec("calendar.add_event", Connector.CALENDAR, True, "add a calendar event",
          CalendarAddEventArgs, CalendarEventResult,
          lambda a: f"Add the calendar event {_quoted(a.title)} starting {a.start}"
                    + (f" at {_quoted(a.location)}" if a.location else "")),
    _spec("reminders.list", Connector.REMINDERS, False, "list reminders",
          RemindersListArgs, RemindersResult, lambda a: "Read reminders"),
    _spec("reminders.add", Connector.REMINDERS, True, "add a reminder",
          RemindersAddArgs, ReminderResult,
          lambda a: f"Add the reminder {_quoted(a.title)}" + (f" due {a.due}" if a.due else "")),
    _spec("reminders.complete", Connector.REMINDERS, True, "mark a reminder completed by its id",
          RemindersCompleteArgs, ReminderResult, lambda a: f"Mark reminder {_quoted(a.reminder_id)} as completed"),
    _spec("contacts.search", Connector.CONTACTS, False, "search contacts by name",
          ContactsSearchArgs, ContactsResult, lambda a: f"Search contacts for {_quoted(a.query)}"),
    _spec("location.current", Connector.LOCATION, False, "get the phone's current location",
          LocationCurrentArgs, LocationCurrentResult, lambda a: "Read the current location"),
    _spec("location.search_nearby", Connector.LOCATION, False, "find places near the phone",
          LocationSearchNearbyArgs, PlacesResult, lambda a: f"Search for {_quoted(a.query)} near the current location"),
    _spec("alarms.set", Connector.ALARMS, True, "set an alarm",
          AlarmsSetArgs, AlarmResult,
          lambda a: f"Set an alarm for {a.at}" + (f" labelled {_quoted(a.label)}" if a.label else "")),
    _spec("alarms.list", Connector.ALARMS, False, "list alarms",
          AlarmsListArgs, AlarmsResult, lambda a: "Read alarms"),
    _spec("timers.start", Connector.ALARMS, True, "start a countdown timer",
          TimersStartArgs, TimerResult,
          lambda a: f"Start a {a.seconds} second timer" + (f" labelled {_quoted(a.label)}" if a.label else "")),
    _spec("home.list_accessories", Connector.HOME, False, "list home accessories and their state",
          HomeListAccessoriesArgs, AccessoriesResult, lambda a: "Read home accessories"),
    _spec("home.set", Connector.HOME, True, "change one accessory characteristic",
          HomeSetArgs, AccessoryResult,
          lambda a: f"Set {a.characteristic} of home accessory {_quoted(a.accessory_id)} to {a.value}"),
    _spec("shell.run", Connector.SHELL, True,
          "run a shell command in the user's login shell and return exit code, stdout and stderr",
          ShellRunArgs, ShellRunResult, lambda a: f"Run the command {_quoted(a.command)}", MAC_ONLY),
    _spec("files.read", Connector.FILES, False, "read a text file by absolute or ~/ path",
          FilesReadArgs, FilesReadResult, lambda a: f"Read the file {_quoted(a.path)}", MAC_ONLY),
    _spec("files.list", Connector.FILES, False, "list the entries of a directory",
          FilesListArgs, FilesListResult, lambda a: f"List the folder {_quoted(a.path)}", MAC_ONLY),
    _spec("files.write", Connector.FILES, True, "write or append text to a file",
          FilesWriteArgs, FilesWriteResult, lambda a: f"Write the file {_quoted(a.path)}", MAC_ONLY),
    _spec("input.displays", Connector.INPUT, False,
          "list the displays (id, origin x y, width, height in points, scale) and the pointer position; every "
          "coordinate is in points, origin at the top-left of the main display, y grows downward, a secondary "
          "display can have negative x or y; give `display` to make x y relative to that display's top-left; "
          "multiply by scale for pixels of a screenshot",
          InputDisplaysArgs, InputDisplaysResult, lambda a: "Read the screen sizes and pointer position", MAC_ONLY),
    _spec("input.move", Connector.INPUT, True, "move the pointer to x y (points) or by dx dy",
          InputMoveArgs, InputResult, lambda a: "Move the mouse pointer", MAC_ONLY),
    _spec("input.click", Connector.INPUT, True,
          "click button left|right|middle, clicks 1|2, at x y (points) or at the pointer when omitted",
          InputClickArgs, InputResult, lambda a: f"Click the {a.button} mouse button", MAC_ONLY),
    _spec("input.drag", Connector.INPUT, True, "press at from_x from_y, drag to to_x to_y, release",
          InputDragArgs, InputResult, lambda a: "Drag the mouse", MAC_ONLY),
    _spec("input.scroll", Connector.INPUT, True,
          f"scroll by dx dy lines (at most {INPUT_MAX_SCROLL_LINES}; dy negative scrolls down), at x y or the pointer",
          InputScrollArgs, InputResult, lambda a: "Scroll", MAC_ONLY),
    _spec("input.type", Connector.INPUT, True,
          f"type text as keystrokes into the focused field (at most {INPUT_MAX_TYPED_CHARS} characters; fails on a "
          "password field)",
          InputTypeArgs, InputResult, lambda a: f"Type {len(a.text)} characters", MAC_ONLY),
    _spec("input.key", Connector.INPUT, True, "press a key or combo such as return, escape, cmd+c, cmd+shift+4",
          InputKeyArgs, InputResult, lambda a: f"Press {_quoted(a.key)}", MAC_ONLY),
    _spec("clipboard.read", Connector.CLIPBOARD, False,
          "read the clipboard: text, and which other kinds of content it holds; include_image returns a small image",
          ClipboardReadArgs, ClipboardReadResult, lambda a: "Read the clipboard", MAC_ONLY),
    _spec("clipboard.write", Connector.CLIPBOARD, True, "replace the clipboard with text or a small image (base64)",
          ClipboardWriteArgs, ClipboardWriteResult,
          lambda a: "Replace the clipboard with " + (f"{len(a.text)} characters of text" if a.text is not None else "an image"),
          MAC_ONLY),
    _spec("apps.list", Connector.APPS, False, "list running apps (name, bundle_id, pid, frontmost; at most 200)",
          AppsListArgs, AppsResult, lambda a: "List the running apps", MAC_ONLY),
    _spec("apps.open", Connector.APPS, True,
          "open an app by bundle id or name, optionally opening a file path or URL (target) with it",
          AppsOpenArgs, AppOpenResult,
          lambda a: f"Open {_quoted(a.app)}" + (f" with {_quoted(a.target)}" if a.target else ""), MAC_ONLY),
    _spec("apps.quit", Connector.APPS, True, "ask a running app to quit normally (no force quit)",
          AppsQuitArgs, AppQuitResult, lambda a: f"Quit {_quoted(a.app)}", MAC_ONLY),
    _spec("windows.list", Connector.APPS, False,
          "list windows (app, window_id, frame, on_screen; at most 200); titles appear only when macOS allows it",
          WindowsListArgs, WindowsResult, lambda a: "List open windows", MAC_ONLY),
    _spec("windows.focus", Connector.APPS, True, "bring a window (window_id) or an app to the front",
          WindowsFocusArgs, WindowsFocusResult,
          lambda a: "Bring " + (f"window {a.window_id}" if a.window_id is not None else _quoted(a.app)) + " to the front",
          MAC_ONLY),
])


def action_catalog_text(kinds: frozenset[str] | None = None) -> str:
    lines = []
    for spec in ACTIONS.values():
        if kinds is not None and not (spec.kinds & kinds):
            continue
        fields = ", ".join(
            f"{name}{'' if field.is_required() else '?'}" for name, field in spec.args.model_fields.items())
        lines.append(f"{spec.name}({fields}): {spec.purpose}" + (" [changes the device]" if spec.write else ""))
    return "\n".join(lines)
