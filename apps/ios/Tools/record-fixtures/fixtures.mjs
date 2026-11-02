import { Redactor, blobMarker, blobMarkerForBytes } from './redact.mjs'

const CONNECTION_METHODS = new Set(['client.capabilities', 'runtime.describe', 'gateway.ping', 'profiles.list'])
const CONNECTION_EVENTS = new Set(['gateway.ready', 'runtime.describe'])
const SESSION_ID_KEYS = new Set(['session_id', 'stored_session_id', 'resolved_id', 'runtime_session_id'])
const SAFE_HTTP_HEADERS = new Set(['content-type', 'accept', 'content-length', 'content-disposition'])

const parse = (text) => {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

const pathOf = (url) => {
  try {
    return new URL(url).pathname
  } catch {
    return String(url).split('?')[0]
  }
}

const queryOf = (url) => {
  try {
    return new URL(url).searchParams
  } catch {
    return new URLSearchParams()
  }
}

export class FixtureBuilder {
  constructor({ profile, denyWords, redactor, extraMethods = new Set() }) {
    this.profile = profile
    this.denyWords = denyWords
    this.redactor = redactor
    this.extraMethods = extraMethods
    this.sessions = new Set()
    this.keptRequests = new Map()
    this.keptServerRequests = new Set()
    this.dropped = new Map()
    this.droppedMethods = new Map()
  }

  #drop(kind) {
    this.dropped.set(kind, (this.dropped.get(kind) ?? 0) + 1)
    return null
  }

  #learnSessions(value, depth = 0) {
    if (depth > 6 || !value || typeof value !== 'object') return
    if (Array.isArray(value)) return value.forEach((item) => this.#learnSessions(item, depth + 1))
    for (const [key, item] of Object.entries(value)) {
      if (SESSION_ID_KEYS.has(key) && typeof item === 'string' && item) this.sessions.add(item)
      else if (key === 'canonical_session' && item?.id) {
        this.sessions.add(item.id)
        if (item.resolved_id) this.sessions.add(item.resolved_id)
      } else if (typeof item === 'object') this.#learnSessions(item, depth + 1)
    }
  }

  #requestBelongs(message) {
    const params = message.params ?? {}
    if (CONNECTION_METHODS.has(message.method)) return true
    if (this.extraMethods.has(message.method) && (params.profile === this.profile || this.sessions.has(params.session_id))) return true
    if (params.profile === this.profile || params.name === this.profile) return true
    if (params.session_id && this.sessions.has(params.session_id)) return true
    return false
  }

  #profilesList(result) {
    const rows = Array.isArray(result.profiles) ? result.profiles : []
    const own = rows.find((row) => row?.name === this.profile)
    const others = rows.length - (own ? 1 : 0)
    return { ...result, profiles: [...(own ? [own] : []), `<${others} other rows>`] }
  }

  ws(record) {
    const key = (id) => `${record.socket}:${id}`
    if (record.kind === 'ws-open') {
      return { dir: 'send', frame: { ws: { event: 'open', subprotocols: ['hermes-gateway-v1', '<redacted>'] } } }
    }
    if (record.kind === 'ws-close') return { dir: 'recv', frame: { ws: { event: 'close' } } }
    if (record.kind === 'ws-error') return { dir: 'recv', frame: { ws: { event: 'error', message: this.redactor.string(record.error ?? '') } } }
    if (record.kind !== 'ws-frame') return null
    const message = parse(record.payload)
    if (!message || typeof message !== 'object') return this.#drop('unparseable')

    if (record.dir === 'send') {
      if (!message.method && message.id !== undefined && this.keptServerRequests.has(key(message.id))) {
        return { dir: 'send', frame: this.redactor.value(message) }
      }
      if (!message.method) return this.#drop('send-other')
      if (!this.#requestBelongs(message)) {
        this.droppedMethods.set(message.method, (this.droppedMethods.get(message.method) ?? 0) + 1)
        return this.#drop('send-other-scope')
      }
      this.keptRequests.set(key(message.id), message.method)
      return { dir: 'send', frame: this.redactor.value(message) }
    }

    if (typeof message.method === 'string' && message.method !== 'event' && message.id !== undefined) {
      if (!this.sessions.has(message.params?.session_id)) return this.#drop('server-request-other-scope')
      this.keptServerRequests.add(key(message.id))
      return { dir: 'recv', frame: this.redactor.value(message) }
    }

    if (message.method === 'event') {
      const params = message.params ?? {}
      const own = params.session_id && this.sessions.has(params.session_id)
      if (!own && !CONNECTION_EVENTS.has(params.type)) return this.#drop('event-other-scope')
      return { dir: 'recv', frame: this.redactor.value(message) }
    }

    if (message.id !== undefined && key(message.id) && this.keptRequests.has(key(message.id))) {
      const method = this.keptRequests.get(key(message.id))
      let body = message
      if (method === 'profiles.list' && message.result) body = { ...message, result: this.#profilesList(message.result) }
      if (method === 'profiles.list' && message.result?.profiles) {
        const own = message.result.profiles.find((row) => row?.name === this.profile)
        if (own) this.#learnSessions(own)
      } else if (message.result && method !== 'profiles.list') this.#learnSessions(message.result)
      return { dir: 'recv', frame: this.redactor.value(body) }
    }
    return this.#drop('recv-other')
  }

  http(record) {
    const url = record.url
    const params = queryOf(url)
    const body = typeof record.body === 'string' ? record.body : ''
    const mentions = (needle) => url.includes(needle) || body.includes(needle)
    const belongs =
      (record.via && /^\/api\/audio\//.test(pathOf(url))) ||
      params.get('profile') === this.profile ||
      mentions(this.profile) ||
      [...this.sessions].some((id) => mentions(id))
    if (!belongs) {
      const key = `${record.method} ${pathOf(url)}`
      this.droppedMethods.set(key, (this.droppedMethods.get(key) ?? 0) + 1)
      return this.#drop('http-other-scope')
    }
    const headers = Object.fromEntries(
      Object.entries(record.headers ?? {}).filter(([name]) => SAFE_HTTP_HEADERS.has(name.toLowerCase()))
    )
    const responseHeaders = Object.fromEntries(
      Object.entries(record.responseHeaders ?? {}).filter(([name]) => SAFE_HTTP_HEADERS.has(name.toLowerCase()))
    )
    return {
      dir: 'send',
      channel: 'http',
      urlPath: pathOf(url),
      frame: {
        http: {
          ...(record.via ? { via: record.via } : {}),
          method: record.method,
          status: record.status ?? 0,
          query: this.redactor.value(Object.fromEntries(params.entries())),
          request: { headers, body: this.#httpBody(record.body, headers) },
          response: { headers: responseHeaders, body: this.#responseBody(record.response, responseHeaders) },
          ...(record.error ? { error: this.redactor.string(record.error) } : {})
        }
      }
    }
  }

  #httpBody(text, headers) {
    if (text === null || text === undefined || text === '') return null
    const contentType = Object.entries(headers).find(([name]) => name.toLowerCase() === 'content-type')?.[1] ?? ''
    const json = parse(text)
    if (json !== undefined) return this.redactor.value(json)
    if (/multipart\/form-data/i.test(contentType)) return this.#multipart(text)
    return text.length > 256 ? blobMarker(text) : this.redactor.string(text)
  }

  #multipart(text) {
    const parts = text.split(/\r?\n--[^\r\n]*/).map((part) => part.trim()).filter((part) => part && part !== '--')
    return {
      multipart: parts.map((part) => {
        const [head, ...rest] = part.split(/\r?\n\r?\n/)
        const content = rest.join('\n\n')
        return {
          headers: this.redactor.string(head.replace(/\r?\n/g, '; ')),
          body: content.length > 256 || /[^\x20-\x7e\s]/.test(content) ? blobMarker(content) : this.redactor.string(content)
        }
      })
    }
  }

  #responseBody(response, headers) {
    if (!response) return null
    if (response.base64) return blobMarkerForBytes(Buffer.from(response.base64, 'base64'))
    if (response.text === null || response.text === undefined) return null
    const json = parse(response.text)
    if (json !== undefined) return this.redactor.value(json)
    return response.text.length > 256 ? blobMarker(response.text) : this.redactor.string(response.text)
  }

  build(records, startT) {
    const lines = []
    const ordered = [...records].sort((a, b) => a.t - b.t)
    for (const record of ordered) {
      let entry = null
      let channel = 'ws'
      let urlPath = pathOf(record.url ?? '')
      if (record.kind === 'http') {
        entry = this.http(record)
        if (entry) ({ channel, urlPath } = entry)
      } else entry = this.ws(record)
      if (!entry) continue
      lines.push({ t: Math.max(0, record.t - startT), dir: entry.dir, channel, url_path: urlPath, frame: entry.frame })
    }
    return lines
  }

  audit(text) {
    const lowered = text.toLowerCase()
    return this.denyWords.flatMap((word) => {
      const hits = []
      const needle = word.toLowerCase()
      for (let at = lowered.indexOf(needle); at !== -1 && hits.length < 3; at = lowered.indexOf(needle, at + 1)) {
        hits.push({ word, context: text.slice(Math.max(0, at - 70), at + word.length + 40) })
      }
      return hits
    })
  }
}
