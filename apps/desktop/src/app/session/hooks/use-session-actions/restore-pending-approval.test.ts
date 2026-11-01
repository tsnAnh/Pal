import { beforeEach, describe, expect, it, vi } from 'vitest'

const replayPendingApproval = vi.fn(() => Promise.resolve())
const receiveApprovalRequest = vi.fn(() => Promise.resolve())

vi.mock('@/store/prompts', () => ({
  receiveApprovalRequest: (...args: unknown[]) => receiveApprovalRequest(...(args as [])),
  replayPendingApproval: (...args: unknown[]) => replayPendingApproval(...(args as []))
}))

vi.mock('@/store/gateway', () => ({ $gateway: { get: () => ({ request: vi.fn() }) } }))

import type { SessionResumeResult } from '@/types/hermes'

import { restorePendingApproval } from './restore-pending-approval'

beforeEach(() => {
  replayPendingApproval.mockClear()
  receiveApprovalRequest.mockClear()
})

describe('restorePendingApproval', () => {
  it('replays the queue even when the snapshot carries no approval, so held drafts surface on open', () => {
    expect(restorePendingApproval({} as SessionResumeResult, 'sess-1')).toBe(false)
    expect(replayPendingApproval).toHaveBeenCalledWith(expect.anything(), 'sess-1')
    expect(receiveApprovalRequest).not.toHaveBeenCalled()
  })

  it('keeps the draft and the Bot Chat scope of a restored approval', () => {
    const response = {
      pending_approval: {
        command: 'Lunch at noon?',
        draft: { channel: 'Gmail', editable: true, recipient: 'ada@example.com', text: 'Lunch at noon?' },
        request_id: 'req-1',
        scope: 'bot_chat'
      }
    } as unknown as SessionResumeResult

    expect(restorePendingApproval(response, 'sess-1')).toBe(true)
    expect(receiveApprovalRequest).toHaveBeenCalledWith(
      null,
      expect.objectContaining({
        draft: expect.objectContaining({ channel: 'Gmail', editable: true, text: 'Lunch at noon?' }),
        requestId: 'req-1',
        scope: 'bot_chat'
      })
    )
  })
})
