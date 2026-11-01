import {
  SiAlibabacloud,
  SiClaude,
  SiDeepseek,
  SiGithubcopilot,
  SiGooglegemini,
  SiHuggingface,
  SiKimi,
  SiLmstudio,
  SiMinimax,
  SiMistralai,
  SiMoonshotai,
  SiNvidia,
  SiOllama,
  SiOpencode,
  SiOpenrouter,
  SiPerplexity,
  SiQwen,
  SiVercel,
  SiXiaomi
} from '@icons-pack/react-simple-icons'
import { IconBrandOpenai } from '@tabler/icons-react'
import type { ComponentType, ReactNode } from 'react'

import { cn } from '@/lib/utils'

type ProviderIcon = ComponentType<{ 'aria-hidden'?: boolean; className?: string; title?: string }>

const ClaudeMark: ProviderIcon = ({ className }) => (
  <SiClaude aria-hidden className={cn('text-[#d97757]', className)} title="" />
)

const OpenAiMark: ProviderIcon = ({ className }) => <IconBrandOpenai aria-hidden className={className} stroke={1.75} />

const PROVIDER_ICONS: Record<string, ProviderIcon> = {
  alibaba: SiAlibabacloud,
  anthropic: ClaudeMark,
  claude: ClaudeMark,
  copilot: SiGithubcopilot,
  deepseek: SiDeepseek,
  gemini: SiGooglegemini,
  google: SiGooglegemini,
  huggingface: SiHuggingface,
  kimi: SiKimi,
  lmstudio: SiLmstudio,
  minimax: SiMinimax,
  mistral: SiMistralai,
  moonshot: SiMoonshotai,
  nvidia: SiNvidia,
  ollama: SiOllama,
  openai: OpenAiMark,
  opencode: SiOpencode,
  openrouter: SiOpenrouter,
  perplexity: SiPerplexity,
  qwen: SiQwen,
  vercel: SiVercel,
  vertex: SiGooglegemini,
  xiaomi: SiXiaomi
}

export function resolveProviderIcon(provider: string): null | ProviderIcon {
  const slug = provider.trim().toLowerCase()

  if (!slug) {
    return null
  }

  const family = slug.split(/[-_/:]/, 1)[0]

  return PROVIDER_ICONS[slug] ?? PROVIDER_ICONS[family] ?? null
}

export function ProviderBrandIcon({
  className,
  fallback = null,
  provider
}: {
  className?: string
  fallback?: ReactNode
  provider: string
}) {
  const Icon = resolveProviderIcon(provider)

  return Icon ? (
    <Icon aria-hidden className={cn('shrink-0', className)} title="" />
  ) : (
    fallback
  )
}
