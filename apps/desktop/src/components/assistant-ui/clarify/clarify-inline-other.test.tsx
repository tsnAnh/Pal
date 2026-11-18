import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { I18nProvider } from '@/i18n'

import { QuestionBlock } from './core/question-block'

afterEach(cleanup)

const question = { choices: ['staging', 'production'], multiSelect: false, qid: 'q0', question: 'Which target?' }

function renderBlock(staged: { choices: string[]; draft: string }, onDraft = vi.fn()) {
  render(
    <I18nProvider configClient={null} initialLocale="en">
      <QuestionBlock
        cursor={null}
        disabled={false}
        onActivate={vi.fn()}
        onDraft={onDraft}
        onOtherFocus={vi.fn()}
        onPick={vi.fn()}
        question={question}
        staged={staged}
      />
    </I18nProvider>
  )

  return onDraft
}

describe('the free-text option is an inline row', () => {
  it('shows Something else as the placeholder of an input in the option list', () => {
    renderBlock({ choices: ['staging'], draft: '' })

    const input = screen.getByPlaceholderText('Something else')
    expect(input.className).toContain('placeholder:text-(--ui-text-secondary)')
    expect(input.className).toContain('text-(--ui-text-primary)')
    expect(input.closest('label')?.className).toContain('text-(--ui-text-secondary)')
  })

  it('reports typed text through the draft handler', () => {
    const onDraft = renderBlock({ choices: [], draft: '' })
    fireEvent.change(screen.getByPlaceholderText('Something else'), { target: { value: 'mint' } })
    expect(onDraft).toHaveBeenCalledWith('mint')
  })

  it('renders chosen rows in the primary colour and unchosen rows in the secondary colour', () => {
    renderBlock({ choices: ['staging'], draft: 'mint' })

    expect(screen.getByRole('button', { name: /staging/ }).className).toContain('text-(--ui-text-primary)')
    expect(screen.getByRole('button', { name: /production/ }).className).not.toContain('text-(--ui-text-primary)')
    expect(screen.getByRole('button', { name: /production/ }).className).toContain('text-(--ui-text-secondary)')
    expect(screen.getByPlaceholderText('Something else').closest('label')?.className).toContain('text-(--ui-text-primary)')
  })

  it('shares the option row classes and carries no border, ring or outline of its own', () => {
    renderBlock({ choices: [], draft: '' })

    const input = screen.getByPlaceholderText('Something else')
    const row = input.closest('label')?.className ?? ''
    const option = screen.getByRole('button', { name: /staging/ }).className

    for (const shared of ['min-h-12', 'rounded-xl', 'bg-(--ui-bg-quaternary)', 'py-3', 'pl-4', 'pr-4', 'gap-3', 'leading-6']) {
      expect(row).toContain(shared)
      expect(option).toContain(shared)
    }

    expect(input.className).toContain('border-0')
    expect(input.className).toContain('focus-visible:ring-0')
    expect(input.className).toContain('focus-visible:outline-none')
    expect(input.className).not.toMatch(/(^|\s)(ring-[1-9]|border(-[a-z]+)?-\(|focus:ring-[1-9]|focus-visible:ring-[1-9])/)
    expect(row).toContain('focus-within:text-(--ui-text-primary)')
    expect(row).not.toContain('focus-within:ring-2')
  })

  it('treats a whitespace-only draft as unchosen', () => {
    renderBlock({ choices: [], draft: '   ' })
    expect(screen.getByPlaceholderText('Something else').closest('label')?.className).not.toContain('ring-primary/60')
  })
})
