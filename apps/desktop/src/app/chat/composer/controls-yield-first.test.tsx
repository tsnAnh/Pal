import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'

import type { ChatBarState } from '@/app/chat/composer/types'
import { I18nProvider } from '@/i18n'

import { ComposerControls } from './controls'

vi.mock('./model-pill', () => ({ ModelPill: () => null }))

const state: ChatBarState = {
  model: { canSwitch: false, model: '', provider: '' },
  tools: { enabled: false, label: '' },
  voice: { active: false, enabled: false }
}

function renderControls(overrides: Partial<React.ComponentProps<typeof ComposerControls>> = {}) {
  return render(
    <I18nProvider configClient={null} initialLocale="en">
      <ComposerControls
        autoSpeak={false}
        busy
        busyAction="send"
        canSubmit
        conversation={{
          active: false,
          level: 0,
          muted: false,
          onEnd: vi.fn(),
          onStart: vi.fn(),
          onStopTurn: vi.fn(),
          onToggleMute: vi.fn(),
          status: 'idle'
        }}
        disabled={false}
        hasComposerPayload
        onDictate={vi.fn()}
        onQueue={vi.fn()}
        onToggleAutoSpeak={vi.fn()}
        state={state}
        voiceStatus="idle"
        {...overrides}
      />
    </I18nProvider>
  )
}

afterEach(cleanup)

describe('composer controls in a yield-first chat while a turn runs', () => {
  it('labels the primary action Send, with no Redirect, Queue or Steer', () => {
    renderControls()

    expect(screen.getByLabelText('Send')).toBeTruthy()

    for (const label of ['Redirect the current run', 'Queue message', 'Steer the current run']) {
      expect(screen.queryByLabelText(label)).toBeNull()
    }
  })

  it('keeps an explicit Stop reachable beside Send while the owner is typing', () => {
    const onStop = vi.fn()
    renderControls({ onStop })

    fireEvent.click(screen.getByLabelText('Stop'))

    expect(onStop).toHaveBeenCalledOnce()
    expect(screen.getByLabelText('Send')).toBeTruthy()
  })

  it('shows the single Stop button on an empty composer', () => {
    renderControls({ busyAction: 'stop', hasComposerPayload: false, onStop: vi.fn() })

    expect(screen.getAllByLabelText('Stop')).toHaveLength(1)
  })

  it('offers no extra Stop when the chat is idle', () => {
    renderControls({ busy: false, busyAction: 'stop', onStop: vi.fn() })

    expect(screen.queryByLabelText('Stop')).toBeNull()
  })
})
