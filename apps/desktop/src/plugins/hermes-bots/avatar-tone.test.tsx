import { cleanup, render } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'

vi.mock('@hermes/plugin-sdk', async () => {
  const { atom } = await import('nanostores')
  const { blobatar } = await import('blobatar/blob')

  return {
    atom,
    blobatarSvg: blobatar,
    createBudgetedLoop: undefined,
    host: { state: { connectionId: { get: () => 'local' } } },
    profileColor: () => '#8b5cf6',
    PROFILE_SWATCHES: [],
    queryClient: undefined,
    useQuery: vi.fn(),
    useValue: vi.fn()
  }
})

vi.mock('./shared', () => ({ getPluginCtx: () => null, ID: 'hermes-bots' }))

import { BotFace, stopFaceClock } from './avatar'
import { isWhiteAvatarColor } from './avatar-color'

const SHAPES = { blob: 'blobatar:alpha:round', math: 'squircle', sigil: 'sigil-3' }

function toneOf(shape: string, color: string): null | string {
  const { container } = render(<BotFace color={color} name="alpha" shape={shape} size={48} />)

  return container.querySelector('svg')!.getAttribute('data-hb-tone')
}

afterEach(() => {
  cleanup()
  stopFaceClock()
})

describe('isWhiteAvatarColor', () => {
  it('is true at a luminance of 230 and above and false below it', () => {
    expect(isWhiteAvatarColor('#ffffff')).toBe(true)
    expect(isWhiteAvatarColor('#fff')).toBe(true)
    expect(isWhiteAvatarColor('rgb(255, 255, 255)')).toBe(true)
    expect(isWhiteAvatarColor('hsl(0, 0%, 100%)')).toBe(true)
    expect(isWhiteAvatarColor('#e7e7e7')).toBe(true)
    expect(isWhiteAvatarColor('#e5e5e5')).toBe(false)
    expect(isWhiteAvatarColor('#8b5cf6')).toBe(false)
    expect(isWhiteAvatarColor('#000000')).toBe(false)
    expect(isWhiteAvatarColor('not a colour')).toBe(false)
  })
})

describe.each(Object.entries(SHAPES))('the %s face', (_kind, shape) => {
  it('is marked white only for a white colour', () => {
    expect(toneOf(shape, '#ffffff')).toBe('white')
    expect(toneOf(shape, '#f4f4f4')).toBe('white')
    expect(toneOf(shape, '#3e8ef7')).toBeNull()
    expect(toneOf(shape, '#1b1b1b')).toBeNull()
    expect(toneOf(shape, '#dddddd')).toBeNull()
  })
})
