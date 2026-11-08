import { describe, expect, it } from 'vitest'

import {
  type AvatarPose,
  blendPoses,
  createLoadingSequence,
  FACING_POSE,
  type LoadingClip,
  loadingSeed,
  motionPose,
  parseLoadingClips,
  POSE_FIELDS,
  REST_POSE,
  sessionPose,
  sessionSeed,
  sessionSettled,
  SETTLE_SECONDS,
  splitMix64,
  startSession,
  trackPose,
  workingDots
} from './avatar-motion'
import { loadingClipFile } from './loading-clips-test-utils'

const file = loadingClipFile() as { clips: unknown[]; vectors: { clips: string[]; key: string }[]; version: number }
const clips = parseLoadingClips(file)
const cycle = clips.reduce((total, clip) => total + clip.duration, 0)
const sequence = createLoadingSequence(loadingSeed('alpha'), clips)
const FRAME = 1 / 120

const samples = (from: number, to: number, step = FRAME) =>
  Array.from({ length: Math.floor((to - from) / step) + 1 }, (_, index) => from + index * step)

const sameAsFacing = (pose: AvatarPose, tolerance = 1e-9) =>
  POSE_FIELDS.every(field => Math.abs(pose[field] - FACING_POSE[field]) <= tolerance)

const eyesHidden = (pose: AvatarPose) => Math.abs(pose.eyeX) >= 0.75 || Math.abs(pose.eyeY) >= 0.75

const JUMP_LIMITS: [Exclude<keyof AvatarPose, 'dots'>, number][] = [
  ['eyeX', 0.2],
  ['eyeY', 0.2],
  ['eyeRoll', 6],
  ['front', 0.1],
  ['eyeScale', 0.1],
  ['bodyX', 0.05],
  ['bodyY', 0.05],
  ['bodyScaleX', 0.1],
  ['bodyScaleY', 0.1],
  ['bodyRotation', 3],
  ['opacity', 0.1],
  ['eyeOpen', 0.5]
]

function visibleJump(a: AvatarPose, b: AvatarPose): boolean {
  if (eyesHidden(a) || eyesHidden(b)) {
    return Math.abs(a.bodyScaleX - b.bodyScaleX) > 0.1 || Math.abs(a.bodyY - b.bodyY) > 0.05
  }

  return JUMP_LIMITS.some(([field, limit]) => Math.abs(a[field] - b[field]) > limit)
}

const close = (a: AvatarPose, b: AvatarPose) => POSE_FIELDS.every(field => Math.abs(a[field] - b[field]) < 1e-6)

describe('the loading clips', () => {
  it('are twenty distinct clips between 1.2 and 3.6 seconds', () => {
    expect(clips).toHaveLength(20)
    expect(new Set(clips.map(clip => clip.name)).size).toBe(20)

    for (const clip of clips) {
      expect(clip.duration, clip.name).toBeGreaterThanOrEqual(1.2)
      expect(clip.duration, clip.name).toBeLessThanOrEqual(3.6)
    }
  })

  it.each(clips.map(clip => clip.name))('%s starts and ends facing the viewer', name => {
    const clip = clips.find(candidate => candidate.name === name) as LoadingClip

    expect(clip.keys[0].time).toBe(0)
    expect(sameAsFacing(trackPose(clip.keys, 0))).toBe(true)
    expect(sameAsFacing(trackPose(clip.keys, clip.duration))).toBe(true)
  })

  it.each(clips.map(clip => clip.name))('%s only teleports hidden eyes and never visibly jumps', name => {
    const clip = clips.find(candidate => candidate.name === name) as LoadingClip

    clip.keys.forEach((key, index) => {
      const next = clip.keys[index + 1]

      if (next?.time === key.time) {
        expect(eyesHidden(key.pose) && eyesHidden(next.pose), `${name} teleports visible eyes at ${key.time}`).toBe(
          true
        )
      }
    })

    const times = samples(0, clip.duration)

    times.slice(1).forEach((time, index) => {
      expect(visibleJump(trackPose(clip.keys, times[index]), trackPose(clip.keys, time)), `${name} at ${time}`).toBe(
        false
      )
    })
  })

  it.each(clips.map(clip => clip.name))('%s stays inside the ranges the avatars were tuned for', name => {
    const clip = clips.find(candidate => candidate.name === name) as LoadingClip

    for (const { pose, time } of clip.keys.filter(key => !eyesHidden(key.pose))) {
      expect(Math.abs(pose.eyeX) <= 0.42 && Math.abs(pose.eyeY) <= 0.42, `${name} looks too far at ${time}`).toBe(true)
      expect(Math.abs(pose.bodyX) <= 0.06 && Math.abs(pose.bodyY) <= 0.14).toBe(true)
      expect(pose.eyeScale).toBeGreaterThanOrEqual(0.4)
      expect(pose.eyeScale).toBeLessThanOrEqual(1.35)
      expect(pose.eyeOpen).toBeGreaterThanOrEqual(0)
      expect(pose.eyeOpen).toBeLessThanOrEqual(1)
    }
  })

  it('rejects files the engine cannot play', () => {
    const clip = (keys: unknown[]) => ({ clips: [{ keys, name: 'x' }], version: 1 })
    const key = (extra: Record<string, unknown> = {}) => ({ ease: 'linear', pose: {}, t: 0, ...extra })

    expect(() => parseLoadingClips({ clips: [], version: 1 })).toThrow()
    expect(() => parseLoadingClips({ ...clip([key()]), version: 2 })).toThrow()
    expect(() => parseLoadingClips(clip([key({ t: 0.5 })]))).toThrow()
    expect(() => parseLoadingClips(clip([key(), key({ t: 0.5 }), key({ t: 0.2 })]))).toThrow()
    expect(() => parseLoadingClips(clip([key({ pose: { wobble: 1 } })]))).toThrow()
    expect(() => parseLoadingClips(clip([key({ ease: 'bounce' })]))).toThrow()
    expect(parseLoadingClips(clip([key(), key({ t: 1 })]))).toHaveLength(1)
  })
})

describe('the loading sequence', () => {
  it('hashes and shuffles with the published algorithms', () => {
    expect(loadingSeed('')).toBe(0xcbf29ce484222325n)
    expect(loadingSeed('a')).toBe(0xaf63dc4c8601ec8cn)
    expect(splitMix64(0n)()).toBe(0xe220a8397b1dcdafn)
  })

  it('reproduces the vectors the shared file pins', () => {
    expect(file.vectors.length).toBeGreaterThanOrEqual(3)

    for (const vector of file.vectors) {
      const names = createLoadingSequence(loadingSeed(vector.key), clips)
        .clipIndices(45)
        .map(index => clips[index].name)

      expect(names, `vector for "${vector.key}"`).toEqual(vector.clips)
    }
  })

  it('plays every clip exactly once per bag', () => {
    for (const key of ['alpha', 'chó grok bot', '', 'Nova']) {
      const keyed = createLoadingSequence(loadingSeed(key), clips)

      for (let index = 0; index < 60; index++) {
        expect(
          [...keyed.bag(index)].sort((a, b) => a - b),
          `bag ${index} of ${key}`
        ).toEqual(Array.from({ length: clips.length }, (_, position) => position))
      }
    }
  })

  it('never repeats a clip back to back, across bag boundaries too', () => {
    for (let bot = 0; bot < 40; bot++) {
      const order = createLoadingSequence(loadingSeed(`bot-${bot}`), clips).clipIndices(20 * 60)

      expect(
        order.every((index, position) => position === 0 || index !== order[position - 1]),
        `bot-${bot}`
      ).toBe(true)
    }
  })

  it('is deterministic per key and differs between keys', () => {
    const orders = Array.from({ length: 24 }, (_, bot) =>
      createLoadingSequence(loadingSeed(`bot-${bot}`), clips).clipIndices(20)
    )

    expect(orders).toEqual(
      Array.from({ length: 24 }, (_, bot) => createLoadingSequence(loadingSeed(`bot-${bot}`), clips).clipIndices(20))
    )
    expect(new Set(orders.map(order => order.join())).size).toBe(24)
  })

  it('walks the bag clip by clip', () => {
    let start = 0

    for (const index of sequence.bag(0)) {
      const clip = clips[index]

      expect(close(sequence.pose(start + clip.duration / 2), trackPose(clip.keys, clip.duration / 2)), clip.name).toBe(
        true
      )
      start += clip.duration
    }

    const second = clips[sequence.bag(1)[0]]

    expect(close(sequence.pose(cycle + second.duration / 2), trackPose(second.keys, second.duration / 2))).toBe(true)
  })

  it('joins every clip and bag boundary seamlessly', () => {
    const times = samples(0, 3 * cycle)
    let previous = sequence.pose(times[0])

    for (const time of times.slice(1)) {
      const current = sequence.pose(time)

      expect(visibleJump(previous, current), `visible jump at ${time}`).toBe(false)
      previous = current
    }

    for (let index = 0; index < 3; index++) {
      let boundary = index * cycle

      for (const clipIndex of sequence.bag(index)) {
        expect(sameAsFacing(sequence.pose(boundary), 1e-6), `not facing at ${boundary}`).toBe(true)
        boundary += clips[clipIndex].duration
      }
    }
  })

  it('opens facing and tolerates negative time', () => {
    expect(sameAsFacing(sequence.pose(0))).toBe(true)
    expect(sameAsFacing(sequence.pose(-3))).toBe(true)
  })

  it('opens each loading session of the same bot with different clips', () => {
    const seed = loadingSeed('chó grok bot')

    const openers = new Set(
      Array.from(
        { length: 12 },
        (_, minute) =>
          createLoadingSequence(sessionSeed(seed, 1_800_000_000_000 + Math.floor(minute * 61_700)), clips).bag(0)[0]
      )
    )

    expect(openers.size).toBeGreaterThanOrEqual(4)
  })

  it('wraps the session seed like an unsigned 64-bit integer', () => {
    expect(sessionSeed(0n, 5)).toBe(5n)
    expect(sessionSeed(1n, -1)).toBe(0xffffffffffffffffn ^ 1n)
    expect(sessionSeed(0xffffffffffffffffn, 2 ** 53)).toBe(0xffffffffffffffffn ^ (1n << 53n))
  })
})

describe('a loading session', () => {
  const start = (mood: 'idle' | 'think' | 'work', from: AvatarPose = REST_POSE) =>
    startSession({ clips, from, loadingSeed: loadingSeed('alpha'), mood, since: 1000, sinceEpochMs: 1_800_000_000_000 })

  it('settles from the last pose to the clips over 0.4 seconds, easing out', () => {
    const session = start('work')
    const settled = sessionPose(session, 1000 + SETTLE_SECONDS * 1000, false)
    const midway = sessionPose(session, 1000 + (SETTLE_SECONDS / 2) * 1000, false)
    const target = motionPose('work', SETTLE_SECONDS / 2, false, session.sequence)

    expect(sessionPose(session, 1000, false).front).toBe(0)
    expect(midway.front).toBeCloseTo(blendPoses(REST_POSE, target, 0.75).front, 6)
    expect(close(settled, motionPose('work', SETTLE_SECONDS, false, session.sequence))).toBe(true)
  })

  it('plays the clips and the working dots in loading moods, rest in idle', () => {
    const session = start('think')
    const later = sessionPose(session, 1000 + 5000, false)

    expect(later.dots).toEqual(workingDots('think', 5))
    expect(motionPose('idle', 3, false, session.sequence)).toEqual(REST_POSE)
    expect(workingDots('idle', 3)).toEqual([0, 0, 0])
  })

  it('pulses opacity instead of moving under reduced motion', () => {
    const session = start('work', FACING_POSE)

    for (const seconds of [0, 0.5, 1, 1.5, 2, 7.25]) {
      const pose = sessionPose(session, 1000 + seconds * 1000, true)

      expect(pose.opacity).toBeCloseTo(0.8 + 0.2 * Math.cos(Math.PI * seconds), 9)
      expect(pose.front).toBe(0)
      expect(pose.eyeX).toBe(0)
      expect(pose.dots).toEqual(workingDots('work', 0))
    }
  })

  it('is settled only once an idle session has blended back to rest', () => {
    expect(sessionSettled(start('work'), 1000 + 60_000, false)).toBe(false)
    expect(sessionSettled(start('idle', FACING_POSE), 1000 + 100, false)).toBe(false)
    expect(sessionSettled(start('idle', FACING_POSE), 1000 + 400, false)).toBe(true)
    expect(sessionSettled(start('idle', FACING_POSE), 1000 + 10, true)).toBe(true)
  })

  it('blends back from a mid-clip pose to exactly rest', () => {
    const from = sequence.pose(1.1)
    const session = start('idle', from)

    expect(close(sessionPose(session, 1000, false), from)).toBe(true)
    expect(close(sessionPose(session, 1000 + 400, false), REST_POSE)).toBe(true)
  })
})
