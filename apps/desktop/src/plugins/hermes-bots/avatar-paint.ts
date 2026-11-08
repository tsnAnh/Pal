import {
  asMotionMood,
  type AvatarPose,
  isLoadingMood,
  loadingSeed,
  type MotionMood,
  type MotionSession,
  REST_POSE,
  sessionPose,
  sessionSettled,
  startSession
} from './avatar-motion'
import { type AvatarRig, createRig, paintEyes } from './avatar-rig'
import {
  curveEye,
  type EyeSize,
  invert,
  type Matrix,
  multiply,
  parseTransform,
  readEyeSize,
  readSurfaceSpec,
  ringsPath,
  type SurfaceSpec
} from './eye-frame'
import { MOOD_ATTRIBUTE, MOTION_ATTRIBUTE } from './face-driver'
import { loadingClips } from './loading-clips'

const GAZE_SELECTOR = '[data-hb-gaze]'
const EYE_SELECTOR = '[data-hb-eye]'
const DOT_SELECTOR = '[data-hb-dot]'
const REST_ATTRIBUTE = 'data-hb-rest'
const KEY_ATTRIBUTE = 'data-hb-key'
const TRAVEL_ATTRIBUTE = 'data-hb-travel'
const FACING_ATTRIBUTE = 'data-hb-facing'
const STALE_MS = 500
const MATRIX_DECIMALS = 5

interface FaceRig {
  dots: SVGElement[]
  eyes: { group: SVGGElement; path: SVGPathElement | null }[]
  gaze: SVGGElement
  identity: string
  rig: AvatarRig
  size: EyeSize
  spec: SurfaceSpec
  viewBox: { height: number; width: number }
}

interface FaceMotion {
  mood: MotionMood
  painted: number
  pose: AvatarPose
  rig: FaceRig | null
  session: MotionSession | null
}

const motions = new WeakMap<SVGSVGElement, FaceMotion>()

function matrixAttribute(m: Matrix): string {
  return `matrix(${m.map(value => value.toFixed(MATRIX_DECIMALS)).join(' ')})`
}

function readViewBox(svg: SVGSVGElement): FaceRig['viewBox'] | null {
  const [, , width, height] = (svg.getAttribute('viewBox') ?? '')
    .trim()
    .split(/[\s,]+/)
    .map(Number)

  return width > 0 && height > 0 ? { height, width } : null
}

function identityOf(svg: SVGSVGElement, group: Element, eyes: Element[]): string {
  return [
    svg.getAttribute('viewBox'),
    group.getAttribute('data-hb-mask'),
    group.getAttribute('data-hb-frame'),
    group.getAttribute('data-hb-reach'),
    group.getAttribute(TRAVEL_ATTRIBUTE),
    group.getAttribute(FACING_ATTRIBUTE),
    ...eyes.flatMap(eye => [eye.getAttribute(REST_ATTRIBUTE), eye.getAttribute('data-hb-size')])
  ].join('|')
}

function readFaceRig(svg: SVGSVGElement): FaceRig | null {
  const group = svg.querySelector<SVGGElement>(GAZE_SELECTOR)
  const spec = group && readSurfaceSpec(group)
  const viewBox = readViewBox(svg)
  const eyeGroups = group ? Array.from(group.querySelectorAll<SVGGElement>(EYE_SELECTOR)) : []
  const size = eyeGroups[0] && readEyeSize(eyeGroups[0])
  const rests = eyeGroups.map(eye => eye.getAttribute(REST_ATTRIBUTE))

  if (!group || !spec || !viewBox || !size || rests.some(rest => rest === null)) {
    return null
  }

  const travel = Number(group.getAttribute(TRAVEL_ATTRIBUTE))

  const rig = createRig({
    facesRest: group.getAttribute(FACING_ATTRIBUTE) === 'rest',
    rests: rests.map(rest => parseTransform(rest ?? '')),
    size,
    surface: spec,
    travel: travel > 0 ? travel : null
  })

  return {
    dots: Array.from(svg.querySelectorAll<SVGElement>(DOT_SELECTOR)),
    eyes: eyeGroups.map(eye => ({ group: eye, path: eye.querySelector('path') })),
    gaze: group,
    identity: identityOf(svg, group, eyeGroups),
    rig,
    size,
    spec,
    viewBox
  }
}

function faceRigFor(svg: SVGSVGElement, motion: FaceMotion): FaceRig | null {
  const known = motion.rig

  if (
    known?.gaze.isConnected &&
    identityOf(
      svg,
      known.gaze,
      known.eyes.map(eye => eye.group)
    ) === known.identity
  ) {
    return known
  }

  motion.rig = readFaceRig(svg)

  return motion.rig
}

function paintFigure(svg: SVGSVGElement, face: FaceRig, pose: AvatarPose) {
  const { height, width } = face.viewBox
  const side = Math.max(width, height)
  const originX = ((1 - width / side) / 2 + face.rig.pivot[0] / side) * 100
  const originY = ((1 - height / side) / 2 + face.rig.pivot[1] / side) * 100
  const shiftX = ((pose.bodyX * face.rig.span) / side) * 100
  const shiftY = ((pose.bodyY * face.rig.span) / side) * 100

  svg.style.transformBox = 'border-box'
  svg.style.transformOrigin = `${originX.toFixed(4)}% ${originY.toFixed(4)}%`
  svg.style.transform =
    `translate(${shiftX.toFixed(4)}%, ${shiftY.toFixed(4)}%) rotate(${pose.bodyRotation.toFixed(4)}deg) ` +
    `scale(${pose.bodyScaleX.toFixed(5)}, ${pose.bodyScaleY.toFixed(5)})`
  svg.style.opacity = pose.opacity < 1 ? pose.opacity.toFixed(4) : ''
}

function paintDots(face: FaceRig, pose: AvatarPose) {
  face.dots.forEach((dot, index) => dot.setAttribute('opacity', String(pose.dots[index] ?? 0)))
}

function paintPose(svg: SVGSVGElement, face: FaceRig, pose: AvatarPose) {
  const toFigure = invert(face.rig.frame)

  paintEyes(face.rig, pose).forEach(({ eye, local, rings }, index) => {
    const target = face.eyes[index]

    if (!target) {
      return
    }

    target.group.setAttribute('transform', matrixAttribute(multiply(toFigure, eye)))
    target.path?.setAttribute('d', ringsPath(rings, local))
  })

  paintDots(face, pose)
  paintFigure(svg, face, pose)
  svg.setAttribute(MOTION_ATTRIBUTE, '')
}

function release(svg: SVGSVGElement, face: FaceRig) {
  for (const { group, path } of face.eyes) {
    const rest = group.getAttribute(REST_ATTRIBUTE)

    if (rest) {
      group.setAttribute('transform', rest)
      path?.setAttribute('d', curveEye(face.spec, face.size, parseTransform(rest)))
    }
  }

  paintDots(face, REST_POSE)
  svg.style.removeProperty('transform')
  svg.style.removeProperty('transform-origin')
  svg.style.removeProperty('transform-box')
  svg.style.removeProperty('opacity')
  svg.removeAttribute(MOTION_ATTRIBUTE)
}

function motionOf(svg: SVGSVGElement): FaceMotion {
  const known = motions.get(svg)

  if (known) {
    return known
  }

  const fresh: FaceMotion = { mood: 'idle', painted: -Infinity, pose: REST_POSE, rig: null, session: null }

  motions.set(svg, fresh)

  return fresh
}

function faceKey(svg: SVGSVGElement): string {
  return svg.getAttribute(KEY_ATTRIBUTE) ?? svg.getAttribute('data-bot-face') ?? ''
}

function changeMood(svg: SVGSVGElement, motion: FaceMotion, mood: MotionMood, now: number, epochMs: number) {
  const from = now - motion.painted <= STALE_MS ? motion.pose : REST_POSE
  const clips = loadingClips()

  if ((isLoadingMood(mood) && clips.length > 0) || motion.session) {
    motion.session = startSession({
      clips,
      from,
      loadingSeed: loadingSeed(faceKey(svg)),
      mood,
      since: now,
      sinceEpochMs: epochMs
    })
  }

  motion.mood = mood
}

export function paintMotion(svg: SVGSVGElement, now: number, epochMs: number, reduceMotion: boolean): boolean {
  const motion = motionOf(svg)
  const mood = asMotionMood(svg.getAttribute(MOOD_ATTRIBUTE))

  if (mood !== motion.mood) {
    changeMood(svg, motion, mood, now, epochMs)
  }

  if (!motion.session) {
    return false
  }

  const face = faceRigFor(svg, motion)

  if (!face) {
    motion.session = null

    return false
  }

  if (sessionSettled(motion.session, now, reduceMotion)) {
    release(svg, face)
    motion.session = null
    motion.pose = REST_POSE

    return false
  }

  const pose = sessionPose(motion.session, now, reduceMotion)

  paintPose(svg, face, pose)
  motion.pose = pose
  motion.painted = now

  return true
}
