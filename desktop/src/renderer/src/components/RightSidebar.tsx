/**
 * Right sidebar: backlinks (+ unlinked mentions), outline, properties, tags,
 * and the Onyx-specific Todo and Calendar panes.
 */

import { useEffect, useMemo, useState } from 'react'
import type { Backlink } from '@shared/types'
import { useStore, type RightPanel } from '../store'
import { Icon, type IconName } from './Icon'
import { Resizer } from './Resizer'
import { TagsPane } from './LeftSidebar'
import { TodoPane } from './TodoPane'
import { CalendarPane } from './CalendarPane'
import { extractHeadings, extractFrontmatterProperties } from '@shared/parse'
import { stem } from '../lib/notes'

const TABS: Array<{ id: RightPanel; icon: IconName; title: string }> = [
  { id: 'backlinks', icon: 'link', title: 'Backlinks' },
  { id: 'outline', icon: 'list', title: 'Outline' },
  { id: 'properties', icon: 'info', title: 'Properties' },
  { id: 'tags', icon: 'tag', title: 'Tags' },
  { id: 'todo', icon: 'check', title: 'Todo' },
  { id: 'calendar', icon: 'calendar', title: 'Calendar' },
]

export function RightSidebar(): JSX.Element {
  const panel = useStore((s) => s.rightPanel)
  const width = useStore((s) => s.rightWidth)
  const setPanel = useStore((s) => s.setRightPanel)
  const setWidth = useStore((s) => s.setRightWidth)

  return (
    <div className="sidebar right" style={{ width, flex: `0 0 ${width}px` }}>
      <Resizer edge="left" value={width} onChange={setWidth} />
      <div className="sidebar-tabs">
        {TABS.map((t) => (
          <button
            key={t.id}
            className={`sidebar-tab${panel === t.id ? ' is-active' : ''}`}
            title={t.title}
            onClick={() => setPanel(t.id)}
          >
            <Icon name={t.icon} size={15} />
          </button>
        ))}
      </div>
      <div className="sidebar-body">
        {panel === 'backlinks' && <BacklinksPane />}
        {panel === 'outline' && <OutlinePane />}
        {panel === 'properties' && <PropertiesPane />}
        {panel === 'tags' && <TagsPane />}
        {panel === 'todo' && <TodoPane />}
        {panel === 'calendar' && <CalendarPane />}
      </div>
    </div>
  )
}

// -------------------------------------------------------------- backlinks

function BacklinksPane(): JSX.Element {
  const path = useStore((s) => s.activeTab()?.path ?? null)
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const [linked, setLinked] = useState<Array<{ path: string; title: string }>>([])
  const [unlinked, setUnlinked] = useState<Backlink[]>([])
  const [showUnlinked, setShowUnlinked] = useState(false)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!path) {
      setLinked([])
      setUnlinked([])
      return
    }
    void window.onyx.vault.backlinks(path).then(setLinked)
  }, [path, notes])

  useEffect(() => {
    if (!path || !showUnlinked) return
    setBusy(true)
    void window.onyx.search
      .unlinked(path)
      .then(setUnlinked)
      .finally(() => setBusy(false))
  }, [path, showUnlinked, notes])

  if (!path) return <div className="empty-note">Open a note to see its backlinks.</div>

  return (
    <div>
      <div className="pane-title">
        <span>Linked mentions</span>
        <span className="count" style={{ color: 'var(--fg-subtle)' }}>
          {linked.length}
        </span>
      </div>
      <div className="list-pane">
        {!linked.length && <div className="empty-note">No backlinks yet.</div>}
        {linked.map((b) => (
          <div className="list-row" key={b.path} onClick={() => void openFile(b.path)}>
            <Icon name="link" size={12} />
            <span className="label">{b.title}</span>
          </div>
        ))}
      </div>

      <div
        className="pane-title"
        style={{ cursor: 'default' }}
        onClick={() => setShowUnlinked(!showUnlinked)}
      >
        <span>
          <Icon name={showUnlinked ? 'chevronDown' : 'chevronRight'} size={11} /> Unlinked mentions
        </span>
        {busy && <span className="spinner" />}
      </div>
      {showUnlinked && (
        <div className="list-pane">
          {!busy && !unlinked.length && <div className="empty-note">No unlinked mentions.</div>}
          {unlinked.map((u) => (
            <div key={u.path}>
              <div className="list-row" onClick={() => void openFile(u.path)}>
                <span className="label">{u.title}</span>
                <span className="count">{u.contexts.length}</span>
              </div>
              {u.contexts.map((c, i) => (
                <div className="search-match" key={i} onClick={() => void openFile(u.path)}>
                  {c.text.slice(0, 140)}
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------- outline

function OutlinePane(): JSX.Element {
  const tab = useStore((s) => s.activeTab())
  const content = useStore((s) => (tab?.path ? s.docs.get(tab.path)?.content : undefined))

  const headings = useMemo(() => (content ? extractHeadings(content) : []), [content])
  if (!tab?.path) return <div className="empty-note">Open a note to see its outline.</div>

  const min = headings.length ? Math.min(...headings.map((h) => h.level)) : 1

  return (
    <div>
      <div className="pane-title">Outline</div>
      <div className="list-pane">
        {!headings.length && <div className="empty-note">No headings in this note.</div>}
        {headings.map((h, i) => (
          <div
            className="list-row outline-row"
            key={i}
            style={{ '--depth': h.level - min } as React.CSSProperties}
            onClick={() => {
              // Scroll the rendered view / editor to the heading's line.
              const view = document.querySelector('.markdown-view')
              const cm = view?.querySelector('.cm-content')
              if (cm) {
                const lineEl = cm.children[h.line] as HTMLElement | undefined
                lineEl?.scrollIntoView({ block: 'center', behavior: 'smooth' })
              } else if (view) {
                const target = [...view.querySelectorAll('h1,h2,h3,h4,h5,h6')].find(
                  (el) => el.textContent?.trim() === h.text,
                )
                target?.scrollIntoView({ block: 'center', behavior: 'smooth' })
              }
            }}
          >
            <span className="label" style={{ fontWeight: h.level <= 2 ? 600 : 400 }}>
              {h.text}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}

// ------------------------------------------------------------- properties

function PropertiesPane(): JSX.Element {
  const tab = useStore((s) => s.activeTab())
  const content = useStore((s) => (tab?.path ? s.docs.get(tab.path)?.content : undefined))
  const meta = useStore((s) => (tab?.path ? s.notes.get(tab.path) : undefined))
  const props = useMemo(() => (content ? extractFrontmatterProperties(content) : []), [content])

  if (!tab?.path) return <div className="empty-note">Open a note to see its properties.</div>

  return (
    <div>
      <div className="pane-title">Properties</div>
      <div style={{ padding: '0 10px 10px' }}>
        {!props.length && (
          <div className="empty-note" style={{ padding: '6px 2px' }}>
            No frontmatter properties.
          </div>
        )}
        {props.length > 0 && (
          <div className="properties">
            {props.map(([k, vs]) => (
              <div className="properties-row" key={k}>
                <div className="properties-key">{k}</div>
                <div className="properties-val">
                  {vs.length ? (
                    vs.map((v, i) => (
                      <span className="prop-chip" key={i}>
                        {v}
                      </span>
                    ))
                  ) : (
                    <span style={{ color: 'var(--fg-subtle)' }}>—</span>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="pane-title">File</div>
      <div className="list-pane">
        <Row label="Path" value={tab.path} />
        <Row label="Words" value={String(meta?.wordCount ?? 0)} />
        <Row label="Characters" value={String(content?.length ?? 0)} />
        <Row label="Tags" value={meta?.tags.map((t) => `#${t}`).join(' ') || '—'} />
        <Row label="Aliases" value={meta?.aliases.join(', ') || '—'} />
        <Row
          label="Modified"
          value={meta ? new Date(meta.mtime).toLocaleString() : '—'}
        />
      </div>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }): JSX.Element {
  return (
    <div className="list-row" style={{ cursor: 'default' }}>
      <span style={{ color: 'var(--fg-subtle)', minWidth: 84 }}>{label}</span>
      <span className="label" title={value}>
        {value}
      </span>
    </div>
  )
}

export { stem }
