import { useEffect, useState } from 'react'
import scribeIcon from '../assets/scribe-icon.png'


/** Electron's mark: three open orbits capped by tag-coloured electrons. */
export function ElectronMark({ className }: { className?: string }): JSX.Element {
  return (
    <svg className={className} viewBox="0 0 512 512" aria-hidden="true">
      <g fill="none" stroke="#63558f" strokeWidth="26" strokeLinecap="round">
        <path d="M256 184 A72 72 0 1 1 184 256" />
        <path d="M382 256 A126 126 0 1 1 256 130" />
        <path d="M256 436 A180 180 0 1 1 436 256" />
      </g>
      <circle cx="256" cy="256" r="38" fill="#a78bfa" />
      <circle cx="256" cy="184" r="26" fill="#7aa2f7" />
      <circle cx="382" cy="256" r="26" fill="#34d399" />
      <circle cx="256" cy="130" r="26" fill="#f59e0b" />
      <circle cx="256" cy="436" r="26" fill="#e0c889" />
      <circle cx="436" cy="256" r="26" fill="#f7768e" />
    </svg>
  )
}

/**
 * The two notes apps in one window (macOS), at the left of the top bar:
 * Electron, and Scribe, whose native view covers it once chosen. Scribe
 * draws the same pair in its own sidebar to switch back.
 */
export function AppSwitcher(): JSX.Element | null {
  const [available, setAvailable] = useState(false)
  useEffect(() => {
    void window.onyx.apps.info().then((apps) => setAvailable(apps.available))
  }, [])
  if (!available) return null
  return (
    <div className="app-switcher">
      <button className="app-switch is-current" title="Electron" aria-current="true">
        <ElectronMark />
      </button>
      <button
        className="app-switch"
        title="Switch to Scribe (Ctrl+Cmd+2)"
        onClick={() => void window.onyx.apps.switchTo('scribe')}
      >
        <img src={scribeIcon} alt="Scribe" draggable={false} />
      </button>
    </div>
  )
}
