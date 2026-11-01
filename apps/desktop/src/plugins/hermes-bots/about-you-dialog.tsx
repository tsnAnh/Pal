import {
  Button,
  Codicon,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DropdownMenuItem,
  Input,
  isSubmitEnter,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  useI18n,
  useValue
} from '@hermes/plugin-sdk'
import { useEffect, useRef, useState } from 'react'

import {
  $aboutYouOpen,
  ABOUT_YOU_NAME_MAX,
  aboutYouFailure,
  type AboutYouFailure,
  AUTO_TIMEZONE,
  browserTimeZone,
  closeAboutYou,
  loadAboutYou,
  openAboutYou,
  saveAboutYou,
  timeZoneChoices,
  useAboutYouSupport
} from './about-you'
import { labeled } from './dialog-parts'
import { useBots } from './i18n'

type Phase = 'error' | 'loading' | 'ready'

export function AboutYouMenuItem() {
  const b = useBots()

  if (useAboutYouSupport(true) !== 'supported') {
    return null
  }

  return (
    <DropdownMenuItem onSelect={openAboutYou}>
      <Codicon className="mr-1.5" name="account" />
      {b.aboutYou.menu}
    </DropdownMenuItem>
  )
}

export function AboutYouDialog() {
  const { t } = useI18n()
  const b = useBots()
  const open = useValue($aboutYouOpen)
  const [phase, setPhase] = useState<Phase>('loading')
  const [name, setName] = useState('')
  const [zone, setZone] = useState('')
  const [saving, setSaving] = useState(false)
  const [failure, setFailure] = useState<AboutYouFailure | null>(null)
  const [attempt, setAttempt] = useState(0)
  const token = useRef(0)
  const detected = browserTimeZone()

  useEffect(() => {
    if (!open) {
      return
    }

    const mine = ++token.current
    setPhase('loading')
    setFailure(null)

    loadAboutYou().then(
      facts => {
        if (token.current === mine) {
          setName(facts.name)
          setZone(facts.timezone || (detected ? AUTO_TIMEZONE : ''))
          setPhase('ready')
        }
      },
      () => {
        if (token.current === mine) {
          setPhase('error')
        }
      }
    )

    const requests = token

    return () => {
      requests.current++
    }
  }, [attempt, detected, open])

  const submit = async () => {
    if (phase !== 'ready' || saving) {
      return
    }

    const mine = ++token.current
    setSaving(true)
    setFailure(null)

    try {
      await saveAboutYou({ name: name.trim(), timezone: zone === AUTO_TIMEZONE ? detected : zone })

      if (token.current === mine) {
        closeAboutYou()
      }
    } catch (error) {
      if (token.current === mine) {
        setFailure(aboutYouFailure(error))
      }
    } finally {
      if (token.current === mine) {
        setSaving(false)
      }
    }
  }

  const choices = timeZoneChoices(zone === AUTO_TIMEZONE ? '' : zone)

  return (
    <Dialog onOpenChange={next => !next && closeAboutYou()} open={open}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>{b.aboutYou.title}</DialogTitle>
          <DialogDescription>{b.aboutYou.description}</DialogDescription>
        </DialogHeader>
        {phase === 'loading' ? (
          <p className="text-sm text-(--ui-text-tertiary)">{b.aboutYou.loading}</p>
        ) : phase === 'error' ? (
          <div className="flex items-center justify-between gap-3">
            <p className="text-sm text-destructive">{b.aboutYou.loadFailed}</p>
            <Button onClick={() => setAttempt(value => value + 1)} size="sm" type="button" variant="outline">
              {b.aboutYou.retry}
            </Button>
          </div>
        ) : (
          <div className="grid gap-3">
            {labeled(
              b.aboutYou.nameLabel,
              <Input
                aria-label={b.aboutYou.nameLabel}
                autoFocus
                maxLength={ABOUT_YOU_NAME_MAX}
                onChange={event => setName(event.target.value)}
                onKeyDown={event => {
                  if (isSubmitEnter(event)) {
                    event.preventDefault()
                    void submit()
                  }
                }}
                placeholder={b.aboutYou.namePlaceholder}
                value={name}
              />
            )}
            {labeled(
              b.aboutYou.timezoneLabel,
              <Select onValueChange={setZone} value={zone}>
                <SelectTrigger aria-label={b.aboutYou.timezoneLabel} className="h-8 rounded-md">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {detected ? <SelectItem value={AUTO_TIMEZONE}>{b.aboutYou.timezoneAuto(detected)}</SelectItem> : null}
                  {choices.map(choice => (
                    <SelectItem key={choice} value={choice}>
                      {choice}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
            {failure ? (
              <p className="text-xs text-destructive" role="alert">
                {failure === 'invalid-timezone' ? b.aboutYou.invalidTimezone : b.aboutYou.saveFailed}
              </p>
            ) : null}
          </div>
        )}
        <DialogFooter>
          <Button onClick={closeAboutYou} type="button" variant="ghost">
            {t.common.cancel}
          </Button>
          <Button disabled={phase !== 'ready' || saving} onClick={() => void submit()} type="button">
            {t.common.save}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
