import { atom, useValue } from '@hermes/plugin-sdk'
import { useEffect } from 'react'

import type { RosterRow } from './types'

export interface RoutineOpenRequest {
  botKey: string
  jobId: string
}

type DeletableBot = RosterRow & { path?: string }

export const $botDeleteRequest = atom<DeletableBot | null>(null)

export const requestBotDelete = (bot: RosterRow) => $botDeleteRequest.set(bot)

export const $routineOpenRequest = atom<null | RoutineOpenRequest>(null)

export function useBotDeleteRequest(onDelete: (bot: DeletableBot) => void) {
  const request = useValue($botDeleteRequest)

  useEffect(() => {
    if (request) {
      onDelete(request)
      $botDeleteRequest.set(null)
    }
  }, [onDelete, request])
}

export function useRoutineOpenRequest(ownerKey: null | string, onOpen: (jobId: string) => void) {
  const request = useValue($routineOpenRequest)

  useEffect(() => {
    if (request && ownerKey && request.botKey === ownerKey) {
      onOpen(request.jobId)
      $routineOpenRequest.set(null)
    }
  }, [onOpen, ownerKey, request])
}
