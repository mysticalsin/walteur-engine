import { useCallback, useMemo, useRef, useState } from 'react'
import { PRESETS } from './lib/presets'
import { formatClock, formatLongDate, totalMinutes } from './lib/format'
import { useSessions } from './lib/useSessions'
import { useTimer, type TimerApi } from './lib/useTimer'
import { BrandMark } from './lib/icons'
import { ProgressRing } from './components/ProgressRing'
import { PresetPicker } from './components/PresetPicker'
import { Controls } from './components/Controls'
import { SummaryBar } from './components/SummaryBar'
import { SessionList } from './components/SessionList'

const FINISH_EARLY_THRESHOLD_SECONDS = 60

export function App() {
  const [presetId, setPresetId] = useState<string>(PRESETS[0].id)
  const preset = useMemo(
    () => PRESETS.find((item) => item.id === presetId) ?? PRESETS[0],
    [presetId],
  )
  const { sessions, addSession } = useSessions()
  const [message, setMessage] = useState<string>('')
  const [messageTone, setMessageTone] = useState<'default' | 'done'>('default')
  const timerRef = useRef<TimerApi | null>(null)

  const handleComplete = useCallback(() => {
    addSession({ label: preset.label, minutes: preset.minutes, kind: 'completed' })
    setMessage(`${preset.label} complete · ${preset.minutes} min logged`)
    setMessageTone('done')
    timerRef.current?.reset()
  }, [addSession, preset])

  const timer = useTimer(preset.minutes * 60, handleComplete)
  timerRef.current = timer

  const idle = timer.status === 'idle' || timer.status === 'completed'
  const canFinishEarly =
    (timer.status === 'running' || timer.status === 'paused') &&
    timer.elapsed >= FINISH_EARLY_THRESHOLD_SECONDS

  const selectPreset = useCallback(
    (id: string) => {
      const next = PRESETS.find((item) => item.id === id)
      if (!next) return
      setPresetId(id)
      timer.setDuration(next.minutes * 60)
      setMessage('')
      setMessageTone('default')
    },
    [timer],
  )

  const handleStart = useCallback(() => {
    timer.start()
    setMessage(`Focusing on ${preset.label}`)
    setMessageTone('default')
  }, [preset.label, timer])

  const handlePause = useCallback(() => {
    timer.pause()
    setMessage('Paused')
    setMessageTone('default')
  }, [timer])

  const handleReset = useCallback(() => {
    timer.reset()
    setMessage('')
    setMessageTone('default')
  }, [timer])

  const handleFinish = useCallback(() => {
    const minutes = Math.max(1, Math.round(timer.elapsed / 60))
    addSession({ label: preset.label, minutes, kind: 'early' })
    setMessage(`Saved ${minutes} min of ${preset.label}`)
    setMessageTone('done')
    timer.reset()
  }, [addSession, preset.label, timer])

  const fraction = timer.duration > 0 ? timer.elapsed / timer.duration : 0
  const defaultMessage = `${preset.minutes}-minute ${preset.label} · ready when you are`
  const statusText = message !== '' ? message : defaultMessage

  return (
    <div className="app">
      <div className="app__inner">
        <header className="masthead">
          <div className="masthead__brand">
            <BrandMark className="brand-mark" />
            <span className="masthead__word">Cadence</span>
          </div>
          <p className="masthead__tagline">Focus in blocks. Watch the day add up.</p>
        </header>

        <main className="timer" aria-label="Focus timer">
          <div className="timer__ring-wrap">
            <ProgressRing fraction={fraction} done={timer.status === 'completed'} />
            <div className="timer__readout">
              <span className="timer__clock">{formatClock(timer.remaining)}</span>
              <span className="timer__phase">{preset.label}</span>
            </div>
          </div>

          <p
            className={messageTone === 'done' ? 'status status--done' : 'status'}
            role="status"
            aria-live="polite"
          >
            {statusText}
          </p>

          <PresetPicker
            presets={PRESETS}
            activeId={preset.id}
            disabled={!idle}
            onSelect={selectPreset}
          />

          <Controls
            status={timer.status}
            canFinishEarly={canFinishEarly}
            onStart={handleStart}
            onPause={handlePause}
            onReset={handleReset}
            onFinish={handleFinish}
          />
        </main>

        <section className="today" aria-label="Today's sessions">
          <div className="today__head">
            <h2 className="today__title">Today</h2>
            <span className="today__date">{formatLongDate(Date.now())}</span>
          </div>
          <SummaryBar sessionCount={sessions.length} minutes={totalMinutes(sessions)} />
          <SessionList sessions={sessions} />
        </section>
      </div>
    </div>
  )
}
