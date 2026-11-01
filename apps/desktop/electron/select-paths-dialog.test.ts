import path from 'node:path'

import { describe, expect, it } from 'vitest'

import { selectPathsDefaultPath, selectPathsDialogProperties } from './select-paths-dialog'

describe('selectPathsDialogProperties', () => {
  it('lets a directory picker create a new folder (macOS hides New Folder without createDirectory)', () => {
    const properties = selectPathsDialogProperties({ directories: true, multiple: false })

    expect(properties).toContain('openDirectory')
    expect(properties).toContain('createDirectory')
  })

  it('keeps file pickers file-only and multi-select by default', () => {
    const properties = selectPathsDialogProperties({})

    expect(properties).toContain('openFile')
    expect(properties).toContain('multiSelections')
    expect(properties).not.toContain('openDirectory')
    expect(properties).not.toContain('createDirectory')
  })

  it('drops multi-select only when the caller opts out', () => {
    expect(selectPathsDialogProperties({ directories: true })).toContain('multiSelections')
    expect(selectPathsDialogProperties({ directories: true, multiple: false })).not.toContain('multiSelections')
  })
})

describe('selectPathsDefaultPath', () => {
  it('offers no start folder when the caller names none', () => {
    expect(selectPathsDefaultPath({}, null)).toBeUndefined()
    expect(selectPathsDefaultPath({ defaultPath: '' }, null)).toBeUndefined()
  })

  it('resolves the caller’s folder as given when no host bridge applies', () => {
    expect(selectPathsDefaultPath({ defaultPath: 'notes' }, null)).toBe(path.resolve('notes'))
  })

  it('bridges a backend path for the picker, passing the profile along', () => {
    const seen: unknown[][] = []

    const bridge = (...args: unknown[]) => {
      seen.push(args)

      return '/mnt/c/Users/alex'
    }

    expect(selectPathsDefaultPath({ defaultPath: '/home/alex', profile: 'work' }, bridge)).toBe(
      path.resolve('/mnt/c/Users/alex')
    )
    expect(seen).toEqual([['/home/alex', undefined, 'work']])
  })

  it('falls back to no start folder when the bridge has no answer or throws', () => {
    expect(selectPathsDefaultPath({ defaultPath: '/home/alex' }, () => undefined)).toBeUndefined()

    expect(
      selectPathsDefaultPath({ defaultPath: '/home/alex' }, () => {
        throw new Error('no distro')
      })
    ).toBeUndefined()
  })
})
