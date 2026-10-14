import { useEffect, useState } from 'react'
import { useStore } from '../store'
import scribeIcon from '../assets/scribe-icon.png'
import { runCommand } from '../commands'
import { Icon, type IconName } from './Icon'

interface Item {
  id: string
  icon: IconName
  title: string
  run: () => void
  active?: boolean
}

/** Electron's mark: three open orbits capped by tag-coloured electrons. */
function ElectronMark({ className }: { className?: string }): JSX.Element {
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
 * The two notes apps in one window (macOS): Electron, on screen whenever this
 * ribbon is, and Scribe, whose native view covers it once chosen. Scribe
 * draws the same pair in its own sidebar to switch back.
 */
function AppSwitcher(): JSX.Element | null {
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

export function Ribbon(): JSX.Element {
  const leftOpen = useStore((s) => s.leftOpen)
  const rightOpen = useStore((s) => s.rightOpen)
  const sections = useStore((s) => s.sections)
  const activeType = useStore((s) => s.activeTab()?.type)
  const toggleSection = useStore((s) => s.toggleSection)
  const shown = (id: string, side: 'left' | 'right'): boolean =>
    (side === 'left' ? leftOpen : rightOpen) &&
    sections[side].some((sec) => sec.id === id && sec.visible)

  const items: Item[] = [
    {
      id: 'files',
      icon: 'files',
      title: 'Files pane',
      run: () => toggleSection('files'),
      active: shown('files', 'left'),
    },
    {
      id: 'search',
      icon: 'search',
      title: 'Search (Ctrl+Shift+F)',
      run: () => runCommand('search:open'),
      active: activeType === 'search',
    },
    {
      id: 'bookmarks',
      icon: 'star',
      title: 'Bookmarks pane',
      run: () => toggleSection('bookmarks'),
      active: shown('bookmarks', 'left'),
    },
    {
      id: 'quicknote',
      icon: 'edit',
      title: 'Quicknote pane',
      run: () => toggleSection('quicknote'),
      active: shown('quicknote', 'left'),
    },
    {
      id: 'todo',
      icon: 'check',
      title: 'Todo pane',
      run: () => toggleSection('todo'),
      active: shown('todo', 'left'),
    },
    {
      id: 'backlinks',
      icon: 'link',
      title: 'Backlinks pane',
      run: () => toggleSection('backlinks'),
      active: shown('backlinks', 'right'),
    },
    {
      id: 'graphpane',
      icon: 'target',
      title: 'Graph pane',
      run: () => toggleSection('graph'),
      active: shown('graph', 'right'),
    },
    {
      id: 'calendarpane',
      icon: 'calendar',
      title: 'Calendar pane',
      run: () => toggleSection('calendar'),
      active: shown('calendar', 'right'),
    },
  ]

  const tools: Item[] = [
    { id: 'new', icon: 'newNote', title: 'New note (Ctrl+N)', run: () => runCommand('file:new') },
    {
      id: 'graph',
      icon: 'graph',
      title: 'Open graph view (Ctrl+G)',
      run: () => runCommand('graph:open'),
      active: activeType === 'graph',
    },
    {
      id: 'canvas',
      icon: 'canvas',
      title: 'Create new canvas',
      run: () => runCommand('canvas:new'),
      active: activeType === 'canvas',
    },
    {
      id: 'daily',
      icon: 'book',
      title: "Open today's daily note",
      run: () => runCommand('file:daily'),
    },
    {
      id: 'ai',
      icon: 'bot',
      title: 'Electron AI (Ctrl+Shift+A)',
      run: () => runCommand('ai:open'),
      active: activeType === 'ai',
    },
    {
      id: 'drive',
      icon: 'cloud',
      title: 'Google Drive',
      run: () => runCommand('drive:open'),
      active: activeType === 'drive',
    },
    {
      id: 'db',
      icon: 'list',
      title: 'Open folder as database',
      run: () => runCommand('db:open'),
      active: activeType === 'database',
    },
  ]

  return (
    <div className="ribbon">
      <AppSwitcher />
      {/* The app mark; only the velvet skin shows it (styles/velvet.css), and
          only when there's no app switcher already showing it. */}
      <ElectronMark className="ribbon-logo" />
      {items.map((i) => (
        <button
          key={i.id}
          className={`ribbon-btn${i.active ? ' is-active' : ''}`}
          title={i.title}
          onClick={i.run}
        >
          <Icon name={i.icon} />
        </button>
      ))}
      <div style={{ height: 10 }} />
      {tools.map((i) => (
        <button
          key={i.id}
          className={`ribbon-btn${i.active ? ' is-active' : ''}`}
          title={i.title}
          onClick={i.run}
        >
          <Icon name={i.icon} />
        </button>
      ))}
      <div className="ribbon-spacer" />
      <button
        className="ribbon-btn"
        title="Open another vault"
        onClick={() => runCommand('vault:open')}
      >
        <Icon name="vault" />
      </button>
      <button
        className="ribbon-btn"
        title="Settings (Ctrl+,)"
        onClick={() => runCommand('settings:open')}
      >
        <Icon name="settings" />
      </button>
    </div>
  )
}
