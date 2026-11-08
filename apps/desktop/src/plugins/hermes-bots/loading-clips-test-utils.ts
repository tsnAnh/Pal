import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

export function loadingClipFile(): unknown {
  return JSON.parse(readFileSync(resolve(process.cwd(), '../shared/src/avatar-loading-clips.json'), 'utf8'))
}
