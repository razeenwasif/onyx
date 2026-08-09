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
  const leftPanel = useStore((s) => s.leftPanel)
  const leftOpen = useStore((s) => s.leftOpen)
  const activeType = useStore((s) => s.activeTab()?.type)
  const setLeftPanel = useStore((s) => s.setLeftPanel)

  const items: Item[] = [
    {
      id: 'files',
      icon: 'files',
      title: 'Files',
      run: () => setLeftPanel('files'),
      active: leftOpen && leftPanel === 'files',
    },
    {
      id: 'search',
      icon: 'search',
      title: 'Search',
      run: () => setLeftPanel('search'),
      active: leftOpen && leftPanel === 'search',
    },
    {
      id: 'bookmarks',
      icon: 'star',
      title: 'Bookmarks',
      run: () => setLeftPanel('bookmarks'),
      active: leftOpen && leftPanel === 'bookmarks',
    },
    {
      id: 'tags',
      icon: 'tag',
      title: 'Tags',
      run: () => setLeftPanel('tags'),
      active: leftOpen && leftPanel === 'tags',
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
      icon: 'calendar',
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
