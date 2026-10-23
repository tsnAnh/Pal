import { PROCESS_NOTIFICATION_RE } from '@/components/assistant-ui/thread/content'
import type { ChatMessage } from '@/lib/chat-messages'
import { chatMessageText } from '@/lib/chat-messages'

const SILENT_REPLY = '[SILENT]'

function isSilentReply(message: ChatMessage): boolean {
  return (
    message.role === 'assistant' &&
    message.parts.every(part => part.type === 'text' || part.type === 'reasoning') &&
    chatMessageText(message).trim() === SILENT_REPLY
  )
}

export function isProcessNotice(message: ChatMessage): boolean {
  if (message.role === 'system') {
    return message.asyncResultKind === 'process'
  }

  return message.role === 'user' && PROCESS_NOTIFICATION_RE.test(chatMessageText(message).trim())
}

export function isSilentInTranscript(message: ChatMessage): boolean {
  return isProcessNotice(message) || isSilentReply(message)
}
