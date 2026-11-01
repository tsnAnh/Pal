import { $botChromeless } from './bot-surface'

type ChromeLayout = 'default' | 'relaxed'

export function bindWindowChromeLayout(): () => void {
  let applied: ChromeLayout | null = null

  const apply = (layout: ChromeLayout) => {
    if (layout === applied) {
      return
    }

    applied = layout
    window.hermesDesktop?.windowChrome?.setLayout(layout)
  }

  const stop = $botChromeless.subscribe(chromeless => apply(chromeless ? 'relaxed' : 'default'))

  return () => {
    stop()
    apply('default')
  }
}
