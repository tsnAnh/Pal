import importlib
import importlib.abc
import importlib.util
import os
import sys

TARGET = "agent.account_usage"


def fake_base():
    return os.environ.get("IOS_E2E_PROVIDER_USAGE_URL", "").rstrip("/")


class RedirectCopilotUsage(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path, target=None):
        if name != TARGET:
            return None
        sys.meta_path.remove(self)
        spec = importlib.util.find_spec(name)
        if spec is None or spec.loader is None:
            return spec
        execute = spec.loader.exec_module

        def exec_module(module):
            execute(module)
            module._COPILOT_USER_URL = f"{fake_base()}/copilot_internal/user"

        spec.loader.exec_module = exec_module
        return spec


if fake_base().startswith("http://127.0.0.1:"):
    sys.meta_path.insert(0, RedirectCopilotUsage())
