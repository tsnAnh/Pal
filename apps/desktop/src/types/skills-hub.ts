/** One skill-hub source (official index, GitHub, skills.sh, …) as reported by
 *  `GET /api/skills/hub/sources`. */
export interface SkillHubSource {
  id: string
  label: string
  available?: boolean
  rate_limited?: boolean
  // False when the centralized index already covers this source, so the UI's
  // per-source search fan-out skips it (avoids redundant external API calls).
  searchable?: boolean
}

/** A searchable/installable hub skill from `GET /api/skills/hub/search`. */
export interface SkillHubResult {
  name: string
  description: string
  source: string
  identifier: string
  trust_level: string
  repo: string | null
  tags: string[]
}

export interface SkillHubInstalledEntry {
  name: string | null
  trust_level: string | null
  scan_verdict: string | null
}

export interface SkillHubSourcesResponse {
  sources: SkillHubSource[]
  index_available: boolean
  featured: SkillHubResult[]
  installed: Record<string, SkillHubInstalledEntry>
}

export interface SkillHubSearchResponse {
  results: SkillHubResult[]
  source_counts: Record<string, number>
  timed_out: string[]
  installed: Record<string, SkillHubInstalledEntry>
}

/** `GET /api/skills/hub/preview` — SKILL.md + manifest without installing. */
export interface SkillHubPreview {
  name: string
  description: string
  source: string
  identifier: string
  trust_level: string
  repo: string | null
  tags: string[]
  skill_md: string
  files: string[]
}

export interface SkillHubScanFinding {
  severity: string
  category: string
  file: string
  line: number | null
  description: string
}

/** `GET /api/skills/hub/scan` — install-time security scan verdict. */
export interface SkillHubScanResult {
  name: string
  identifier: string
  source: string
  trust_level: string
  verdict: string
  summary: string
  policy: 'allow' | 'ask' | 'block'
  policy_reason: string | null
  findings: SkillHubScanFinding[]
  severity_counts: Record<string, number>
}
