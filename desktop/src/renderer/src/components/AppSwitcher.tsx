import { useEffect, useState } from 'react'



/** The iPad's marks for the two apps (SF Symbols atom and pencil.and.scribble), as line icons. */
function AtomMark(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" aria-hidden="true">
      <circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" />
      <ellipse cx="12" cy="12" rx="10" ry="4" />
      <ellipse cx="12" cy="12" rx="10" ry="4" transform="rotate(60 12 12)" />
      <ellipse cx="12" cy="12" rx="10" ry="4" transform="rotate(120 12 12)" />
    </svg>
  )
}

function ScribbleMark(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M2.5 17.5c1.6-3 3.4-5 4.4-4.4 1.2.7-1.6 4.4-.3 5.2 1.1.7 2.6-1.7 3.6-2.8" />
      <path d="M12.6 16.2 20 8.8a1.7 1.7 0 0 0-2.4-2.4l-7.4 7.4-.7 3.1z" />
    </svg>
  )
}

/**
 * The two notes apps in one window (macOS), at the left of the top bar:
 * Electron, and Scribe, whose native view covers it once chosen. Drawn as
 * on the iPad: the two marks side by side, the open one lit. Scribe draws
 * the same pair in its own sidebar to switch back.
 */
export function AppSwitcher(): JSX.Element | null {
  const [available, setAvailable] = useState(false)
  useEffect(() => {
    void window.onyx.apps.info().then((apps) => setAvailable(apps.available))
  }, [])
  if (!available) return null
  return (
    <div className="app-switcher" role="group" aria-label="Apps">
      <button className="app-switch is-current is-electron" title="Electron" aria-current="true">
        <AtomMark />
      </button>
      <button
        className="app-switch is-scribe"
        title="Switch to Scribe (Ctrl+Cmd+2)"
        aria-label="Scribe"
        onClick={() => void window.onyx.apps.switchTo('scribe')}
      >
        <ScribbleMark />
      </button>
    </div>
  )
}
