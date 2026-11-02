import { bareChoice, type ClarifyQuestion } from '@/store/clarify'

export interface StagedAnswer {
  choices: string[]
  draft: string
}

function parseReplayedAnswers(answer: string, multiSelect: boolean): string[] {
  if (!multiSelect) {
    return [answer]
  }

  try {
    const parsed = JSON.parse(answer)

    if (Array.isArray(parsed) && parsed.every(value => typeof value === 'string')) {
      return parsed
    }
  } catch {
    return [answer]
  }

  return [answer]
}

function replayedStage(question: ClarifyQuestion, answer: string): StagedAnswer {
  const options = question.choices ?? []
  const replayed = parseReplayedAnswers(answer, question.multiSelect ?? false)
  const choices = options.filter(choice => replayed.includes(bareChoice(choice)))
  const draft = replayed.filter(value => !options.some(choice => bareChoice(choice) === value)).join(', ')

  return { choices, draft }
}

export function replayLockedAnswers(
  current: Record<string, StagedAnswer>,
  questions: readonly ClarifyQuestion[],
  lockedAnswers: Record<string, null | string>,
  seenLocks: Record<string, null | string>
): Record<string, StagedAnswer> {
  const next = { ...current }

  for (const question of questions) {
    const answer = lockedAnswers[question.qid]

    if (answer === undefined || answer === null || seenLocks[question.qid] === answer) {
      continue
    }

    next[question.qid] = replayedStage(question, answer)
  }

  return next
}
