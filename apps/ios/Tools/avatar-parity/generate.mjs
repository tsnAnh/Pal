import { build } from 'esbuild'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { ACCENT_CASES, CASES, COLOR_INPUTS, KIND_TRAITS, NAME_INPUTS, SEED_INPUTS, SHAPE_INPUTS } from './matrix.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '../../../..')
const parityDir = resolve(here, '../../Packages/HermesDesign/Tests/HermesDesignTests/Parity')
const size = 256

const requireTool = tool => {
  try {
    execFileSync('which', [tool], { stdio: 'ignore' })
  } catch {
    throw new Error(`${tool} is required to rasterize the reference SVGs (brew install librsvg)`)
  }
}

requireTool('rsvg-convert')

const work = mkdtempSync(join(tmpdir(), 'avatar-parity-'))
const bundle = join(work, 'harness.mjs')

try {
  await build({
    entryPoints: [join(here, 'harness.tsx')],
    outfile: bundle,
    bundle: true,
    format: 'esm',
    platform: 'node',
    jsx: 'automatic',
    logLevel: 'error',
    nodePaths: [join(repo, 'node_modules')],
    alias: {
      '@hermes/plugin-sdk': join(here, 'sdk-stub.ts'),
      '@hermes/shared/color': join(repo, 'apps/shared/src/color.ts')
    },
    banner: {
      js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);"
    }
  })

  const h = await import(pathToFileURL(bundle).href)

  mkdirSync(parityDir, { recursive: true })

  for (const entry of readdirSync(parityDir)) {
    if (entry.endsWith('.png') || entry === 'matrix.json' || entry === 'figures.json') {
      rmSync(join(parityDir, entry))
    }
  }

  const cases = CASES.map(testCase => {
    const { svg, resolved } = h.renderCase(testCase, size)
    const entry = { ...testCase, resolved, png: null }

    if (testCase.render) {
      if (!svg) {
        throw new Error(`${testCase.id}: no svg produced`)
      }

      const svgFile = join(work, `${testCase.id}.svg`)
      const png = `${testCase.id}.png`

      writeFileSync(svgFile, svg)
      execFileSync('rsvg-convert', ['-w', String(size), '-h', String(size), '-o', join(parityDir, png), svgFile])
      entry.png = png
    }

    return entry
  })

  const figureSeeds = [...new Set(SEED_INPUTS)]
  const kindTraits = Object.entries(KIND_TRAITS)

  const figures = [
    ...figureSeeds.map(seed => h.figureGolden(seed)),
    ...figureSeeds.flatMap(seed => kindTraits.map(([, trait]) => h.figureGolden(seed, trait)).slice(0, 3))
  ]

  let state = 0x9e3779b9

  const next = () => {
    state ^= state << 13
    state ^= state >>> 17
    state ^= state << 5
    state >>>= 0

    return state / 4294967296
  }

  for (let i = 0; i < 240; i += 1) {
    const seed = Array.from({ length: 8 }, () => Math.floor(next() * 36).toString(36)).join('')

    figures.push(h.figureGolden(seed))
    figures.push(h.figureGolden(seed, kindTraits[i % kindTraits.length][1]))
  }

  const matrix = {
    size,
    kindTraits: KIND_TRAITS,
    cases,
    colors: COLOR_INPUTS.map(h.colorGolden),
    names: NAME_INPUTS.map(h.nameGolden),
    shapes: SHAPE_INPUTS.flatMap(shape => ['', 'alice', 'chó hóng hớt'].map(name => h.shapeGolden(shape, name))),
    accents: ACCENT_CASES.map(({ name, meta }) => h.accentGolden(name, meta))
  }

  writeFileSync(join(parityDir, 'matrix.json'), JSON.stringify(matrix, null, 1) + '\n')
  writeFileSync(join(parityDir, 'figures.json'), JSON.stringify(figures) + '\n')
  process.stdout.write(`wrote ${cases.filter(c => c.png).length} reference PNGs and matrix.json to ${parityDir}\n`)
} finally {
  rmSync(work, { recursive: true, force: true })
}
