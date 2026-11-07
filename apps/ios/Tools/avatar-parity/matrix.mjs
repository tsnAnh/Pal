export const BLOB_KINDS = ['round', 'organic', 'boxy', 'capsule', 'nub', 'cloud', 'droplet', 'hexagon', 'sun', 'triangle']

const BLOB_KIND_TRAIT = {
  round: 0.11,
  organic: 0.35,
  boxy: 0.54,
  capsule: 0.65,
  nub: 0.745,
  cloud: 0.825,
  droplet: 0.8875,
  hexagon: 0.9325,
  sun: 0.965,
  triangle: 0.99
}

export const KIND_TRAITS = BLOB_KIND_TRAIT

export const EXTENDED_BLOB_KINDS = ['spark', 'clover', 'burst', 'gem']

const CLASSIC_SHAPES = [
  'circle',
  'blob',
  'squircle',
  'pill',
  'triangle',
  'hexagon',
  'cloud',
  'drop',
  'cube',
  'pebble',
  'banana',
  'tetrahedron',
  'teardrop'
]

const cases = []

const add = (group, id, name, shape, meta = {}, extra = {}) => {
  cases.push({
    id: `${group}-${id}`,
    group,
    name,
    meta: { ...(shape === null ? {} : { shape }), ...meta },
    mood: 'idle',
    render: true,
    ...extra
  })
}

BLOB_KINDS.forEach((kind, index) => {
  add('blob-kinds', `${kind}-s1`, `${kind}-bot`, `blobatar:k7q2m9x${index}:${kind}`)
  add('blob-kinds', `${kind}-s2`, `${kind}-bot`, `blobatar:hermes${index * 7}:${kind}`)
  add('blob-kinds', `${kind}-dark`, `${kind}-bot`, `blobatar:0000zzzz:${kind}`, { color: '#1a1a2e', custom: true })
  add('blob-kinds', `${kind}-light`, `${kind}-bot`, `blobatar:a1b2c3d4:${kind}`, { color: '#f5f5f5', custom: true })
})

EXTENDED_BLOB_KINDS.forEach((kind, index) => {
  add('blob-kinds', `${kind}-s1`, `${kind}-bot`, `blobatar:k7q2m9x${index + 10}:${kind}`)
  add('blob-kinds', `${kind}-s2`, `${kind}-bot`, `blobatar:hermes${(index + 10) * 7}:${kind}`)
  add('blob-kinds', `${kind}-dark`, `${kind}-bot`, `blobatar:0000zzzz:${kind}`, { color: '#1a1a2e', custom: true })
  add('blob-kinds', `${kind}-light`, `${kind}-bot`, `blobatar:a1b2c3d4:${kind}`, { color: '#f5f5f5', custom: true })
  add('blob-kinds', `${kind}-orange`, `${kind}-bot`, `blobatar:grok${index}:${kind}`, { color: '#f58903', custom: true })
})

add('blob-unpinned', 'alice', 'alice', 'blobatar')
add('blob-unpinned', 'bob-builder', 'Bob Builder', 'blobatar')
add('blob-unpinned', 'vi-dog', 'chó hóng hớt', 'blobatar')
add('blob-unpinned', 'vi-name', 'Trần Văn Ánh', 'blobatar')
add('blob-unpinned', 'emoji', '🤖 robo', 'blobatar')
add('blob-unpinned', 'padded', '  padded  ', 'blobatar')
add('blob-unpinned', 'single', 'x', 'blobatar')
add('blob-unpinned', 'nan-name', 'NaN', 'blobatar')
add('blob-unpinned', 'empty-name', '', 'blobatar')
add('blob-unpinned', 'empty-seed', 'empty-seed', 'blobatar:')
add('blob-unpinned', 'kind-follows-name', 'follow-name', 'blobatar::boxy')
add('blob-unpinned', 'kind-sun-vi', 'Hóng', 'blobatar::sun')
add('blob-unpinned', 'unknown-kind', 'bogus-kind', 'blobatar:seed7:bogus')
add('blob-unpinned', 'extra-segments', 'extra', 'blobatar:seed7:round:extra')
add('blob-unpinned', 'space-seed', 'space', 'blobatar:  :cloud')
add('blob-unpinned', 'upper-seed', 'case', 'blobatar:HERMES:organic')
add('blob-unpinned', 'decomposed', 'cafe', 'blobatar:café:capsule')
add('blob-unpinned', 'composed', 'cafe', 'blobatar:café:capsule')

const COLOR_NAME = 'tinted'
const blobColors = [
  ['rgb-comma', 'rgb(233, 61, 130)'],
  ['rgba-slash', 'rgba(20 20 20 / 0.9)'],
  ['hsl-space', 'hsl(210 80% 45%)'],
  ['hsl-deg', 'hsl(30deg, 90%, 60%)'],
  ['hex3', '#0af'],
  ['hex8-alpha', '#00000080'],
  ['rgb-percent', 'rgb(10%, 50%, 90%)'],
  ['hsl-bare', 'hsl(200 50 50)'],
  ['invalid-named', 'red'],
  ['invalid-rgb', 'rgb(1,2)'],
  ['invalid-hex', '#12345'],
  ['invalid-hsl', 'hsl(1 2 3 4)'],
  ['invalid-arabic-digits', 'rgb(١, 2, 3)'],
  ['invalid-trailing-newline', '#fff\n']
]

const UNRASTERIZABLE = new Set(['hsl-bare'])

for (const [id, color] of blobColors) {
  add('blob-colors', id, COLOR_NAME, 'blobatar:tintseed', { color, custom: true }, { render: !UNRASTERIZABLE.has(id) })
}

const CLASSIC_COLORS = [
  ['green', '#46a758'],
  ['ink', '#3a3a3a']
]

for (const shape of CLASSIC_SHAPES) {
  for (const [id, color] of CLASSIC_COLORS) {
    add('classic', `${shape}-${id}`, 'classic-bot', shape, { color, custom: true })
  }
}

add('classic-color-syntax', 'rgb', 'syntax', 'squircle', { color: 'rgb(255 140 0)', custom: true })
add('classic-color-syntax', 'hsl-light', 'syntax', 'cloud', { color: 'hsl(55 95% 55%)', custom: true })
add('classic-color-syntax', 'invalid-falls-back', 'Kẻ lạ', 'circle', { color: 'chartreuse', custom: true })
add('classic-color-syntax', 'hex-alpha', 'syntax', 'pill', { color: '#e5484dcc', custom: true })

add('sigil', 'zero', 'sigil-bot', 'sigil-0', { color: '#8e4ec6', custom: true })
add('sigil', 'three', 'sigil-bot', 'sigil-3', { color: '#3e8ef7', custom: true })
add('sigil', 'twelve', 'Vi Tính', 'sigil-12', { color: '#f0772d', custom: true })
add('sigil', 'not-a-number', 'sigil-bot', 'sigil-x', { color: '#46a758', custom: true })
add('sigil', 'negative', 'sigil-bot', 'sigil--2', { color: '#e93d82', custom: true })
add('sigil', 'dark', 'sigil-bot', 'sigil-9', { color: '#3a3a3a', custom: true })

add('default-bot', 'plain', 'default', null)
add('default-bot', 'capitalised', 'Default', null)
add('default-bot', 'padded-upper', ' DEFAULT ', null)
add('default-bot', 'with-blob-shape', 'default', 'blobatar:abc12345')
add('default-bot', 'customized', 'default', 'circle', { color: '#e5484d', custom: true })
add('default-bot', 'customized-blob', 'default', 'blobatar:abc12345:sun', { custom: true })

const legacyNames = ['chó hóng hớt', 'alice', 'Bảo Châu', '🤖', 'a', '', 'NaN', 'zażółć gęślą jaźń', 'bot-with-a-very-long-name-1234', 'ΟΔΥΣΣΕΑΣ']

legacyNames.forEach((name, index) => add('legacy', `n${index}`, name, null))

add('mood', 'think', 'moody', 'squircle', { color: '#3e8ef7', custom: true }, { mood: 'think' })
add('mood', 'work', 'moody', 'hexagon', { color: '#f5a524', custom: true }, { mood: 'work' })
add('mood', 'idle', 'moody', 'drop', { color: '#8e4ec6', custom: true }, { mood: 'idle' })

add(
  'photo',
  'photo',
  'portrait',
  'blobatar',
  { image: 'data:image/png;base64,iVBORw0KGgo=', imageKind: 'photo', custom: true },
  { render: false }
)
add(
  'photo',
  'backfilled-face',
  'portrait',
  'blobatar',
  { image: 'data:image/png;base64,iVBORw0KGgo=', imageKind: 'shape' },
  { render: false }
)

export const CASES = cases

export const COLOR_INPUTS = [
  '#fff',
  '#FFFF',
  '#abcdef',
  '#ABCDEF12',
  '#12345',
  '#ggg',
  '#',
  '',
  ' #fff',
  '#fff ',
  '#fff\n',
  'rgb(0,0,0)',
  'RGB(255 255 255)',
  'rgba(1, 2, 3, 0.5)',
  'rgba(1 2 3 / 50%)',
  'rgb(10%, 20%, 30%)',
  'rgb(300, -20, 1e2)',
  'rgb(1.5, 2.5, 3.5)',
  'rgb( 1 , 2 , 3 )',
  'rgb(1,2)',
  'rgb(1 2 3 4)',
  'rgb(١,2,3)',
  'rgb(.5,.5,.5)',
  'rgb(+5,+5,+5)',
  'hsl(0 0% 0%)',
  'hsl(0, 100%, 50%)',
  'hsl(120deg 60% 30%)',
  'hsl(-30 50% 50%)',
  'hsl(400 50% 50%)',
  'hsl(200 50 50)',
  'hsla(200, 50%, 50%, 0.3)',
  'hsl(1 2 3 4)',
  'hsl(0.5turn 50% 50%)',
  'hsl(200 150% 50%)',
  'hsl(200 50% 150%)',
  'hsl(60 100% 25%)',
  'red',
  'transparent',
  'var(--x)',
  'rgb(0 0 0 / 0)',
  '#6e6e6e',
  '#6f6f6f',
  '#6e6e6eff',
  'hsl(210 80% 45%)',
  'hsl(0 68% 58%)'
]

export const NAME_INPUTS = [
  '',
  ' ',
  'default',
  'Default',
  ' default ',
  'a',
  'alice',
  'Alice',
  'NaN',
  'undefined',
  'null',
  'chó hóng hớt',
  'chó hóng',
  'Trần Văn Ánh',
  '🤖',
  '🤖 robo',
  'a🤖b',
  'ΟΔΥΣΣΕΑΣ',
  'İstanbul',
  'straße',
  ' pad ',
  '﻿bom',
  '\u0085nel',
  '᠎mvs',
  ' ls ',
  '\tTab\n',
  'x'.repeat(300),
  'zażółć gęślą jaźń',
  '日本語のボット',
  '👨‍👩‍👧‍👦 family'
]

export const SHAPE_INPUTS = [
  'blobatar',
  'blobatar:',
  'blobatar::',
  'blobatar:abc',
  'blobatar:abc:round',
  'blobatar:abc:sun',
  'blobatar:abc:spark',
  'blobatar::gem',
  'blobatar:abc:bogus',
  'blobatar:abc:',
  'blobatar::triangle',
  'blobatar::Triangle',
  'blobatar:a:b:c:d',
  'blobatar:  :cloud',
  'blobatar:ABC:capsule',
  'blobatar:é:nub',
  'blobatarx',
  'Blobatar',
  'blobatar-abc',
  '',
  'circle',
  'sigil-3',
  ':',
  '::round'
]

export const SEED_INPUTS = [
  '',
  ' ',
  'A',
  'a',
  'agent',
  'hermes',
  'Hermes',
  '  hermes  ',
  'NaN',
  'undefined',
  'Élan',
  'élan',
  'chó hóng hớt',
  'chó hóng hơt́',
  '🤖',
  '🤖 robo',
  'ΟΔΥΣΣΕΑΣ',
  'Σ',
  'ΑΣ',
  'Σ ',
  'AΣ.',
  'İstanbul',
  'ǅ',
  'ß',
  'ẞ',
  ' pad ',
  '﻿bom',
  '\u0085nel',
  '᠎mvs',
  ' ls ',
  '\tTab\n',
  'x'.repeat(300),
  '日本語のボット',
  '👨‍👩‍👧‍👦 family',
  '\u0000nul',
  'a:b',
  'k7q2m9x1',
  '0000zzzz',
  'a1b2c3d4'
]

export const ACCENT_CASES = [
  { name: 'alice', meta: {} },
  { name: 'alice', meta: { color: '#3e8ef7' } },
  { name: 'alice', meta: { color: '#3e8ef780' } },
  { name: 'alice', meta: { color: '#f5d90a' } },
  { name: 'alice', meta: { color: '#fff' } },
  { name: 'alice', meta: { color: '#000' } },
  { name: 'alice', meta: { color: '#4f9e5e' } },
  { name: 'alice', meta: { color: 'rgb(10, 20, 30)' } },
  { name: 'alice', meta: { color: 'hsl(210 80% 45%)' } },
  { name: 'alice', meta: { color: 'hsl(210deg, 80%, 45%)' } },
  { name: 'alice', meta: { color: 'hsl(210 80 45)' } },
  { name: 'alice', meta: { color: 'hsla(-30, 100%, 50%, 0.4)' } },
  { name: 'alice', meta: { color: 'hsl(400 150% 20%)' } },
  { name: 'chó hóng hớt', meta: {} },
  { name: 'default', meta: {} },
  { name: 'default', meta: { custom: true, color: '#e5484d' } },
  { name: '', meta: {} }
]
