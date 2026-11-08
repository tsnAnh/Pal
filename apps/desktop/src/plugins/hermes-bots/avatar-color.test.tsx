import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'

vi.mock('@hermes/plugin-sdk', async () => {
  const { atom } = await import('nanostores')
  const { blobatar } = await import('blobatar/blob')

  return {
    atom,
    blobatarSvg: blobatar,
    createBudgetedLoop: undefined,
    host: { state: { connectionId: { get: () => 'local' } } },
    profileColor: () => '#8b5cf6',
    PROFILE_SWATCHES: ['#8b5cf6'],
    queryClient: undefined,
    useQuery: vi.fn(),
    useValue: vi.fn()
  }
})

vi.mock('./shared', () => ({ getPluginCtx: () => null, ID: 'hermes-bots' }))

const MALICIOUS = [
  'red"/><image href=x onerror=alert(1)>',
  'url(javascript:alert(1))',
  'expression(alert(1))',
  '#fff" onload="x',
  'rgb(1,2,3)"/><script>',
  'hsl(1,2%,3%);background:url(x)',
  'rgb(0, 0, 0',
  '#12',
  '#12345',
  '<svg onload=x>',
  ''
]

const VALID = [
  '#fff',
  '#ffff',
  '#38bdf8',
  '#38BDF8cc',
  'rgb(10, 20, 30)',
  'rgba(10,20,30,0.5)',
  'rgb(10 20 30 / 50%)',
  'rgb(10%, 20%, 30%)',
  'hsl(210, 50%, 40%)',
  'hsla(210deg, 50%, 40%, .5)'
]

describe('safeAvatarColor', () => {
  it.each(MALICIOUS)('rejects %j', async value => {
    const { safeAvatarColor } = await import('./avatar-color')

    expect(safeAvatarColor(value)).toBeNull()
  })

  it.each(VALID)('passes %j through', async value => {
    const { safeAvatarColor } = await import('./avatar-color')

    expect(safeAvatarColor(value)).toBe(value)
  })

  it('rejects non-strings', async () => {
    const { safeAvatarColor } = await import('./avatar-color')

    expect(safeAvatarColor(null)).toBeNull()
    expect(safeAvatarColor(undefined)).toBeNull()
    expect(safeAvatarColor(42 as unknown as string)).toBeNull()
  })
})

describe('isDarkAvatarColor', () => {
  it('classifies hex, rgb and hsl bodies', async () => {
    const { isDarkAvatarColor } = await import('./avatar-color')

    expect(isDarkAvatarColor('#1a1a2a')).toBe(true)
    expect(isDarkAvatarColor('#fff')).toBe(false)
    expect(isDarkAvatarColor('rgb(10, 10, 20)')).toBe(true)
    expect(isDarkAvatarColor('rgb(240, 240, 250)')).toBe(false)
    expect(isDarkAvatarColor('hsl(240, 30%, 10%)')).toBe(true)
    expect(isDarkAvatarColor('hsl(40, 90%, 70%)')).toBe(false)
  })
})

const ALLOWED_ELEMENTS = new Set(['svg', 'g', 'path', 'rect', 'circle'])

function auditMarkup(container: HTMLElement) {
  const svg = container.querySelector('svg')!
  const nodes = [svg, ...Array.from(svg.querySelectorAll('*'))]

  for (const node of nodes) {
    expect(ALLOWED_ELEMENTS.has(node.localName)).toBe(true)

    for (const attr of Array.from(node.attributes)) {
      expect(attr.name.startsWith('on')).toBe(false)
    }
  }
}

describe('a hostile meta colour never reaches avatar markup', () => {
  it.each(MALICIOUS.filter(Boolean))('renders %j as the deterministic colour', async value => {
    const { BotFace, botAppearance } = await import('./avatar')

    const appearance = botAppearance('alpha', { color: value, custom: true, shape: 'blobatar' })

    expect(appearance.color).toBe('#8b5cf6')

    const { container } = render(<BotFace color={value} name="alpha" shape="blobatar" size={48} />)

    auditMarkup(container)
    expect(container.innerHTML).not.toContain('image')
    expect(container.innerHTML).not.toContain('onerror')
    expect(container.innerHTML).not.toContain('onload')
  })

  it('renders a valid colour as the body fill', async () => {
    const { BotFace } = await import('./avatar')
    const { container } = render(<BotFace color="#38bdf8" name="alpha" shape="blobatar" size={48} />)

    auditMarkup(container)
    expect(container.querySelector('svg [fill="#38bdf8"]')).toBeTruthy()
  })
})

describe('eyes stay visible on any body', () => {
  it('lights the blob eyes on a dark body and darkens them on a light one', async () => {
    const { BotFace } = await import('./avatar')

    const dark = render(<BotFace color="#1a1a2a" name="alpha" shape="blobatar" size={48} />)

    expect(dark.container.querySelector('[data-hb-eyes]')?.getAttribute('fill')).toBe('#f3f4fd')
    dark.unmount()

    const light = render(<BotFace color="#fde68a" name="alpha" shape="blobatar" size={48} />)

    expect(light.container.querySelector('[data-hb-eyes]')?.getAttribute('fill')).toBe('#1b1b1b')
  })

  it('lights the math-face eyes on a dark body and darkens them on a light one', async () => {
    const { BotFace } = await import('./avatar')

    const dark = render(<BotFace color="#1a1a2a" name="alpha" shape="circle" size={48} />)

    expect(dark.container.querySelector('[data-hb-eye] path')?.getAttribute('fill')).toBe('#f3f4fd')
    dark.unmount()

    const light = render(<BotFace color="#fde68a" name="alpha" shape="circle" size={48} />)

    expect(light.container.querySelector('[data-hb-eye] path')?.getAttribute('fill')).toBe('#1b1b1b')
  })
})
