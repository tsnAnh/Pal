import { describe, expect, it } from 'vitest'

import { circlePath, curveEye, type Matrix, pillPath, type SurfaceSpec, translation } from './eye-frame'

const EYE = { height: 24, width: 10 }
const ball: SurfaceSpec = { frame: '', mask: [circlePath(0, 0, 50)], reach: 0 }
const slab: SurfaceSpec = { frame: '', mask: [pillPath({ height: 100, width: 300 })], reach: 0 }

const paint = (spec: SurfaceSpec, at: [number, number]) => {
  const eye: Matrix = translation(at[0], at[1])

  return Array.from(curveEye(spec, EYE, eye).matchAll(/(-?[\d.]+) (-?[\d.]+)/g), point => ({
    x: Number(point[1]) + at[0],
    y: Number(point[2]) + at[1]
  }))
}

const box = (points: { x: number; y: number }[]) => ({
  maxX: Math.max(...points.map(p => p.x)),
  minX: Math.min(...points.map(p => p.x))
})

describe('eyes painted on the body', () => {
  it('narrows an eye sliding toward the rim of a ball, most on its far side', () => {
    const middle = box(paint(ball, [0, 0]))
    const side = box(paint(ball, [30, 0]))

    expect(middle.maxX - middle.minX).toBeCloseTo(10, 0)
    expect(side.maxX - side.minX).toBeLessThan((middle.maxX - middle.minX) * 0.85)
    expect(side.maxX - 30).toBeLessThan((30 - side.minX) * 0.92)
  })

  it('keeps the width of an eye on a flat-sided body where a ball would curve it', () => {
    const onBall = box(paint(ball, [30, 0]))
    const onSlab = box(paint(slab, [30, 0]))

    expect(onSlab.maxX - onSlab.minX).toBeGreaterThan((onBall.maxX - onBall.minX) * 1.2)
    expect(onSlab.maxX - onSlab.minX).toBeCloseTo(10, 0)
  })

  it('draws nothing for an eye whose centre is off the body', () => {
    expect(curveEye(ball, EYE, translation(60, 0))).toBe('')
    expect(paint(ball, [40, 0]).length).toBeGreaterThan(8)
  })

  it('never leaves the body for an eye anywhere on it', () => {
    for (let x = -45; x <= 45; x += 7.5) {
      for (let y = -45; y <= 45; y += 7.5) {
        for (const point of paint(ball, [x, y])) {
          expect(Math.hypot(point.x, point.y)).toBeLessThanOrEqual(50 + 3)
        }
      }
    }
  })

  it('counts the rounded stroke as body', () => {
    const bare: SurfaceSpec = { frame: '', mask: [circlePath(0, 0, 20)], reach: 0 }
    const stroked: SurfaceSpec = { ...bare, reach: 10 }

    expect(curveEye(bare, EYE, translation(25, 0))).toBe('')
    expect(paint(stroked, [25, 0]).length).toBeGreaterThan(8)
  })

  it('paints the same eye whichever frame the face is drawn in', () => {
    const framed: SurfaceSpec = { ...ball, frame: 'translate(20 -7) scale(0.8)' }
    const plain = box(paint(ball, [30, 0]))
    const turned = box(paint(framed, [30, 0]))

    expect(turned.maxX - turned.minX).toBeCloseTo(plain.maxX - plain.minX, 0)
    expect(turned.maxX - 30).toBeLessThan((30 - turned.minX) * 0.92)
  })
})
