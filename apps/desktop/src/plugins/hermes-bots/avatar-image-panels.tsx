import { Button, Codicon, GlyphSpinner, host, Textarea, useValue } from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'

import {
  $imagenAvailable,
  generateAvatarImage,
  type GeneratedImage,
  normalizeAvatarImage,
  pickImageFromDevice,
  probeImagen
} from './avatar-image'
import { useBots } from './i18n'

export interface AvatarGenerateSeed {
  description?: string
  name?: string
  title?: string
}

interface GeneratePanelProps {
  generateSeed?: AvatarGenerateSeed | null
  onImage: (image: string) => void
}

async function describedImage(custom: string): Promise<null | string | undefined> {
  const res = await host.request<GeneratedImage>('image.generate', {
    prompt: `${custom}. Avatar for an AI agent: centered, bold flat vector style, solid color background, no text.`,
    aspect_ratio: 'square'
  })

  if (!res?.success) {
    throw new Error(res?.error || 'generation failed')
  }

  return res.image_data || res.image
}

export function GeneratePanel({ generateSeed, onImage }: GeneratePanelProps) {
  const b = useBots()
  const imagen = useValue($imagenAvailable)
  const [describe, setDescribe] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if ($imagenAvailable.get() === false) {
      $imagenAvailable.set(null)
    }

    void probeImagen()
  }, [])

  const generate = async () => {
    if (busy) {
      return
    }

    setBusy(true)

    try {
      const custom = describe.trim()

      const img = custom
        ? await describedImage(custom)
        : await generateAvatarImage(generateSeed?.name || 'agent', generateSeed?.title, generateSeed?.description)

      if (img) {
        onImage(await normalizeAvatarImage(img))
      }
    } catch (err) {
      host.notifyError(err, b.avatar.generationFailed)
    } finally {
      setBusy(false)
    }
  }

  if (!imagen) {
    return (
      <div className="px-2 py-3 text-center text-xs leading-5 text-(--ui-text-tertiary)">
        {imagen === false ? b.editor.noImageModel : b.editor.checkingImage}
      </div>
    )
  }

  return (
    <div className="grid w-full gap-2">
      <Textarea
        className="min-h-16 text-xs"
        onChange={event => setDescribe(event.target.value)}
        placeholder={b.avatar.describePlaceholder}
        value={describe}
      />
      <Button className="w-full justify-center" disabled={busy} onClick={generate} type="button" variant="secondary">
        {busy ? (
          <GlyphSpinner className="mr-1 text-[0.8rem]" spinner="breathe" />
        ) : (
          <Codicon className="mr-1 text-[0.8rem]" name="sparkle" />
        )}
        {busy ? b.avatar.generating : b.avatar.generate}
      </Button>
      {describe.trim() ? null : (
        <div className="text-center text-[0.65rem] text-(--ui-text-quaternary)">{b.bot.descriptionHint}</div>
      )}
    </div>
  )
}

export function UploadPanel({ onImage }: { onImage: (image: string) => void }) {
  const b = useBots()

  const upload = async () => {
    const raw = await pickImageFromDevice()

    if (raw) {
      onImage(await normalizeAvatarImage(raw))
    }
  }

  return (
    <Button className="w-full justify-center" onClick={upload} type="button" variant="secondary">
      <Codicon className="mr-1 text-[0.8rem]" name="device-camera" />
      {b.editor.chooseImage}
    </Button>
  )
}
