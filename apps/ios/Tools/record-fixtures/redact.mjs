import { createHash } from 'node:crypto'
import os from 'node:os'

const SECRET_KEYS = /^(authorization|proxy-authorization|cookie|set-cookie|x-hermes-session-token|x-hermes-gateway-ticket|ticket|token|access_token|refresh_token|id_token|api_key|apikey|secret|client_secret|password|install_id|code_verifier|session_token)$/i

const SECRET_STRING_KEYS = /^(code|state)$/i

const OPAQUE_KEYS = new Set(['system_prompt'])

const DATA_URL = /data:[\w.+-]+\/[\w.+-]+(?:;[\w=.+-]+)*;base64,[A-Za-z0-9+/=_-]{200,}/g
const LONG_BASE64 = /[A-Za-z0-9+/_-]{257,}={0,2}/g

const SECRET_PATTERNS = [
  [/hermes-gateway-ticket\.[^\s",;]+/gi, '<redacted>'],
  [/[?&](?:ticket|token|access_token|api_key|apikey|key|code|state|code_verifier|session_token)=[^&\s"'#]*/gi, '<redacted>'],
  [/\b(?:code|state|code_verifier|session_token)=[^&\s"'#]+/gi, '<redacted>'],
  [/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, '<redacted>'],
  [/\bsk-[A-Za-z0-9_-]{16,}/g, '<redacted>'],
  [/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/g, '<redacted>'],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/g, '<redacted>'],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}/g, '<redacted>'],
  [/\bAKIA[0-9A-Z]{16}\b/g, '<redacted>'],
  [/\bAIza[0-9A-Za-z_-]{30,}/g, '<redacted>'],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, '<redacted>']
]

export const blobMarker = (text) => `<blob sha256=${createHash('sha256').update(text).digest('hex')} len=${text.length}>`

export const blobMarkerForBytes = (bytes) => `<blob sha256=${createHash('sha256').update(bytes).digest('hex')} len=${bytes.length}>`

export class Redactor {
  constructor({ home = os.homedir(), extraSecrets = [], maskWords = [] } = {}) {
    this.home = home
    this.mask = [...maskWords].sort((a, b) => b.length - a.length).map((word) => new RegExp(word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'))
    this.secrets = extraSecrets.filter((value) => typeof value === 'string' && value.length >= 12)
  }

  maskKey(key) {
    let out = key
    for (const pattern of this.mask) out = out.replace(pattern, '<other-bot>')
    return out
  }

  string(text) {
    if (text.length > 256 && /^[A-Za-z0-9+/=_\-\s]+$/.test(text) && !/\s/.test(text.trim())) return blobMarker(text)
    if (text.length > 256 && text.startsWith('data:')) return blobMarker(text)
    let out = text.replace(DATA_URL, (match) => blobMarker(match))
    out = out.replace(LONG_BASE64, (match) => blobMarker(match))
    for (const [pattern, replacement] of SECRET_PATTERNS) out = out.replace(pattern, replacement)
    for (const secret of this.secrets) if (out.includes(secret)) out = out.split(secret).join('<redacted>')
    for (const pattern of this.mask) out = out.replace(pattern, '<other-bot>')
    return out.split(this.home).join('~')
  }

  value(input, key = '') {
    if (SECRET_KEYS.test(key) && input !== null && input !== '' && input !== false) return '<redacted>'
    if (typeof input === 'string' && input !== '' && SECRET_STRING_KEYS.test(key)) return '<redacted>'
    if (typeof input === 'string' && OPAQUE_KEYS.has(key)) return blobMarker(input)
    if (typeof input === 'string') return this.string(input)
    if (Array.isArray(input)) return input.map((item) => this.value(item))
    if (input && typeof input === 'object') {
      return Object.fromEntries(Object.entries(input).map(([k, v]) => [this.maskKey(k), this.value(v, k)]))
    }
    return input
  }
}
