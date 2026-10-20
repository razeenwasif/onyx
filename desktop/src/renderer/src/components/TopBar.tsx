/**
 * The bar across the top of the window: the command bar's pill in the
 * middle (⌘K) and a New note button. Its empty space moves the window, as
 * the title bar would (macOS hides the native one).
 */

import { useStore } from '../store'
import { runCommand } from '../commands'
import { Icon } from './Icon'

const mod = navigator.platform.toLowerCase().includes('mac') ? '⌘' : 'Ctrl+'

export function TopBar(): JSX.Element {
  const setModal = useStore((s) => s.setModal)
  return (
    <header className="topbar">
      <button type="button" className="topbar-today" onClick={() => runCommand('today:open')}>
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
      <button type="button" className="topbar-new" onClick={() => runCommand('file:new')}>
        <Icon name="plus" size={14} />
        New note
      </button>
    </header>
  )
}
