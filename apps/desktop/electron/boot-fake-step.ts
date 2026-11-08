export function bootFakeStepMs(value: string | undefined): number {
  const raw = Number.parseInt(String(value || ''), 10)

  if (!Number.isFinite(raw) || raw <= 0) {
    return 650
  }

  return Math.max(120, raw)
}
