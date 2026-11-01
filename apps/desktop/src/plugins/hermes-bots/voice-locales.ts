export type VoiceMessages = {
  call: {
    callLive: string
    ended: (duration: string) => string
    hangUp: string
    hideTranscript: string
    listening: string
    mute: string
    muted: string
    pauseMemo: string
    playMemo: string
    showTranscript: string
    speaking: string
    startCall: string
    thinking: string
    transcriptEmpty: string
    unmute: string
    you: string
  }
  customVoicePlaceholder: string
  hint: string
  language: string
  languageHint: string
  languagePlaceholder: string
  pendingHint: string
  preview: string
  previewFailed: string
  previewing: string
  previewText: string
  saveFailed: string
  title: string
  voice: string
}

export const VOICE_LOCALES = {
  en: {
    call: {
      callLive: 'On a call',
      ended: duration => `Voice chat · ${duration}`,
      hangUp: 'Hang up',
      hideTranscript: 'Hide transcript',
      listening: 'Listening',
      mute: 'Mute',
      muted: 'Muted',
      pauseMemo: 'Pause voice memo',
      playMemo: 'Play voice memo',
      showTranscript: 'Show transcript',
      speaking: 'Speaking',
      startCall: 'Start voice chat',
      thinking: 'Thinking',
      transcriptEmpty: 'Nothing said yet.',
      unmute: 'Unmute',
      you: 'You'
    },
    customVoicePlaceholder: 'Voice name or ID',
    hint: "The voice this bot speaks with in voice chat and when it reads replies aloud. It uses the voice service set up for this bot's profile.",
    language: 'Voice chat language',
    languageHint: 'Language code, for example en or ja. Leave empty to detect it.',
    languagePlaceholder: 'Auto',
    pendingHint: 'Save to hear the new voice.',
    preview: 'Preview',
    previewFailed: "Couldn't play the voice preview.",
    previewing: 'Playing…',
    previewText: 'Hi, this is how I sound. Pick the voice you like best.',
    saveFailed: "Couldn't save the voice.",
    title: 'Voice',
    voice: 'Voice'
  },
  ja: {
    call: {
      callLive: '通話中',
      ended: duration => `音声チャット · ${duration}`,
      hangUp: '終了',
      hideTranscript: '文字起こしを隠す',
      listening: '聞いています',
      mute: 'ミュート',
      muted: 'ミュート中',
      pauseMemo: 'ボイスメモを一時停止',
      playMemo: 'ボイスメモを再生',
      showTranscript: '文字起こしを表示',
      speaking: '話しています',
      startCall: '音声チャットを開始',
      thinking: '考えています',
      transcriptEmpty: 'まだ会話がありません。',
      unmute: 'ミュート解除',
      you: 'あなた'
    },
    customVoicePlaceholder: '音声名またはID',
    hint: '音声チャットや返信の読み上げでこのボットが使う声です。このボットのプロファイルに設定された音声サービスを使います。',
    language: '音声チャットの言語',
    languageHint: 'en や ja などの言語コード。空欄の場合は自動で判定します。',
    languagePlaceholder: '自動',
    pendingHint: '保存すると新しい音声を試聴できます。',
    preview: 'プレビュー',
    previewFailed: '音声のプレビューを再生できませんでした。',
    previewing: '再生中…',
    previewText: 'こんにちは、これが私の声です。お好みの声を選んでください。',
    saveFailed: '音声を保存できませんでした。',
    title: '音声',
    voice: '音声'
  },
  zh: {
    call: {
      callLive: '通话中',
      ended: duration => `语音聊天 · ${duration}`,
      hangUp: '挂断',
      hideTranscript: '隐藏文字记录',
      listening: '正在聆听',
      mute: '静音',
      muted: '已静音',
      pauseMemo: '暂停语音留言',
      playMemo: '播放语音留言',
      showTranscript: '显示文字记录',
      speaking: '正在说话',
      startCall: '开始语音聊天',
      thinking: '正在思考',
      transcriptEmpty: '还没有对话内容。',
      unmute: '取消静音',
      you: '你'
    },
    customVoicePlaceholder: '语音名称或 ID',
    hint: '此机器人在语音聊天和朗读回复时使用的声音，使用该机器人配置文件中设置的语音服务。',
    language: '语音聊天语言',
    languageHint: '语言代码，例如 en 或 ja。留空则自动识别。',
    languagePlaceholder: '自动',
    pendingHint: '保存后即可试听新语音。',
    preview: '试听',
    previewFailed: '无法播放语音试听。',
    previewing: '播放中…',
    previewText: '你好，这就是我的声音。选一个你最喜欢的吧。',
    saveFailed: '无法保存语音。',
    title: '语音',
    voice: '语音'
  },
  'zh-hant': {
    call: {
      callLive: '通話中',
      ended: duration => `語音聊天 · ${duration}`,
      hangUp: '掛斷',
      hideTranscript: '隱藏文字記錄',
      listening: '正在聆聽',
      mute: '靜音',
      muted: '已靜音',
      pauseMemo: '暫停語音留言',
      playMemo: '播放語音留言',
      showTranscript: '顯示文字記錄',
      speaking: '正在說話',
      startCall: '開始語音聊天',
      thinking: '正在思考',
      transcriptEmpty: '還沒有對話內容。',
      unmute: '取消靜音',
      you: '你'
    },
    customVoicePlaceholder: '語音名稱或 ID',
    hint: '此機器人在語音聊天與朗讀回覆時使用的聲音，使用該機器人設定檔中的語音服務。',
    language: '語音聊天語言',
    languageHint: '語言代碼，例如 en 或 ja。留空則自動辨識。',
    languagePlaceholder: '自動',
    pendingHint: '儲存後即可試聽新語音。',
    preview: '試聽',
    previewFailed: '無法播放語音試聽。',
    previewing: '播放中…',
    previewText: '你好，這就是我的聲音。選一個你最喜歡的吧。',
    saveFailed: '無法儲存語音。',
    title: '語音',
    voice: '語音'
  }
} satisfies Record<'en' | 'ja' | 'zh' | 'zh-hant', VoiceMessages>
