from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import AfterValidator, BaseModel, BeforeValidator, ConfigDict, Field, model_validator

from tools.ansi_strip import strip_unicode_tags
from tui_gateway.contracts.canonical_device import DeviceConnectorId as Connector

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f  ‪-‮⁦-⁩]")


@dataclass(frozen=True, slots=True)
class ConnectorInfo:
    connector: Connector
    title: str
    subtitle: str


CONNECTOR_CATALOG: tuple[ConnectorInfo, ...] = (
    ConnectorInfo(Connector.CALENDAR, "Calendar", "See your day and add events"),
    ConnectorInfo(Connector.HOME, "Home", "Control lights, locks and more"),
    ConnectorInfo(Connector.REMINDERS, "Reminders", "Set and check reminders"),
    ConnectorInfo(Connector.CONTACTS, "Contacts", "Look up people you know"),
    ConnectorInfo(Connector.LOCATION, "Location", "Find places near you"),
    ConnectorInfo(Connector.ALARMS, "Alarms", "Set alarms and timers"),
)


def clean_text(value: str, limit: int) -> str:
    text = _CONTROL.sub("", strip_unicode_tags(value)).replace("\r\n", "\n").replace("\r", "\n")
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _clipped(limit: int):
    return BeforeValidator(lambda value: clean_text(value, limit) if isinstance(value, str) else value)


def _first(limit: int):
    return BeforeValidator(lambda value: value[:limit] if isinstance(value, list) else value)


def _iso(value: str) -> str:
    datetime.fromisoformat(value)
    return value


Short = Annotated[str, _clipped(200)]
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


def _spec(name: str, connector: Connector, write: bool, purpose: str, args: type[_Args], result: type[_Data],
          describe: Callable[[Any], str]) -> tuple[str, ActionSpec]:
    return name, ActionSpec(name, connector, write, purpose, args, result, describe)


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
])


def action_catalog_text() -> str:
    lines = []
    for spec in ACTIONS.values():
        fields = ", ".join(
            f"{name}{'' if field.is_required() else '?'}" for name, field in spec.args.model_fields.items())
        lines.append(f"{spec.name}({fields}): {spec.purpose}" + (" [changes the phone]" if spec.write else ""))
    return "\n".join(lines)
