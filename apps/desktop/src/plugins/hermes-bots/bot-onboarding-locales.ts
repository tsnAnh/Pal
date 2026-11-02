export type BotOnboardingMessages = {
  newBotName: string
  greeting: (bot: string) => string
  greetingNamed: (user: string, bot: string) => string
  question: string
  options: { assistant: string; research: string; metrics: string; writing: string }
  firstMessage: (purpose: string) => string
  saveFailed: string
  rejected: string
  identity: {
    undo: string
    undoing: string
    undone: string
    undoStale: string
    undoFailed: string
  }
}

export const BOT_ONBOARDING_LOCALES: Record<'en' | 'ja' | 'zh' | 'zh-hant', BotOnboardingMessages> = {
  en: {
    newBotName: 'New bot',
    greeting: bot => `Hi! I'm ${bot}, just created and ready to work.`,
    greetingNamed: (user, bot) => `Hi ${user}! I'm ${bot}, just created and ready to work.`,
    question: 'What should I focus on?',
    options: {
      assistant: 'Daily assistant',
      research: 'Research and summaries',
      metrics: 'Track apps and report metrics',
      writing: 'Writing and social content'
    },
    firstMessage: purpose => `I want you to focus on: ${purpose}`,
    saveFailed: 'Couldn’t save that. Try again.',
    rejected: 'I can’t use that as my focus. Try describing the job another way.',
    identity: {
      undo: 'Undo',
      undoing: 'Undoing…',
      undone: 'Undone',
      undoStale: 'A newer change exists, so this one can’t be undone anymore.',
      undoFailed: 'Couldn’t undo that. Try again.'
    }
  },
  ja: {
    newBotName: '新しいボット',
    greeting: bot => `こんにちは！${bot}です。作成されたばかりですが、すぐに働けます。`,
    greetingNamed: (user, bot) => `こんにちは、${user}さん！${bot}です。作成されたばかりですが、すぐに働けます。`,
    question: '何を中心に担当しましょうか？',
    options: {
      assistant: '毎日のアシスタント',
      research: 'リサーチと要約',
      metrics: 'アプリの追跡と指標のレポート',
      writing: '文章作成とソーシャル向けコンテンツ'
    },
    firstMessage: purpose => `次を中心に担当してください：${purpose}`,
    saveFailed: '保存できませんでした。もう一度お試しください。',
    rejected: 'それは担当内容として使えません。別の言い方で仕事を説明してください。',
    identity: {
      undo: '元に戻す',
      undoing: '元に戻しています…',
      undone: '元に戻しました',
      undoStale: 'より新しい変更があるため、この変更はもう元に戻せません。',
      undoFailed: '元に戻せませんでした。もう一度お試しください。'
    }
  },
  zh: {
    newBotName: '新机器人',
    greeting: bot => `你好！我是${bot}，刚刚创建，随时可以开始工作。`,
    greetingNamed: (user, bot) => `你好，${user}！我是${bot}，刚刚创建，随时可以开始工作。`,
    question: '我应该专注于什么？',
    options: {
      assistant: '日常助手',
      research: '研究与摘要',
      metrics: '跟踪应用并汇报指标',
      writing: '写作与社交内容'
    },
    firstMessage: purpose => `我希望你专注于：${purpose}`,
    saveFailed: '无法保存，请重试。',
    rejected: '我无法将其作为工作重点。请换一种方式描述这项工作。',
    identity: {
      undo: '撤销',
      undoing: '正在撤销…',
      undone: '已撤销',
      undoStale: '已有更新的更改，因此无法再撤销这一项。',
      undoFailed: '无法撤销，请重试。'
    }
  },
  'zh-hant': {
    newBotName: '新機器人',
    greeting: bot => `你好！我是${bot}，剛剛建立，隨時可以開始工作。`,
    greetingNamed: (user, bot) => `你好，${user}！我是${bot}，剛剛建立，隨時可以開始工作。`,
    question: '我應該專注於什麼？',
    options: {
      assistant: '日常助理',
      research: '研究與摘要',
      metrics: '追蹤應用程式並回報指標',
      writing: '寫作與社群內容'
    },
    firstMessage: purpose => `我希望你專注於：${purpose}`,
    saveFailed: '無法儲存，請再試一次。',
    rejected: '我無法將其作為工作重點。請換一種方式描述這項工作。',
    identity: {
      undo: '復原',
      undoing: '正在復原…',
      undone: '已復原',
      undoStale: '已有更新的變更，因此無法再復原這一項。',
      undoFailed: '無法復原，請再試一次。'
    }
  }
}
