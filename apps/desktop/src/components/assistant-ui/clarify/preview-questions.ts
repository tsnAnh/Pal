import type { ClarifyQuestion } from '@/store/clarify'

import type { ClarifyArgs } from './parse'

export const previewQuestionsOf = (fromArgs?: ClarifyArgs): ClarifyQuestion[] =>
  (fromArgs?.questions ?? []).map((entry, index) => ({
    choices: entry.choices ?? null,
    multiSelect: entry.multiSelect ?? false,
    qid: `args-${index}`,
    question: entry.question
  }))
