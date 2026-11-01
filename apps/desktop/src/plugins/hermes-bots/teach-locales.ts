import type { PluginLocaleBundles } from '@hermes/plugin-sdk'

export type TeachMessages = {
  start: string
  startHint: (name: string) => string
  leaseReason: string
  recording: string
  timeLeft: (clock: string) => string
  waitingForBrowser: string
  stop: string
  stopHint: string
  endedLimit: string
  endedReturned: string
  createSkill: string
  discardRecording: string
  nothingRecorded: string
  startFailed: string
  startRefused: Record<'draft_pending' | 'not_in_control' | 'recording_in_progress' | 'unavailable', string>
  stopFailed: string
  openChatFirst: (name: string) => string
  sendFailed: (name: string) => string
  draft: {
    writing: (name: string) => string
    writingBody: string
    ready: (name: string) => string
    review: string
    askAgain: string
    asked: (name: string) => string
    title: string
    description: (name: string) => string
    privacy: string
    truncated: string
    extraFiles: (files: string) => string
    loading: string
    loadFailed: string
    approve: string
    edit: string
    cancelEdit: string
    save: string
    discard: string
    discardTitle: string
    discardBody: string
    approved: (skill: string) => string
    discarded: string
    approveFailed: string
    saveFailed: string
    discardFailed: string
    notReady: string
    changed: string
  }
}

const en: TeachMessages = {
  start: 'Teach a skill',
  startHint: name => `Show ${name} a browser workflow once and it learns it. Takes control of this screen.`,
  leaseReason: 'Teaching a skill',
  recording: 'Recording',
  timeLeft: clock => `${clock} left`,
  waitingForBrowser: 'Open the Browser on this screen to begin',
  stop: 'Stop',
  stopHint: 'Only browser steps are recorded: no video, no sound, never what you type into password or code fields.',
  endedLimit: 'Recording stopped at the 10 minute limit',
  endedReturned: 'Recording stopped when control went back',
  createSkill: 'Create skill',
  discardRecording: 'Discard',
  nothingRecorded: 'Nothing was recorded, so no skill was created.',
  startFailed: 'Could not start recording.',
  startRefused: {
    draft_pending: 'Review or discard the previous draft first.',
    not_in_control: 'Take control of the screen first.',
    recording_in_progress: 'A recording is already in progress.',
    unavailable: 'Teaching is not available on this screen.'
  },
  stopFailed: 'Could not finish the recording.',
  openChatFirst: name => `Open ${name}'s chat once, then try again.`,
  sendFailed: name => `Could not send the recording to ${name}.`,
  draft: {
    writing: name => `${name} is writing the skill…`,
    writingBody: 'It will appear here for your review. Nothing runs until you approve it.',
    ready: name => `${name} wrote a skill for you to review`,
    review: 'Review',
    askAgain: 'Ask again',
    asked: name => `Asked ${name} to write the skill.`,
    title: 'Review the skill',
    description: name => `${name} learned this from your demonstration. It stays off until you approve it.`,
    privacy: 'Passwords, codes and card numbers you typed were never recorded.',
    truncated: 'The recording hit its size limit, so the end of the workflow may be missing.',
    extraFiles: files => `The draft also contains other files (${files}). Only the skill text can be reviewed here, so it cannot be approved. Discard it and ask again.`,
    loading: 'Loading the draft',
    loadFailed: 'Could not load the draft.',
    approve: 'Approve',
    edit: 'Edit',
    cancelEdit: 'Cancel',
    save: 'Save changes',
    discard: 'Discard',
    discardTitle: 'Discard this draft?',
    discardBody: 'The draft skill and the recording are deleted. This cannot be undone.',
    approved: skill => `Skill approved: ${skill}`,
    discarded: 'Draft discarded.',
    approveFailed: 'Could not approve the skill.',
    saveFailed: 'Could not save your changes.',
    discardFailed: 'Could not discard the draft.',
    notReady: 'The skill has not been written yet.',
    changed: 'The draft changed while you were reviewing it. Review the new version before approving.'
  }
}

const ja: TeachMessages = {
  start: 'スキルを教える',
  startHint: name => `ブラウザの操作を一度見せると、${name}が覚えます。この画面の操作権を取得します。`,
  leaseReason: 'スキルを教えています',
  recording: '記録中',
  timeLeft: clock => `残り ${clock}`,
  waitingForBrowser: 'この画面でブラウザを開くと記録が始まります',
  stop: '停止',
  stopHint: '記録されるのはブラウザの操作のみです。動画も音声も録らず、パスワードやコード欄への入力は記録しません。',
  endedLimit: '10分の上限で記録を停止しました',
  endedReturned: '操作権が戻ったため記録を停止しました',
  createSkill: 'スキルを作成',
  discardRecording: '破棄',
  nothingRecorded: '何も記録されなかったため、スキルは作成されませんでした。',
  startFailed: '記録を開始できませんでした。',
  startRefused: {
    draft_pending: '先に前回の下書きを確認するか破棄してください。',
    not_in_control: '先にこの画面の操作権を取得してください。',
    recording_in_progress: 'すでに記録中です。',
    unavailable: 'この画面ではスキルを教えられません。'
  },
  stopFailed: '記録を完了できませんでした。',
  openChatFirst: name => `${name}のチャットを一度開いてから、もう一度お試しください。`,
  sendFailed: name => `記録を${name}に送信できませんでした。`,
  draft: {
    writing: name => `${name}がスキルを書いています…`,
    writingBody: '完成するとここに表示されます。承認するまで何も実行されません。',
    ready: name => `${name}がスキルを書きました。確認してください`,
    review: '確認',
    askAgain: 'もう一度依頼',
    asked: name => `${name}にスキルの作成を依頼しました。`,
    title: 'スキルを確認',
    description: name => `${name}があなたの操作から学んだ内容です。承認するまで無効のままです。`,
    privacy: '入力したパスワード、コード、カード番号は記録されていません。',
    truncated: '記録がサイズ上限に達したため、手順の最後が欠けている可能性があります。',
    extraFiles: files => `この下書きにはほかのファイル(${files})も含まれています。ここで確認できるのはスキルの本文だけなので、承認できません。破棄してもう一度依頼してください。`,
    loading: '下書きを読み込み中',
    loadFailed: '下書きを読み込めませんでした。',
    approve: '承認',
    edit: '編集',
    cancelEdit: 'キャンセル',
    save: '変更を保存',
    discard: '破棄',
    discardTitle: 'この下書きを破棄しますか?',
    discardBody: '下書きのスキルと記録が削除されます。元に戻せません。',
    approved: skill => `スキルを承認しました: ${skill}`,
    discarded: '下書きを破棄しました。',
    approveFailed: 'スキルを承認できませんでした。',
    saveFailed: '変更を保存できませんでした。',
    discardFailed: '下書きを破棄できませんでした。',
    notReady: 'スキルはまだ書き上がっていません。',
    changed: '確認中に下書きが変更されました。承認する前に新しい内容を確認してください。'
  }
}

const zh: TeachMessages = {
  start: '教它一项技能',
  startHint: name => `向${name}演示一次浏览器操作，它就会学会。这会接管此屏幕。`,
  leaseReason: '正在教授技能',
  recording: '录制中',
  timeLeft: clock => `剩余 ${clock}`,
  waitingForBrowser: '请在此屏幕上打开浏览器以开始',
  stop: '停止',
  stopHint: '只记录浏览器操作：不录视频、不录声音，也绝不记录你在密码或验证码栏中输入的内容。',
  endedLimit: '已达到 10 分钟上限，录制已停止',
  endedReturned: '控制权已交还，录制已停止',
  createSkill: '创建技能',
  discardRecording: '放弃',
  nothingRecorded: '没有录到任何操作，因此未创建技能。',
  startFailed: '无法开始录制。',
  startRefused: {
    draft_pending: '请先查看或放弃上一份草稿。',
    not_in_control: '请先接管此屏幕。',
    recording_in_progress: '已有录制正在进行。',
    unavailable: '此屏幕无法教授技能。'
  },
  stopFailed: '无法完成录制。',
  openChatFirst: name => `请先打开一次${name}的聊天，然后重试。`,
  sendFailed: name => `无法将录制内容发送给${name}。`,
  draft: {
    writing: name => `${name}正在编写技能…`,
    writingBody: '完成后会显示在这里供你审阅。批准之前不会运行任何内容。',
    ready: name => `${name}写好了一项技能，请审阅`,
    review: '审阅',
    askAgain: '再次请求',
    asked: name => `已请${name}编写技能。`,
    title: '审阅技能',
    description: name => `这是${name}从你的演示中学到的内容。批准之前它保持关闭。`,
    privacy: '你输入的密码、验证码和银行卡号从未被记录。',
    truncated: '录制达到大小上限，流程末尾可能缺失。',
    extraFiles: files => `草稿还包含其他文件（${files}）。这里只能审阅技能正文，因此无法批准。请放弃后重新请求。`,
    loading: '正在加载草稿',
    loadFailed: '无法加载草稿。',
    approve: '批准',
    edit: '编辑',
    cancelEdit: '取消',
    save: '保存更改',
    discard: '放弃',
    discardTitle: '放弃这份草稿？',
    discardBody: '草稿技能和录制内容都会被删除，无法恢复。',
    approved: skill => `技能已批准：${skill}`,
    discarded: '草稿已放弃。',
    approveFailed: '无法批准该技能。',
    saveFailed: '无法保存你的更改。',
    discardFailed: '无法放弃草稿。',
    notReady: '技能尚未写好。',
    changed: '审阅期间草稿已更改。请先审阅新版本再批准。'
  }
}

const zhHant: TeachMessages = {
  start: '教它一項技能',
  startHint: name => `向${name}示範一次瀏覽器操作，它就會學會。這會接管此畫面。`,
  leaseReason: '正在教授技能',
  recording: '錄製中',
  timeLeft: clock => `剩餘 ${clock}`,
  waitingForBrowser: '請在此畫面上開啟瀏覽器以開始',
  stop: '停止',
  stopHint: '只記錄瀏覽器操作：不錄影片、不錄聲音，也絕不記錄你在密碼或驗證碼欄位中輸入的內容。',
  endedLimit: '已達 10 分鐘上限，錄製已停止',
  endedReturned: '控制權已交還，錄製已停止',
  createSkill: '建立技能',
  discardRecording: '捨棄',
  nothingRecorded: '沒有錄到任何操作，因此未建立技能。',
  startFailed: '無法開始錄製。',
  startRefused: {
    draft_pending: '請先檢視或捨棄上一份草稿。',
    not_in_control: '請先接管此畫面。',
    recording_in_progress: '已有錄製正在進行。',
    unavailable: '此畫面無法教授技能。'
  },
  stopFailed: '無法完成錄製。',
  openChatFirst: name => `請先開啟一次${name}的聊天，然後重試。`,
  sendFailed: name => `無法將錄製內容傳送給${name}。`,
  draft: {
    writing: name => `${name}正在撰寫技能…`,
    writingBody: '完成後會顯示在這裡供你審閱。核准之前不會執行任何內容。',
    ready: name => `${name}寫好了一項技能，請審閱`,
    review: '審閱',
    askAgain: '再次請求',
    asked: name => `已請${name}撰寫技能。`,
    title: '審閱技能',
    description: name => `這是${name}從你的示範中學到的內容。核准之前它保持關閉。`,
    privacy: '你輸入的密碼、驗證碼和信用卡號從未被記錄。',
    truncated: '錄製達到大小上限，流程末尾可能缺失。',
    extraFiles: files => `草稿還包含其他檔案（${files}）。這裡只能審閱技能正文，因此無法核准。請捨棄後重新請求。`,
    loading: '正在載入草稿',
    loadFailed: '無法載入草稿。',
    approve: '核准',
    edit: '編輯',
    cancelEdit: '取消',
    save: '儲存變更',
    discard: '捨棄',
    discardTitle: '捨棄這份草稿？',
    discardBody: '草稿技能和錄製內容都會被刪除，無法復原。',
    approved: skill => `技能已核准：${skill}`,
    discarded: '草稿已捨棄。',
    approveFailed: '無法核准該技能。',
    saveFailed: '無法儲存你的變更。',
    discardFailed: '無法捨棄草稿。',
    notReady: '技能尚未寫好。',
    changed: '審閱期間草稿已變更。請先審閱新版本再核准。'
  }
}

export const TEACH_LOCALES = { en, ja, zh, 'zh-hant': zhHant } as const

/** Registered beside `BOTS_LOCALES`: `ctx.i18n.register` merges per locale, so these strings join the plugin's own namespace. */
export const TEACH_BUNDLES: PluginLocaleBundles = {
  en: { teach: en },
  ja: { teach: ja },
  zh: { teach: zh },
  'zh-hant': { teach: zhHant }
}
