"""Frozen editor policy, without an editor process."""
from dataclasses import asdict
import os

from gateway.session_policy import build_policy, restore_policy


def test_acp_policy_uses_its_own_tools_and_restores_frozen_cwd(tmp_path):
    from hermes_cli.tools_config import _get_platform_tools
    cfg = {'platform_toolsets': {'cli': ['terminal'], 'acp': ['file']}}
    params = {'source': 'acp', 'cwd': str(tmp_path), 'model': 'fixture',
              'editor': {'mcp_servers': [], 'edit_approval_policy': 'ask'}}
    before = dict(os.environ)
    policy = build_policy(params, cfg)
    assert policy.platform == 'acp'
    assert set(policy.toolsets) == _get_platform_tools(cfg, 'acp')
    assert 'terminal' not in policy.toolsets and 'project' not in policy.toolsets
    restored = restore_policy(asdict(policy))
    assert restored == policy
    cfg['platform_toolsets']['acp'] = ['terminal']
    assert 'terminal' not in restored.toolsets
    assert dict(os.environ) == before
