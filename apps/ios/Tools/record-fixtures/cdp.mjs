export class CdpSession {
  #socket
  #nextId = 1
  #pending = new Map()
  #listeners = new Set()

  static async connect(port, pickTarget = (targets) => targets.find((t) => t.type === 'page')) {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`)
    const target = pickTarget(await response.json())
    if (!target) throw new Error('no page target')
    const session = new CdpSession(target.webSocketDebuggerUrl)
    await session.opened
    return session
  }

  constructor(url) {
    this.#socket = new WebSocket(url)
    this.opened = new Promise((resolve, reject) => {
      this.#socket.addEventListener('open', resolve, { once: true })
      this.#socket.addEventListener('error', () => reject(new Error('cdp connect failed')), { once: true })
    })
    this.#socket.addEventListener('message', (event) => this.#onMessage(JSON.parse(event.data)))
  }

  #onMessage(message) {
    if (message.id !== undefined) {
      const pending = this.#pending.get(message.id)
      if (!pending) return
      this.#pending.delete(message.id)
      if (message.error) pending.reject(new Error(`${pending.method}: ${message.error.message}`))
      else pending.resolve(message.result)
      return
    }
    for (const listener of this.#listeners) listener(message.method, message.params)
  }

  send(method, params = {}) {
    const id = this.#nextId++
    return new Promise((resolve, reject) => {
      this.#pending.set(id, { resolve, reject, method })
      this.#socket.send(JSON.stringify({ id, method, params }))
    })
  }

  onEvent(listener) {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  async evaluate(expression, { awaitPromise = true } = {}) {
    const result = await this.send('Runtime.evaluate', { expression, awaitPromise, returnByValue: true })
    if (result.exceptionDetails) throw new Error(`evaluate: ${result.exceptionDetails.exception?.description ?? result.exceptionDetails.text}`)
    return result.result.value
  }

  close() {
    this.#socket.close()
  }
}
