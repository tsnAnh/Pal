import fs from 'node:fs'
import path from 'node:path'

import type { Page } from '@playwright/test'

import { CARD_CLARIFY_QUESTIONS, CARD_CLARIFY_TRIGGER } from '../../../tests-js/scripts/mock-server'

import { type MockBackendFixture, setupMockBackend, waitForAppReady } from './fixtures'
import { expect, test } from './test'

const ARTIFACT_DIR = process.env.CLARIFY_CARD_SCREENSHOT_DIR ?? path.join(process.cwd(), 'test-results', 'clarify-card')
const [{ question: QUESTION, choices: CHOICES }] = CARD_CLARIFY_QUESTIONS

let fixture: MockBackendFixture | null = null

async function capture(page: Page, name: string): Promise<void> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true })
  await page.screenshot({ animations: 'disabled', caret: 'hide', path: path.join(ARTIFACT_DIR, `${name}.png`) })
}

async function resizeWindow(width: number, height: number): Promise<void> {
  await fixture!.app.evaluate(
    ({ BrowserWindow }, size) => {
      const win = BrowserWindow.getAllWindows()[0]

      win?.unmaximize()
      win?.setMinimumSize(1, 1)
      win?.setBounds({ height: size.height, width: size.width, x: 0, y: 0 })
    },
    { height, width }
  )
}

test.beforeAll(async () => {
  fixture = await setupMockBackend()
  await waitForAppReady(fixture!, 120_000)
})

test.afterAll(async () => {
  await fixture?.cleanup()
  fixture = null
})

test('a question card shows lettered options, a free-text footer, and answers from the keyboard', async () => {
  test.setTimeout(180_000)
  const page = fixture!.page
  await page.emulateMedia({ colorScheme: 'light' })

  const composer = page.locator('[contenteditable="true"]').first()
  await composer.waitFor({ state: 'visible', timeout: 10_000 })
  await composer.click()
  await composer.type(CARD_CLARIFY_TRIGGER, { delay: 20 })
  await page.keyboard.press('Enter')

  const card = page.locator('form[data-clarify-batch]')
  await expect(card).toHaveCount(1, { timeout: 60_000 })
  await expect(card.getByText(QUESTION)).toBeVisible()

  const rows = card.locator('button[data-choice]')
  await expect(rows).toHaveCount(CHOICES.length)

  for (const [index, choice] of CHOICES.entries()) {
    await expect(rows.nth(index)).toContainText(choice)
    await expect(rows.nth(index)).toContainText(String.fromCharCode(65 + index))
  }

  const input = card.getByPlaceholder('Type your own answer')
  const send = card.getByRole('button', { name: 'Send' })
  await expect(card.getByRole('button', { name: 'Dismiss question' })).toBeVisible()
  await expect(send).toBeDisabled()
  await page.mouse.move(0, 0)
  await capture(page, '01-default-light')

  await rows.nth(1).hover()
  await rows.nth(1).focus()
  await capture(page, '02-hover-focus-b')

  await input.fill('   ')
  await expect(send).toBeDisabled()
  await input.fill('Something only I know')
  await expect(send).toBeEnabled()
  await capture(page, '03-typing')
  await input.fill('')

  await page.emulateMedia({ colorScheme: 'dark' })
  await expect(page.locator('html')).toHaveClass(/dark/, { timeout: 10_000 })
  await page.waitForTimeout(600)
  await capture(page, '04-default-dark')
  await page.emulateMedia({ colorScheme: 'light' })
  await expect(page.locator('html')).not.toHaveClass(/dark/, { timeout: 10_000 })

  await resizeWindow(400, 800)
  await page.waitForTimeout(600)
  await input.fill('Something only I know')
  await capture(page, '05-narrow-400')
  const overflow = await card.evaluate(el => el.scrollWidth - el.clientWidth)
  expect(overflow, 'the card never overflows horizontally at 400px').toBeLessThanOrEqual(0)
  await input.fill('')
  await resizeWindow(1220, 800)
  await page.waitForTimeout(600)

  await input.focus()
  await input.blur()
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('b')

  const settled = page.locator('[data-clarify-settled]')
  await settled.waitFor({ state: 'visible', timeout: 30_000 })
  await expect(settled.getByText(CHOICES[1], { exact: true })).toBeVisible()
  await expect(page.locator('form[data-clarify-batch]')).toHaveCount(0)
  await capture(page, '06-answered')
})
