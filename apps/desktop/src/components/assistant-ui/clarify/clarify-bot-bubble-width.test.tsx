import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { cleanup, render } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'

import { ClarifyShell } from './core/shell'

function botBubble(content: React.ReactNode) {
  const { container } = render(
    <div data-bot-chat>
      <div data-slot="bot-reply-row" style={{ display: 'flex' }}>
        <div data-bubble="assistant">{content}</div>
      </div>
    </div>
  )

  return container.querySelector<HTMLElement>('[data-bubble="assistant"]')!
}

const stylesheet = readFileSync(resolve(__dirname, '../../../styles.css'), 'utf8')

describe('Bot Chat bubble holding a clarify card', () => {
  const style = document.createElement('style')
  style.textContent = stylesheet.replace(/@import[^;]*;/g, '')
  document.head.append(style)

  afterEach(cleanup)

  it('gets a definite width because the card is an inline-size container', () => {
    const bubble = botBubble(<ClarifyShell />)

    expect(bubble.querySelector('[data-slot="clarify-inline"]')!.className).toContain('@container')
    expect(getComputedStyle(bubble).width).toBe('100%')
  })

  it('leaves bubbles without a card shrink-to-fit', () => {
    const bubble = botBubble(<p>plain reply</p>)

    expect(getComputedStyle(bubble).width).not.toBe('100%')
  })
})
