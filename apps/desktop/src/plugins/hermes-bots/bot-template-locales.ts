export type BotTemplateMessages = {
  share: string
  exportAction: string
  exportDone: (name: string) => string
  exportFailed: string
  exportNeedsUpdate: string
  importAction: string
  importTitle: string
  importDescription: string
  nameLabel: string
  abilitiesHeading: string
  useDefaultTools: string
  useTools: (names: string) => string
  useSkills: (count: number) => string
  skillScripts: string
  serverLocal: (name: string, command: string) => string
  serverRemote: (name: string, url: string, transport: string) => string
  serversOff: string
  serverNeeds: (keys: string) => string
  routines: (count: number) => string
  routinesPaused: string
  skippedRoutines: (names: string) => string
  useModel: (name: string) => string
  instructionsHeading: string
  noInstructions: string
  privacyNote: string
  confirm: string
  importing: string
  imported: (name: string) => string
  needsModel: string
  readFailed: string
  failureInvalid: string
  failureTooLarge: string
  failureNewer: string
  failureChanged: string
  failureNameTaken: string
  failureUnsupported: string
  failureGeneric: string
  reviewLabel: string
}

export const BOT_TEMPLATE_LOCALES: Record<'en' | 'ja' | 'zh' | 'zh-hant', BotTemplateMessages> = {
  en: {
    share: 'Share',
    exportAction: 'Export template…',
    exportDone: name => `Exported “${name}” as a template`,
    exportFailed: 'Could not export this bot',
    exportNeedsUpdate: 'Update Hermes on this bot’s machine to export templates.',
    importAction: 'Import bot…',
    importTitle: 'Import bot',
    importDescription: 'Review what this template carries before the bot is created.',
    nameLabel: 'Name',
    abilitiesHeading: 'This bot will be able to:',
    useDefaultTools: 'Use the default tools',
    useTools: names => `Use these tools: ${names}`,
    useSkills: count => (count === 1 ? 'Use 1 skill' : `Use ${count} skills`),
    skillScripts: 'Some skills include scripts it can run',
    serverLocal: (name, command) => `Run ${name} on this computer (local program): ${command}`,
    serverRemote: (name, url, transport) => `Connect to ${name} at ${url} (${transport})`,
    serversOff: 'Connections start turned off. Turn each one on yourself once you trust it.',
    serverNeeds: keys => `Needs your own credentials: ${keys}`,
    routines: count => (count === 1 ? 'Run 1 routine on a schedule' : `Run ${count} routines on a schedule`),
    routinesPaused: 'Routines start paused until you resume them',
    skippedRoutines: names => `Left out because they could not be scheduled: ${names}`,
    useModel: name => `Prefer the model ${name}`,
    instructionsHeading: 'Instructions it will follow',
    noInstructions: 'This template has no custom instructions.',
    privacyNote: 'No history, memories or keys come with a template. The bot uses your own accounts.',
    confirm: 'Import bot',
    importing: 'Importing…',
    imported: name => `Imported ${name}`,
    needsModel: 'Choose a model for this bot before it can reply.',
    readFailed: 'Could not read that file.',
    failureInvalid: 'This is not a valid Hermes bot template.',
    failureTooLarge: 'This template is too large to import.',
    failureNewer: 'This template needs a newer version of Hermes.',
    failureChanged: 'The template changed after you reviewed it. Open it again.',
    failureNameTaken: 'That name is already taken. Choose another.',
    failureUnsupported: 'Update Hermes on this machine to import bots.',
    failureGeneric: 'Could not import this bot.',
    reviewLabel: 'Template contents'
  },
  ja: {
    share: '共有',
    exportAction: 'テンプレートを書き出す…',
    exportDone: name => `「${name}」をテンプレートとして書き出しました`,
    exportFailed: 'このボットを書き出せませんでした',
    exportNeedsUpdate: 'テンプレートを書き出すには、このボットのマシンで Hermes を更新してください。',
    importAction: 'ボットを読み込む…',
    importTitle: 'ボットを読み込む',
    importDescription: 'ボットを作成する前に、テンプレートの内容を確認してください。',
    nameLabel: '名前',
    abilitiesHeading: 'このボットができること:',
    useDefaultTools: '標準のツールを使う',
    useTools: names => `次のツールを使う: ${names}`,
    useSkills: count => `${count} 個のスキルを使う`,
    skillScripts: '実行できるスクリプトを含むスキルがあります',
    serverLocal: (name, command) => `このコンピューターで ${name} を実行する (ローカルプログラム): ${command}`,
    serverRemote: (name, url, transport) => `${url} の ${name} に接続する (${transport})`,
    serversOff: '接続はオフの状態で始まります。信頼できると判断したら、ご自身でオンにしてください。',
    serverNeeds: keys => `ご自身の認証情報が必要です: ${keys}`,
    routines: count => `${count} 件のルーティンをスケジュールどおりに実行する`,
    routinesPaused: 'ルーティンは再開するまで一時停止の状態で始まります',
    skippedRoutines: names => `スケジュールできないため除外しました: ${names}`,
    useModel: name => `モデル ${name} を優先する`,
    instructionsHeading: '従う指示',
    noInstructions: 'このテンプレートにはカスタムの指示がありません。',
    privacyNote: '履歴、記憶、キーはテンプレートに含まれません。ボットはご自身のアカウントを使います。',
    confirm: 'ボットを読み込む',
    importing: '読み込み中…',
    imported: name => `${name} を読み込みました`,
    needsModel: '返信するには、このボットのモデルを選択してください。',
    readFailed: 'そのファイルを読み込めませんでした。',
    failureInvalid: 'Hermes のボットテンプレートではありません。',
    failureTooLarge: 'このテンプレートは大きすぎて読み込めません。',
    failureNewer: 'このテンプレートには新しいバージョンの Hermes が必要です。',
    failureChanged: '確認後にテンプレートが変更されました。もう一度開いてください。',
    failureNameTaken: 'その名前はすでに使われています。別の名前を選んでください。',
    failureUnsupported: 'ボットを読み込むには、このマシンで Hermes を更新してください。',
    failureGeneric: 'このボットを読み込めませんでした。',
    reviewLabel: 'テンプレートの内容'
  },
  zh: {
    share: '分享',
    exportAction: '导出模板…',
    exportDone: name => `已将“${name}”导出为模板`,
    exportFailed: '无法导出此机器人',
    exportNeedsUpdate: '请在此机器人所在的机器上更新 Hermes 后再导出模板。',
    importAction: '导入机器人…',
    importTitle: '导入机器人',
    importDescription: '创建机器人之前，请先查看此模板包含的内容。',
    nameLabel: '名称',
    abilitiesHeading: '此机器人将能够：',
    useDefaultTools: '使用默认工具',
    useTools: names => `使用这些工具：${names}`,
    useSkills: count => `使用 ${count} 个技能`,
    skillScripts: '部分技能包含可运行的脚本',
    serverLocal: (name, command) => `在此电脑上运行 ${name}（本地程序）：${command}`,
    serverRemote: (name, url, transport) => `连接到 ${url} 上的 ${name}（${transport}）`,
    serversOff: '连接默认处于关闭状态。确认可信后，请自行逐个开启。',
    serverNeeds: keys => `需要你自己的凭据：${keys}`,
    routines: count => `按计划运行 ${count} 个例行任务`,
    routinesPaused: '例行任务在你恢复之前保持暂停',
    skippedRoutines: names => `因无法安排计划而未包含：${names}`,
    useModel: name => `优先使用模型 ${name}`,
    instructionsHeading: '它将遵循的指令',
    noInstructions: '此模板没有自定义指令。',
    privacyNote: '模板不包含历史记录、记忆或密钥。机器人使用你自己的账户。',
    confirm: '导入机器人',
    importing: '正在导入…',
    imported: name => `已导入 ${name}`,
    needsModel: '请先为此机器人选择模型，它才能回复。',
    readFailed: '无法读取该文件。',
    failureInvalid: '这不是有效的 Hermes 机器人模板。',
    failureTooLarge: '此模板太大，无法导入。',
    failureNewer: '此模板需要更新版本的 Hermes。',
    failureChanged: '模板在你查看之后发生了变化，请重新打开。',
    failureNameTaken: '该名称已被占用，请换一个。',
    failureUnsupported: '请在此机器上更新 Hermes 后再导入机器人。',
    failureGeneric: '无法导入此机器人。',
    reviewLabel: '模板内容'
  },
  'zh-hant': {
    share: '分享',
    exportAction: '匯出範本…',
    exportDone: name => `已將「${name}」匯出為範本`,
    exportFailed: '無法匯出此機器人',
    exportNeedsUpdate: '請在此機器人所在的機器上更新 Hermes 後再匯出範本。',
    importAction: '匯入機器人…',
    importTitle: '匯入機器人',
    importDescription: '建立機器人之前，請先檢視此範本包含的內容。',
    nameLabel: '名稱',
    abilitiesHeading: '此機器人將能夠：',
    useDefaultTools: '使用預設工具',
    useTools: names => `使用這些工具：${names}`,
    useSkills: count => `使用 ${count} 個技能`,
    skillScripts: '部分技能包含可執行的指令碼',
    serverLocal: (name, command) => `在此電腦上執行 ${name}（本機程式）：${command}`,
    serverRemote: (name, url, transport) => `連線到 ${url} 上的 ${name}（${transport}）`,
    serversOff: '連線預設為關閉狀態。確認可信後，請自行逐一開啟。',
    serverNeeds: keys => `需要你自己的憑證：${keys}`,
    routines: count => `依排程執行 ${count} 個例行任務`,
    routinesPaused: '例行任務在你恢復之前保持暫停',
    skippedRoutines: names => `因無法排程而未包含：${names}`,
    useModel: name => `優先使用模型 ${name}`,
    instructionsHeading: '它將遵循的指示',
    noInstructions: '此範本沒有自訂指示。',
    privacyNote: '範本不包含歷史記錄、記憶或金鑰。機器人使用你自己的帳號。',
    confirm: '匯入機器人',
    importing: '正在匯入…',
    imported: name => `已匯入 ${name}`,
    needsModel: '請先為此機器人選擇模型，它才能回覆。',
    readFailed: '無法讀取該檔案。',
    failureInvalid: '這不是有效的 Hermes 機器人範本。',
    failureTooLarge: '此範本太大，無法匯入。',
    failureNewer: '此範本需要更新版本的 Hermes。',
    failureChanged: '範本在你檢視之後發生了變化，請重新開啟。',
    failureNameTaken: '該名稱已被使用，請換一個。',
    failureUnsupported: '請在此機器上更新 Hermes 後再匯入機器人。',
    failureGeneric: '無法匯入此機器人。',
    reviewLabel: '範本內容'
  }
}
