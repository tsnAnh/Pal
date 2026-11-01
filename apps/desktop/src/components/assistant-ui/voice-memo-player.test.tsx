import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { memoClock, VoiceMemoPlayer } from './voice-memo-player'

const labels = { pauseMemo: 'Pause voice memo', playMemo: 'Play voice memo' }

const mount = (props: Partial<Parameters<typeof VoiceMemoPlayer>[0]> = {}) =>
  render(<VoiceMemoPlayer labels={labels} name="memo.mp3" src="blob:memo" {...props} />)

const audioOf = (container: HTMLElement) => container.querySelector('audio') as HTMLAudioElement

const defineAudio = (audio: HTMLAudioElement, values: Partial<Record<'currentTime' | 'duration', number>>) => {
  for (const [key, value] of Object.entries(values)) {
    Object.defineProperty(audio, key, { configurable: true, value })
  }
}

describe('VoiceMemoPlayer', () => {
  beforeEach(() => {
    vi.spyOn(HTMLMediaElement.prototype, 'play').mockImplementation(function (this: HTMLMediaElement) {
      Object.defineProperty(this, 'paused', { configurable: true, value: false })
      this.dispatchEvent(new Event('play'))

      return Promise.resolve()
    })
    vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(function (this: HTMLMediaElement) {
      Object.defineProperty(this, 'paused', { configurable: true, value: true })
      this.dispatchEvent(new Event('pause'))
    })
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  it('renders a compact player with Play and the duration once metadata loads', () => {
    const { container } = mount()

    expect(screen.getByRole('button', { name: 'Play voice memo' })).toBeTruthy()
    expect(container.querySelector('[data-slot="voice-memo-time"]')?.textContent).toBe('0:00')

    act(() => {
      defineAudio(audioOf(container), { duration: 83.4 })
      fireEvent.loadedMetadata(audioOf(container))
    })

    expect(container.querySelector('[data-slot="voice-memo-time"]')?.textContent).toBe('1:23')
    expect(container.querySelector('audio[controls]')).toBeNull()
  })

  it('toggles Play/Pause and shows the position while playing', () => {
    const { container } = mount()

    act(() => {
      defineAudio(audioOf(container), { duration: 30 })
      fireEvent.loadedMetadata(audioOf(container))
    })

    fireEvent.click(screen.getByRole('button', { name: 'Play voice memo' }))
    expect(screen.getByRole('button', { name: 'Pause voice memo' })).toBeTruthy()

    act(() => {
      defineAudio(audioOf(container), { currentTime: 7 })
      fireEvent.timeUpdate(audioOf(container))
    })
    expect(container.querySelector('[data-slot="voice-memo-time"]')?.textContent).toBe('0:07')

    fireEvent.click(screen.getByRole('button', { name: 'Pause voice memo' }))
    expect(screen.getByRole('button', { name: 'Play voice memo' })).toBeTruthy()
  })

  it('returns to the start when playback ends', () => {
    const { container } = mount()

    act(() => {
      defineAudio(audioOf(container), { duration: 12 })
      fireEvent.loadedMetadata(audioOf(container))
    })
    fireEvent.click(screen.getByRole('button', { name: 'Play voice memo' }))
    fireEvent.ended(audioOf(container))

    expect(screen.getByRole('button', { name: 'Play voice memo' })).toBeTruthy()
    expect(container.querySelector('[data-slot="voice-memo-time"]')?.textContent).toBe('0:12')
  })

  it('pauses another memo that was playing', () => {
    const first = mount({ name: 'a.mp3' })
    const second = mount({ name: 'b.mp3' })

    const [playFirst, playSecond] = screen.getAllByRole('button', { name: 'Play voice memo' })

    fireEvent.click(playFirst)
    fireEvent.click(playSecond)

    expect(screen.getAllByRole('button', { name: 'Play voice memo' })).toHaveLength(1)
    expect(screen.getAllByRole('button', { name: 'Pause voice memo' })).toHaveLength(1)
    expect(first.container.querySelector('[data-playing]')).toBeNull()
    expect(second.container.querySelector('[data-playing]')).not.toBeNull()
  })

  it('hands load errors to the caller so an expired source can be re-resolved', () => {
    const onError = vi.fn()
    const { container } = mount({ onError })

    fireEvent.error(audioOf(container))

    expect(onError).toHaveBeenCalledTimes(1)
  })

  it('formats clocks and survives a non-finite duration', () => {
    expect(memoClock(5)).toBe('0:05')
    expect(memoClock(Number.NaN)).toBe('0:00')
    expect(memoClock(Number.POSITIVE_INFINITY)).toBe('0:00')
  })
})
