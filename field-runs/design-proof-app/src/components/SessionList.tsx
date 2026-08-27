import type { Session } from '../lib/types'
import { formatTimeOfDay } from '../lib/format'

interface SessionListProps {
  sessions: Session[]
}

export function SessionList({ sessions }: SessionListProps) {
  if (sessions.length === 0) {
    return (
      <div className="empty">
        <p className="empty__title">No sessions yet today</p>
        <p className="empty__hint">
          Start your first focus block. Finished sessions land here so the day adds up in front of you.
        </p>
      </div>
    )
  }

  return (
    <ul className="sessions">
      {sessions.map((session) => (
        <li key={session.id} className="session">
          <span
            className={session.kind === 'early' ? 'session__dot session__dot--early' : 'session__dot'}
            aria-hidden="true"
          />
          <div className="session__body">
            <span className="session__label">{session.label}</span>
            <span className="session__meta">
              {formatTimeOfDay(session.completedAt)}
              {session.kind === 'early' ? ' · finished early' : ''}
            </span>
          </div>
          <span className="session__dur">{session.minutes} min</span>
        </li>
      ))}
    </ul>
  )
}
