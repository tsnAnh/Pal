import { execFile } from 'node:child_process'
import { mkdir, rm, writeFile } from 'node:fs/promises'
import { promisify } from 'node:util'
import path from 'node:path'
import { deflateSync } from 'node:zlib'
import { Ui } from './ui.mjs'

export const PROFILE = 'ios-fixture'
const ROW = `button[aria-label^="${PROFILE} ·"]`
const COMPOSER = '[data-fx=composer]'

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  return c >>> 0
})

const crc32 = (buffer) => {
  let c = 0xffffffff
  for (const byte of buffer) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

const chunk = (type, data) => {
  const body = Buffer.concat([Buffer.from(type), data])
  const out = Buffer.alloc(8 + data.length + 4)
  out.writeUInt32BE(data.length, 0)
  body.copy(out, 4)
  out.writeUInt32BE(crc32(body), 8 + data.length)
  return out
}

export function solidPng(width, height, [r, g, b]) {
  const row = Buffer.alloc(1 + width * 3)
  for (let x = 0; x < width; x++) row.set([r, g, b], 1 + x * 3)
  const raw = Buffer.concat(Array.from({ length: height }, () => row))
  const header = Buffer.alloc(13)
  header.writeUInt32BE(width, 0)
  header.writeUInt32BE(height, 4)
  header.set([8, 2, 0, 0, 0], 8)
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', Buffer.from(deflateSync(raw))),
    chunk('IEND', Buffer.alloc(0))
  ])
}

export async function prepareAssets(dir) {
  await mkdir(dir, { recursive: true })
  const png = path.join(dir, 'fixture-blue.png')
  const text = path.join(dir, 'fixture-notes.txt')
  await writeFile(png, solidPng(32, 32, [30, 90, 220]))
  await writeFile(text, 'ios fixture attachment\nsecret word: pelican\n')
  const speech = path.join(dir, 'fixture-speech.wav')
  const aiff = path.join(dir, 'fixture-speech.aiff')
  const run = promisify(execFile)
  await run('say', ['-o', aiff, 'Hello, please tell me a short fact about the moon.'])
  await run('afconvert', ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', aiff, speech])
  await rm(aiff)
  return { png, text, speech }
}

export async function deleteBotViaUi({ ui, cdp }) {
  const present = await ui.waitFor(`!!document.querySelector(${JSON.stringify(ROW)})`, { timeout: 20000, label: 'bot row' }).then(() => true, () => false)
  if (!present) {
    await cdp.send('Page.reload')
    await ui.waitFor(`!!document.querySelector(${JSON.stringify(ROW)})`, { timeout: 180000, label: 'bot row after reload' })
  }
  await ui.rightClick(Ui.bySelector(ROW), { timeout: 60000 })
  await ui.click(Ui.byPattern('^Delete$', '[role=menuitem]'))
  await ui.click(Ui.byPattern('^Delete', '[role=alertdialog] button,[role=dialog] button'), { timeout: 15000 })
  await ui.waitFor(`!document.querySelector(${JSON.stringify(ROW)})`, { timeout: 60000, label: `${PROFILE} row to disappear` })
}

export async function openBotChat({ ui }) {
  await ui.click(Ui.bySelector(ROW), { timeout: 90000 })
  await ui.waitFor(COMPOSER_VISIBLE, { timeout: 180000, label: 'composer' })
  await ui.sleep(1500)
}

const COMPOSER_VISIBLE = `[...document.querySelectorAll('[aria-label=Message]')].some(e=>e.offsetParent!==null)`

export async function assertBotChat({ cdp, ui }) {
  await ui.waitFor(COMPOSER_VISIBLE, { timeout: 180000, label: 'chat composer' })
  const inBotChat = await cdp.evaluate(
    `[...document.querySelectorAll('*')].some(e=>e.offsetParent!==null&&e.children.length===0&&(e.textContent.trim()==='@${PROFILE}'||(e.textContent||'').trim()==='Message ${PROFILE}'))`
  )
  if (!inBotChat) throw new Error(`refusing to type: the open chat is not ${PROFILE}`)
}

async function dropFiles({ cdp, ui }, files) {
  await assertBotChat({ cdp, ui })
  const [x, y] = await cdp.evaluate(`(()=>{const e=[...document.querySelectorAll('[aria-label=Message]')].find(e=>e.offsetParent!==null);const b=e.getBoundingClientRect();return [b.x+b.width/2,b.y+b.height/2]})()`)
  const data = { items: [], files, dragOperationsMask: 1 }
  for (const type of ['dragEnter', 'dragOver', 'drop']) {
    await cdp.send('Input.dispatchDragEvent', { type, x, y, data })
    await ui.sleep(300)
  }
  await ui.sleep(2500)
}

async function clearComposer({ cdp, ui }) {
  await assertBotChat({ cdp, ui })
  await cdp.evaluate(`(()=>{const e=[...document.querySelectorAll('[aria-label=Message]')].find(e=>e.offsetParent!==null);e.focus();document.execCommand('selectAll');document.execCommand('delete')})()`)
}

async function send({ cdp, ui, capture }, text, { contains = false } = {}) {
  await assertBotChat({ cdp, ui })
  await ensureIdle({ cdp, ui })
  const mark = capture.mark()
  await cdp.evaluate(`(()=>{document.querySelectorAll('[data-fx=composer]').forEach(e=>delete e.dataset.fx);const e=[...document.querySelectorAll('[aria-label=Message]')].find(e=>e.offsetParent!==null);e.dataset.fx='composer'})()`)
  await ui.clickSelector(COMPOSER)
  await ui.type(text)
  await ui.sleep(300)
  await ui.press('Enter')
  const { message } = await capture.waitForFrame(
    mark,
    (m, r) => r.dir === 'send' && m.method === 'prompt.submit' && m.params?.profile === PROFILE && (contains ? String(m.params?.text).includes(text) : m.params?.text === text),
    { label: 'prompt.submit' }
  )
  return { mark, sessionId: message.params.session_id }
}

async function ensureIdle({ ui, cdp }) {
  const dismiss = async () => {
    await ui.click(Ui.byPattern('^(Skip|Dismiss question)$', 'button'), { timeout: 1500 }).catch(() => {})
    await ui.click(Ui.byPattern('^Stop$', 'button'), { timeout: 1500 }).catch(() => {})
  }
  const busy = `[...document.querySelectorAll('button')].some(b=>b.offsetParent!==null&&(/^(Stop|Skip|Dismiss question)$/.test((b.innerText||b.getAttribute('aria-label')||'').trim())))`
  for (let attempt = 0; attempt < 6 && (await cdp.evaluate(busy)); attempt++) {
    await dismiss()
    await ui.sleep(2500)
  }
}

const waitForClarify = (capture, turn, timeout = 90000) =>
  capture.waitForFrame(turn.mark, (m) => m.method === 'clarify' && m.id !== undefined && m.params?.session_id === turn.sessionId, { label: 'clarify server request', timeout })

const turnDone = (ctx, turn, timeout = 300000) => ctx.capture.waitForEvent(turn.mark, turn.sessionId, 'message.complete', { timeout })

const safeParse = (text) => {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

export const SCENARIOS = [
  {
    name: 'open-bot',
    async run(ctx) {
      const { ui, cdp, capture } = ctx
      for (let attempt = 0; ; attempt++) {
        await ui.clickSelector('[aria-label="New bot or group chat"]')
        const opened = await ui.waitFor(`[...document.querySelectorAll('[role=menuitem]')].some(e=>e.offsetParent!==null&&/^New bot/i.test(e.innerText))`, { timeout: 4000, label: 'new bot menu' }).then(() => true, () => false)
        if (opened) break
        if (attempt >= 4) throw new Error('the New bot menu never opened')
        await ui.press('Escape')
        await ui.sleep(1000)
      }
      await ui.click(Ui.byPattern('^New bot', '[role=menuitem]'))
      await ui.waitFor(`!!document.querySelector('input[placeholder="inbox-triage"]')`)
      await ui.focus('input[placeholder="inbox-triage"]')
      await cdp.evaluate(`document.querySelector('input[placeholder="inbox-triage"]').select()`)
      await ui.type(PROFILE)
      const mark = capture.mark()
      await ctx.beforeCreate?.()
      await ui.click(Ui.byPattern('^Create Bot$', 'button'))
      await capture.waitForFrame(mark, (m) => m.id !== undefined && m.result?.name === PROFILE && m.result?.ok === true, { label: 'profiles.create result' })
      await capture.waitForFrame(mark, (m, r) => r.dir === 'send' && m.method === 'session.create' && m.params?.profile === PROFILE, { label: 'session.create', timeout: 60000 })
      await openBotChat(ctx)
      await capture.waitForFrame(mark, (m, r) => r.dir === 'send' && m.method === 'session.resume' && m.params?.profile === PROFILE, { label: 'session.resume' })
      await ui.sleep(3000)
    }
  },
  {
    name: 'send-stream',
    async run(ctx) {
      const turn = await send(ctx, 'Reply with exactly three short sentences about the color blue.')
      await turnDone(ctx, turn)
      await ctx.ui.sleep(1500)
    }
  },
  {
    name: 'clarify',
    async run(ctx) {
      const { ui, capture } = ctx
      const askSingle = async () => {
        const turn = await send(ctx, "Call your clarify tool right now with exactly one question: 'Which color do you prefer?' and the choices red, green, blue. Do not write any text before calling the tool.")
        await waitForClarify(capture, turn, 75000)
        return turn
      }
      const single = await askSingle().catch(async () => {
        await ensureIdle(ctx)
        return askSingle()
      })
      await ui.sleep(1500)
      await ui.click(Ui.byPattern('^B\\s+green', 'button'))
      await turnDone(ctx, single)
      await ui.sleep(1500)
      const multi = await send(ctx, "Call your clarify tool once with exactly two questions in the same call. Question 1: 'Pick a size' with choices small, large. Question 2: 'Pick a shape' with choices circle, square. Do not write any text before calling the tool.")
      await waitForClarify(capture, multi)
      await ui.sleep(1500)
      await ui.click(Ui.byPattern('^B\\s+large', 'button'))
      await ui.click(Ui.byPattern('^B\\s+square', 'button'), { timeout: 20000 })
      await ui.click(Ui.byPattern('^Confirm and continue', 'button'), { timeout: 20000 })
      await turnDone(ctx, multi)
      await ui.sleep(1500)
    }
  },
  {
    name: 'handback',
    async run(ctx) {
      const { ui, capture } = ctx
      const ask = async (reason, button) => {
        const turn = await send(ctx, `Call your request_handback tool right now with the reason '${reason}'. After the tool returns, end your turn with one short line. Do not do anything else.`)
        await turnDone(ctx, turn)
        const toolEvents = capture.records
          .slice(turn.mark)
          .map((record) => (record.kind === 'ws-frame' ? safeParse(record.payload) : null))
          .filter((message) => message?.method === 'event' && message.params.session_id === turn.sessionId && /^tool\./.test(message.params.type))
        const called = toolEvents.some((message) => message.params.payload?.name === 'request_handback')
        if (!called) return { partial: 'request_handback tool unavailable for this profile: the model never saw it', turn }
        await ui.click(Ui.byPattern(button, 'button'), { timeout: 15000 }).catch(() => {})
        await ui.sleep(2500)
        return { turn }
      }
      const done = await ask('Sign in to Example to continue', "^I'm done$")
      if (done.partial) return { partial: done.partial }
      await ctx.capture.waitForEvent(done.turn.mark, done.turn.sessionId, 'message.complete', { timeout: 120000 }).catch(() => {})
      await ui.sleep(4000)
      const cancel = await ask('Enter the code sent to your phone', '^Cancel$')
      if (cancel.partial) return { partial: cancel.partial }
      await ui.sleep(5000)
    }
  },
  {
    name: 'attachment',
    async run(ctx) {
      const { ui } = ctx
      await clearComposer(ctx)
      await dropFiles(ctx, [ctx.assets.png, ctx.assets.text])
      const question = 'What color is the attached image, and what is the secret word in the attached text file? Answer in one sentence.'
      const turn = await send(ctx, question, { contains: true })
      await turnDone(ctx, turn, 180000)
      await ui.sleep(2000)
    }
  },
  {
    name: 'voice',
    async run(ctx) {
      const { ui, cdp } = ctx
      await clearComposer(ctx)
      await ui.click(Ui.bySelector('button[aria-label="Voice dictation"]'))
      await ui.sleep(7000)
      await ui.click(Ui.bySelector('button[aria-label="Stop dictation"]'))
      const transcribed = await ui
        .waitFor(`(()=>{const e=[...document.querySelectorAll('[aria-label=Message]')].find(e=>e.offsetParent!==null);return e&&e.innerText.trim().length>0})()`, { timeout: 25000, label: 'dictated text' })
        .then(() => true, () => false)
      await ui.sleep(1500)
      await clearComposer(ctx)
      await cdp.evaluate(`(()=>{document.querySelectorAll('[data-fx=read-aloud]').forEach(e=>delete e.dataset.fx);const b=[...document.querySelectorAll('button[aria-label="Read aloud"]')].filter(b=>b.offsetParent!==null).pop();b.dataset.fx='read-aloud'})()`)
      await ui.click(Ui.bySelector('[data-fx=read-aloud]'))
      await ui.sleep(12000)
      if (!transcribed) {
        return { partial: 'dictation sent audio to /api/audio/transcribe but the gateway returned an empty transcript (provider null: no speech-to-text provider is configured); TTS via /api/audio/speak is complete' }
      }
    }
  },
  {
    name: 'reconnect',
    async run(ctx) {
      const { cdp, ui, capture } = ctx
      const turn = await send(ctx, 'Count from 1 to 80, one number per line, each followed by a different animal name. No other text.')
      await capture.waitForEvent(turn.mark, turn.sessionId, 'message.delta', { timeout: 90000 })
      await ui.sleep(1500)
      const offline = (value) => cdp.send('Network.emulateNetworkConditions', { offline: value, latency: 0, downloadThroughput: -1, uploadThroughput: -1 })
      await offline(true)
      const proto = await cdp.send('Runtime.evaluate', { expression: 'WebSocket.prototype' })
      const { objects } = await cdp.send('Runtime.queryObjects', { prototypeObjectId: proto.result.objectId })
      await cdp.send('Runtime.callFunctionOn', {
        objectId: objects.objectId,
        functionDeclaration: 'function(){this.filter(w=>w.readyState===1&&/\\/api\\/ws/.test(w.url)).forEach(w=>w.close(3000,"fixture-drop"))}'
      })
      const droppedAt = Date.now() - capture.epoch
      const dropMark = capture.mark()
      await ui.sleep(6000)
      await offline(false)
      let reloaded = false
      const resumed = await capture
        .waitForFrame(dropMark, (m, r) => r.dir === 'send' && m.method === 'session.events.since', { timeout: 60000, label: 'session.events.since' })
        .then(() => true, () => false)
      if (!resumed) {
        reloaded = true
        await cdp.send('Page.reload')
        await openBotChat(ctx)
      }
      const { record } = await capture.waitForEvent(turn.mark, turn.sessionId, 'message.complete', { timeout: 240000 })
      await ui.sleep(3000)
      if (record.t < droppedAt) return { partial: 'the stream finished before the socket was dropped' }
      if (reloaded) return { partial: 'the app did not redial on its own within 60s of coming back online, so the page was reloaded; the redial frames are the reload path, not the in-place resume' }
    }
  }
]
