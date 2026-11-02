import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { FocusedConversationClassifier } from './last-conversation-recorder'
import type * as Windows from './windows'

const botTile = 'bot-canonical'

const classify: FocusedConversationClassifier = id =>
  id === botTile ? { connectionId: 'pi', profile: 'chief' } : 'session'

async function setup({
  main = true,
  classifier = classify
}: { classifier?: FocusedConversationClassifier | null; main?: boolean } = {}) {
  vi.resetModules()
  window.localStorage.clear()
  vi.doMock('./windows', async importOriginal => ({
    ...(await importOriginal<typeof Windows>()),
    isMainWindow: () => main
  }))

  const tree = await import('@/components/pane-shell/tree/store')
  const model = await import('@/components/pane-shell/tree/model')
  const { registry } = await import('@/contrib/registry')
  const recorder = await import('./last-conversation-recorder')
  const { $lastConversation } = await import('./last-conversation')
  const { setSessionOwnerHint } = await import('./session')

  for (const id of ['workspace', `session-tile:${botTile}`, 'session-tile:sess-2']) {
    registry.register({
      area: 'panes',
      data: id === 'workspace' ? { placement: 'main', uncloseable: true } : { placement: 'main' },
      id,
      render: () => null,
      title: id
    })
  }

  tree.declareDefaultTree(
    model.split('row', [
      model.group(['workspace'], { active: 'workspace', id: 'grp-main' }),
      model.group([`session-tile:${botTile}`, 'session-tile:sess-2'], {
        active: `session-tile:${botTile}`,
        id: 'grp-side'
      })
    ])
  )
  tree.noteActiveTreeGroup('grp-side')
  setSessionOwnerHint('sess-2', { connectionId: 'pi', profile: 'default' })

  if (classifier) {
    recorder.registerFocusedConversationClassifier(classifier)
  }

  const stop = recorder.startLastConversationRecorder()

  return { $lastConversation, stop, tree }
}

describe('the reopen pointer follows the focused conversation', () => {
  beforeEach(() => {
    vi.resetModules()
  })

  afterEach(() => {
    vi.doUnmock('./windows')
    vi.resetModules()
  })

  it('activating a Bot Chat tab records that bot', async () => {
    const { $lastConversation, tree } = await setup()

    tree.activateTreePane('grp-side', 'session-tile:sess-2')
    tree.activateTreePane('grp-side', `session-tile:${botTile}`)

    expect($lastConversation.get()).toMatchObject({ connectionId: 'pi', kind: 'bot-chat', profile: 'chief' })
  })

  it('activating a session tab records that session with its owner', async () => {
    const { $lastConversation, tree } = await setup()

    tree.activateTreePane('grp-side', 'session-tile:sess-2')

    expect($lastConversation.get()).toMatchObject({
      connectionId: 'pi',
      kind: 'session',
      profile: 'default',
      sessionId: 'sess-2'
    })
  })

  it('a session tab replaces an older Bot Chat pointer, and back again', async () => {
    const { $lastConversation, tree } = await setup()

    tree.activateTreePane('grp-side', `session-tile:${botTile}`)
    tree.activateTreePane('grp-side', 'session-tile:sess-2')
    expect($lastConversation.get()?.kind).toBe('session')

    tree.activateTreePane('grp-side', `session-tile:${botTile}`)
    expect($lastConversation.get()?.kind).toBe('bot-chat')
  })

  it('a window that is not the main window never records', async () => {
    const { $lastConversation, tree } = await setup({ main: false })

    tree.activateTreePane('grp-side', 'session-tile:sess-2')
    tree.activateTreePane('grp-side', `session-tile:${botTile}`)

    expect($lastConversation.get()).toBeNull()
  })

  it('records nothing while the classifier cannot tell yet', async () => {
    const { $lastConversation, tree } = await setup({ classifier: () => 'unknown' })

    tree.activateTreePane('grp-side', 'session-tile:sess-2')

    expect($lastConversation.get()).toBeNull()
  })

  it('records nothing without a classifier rather than guessing a bot tile is a session', async () => {
    const { $lastConversation, tree } = await setup({ classifier: null })

    tree.activateTreePane('grp-side', 'session-tile:sess-2')

    expect($lastConversation.get()).toBeNull()
  })

  it('does not overwrite the pointer while the boot restore is reading it', async () => {
    const { $lastConversation, tree } = await setup()
    const { $bootRestorePhase } = await import('./last-conversation-restore')

    $bootRestorePhase.set('restoring')
    tree.activateTreePane('grp-side', 'session-tile:sess-2')

    expect($lastConversation.get()).toBeNull()
  })
})
