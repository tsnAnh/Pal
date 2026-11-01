import type { ToolCallMessagePartProps } from '@assistant-ui/react'
import { useStore } from '@nanostores/react'
import type { FC } from 'react'

import { useSessionView } from '@/app/chat/session-view'
import { ToolFallback } from '@/components/assistant-ui/tool/fallback'
import { ErrorBoundary } from '@/components/error-boundary'
import { useContributions } from '@/contrib'
import { TOOL_CARD_AREA, type ToolCardContribution } from '@/lib/tool-card-renderers'

export const PluginToolCard: FC<ToolCallMessagePartProps> = props => {
  const claims = useContributions(TOOL_CARD_AREA)
  const view = useSessionView()
  const storedId = useStore(view.$storedId)
  const runtimeId = useStore(view.$runtimeId)

  const fallback = <ToolFallback {...props} />

  const claim = claims.find(candidate => {
    const tools = (candidate.data as Partial<ToolCardContribution> | undefined)?.tools

    return Array.isArray(tools) && tools.includes(props.toolName)
  })

  const render = (claim?.data as Partial<ToolCardContribution> | undefined)?.render

  if (!claim || typeof render !== 'function' || props.result === undefined || props.isError) {
    return fallback
  }

  return (
    <ErrorBoundary fallback={() => fallback} label={`contrib:${claim.id}`}>
      <ClaimedToolCard
        args={props.args}
        fallback={fallback}
        render={render}
        result={props.result}
        sessionId={storedId || runtimeId || null}
        toolCallId={props.toolCallId}
        toolName={props.toolName}
      />
    </ErrorBoundary>
  )
}

const ClaimedToolCard: FC<
  Parameters<ToolCardContribution['render']>[0] & { render: ToolCardContribution['render'] }
> = ({ render, ...props }) => <>{render(props) ?? props.fallback}</>
