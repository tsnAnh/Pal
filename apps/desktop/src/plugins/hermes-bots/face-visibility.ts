const FACE_SELECTOR = 'svg[data-bot-face]'
const VISIBLE_ATTRIBUTE = 'data-hb-visible'

let activeStop: (() => void) | null = null

function facesIn(node: Node): SVGSVGElement[] {
  if (!(node instanceof Element)) {
    return []
  }

  const nested = Array.from(node.querySelectorAll<SVGSVGElement>(FACE_SELECTOR))

  return node.matches(FACE_SELECTOR) ? [node as unknown as SVGSVGElement, ...nested] : nested
}

export function startFaceVisibility(): () => void {
  if (activeStop) {
    return activeStop
  }

  if (typeof IntersectionObserver === 'undefined' || typeof MutationObserver === 'undefined') {
    return () => undefined
  }

  const intersections = new IntersectionObserver(entries => {
    for (const { isIntersecting, target } of entries) {
      target.toggleAttribute(VISIBLE_ATTRIBUTE, isIntersecting)
    }
  })

  const mutations = new MutationObserver(records => {
    for (const record of records) {
      record.removedNodes.forEach(node => facesIn(node).forEach(face => intersections.unobserve(face)))
      record.addedNodes.forEach(node => facesIn(node).forEach(face => intersections.observe(face)))
    }
  })

  facesIn(document.documentElement).forEach(face => intersections.observe(face))
  mutations.observe(document.documentElement, { childList: true, subtree: true })

  activeStop = () => {
    mutations.disconnect()
    intersections.disconnect()
    document.querySelectorAll(`[${VISIBLE_ATTRIBUTE}]`).forEach(face => face.removeAttribute(VISIBLE_ATTRIBUTE))
    activeStop = null
  }

  return activeStop
}
