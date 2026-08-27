interface SummaryBarProps {
  sessionCount: number
  minutes: number
}

export function SummaryBar({ sessionCount, minutes }: SummaryBarProps) {
  return (
    <div className="summary">
      <div className="summary__stat">
        <span className="summary__value">{sessionCount}</span>
        <span className="summary__label">{sessionCount === 1 ? 'Session' : 'Sessions'}</span>
      </div>
      <span className="summary__divider" aria-hidden="true" />
      <div className="summary__stat">
        <span className="summary__value">{minutes}</span>
        <span className="summary__label">Minutes focused</span>
      </div>
    </div>
  )
}
