const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

const DEFAULT_SCOPE = 'button,[role=menuitem],[role=option],[role=tab],[role=radio],[role=checkbox],a,[role=button]'

export class Ui {
  constructor(cdp) {
    this.cdp = cdp
  }

  sleep = sleep

  async centerOf(finderExpression) {
    return this.cdp.evaluate(
      `(()=>{const e=${finderExpression};if(!e)return null;e.scrollIntoView({block:'center'});const b=e.getBoundingClientRect();return [b.x+b.width/2,b.y+b.height/2]})()`
    )
  }

  async mouseClick([x, y], button = 'left') {
    for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
      await this.cdp.send('Input.dispatchMouseEvent', { type, x, y, button, clickCount: 1 })
    }
  }

  async rightClick(finderExpression, { timeout = 10000 } = {}) {
    const deadline = Date.now() + timeout
    for (;;) {
      const point = await this.centerOf(finderExpression)
      if (point) {
        await this.mouseClick(point, 'right')
        await sleep(500)
        return
      }
      if (Date.now() > deadline) throw new Error(`right-click target not found: ${finderExpression.slice(0, 120)}`)
      await sleep(250)
    }
  }

  static byText(text, scope) {
    return `[...document.querySelectorAll(${JSON.stringify(scope || DEFAULT_SCOPE)})].filter(e=>e.offsetParent!==null).find(e=>(e.innerText||e.getAttribute('aria-label')||'').trim().toLowerCase().startsWith(${JSON.stringify(text.toLowerCase())}))`
  }

  static byPattern(pattern, scope) {
    return `[...document.querySelectorAll(${JSON.stringify(scope || DEFAULT_SCOPE)})].filter(e=>e.offsetParent!==null).find(e=>new RegExp(${JSON.stringify(pattern)},'i').test((e.innerText||e.getAttribute('aria-label')||'').trim()))`
  }

  static bySelector(selector) {
    return `document.querySelector(${JSON.stringify(selector)})`
  }

  async click(finderExpression, { timeout = 10000 } = {}) {
    const deadline = Date.now() + timeout
    for (;;) {
      const point = await this.centerOf(finderExpression)
      if (point) {
        await this.mouseClick(point)
        await sleep(350)
        return
      }
      if (Date.now() > deadline) throw new Error(`click target not found: ${finderExpression.slice(0, 120)}`)
      await sleep(250)
    }
  }

  clickText(text, scope) {
    return this.click(Ui.byText(text, scope))
  }

  clickSelector(selector) {
    return this.click(Ui.bySelector(selector))
  }

  async focus(selector) {
    await this.clickSelector(selector)
    await this.cdp.evaluate(`document.querySelector(${JSON.stringify(selector)})?.focus()`)
  }

  async type(text) {
    await this.cdp.send('Input.insertText', { text })
  }

  async press(key, code = key) {
    await this.cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: key === 'Enter' ? 13 : 0 })
    await this.cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code })
  }

  async waitFor(expression, { timeout = 30000, interval = 300, label = expression } = {}) {
    const deadline = Date.now() + timeout
    for (;;) {
      const value = await this.cdp.evaluate(expression)
      if (value) return value
      if (Date.now() > deadline) throw new Error(`timeout waiting for ${label.slice(0, 120)}`)
      await sleep(interval)
    }
  }

  async screenshot(path) {
    const { writeFile } = await import('node:fs/promises')
    const shot = await this.cdp.send('Page.captureScreenshot', { format: 'png' })
    await writeFile(path, Buffer.from(shot.data, 'base64'))
  }

  visibleControls(scope = '[role=dialog]') {
    return this.cdp.evaluate(
      `[...document.querySelectorAll(${JSON.stringify(scope + ' *')})].filter(e=>e.offsetParent!==null&&(e.children.length===0||['BUTTON','INPUT','TEXTAREA','SELECT'].includes(e.tagName)||e.getAttribute('role'))).map(e=>e.tagName+'|'+(e.getAttribute('role')||'')+'|'+(e.getAttribute('aria-label')||'')+'|'+(e.innerText||'').slice(0,50).replace(/\\n/g,' ')+'|'+(e.placeholder||'')+'|'+(e.name||'')).join('\\n')`
    )
  }
}
