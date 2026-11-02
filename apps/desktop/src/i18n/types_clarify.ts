/** The clarify question card. */
export interface ClarifyCopy {
  notReady: string
  gatewayDisconnected: string
  sendFailed: string
  loadingQuestion: string
  other: string
  placeholder: string
  skip: string
  send: string
  close: string
  skipped: string
  noAnswer: string
  confirmAndContinueLabel: string
  singleSelectHint: string
  multiSelectHint: string
  oneQuestion: string
  questionProgress: (answered: number, total: number) => string
  notDelivered: string
}
