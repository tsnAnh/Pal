import { Button } from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'

import type { CanonicalDriverActivity } from './canonical-group-activity'
import type { CanonicalGroupReplyTarget } from './canonical-group-history'
import { useCanonicalGroupLabels } from './canonical-group-labels'
import { canonicalGroupRequest } from './canonical-groups'
import type { CanonicalGroupBinding, CanonicalRoomMember } from './canonical-groups'

export const groupIsWorking = (phases: ReadonlyMap<string, unknown>, driver?: CanonicalDriverActivity) =>
  phases.size > 0 || !!driver?.working

export const restoredReply = (value: unknown): CanonicalGroupReplyTarget | null => {
  const reply = value as Partial<CanonicalGroupReplyTarget> | undefined

  return reply?.event_id && reply.member_id && typeof reply.quote === 'string'
    ? { event_id: reply.event_id, member_id: reply.member_id, quote: reply.quote, author: reply.member_id }
    : null
}

export const replyHandler = (
  features: ReadonlySet<string>, locked: boolean, reply: (target: CanonicalGroupReplyTarget) => void
) => features.has('reply_to') && !locked ? reply : undefined

/** The room's `groups.capabilities.features`, read once per mounted room; empty on a gateway that predates them. */
export function useCanonicalGroupFeatures(binding: CanonicalGroupBinding): ReadonlySet<string> {
  const [features, setFeatures] = useState<ReadonlySet<string>>(() => new Set())

  useEffect(() => {
    let cancelled = false

    void canonicalGroupRequest<{ features?: unknown }>(binding, 'groups.capabilities').then(
      result => {
        if (!cancelled && Array.isArray(result?.features)) {
          setFeatures(new Set(result.features.filter((feature): feature is string => typeof feature === 'string')))
        }
      },
      () => undefined
    )

    return () => { cancelled = true }
  }, [binding])

  return features
}

export function CanonicalGroupReplyChip({ disabled, members = [], onCancel, reply }: {
  disabled: boolean
  members?: CanonicalRoomMember[]
  onCancel: () => void
  reply: CanonicalGroupReplyTarget
}) {
  const labels = useCanonicalGroupLabels()
  const member = members.find(candidate => candidate.member_id === reply.member_id)

  return <div className="flex items-center gap-2 border-l-2 border-(--ui-accent) pl-2 text-xs" data-slot="group-reply-chip">
    <span className="min-w-0 flex-1 truncate"><strong>{labels.replyingTo} {member?.display_name || member?.handle || reply.author}</strong> {reply.quote}</span>
    <Button aria-label={labels.cancelReply} disabled={disabled} onClick={onCancel} type="button">×</Button>
  </div>
}
