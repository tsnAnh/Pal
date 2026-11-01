import {
  Button,
  cn,
  host,
  Popover,
  PopoverContent,
  PopoverTrigger,
  queryClient
} from '@hermes/plugin-sdk'
import { type KeyboardEvent, useId, useRef, useState } from 'react'

import {
  AVATAR_PICKER_SHAPES,
  avatarColor,
  BLOB_KINDS,
  blobatarSvg,
  blobShapeString,
  botAppearance,
  BotFace,
  defaultShapeFor,
  isBlobShape,
  parseBlobShape
} from './avatar'
import { safeAvatarColor } from './avatar-color'
import { GeneratePanel, UploadPanel } from './avatar-image-panels'
import { submitLatestWins } from './avatar-save-queue'
import { AVATAR_SWATCHES } from './avatar-swatches'
import { botOwner, ROSTER_KEY, saveBotMeta } from './data'
import { useBots } from './i18n'
import type { BotMeta, RosterRow } from './types'

type PopoverTab = 'bot' | 'generate' | 'upload'

interface AvatarPopoverProps {
  bot: string
  meta: BotMeta | null
  owner: RosterRow
}

interface ShapeChoice {
  id: string
  shape: string
}

const PANE_MARGIN = 12
const FALLBACK_WIDTH = 320
const HEADER_SELECTOR = '[data-slot="bot-profile-header"]'

const SHAPE_PATCH = { image: null, imageKind: 'shape', custom: true } as const

function shapeChoices(bot: string, seedPart: string): ShapeChoice[] {
  if (blobatarSvg) {
    return BLOB_KINDS.map(kind => ({ id: kind, shape: blobShapeString(seedPart, kind) }))
  }

  return AVATAR_PICKER_SHAPES.map(shape => ({ id: shape, shape: shape === 'blob' ? defaultShapeFor(bot) : shape }))
}

const RESET_PATCH: BotMeta = {
  shape: undefined,
  color: undefined,
  image: null,
  imageKind: undefined,
  custom: false
}

const ROVING_STEP: Record<string, number> = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }

function moveRovingFocus(event: KeyboardEvent<HTMLElement>) {
  const options = Array.from(event.currentTarget.querySelectorAll<HTMLElement>('[role="radio"]'))
  const current = options.indexOf(document.activeElement as HTMLElement)

  if (current < 0) {
    return
  }

  const target =
    event.key === 'Home'
      ? 0
      : event.key === 'End'
        ? options.length - 1
        : ROVING_STEP[event.key] === undefined
          ? null
          : (current + ROVING_STEP[event.key]! + options.length) % options.length

  if (target !== null) {
    event.preventDefault()
    options[target]?.focus()
  }
}

function tabStopIndex(selected: number): number {
  return Math.max(selected, 0)
}

function ringStyle(color?: string) {
  return {
    boxShadow: `0 0 0 2px var(--ui-bg-elevated), 0 0 0 3.5px ${color ?? 'var(--ui-accent)'}`
  }
}

export function AvatarPopover({ bot, meta, owner }: AvatarPopoverProps) {
  const b = useBots()
  const trigger = useRef<HTMLButtonElement>(null)
  const [open, setOpen] = useState(false)
  const [tab, setTab] = useState<PopoverTab>('bot')
  const [width, setWidth] = useState(FALLBACK_WIDTH)
  const [optimistic, setOptimistic] = useState<BotMeta | null>(null)
  const tabsId = useId()
  const shownMeta = optimistic ? { ...meta, ...optimistic } : meta
  const { shape, color, image } = botAppearance(bot, shownMeta)
  const pickedColor = safeAvatarColor(shownMeta?.color)
  const blob = isBlobShape(shape)
  const { seedPart, kind } = parseBlobShape(shape, bot)
  const selectedShape = image ? null : blob ? kind : shape

  const ownerKey = botOwner(owner).key

  const save = (patch: BotMeta) => {
    setOptimistic(current => ({ ...current, ...patch }))

    submitLatestWins(
      ownerKey,
      patch,
      next => saveBotMeta(owner, next),
      settled => {
        setOptimistic(null)

        if (!settled.ok) {
          host.notifyError(settled.error, b.avatar.savedLocally)
        } else if (settled.value?.serverOutcome === 'failed') {
          host.notify({ kind: 'error', message: b.avatar.savedLocally })
        } else if (settled.value?.serverOutcome === 'persisted') {
          queryClient.invalidateQueries({ queryKey: ROSTER_KEY })
        }
      }
    )
  }

  const saveImage = (next: string) => save({ image: next, imageKind: 'photo', custom: true })

  const onOpenChange = (next: boolean) => {
    if (next) {
      const pane = trigger.current?.closest(HEADER_SELECTOR)?.clientWidth

      setWidth(pane ? pane - PANE_MARGIN : FALLBACK_WIDTH)
      setTab('bot')
    }

    setOpen(next)
  }

  const choices = shapeChoices(bot, blob ? seedPart : '')

  const tabs: { id: PopoverTab; label: string }[] = [
    { id: 'bot', label: b.avatar.tabBot },
    { id: 'generate', label: b.avatar.tabGenerate },
    { id: 'upload', label: b.avatar.upload }
  ]

  return (
    <Popover onOpenChange={onOpenChange} open={open}>
      <PopoverTrigger asChild>
        <button
          aria-label={b.avatar.change}
          className="rounded-[26%] outline-none transition-transform focus-visible:ring-2 focus-visible:ring-(--ui-accent) active:scale-[0.98]"
          data-slot="bot-avatar-trigger"
          ref={trigger}
          type="button"
        >
          <BotFace color={avatarColor(color, bot)} image={image} name={bot} shape={shape} size={96} />
        </button>
      </PopoverTrigger>
      <PopoverContent
        align="center"
        className="rounded-[20px] p-3 shadow-none"
        collisionPadding={PANE_MARGIN / 2}
        data-slot="bot-avatar-popover"
        side="bottom"
        sideOffset={10}
        style={{ width }}
        variant="menu"
      >
        <div className="flex items-center justify-between border-b border-(--ui-stroke-secondary) pb-2.5">
          <div aria-label={b.avatar.change} className="flex items-center gap-1" role="tablist">
            {tabs.map(({ id, label }) => (
              <button
                aria-controls={`${tabsId}-panel`}
                aria-selected={tab === id}
                className={cn(
                  'rounded-full px-3 py-1 text-sm transition-colors',
                  tab === id
                    ? 'bg-(--chrome-action-hover) font-medium text-foreground'
                    : 'text-(--ui-text-tertiary) hover:text-foreground'
                )}
                id={`${tabsId}-tab-${id}`}
                key={id}
                onClick={() => setTab(id)}
                role="tab"
                tabIndex={tab === id ? 0 : -1}
                type="button"
              >
                {label}
              </button>
            ))}
          </div>
          <Button
            className="text-sm text-(--ui-text-tertiary) hover:text-foreground"
            onClick={() => save(RESET_PATCH)}
            size="inline"
            type="button"
            variant="text"
          >
            {b.avatar.reset}
          </Button>
        </div>
        <div aria-labelledby={`${tabsId}-tab-${tab}`} id={`${tabsId}-panel`} role="tabpanel">
          {tab === 'bot' ? (
            <div className="grid gap-4 pt-3">
              <div
                aria-label={b.avatar.shapeGroup}
                className="grid grid-cols-5 gap-1"
                onKeyDown={moveRovingFocus}
                role="radiogroup"
              >
                {choices.map((choice, index) => (
                  <button
                    aria-checked={choice.id === selectedShape}
                    aria-label={b.avatar.shapeOption(index + 1)}
                    className="flex aspect-square items-center justify-center rounded-2xl transition-colors hover:bg-(--chrome-action-hover)"
                    key={choice.id}
                    onClick={() => save({ ...SHAPE_PATCH, shape: choice.shape })}
                    role="radio"
                    tabIndex={index === tabStopIndex(choices.findIndex(c => c.id === selectedShape)) ? 0 : -1}
                    type="button"
                  >
                    <span
                      className="flex rounded-[26%]"
                      style={choice.id === selectedShape ? ringStyle() : undefined}
                    >
                      <BotFace color={avatarColor(pickedColor, bot)} name={bot} shape={choice.shape} size={48} />
                    </span>
                  </button>
                ))}
              </div>
              <div
                aria-label={b.avatar.colorGroup}
                className="grid grid-cols-6 justify-items-center gap-y-2"
                onKeyDown={moveRovingFocus}
                role="radiogroup"
              >
                {AVATAR_SWATCHES.map((swatch, index) => (
                  <button
                    aria-checked={swatch === pickedColor}
                    aria-label={b.avatar.colorOption(index + 1)}
                    className="size-10 rounded-full transition-transform hover:scale-105"
                    key={swatch}
                    onClick={() => save({ ...SHAPE_PATCH, color: swatch })}
                    role="radio"
                    style={{
                      backgroundColor: swatch,
                      ...(swatch === pickedColor ? ringStyle(swatch) : null)
                    }}
                    tabIndex={index === tabStopIndex((AVATAR_SWATCHES as readonly string[]).indexOf(pickedColor ?? '')) ? 0 : -1}
                    type="button"
                  />
                ))}
              </div>
            </div>
          ) : null}
          {tab === 'generate' ? (
            <div className="pt-3">
              <GeneratePanel
                generateSeed={{ name: bot, title: meta?.title || owner.title || undefined, description: owner.description }}
                onImage={saveImage}
              />
            </div>
          ) : null}
          {tab === 'upload' ? (
            <div className="pt-3">
              <UploadPanel onImage={saveImage} />
            </div>
          ) : null}
        </div>
      </PopoverContent>
    </Popover>
  )
}
