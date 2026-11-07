import time

from gateway import reach_routes
from gateway.reach_policy import load_policy
from tests.gateway.reach_harness import FakeAppTransport, make_authority, make_home


def _labels(authority, home):
    return [route.label for route in reach_routes.routes(authority, home, load_policy({}))]


def test_input_typed_on_a_phones_chat_socket_counts_for_its_offer_socket(tmp_path):
    home = make_home(tmp_path, "profile")
    authority = make_authority(home)
    now = time.time()
    authority.events["t-desktop"] = FakeAppTransport(home, "Desktop", last_input=now - 120)
    authority.events["t-phone-roster"] = FakeAppTransport(home, "iPhone")
    authority.events["t-phone-chat"] = FakeAppTransport(home, "iPhone", accepts=False, last_input=now - 5)
    assert _labels(authority, home) == ["iPhone", "Desktop"]


def test_another_devices_input_is_never_borrowed(tmp_path):
    home = make_home(tmp_path, "profile")
    authority = make_authority(home)
    now = time.time()
    authority.events["t-desktop"] = FakeAppTransport(home, "Desktop", last_input=now - 5)
    authority.events["t-phone-roster"] = FakeAppTransport(home, "iPhone")
    authority.events["t-tablet-chat"] = FakeAppTransport(home, "iPad", accepts=False, last_input=now - 1)
    assert _labels(authority, home) == ["Desktop", "iPhone"]
