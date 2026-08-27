export interface Preset {
  id: string
  label: string
  minutes: number
}

export type SessionKind = 'completed' | 'early'

export interface Session {
  id: string
  label: string
  minutes: number
  completedAt: number
  kind: SessionKind
}
