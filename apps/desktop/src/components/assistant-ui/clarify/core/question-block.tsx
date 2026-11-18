'use client'

import { Button } from '@/components/ui/button'
import { useI18n } from '@/i18n'
import { Loader2, X } from '@/lib/icons'
import type { ClarifyQuestion } from '@/store/clarify'

import { badgeFor, ChoiceButton, letterFor, OtherChoiceRow } from './choice-row'

interface QuestionBlockProps {
  cursor: null | number
  disabled: boolean
  onActivate: () => void
  onClose?: () => void
  onDraft: (value: string) => void
  onOtherFocus: () => void
  onPick: (index: number) => void
  question: ClarifyQuestion
  send?: { enabled: boolean; submitting: boolean }
  staged: { choices: string[]; draft: string }
}

/** One question's interactive block inside the live batch card. */
export function QuestionBlock({
  cursor,
  disabled,
  onActivate,
  onClose,
  onDraft,
  onOtherFocus,
  onPick,
  question,
  send,
  staged
}: QuestionBlockProps) {
  const { t } = useI18n()
  const copy = t.assistant.clarify
  const choices = question.choices ?? []
  const otherActive = cursor === choices.length

  return (
    <div
      className="grid gap-3"
      data-clarify-batch-question={question.qid}
      onFocus={onActivate}
      onPointerDown={onActivate}
    >
      <div className="flex items-start gap-3">
        <span className="min-w-0 flex-1 text-[0.9375rem] leading-6 font-semibold whitespace-pre-wrap wrap-anywhere">
          {question.question}
        </span>
        {choices.length > 0 && !send ? (
          <span
            className="mt-0.5 shrink-0 rounded-sm bg-(--chrome-action-hover) px-1 py-px text-[0.625rem] text-(--ui-text-tertiary)"
            data-clarify-select-mode={question.multiSelect ? 'multi' : 'single'}
          >
            {question.multiSelect ? copy.multiSelectHint : copy.singleSelectHint}
          </span>
        ) : null}
        {onClose ? (
          <Button
            aria-label={copy.close}
            className="-mt-0.5 -mr-1 shrink-0 text-(--ui-text-tertiary)"
            disabled={disabled}
            onClick={onClose}
            size="icon-xs"
            type="button"
            variant="ghost"
          >
            <X />
          </Button>
        ) : null}
      </div>

      {choices.length > 0 ? (
        <div className="grid gap-2" role="group">
          {choices.map((choice, index) => (
            <ChoiceButton
              active={cursor === index}
              char={badgeFor(index)}
              choice={choice}
              disabled={disabled}
              key={`${index}-${choice}`}
              keyShortcuts={cursor === null || index >= 26 ? undefined : `${letterFor(index)} ${index + 1}`}
              onClick={() => onPick(index)}
              selected={staged.choices.includes(choice)}
            />
          ))}
        </div>
      ) : null}

      <div className="flex flex-wrap items-center gap-2">
        <div className="min-w-0 flex-[1_1_12rem]">
          <OtherChoiceRow
            active={otherActive}
            char={badgeFor(choices.length)}
            selected={staged.draft.trim() !== ''}
          >
            <input
              aria-current={otherActive || undefined}
              aria-keyshortcuts={cursor === null || choices.length >= 26 ? undefined : `${letterFor(choices.length)} ${choices.length + 1}`}
              autoCapitalize="off"
              autoComplete="off"
              autoCorrect="off"
              className="min-w-0 flex-1 appearance-none border-0 bg-transparent p-0 text-(--ui-text-primary) shadow-none ring-0 outline-none placeholder:text-(--ui-text-secondary) focus:ring-0 focus:outline-none focus-visible:ring-0 focus-visible:outline-none disabled:cursor-default"
              data-clarify-other=""
              data-highlighted={otherActive || undefined}
              disabled={disabled}
              onChange={event => onDraft(event.target.value)}
              onFocus={onOtherFocus}
              onKeyDown={send ? undefined : event => event.key === 'Enter' && event.preventDefault()}
              placeholder={choices.length > 0 ? copy.other : copy.placeholder}
              type="text"
              value={staged.draft}
            />
          </OtherChoiceRow>
        </div>
        {send ? (
          <Button
            className="h-10 shrink-0 rounded-full px-5 text-sm @max-xs:flex-1"
            disabled={disabled || !send.enabled}
            size="default"
            type="submit"
          >
            {send.submitting ? <Loader2 className="animate-spin" /> : copy.send}
          </Button>
        ) : null}
      </div>
    </div>
  )
}

export const emptyStage = { choices: [] as string[], draft: '' }
