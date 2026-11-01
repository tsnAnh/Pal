export type RoutinesMessages = {
  active: { label: string; description: string }
  test: {
    action: string
    running: string
    note: string
    queued: string
    started: string
    stoppedWaiting: string
    succeeded: string
    failedWith: (reason: string) => string
    cancelled: string
    refusedWith: (reason: string) => string
    paused: string
    alreadyRunning: string
    notFound: string
    unavailable: string
    needsUpdate: string
  }
  history: {
    title: string
    empty: string
    loadFailed: string
    running: string
    succeeded: string
    failed: string
    cancelled: string
    seconds: (count: number) => string
    minutes: (count: number) => string
    viewOutput: string
    hideOutput: string
    outputFailed: string
    noOutput: string
    truncated: string
    needsUpdate: string
  }
  schedule: {
    checking: string
    runs: (label: string) => string
    nextRun: (when: string) => string
    tooFrequent: string
    unrecognized: string
    invalid: string
    placeholder: string
  }
  triggers: {
    title: string
    add: string
    webhook: string
    webhookSummary: string
    needsUpdate: string
    blockedWebhook: string
    blockedGateway: string
    loadFailed: string
    createdTitle: string
    urlLabel: string
    keyLabel: string
    copyUrl: string
    copyKey: string
    onceNote: string
    howToSend: string
    payloadNote: string
    done: string
    regenerate: string
    regenerateTitle: string
    regenerateBody: string
    regenerateConfirm: string
    regenerating: string
    remove: string
    removeTitle: string
    removeBody: string
    removeConfirm: string
    removing: string
    conflict: string
    failed: string
  }
}

export const ROUTINES_LOCALES: Record<'en' | 'ja' | 'zh' | 'zh-hant', RoutinesMessages> = {
  en: {
    active: { label: 'Active', description: 'Paused routines do not run on their schedule or from triggers.' },
    test: {
      action: 'Test now',
      running: 'Running…',
      note: 'Runs this routine for real, right now. It can send messages and make changes, just like a scheduled run.',
      queued: 'Test queued. This bot’s gateway will run it shortly.',
      started: 'The test started.',
      stoppedWaiting:
        'The test is taking a while, so Hermes is no longer waiting for it. Check Recent runs for the result.',
      succeeded: 'The test finished.',
      failedWith: reason => `The test failed: ${reason}`,
      cancelled: 'The test was stopped.',
      refusedWith: reason => `Could not start the test: ${reason}`,
      paused: 'Turn the routine on before testing it.',
      alreadyRunning: 'This routine is already running.',
      notFound: 'This routine no longer exists.',
      unavailable: 'The run could not start.',
      needsUpdate: 'Testing from here needs a newer Hermes gateway. Update it and restart.'
    },
    history: {
      title: 'Recent runs',
      empty: 'No runs yet.',
      loadFailed: 'Could not load the run history.',
      running: 'Running',
      succeeded: 'Succeeded',
      failed: 'Failed',
      cancelled: 'Stopped',
      seconds: count => `${count}s`,
      minutes: count => `${count}m`,
      viewOutput: 'View output',
      hideOutput: 'Hide output',
      outputFailed: 'Could not load this output.',
      noOutput: 'This run did not save any output.',
      truncated: 'Output shortened.',
      needsUpdate: 'Run history needs a newer Hermes gateway. Update it and restart.'
    },
    schedule: {
      checking: 'Checking…',
      runs: label => `Runs ${label}`,
      nextRun: when => `Next run ${when}`,
      tooFrequent: 'Routines can run at most once every 5 minutes.',
      unrecognized: 'That schedule was not understood. Try “every weekday at 9am” or “every 2 hours”.',
      invalid: 'That schedule is not valid.',
      placeholder: 'every weekday at 9am · every 2 hours · 0 9 * * 1-5'
    },
    triggers: {
      title: 'Triggers',
      add: 'Add trigger',
      webhook: 'Webhook',
      webhookSummary: 'Runs this routine whenever something sends a request to its address.',
      needsUpdate: 'Triggers need a newer Hermes gateway. Update it and restart.',
      blockedWebhook: 'Turn on the Webhook platform for this bot in its messaging settings to add a trigger.',
      blockedGateway: 'Start this bot’s gateway to add a trigger.',
      loadFailed: 'Could not load the trigger.',
      createdTitle: 'Webhook trigger ready',
      urlLabel: 'Address',
      keyLabel: 'Key',
      copyUrl: 'Copy address',
      copyKey: 'Copy key',
      onceNote: 'Copy the key now. It is shown only once; regenerate it if you lose it.',
      howToSend:
        'Send a POST request to the address with the key in an X-Gitlab-Token header, or sign the body with the key (HMAC-SHA256).',
      payloadNote: 'The request body reaches the routine as data to read, never as instructions.',
      done: 'Done',
      regenerate: 'Regenerate key',
      regenerateTitle: 'Regenerate the key?',
      regenerateBody: 'Anything using the current key stops working until you give it the new one.',
      regenerateConfirm: 'Regenerate',
      regenerating: 'Regenerating…',
      remove: 'Remove trigger',
      removeTitle: 'Remove this trigger?',
      removeBody: 'Its address stops working immediately.',
      removeConfirm: 'Remove',
      removing: 'Removing…',
      conflict: 'Another webhook already uses this routine’s address.',
      failed: 'Could not update the trigger.'
    }
  },
  ja: {
    active: { label: '有効', description: '一時停止中のルーティンは、スケジュールやトリガーでは実行されません。' },
    test: {
      action: '今すぐテスト',
      running: '実行中…',
      note: 'このルーティンを今すぐ実際に実行します。スケジュール実行と同じく、メッセージの送信や変更が行われることがあります。',
      queued: 'テストを待機中です。このボットのゲートウェイがまもなく実行します。',
      started: 'テストを開始しました。',
      stoppedWaiting:
        'テストに時間がかかっているため、結果の待機を終了しました。結果は「最近の実行」で確認してください。',
      succeeded: 'テストが完了しました。',
      failedWith: reason => `テストに失敗しました：${reason}`,
      cancelled: 'テストは停止されました。',
      refusedWith: reason => `テストを開始できませんでした：${reason}`,
      paused: 'テストする前にルーティンを有効にしてください。',
      alreadyRunning: 'このルーティンはすでに実行中です。',
      notFound: 'このルーティンは存在しなくなりました。',
      unavailable: '実行を開始できませんでした。',
      needsUpdate: 'ここからテストするには新しい Hermes ゲートウェイが必要です。更新して再起動してください。'
    },
    history: {
      title: '最近の実行',
      empty: 'まだ実行されていません。',
      loadFailed: '実行履歴を読み込めませんでした。',
      running: '実行中',
      succeeded: '成功',
      failed: '失敗',
      cancelled: '停止',
      seconds: count => `${count}秒`,
      minutes: count => `${count}分`,
      viewOutput: '出力を表示',
      hideOutput: '出力を隠す',
      outputFailed: 'この出力を読み込めませんでした。',
      noOutput: 'この実行では出力が保存されませんでした。',
      truncated: '出力は省略されています。',
      needsUpdate: '実行履歴には新しい Hermes ゲートウェイが必要です。更新して再起動してください。'
    },
    schedule: {
      checking: '確認中…',
      runs: label => `実行：${label}`,
      nextRun: when => `次回の実行 ${when}`,
      tooFrequent: 'ルーティンは5分に1回までしか実行できません。',
      unrecognized:
        'そのスケジュールを理解できませんでした。「every weekday at 9am」や「every 2 hours」のように入力してください。',
      invalid: 'そのスケジュールは無効です。',
      placeholder: 'every weekday at 9am · every 2 hours · 0 9 * * 1-5'
    },
    triggers: {
      title: 'トリガー',
      add: 'トリガーを追加',
      webhook: 'Webhook',
      webhookSummary: 'このルーティンのアドレスにリクエストが届くたびに実行します。',
      needsUpdate: 'トリガーには新しい Hermes ゲートウェイが必要です。更新して再起動してください。',
      blockedWebhook:
        'トリガーを追加するには、このボットのメッセージング設定で Webhook プラットフォームを有効にしてください。',
      blockedGateway: 'トリガーを追加するには、このボットのゲートウェイを起動してください。',
      loadFailed: 'トリガーを読み込めませんでした。',
      createdTitle: 'Webhook トリガーの準備ができました',
      urlLabel: 'アドレス',
      keyLabel: 'キー',
      copyUrl: 'アドレスをコピー',
      copyKey: 'キーをコピー',
      onceNote: 'キーは今すぐコピーしてください。表示されるのは一度だけです。失くした場合は再生成してください。',
      howToSend:
        'アドレスに POST リクエストを送り、キーを X-Gitlab-Token ヘッダーに入れるか、キーで本文に署名（HMAC-SHA256）してください。',
      payloadNote: 'リクエスト本文は、指示ではなく読み取るデータとしてルーティンに渡されます。',
      done: '完了',
      regenerate: 'キーを再生成',
      regenerateTitle: 'キーを再生成しますか？',
      regenerateBody: '現在のキーを使っているものは、新しいキーを設定するまで動作しなくなります。',
      regenerateConfirm: '再生成',
      regenerating: '再生成中…',
      remove: 'トリガーを削除',
      removeTitle: 'このトリガーを削除しますか？',
      removeBody: 'そのアドレスはすぐに使えなくなります。',
      removeConfirm: '削除',
      removing: '削除中…',
      conflict: 'このルーティンのアドレスは、別の Webhook がすでに使っています。',
      failed: 'トリガーを更新できませんでした。'
    }
  },
  zh: {
    active: { label: '启用', description: '已暂停的例行任务不会按计划或由触发器运行。' },
    test: {
      action: '立即测试',
      running: '运行中…',
      note: '立即真实运行此例行任务。它可能发送消息并做出更改，与计划运行一样。',
      queued: '测试已排队，此机器人的网关很快会运行它。',
      started: '测试已开始。',
      stoppedWaiting: '测试耗时较长，已不再等待结果。请在“最近运行”中查看结果。',
      succeeded: '测试已完成。',
      failedWith: reason => `测试失败：${reason}`,
      cancelled: '测试已停止。',
      refusedWith: reason => `无法开始测试：${reason}`,
      paused: '请先启用该例行任务再测试。',
      alreadyRunning: '此例行任务已在运行。',
      notFound: '此例行任务已不存在。',
      unavailable: '无法开始运行。',
      needsUpdate: '在此处测试需要较新的 Hermes 网关。请更新并重启。'
    },
    history: {
      title: '最近运行',
      empty: '尚未运行。',
      loadFailed: '无法加载运行记录。',
      running: '运行中',
      succeeded: '成功',
      failed: '失败',
      cancelled: '已停止',
      seconds: count => `${count} 秒`,
      minutes: count => `${count} 分钟`,
      viewOutput: '查看输出',
      hideOutput: '隐藏输出',
      outputFailed: '无法加载此输出。',
      noOutput: '此次运行没有保存任何输出。',
      truncated: '输出已截短。',
      needsUpdate: '运行记录需要较新的 Hermes 网关。请更新并重启。'
    },
    schedule: {
      checking: '检查中…',
      runs: label => `运行：${label}`,
      nextRun: when => `下次运行 ${when}`,
      tooFrequent: '例行任务最多每 5 分钟运行一次。',
      unrecognized: '无法理解该计划。请尝试“every weekday at 9am”或“every 2 hours”。',
      invalid: '该计划无效。',
      placeholder: 'every weekday at 9am · every 2 hours · 0 9 * * 1-5'
    },
    triggers: {
      title: '触发器',
      add: '添加触发器',
      webhook: 'Webhook',
      webhookSummary: '每当有请求发送到它的地址时，运行此例行任务。',
      needsUpdate: '触发器需要较新的 Hermes 网关。请更新并重启。',
      blockedWebhook: '要添加触发器，请先在此机器人的消息设置中开启 Webhook 平台。',
      blockedGateway: '要添加触发器，请先启动此机器人的网关。',
      loadFailed: '无法加载触发器。',
      createdTitle: 'Webhook 触发器已就绪',
      urlLabel: '地址',
      keyLabel: '密钥',
      copyUrl: '复制地址',
      copyKey: '复制密钥',
      onceNote: '请立即复制密钥。它只显示一次；丢失后请重新生成。',
      howToSend:
        '向该地址发送 POST 请求，并在 X-Gitlab-Token 请求头中携带密钥，或使用密钥对请求体签名（HMAC-SHA256）。',
      payloadNote: '请求体会作为待读取的数据交给例行任务，而不是作为指令。',
      done: '完成',
      regenerate: '重新生成密钥',
      regenerateTitle: '重新生成密钥？',
      regenerateBody: '使用当前密钥的一切都会失效，直到你换成新密钥。',
      regenerateConfirm: '重新生成',
      regenerating: '正在重新生成…',
      remove: '移除触发器',
      removeTitle: '移除此触发器？',
      removeBody: '它的地址会立即失效。',
      removeConfirm: '移除',
      removing: '正在移除…',
      conflict: '另一个 Webhook 已在使用此例行任务的地址。',
      failed: '无法更新触发器。'
    }
  },
  'zh-hant': {
    active: { label: '啟用', description: '已暫停的例行任務不會依排程或由觸發器執行。' },
    test: {
      action: '立即測試',
      running: '執行中…',
      note: '立即實際執行此例行任務。它可能傳送訊息並進行變更，與排程執行相同。',
      queued: '測試已排入佇列，此機器人的閘道很快會執行它。',
      started: '測試已開始。',
      stoppedWaiting: '測試耗時較長，已不再等待結果。請在「最近執行」中查看結果。',
      succeeded: '測試已完成。',
      failedWith: reason => `測試失敗：${reason}`,
      cancelled: '測試已停止。',
      refusedWith: reason => `無法開始測試：${reason}`,
      paused: '請先啟用該例行任務再測試。',
      alreadyRunning: '此例行任務已在執行。',
      notFound: '此例行任務已不存在。',
      unavailable: '無法開始執行。',
      needsUpdate: '在此測試需要較新的 Hermes 閘道。請更新並重新啟動。'
    },
    history: {
      title: '最近執行',
      empty: '尚未執行。',
      loadFailed: '無法載入執行記錄。',
      running: '執行中',
      succeeded: '成功',
      failed: '失敗',
      cancelled: '已停止',
      seconds: count => `${count} 秒`,
      minutes: count => `${count} 分鐘`,
      viewOutput: '檢視輸出',
      hideOutput: '隱藏輸出',
      outputFailed: '無法載入此輸出。',
      noOutput: '此次執行沒有儲存任何輸出。',
      truncated: '輸出已截短。',
      needsUpdate: '執行記錄需要較新的 Hermes 閘道。請更新並重新啟動。'
    },
    schedule: {
      checking: '檢查中…',
      runs: label => `執行：${label}`,
      nextRun: when => `下次執行 ${when}`,
      tooFrequent: '例行任務最多每 5 分鐘執行一次。',
      unrecognized: '無法理解該排程。請嘗試「every weekday at 9am」或「every 2 hours」。',
      invalid: '該排程無效。',
      placeholder: 'every weekday at 9am · every 2 hours · 0 9 * * 1-5'
    },
    triggers: {
      title: '觸發器',
      add: '新增觸發器',
      webhook: 'Webhook',
      webhookSummary: '每當有請求傳送到它的位址時，執行此例行任務。',
      needsUpdate: '觸發器需要較新的 Hermes 閘道。請更新並重新啟動。',
      blockedWebhook: '要新增觸發器，請先在此機器人的訊息設定中開啟 Webhook 平台。',
      blockedGateway: '要新增觸發器，請先啟動此機器人的閘道。',
      loadFailed: '無法載入觸發器。',
      createdTitle: 'Webhook 觸發器已就緒',
      urlLabel: '位址',
      keyLabel: '金鑰',
      copyUrl: '複製位址',
      copyKey: '複製金鑰',
      onceNote: '請立即複製金鑰。它只會顯示一次；遺失後請重新產生。',
      howToSend:
        '向該位址傳送 POST 請求，並在 X-Gitlab-Token 標頭中帶上金鑰，或使用金鑰對請求本文簽章（HMAC-SHA256）。',
      payloadNote: '請求本文會作為待讀取的資料交給例行任務，而不是作為指令。',
      done: '完成',
      regenerate: '重新產生金鑰',
      regenerateTitle: '重新產生金鑰？',
      regenerateBody: '使用目前金鑰的一切都會失效，直到你換成新金鑰。',
      regenerateConfirm: '重新產生',
      regenerating: '正在重新產生…',
      remove: '移除觸發器',
      removeTitle: '移除此觸發器？',
      removeBody: '它的位址會立即失效。',
      removeConfirm: '移除',
      removing: '正在移除…',
      conflict: '另一個 Webhook 已在使用此例行任務的位址。',
      failed: '無法更新觸發器。'
    }
  }
}
