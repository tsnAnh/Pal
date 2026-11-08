import { blobatar } from 'blobatar/blob'
import { describe, expect, it } from 'vitest'

import { BLOB_KINDS, parseBlobShape } from './avatar'
import { extendBlob, EXTENDED_BLOB_KINDS, isExtendedBlobKind } from './blob-extended'
import { grokifyBlob } from './blob-style'

const library = blobatar('grok0', { size: 48, traits: { shape: 0.11 } })

describe('extended blob kinds', () => {
  it('are pinnable silhouettes', () => {
    for (const kind of EXTENDED_BLOB_KINDS) {
      expect(BLOB_KINDS).toContain(kind)
      expect(isExtendedBlobKind(kind)).toBe(true)
      expect(parseBlobShape(`blobatar:seed:${kind}`, 'bot').kind).toBe(kind)
    }

    expect(isExtendedBlobKind('round')).toBe(false)
  })

  it.each(EXTENDED_BLOB_KINDS)('%s keeps the library eyes and fill and replaces the body', kind => {
    const extended = extendBlob(library, kind)

    expect(extended).not.toBe(library)
    expect(extended.match(/<g fill="([^"]+)">/g)).toEqual(library.match(/<g fill="([^"]+)">/g))
    expect(extended.slice(extended.indexOf('</g>'))).toBe(library.slice(library.indexOf('</g>')))
  })

  it.each(EXTENDED_BLOB_KINDS)('%s survives the Grok restyle as a well-formed figure', kind => {
    const styled = grokifyBlob(extendBlob(library, kind))
    const doc = new DOMParser().parseFromString(styled, 'image/svg+xml')

    expect(doc.querySelector('parsererror')).toBeNull()
    expect(doc.querySelectorAll('[data-hb-eye]')).toHaveLength(2)
    expect(doc.querySelector('[stroke-width="26"]')?.children.length).toBeGreaterThan(0)
  })

  it('leaves non-library markup untouched', () => {
    expect(extendBlob('<svg></svg>', 'spark')).toBe('<svg></svg>')
  })
})
