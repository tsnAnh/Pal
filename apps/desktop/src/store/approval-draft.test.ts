import { describe, expect, it } from 'vitest'

import { parseApprovalDraft, parseApprovalScope } from './approval-draft'

describe('parseApprovalDraft', () => {
  it('reads the wire shape the backend sends', () => {
    expect(
      parseApprovalDraft({
        channel: 'Gmail',
        editable: true,
        expires_at: 1700000000,
        held: true,
        kind: 'outbound_message',
        recipient: 'ada@example.com',
        state: 'expired',
        subject: 'Lunch',
        text: 'Lunch at noon?'
      })
    ).toEqual({
      channel: 'Gmail',
      details: [],
      editable: true,
      expiresAt: 1700000000,
      held: true,
      recipient: 'ada@example.com',
      state: 'expired',
      subject: 'Lunch',
      text: 'Lunch at noon?',
      unviewable: false
    })
  })

  it('defaults to a pending, read-only draft and tolerates missing fields', () => {
    expect(parseApprovalDraft({ text: 'hi' })).toEqual({
      channel: '',
      details: [],
      editable: false,
      expiresAt: undefined,
      held: false,
      recipient: '',
      state: 'pending',
      subject: '',
      text: 'hi',
      unviewable: false
    })
  })

  it('ignores anything that is not an outbound draft', () => {
    expect(parseApprovalDraft(undefined)).toBeUndefined()
    expect(parseApprovalDraft('draft')).toBeUndefined()
    expect(parseApprovalDraft({ kind: 'something_else', text: 'x' })).toBeUndefined()
  })
})

describe('parseApprovalScope', () => {
  it('knows only the bot chat scope', () => {
    expect(parseApprovalScope('bot_chat')).toBe('bot_chat')
    expect(parseApprovalScope('session')).toBeUndefined()
    expect(parseApprovalScope(undefined)).toBeUndefined()
  })
})

describe('parseApprovalDraft details and viewability', () => {
  const base = { channel: 'Gmail', kind: 'outbound_message', text: 'Hi' }

  it('keeps well-formed details and drops malformed entries', () => {
    const draft = parseApprovalDraft(base, {
      details: [{ name: 'Cc', value: 'bob@example.com' }, { name: 'x' }, null, { name: '', value: 'y' }, 'z']
    })

    expect(draft?.details).toEqual([{ name: 'Cc', value: 'bob@example.com' }])
  })

  it('tolerates absent or non-array details', () => {
    expect(parseApprovalDraft(base)?.details).toEqual([])
    expect(parseApprovalDraft(base, { details: 'nope' })?.details).toEqual([])
  })

  it('caps the number and size of details', () => {
    const many = Array.from({ length: 80 }, (_, index) => ({ name: `n${index}`, value: 'v'.repeat(9000) }))
    const draft = parseApprovalDraft(base, { details: many })

    expect(draft?.details).toHaveLength(50)
    expect(draft?.details[0].value).toHaveLength(4000)
  })

  it('marks a pending draft unviewable only when once is not offered', () => {
    expect(parseApprovalDraft(base, { choices: ['deny'] })?.unviewable).toBe(true)
    expect(parseApprovalDraft(base, { choices: ['once', 'deny'] })?.unviewable).toBe(false)
    expect(parseApprovalDraft(base)?.unviewable).toBe(false)
    expect(parseApprovalDraft({ ...base, state: 'expired' }, { choices: ['deny'] })?.unviewable).toBe(false)
  })
})
