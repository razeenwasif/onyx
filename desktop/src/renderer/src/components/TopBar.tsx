/**
 * The bar across the top of the window, which replaces the old icon strip:
 *
 *   left    Electron/Scribe switch · Today
 *   middle  the command bar's pill (⌘K)
 *   right   Graph · AI · ⋯ (canvas, database, Drive, daily note) ·
 *           Library and Context toggles · New note
 *
 * Its empty space moves the window, as the title bar would (macOS hides the
 * native one, so the bar leaves room for the traffic lights).
 */

import { useEffect, useRef, useState } from 'react'
import { useStore } from '../store'
import { runCommand } from '../commands'
import { Icon, type IconName } from './Icon'
import { AppSwitcher } from './AppSwitcher'

const isMac = navigator.platform.toLowerCase().includes('mac')
const mod = isMac ? '⌘' : 'Ctrl+'

const MORE: Array<{ command: string; icon: IconName; label: string }> = [
  { command: 'file:daily', icon: 'calendar', label: 'Daily note' },
  { command: 'canvas:new', icon: 'canvas', label: 'New canvas' },
  { command: 'db:open', icon: 'list', label: 'Database' },
  { command: 'drive:open', icon: 'cloud', label: 'Google Drive' },
  { command: 'ai:open', icon: 'bot', label: 'Local AI (Ollama)' },
]

export function TopBar(): JSX.Element {
  const setModal = useStore((s) => s.setModal)
  const leftOpen = useStore((s) => s.panelOpen('left'))
  const rightOpen = useStore((s) => s.panelOpen('right'))
  const toggleLeft = useStore((s) => s.toggleLeft)
  const toggleRight = useStore((s) => s.toggleRight)
  const view = useStore((s) => s.activeTab()?.type)

  return (
    <header className={`topbar${isMac ? ' is-mac' : ''}`}>
      <AppSwitcher />
      <button
        type="button"
        className={`topbar-today${view === 'empty' ? ' is-active' : ''}`}
        onClick={() => runCommand('today:open')}
      >
        <Icon name="calendar" size={14} />
        Today
      </button>
      <div className="topbar-centre">
        <button type="button" className="topbar-search" onClick={() => setModal({ kind: 'command' })}>
          <Icon name="search" size={15} />
          <span className="topbar-search-label">Search notes and handwriting, run a command, or ask</span>
          <kbd>{mod}K</kbd>
        </button>
      </div>
      <div className="topbar-tools">
        <ToolButton icon="graph" title="Graph view" active={view === 'graph'} onClick={() => runCommand('graph:open')} />
        <ToolButton icon="sparkle" title="Agent (⇧⌘J)" active={view === 'agent'} onClick={() => runCommand('agent:open')} />
        <MoreMenu />
        <span className="topbar-sep" aria-hidden="true" />
        <ToolButton icon="panelLeft" title="Library" active={leftOpen} onClick={toggleLeft} />
        <ToolButton icon="panelRight" title="Context" active={rightOpen} onClick={toggleRight} />
      </div>
      <button type="button" className="topbar-new" onClick={() => runCommand('file:new')}>
        <Icon name="plus" size={14} />
        New note
      </button>
    </header>
  )
}

function ToolButton({
  icon,
  title,
  active,
  onClick,
}: {
  icon: IconName
  title: string
  active?: boolean
  onClick: () => void
}): JSX.Element {
  return (
    <button
      type="button"
      className={`topbar-tool${active ? ' is-active' : ''}`}
      title={title}
      aria-label={title}
      aria-pressed={active}
      onClick={onClick}
    >
      <Icon name={icon} size={17} />
    </button>
  )
}

/** The tools used now and then, behind ⋯. */
function MoreMenu(): JSX.Element {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setOpen(false)
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', esc)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', esc)
    }
  }, [open])

  return (
    <div className="topbar-more" ref={ref}>
      <button
        type="button"
        className={`topbar-tool${open ? ' is-active' : ''}`}
        title="More"
        aria-label="More"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <Icon name="more" size={17} />
      </button>
      {open && (
        <div className="context-menu topbar-menu" role="menu">
          {MORE.map((m) => (
            <button
              key={m.command}
              type="button"
              role="menuitem"
              onClick={() => {
                setOpen(false)
                runCommand(m.command)
              }}
            >
              <Icon name={m.icon} size={14} />
              {m.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
