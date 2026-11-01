import type { ReactNode } from 'react'

/**
 * TOOL CARDS — a plugin draws the transcript card for a HOST tool whose
 * answer needs plugin-owned UI (Bot Mode's `request_handback` needs the bot's
 * Screen pane, which core has no knowledge of).
 *
 * A finished call of a claimed tool is drawn by the plugin's `render`; a
 * running call, a failed one, and any tool nobody claims keep the built-in row.
 */

export const TOOL_CARD_AREA = 'transcript.toolCard'

/** Props handed to a tool card contribution's `render`. */
export interface ToolCardProps {
  toolName: string
  toolCallId: string
  args: Readonly<Record<string, unknown>>
  result: unknown
  /** The chat whose transcript renders this (stored id, else runtime id), or null. */
  sessionId: null | string
  /** The built-in row: return it for any call you do not draw. */
  fallback: ReactNode
}

/** Payload of a `transcript.toolCard` contribution's `data`. */
export interface ToolCardContribution {
  /** Exact tool names this card draws. */
  tools: readonly string[]
  /** Mounted inside an error boundary whose fallback is the built-in row. */
  render: (props: ToolCardProps) => ReactNode
}
