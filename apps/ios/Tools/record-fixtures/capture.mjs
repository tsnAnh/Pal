export class Capture {
  #cdp
  #sockets = new Map()
  #requests = new Map()
  #bodies = []
  records = []
  epoch = Date.now()

  constructor(cdp) {
    this.#cdp = cdp
    cdp.onEvent((method, params) => this.#onEvent(method, params))
  }

  async start() {
    await this.#cdp.send('Network.enable', { maxPostDataSize: 4_000_000 })
  }

  mark() {
    return this.records.length
  }

  since(mark) {
    return this.records.slice(mark)
  }

  #inScope(url) {
    return typeof url === 'string' && /^(?:ws|http)s?:\/\/(?:127\.0\.0\.1|localhost|\[::1\]):\d+\//.test(url)
  }

  #push(record) {
    this.records.push({ t: Date.now() - this.epoch, ...record })
  }

  #onEvent(method, params) {
    const handler = this[`on_${method.replace('.', '_')}`]
    if (handler) handler.call(this, params)
  }

  on_Network_webSocketCreated({ requestId, url }) {
    if (!this.#inScope(url)) return
    this.#sockets.set(requestId, url)
    this.#push({ kind: 'ws-open', socket: requestId, url })
  }

  on_Network_webSocketWillSendHandshakeRequest({ requestId, request }) {
    if (!this.#sockets.has(requestId)) return
    this.#push({ kind: 'ws-handshake-request', socket: requestId, headers: request.headers })
  }

  on_Network_webSocketHandshakeResponseReceived({ requestId, response }) {
    if (!this.#sockets.has(requestId)) return
    this.#push({ kind: 'ws-handshake-response', socket: requestId, status: response.status, headers: response.headers })
  }

  on_Network_webSocketFrameSent({ requestId, response }) {
    this.#frame(requestId, 'send', response)
  }

  on_Network_webSocketFrameReceived({ requestId, response }) {
    this.#frame(requestId, 'recv', response)
  }

  #frame(requestId, dir, response) {
    if (!this.#sockets.has(requestId)) return
    this.#push({ kind: 'ws-frame', socket: requestId, url: this.#sockets.get(requestId), dir, opcode: response.opcode, payload: response.payloadData })
  }

  on_Network_webSocketClosed({ requestId }) {
    if (!this.#sockets.has(requestId)) return
    this.#push({ kind: 'ws-close', socket: requestId, url: this.#sockets.get(requestId) })
  }

  on_Network_webSocketFrameError({ requestId, errorMessage }) {
    if (!this.#sockets.has(requestId)) return
    this.#push({ kind: 'ws-error', socket: requestId, url: this.#sockets.get(requestId), error: errorMessage })
  }

  on_Network_requestWillBeSent({ requestId, request }) {
    if (!this.#inScope(request.url)) return
    const entry = { url: request.url, method: request.method, headers: request.headers, body: request.postData ?? null, t: Date.now() - this.epoch }
    this.#requests.set(requestId, entry)
  }

  on_Network_responseReceived({ requestId, response }) {
    const entry = this.#requests.get(requestId)
    if (!entry) return
    entry.status = response.status
    entry.responseHeaders = response.headers
    entry.mime = response.mimeType
  }

  on_Network_loadingFinished({ requestId }) {
    const entry = this.#requests.get(requestId)
    if (!entry) return
    this.#requests.delete(requestId)
    const pending = this.#cdp
      .send('Network.getResponseBody', { requestId })
      .then((body) => (body.base64Encoded ? { base64: body.body } : { text: body.body }))
      .catch(() => ({ text: null }))
      .then((body) => this.#push({ kind: 'http', ...entry, response: body }))
    this.#bodies.push(pending)
  }

  on_Network_loadingFailed({ requestId, errorText }) {
    const entry = this.#requests.get(requestId)
    if (!entry) return
    this.#requests.delete(requestId)
    this.#push({ kind: 'http', ...entry, status: entry.status ?? 0, response: { text: null }, error: errorText })
  }

  ingestIpc(entry) {
    const { request = {}, response, error, startedAt } = entry
    const path = String(request.path ?? '')
    this.records.push({
      t: startedAt - this.epoch,
      kind: 'http',
      via: 'electron-ipc hermes:api',
      url: `ipc://hermes-api${path}`,
      method: request.method ?? 'GET',
      headers: {},
      body: request.body === undefined ? null : JSON.stringify(request.body),
      status: error ? (error.status ?? 0) : 200,
      responseHeaders: { 'content-type': 'application/json' },
      response: { text: error ? JSON.stringify({ error: error.message }) : JSON.stringify(response ?? null) },
      ...(error ? { error: error.message } : {})
    })
  }

  async waitForFrame(from, predicate, { timeout = 60000, label = 'frame' } = {}) {
    const deadline = Date.now() + timeout
    let cursor = from
    for (;;) {
      for (; cursor < this.records.length; cursor++) {
        const record = this.records[cursor]
        if (record.kind !== 'ws-frame') continue
        let message
        try {
          message = JSON.parse(record.payload)
        } catch {
          continue
        }
        if (predicate(message, record)) return { message, record }
      }
      if (Date.now() > deadline) throw new Error(`timeout waiting for ${label}`)
      await new Promise((resolve) => setTimeout(resolve, 150))
    }
  }

  waitForEvent(from, sessionId, type, options = {}) {
    return this.waitForFrame(
      from,
      (message) =>
        message.method === 'event' &&
        message.params?.type === type &&
        (sessionId === null || message.params?.session_id === sessionId),
      { label: `event ${type}`, ...options }
    )
  }

  async settle() {
    await Promise.all(this.#bodies.splice(0))
  }
}
