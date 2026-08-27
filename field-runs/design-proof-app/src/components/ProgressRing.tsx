interface ProgressRingProps {
  fraction: number
  done: boolean
  size?: number
  stroke?: number
}

export function ProgressRing({ fraction, done, size = 236, stroke = 14 }: ProgressRingProps) {
  const radius = (size - stroke) / 2
  const circumference = 2 * Math.PI * radius
  const clamped = Math.min(1, Math.max(0, fraction))
  const offset = circumference * (1 - clamped)
  const center = size / 2

  return (
    <svg className="ring" width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true">
      <circle className="ring__track" cx={center} cy={center} r={radius} strokeWidth={stroke} />
      <circle
        className={done ? 'ring__progress ring__progress--done' : 'ring__progress'}
        cx={center}
        cy={center}
        r={radius}
        strokeWidth={stroke}
        strokeDasharray={circumference}
        strokeDashoffset={offset}
      />
    </svg>
  )
}
