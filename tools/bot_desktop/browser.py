"""The bot's browser on its Bot Desktop: one executable, one persistent user-data-dir per profile.

The agent's Chromium (``tools.browser_session`` → ``tools.browser_launcher``) and the dock's Browser icon a
human clicks must be THE SAME browser — same binary, same ``--user-data-dir`` — or the human logs in to a
jar the bot never sees. Chromium's singleton makes a second launch on the same user-data-dir open a window
in the running instance, which is the hand-over we want in ONE direction. When the human's dock instance is
already up, a launch would be forwarded to it and exit without a DevTools endpoint, so the dock exposes a
debugging port and the launcher ATTACHES to it instead of launching.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Optional, Sequence

from tools.bot_desktop import runtime

DISK_CACHE_BYTES = 256 * 1024 * 1024

_SYSTEM_BROWSERS = ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser")
_SNAP_BIN_DIR = "/snap/bin"
_SNAP_ROOT = "/snap"
_ICON_ROOT = "/usr/share/icons"
_HICOLOR_SIZES = ("256x256", "128x128", "64x64", "48x48", "32x32", "22x22")
_HICOLOR_NAMES = ("chromium-browser", "chromium", "google-chrome")
_THEME_ICONS = ("internet-web-browser", "web-browser")
SHIPPED_ICON = Path(__file__).with_name("browser-icon.svg")


def profile_dir() -> Path:
    """User-data-dir the bot's browser uses on this profile's screen. ``browser.user_data_dir`` pins your own:
    ``~`` expands, and a relative path is anchored at this profile's HERMES_HOME (where the rest of the screen's
    state lives), so ``pin`` means ``<HERMES_HOME>/pin`` and two profiles never share one jar by accident."""
    from tools.browser_session_cloud import user_data_dir
    override = user_data_dir()
    if override:
        return Path(override)
    exe = executable()
    if exe and _is_snap(exe):
        return _snap_home() / "browser-profile"
    return runtime.state_dir() / "browser-profile"


def executable() -> Optional[str]:
    """The Chromium the bot runs: an explicit ``browser.executable_path``, else the packaged Chromium, else a
    system Chrome/Chromium. ``None`` when there is none.

    Non-root under ``kernel.apparmor_restrict_unprivileged_userns=1`` (Ubuntu 23.10+) flips the order:
    Playwright's bundle has no setuid ``chrome_sandbox`` and dies 'FATAL: No usable sandbox!' there, while
    a distro chromium ships the helper. The bundle stays the answer when it is the only browser — a dock
    icon that fails loudly beats a non-root ``--no-sandbox``.
    """
    from tools.browser_session_cloud import executable_path
    explicit = executable_path()
    if explicit and os.access(explicit, os.X_OK) and not _is_headless_shell(explicit):
        return explicit
    finders = [_managed_executable, _system_executable]
    if not runtime.is_root() and _userns_restricted():
        finders.reverse()
    return next((exe for find in finders if (exe := find())), None)


def _managed_executable() -> Optional[str]:
    from hermes_cli.browser_runtime import chromium_executable

    exe = chromium_executable(allow_override=False)
    return exe if exe and os.access(exe, os.X_OK) and not _is_headless_shell(exe) else None


def _is_headless_shell(exe: str) -> bool:
    """Playwright's ``chrome-headless-shell`` can drive pages but cannot open a window; trusting such an
    override blindly would pin a windowless binary to the dock's Browser icon."""
    return "headless" in os.path.basename(exe).lower() or "headless_shell" in exe


def _system_executable() -> Optional[str]:
    """A service's PATH rarely carries ``/snap/bin``, where Ubuntu's Chromium snap lives."""
    path = os.pathsep.join((os.environ.get("PATH", os.defpath), _SNAP_BIN_DIR))
    return next((found for name in _SYSTEM_BROWSERS if (found := shutil.which(name, path=path))), None)


def _snap_home() -> Path:
    return Path.home() / "snap" / "chromium" / "common" / "hermes-bot-desktop" / runtime._profile_name()


def dock_icon(exe: str) -> str:
    """``Icon=`` for the dock's Browser entry that this host can draw: the browser's own icon file, else a
    theme name the installed theme has, else the icon Hermes ships (a theme without it renders a blank page)."""
    import glob
    snap_gui = glob.glob(f"{_SNAP_ROOT}/{os.path.basename(exe)}/current/meta/gui/*.png") if _is_snap(exe) else []
    hicolor = [f"{_ICON_ROOT}/hicolor/{size}/apps/{icon}.png" for icon in _HICOLOR_NAMES for size in _HICOLOR_SIZES]
    hicolor += [f"{_ICON_ROOT}/hicolor/scalable/apps/{icon}.svg" for icon in _HICOLOR_NAMES]
    if found := next((c for c in (*sorted(snap_gui), *hicolor) if os.path.isfile(c)), None):
        return found
    for theme_icon in _THEME_ICONS:
        if glob.glob(f"{_ICON_ROOT}/**/{theme_icon}.*", recursive=True):
            return theme_icon
    return str(SHIPPED_ICON)


def snap_xauthority() -> Path:
    return _snap_home() / "Xauthority"


def sync_snap_xauthority() -> None:
    """Copy the screen's X cookie to where a snap-confined browser may read it (strict confinement cannot read
    ``~/.hermes``). Mode 0600 in a 0700 directory, replaced on every screen start; the content is never read
    into a log."""
    target = snap_xauthority()
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = target.with_name(target.name + ".new")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write((runtime.state_dir() / "Xauthority").read_bytes())
    os.replace(tmp, target)


def remove_snap_xauthority() -> None:
    snap_xauthority().unlink(missing_ok=True)


def snap_env(env: dict[str, str]) -> dict[str, str]:
    """``env`` with ``XAUTHORITY`` on the snap-readable cookie copy. Raises in plain words when it cannot be
    made: a snap browser without it cannot reach the screen, and headless would hide that."""
    try:
        sync_snap_xauthority()
    except OSError as exc:
        raise RuntimeError("The browser is a snap, and snap confinement cannot read the bot screen's X authority; "
                           f"Hermes could not place a copy where the snap may read it ({exc.strerror or 'I/O error'}). "
                           "Set browser.executable_path to a non-snap Chromium, or fix the permissions of "
                           f"{snap_xauthority().parent}.") from exc
    return {**env, "XAUTHORITY": str(snap_xauthority())}


def _is_snap(exe: str) -> bool:
    """A snap-confined browser cannot write hidden directories under HOME (``~/.hermes``), only ``~/snap/<name>/common``."""
    return os.path.dirname(exe) == _SNAP_BIN_DIR or os.path.basename(os.path.realpath(exe)) == "snap"


def _userns_restricted() -> bool:
    from tools.browser_launcher import apparmor_restricts_unprivileged_userns
    return apparmor_restricts_unprivileged_userns()


def dock_launch() -> Optional[tuple[str, str]]:
    """``(executable, user_data_dir)`` for the dock's Browser icon, or ``None`` when no Chromium exists."""
    exe = executable()
    return (exe, str(profile_dir())) if exe else None


# Flags the agent's launch and the dock's icon share on the persistent profile. --test-type hides the
# "Chrome for Testing is only for automated testing" and unsupported-flag (--no-sandbox as root) infobars
# that would sit over the human's takeover view; the persistent profile's HTTP cache is capped (uncapped it
# grows for months toward a hosted instance's 6 GB).
SHARED_PROFILE_ARGS = ("--test-type", f"--disk-cache-size={DISK_CACHE_BYTES}")


def dock_argv(exe: str, user_data_dir: str, *, sandbox_bypass: Optional[bool] = None) -> list[str]:
    """Command the dock's Browser icon runs. ``--remote-debugging-port=0`` makes a human-started
    instance attachable (Chromium writes the chosen port to ``<user-data-dir>/DevToolsActivePort``);
    first-run / default-browser dialogs would sit between the human and the bot's tabs. The sandbox policy
    is the launcher's (root, Docker, AppArmor userns): the human's Browser is the bot's browser."""
    from tools.browser_launcher import CHROMIUM_SANDBOX_BYPASS_ARGS, needs_chromium_sandbox_bypass
    return [exe, f"--user-data-dir={user_data_dir}", "--remote-debugging-port=0", "--no-first-run",
            "--no-default-browser-check", *SHARED_PROFILE_ARGS,
            *(CHROMIUM_SANDBOX_BYPASS_ARGS if (needs_chromium_sandbox_bypass() if sandbox_bypass is None
                                              else sandbox_bypass) else ())]


def dock_wrapper(user_data_dir: str, exe: str = "") -> tuple[str, ...]:
    snap = ("env", f"XAUTHORITY={snap_xauthority()}") if exe and _is_snap(exe) else ()
    return (*snap, *_managed_wrapper(user_data_dir))


def _managed_wrapper(user_data_dir: str) -> tuple[str, ...]:
    from tools.bot_desktop import chrome_profile
    if not chrome_profile.is_managed_copy(user_data_dir):
        return ()
    from hermes_cli._launchers import installation_command
    from hermes_cli._startup_fast import project_root_str
    from hermes_constants import get_hermes_home
    command = installation_command(Path(project_root_str()), module="tools.bot_desktop.chrome_profile")
    return ("env", f"HERMES_HOME={get_hermes_home()}", *command, "run", "--")


def dock_exec_line(exe: str, user_data_dir: str, *, sandbox_bypass: Optional[bool] = None,
                   wrapper: Sequence[str] = ()) -> str:
    """The ``Exec=`` line of the dock's ``.desktop`` entry. Every argument is double-quoted per the
    Desktop Entry spec (a browser under ``/opt/Google Chrome/`` or a profile under a spaced HERMES_HOME
    otherwise splits into garbage): inside the quotes ``" ` $ \\`` are backslash-escaped, and because the
    value is itself a string field, each of those backslashes is escaped once more."""
    def quote(arg: str) -> str:
        quoted = "".join("\\" + ch if ch in '"`$\\' else ch for ch in arg)
        return '"' + quoted.replace("\\", "\\\\") + '"'
    argv = [*wrapper, *dock_argv(exe, user_data_dir, sandbox_bypass=sandbox_bypass)]
    return "Exec=" + " ".join(quote(arg) for arg in argv)
