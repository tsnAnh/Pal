import { isLoadingMood } from './avatar-motion'

export const MOTION_ATTRIBUTE = 'data-hb-motion'
export const MOOD_ATTRIBUTE = 'data-hb-mood'

const REDUCED_MOTION_QUERY = '(prefers-reduced-motion: reduce)'

export function eyesDriven(svg: Element): boolean {
  return svg.hasAttribute(MOTION_ATTRIBUTE) || isLoadingMood(svg.getAttribute(MOOD_ATTRIBUTE))
}

export function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia(REDUCED_MOTION_QUERY).matches
}
