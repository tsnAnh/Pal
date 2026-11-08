import path from 'node:path'

import { writeEnvFile, writeMockProviderConfig } from '../../../../tests-js/scripts/mock-provider-config.ts'
import { startMockServer } from '../../../../tests-js/scripts/mock-server.ts'

const [home, portArg] = process.argv.slice(2)

if (!home || !path.isAbsolute(home)) {
  console.error('usage: node mock-up.ts ABSOLUTE_HERMES_HOME [PORT]')
  process.exit(2)
}

const mock = await startMockServer(portArg ? { port: Number(portArg) } : {})

writeMockProviderConfig(home, mock.url, undefined, 'telemetry:\n  shared_metrics:\n    enabled: false\n    send: false\n    offer_version: 2\n')
writeEnvFile(home, 'e2e-mock-key', mock.url)

let closing = false
const shutdown = async (): Promise<void> => {
  if (closing) return
  closing = true
  await mock.close()
  process.exit(0)
}

process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)

console.log(`HV_MOCK_READY port=${mock.port} url=${mock.url}`)
