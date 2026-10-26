import { useStore } from '@nanostores/react'
import { useEffect, useState } from 'react'

import { getStatus } from '@/hermes'
import { evaluateRuntimeReadiness, type RuntimeReadinessResult } from '@/lib/runtime-readiness'
import { requestGatewayForProfile } from '@/store/gateway'
import { $activeGatewayProfile } from '@/store/profile'
import type { StatusResponse } from '@/types/hermes'

interface GatewayMenuSnapshot {
  inferenceStatus: RuntimeReadinessResult | null
  statusSnapshot: StatusResponse | null
}

const EMPTY: GatewayMenuSnapshot = { inferenceStatus: null, statusSnapshot: null }

export function useGatewayMenuSnapshot(gatewayState: string): GatewayMenuSnapshot {
  const profile = useStore($activeGatewayProfile)
  const [snapshot, setSnapshot] = useState<GatewayMenuSnapshot>(EMPTY)

  useEffect(() => {
    let cancelled = false

    setSnapshot(EMPTY)

    void Promise.allSettled([
      getStatus(),
      gatewayState === 'open'
        ? evaluateRuntimeReadiness((method, params) => requestGatewayForProfile(profile, method, params))
        : Promise.resolve(null)
    ]).then(([status, inference]) => {
      if (cancelled) {
        return
      }

      setSnapshot({
        inferenceStatus:
          inference.status === 'fulfilled' && inference.value?.source !== 'fallback' ? inference.value : null,
        statusSnapshot: status.status === 'fulfilled' ? status.value : null
      })
    })

    return () => {
      cancelled = true
    }
  }, [gatewayState, profile])

  return snapshot
}
