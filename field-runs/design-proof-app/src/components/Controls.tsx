import type { TimerStatus } from '../lib/useTimer'
import { PlayIcon, PauseIcon, ResetIcon, CheckIcon } from '../lib/icons'

interface ControlsProps {
  status: TimerStatus
  canFinishEarly: boolean
  onStart: () => void
  onPause: () => void
  onReset: () => void
  onFinish: () => void
}

export function Controls({
  status,
  canFinishEarly,
  onStart,
  onPause,
  onReset,
  onFinish,
}: ControlsProps) {
  const active = status === 'running' || status === 'paused'
  const primaryLabel = status === 'paused' ? 'Resume' : 'Start'

  return (
    <div className="controls-group">
      <div className="controls">
        {status === 'running' ? (
          <button type="button" className="btn btn--primary" onClick={onPause}>
            <PauseIcon className="btn__icon" />
            <span>Pause</span>
          </button>
        ) : (
          <button type="button" className="btn btn--primary" onClick={onStart}>
            <PlayIcon className="btn__icon" />
            <span>{primaryLabel}</span>
          </button>
        )}

        {active && canFinishEarly ? (
          <button type="button" className="btn btn--ghost" onClick={onFinish}>
            <CheckIcon className="btn__icon" />
            <span>Finish early</span>
          </button>
        ) : null}
      </div>

      {active ? (
        <button type="button" className="btn btn--danger" onClick={onReset}>
          <ResetIcon className="btn__icon" />
          <span>Reset</span>
        </button>
      ) : null}
    </div>
  )
}
