import { useCallback, useEffect, useRef, useState } from 'react'

export type TimerStatus = 'idle' | 'running' | 'paused' | 'completed'

export interface TimerApi {
  status: TimerStatus
  remaining: number
  duration: number
  elapsed: number
  start: () => void
  pause: () => void
  reset: () => void
  setDuration: (seconds: number) => void
}

interface TimerState {
  status: TimerStatus
  remaining: number
}

const TICK_MS = 250

export function useTimer(
  initialSeconds: number,
  onComplete: (completedSeconds: number) => void,
): TimerApi {
  const [duration, setDurationValue] = useState(initialSeconds)
  const [state, setState] = useState<TimerState>({ status: 'idle', remaining: initialSeconds })
  const endAtRef = useRef<number | null>(null)
  const completeRef = useRef(onComplete)
  completeRef.current = onComplete

  useEffect(() => {
    if (state.status !== 'running') return
    const id = window.setInterval(() => {
      const endAt = endAtRef.current
      if (endAt === null) return
      const remaining = Math.max(0, Math.round((endAt - Date.now()) / 1000))
      if (remaining <= 0) {
        endAtRef.current = null
        setState({ status: 'completed', remaining: 0 })
        completeRef.current(duration)
      } else {
        setState((previous) =>
          previous.remaining === remaining ? previous : { status: 'running', remaining },
        )
      }
    }, TICK_MS)
    return () => window.clearInterval(id)
  }, [state.status, duration])

  const start = useCallback(() => {
    setState((previous) => {
      const base =
        previous.status === 'completed' || previous.remaining <= 0 ? duration : previous.remaining
      endAtRef.current = Date.now() + base * 1000
      return { status: 'running', remaining: base }
    })
  }, [duration])

  const pause = useCallback(() => {
    setState((previous) => {
      if (previous.status !== 'running') return previous
      endAtRef.current = null
      return { status: 'paused', remaining: previous.remaining }
    })
  }, [])

  const reset = useCallback(() => {
    endAtRef.current = null
    setState({ status: 'idle', remaining: duration })
  }, [duration])

  const setDuration = useCallback((seconds: number) => {
    endAtRef.current = null
    setDurationValue(seconds)
    setState({ status: 'idle', remaining: seconds })
  }, [])

  const elapsed = Math.max(0, duration - state.remaining)

  return {
    status: state.status,
    remaining: state.remaining,
    duration,
    elapsed,
    start,
    pause,
    reset,
    setDuration,
  }
}
