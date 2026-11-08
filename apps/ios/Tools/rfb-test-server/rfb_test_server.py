#!/usr/bin/env python3
"""A stand-in for one bot's Xvnc: the screen source behind the gateway's real /api/display/ws bridge.

It publishes the same on-disk state a running Bot Desktop publishes under ``<profile home>/bot-desktop``
(launcher.pid, env, rfb.sock) so the gateway's own status, observe, lease and bridge code runs unchanged,
and serves RFB 3.8 with no authentication over that unix socket. It draws a fixed test pattern, a marker
that follows the pointer and a bar that grows with every key, and logs every input message it receives.
Only the screen is faked.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import signal
import struct
import sys
import time
from pathlib import Path

import psutil

BARS = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0), (255, 0, 255), (255, 0, 0), (0, 0, 255), (20, 20, 20)]
MARKER = 28


class Screen:
    def __init__(self, width: int, height: int, wallpaper: Path | None = None) -> None:
        self.width, self.height = width, height
        self.base = self._wallpaper(wallpaper) if wallpaper else self._pattern()
        self.pointer = (width // 2, height // 2)
        self.buttons = 0
        self.keys = 0

    def _wallpaper(self, path: Path) -> bytearray:
        from PIL import Image

        image = Image.open(path).convert("RGB").resize((self.width, self.height))
        return bytearray(image.convert("RGBX").tobytes("raw", "BGRX"))

    def _pattern(self) -> bytearray:
        w, h = self.width, self.height
        rows = bytearray()
        bar_h = h * 2 // 5
        for y in range(h):
            if y < bar_h:
                row = b"".join(bytes((b, g, r, 0)) * (w // len(BARS) + 1) for r, g, b in BARS)[: w * 4]
            else:
                shade = 40 + (y - bar_h) * 160 // max(1, h - bar_h)
                row = b"".join(bytes((shade, (x * 255) // w, 255 - shade, 0)) for x in range(0, w, 8) for _ in range(8))[: w * 4]
            if y % 100 == 0 or y == h - 1:
                row = bytes((255, 255, 255, 0)) * w
            rows += row
        for x in range(0, w, 100):
            for y in range(h):
                o = (y * w + x) * 4
                rows[o : o + 4] = bytes((255, 255, 255, 0))
        return rows

    def render(self, x: int, y: int, w: int, h: int) -> bytes:
        out = bytearray()
        for row in range(y, y + h):
            start = (row * self.width + x) * 4
            out += self.base[start : start + w * 4]
        self._overlay(out, x, y, w, h)
        return bytes(out)

    def _overlay(self, out: bytearray, x: int, y: int, w: int, h: int) -> None:
        color = (0, 0, 255) if self.buttons == 0 else (0, 200, 0) if self.buttons & 1 else (255, 140, 0)
        px, py = self.pointer
        for yy in range(max(py - MARKER // 2, y), min(py + MARKER // 2, y + h)):
            for xx in range(max(px - MARKER // 2, x), min(px + MARKER // 2, x + w)):
                o = ((yy - y) * w + (xx - x)) * 4
                out[o : o + 4] = bytes((color[2], color[1], color[0], 0))
        bar_w = min(self.width, 8 * self.keys)
        for yy in range(max(0, y), min(24, y + h)):
            for xx in range(x, min(bar_w, x + w)):
                o = ((yy - y) * w + (xx - x)) * 4
                out[o : o + 4] = bytes((0, 128, 255, 0))

    def marker_rect(self) -> tuple[int, int, int, int]:
        px, py = self.pointer
        x0, y0 = max(px - MARKER // 2, 0), max(py - MARKER // 2, 0)
        return x0, y0, min(MARKER, self.width - x0), min(MARKER, self.height - y0)


class Server:
    def __init__(self, log_path: Path, screen: Screen, init_delay: float = 0) -> None:
        self.log_path = log_path
        self.screen = screen
        self.init_delay = init_delay
        self.dirty: list[tuple[int, int, int, int]] = []

    def log(self, line: str) -> None:
        with self.log_path.open("a", encoding="utf-8") as fh:
            fh.write(f"{time.monotonic():.3f} {line}\n")

    async def serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.log("client connected")
        try:
            await self.handshake(reader, writer)
            await self.messages(reader, writer)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            self.log("client disconnected")
            writer.close()

    async def handshake(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        writer.write(b"RFB 003.008\n")
        await reader.readexactly(12)
        writer.write(bytes([1, 1]))
        await reader.readexactly(1)
        writer.write(struct.pack(">I", 0))
        await reader.readexactly(1)
        await asyncio.sleep(self.init_delay)
        name = b"test-desktop"
        pixel_format = struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        writer.write(struct.pack(">HH", self.screen.width, self.screen.height) + pixel_format + struct.pack(">I", len(name)) + name)
        await writer.drain()

    async def messages(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        pending = None
        while True:
            kind = (await reader.readexactly(1))[0]
            if kind == 0:
                await reader.readexactly(19)
                self.log("set-pixel-format")
            elif kind == 2:
                _, count = struct.unpack(">xH", await reader.readexactly(3))
                encodings = struct.unpack(f">{count}i", await reader.readexactly(4 * count))
                self.log(f"set-encodings {list(encodings)}")
            elif kind == 3:
                incremental, x, y, w, h = struct.unpack(">BHHHH", await reader.readexactly(9))
                if not incremental:
                    await self.send(writer, [(0, 0, self.screen.width, self.screen.height)])
                    pending = None
                elif self.dirty:
                    await self.send(writer, self.take_dirty())
                    pending = None
                else:
                    pending = (x, y, w, h)
            elif kind == 4:
                down, _pad, keysym = struct.unpack(">BHI", await reader.readexactly(7))
                self.log(f"key down={down} keysym=0x{keysym:x}")
                if down:
                    self.screen.keys += 1
                    self.dirty.append((0, 0, self.screen.width, 24))
            elif kind == 5:
                buttons, x, y = struct.unpack(">BHH", await reader.readexactly(5))
                self.log(f"pointer buttons={buttons} x={x} y={y}")
                self.dirty.append(self.screen.marker_rect())
                self.screen.pointer = (min(x, self.screen.width - 1), min(y, self.screen.height - 1))
                self.screen.buttons = buttons
                self.dirty.append(self.screen.marker_rect())
            elif kind == 6:
                (length,) = struct.unpack(">xxxI", await reader.readexactly(7))
                text = (await reader.readexactly(length)).decode("latin-1")
                self.log(f"client-cut-text {text!r}")
            else:
                self.log(f"unknown client message {kind}")
                return
            if pending is not None and self.dirty:
                await self.send(writer, self.take_dirty())
                pending = None

    def take_dirty(self) -> list[tuple[int, int, int, int]]:
        left = min(r[0] for r in self.dirty)
        top = min(r[1] for r in self.dirty)
        right = max(r[0] + r[2] for r in self.dirty)
        bottom = max(r[1] + r[3] for r in self.dirty)
        self.dirty = []
        return [(left, top, min(right, self.screen.width) - left, min(bottom, self.screen.height) - top)]

    async def send(self, writer: asyncio.StreamWriter, rects: list[tuple[int, int, int, int]]) -> None:
        payload = bytearray(struct.pack(">BxH", 0, len(rects)))
        for x, y, w, h in rects:
            payload += struct.pack(">HHHHi", x, y, w, h, 0) + self.screen.render(x, y, w, h)
        writer.write(bytes(payload))
        await writer.drain()


def publish(state: Path) -> None:
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    born = psutil.Process(os.getpid()).create_time()
    (state / "launcher.pid").write_text(f"{os.getpid()} {born}\n", encoding="utf-8")
    (state / "env").write_text("DISPLAY=:99\n", encoding="utf-8")


def withdraw(state: Path) -> None:
    for name in ("launcher.pid", "env", "rfb.sock"):
        (state / name).unlink(missing_ok=True)


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-home", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--size", default="1280x800")
    parser.add_argument("--init-delay", type=float, default=0, help="seconds a connecting viewer waits for the first frame")
    parser.add_argument("--wallpaper", type=Path, help="draw this image instead of the test pattern")
    args = parser.parse_args()
    width, height = (int(part) for part in args.size.split("x"))
    state = args.profile_home / "bot-desktop"
    server = Server(args.log, Screen(width, height, args.wallpaper), args.init_delay)
    publish(state)
    sock = state / "rfb.sock"
    sock.unlink(missing_ok=True)
    listener = await asyncio.start_unix_server(server.serve, path=str(sock))
    os.chmod(sock, 0o600)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, stop.set)
    server.log(f"listening {width}x{height}")
    print("ready", flush=True)
    try:
        await stop.wait()
    finally:
        listener.close()
        withdraw(state)


if __name__ == "__main__":
    asyncio.run(main())
    sys.exit(0)
