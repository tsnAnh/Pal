'use client'

import type { ReactNode } from 'react'

import { cn } from '@/lib/utils'
import { bareChoice, RECOMMENDED_LABEL } from '@/store/clarify'

export const letterFor = (index: number): string => String.fromCharCode(65 + index)

export const badgeFor = (index: number): string => (index < 26 ? letterFor(index) : String(index + 1))

// The backend tags the agent's preferred option (`mark_recommended`); the card
// renders the label in tertiary text so the option itself still reads first.
export function ChoiceLabel({ choice }: { choice: string }) {
  const bare = bareChoice(choice)

  if (bare === choice) {
    return <>{choice}</>
  }

  return (
    <>
      {bare} <span className="text-(--ui-text-tertiary)">{RECOMMENDED_LABEL}</span>
    </>
  )
}

export function KeyBadge({
  char,
  disabled,
  className,
  preview,
  selected
}: {
  char: string
  className?: string
  disabled?: boolean
  preview?: boolean
  selected: boolean
}) {
  return (
    <span
      aria-hidden
      className={cn(
        'mt-px grid size-6 shrink-0 place-items-center rounded-md bg-(--ui-bg-tertiary) text-[0.6875rem] font-medium leading-none text-(--ui-text-secondary) select-none',
        disabled && 'opacity-50',
        preview && 'bg-[color-mix(in_srgb,var(--theme-primary)_18%,transparent)] text-primary',
        selected && 'bg-primary text-primary-foreground',
        className
      )}
    >
      {char}
    </span>
  )
}

/** A letter-badged option row. */
export function ChoiceButton({
  active = false,
  char,
  choice,
  disabled,
  keyShortcuts,
  onClick,
  selected
}: {
  active?: boolean
  char: string
  choice: string
  disabled?: boolean
  keyShortcuts?: string
  onClick: () => void
  selected?: boolean
}) {
  return (
    <button
      aria-current={active || undefined}
      aria-keyshortcuts={keyShortcuts}
      aria-pressed={selected}
      className={cn(
        'flex min-h-12 w-full cursor-pointer items-start gap-3 rounded-xl bg-(--ui-bg-quaternary) py-3 pr-4 pl-4 text-left text-[length:var(--conversation-text-font-size)] leading-6 text-(--ui-text-secondary) outline-none transition-colors duration-100 motion-reduce:transition-none',
        'hover:bg-(--chrome-action-hover) focus-visible:ring-2 focus-visible:ring-ring/60 disabled:cursor-default disabled:aria-[pressed=false]:opacity-50',
        active && 'bg-(--chrome-action-hover) ring-1 ring-(--ui-stroke-secondary)',
        selected && 'bg-(--chrome-action-hover) text-(--ui-text-primary) ring-1 ring-primary/60'
      )}
      data-choice
      data-highlighted={active || undefined}
      disabled={disabled}
      onClick={onClick}
      type="button"
    >
      <KeyBadge char={char} preview={active} selected={Boolean(selected)} />
      <span className="min-w-0 flex-1 wrap-anywhere whitespace-pre-wrap">
        <ChoiceLabel choice={choice} />
      </span>
    </button>
  )
}

/** The free-text option: an inline input that reads as one more option row. */
export function OtherChoiceRow({
  active,
  char,
  children,
  selected
}: {
  active: boolean
  char: string
  children: ReactNode
  selected: boolean
}) {
  return (
    <label
      className={cn(
        'flex min-h-12 w-full cursor-text items-start gap-3 rounded-xl bg-(--ui-bg-quaternary) py-3 pr-4 pl-4 text-left text-[length:var(--conversation-text-font-size)] leading-6 text-(--ui-text-secondary) transition-colors duration-100 motion-reduce:transition-none',
        'group/other hover:bg-(--chrome-action-hover) focus-within:bg-(--chrome-action-hover) focus-within:text-(--ui-text-primary) focus-within:ring-1 focus-within:ring-primary/60',
        active && 'bg-(--chrome-action-hover) ring-1 ring-(--ui-stroke-secondary)',
        selected && 'bg-(--chrome-action-hover) text-(--ui-text-primary) ring-1 ring-primary/60'
      )}
    >
      <KeyBadge
        char={char}
        className="group-focus-within/other:bg-primary group-focus-within/other:text-primary-foreground"
        preview={active}
        selected={selected}
      />
      {children}
    </label>
  )
}
