import type { BotsMessages } from './i18n-messages'

export const ABOUTYOU_LOCALES: Record<'en' | 'ja' | 'zh' | 'zh-hant', BotsMessages['aboutYou']> = {
  en: {
    menu: 'About you…',
    title: 'About you',
    description: 'Every bot knows these two things about you. Nothing else is shared between bots.',
    nameLabel: 'Your name',
    namePlaceholder: 'e.g. Alex',
    timezoneLabel: 'Time zone',
    timezoneAuto: zone => `Auto-detect (${zone})`,
    loading: 'Loading…',
    loadFailed: 'Couldn’t load your details.',
    saveFailed: 'Couldn’t save your details. Try again.',
    invalidTimezone: 'That time zone isn’t recognized.',
    retry: 'Try again'
  },
  ja: {
    menu: 'あなたについて…',
    title: 'あなたについて',
    description: 'すべてのボットがあなたのこの2点を知っています。それ以外はボット間で共有されません。',
    nameLabel: 'お名前',
    namePlaceholder: '例: 太郎',
    timezoneLabel: 'タイムゾーン',
    timezoneAuto: zone => `自動検出 (${zone})`,
    loading: '読み込み中…',
    loadFailed: '情報を読み込めませんでした。',
    saveFailed: '情報を保存できませんでした。もう一度お試しください。',
    invalidTimezone: 'このタイムゾーンは認識できません。',
    retry: '再試行'
  },
  zh: {
    menu: '关于你…',
    title: '关于你',
    description: '所有机器人都知道你的这两项信息，其他内容不会在机器人之间共享。',
    nameLabel: '你的名字',
    namePlaceholder: '例如：小明',
    timezoneLabel: '时区',
    timezoneAuto: zone => `自动检测（${zone}）`,
    loading: '加载中…',
    loadFailed: '无法加载你的信息。',
    saveFailed: '无法保存你的信息，请重试。',
    invalidTimezone: '无法识别该时区。',
    retry: '重试'
  },
  'zh-hant': {
    menu: '關於你…',
    title: '關於你',
    description: '所有機器人都知道你的這兩項資訊，其他內容不會在機器人之間共享。',
    nameLabel: '你的名字',
    namePlaceholder: '例如：小明',
    timezoneLabel: '時區',
    timezoneAuto: zone => `自動偵測（${zone}）`,
    loading: '載入中…',
    loadFailed: '無法載入你的資訊。',
    saveFailed: '無法儲存你的資訊，請重試。',
    invalidTimezone: '無法辨識該時區。',
    retry: '重試'
  }
}
