export type Dots = readonly [number, number, number]

export interface AvatarPose {
  bodyRotation: number
  bodyScaleX: number
  bodyScaleY: number
  bodyX: number
  bodyY: number
  dots: Dots
  eyeDot: number
  eyeHappy: number
  eyeOpen: number
  eyeRoll: number
  eyeScale: number
  eyeSpread: number
  eyeX: number
  eyeY: number
  front: number
  opacity: number
}

export type PoseField = Exclude<keyof AvatarPose, 'dots'>

export const POSE_FIELDS: readonly PoseField[] = [
  'front',
  'eyeX',
  'eyeY',
  'eyeRoll',
  'eyeSpread',
  'eyeScale',
  'eyeDot',
  'eyeHappy',
  'eyeOpen',
  'bodyX',
  'bodyY',
  'bodyScaleX',
  'bodyScaleY',
  'bodyRotation',
  'opacity'
]

export const REST_POSE: AvatarPose = {
  bodyRotation: 0,
  bodyScaleX: 1,
  bodyScaleY: 1,
  bodyX: 0,
  bodyY: 0,
  dots: [0, 0, 0],
  eyeDot: 0,
  eyeHappy: 0,
  eyeOpen: 1,
  eyeRoll: 0,
  eyeScale: 1,
  eyeSpread: 1,
  eyeX: 0,
  eyeY: 0,
  front: 0,
  opacity: 1
}

export const FACING_POSE: AvatarPose = { ...REST_POSE, front: 1 }

export type Ease = 'easeIn' | 'easeInOut' | 'easeOut' | 'linear'

export const EASES: Record<Ease, (x: number) => number> = {
  easeIn: x => x * x,
  easeInOut: x => (x < 0.5 ? 2 * x * x : 1 - (-2 * x + 2) ** 2 / 2),
  easeOut: x => 1 - (1 - x) * (1 - x),
  linear: x => x
}

export function blendPoses(from: AvatarPose, to: AvatarPose, amount: number): AvatarPose {
  const pose: AvatarPose = { ...from }

  for (const field of POSE_FIELDS) {
    pose[field] = from[field] + (to[field] - from[field]) * amount
  }

  const dot = (index: 0 | 1 | 2) => from.dots[index] + (to.dots[index] - from.dots[index]) * amount

  pose.dots = [dot(0), dot(1), dot(2)]

  return pose
}

export interface Keyframe {
  ease: Ease
  pose: AvatarPose
  time: number
}

export interface LoadingClip {
  duration: number
  keys: readonly Keyframe[]
  name: string
}

export function trackPose(keys: readonly Keyframe[], t: number): AvatarPose {
  const first = keys[0]
  const last = keys[keys.length - 1]

  if (t <= first.time) {
    return first.pose
  }

  if (t >= last.time) {
    return last.pose
  }

  const next = keys.findIndex(key => key.time > t)
  const from = keys[next - 1]
  const to = keys[next]

  return blendPoses(from.pose, to.pose, EASES[to.ease]((t - from.time) / (to.time - from.time)))
}

function fail(message: string): never {
  throw new Error(`avatar-loading-clips: ${message}`)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isEase(value: unknown): value is Ease {
  return typeof value === 'string' && Object.hasOwn(EASES, value)
}

function isPoseField(name: string): name is PoseField {
  return (POSE_FIELDS as readonly string[]).includes(name)
}

function parsePose(fields: unknown, clip: string): AvatarPose {
  if (!isRecord(fields)) {
    fail(`clip ${clip} has a key without a pose`)
  }

  const pose: AvatarPose = { ...FACING_POSE }

  for (const [name, value] of Object.entries(fields)) {
    if (!isPoseField(name)) {
      fail(`clip ${clip} sets unknown pose field ${name}`)
    }

    if (typeof value !== 'number' || !Number.isFinite(value)) {
      fail(`clip ${clip} sets ${name} to a non-number`)
    }

    pose[name] = value
  }

  return pose
}

function parseKey(key: unknown, clip: string): Keyframe {
  if (!isRecord(key) || typeof key.t !== 'number' || !Number.isFinite(key.t) || !isEase(key.ease)) {
    return fail(`clip ${clip} has a malformed key`)
  }

  return { ease: key.ease, pose: parsePose(key.pose, clip), time: key.t }
}

function parseClip(clip: unknown): LoadingClip {
  if (!isRecord(clip) || typeof clip.name !== 'string' || !Array.isArray(clip.keys) || clip.keys.length === 0) {
    return fail('a clip is malformed')
  }

  const name = clip.name
  const keys = clip.keys.map(key => parseKey(key, name))

  if (keys[0].time !== 0) {
    fail(`clip ${name} must start at t=0`)
  }

  if (keys.some((key, index) => index > 0 && key.time < keys[index - 1].time)) {
    fail(`clip ${name} has keyframes out of order`)
  }

  return { duration: keys[keys.length - 1].time, keys, name }
}

export function parseLoadingClips(file: unknown): LoadingClip[] {
  if (!isRecord(file) || file.version !== 1 || !Array.isArray(file.clips) || file.clips.length === 0) {
    return fail('the file is malformed, empty or an unsupported version')
  }

  return file.clips.map(parseClip)
}

const MASK_64 = (1n << 64n) - 1n
const GOLDEN = 0x9e3779b97f4a7c15n
const FNV_OFFSET = 0xcbf29ce484222325n
const FNV_PRIME = 0x100000001b3n

export function loadingSeed(key: string): bigint {
  let hash = FNV_OFFSET

  for (const byte of new TextEncoder().encode(key)) {
    hash = ((hash ^ BigInt(byte)) * FNV_PRIME) & MASK_64
  }

  return hash
}

export function splitMix64(seed: bigint): () => bigint {
  let state = seed & MASK_64

  return () => {
    state = (state + GOLDEN) & MASK_64

    let z = state

    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK_64
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK_64

    return z ^ (z >> 31n)
  }
}

export function sessionSeed(seed: bigint, sinceEpochMs: number): bigint {
  return seed ^ BigInt.asUintN(64, BigInt(Math.floor(sinceEpochMs)))
}

export interface LoadingSequence {
  bag: (index: number) => number[]
  clipIndices: (count: number) => number[]
  pose: (t: number) => AvatarPose
}

export function createLoadingSequence(seed: bigint, clips: readonly LoadingClip[]): LoadingSequence {
  const cycle = clips.reduce((total, clip) => total + clip.duration, 0)
  const shuffles = new Map<number, number[]>()
  const bags = new Map<number, number[]>()

  const shuffled = (index: number): number[] => {
    const known = shuffles.get(index)

    if (known) {
      return known
    }

    const next = splitMix64(seed ^ ((BigInt(index) * GOLDEN) & MASK_64))
    const order = clips.map((_, position) => position)

    for (let i = order.length - 1; i >= 1; i--) {
      const j = Number(next() % BigInt(i + 1))

      ;[order[i], order[j]] = [order[j], order[i]]
    }

    shuffles.set(index, order)

    return order
  }

  const bag = (index: number): number[] => {
    const known = bags.get(index)

    if (known) {
      return known
    }

    const order = [...shuffled(index)]

    if (index >= 1 && order[0] === shuffled(index - 1)[order.length - 1]) {
      ;[order[0], order[1]] = [order[1], order[0]]
    }

    bags.set(index, order)

    return order
  }

  const clipIndices = (count: number): number[] => {
    const indices: number[] = []

    for (let index = 0; indices.length < count; index++) {
      indices.push(...bag(index))
    }

    return indices.slice(0, count)
  }

  const pose = (t: number): AvatarPose => {
    const time = Math.max(t, 0)
    const index = Math.floor(time / cycle)
    const order = bag(index)
    let remaining = time - index * cycle

    for (const clipIndex of order) {
      const clip = clips[clipIndex]

      if (remaining < clip.duration) {
        return trackPose(clip.keys, remaining)
      }

      remaining -= clip.duration
    }

    const last = clips[order[order.length - 1]]

    return trackPose(last.keys, last.duration)
  }

  return { bag, clipIndices, pose }
}

export type MotionMood = 'idle' | 'think' | 'work'

export function isLoadingMood(mood: null | string | undefined): mood is 'think' | 'work' {
  return mood === 'think' || mood === 'work'
}

export function asMotionMood(mood: null | string | undefined): MotionMood {
  return isLoadingMood(mood) ? mood : 'idle'
}

export const SETTLE_SECONDS = 0.4
export const REDUCED_PULSE_SECONDS = 2

const DOT_RATES = { think: 2.4, work: 2.6 } as const

export function workingDots(mood: MotionMood, t: number): Dots {
  if (mood === 'idle') {
    return [0, 0, 0]
  }

  const rate = DOT_RATES[mood]
  const dot = (index: number) => 0.2 + 0.8 * Math.max(0, Math.sin(t * rate - index * 0.7))

  return [dot(0), dot(1), dot(2)]
}

export function motionPose(mood: MotionMood, t: number, reduceMotion: boolean, sequence: LoadingSequence): AvatarPose {
  if (mood === 'idle') {
    return REST_POSE
  }

  if (reduceMotion) {
    return {
      ...REST_POSE,
      dots: workingDots(mood, 0),
      opacity: 0.8 + 0.2 * Math.cos((2 * Math.PI * t) / REDUCED_PULSE_SECONDS)
    }
  }

  return { ...sequence.pose(t), dots: workingDots(mood, t) }
}

export interface MotionSession {
  from: AvatarPose
  mood: MotionMood
  sequence: LoadingSequence
  since: number
}

export interface SessionStart {
  clips: readonly LoadingClip[]
  from: AvatarPose
  loadingSeed: bigint
  mood: MotionMood
  since: number
  sinceEpochMs: number
}

export function startSession({
  clips,
  from,
  loadingSeed: seed,
  mood,
  since,
  sinceEpochMs
}: SessionStart): MotionSession {
  return { from, mood, sequence: createLoadingSequence(sessionSeed(seed, sinceEpochMs), clips), since }
}

export function sessionPose(session: MotionSession, now: number, reduceMotion: boolean): AvatarPose {
  const t = (now - session.since) / 1000
  const pose = motionPose(session.mood, t, reduceMotion, session.sequence)

  if (reduceMotion || t >= SETTLE_SECONDS) {
    return pose
  }

  return blendPoses(session.from, pose, EASES.easeOut(Math.max(0, t) / SETTLE_SECONDS))
}

export function sessionSettled(session: MotionSession, now: number, reduceMotion: boolean): boolean {
  return session.mood === 'idle' && (reduceMotion || (now - session.since) / 1000 >= SETTLE_SECONDS)
}
