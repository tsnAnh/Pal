"""Tests for GHSA-qg5c-hvr5-hjgr: the consent callback is per-thread, so overlapping ACP sessions
cannot overwrite each other's slot."""

import threading


class TestThreadLocalApprovalCallback:
    """GHSA-qg5c-hvr5-hjgr: set_approval_callback must be per-thread so
    concurrent ACP sessions don't stomp on each other's handlers."""


    def test_callback_not_visible_in_different_thread(self):
        """Thread A's callback is NOT visible to Thread B."""
        from tools.terminal_tool import (
            set_approval_callback,
            _get_approval_callback,
        )

        cb_a = lambda cmd, desc: "thread_a"
        cb_b = lambda cmd, desc: "thread_b"

        seen_in_a = []
        seen_in_b = []

        def thread_a():
            set_approval_callback(cb_a)
            # Pause so thread B has time to set its own callback
            import time
            time.sleep(0.05)
            seen_in_a.append(_get_approval_callback())

        def thread_b():
            set_approval_callback(cb_b)
            import time
            time.sleep(0.05)
            seen_in_b.append(_get_approval_callback())

        ta = threading.Thread(target=thread_a)
        tb = threading.Thread(target=thread_b)
        ta.start()
        tb.start()
        ta.join()
        tb.join()

        # Each thread must see ONLY its own callback — not the other's
        assert seen_in_a == [cb_a]
        assert seen_in_b == [cb_b]

    def test_main_thread_callback_not_leaked_to_worker(self):
        """A callback set in the main thread does NOT leak into a
        freshly-spawned worker thread."""
        from tools.terminal_tool import (
            set_approval_callback,
            _get_approval_callback,
        )

        cb_main = lambda cmd, desc: "main"
        set_approval_callback(cb_main)

        worker_saw = []

        def worker():
            worker_saw.append(_get_approval_callback())

        t = threading.Thread(target=worker)
        t.start()
        t.join()

        # Worker thread has no callback set — TLS is empty for it
        assert worker_saw == [None]
        # Main thread still has its callback
        assert _get_approval_callback() is cb_main


    def test_sudo_password_cache_does_not_leak_across_threads(self):
        """Interactive sudo cache must not bleed into another executor thread."""
        from tools.terminal_tool_sudo import (
            _get_cached_sudo_password,
            _reset_cached_sudo_passwords,
            _set_cached_sudo_password,
        )

        _reset_cached_sudo_passwords()
        _set_cached_sudo_password("main-thread-password")

        worker_saw = []

        def worker():
            worker_saw.append(_get_cached_sudo_password())

        t = threading.Thread(target=worker)
        t.start()
        t.join()

        assert worker_saw == [""]
        assert _get_cached_sudo_password() == "main-thread-password"
