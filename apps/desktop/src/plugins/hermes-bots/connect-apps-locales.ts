import type { BotsMessages } from './i18n-messages'

type ConnectAppsMessages = BotsMessages['connectApps']

export const CONNECT_APPS_LOCALES: Record<'en' | 'ja' | 'zh' | 'zh-hant', ConnectAppsMessages> = {
  en: {
    menu: 'Connect apps…',
    title: 'Connect apps',
    description: 'Connect an app once, then choose which bots may use it.',
    focusDescription: bot => `Connect apps and choose which ones ${bot} may use.`,
    searchPlaceholder: 'Search apps',
    searchLabel: 'Search apps',
    popular: 'Popular',
    moreApps: 'More apps',
    noResults: 'No apps match your search.',
    loading: 'Loading apps…',
    noBots: 'No bots yet.',
    status: { connected: 'Connected', needsSignIn: 'Needs sign-in again', notConnected: 'Not connected' },
    comingSoon: 'Not available yet',
    unknown: 'Can’t check right now',
    offByOrg: 'Turned off by your organization',
    action: { cancel: 'Cancel', connect: 'Connect', reconnect: 'Sign in again', setup: 'Set up…', turnOn: 'Turn on' },
    waiting: 'Finish signing in in your browser…',
    usedBy: bots => `Used by ${bots}`,
    usedByNone: 'No bots use it yet',
    manageBots: 'Choose bots',
    useFor: bot => `Let ${bot} use this app`,
    botNeedsSignIn: 'Needs sign-in',
    botSignIn: 'Sign in',
    botUnknown: 'Can’t check',
    notice: {
      failed: 'Couldn’t load apps.',
      retry: 'Try again',
      signedOut: 'Sign in to Hermes to connect apps.',
      unavailable: 'Apps aren’t available for this account.'
    },
    failure: {
      failed: 'Couldn’t update this bot. Try again.',
      needsSetup: 'This app needs setup before a bot can use it. Choose Set up….',
      rulesReadOnly: 'This bot’s app rules can’t be changed right now.'
    },
    openFromBot: 'Connect apps…'
  },
  ja: {
    menu: 'アプリを接続…',
    title: 'アプリを接続',
    description: 'アプリを一度接続すると、どのボットが使えるかを選べます。',
    focusDescription: bot => `アプリを接続し、${bot} が使えるものを選びます。`,
    searchPlaceholder: 'アプリを検索',
    searchLabel: 'アプリを検索',
    popular: '人気',
    moreApps: 'その他のアプリ',
    noResults: '一致するアプリがありません。',
    loading: 'アプリを読み込み中…',
    noBots: 'ボットがまだありません。',
    status: { connected: '接続済み', needsSignIn: '再度サインインが必要', notConnected: '未接続' },
    comingSoon: 'まだ利用できません',
    unknown: '今は確認できません',
    offByOrg: '組織によりオフになっています',
    action: {
      cancel: 'キャンセル',
      connect: '接続',
      reconnect: '再度サインイン',
      setup: '設定…',
      turnOn: 'オンにする'
    },
    waiting: 'ブラウザーでサインインを完了してください…',
    usedBy: bots => `使用中: ${bots}`,
    usedByNone: 'まだ使っているボットはありません',
    manageBots: 'ボットを選ぶ',
    useFor: bot => `${bot} にこのアプリの使用を許可`,
    botNeedsSignIn: 'サインインが必要',
    botSignIn: 'サインイン',
    botUnknown: '確認できません',
    notice: {
      failed: 'アプリを読み込めませんでした。',
      retry: '再試行',
      signedOut: 'アプリを接続するには Hermes にサインインしてください。',
      unavailable: 'このアカウントではアプリを利用できません。'
    },
    failure: {
      failed: 'このボットを更新できませんでした。もう一度お試しください。',
      needsSetup: 'ボットが使う前にこのアプリの設定が必要です。「設定…」を選んでください。',
      rulesReadOnly: 'このボットのアプリ設定は今は変更できません。'
    },
    openFromBot: 'アプリを接続…'
  },
  zh: {
    menu: '连接应用…',
    title: '连接应用',
    description: '连接一次应用，然后选择哪些机器人可以使用。',
    focusDescription: bot => `连接应用，并选择 ${bot} 可以使用哪些。`,
    searchPlaceholder: '搜索应用',
    searchLabel: '搜索应用',
    popular: '热门',
    moreApps: '更多应用',
    noResults: '没有匹配的应用。',
    loading: '正在加载应用…',
    noBots: '还没有机器人。',
    status: { connected: '已连接', needsSignIn: '需要重新登录', notConnected: '未连接' },
    comingSoon: '暂不可用',
    unknown: '暂时无法检查',
    offByOrg: '已被你的组织关闭',
    action: { cancel: '取消', connect: '连接', reconnect: '重新登录', setup: '设置…', turnOn: '开启' },
    waiting: '请在浏览器中完成登录…',
    usedBy: bots => `使用者：${bots}`,
    usedByNone: '还没有机器人使用',
    manageBots: '选择机器人',
    useFor: bot => `允许 ${bot} 使用此应用`,
    botNeedsSignIn: '需要登录',
    botSignIn: '登录',
    botUnknown: '无法检查',
    notice: {
      failed: '无法加载应用。',
      retry: '重试',
      signedOut: '请登录 Hermes 以连接应用。',
      unavailable: '此账户暂不支持应用。'
    },
    failure: {
      failed: '无法更新此机器人，请重试。',
      needsSetup: '机器人使用前，此应用需要先设置。请选择“设置…”。',
      rulesReadOnly: '此机器人的应用规则目前无法更改。'
    },
    openFromBot: '连接应用…'
  },
  'zh-hant': {
    menu: '連接應用程式…',
    title: '連接應用程式',
    description: '連接一次應用程式，再選擇哪些機器人可以使用。',
    focusDescription: bot => `連接應用程式，並選擇 ${bot} 可以使用哪些。`,
    searchPlaceholder: '搜尋應用程式',
    searchLabel: '搜尋應用程式',
    popular: '熱門',
    moreApps: '更多應用程式',
    noResults: '沒有符合的應用程式。',
    loading: '正在載入應用程式…',
    noBots: '還沒有機器人。',
    status: { connected: '已連接', needsSignIn: '需要重新登入', notConnected: '未連接' },
    comingSoon: '尚未提供',
    unknown: '目前無法檢查',
    offByOrg: '已被你的組織關閉',
    action: { cancel: '取消', connect: '連接', reconnect: '重新登入', setup: '設定…', turnOn: '開啟' },
    waiting: '請在瀏覽器中完成登入…',
    usedBy: bots => `使用者：${bots}`,
    usedByNone: '還沒有機器人使用',
    manageBots: '選擇機器人',
    useFor: bot => `允許 ${bot} 使用此應用程式`,
    botNeedsSignIn: '需要登入',
    botSignIn: '登入',
    botUnknown: '無法檢查',
    notice: {
      failed: '無法載入應用程式。',
      retry: '重試',
      signedOut: '請登入 Hermes 以連接應用程式。',
      unavailable: '此帳戶目前不支援應用程式。'
    },
    failure: {
      failed: '無法更新此機器人，請再試一次。',
      needsSetup: '機器人使用前，此應用程式需要先設定。請選擇「設定…」。',
      rulesReadOnly: '此機器人的應用程式規則目前無法變更。'
    },
    openFromBot: '連接應用程式…'
  }
}
