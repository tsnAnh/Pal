import type { BotsMessages } from './i18n-messages'

export const HANDBACK_LOCALES: Record<'en' | 'ja' | 'zh' | 'zh-hant', BotsMessages['handback']> = {
  en: {
    needsYou: 'Needs you',
    openComputer: 'Open computer',
    done: "I'm done",
    cancel: 'Cancel',
    inControl: "You have control. Choose I'm done when you finish.",
    elsewhere: 'Another viewer is in control right now.',
    resolved: 'Handed back',
    continueMessage: "I'm done. Please continue from where you stopped.",
    cancelMessage: "Cancel that task. Please stop and don't continue it.",
    actionFailed: "Couldn't update this request. Try again.",
    sendFailed: n => `Couldn't message ${n}. Tell them in the chat instead.`
  },
  ja: {
    needsYou: '操作をお願いします',
    openComputer: 'コンピューターを開く',
    done: '完了しました',
    cancel: 'キャンセル',
    inControl: '操作権があります。終わったら「完了しました」を選んでください。',
    elsewhere: '現在、別のビューアが操作中です。',
    resolved: '引き継ぎ済み',
    continueMessage: '完了しました。中断したところから続けてください。',
    cancelMessage: 'そのタスクはキャンセルします。中止して、続けないでください。',
    actionFailed: 'このリクエストを更新できませんでした。もう一度お試しください。',
    sendFailed: n => `${n}にメッセージを送れませんでした。代わりにチャットで伝えてください。`
  },
  zh: {
    needsYou: '需要你操作',
    openComputer: '打开电脑',
    done: '我完成了',
    cancel: '取消',
    inControl: '你已接管。完成后请选择“我完成了”。',
    elsewhere: '另一位查看者正在控制。',
    resolved: '已交还',
    continueMessage: '我完成了，请从中断的地方继续。',
    cancelMessage: '取消这项任务，请停止，不要继续。',
    actionFailed: '无法更新此请求，请重试。',
    sendFailed: n => `无法给${n}发送消息，请改在聊天中告诉它。`
  },
  'zh-hant': {
    needsYou: '需要你操作',
    openComputer: '開啟電腦',
    done: '我完成了',
    cancel: '取消',
    inControl: '你已接管。完成後請選擇「我完成了」。',
    elsewhere: '另一位檢視者正在控制。',
    resolved: '已交還',
    continueMessage: '我完成了，請從中斷的地方繼續。',
    cancelMessage: '取消這項任務，請停止，不要繼續。',
    actionFailed: '無法更新此請求，請重試。',
    sendFailed: n => `無法傳送訊息給${n}，請改在聊天中告訴它。`
  }
}
