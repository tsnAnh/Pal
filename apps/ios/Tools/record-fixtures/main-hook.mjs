import { CdpSession } from './cdp.mjs'

const INSTALL = `(() => {
  const { ipcMain } = process.mainModule.require('electron')
  const handlers = ipcMain._invokeHandlers
  if (globalThis.__fxHook) return 'already'
  const original = handlers.get('hermes:api')
  globalThis.__fxHook = { log: [], original }
  handlers.set('hermes:api', async (event, ...args) => {
    const startedAt = Date.now()
    try {
      const response = await original(event, ...args)
      globalThis.__fxHook.log.push({ startedAt, endedAt: Date.now(), request: args[0], response })
      return response
    } catch (error) {
      globalThis.__fxHook.log.push({ startedAt, endedAt: Date.now(), request: args[0], error: { message: String(error && error.message), status: error && error.status } })
      throw error
    }
  })
  return 'installed'
})()`

const DRAIN = `(() => globalThis.__fxHook ? JSON.stringify(globalThis.__fxHook.log.splice(0)) : '[]')()`

const UNINSTALL = `(() => {
  const hook = globalThis.__fxHook
  if (!hook) return 'none'
  process.mainModule.require('electron').ipcMain._invokeHandlers.set('hermes:api', hook.original)
  delete globalThis.__fxHook
  return 'restored'
})()`

export class MainHook {
  #session
  #timer
  #onEntry

  static async attach(port, onEntry) {
    const hook = new MainHook()
    hook.#onEntry = onEntry
    const registered = `(() => { try { return process.mainModule.require('electron').ipcMain._invokeHandlers.has('hermes:api') } catch { return false } })()`
    const deadline = Date.now() + 120000
    for (;;) {
      try {
        hook.#session = await CdpSession.connect(port, (targets) => targets.find((target) => target.type === 'node'))
        await hook.#session.send('Runtime.enable')
        while (!(await hook.#session.evaluate(registered))) {
          if (Date.now() > deadline) throw new Error('the main process never registered hermes:api')
          await new Promise((resolve) => setTimeout(resolve, 500))
        }
        await hook.#session.evaluate(INSTALL)
        break
      } catch (error) {
        hook.#session?.close()
        if (Date.now() > deadline) throw error
        await new Promise((resolve) => setTimeout(resolve, 1000))
      }
    }
    hook.#timer = setInterval(() => hook.drain().catch(() => {}), 400)
    return hook
  }

  async drain() {
    const entries = JSON.parse(await this.#session.evaluate(DRAIN))
    for (const entry of entries) this.#onEntry(entry)
  }

  async detach() {
    clearInterval(this.#timer)
    await this.drain().catch(() => {})
    await this.#session.evaluate(UNINSTALL).catch(() => {})
    this.#session.close()
  }
}
