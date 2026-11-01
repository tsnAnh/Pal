export type SaveSettled<R> = { ok: false; error: unknown } | { ok: true; value: R }

interface Lane<P extends object, R> {
  pending: null | P
  run: (patch: P) => Promise<R>
  settle: (settled: SaveSettled<R>) => void
}

const lanes = new Map<string, Lane<never, never>>()

async function attempt<P extends object, R>(lane: Lane<P, R>, patch: P): Promise<SaveSettled<R>> {
  try {
    return { ok: true, value: await lane.run(patch) }
  } catch (error) {
    return { ok: false, error }
  }
}

async function drain<P extends object, R>(key: string, lane: Lane<P, R>) {
  while (lane.pending) {
    const patch = lane.pending

    lane.pending = null

    const settled = await attempt(lane, patch)

    if (!lane.pending) {
      lane.settle(settled)
    }
  }

  lanes.delete(key)
}

export function submitLatestWins<P extends object, R>(
  key: string,
  patch: P,
  run: (patch: P) => Promise<R>,
  settle: (settled: SaveSettled<R>) => void
) {
  const existing = lanes.get(key) as Lane<P, R> | undefined

  if (existing) {
    existing.pending = { ...existing.pending, ...patch }
    existing.run = run
    existing.settle = settle

    return
  }

  const lane: Lane<P, R> = { pending: patch, run, settle }

  lanes.set(key, lane as unknown as Lane<never, never>)
  void drain(key, lane)
}
