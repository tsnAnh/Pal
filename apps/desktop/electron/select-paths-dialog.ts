import path from 'node:path'

import type { OpenDialogOptions } from 'electron'

type DialogProperty = NonNullable<OpenDialogOptions['properties']>[number]

// `hermes:selectPaths` → `dialog.showOpenDialog` properties. Directory pickers
// carry `createDirectory` so macOS shows New Folder: a new project needs a
// folder, and the picker is where the user expects to make one.
export function selectPathsDialogProperties(options: { directories?: boolean; multiple?: boolean } = {}) {
  const properties: DialogProperty[] = options.directories ? ['openDirectory', 'createDirectory'] : ['openFile']

  if (options.multiple !== false) {
    properties.push('multiSelections')
  }

  return properties
}

type PickerPathBridge = (defaultPath: string, distro: string | undefined, profile: unknown) => string | undefined

export function selectPathsDefaultPath(
  options: { defaultPath?: unknown; profile?: unknown },
  bridge: PickerPathBridge | null
): string | undefined {
  if (!options.defaultPath) {
    return undefined
  }

  try {
    // On a Windows host with a WSL backend the cwd may be a POSIX/WSL path;
    // bridge it to a UNC/drive form the native dialog can actually open.
    const given = String(options.defaultPath)
    const bridged = bridge ? bridge(given, undefined, options.profile) : given

    return bridged ? path.resolve(bridged) : undefined
  } catch {
    return undefined
  }
}
