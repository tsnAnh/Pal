export type GroupListFailure = 'down' | 'quiet' | 'unsupported'

const METHOD_NOT_FOUND = -32601
const MISSING_METHOD = /method not found|unknown method|no such method|no handler for|unsupported rpc/i

const TRANSPORT =
  /not connected|gateway unavailable|unavailable for profile|no connection with id|socket|connection (?:closed|lost|refused|reset)|timed? ?out|network|econn|epipe/i

function errorCode(error: unknown): number | undefined {
  const code = error && typeof error === 'object' ? (error as { code?: unknown }).code : undefined

  return typeof code === 'number' ? code : undefined
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error ?? '')
}

export function classifyGroupListFailure(error: unknown, gatewayState: string): GroupListFailure {
  const code = errorCode(error)

  if (code === METHOD_NOT_FOUND || (code === undefined && MISSING_METHOD.test(errorMessage(error)))) {
    return 'unsupported'
  }

  if (gatewayState !== 'open' || (code === undefined && TRANSPORT.test(errorMessage(error)))) {
    return 'down'
  }

  return 'quiet'
}
