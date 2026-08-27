import type { Preset } from '../lib/types'

interface PresetPickerProps {
  presets: Preset[]
  activeId: string
  disabled: boolean
  onSelect: (id: string) => void
}

export function PresetPicker({ presets, activeId, disabled, onSelect }: PresetPickerProps) {
  return (
    <div className="presets" role="group" aria-label="Session length">
      {presets.map((preset) => {
        const active = preset.id === activeId
        return (
          <button
            key={preset.id}
            type="button"
            className={active ? 'preset preset--active' : 'preset'}
            aria-pressed={active}
            disabled={disabled}
            onClick={() => onSelect(preset.id)}
          >
            <span>{preset.label}</span>
            <span className="preset__mins">{preset.minutes}m</span>
          </button>
        )
      })}
    </div>
  )
}
