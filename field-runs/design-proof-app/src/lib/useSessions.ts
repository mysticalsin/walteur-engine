import { useCallback, useEffect, useState } from 'react'
import type { Session, SessionKind } from './types'

const STORAGE_KEY = 'cadence.sessions.v1'

export interface SessionDraft {
  label: string
  minutes: number
  kind: SessionKind
}

function makeId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  return `s_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`
}

function isSameDay(a: number, b: number): boolean {
  const da = new Date(a)
  const db = new Date(b)
  return (
    da.getFullYear() === db.getFullYear() &&
    da.getMonth() === db.getMonth() &&
    da.getDate() === db.getDate()
  )
}

function isSession(value: unknown): value is Session {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Record<string, unknown>
  return (
    typeof candidate.id === 'string' &&
    typeof candidate.label === 'string' &&
    typeof candidate.minutes === 'number' &&
    typeof candidate.completedAt === 'number' &&
    (candidate.kind === 'completed' || candidate.kind === 'early')
  )
}

function loadSessions(): Session[] {
  if (typeof window === 'undefined') return []
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    const now = Date.now()
    return parsed.filter(isSession).filter((session) => isSameDay(session.completedAt, now))
  } catch {
    return []
  }
}

export function useSessions(): {
  sessions: Session[]
  addSession: (draft: SessionDraft) => void
} {
  const [sessions, setSessions] = useState<Session[]>(() => loadSessions())

  useEffect(() => {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(sessions))
    } catch {
      /* storage unavailable or over quota: the log simply will not persist this session */
    }
  }, [sessions])

  const addSession = useCallback((draft: SessionDraft) => {
    const session: Session = {
      id: makeId(),
      completedAt: Date.now(),
      label: draft.label,
      minutes: draft.minutes,
      kind: draft.kind,
    }
    setSessions((previous) => [session, ...previous])
  }, [])

  return { sessions, addSession }
}
