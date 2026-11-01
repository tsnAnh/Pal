import { useStore } from '@nanostores/react'
import { useEffect, useState } from 'react'

import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { Tip, TipKeybindLabel } from '@/components/ui/tooltip'
import { chatMessageText } from '@/lib/chat-messages'
import { triggerHaptic } from '@/lib/haptics'
import { AudioLines, FileText, iconSize, Mic, MicOff, PhoneOff } from '@/lib/icons'
import { cn } from '@/lib/utils'
import type { ChatPersona, ChatVoiceLabels } from '@/store/chat-persona'
import { requestVoiceConversationStart } from '@/store/composer'
import { $messages } from '@/store/session'
import { $voiceCall, $voiceCallControls, callTurns, formatCallDuration, type VoiceCallState } from '@/store/voice-call'

const pillClass =
  'pointer-events-auto flex h-7 shrink-0 items-center gap-1 rounded-full border border-(--ui-stroke-tertiary) bg-(--ui-chat-surface-background)/80 text-xs font-medium text-foreground backdrop-blur-md [-webkit-app-region:no-drag]'

const iconButtonClass =
  'grid size-7 shrink-0 place-items-center rounded-full text-(--ui-text-secondary) hover:bg-(--ui-control-hover-background) hover:text-foreground aria-pressed:bg-(--ui-control-active-background)'

function useElapsed(startedAt: null | number): number {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (startedAt === null) {
      return
    }

    setNow(Date.now())

    const timer = window.setInterval(() => setNow(Date.now()), 1000)

    return () => window.clearInterval(timer)
  }, [startedAt])

  return startedAt === null ? 0 : Math.max(0, now - startedAt)
}

function statusText(call: VoiceCallState, labels: ChatVoiceLabels): string {
  if (call.muted) {
    return labels.muted
  }

  switch (call.status) {
    case 'listening':
      return labels.listening

    case 'speaking':
      return labels.speaking

    case 'thinking':

    case 'transcribing':
      return labels.thinking

    default:
      return labels.callLive
  }
}

function CallTranscript({ labels, startedAt }: { labels: ChatVoiceLabels; startedAt: null | number }) {
  const messages = useStore($messages)
  const turns = callTurns(messages, startedAt)

  if (turns.length === 0) {
    return <p className="px-1 py-2 text-xs text-muted-foreground">{labels.transcriptEmpty}</p>
  }

  return (
    <ol className="flex max-h-72 flex-col gap-2 overflow-y-auto px-1 py-1 text-xs" data-slot="voice-call-transcript">
      {turns.map(turn => (
        <li className="min-w-0" key={turn.id}>
          {turn.role === 'user' && <span className="mr-1 font-medium text-muted-foreground">{labels.you}</span>}
          <span className="wrap-anywhere whitespace-pre-wrap">{chatMessageText(turn).trim()}</span>
        </li>
      ))}
    </ol>
  )
}

function LiveCall({ call, labels }: { call: VoiceCallState; labels: ChatVoiceLabels }) {
  const controls = useStore($voiceCallControls)
  const elapsed = useElapsed(call.startedAt)
  const [transcriptOpen, setTranscriptOpen] = useState(false)

  return (
    <div className={cn(pillClass, 'pl-3')} data-slot="voice-call-live" data-status={call.status}>
      <span aria-live="polite" className="flex items-center gap-1.5">
        <span
          aria-hidden="true"
          className={cn(
            'size-1.5 rounded-full bg-emerald-500',
            !call.muted && call.status === 'listening' && 'animate-pulse'
          )}
        />
        <span>{statusText(call, labels)}</span>
        <span className="tabular-nums text-muted-foreground">{formatCallDuration(elapsed)}</span>
      </span>
      <Tip label={call.muted ? labels.unmute : labels.mute}>
        <button
          aria-label={call.muted ? labels.unmute : labels.mute}
          aria-pressed={call.muted}
          className={iconButtonClass}
          disabled={!controls}
          onClick={() => controls?.toggleMute()}
          type="button"
        >
          {call.muted ? <MicOff className={iconSize.sm} /> : <Mic className={iconSize.sm} />}
        </button>
      </Tip>
      <Popover onOpenChange={setTranscriptOpen} open={transcriptOpen}>
        <Tip label={transcriptOpen ? labels.hideTranscript : labels.showTranscript}>
          <PopoverTrigger asChild>
            <button
              aria-label={transcriptOpen ? labels.hideTranscript : labels.showTranscript}
              aria-pressed={transcriptOpen}
              className={iconButtonClass}
              type="button"
            >
              <FileText className={iconSize.sm} />
            </button>
          </PopoverTrigger>
        </Tip>
        <PopoverContent align="end" className="w-80">
          <CallTranscript labels={labels} startedAt={call.startedAt} />
        </PopoverContent>
      </Popover>
      <Tip label={labels.hangUp}>
        <button
          aria-label={labels.hangUp}
          className={cn(iconButtonClass, 'bg-destructive text-white hover:bg-destructive/90 hover:text-white')}
          disabled={!controls}
          onClick={() => {
            triggerHaptic('close')
            controls?.hangUp()
          }}
          type="button"
        >
          <PhoneOff className={iconSize.sm} />
        </button>
      </Tip>
    </div>
  )
}

export function VoiceCallControls({ labels }: { labels: ChatVoiceLabels }) {
  const call = useStore($voiceCall)

  if (call.phase === 'live') {
    return <LiveCall call={call} labels={labels} />
  }

  return (
    <Tip label={<TipKeybindLabel actionId="composer.voice" text={labels.startCall} />}>
      <button
        aria-label={labels.startCall}
        className={cn(pillClass, 'w-7 justify-center hover:bg-(--ui-control-hover-background)')}
        data-slot="voice-call-start"
        onClick={() => {
          triggerHaptic('open')
          requestVoiceConversationStart()
        }}
        type="button"
      >
        <AudioLines className={iconSize.sm} />
      </button>
    </Tip>
  )
}

export function PersonaVoiceCall({ persona }: { persona: ChatPersona }) {
  return persona.voice ? (
    <div className="pointer-events-auto ml-2 flex shrink-0 items-center">
      <VoiceCallControls labels={persona.voice()} />
    </div>
  ) : null
}
