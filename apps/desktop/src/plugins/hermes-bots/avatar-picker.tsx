/**
 * The avatar editor shared by Edit Profile and New Bot: shape grid + color
 * swatches, the Generate and Upload tabs, and the petdex Pet tab.
 */

import { Button, cn, Codicon, ColorSwatches, RowButton, SegmentedControl, Tip } from '@hermes/plugin-sdk'
import { useState } from 'react'

import {
  AVATAR_PICKER_SHAPES,
  avatarColor,
  BLOB_KINDS,
  blobatarSvg,
  blobShapeString,
  BotFace,
  defaultShapeFor,
  isBlobShape,
  parseBlobShape
} from './avatar'
import { type AvatarGenerateSeed, GeneratePanel, UploadPanel } from './avatar-image-panels'
import { AVATAR_SWATCHES } from './avatar-swatches'
import { useBots } from './i18n'
import { PetTab } from './pet'

interface AvatarPickerProps {
  /** `null` = no explicit pick, i.e. the name's deterministic hue. */
  color: null | string
  /** Feeds the Generate tab when the user leaves the description blank. */
  generateSeed?: AvatarGenerateSeed | null
  image: null | string
  onColor: (color: null | string) => void
  onImage: (image: null | string) => void
  onShape: (shape: string) => void
  shape: string
}

/** Shape grid + color swatches, shared by Edit Profile and New Bot. */
export function AvatarPicker({ shape, color, image, onShape, onColor, onImage, generateSeed }: AvatarPickerProps) {
  const b = useBots()
  const pickerName = generateSeed?.name || 'agent'
  const [tab, setTab] = useState('bot')

  return (
    <div className="grid justify-items-center gap-3">
      <SegmentedControl
        onChange={setTab}
        options={[
          { id: 'bot', label: b.avatar.tabBot },
          { id: 'generate', label: b.avatar.tabGenerate },
          { id: 'upload', label: b.avatar.upload },
          { id: 'pet', label: b.avatar.tabPet }
        ]}
        value={tab}
      />
      {image && tab !== 'generate' ? (
        <Button onClick={() => onImage(null)} size="sm" type="button" variant="ghost">
          {b.avatar.removeImage}
        </Button>
      ) : null}
      {tab === 'bot' ? (
        isBlobShape(shape) && blobatarSvg ? (
          (() => {
            const { seedPart, kind } = parseBlobShape(shape, pickerName)
            const locked = Boolean(seedPart)

            return (
              <div className="grid justify-items-center gap-3">
                {/* Silhouette pins: Auto (name decides) + the blob kinds. */}
                <div className="grid grid-cols-4 justify-items-center gap-1.5">
                  {['', ...BLOB_KINDS].map(k => (
                    <Tip key={k || 'auto'} label={k || b.editor.autoHint}>
                      <RowButton
                        aria-label={k || b.editor.autoHint}
                        className={cn(
                          'flex size-11 items-center justify-center rounded-md transition-colors hover:bg-(--chrome-action-hover)',
                          k === kind && !image && 'ring-1 ring-(--ui-accent)'
                        )}
                        onClick={() => {
                          onImage(null)
                          onShape(blobShapeString(seedPart, k))
                        }}
                      >
                        {k ? (
                          <BotFace
                            color={avatarColor(color, pickerName)}
                            name={pickerName}
                            shape={blobShapeString(seedPart, k)}
                            size={32}
                          />
                        ) : (
                          <span className="text-[0.6rem] text-(--ui-text-tertiary)">{b.editor.auto}</span>
                        )}
                      </RowButton>
                    </Tip>
                  ))}
                </div>
                <div className="flex items-center gap-1">
                  <Button
                    onClick={() => {
                      onImage(null)
                      onShape(blobShapeString(Math.random().toString(36).slice(2, 10), kind))
                    }}
                    size="sm"
                    type="button"
                    variant="ghost"
                  >
                    <Codicon className="mr-1 text-[0.8rem]" name="refresh" />
                    {b.avatar.randomize}
                  </Button>
                  <Button
                    onClick={() => onShape(blobShapeString(locked ? '' : pickerName, kind))}
                    size="sm"
                    type="button"
                    variant="ghost"
                  >
                    <Codicon className="mr-1 text-[0.8rem]" name={locked ? 'unlock' : 'lock'} />
                    {locked ? b.editor.unlock : b.editor.lockFace}
                  </Button>
                </div>
                <div className="text-center text-[0.65rem] text-(--ui-text-quaternary)">
                  {locked ? b.editor.lockedHint : b.editor.unlockedHint}
                </div>
                <ColorSwatches
                  clearLabel={b.avatar.matchTheName}
                  onChange={onColor}
                  swatches={AVATAR_SWATCHES}
                  value={color}
                />
                <Button
                  className="text-(--ui-text-tertiary)"
                  onClick={() => onShape(defaultShapeFor(pickerName))}
                  size="sm"
                  type="button"
                  variant="ghost"
                >
                  {b.avatar.classicShapes}
                </Button>
              </div>
            )
          })()
        ) : (
          <div className="grid justify-items-center gap-3">
            <div className="grid grid-cols-4 justify-items-center gap-1.5">
              {(blobatarSvg ? ['blobatar', ...AVATAR_PICKER_SHAPES] : AVATAR_PICKER_SHAPES).map(s => (
                <Tip key={s} label={s === 'blobatar' ? b.avatar.blobFromName : undefined}>
                  <RowButton
                    aria-label={s === 'blobatar' ? b.avatar.blobFromName : s}
                    className={cn(
                      'flex size-11 items-center justify-center rounded-md transition-colors hover:bg-(--chrome-action-hover)',
                      s === shape && !image && 'ring-1 ring-(--ui-accent)'
                    )}
                    onClick={() => {
                      onImage(null)
                      onShape(s)
                    }}
                  >
                    <BotFace color={avatarColor(color, pickerName)} name={pickerName} shape={s} size={32} />
                  </RowButton>
                </Tip>
              ))}
            </div>
            <ColorSwatches
              clearLabel={b.avatar.matchTheName}
              onChange={onColor}
              swatches={AVATAR_SWATCHES}
              value={color}
            />
          </div>
        )
      ) : null}
      {tab === 'generate' ? <GeneratePanel generateSeed={generateSeed} onImage={onImage} /> : null}
      {tab === 'upload' ? <UploadPanel onImage={onImage} /> : null}
      {tab === 'pet' ? <PetTab image={image} onImage={onImage} /> : null}
    </div>
  )
}
