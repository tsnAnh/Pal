import { type SyntheticEvent, useCallback, useEffect, useRef, useState } from 'react'

import { iconSize, Pause, Play } from '@/lib/icons'
import { cn } from '@/lib/utils'
import type { ChatVoiceLabels } from '@/store/chat-persona'
import { formatCallDuration } from '@/store/voice-call'

type MemoLabels = Pick<ChatVoiceLabels, 'pauseMemo' | 'playMemo'>

interface VoiceMemoPlayerProps {
  labels: MemoLabels
  name: string
  onError?: (event: SyntheticEvent<HTMLAudioElement>) => void
  onLoadedMetadata?: (event: SyntheticEvent<HTMLAudioElement>) => void
  src: string
}

let playingMemo: HTMLAudioElement | null = null

export function memoClock(seconds: number): string {
  return formatCallDuration(Number.isFinite(seconds) ? seconds * 1000 : 0)
}

export function VoiceMemoPlayer({ labels, name, onError, onLoadedMetadata, src }: VoiceMemoPlayerProps) {
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const [duration, setDuration] = useState(0)
  const [position, setPosition] = useState(0)
  const [playing, setPlaying] = useState(false)

  useEffect(
    () => () => {
      if (playingMemo === audioRef.current) {
        playingMemo = null
      }
    },
    []
  )

  const toggle = useCallback(() => {
    const audio = audioRef.current

    if (!audio) {
      return
    }

    if (!audio.paused) {
      audio.pause()

      return
    }

    if (playingMemo && playingMemo !== audio) {
      playingMemo.pause()
    }

    playingMemo = audio
    void audio.play().catch(() => setPlaying(false))
  }, [])

  const progress = duration > 0 ? Math.min(1, position / duration) : 0
  const label = playing ? labels.pauseMemo : labels.playMemo

  return (
    <span
      className="my-2 inline-flex h-9 max-w-full items-center gap-2 rounded-full border border-(--ui-stroke-tertiary) bg-muted/35 py-1 pr-3 pl-1"
      data-playing={playing ? '' : undefined}
      data-slot="voice-memo-player"
      title={name}
    >
      <button
        aria-label={label}
        className="grid size-7 shrink-0 place-items-center rounded-full bg-foreground text-background hover:bg-foreground/90"
        onClick={toggle}
        type="button"
      >
        {playing ? <Pause className={iconSize.sm} /> : <Play className={iconSize.sm} />}
      </button>
      <span
        aria-hidden="true"
        className="relative h-1 w-24 shrink-0 overflow-hidden rounded-full bg-(--ui-stroke-tertiary)"
      >
        <span
          className={cn('absolute inset-y-0 left-0 rounded-full bg-foreground/70')}
          style={{ width: `${progress * 100}%` }}
        />
      </span>
      <span className="text-xs tabular-nums text-muted-foreground" data-slot="voice-memo-time">
        {memoClock(playing || position > 0 ? position : duration)}
      </span>
      <audio
        onEnded={() => {
          setPlaying(false)
          setPosition(0)
        }}
        onError={onError}
        onLoadedMetadata={event => {
          setDuration(event.currentTarget.duration)
          onLoadedMetadata?.(event)
        }}
        onPause={() => setPlaying(false)}
        onPlay={() => setPlaying(true)}
        onTimeUpdate={event => setPosition(event.currentTarget.currentTime)}
        preload="metadata"
        ref={audioRef}
        src={src}
      />
    </span>
  )
}
