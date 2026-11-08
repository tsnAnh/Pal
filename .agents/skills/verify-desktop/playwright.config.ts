import '../../../apps/desktop/e2e/run-tmp'
import '../../../apps/desktop/e2e/fix-electron-tracing'

import path from 'node:path'

import { defineConfig } from '@playwright/test'

const runDir = process.env.VERIFY_RUN_DIR

if (!runDir) {
  throw new Error('VERIFY_RUN_DIR is unset: run journeys through scripts/verify, not playwright directly')
}

export default defineConfig({
  testDir: './journeys',
  outputDir: path.join(runDir, 'playwright'),
  timeout: 1_200_000,
  retries: 0,
  workers: 1,
  fullyParallel: false,
  forbidOnly: true,
  reporter: [['list'], ['json', { outputFile: path.join(runDir, 'results.json') }]],
  use: { screenshot: 'on', trace: { mode: 'on', screenshots: true, snapshots: true, sources: false } }
})
