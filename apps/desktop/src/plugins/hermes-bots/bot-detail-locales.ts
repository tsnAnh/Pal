export type BotDetailMessages = {
  runHistoryTab: string
  renameBot: string
  moreActions: string
  share: string
  exportTemplate: string
  jobLabel: string
  noJob: string
  modelLabel: string
  skillsLabel: string
  skillsCount: (count: number) => string
  appsLabel: string
  noApps: string
  historyEmpty: string
  historyFailed: string
  historyNeedsUpdate: string
  historyRoutine: (name: string) => string
  searchTitle: string
  searchPlaceholder: string
  searchHint: string
  searching: string
  noResults: (query: string) => string
  groupBots: string
  groupRooms: string
  groupRoutines: string
  groupMessages: string
  roomMembers: (count: number) => string
  routineOf: (bot: string) => string
  messageIn: (name: string) => string
  messagesUnavailable: string
}

export const BOT_DETAIL_LOCALES: Record<'en' | 'ja' | 'zh' | 'zh-hant', BotDetailMessages> = {
  en: {
    runHistoryTab: 'Run history',
    renameBot: 'Rename',
    moreActions: 'More actions',
    share: 'Share',
    exportTemplate: 'Export template…',
    jobLabel: 'Job',
    noJob: 'No job yet',
    modelLabel: 'Model',
    skillsLabel: 'Skills',
    skillsCount: count => (count === 1 ? '1 skill' : `${count} skills`),
    appsLabel: 'Connected apps',
    noApps: 'None connected',
    historyEmpty: 'No runs yet',
    historyFailed: 'Could not load run history.',
    historyNeedsUpdate: 'Run history needs a newer Hermes.',
    historyRoutine: name => `Routine: ${name}`,
    searchTitle: 'Search',
    searchPlaceholder: 'Search bots, group chats, routines and messages',
    searchHint: 'Type to search across your bots, group chats, routines and messages.',
    searching: 'Searching…',
    noResults: query => `No results for “${query}”`,
    groupBots: 'Bots',
    groupRooms: 'Group chats',
    groupRoutines: 'Routines',
    groupMessages: 'Messages',
    roomMembers: count => (count === 1 ? '1 member' : `${count} members`),
    routineOf: bot => `Routine · ${bot}`,
    messageIn: name => `In ${name}`,
    messagesUnavailable: 'Message search needs a newer Hermes.'
  },
  ja: {
    runHistoryTab: '実行履歴',
    renameBot: '名前を変更',
    moreActions: 'その他の操作',
    share: '共有',
    exportTemplate: 'テンプレートを書き出す…',
    jobLabel: '役割',
    noJob: '役割はまだありません',
    modelLabel: 'モデル',
    skillsLabel: 'スキル',
    skillsCount: count => `${count} 件のスキル`,
    appsLabel: '接続済みアプリ',
    noApps: '接続なし',
    historyEmpty: '実行履歴はまだありません',
    historyFailed: '実行履歴を読み込めませんでした。',
    historyNeedsUpdate: '実行履歴には新しい Hermes が必要です。',
    historyRoutine: name => `ルーティン: ${name}`,
    searchTitle: '検索',
    searchPlaceholder: 'ボット、グループチャット、ルーティン、メッセージを検索',
    searchHint: 'ボット、グループチャット、ルーティン、メッセージを横断して検索します。',
    searching: '検索中…',
    noResults: query => `「${query}」の結果はありません`,
    groupBots: 'ボット',
    groupRooms: 'グループチャット',
    groupRoutines: 'ルーティン',
    groupMessages: 'メッセージ',
    roomMembers: count => `${count} 人のメンバー`,
    routineOf: bot => `ルーティン · ${bot}`,
    messageIn: name => `${name} 内`,
    messagesUnavailable: 'メッセージ検索には新しい Hermes が必要です。'
  },
  zh: {
    runHistoryTab: '运行记录',
    renameBot: '重命名',
    moreActions: '更多操作',
    share: '分享',
    exportTemplate: '导出模板…',
    jobLabel: '职责',
    noJob: '暂无职责',
    modelLabel: '模型',
    skillsLabel: '技能',
    skillsCount: count => `${count} 项技能`,
    appsLabel: '已连接的应用',
    noApps: '未连接',
    historyEmpty: '暂无运行记录',
    historyFailed: '无法加载运行记录。',
    historyNeedsUpdate: '运行记录需要更新版本的 Hermes。',
    historyRoutine: name => `例行任务：${name}`,
    searchTitle: '搜索',
    searchPlaceholder: '搜索机器人、群聊、例行任务和消息',
    searchHint: '输入关键词，在机器人、群聊、例行任务和消息中搜索。',
    searching: '搜索中…',
    noResults: query => `没有找到“${query}”的结果`,
    groupBots: '机器人',
    groupRooms: '群聊',
    groupRoutines: '例行任务',
    groupMessages: '消息',
    roomMembers: count => `${count} 位成员`,
    routineOf: bot => `例行任务 · ${bot}`,
    messageIn: name => `位于 ${name}`,
    messagesUnavailable: '消息搜索需要更新版本的 Hermes。'
  },
  'zh-hant': {
    runHistoryTab: '執行記錄',
    renameBot: '重新命名',
    moreActions: '更多操作',
    share: '分享',
    exportTemplate: '匯出範本…',
    jobLabel: '職責',
    noJob: '尚無職責',
    modelLabel: '模型',
    skillsLabel: '技能',
    skillsCount: count => `${count} 項技能`,
    appsLabel: '已連結的應用程式',
    noApps: '尚未連結',
    historyEmpty: '尚無執行記錄',
    historyFailed: '無法載入執行記錄。',
    historyNeedsUpdate: '執行記錄需要較新版本的 Hermes。',
    historyRoutine: name => `例行任務：${name}`,
    searchTitle: '搜尋',
    searchPlaceholder: '搜尋機器人、群組聊天、例行任務和訊息',
    searchHint: '輸入關鍵字，在機器人、群組聊天、例行任務和訊息中搜尋。',
    searching: '搜尋中…',
    noResults: query => `找不到「${query}」的結果`,
    groupBots: '機器人',
    groupRooms: '群組聊天',
    groupRoutines: '例行任務',
    groupMessages: '訊息',
    roomMembers: count => `${count} 位成員`,
    routineOf: bot => `例行任務 · ${bot}`,
    messageIn: name => `位於 ${name}`,
    messagesUnavailable: '訊息搜尋需要較新版本的 Hermes。'
  }
}
