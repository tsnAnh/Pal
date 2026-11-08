import type { ReachOfferPayload, ReachOutcomeParams } from '@hermes/shared'

import { sessionRoute } from '@/app/routes'
import { translateNow } from '@/i18n'

import { nativeNotificationEnabled, presentNativeNotification } from './native-notifications'
import { dismissNotification, notify } from './notifications'
import { requestRoute } from './recovery-requests'

export type ReachOutcome = ReachOutcomeParams['outcome']

export interface OutcomeSender {
  request: <T>(method: string, params?: Record<string, unknown>) => Promise<T>
}

interface PendingOffer {
  offerId: string
  sender: OutcomeSender
}

type OfferSurface = 'native' | 'toast'

type OfferPresenter = (offer: ReachOfferPayload, handle: string) => Promise<boolean>

export const TOAST_LIFETIME_MS = 15_000
const SEEN_OFFERS_MAX = 256
const PENDING_OFFERS_MAX = 64
const OFFER_ID_MAX = 64

const seenOffers = new Set<string>()
const pendingOffers = new Map<string, PendingOffer>()

function remember<T>(collection: Set<T>, value: T, max: number): void {
  collection.add(value)

  for (const oldest of collection) {
    if (collection.size <= max) {
      break
    }

    collection.delete(oldest)
  }
}

function reportOutcome(sender: OutcomeSender, offerId: string, outcome: ReachOutcome): void {
  const params: ReachOutcomeParams = { offer_id: offerId, outcome }

  void sender.request('reach.outcome', { ...params }).catch(() => undefined)
}

function isForeground(): boolean {
  return !document.hidden && (typeof document.hasFocus !== 'function' || document.hasFocus())
}

function settleOffer(handle: string, outcome: Exclude<ReachOutcome, 'shown'>): boolean {
  const pending = pendingOffers.get(handle)

  if (!pending) {
    return false
  }

  pendingOffers.delete(handle)
  reportOutcome(pending.sender, pending.offerId, outcome)

  return true
}

export function settleReachOfferNotification(handle: string | undefined, outcome: 'acted' | 'dismissed'): void {
  if (handle) {
    settleOffer(handle, outcome)
  }
}

function presentToast(offer: ReachOfferPayload, handle: string): Promise<boolean> {
  const sessionId = offer.session_id || undefined
  let expired = false

  const id = notify({
    action: sessionId
      ? {
          label: translateNow('notifications.native.proactiveOpen'),
          onClick: () => {
            if (settleOffer(handle, 'acted')) {
              requestRoute(sessionRoute(sessionId))
            }
          }
        }
      : undefined,
    durationMs: 0,
    message: offer.body,
    onDismiss: () => {
      if (!expired) {
        settleOffer(handle, 'dismissed')
      }
    },
    title: offer.title
  })

  window.setTimeout(() => {
    expired = true
    pendingOffers.delete(handle)
    dismissNotification(id)
  }, TOAST_LIFETIME_MS)

  return Promise.resolve(true)
}

function presentNative(offer: ReachOfferPayload, handle: string): Promise<boolean> {
  return presentNativeNotification({
    body: offer.body,
    focusSessionId: offer.session_id || undefined,
    kind: 'proactive',
    notifyId: handle,
    tag: offer.offer_id,
    title: offer.title
  })
}

const PRESENTERS: Record<OfferSurface, OfferPresenter> = {
  native: presentNative,
  toast: presentToast
}

function isOffer(value: unknown): value is ReachOfferPayload {
  const offer = value as Partial<ReachOfferPayload> | null | undefined

  return (
    typeof offer?.offer_id === 'string' &&
    offer.offer_id.length > 0 &&
    offer.offer_id.length <= OFFER_ID_MAX &&
    typeof offer.title === 'string' &&
    typeof offer.body === 'string'
  )
}

export function receiveReachOffer(sender: OutcomeSender, payload: unknown): void {
  if (!isOffer(payload) || seenOffers.has(payload.offer_id) || !nativeNotificationEnabled('proactive')) {
    return
  }

  remember(seenOffers, payload.offer_id, SEEN_OFFERS_MAX)

  const handle = `reach:${payload.offer_id}`
  const surface: OfferSurface = isForeground() ? 'toast' : 'native'

  pendingOffers.set(handle, { offerId: payload.offer_id, sender })

  for (const oldest of pendingOffers.keys()) {
    if (pendingOffers.size <= PENDING_OFFERS_MAX) {
      break
    }

    pendingOffers.delete(oldest)
  }

  void PRESENTERS[surface](payload, handle).then(shown => {
    if (shown) {
      reportOutcome(sender, payload.offer_id, 'shown')

      return
    }

    pendingOffers.delete(handle)
    seenOffers.delete(payload.offer_id)
  })
}

export function __resetPresenceOffersForTests(): void {
  seenOffers.clear()
  pendingOffers.clear()
}
