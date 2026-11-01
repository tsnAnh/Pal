import { atom } from '@hermes/plugin-sdk'

export const $botSearchOpen = atom(false)

export const openBotSearch = () => $botSearchOpen.set(true)

export const closeBotSearch = () => $botSearchOpen.set(false)
