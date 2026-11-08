import path from 'node:path'

import { runDesktopChatSmoke } from '../../../../tests-js/scripts/desktop-chat-smoke'
import { writeEnvFile, writeMockProviderConfig } from '../../../../tests-js/scripts/mock-provider-config'
import { startMockServer } from '../../../../tests-js/scripts/mock-server'
import {
  buildAppEnv,
  createSandbox,
  launchDesktop,
  type MockBackendFixture,
  waitForAppReady
} from '../../../../apps/desktop/e2e/fixtures'
import { test } from '../../../../apps/desktop/e2e/test'

import { provisionHome } from './provision'

let fixture: MockBackendFixture | null = null

test.beforeAll(async () => {
  const mock = await startMockServer()
  const sandbox = createSandbox('verify-chat')
  writeMockProviderConfig(sandbox.hermesHome, mock.url)
  writeEnvFile(sandbox.hermesHome)

  const env = buildAppEnv(sandbox)

  provisionHome(env, sandbox.hermesHome)

  const { app, page } = await launchDesktop(env)

  fixture = {
    app,
    page,
    mock,
    mockUrl: mock.url,
    sandbox,
    cleanup: async () => {
      await app.close().catch(() => undefined)
      await mock.close()
      sandbox.cleanup()
    }
  }
  await waitForAppReady(fixture, 240_000)
})

test.afterAll(async () => {
  await fixture?.cleanup()
  fixture = null
})

test('a typed message reaches the mock model and its reply renders in the transcript', async () => {
  await runDesktopChatSmoke(fixture!.page, {
    mockUrl: fixture!.mockUrl,
    phase: 'installed',
    outDir: path.join(process.env.VERIFY_RUN_DIR!, 'chat')
  })
})
