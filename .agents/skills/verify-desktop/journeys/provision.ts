import { spawnSync } from 'node:child_process'
import path from 'node:path'

const REPO = path.resolve(import.meta.dirname, '../../../..')
const PYTHON = path.join(REPO, '.venv/bin/python')
const PROVISION_TIMEOUT_SECONDS = 900

function hermes(env: Record<string, string>, home: string, args: string[], timeoutSeconds: number) {
  const result = spawnSync(PYTHON, ['-m', 'hermes_cli.main', ...args], {
    cwd: REPO,
    encoding: 'utf8',
    env: { ...env, HERMES_HOME: home, PYTHONPATH: REPO },
    timeout: timeoutSeconds * 1000
  })

  if (result.status !== 0) {
    throw new Error(`hermes ${args.join(' ')} failed for ${home} (status ${result.status}): ${(result.stderr || result.stdout).slice(-2000)}`)
  }

  return result.stdout
}

export function provisionHome(env: Record<string, string>, home: string): void {
  const ensured = hermes(env, home, ['gateway', 'ensure', '--json', '--timeout', String(PROVISION_TIMEOUT_SECONDS)], PROVISION_TIMEOUT_SECONDS + 60)

  if (!ensured.includes('"state":"ready"')) {
    throw new Error(`gateway did not reach ready while provisioning ${home}: ${ensured.slice(-1000)}`)
  }

  hermes(env, home, ['gateway', 'stop'], 120)
}
