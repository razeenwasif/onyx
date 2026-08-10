/**
 * The two sidebars, laid out like the Onyx TUI: a vertical stack of panes per
 * side rather than Obsidian's one-tab-at-a-time sidebar.
 *
 *   left   files · quicknote · todo        (+ bookmarks, hidden by default)
 *   right  backlinks · graph · calendar    (+ outline, tags, properties)
 *
 * Panes collapse by clicking their header, resize by dragging the divider
 * below them, and can be shown or hidden from the right-click menu on the
 * sidebar background. Everything persists.
 */

import { useEffect, useState } from 'react'
import type { SectionId } from '@shared/types'
import { useStore } from '../store'
import { Icon, type IconName } from './Icon'
import { Resizer } from './Resizer'
import { SidebarStack, type StackSection } from './SidebarStack'
import { FileExplorer, BookmarksPane, TagsPane } from './LeftSidebar'
import { BacklinksPane, OutlinePane, PropertiesPane } from './RightSidebar'
import { TodoPane, QuicknotePane } from './TodoPane'
import { CalendarPane } from './CalendarPane'
import { SidebarGraph } from '../graph/SidebarGraph'
import { runCommand } from '../commands'

const META: Record<SectionId, { title: string; icon: IconName }> = {
  files: { title: 'Files', icon: 'files' },
  bookmarks: { title: 'Bookmarks', icon: 'star' },
  quicknote: { title: 'Quicknote', icon: 'edit' },
  todo: { title: 'Todo', icon: 'check' },
  backlinks: { title: 'Backlinks', icon: 'link' },
  graph: { title: 'Graph', icon: 'graph' },
  calendar: { title: 'Calendar', icon: 'calendar' },
  outline: { title: 'Outline', icon: 'list' },
  tags: { title: 'Tags', icon: 'tag' },
  properties: { title: 'Properties', icon: 'info' },
}

function body(id: SectionId): JSX.Element {
  switch (id) {
    case 'files':
      return <FileExplorer />
    case 'bookmarks':
      return <BookmarksPane />
    case 'quicknote':
      return <QuicknotePane />
    case 'todo':
      return <TodoPane />
    case 'backlinks':
      return <BacklinksPane />
    case 'graph':
      return <SidebarGraph />
    case 'calendar':
      return <CalendarPane />
    case 'outline':
      return <OutlinePane />
    case 'tags':
      return <TagsPane />
    case 'properties':
      return <PropertiesPane />
  }
}

function actionsFor(id: SectionId): StackSection['actions'] {
  switch (id) {
    case 'files':
      return [
        { icon: 'newNote', title: 'New note', onClick: () => runCommand('file:new') },
        { icon: 'newFolder', title: 'New folder', onClick: () => runCommand('file:new-folder') },
      ]
    case 'graph':
      return [
        { icon: 'maximize', title: 'Open the full graph', onClick: () => runCommand('graph:open') },
      ]
    default:
      return undefined
  }
}

function Side({ side }: { side: 'left' | 'right' }): JSX.Element {
  const sections = useStore((s) => s.sections[side])
  const width = useStore((s) => (side === 'left' ? s.leftWidth : s.rightWidth))
  const setWidth = useStore((s) => (side === 'left' ? s.setLeftWidth : s.setRightWidth))
  const setSectionHeight = useStore((s) => s.setSectionHeight)
  const toggleCollapsed = useStore((s) => s.toggleSectionCollapsed)
  const toggleSection = useStore((s) => s.toggleSection)
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)

  useEffect(() => {
    if (!menu) return
    const close = (): void => setMenu(null)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [menu])

  const visible: StackSection[] = sections
    .filter((s) => s.visible)
    .map((s) => ({
      id: s.id,
      title: META[s.id].title,
      icon: META[s.id].icon,
      height: s.height,
      collapsed: s.collapsed,
      actions: actionsFor(s.id),
      body: body(s.id),
    }))

  return (
    <div className={`sidebar ${side}`} style={{ width, flex: `0 0 ${width}px` }}>
      {side === 'right' && <Resizer edge="left" value={width} onChange={setWidth} />}
      <SidebarStack
        sections={visible}
        onResize={setSectionHeight}
        onToggleCollapse={toggleCollapsed}
        onMenu={(x, y) => setMenu({ x, y })}
      />
      {side === 'left' && <Resizer edge="right" value={width} onChange={setWidth} />}

      {menu && (
        <div className="context-menu" style={{ left: menu.x, top: menu.y }}>
          <div className="context-label">Panes</div>
          {sections.map((s) => (
            <button key={s.id} onClick={() => toggleSection(s.id)}>
              <span style={{ width: 14, display: 'inline-block' }}>{s.visible ? '✓' : ''}</span>
              <Icon name={META[s.id].icon} size={12} />
              {META[s.id].title}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

export function LeftSidebar(): JSX.Element {
  return <Side side="left" />
}

export function RightSidebar(): JSX.Element {
  return <Side side="right" />
}
