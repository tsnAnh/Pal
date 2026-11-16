import { act, cleanup } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { chatMessageText, textPart } from '@/lib/chat-messages'

import { type MessageStreamHarness, renderMessageStream } from './test-harness'
import { STREAM_DELTA_FLUSH_MS } from './utils'

const SID = 'absorb-session'
const OTHER = 'absorb-background'
const TURN = 'turn-1'

let stream: MessageStreamHarness

const send = (type: string, payload: Record<string, unknown>, sessionId = SID) =>
  act(() => stream.handleEvent({ payload, session_id: sessionId, type: type as never }))

const start = (sessionId = SID) => send('message.start', { turn_id: TURN }, sessionId)

const delta = (text: string, segment = 0, offset = 0, sessionId = SID) =>
  send('message.delta', { offset, segment, text, turn_id: TURN }, sessionId)

const absorbed = (ids: string[], text: string, sessionId = SID) =>
  send('input.absorbed', { admission_ids: ids, message_uid: `uid-${ids.join('-')}`, text, turn_id: TURN }, sessionId)

const flush = () => act(async () => void (await vi.advanceTimersByTimeAsync(STREAM_DELTA_FLUSH_MS + 10)))

const transcript = (sessionId = SID) =>
  stream
    .state(sessionId)
    .messages.filter(message => !message.hidden)
    .map(message => `${message.role}:${chatMessageText(message)}`)

describe('input.absorbed: the owner message lands inside the running turn', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    stream = renderMessageStream(SID)
  })

  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('seals the streaming segment, places the owner bubble, and opens a new segment after it', async () => {
    await start()
    await delta('Merging the six PRs. ')
    await flush()
    await absorbed(['adm-1'], 'also what is the weather in Hanoi?')
    await delta('24 degrees and clear.', 0, 21)
    await flush()

    expect(transcript()).toEqual([
      'assistant:Merging the six PRs. ',
      'user:also what is the weather in Hanoi?',
      'assistant:24 degrees and clear.'
    ])

    const [sealed, , live] = stream.state().messages

    expect(sealed.pending).not.toBe(true)
    expect(sealed.interrupted).not.toBe(true)
    expect(live.pending).toBe(true)
    expect(stream.state()).toMatchObject({ busy: true, turnLive: true, streamTurnId: TURN })
  })

  it('flushes deltas still waiting for the batch tick into the sealed segment, not after the bubble', async () => {
    await start()
    await delta('buffered words')
    await absorbed(['adm-1'], 'hello')
    await flush()

    expect(transcript()).toEqual(['assistant:buffered words', 'user:hello'])
  })

  it('keeps the turn running: busy and turnLive stay true and the turn id is unchanged', async () => {
    await start()
    await delta('working')
    await flush()
    await absorbed(['adm-1'], 'status?')

    expect(stream.state()).toMatchObject({ busy: true, turnLive: true, streamTurnId: TURN })
    expect(stream.state().interrupted).toBeFalsy()
  })

  it('settles the turn as usual after the owner bubble', async () => {
    await start()
    await delta('Merging. ')
    await flush()
    await absorbed(['adm-1'], 'weather?')
    await delta('Clear skies.', 0, 9)
    await flush()
    await send('message.complete', { status: 'complete', text: 'Clear skies.' })

    expect(transcript()).toEqual(['assistant:Merging. ', 'user:weather?', 'assistant:Clear skies.'])
    expect(stream.state().messages.every(message => message.pending !== true)).toBe(true)
    expect(stream.state().busy).toBe(false)
  })

  it('replaying the same event places one bubble', async () => {
    await start()
    await delta('Merging. ')
    await flush()
    await absorbed(['adm-1'], 'weather?')
    await absorbed(['adm-1'], 'weather?')
    await delta('Clear skies.', 0, 9)
    await flush()
    await absorbed(['adm-1'], 'weather?')

    expect(transcript()).toEqual(['assistant:Merging. ', 'user:weather?', 'assistant:Clear skies.'])
  })

  it('a full reconnect replay of the turn reproduces the same order', async () => {
    const frames = async () => {
      await start()
      await delta('Merging. ', 0, 0)
      await flush()
      await absorbed(['adm-1'], 'weather?')
      await delta('Clear skies.', 0, 9)
      await flush()
    }

    await frames()
    const first = transcript()
    await frames()

    expect(first).toEqual(['assistant:Merging. ', 'user:weather?', 'assistant:Clear skies.'])
    expect(transcript()).toEqual(first)
  })

  it('two admissions absorbed in one event place one bubble with the joined row text', async () => {
    await start()
    await delta('Merging. ')
    await flush()
    await absorbed(['adm-1', 'adm-2'], 'first thing\n\nsecond thing')
    await delta('On both.', 0, 9)
    await flush()

    expect(transcript()).toEqual(['assistant:Merging. ', 'user:first thing\n\nsecond thing', 'assistant:On both.'])
  })

  it('confirms the local echo of an admission instead of adding a second bubble', async () => {
    await start()
    await delta('Merging. ')
    await flush()
    stream.states.set(SID, {
      ...stream.state(),
      messages: [...stream.state().messages, { id: 'user-adm-1', role: 'user', parts: [textPart('weather?')] }],
      streamId: stream.state().streamId
    })
    await absorbed(['adm-1'], 'weather?')
    await delta('Clear skies.', 0, 9)
    await flush()

    expect(transcript()).toEqual(['assistant:Merging. ', 'user:weather?', 'assistant:Clear skies.'])
    expect(stream.state().messages.filter(message => message.id === 'user-adm-1')).toHaveLength(1)
  })

  it('placed before message.start: the bubble stands at the tail and the turn streams below it', async () => {
    await absorbed(['adm-1'], 'are you there?')

    expect(transcript()).toEqual(['user:are you there?'])
    expect(stream.state().busy).toBeFalsy()

    await start()
    await delta('Yes.')
    await flush()

    expect(transcript()).toEqual(['user:are you there?', 'assistant:Yes.'])
  })

  it('shows nothing for an absorption without text and without a local echo', async () => {
    await start()
    await delta('Merging. ')
    await flush()
    await absorbed(['adm-1'], '')
    await delta('more', 0, 9)
    await flush()

    expect(transcript()).toEqual(['assistant:Merging. more'])
  })

  it('leaves a tool the turn is still waiting on running inside the sealed segment', async () => {
    await start()
    await delta('Running the merge. ')
    await flush()
    await send('tool.start', { args: { command: 'merge' }, name: 'terminal', tool_id: 'call-1' })
    await absorbed(['adm-1'], 'weather?')
    await send('tool.complete', { name: 'terminal', result: 'merged 4 of 6', tool_id: 'call-1' })

    const [sealed] = stream.state().messages
    const call = sealed.parts.find(part => part.type === 'tool-call')

    expect(call).toMatchObject({ toolCallId: 'call-1', result: 'merged 4 of 6' })
    expect(call).not.toMatchObject({ interrupted: true })
    expect(stream.state().messages.map(message => message.role)).toEqual(['assistant', 'user'])
  })

  it('reads the fields from the event itself when the frame is flat', async () => {
    await start()
    await delta('Merging. ')
    await flush()
    act(() =>
      stream.handleEvent({
        admission_ids: ['adm-1'],
        message_uid: 'uid-1',
        session_id: SID,
        text: 'flat frame',
        turn_id: TURN,
        type: 'input.absorbed'
      } as never)
    )

    expect(transcript()).toEqual(['assistant:Merging. ', 'user:flat frame'])
  })

  it('ignores a frame that names no admission', async () => {
    await start()
    await delta('Merging. ')
    await flush()
    await send('input.absorbed', { admission_ids: [], text: 'orphan', turn_id: TURN })

    expect(transcript()).toEqual(['assistant:Merging. '])
  })

  it('places the bubble in a session that is not the one on screen', async () => {
    await start(OTHER)
    await delta('Background work. ', 0, 0, OTHER)
    await flush()
    await absorbed(['adm-9'], 'quick question', OTHER)

    expect(transcript(OTHER)).toEqual(['assistant:Background work. ', 'user:quick question'])
    expect(transcript()).toEqual([])
  })

  it('a turn that never receives the event keeps streaming into one segment', async () => {
    await start()
    await delta('Merging. ')
    await delta('Still merging.', 0, 9)
    await flush()

    expect(transcript()).toEqual(['assistant:Merging. Still merging.'])
  })
})
