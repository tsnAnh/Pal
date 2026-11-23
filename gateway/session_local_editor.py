"""Editor policy lives with execution; an ACP connection is only a viewer."""
from persistence.core.errors import AuthorityRefusal


def validate_editor(source, editor):
    """The launch's editor policy, or a refusal that names the key it read (create path totality).

    An ACP connection is a viewer; the policy itself lives with execution. Every branch below refuses
    with its own field, so a rejected editor launch says which key was wrong instead of a bare code.
    """
    if editor is None:
        return
    if source != 'acp':
        raise AuthorityRefusal('invalid_params', field='editor',
                               detail=f'an editor policy is only accepted from an ACP launch, not {source}')
    if not isinstance(editor, dict):
        raise AuthorityRefusal('invalid_params', field='editor',
                               detail=f'must be a mapping, got {type(editor).__name__}')
    unknown = sorted(set(editor) - {'mcp_servers', 'edit_approval_policy'})
    if unknown:
        raise AuthorityRefusal('invalid_params', field=f'editor.{unknown[0]}',
                               detail='unknown editor key')
    if editor.get('edit_approval_policy', 'ask') != 'ask':
        raise AuthorityRefusal('invalid_params', field='editor.edit_approval_policy',
                               detail="must be 'ask': every edit is approved one at a time")
    if not isinstance(editor.get('mcp_servers', []), list):
        raise AuthorityRefusal('invalid_params', field='editor.mcp_servers',
                               detail=f'must be a list, got {type(editor.get("mcp_servers")).__name__}')
    from gateway.session_local_mcp import validate_servers
    validate_servers(editor.get('mcp_servers', []))
