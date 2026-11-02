import { ClarifyQuestionBlock, ClarifyShell, host } from '@hermes/plugin-sdk'
import type { ClarifyQuestion } from '@hermes/plugin-sdk'
import { type FormEvent, type ReactNode, useMemo, useState } from 'react'

import { useAboutYouName } from './about-you'
import {
  answerOnboarding,
  dismissOnboarding,
  ONBOARDING_PURPOSES,
  type OnboardingFailure,
  sendFirstMessage,
  settleOnboarding
} from './bot-onboarding'
import { useBots } from './i18n'
import type { RosterRow } from './types'

interface BotOnboardingProps {
  bot: RosterRow
  face: ReactNode
  name: string
  sessionId: string
}

export function BotOnboarding({ bot, face, name, sessionId }: BotOnboardingProps) {
  const b = useBots()
  const userName = useAboutYouName()
  const [draft, setDraft] = useState('')
  const [pending, setPending] = useState(false)
  const [failure, setFailure] = useState<null | OnboardingFailure>(null)

  const question = useMemo<ClarifyQuestion>(
    () => ({
      choices: ONBOARDING_PURPOSES.map(id => b.onboarding.options[id]),
      multiSelect: false,
      qid: 'bot-onboarding',
      question: b.onboarding.question
    }),
    [b]
  )

  const answer = async (purpose: string) => {
    const text = purpose.trim()

    if (!text || pending) {
      return
    }

    setPending(true)
    setFailure(null)
    const refused = await answerOnboarding(bot, text)

    if (refused) {
      setFailure(refused)
      setPending(false)

      return
    }

    if (!sendFirstMessage(sessionId, b.onboarding.firstMessage(text))) {
      host.notify({ kind: 'error', message: b.onboarding.saveFailed })
    }

    settleOnboarding(bot)
  }

  const dismiss = async () => {
    if (pending) {
      return
    }

    setPending(true)
    setFailure(null)
    const refused = await dismissOnboarding(bot)

    if (refused) {
      setFailure(refused)
      setPending(false)
    }
  }

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    void answer(draft)
  }

  return (
    <div className="pointer-events-auto flex w-full max-w-xl flex-col gap-3 px-4 text-left" data-slot="bot-onboarding">
      <div className="flex items-start gap-2.5">
        <div className="mt-0.5 shrink-0">{face}</div>
        <p
          className="m-0 rounded-2xl bg-(--ui-bg-tertiary) px-3.5 py-2 text-[length:var(--conversation-text-font-size)] leading-6 text-(--ui-text-primary)"
          data-slot="bot-onboarding-greeting"
        >
          {userName ? b.onboarding.greetingNamed(userName, name) : b.onboarding.greeting(name)}
        </p>
      </div>
      <form data-slot="bot-onboarding-card" onSubmit={submit}>
        <ClarifyShell className="grid gap-3">
          <ClarifyQuestionBlock
            cursor={null}
            disabled={pending}
            onActivate={() => undefined}
            onClose={() => void dismiss()}
            onDraft={setDraft}
            onOtherFocus={() => undefined}
            onPick={index => void answer(question.choices?.[index] ?? '')}
            question={question}
            send={{ enabled: draft.trim().length > 0, submitting: pending }}
            staged={{ choices: [], draft }}
          />
          {failure ? (
            <p aria-live="polite" className="m-0 text-xs text-(--ui-text-tertiary)" role="status">
              {failure === 'rejected' ? b.onboarding.rejected : b.onboarding.saveFailed}
            </p>
          ) : null}
        </ClarifyShell>
      </form>
    </div>
  )
}
