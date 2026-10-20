/**
 * The right-hand Context panel: one panel about the note you're reading, in
 * one of four views rather than a stack of panes competing for height.
 *
 *   Linked    notes that link here (with the line), Scribe pages linked
 *             either way, and unlinked mentions on request
 *   Outline   the note's headings
 *   Graph     the note's local graph
 *   Calendar  daily notes and events
 */

import { useEffect, useMemo, useState } from 'react'
import type { Backlink, BacklinkRef, ScribePage } from '@shared/types'
import { extractLinks } from '@shared/parse'
import { parseScribeTarget } from '@shared/scribe-link'
import { useStore, type ContextTab } from '../store'
import { runCommand } from '../commands'
import { Icon } from './Icon'
import { Resizer } from './Resizer'
import { OutlinePane } from './RightSidebar'
import { CalendarPane } from './CalendarPane'
import { GraphView } from '../graph/GraphView'

const TABS: Array<{ id: ContextTab; label: string }> = [
  { id: 'linked', label: 'Linked' },
  { id: 'outline', label: 'Outline' },
  { id: 'graph', label: 'Graph' },
  { id: 'calendar', label: 'Calendar' },
]

/** The note the panel is about: the active markdown tab, else the last one read. */
function useFocusPath(): string | null {
  return useStore((s) => {
    const pane = s.panes.find((p) => p.id === s.activePaneId)
    const tab = pane?.tabs.find((t) => t.id === pane.activeTabId)
    if (tab?.type === 'markdown' && tab.path) return tab.path
    return s.lastNotePath
  })
}

export function ContextPanel(): JSX.Element {
  const tab = useStore((s) => s.contextTab)
  const showContext = useStore((s) => s.showContext)
  const width = useStore((s) => s.rightWidth)
  const setWidth = useStore((s) => s.setRightWidth)
  const path = useFocusPath()

  return (
    <aside className="sidebar right context-panel" style={{ width, flex: `0 0 ${width}px` }} aria-label="Context">
      <Resizer edge="left" value={width} onChange={setWidth} />
      <div className="context-inner">
        <div className="context-tabs" role="tablist" aria-label="Context view">
          {TABS.map((t) => (
            <button
              key={t.id}
              type="button"
              role="tab"
              aria-selected={tab === t.id}
              className={tab === t.id ? 'is-on' : ''}
              onClick={() => showContext(t.id)}
            >
              {t.label}
            </button>
          ))}
        </div>
        <div className="context-body" role="tabpanel">
          {tab === 'linked' && (path ? <LinkedView path={path} /> : <Empty>Open a note to see what links to it.</Empty>)}
          {tab === 'outline' && <OutlinePane />}
          {tab === 'graph' &&
            (path ? (
              <div className="context-graph">
                <div className="context-graph-canvas">
                  <GraphView focusPath={path} local compact />
                </div>
                <button type="button" className="context-wide-btn" onClick={() => runCommand('graph:open')}>
                  <Icon name="maximize" size={13} />
                  Open the whole graph
                </button>
              </div>
            ) : (
              <Empty>Open a note to see its neighbourhood.</Empty>
            ))}
          {tab === 'calendar' && <CalendarPane />}
        </div>
      </div>
    </aside>
  )
}

function Empty({ children }: { children: React.ReactNode }): JSX.Element {
  return <div className="empty-note">{children}</div>
}

/** A context line with its links shown as their text, the ones to `path` marked. */
function ContextLine({ text }: { text: string }): JSX.Element {
  const parts: React.ReactNode[] = []
  let at = 0
  for (const link of extractLinks(text)) {
    if (link.start > at) parts.push(text.slice(at, link.start))
    parts.push(
      <mark key={link.start} className="context-link">
        {link.alias ?? link.target.replace(/[#^].*$/, '')}
      </mark>,
    )
    at = link.end
  }
  parts.push(text.slice(at))
  return <span className="context-line">{parts}</span>
}

function LinkedView({ path }: { path: string }): JSX.Element {
  const notes = useStore((s) => s.notes)
  const scribePages = useStore((s) => s.scribePages)
  const openFile = useStore((s) => s.openFile)
  const content = useStore((s) => s.docs.get(path)?.content ?? '')
  const [linked, setLinked] = useState<Backlink[]>([])
  const [inkLinkingHere, setInkLinkingHere] = useState<BacklinkRef[]>([])
  const [unlinked, setUnlinked] = useState<Backlink[] | null>(null)
  const [showUnlinked, setShowUnlinked] = useState(false)

  useEffect(() => {
    let stale = false
    void window.onyx.search.linked(path).then((r) => !stale && setLinked(r)).catch(() => setLinked([]))
    void window.onyx.vault
      .backlinks(path)
      .then((r) => !stale && setInkLinkingHere(r.filter((b) => b.scribe)))
      .catch(() => setInkLinkingHere([]))
    return () => {
      stale = true
    }
  }, [path, notes, scribePages])

  useEffect(() => {
    setUnlinked(null)
    setShowUnlinked(false)
  }, [path])

  useEffect(() => {
    if (!showUnlinked || unlinked) return
    void window.onyx.search.unlinked(path).then(setUnlinked).catch(() => setUnlinked([]))
  }, [showUnlinked, unlinked, path])

  // Ink both ways: pages this note links to, then pages that link here.
  const ink = useMemo(() => {
    const out: Array<{ page: ScribePage; how: string }> = []
    const seen = new Set<string>()
    for (const l of extractLinks(content)) {
      const target = parseScribeTarget(l.target)
      const page = target && scribePages.get(target.pageId)
      if (!page || seen.has(page.id)) continue
      seen.add(page.id)
      out.push({ page, how: target.area ? 'An area of it is linked here' : 'Linked from this note' })
    }
    for (const ref of inkLinkingHere) {
      const page = ref.scribe && scribePages.get(ref.scribe.id)
      if (!page || seen.has(page.id)) continue
      seen.add(page.id)
      out.push({ page, how: 'Links to this note' })
    }
    return out
  }, [content, scribePages, inkLinkingHere])

  return (
    <div className="linked-view">
      <section>
        <h3 className="context-heading">
          Linked from <span>{linked.length}</span>
        </h3>
        {!linked.length && <Empty>No notes link here yet.</Empty>}
        {linked.map((b) => (
          <button key={b.path} type="button" className="context-card" onClick={() => void openFile(b.path)}>
            <span className="context-card-title">{b.title}</span>
            {b.contexts.slice(0, 2).map((c) => (
              <ContextLine key={c.line} text={c.text} />
            ))}
          </button>
        ))}
      </section>

      {ink.length > 0 && (
        <section>
          <h3 className="context-heading">
            Ink <span>{ink.length}</span>
          </h3>
          <div className="context-ink">
            {ink.map(({ page, how }) => (
              <button
                key={page.id}
                type="button"
                className="context-ink-tile"
                title={`${page.notebook} › ${page.section}`}
                onClick={() => void window.onyx.apps.scribeOpen(page.path)}
              >
                <span className="context-ink-mark" aria-hidden="true" />
                <span className="context-card-title">{page.title}</span>
                <span className="context-ink-how">{how}</span>
              </button>
            ))}
          </div>
        </section>
      )}

      <section>
        <button
          type="button"
          className="context-wide-btn"
          aria-expanded={showUnlinked}
          onClick={() => setShowUnlinked((v) => !v)}
        >
          <Icon name={showUnlinked ? 'chevronDown' : 'chevronRight'} size={12} />
          Unlinked mentions
          {unlinked && <span className="context-count">{unlinked.length}</span>}
        </button>
        {showUnlinked && !unlinked && <Empty>Looking…</Empty>}
        {showUnlinked && unlinked && !unlinked.length && <Empty>No notes mention it without a link.</Empty>}
        {showUnlinked &&
          unlinked?.map((u) => (
            <button key={u.path} type="button" className="context-card" onClick={() => void openFile(u.path)}>
              <span className="context-card-title">{u.title}</span>
              {u.contexts.slice(0, 2).map((c) => (
                <span key={c.line} className="context-line">
                  {c.text}
                </span>
              ))}
            </button>
          ))}
      </section>
    </div>
  )
}
