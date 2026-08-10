import { useStore } from '../store'
import { runCommand } from '../commands'
import { Icon, type IconName } from './Icon'

interface Item {
  id: string
  icon: IconName
  title: string
  run: () => void
  active?: boolean
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
      title: 'Onyx AI (Ctrl+Shift+A)',
      run: () => runCommand('ai:open'),
      active: activeType === 'ai',
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
