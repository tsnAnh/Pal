from __future__ import annotations

import ipaddress
import socket
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field

LOCAL_NAMES = frozenset({"localhost", "ip6-localhost", "ip6-loopback"})
INTERNET_FAMILIES = frozenset({socket.AF_INET, socket.AF_INET6})
LOOKUPS = ("getaddrinfo", "gethostbyname", "gethostbyname_ex", "gethostbyaddr", "getnameinfo")
CONNECTS = ("connect", "connect_ex", "sendto")


class NetworkBlocked(OSError):
    pass


@dataclass
class Guard:
    targets: list[str] = field(default_factory=list)

    @property
    def attempts(self) -> int:
        return len(self.targets)

    def require_loopback(self, operation: str, host: object) -> None:
        if is_loopback(host):
            return
        self.targets.append(f"{operation} {host}")
        raise NetworkBlocked(f"memory bench refuses {operation} to non-loopback host {host!r}")


def is_loopback(host: object) -> bool:
    if host is None:
        return True
    name = host.decode("ascii", "replace") if isinstance(host, bytes) else str(host)
    if name.lower() in LOCAL_NAMES:
        return True
    try:
        return ipaddress.ip_address(name.partition("%")[0]).is_loopback
    except ValueError:
        return False


def guarded_lookup(guard: Guard, operation: str, original: Callable) -> Callable:
    def lookup(target, *args, **kwargs):
        host = target[0] if isinstance(target, tuple) else target
        guard.require_loopback(operation, host)
        return original(target, *args, **kwargs)

    return lookup


def guarded_connect(guard: Guard, operation: str, original: Callable) -> Callable:
    def connect(sock, *args):
        if sock.family in INTERNET_FAMILIES:
            guard.require_loopback(operation, args[-1][0])
        return original(sock, *args)

    return connect


@contextmanager
def network_blocked() -> Iterator[Guard]:
    guard = Guard()
    lookups = {name: getattr(socket, name) for name in LOOKUPS}
    declared = {name: socket.socket.__dict__.get(name) for name in CONNECTS}
    try:
        for name, original in lookups.items():
            setattr(socket, name, guarded_lookup(guard, name, original))
        for name in CONNECTS:
            setattr(socket.socket, name, guarded_connect(guard, name, getattr(socket.socket, name)))
        yield guard
    finally:
        for name, original in lookups.items():
            setattr(socket, name, original)
        for name, original in declared.items():
            if original is None:
                delattr(socket.socket, name)
            else:
                setattr(socket.socket, name, original)
