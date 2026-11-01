import { describe, expect, it, vi } from 'vitest'

import { submitLatestWins } from './avatar-save-queue'

interface Deferred<T> {
  reject: (error: unknown) => void
  resolve: (value: T) => void
  promise: Promise<T>
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((res, rej) => ((resolve = res), (reject = rej)))

  return { promise, resolve, reject }
}

let lane = 0
const flush = () => new Promise(resolve => setTimeout(resolve, 0))

function harness() {
  const bot = `bot-${lane++}`

  const server: Record<string, unknown>[] = []
  const calls: Deferred<string>[] = []

  const run = vi.fn((patch: Record<string, unknown>) => {
    server.push(patch)
    const call = deferred<string>()

    calls.push(call)

    return call.promise
  })

  return { bot, server, calls, run, settle: vi.fn() }
}

describe('submitLatestWins', () => {
  it('starts the first save at once and holds later ones until it settles', async () => {
    const { bot, calls, run, settle } = harness()

    submitLatestWins(bot, { shape: 'a' }, run, settle)
    submitLatestWins(bot, { shape: 'b' }, run, settle)
    submitLatestWins(bot, { shape: 'c' }, run, settle)

    expect(run).toHaveBeenCalledTimes(1)
    calls[0]!.resolve('first')
    await flush()
    expect(run).toHaveBeenCalledTimes(2)
    expect(run).toHaveBeenLastCalledWith({ shape: 'c' })
    calls[1]!.resolve('last')
    await flush()

    expect(settle).toHaveBeenCalledTimes(1)
    expect(settle).toHaveBeenCalledWith({ ok: true, value: 'last' })
  })

  it('merges the queued picks so no field is lost to a later pick', async () => {
    const { bot, calls, run, settle } = harness()

    submitLatestWins(bot, { shape: 'a', custom: true }, run, settle)
    submitLatestWins(bot, { shape: 'b' }, run, settle)
    submitLatestWins(bot, { color: 'red' }, run, settle)
    calls[0]!.resolve('x')
    await flush()

    expect(run).toHaveBeenLastCalledWith({ shape: 'b', color: 'red' })
  })

  it('ignores the failure of a superseded save and reports only the final one', async () => {
    const { bot, calls, run, settle } = harness()

    submitLatestWins(bot, { shape: 'a' }, run, settle)
    submitLatestWins(bot, { shape: 'b' }, run, settle)
    calls[0]!.reject(new Error('conflict'))
    await flush()

    expect(settle).not.toHaveBeenCalled()

    calls[1]!.reject(new Error('still failing'))
    await flush()

    expect(settle).toHaveBeenCalledTimes(1)
    expect(settle.mock.calls[0]![0]).toMatchObject({ ok: false })
  })

  it('leaves the final server state at the last pick whatever order saves settle in', async () => {
    const { bot, calls, run, server, settle } = harness()

    submitLatestWins(bot, { shape: 'a' }, run, settle)
    submitLatestWins(bot, { shape: 'b' }, run, settle)
    submitLatestWins(bot, { shape: 'c' }, run, settle)
    calls[0]!.resolve('x')
    await flush()
    calls[1]!.resolve('x')
    await flush()

    expect(server.at(-1)).toEqual({ shape: 'c' })
    expect(run).toHaveBeenCalledTimes(2)
  })

  it('keeps bots independent and runs a fresh save after the lane drains', async () => {
    const { bot, calls, run, settle } = harness()

    submitLatestWins('one', { shape: 'a' }, run, settle)
    submitLatestWins('two', { shape: 'b' }, run, settle)

    expect(run).toHaveBeenCalledTimes(2)
    calls[0]!.resolve('x')
    calls[1]!.resolve('y')
    await flush()
    submitLatestWins('one', { shape: 'c' }, run, settle)

    expect(run).toHaveBeenCalledTimes(3)
    expect(run).toHaveBeenLastCalledWith({ shape: 'c' })
  })
})
