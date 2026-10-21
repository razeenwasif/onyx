/** Panes, tab bars, and the view router. */

import { useLayoutEffect, useRef, useState } from 'react'
import { useStore, type Pane, type Tab } from '../store'
import { Icon, type IconName } from './Icon'
import { runCommand } from '../commands'
import { MarkdownView } from '../editor/MarkdownView'
import { GraphView } from '../graph/GraphView'
import { CanvasView } from '../canvas/CanvasView'
import { DatabaseView } from './DatabaseView'
import { SearchPane } from './LeftSidebar'
import { TodayView } from './TodayView'
import { DriveView } from './DriveView'
import { AIView } from './AIView'
import { AgentView } from './AgentView'
import { assetUrl } from '../lib/assets'
import { stem } from '../lib/notes'

export function Workspace(): JSX.Element {
  const panes = useStore((s) => s.panes)
  const zen = useStore((s) => s.zenPaneId)
  const shown = zen ? panes.filter((p) => p.id === zen) : panes

  return (
    <div className="workspace">
      {shown.map((pane) => (
        <PaneView key={pane.id} pane={pane} zen={pane.id === zen} />
      ))}
    </div>
  )
}

function PaneView({ pane, zen }: { pane: Pane; zen: boolean }): JSX.Element {
  const activePaneId = useStore((s) => s.activePaneId)
  const active = pane.tabs.find((t) => t.id === pane.activeTabId) ?? pane.tabs[0]

  return (
    <div
      className={`pane${pane.id === activePaneId ? ' is-active' : ''}${zen ? ' is-zen' : ''}`}
      onMouseDown={() => useStore.setState({ activePaneId: pane.id })}
    >
      <div className="tabbar">
        <TabStrip pane={pane} />
        <TabActions pane={pane} tab={active} />
      </div>
      <div className="view">{active ? <ViewFor tab={active} /> : null}</div>
    </div>
  )
}

/**
 * A pane's tabs at their full titles (up to a cap). Tabs that don't fit go
 * into a "+N" menu at the end, the open tab always staying in view. A
 * hidden copy of the strip measures every tab, so the split is exact.
 */
function TabStrip({ pane }: { pane: Pane }): JSX.Element {
  const setActiveTab = useStore((s) => s.setActiveTab)
  const closeTab = useStore((s) => s.closeTab)
  const moveTab = useStore((s) => s.moveTab)
  const docs = useStore((s) => s.docs)
  const [dropIndex, setDropIndex] = useState<number | null>(null)
  const [shown, setShown] = useState<Set<string> | null>(null)
  const [menu, setMenu] = useState<{ left: number; top: number } | null>(null)
  const stripRef = useRef<HTMLDivElement>(null)
  const measureRef = useRef<HTMLDivElement>(null)
  const titles = pane.tabs.map((t) => t.title).join('\u0000')

  useLayoutEffect(() => {
    const strip = stripRef.current
    const measure = measureRef.current
    if (!strip || !measure) return
    const fit = (): void => {
      const widths = [...measure.children].map((el) => (el as HTMLElement).offsetWidth)
      const gap = parseFloat(getComputedStyle(strip).columnGap) || 0
      const plus = 40 + gap // the New tab button
      const more = 64 + gap // the "+N" button
      const room = strip.clientWidth - plus
      const total = widths.reduce((a, w) => a + w + gap, 0)
      if (total <= room) {
        setShown(null)
        return
      }
      const keep: number[] = []
      let used = 0
      for (let i = 0; i < widths.length; i++) {
        if (used + widths[i] + gap > room - more) break
        keep.push(i)
        used += widths[i] + gap
      }
      const activeIndex = pane.tabs.findIndex((t) => t.id === pane.activeTabId)
      if (activeIndex >= 0 && !keep.includes(activeIndex)) {
        while (keep.length && used + widths[activeIndex] + gap > room - more) {
          used -= widths[keep.pop()!] + gap
        }
        keep.push(activeIndex)
      }
      setShown(new Set(keep.map((i) => pane.tabs[i].id)))
    }
    fit()
    const observer = new ResizeObserver(fit)
    observer.observe(strip)
    return () => observer.disconnect()
  }, [titles, pane.tabs, pane.activeTabId])

  const hidden = shown ? pane.tabs.filter((t) => !shown.has(t.id)) : []
  const dirty = (tab: Tab): boolean => !!(tab.path && docs.get(tab.path)?.dirty)

  return (
    <div className="tabbar-tabs" ref={stripRef}>
      {pane.tabs.map((tab, i) =>
        shown && !shown.has(tab.id) ? null : (
          <div
            key={tab.id}
            className={`tab${tab.id === pane.activeTabId ? ' is-active' : ''}${dropIndex === i ? ' is-active' : ''}`}
            draggable
            onDragStart={(e) => {
              e.dataTransfer.setData('text/onyx-tab', JSON.stringify({ pane: pane.id, tab: tab.id }))
            }}
            onDragOver={(e) => {
              e.preventDefault()
              setDropIndex(i)
            }}
            onDragLeave={() => setDropIndex(null)}
            onDrop={(e) => {
              e.preventDefault()
              setDropIndex(null)
              try {
                const { pane: from, tab: id } = JSON.parse(e.dataTransfer.getData('text/onyx-tab')) as {
                  pane: string
                  tab: string
                }
                moveTab(from, id, pane.id, i)
              } catch {
                /* not a tab drag */
              }
            }}
            onMouseDown={(e) => {
              if (e.button === 1) {
                e.preventDefault()
                closeTab(pane.id, tab.id)
                return
              }
              setActiveTab(pane.id, tab.id)
            }}
            title={tab.path ?? tab.title}
          >
            <Icon name={tabIcon(tab)} size={13} className="tab-icon" />
            <span className="tab-title">{tab.title}</span>
            {dirty(tab) ? (
              <span className="dirty-dot" />
            ) : (
              <span
                className="tab-close"
                onMouseDown={(e) => {
                  e.stopPropagation()
                  closeTab(pane.id, tab.id)
                }}
              >
                <Icon name="close" size={12} />
              </span>
            )}
          </div>
        ),
      )}
      {hidden.length > 0 && (
        <div className="tab-more">
          <button
            type="button"
            className={`tab-more-btn${menu ? ' is-open' : ''}`}
            title={`${hidden.length} more tab${hidden.length === 1 ? '' : 's'}`}
            onClick={(e) => {
              const r = e.currentTarget.getBoundingClientRect()
              setMenu(menu ? null : { left: Math.max(8, Math.min(r.left, window.innerWidth - 368)), top: r.bottom + 6 })
            }}
          >
            +{hidden.length}
            <Icon name="chevronDown" size={11} />
          </button>
          {menu && (
            <>
              <div style={{ position: 'fixed', inset: 0, zIndex: 90 }} onClick={() => setMenu(null)} />
              <div className="context-menu tab-more-menu" style={menu}>
                {hidden.map((tab) => (
                  <button
                    key={tab.id}
                    type="button"
                    title={tab.path ?? tab.title}
                    onClick={() => {
                      setMenu(null)
                      setActiveTab(pane.id, tab.id)
                    }}
                  >
                    <Icon name={tabIcon(tab)} size={13} />
                    <span className="tab-more-title">{tab.title}</span>
                    {tab.path && tab.path.includes('/') && (
                      <span className="tab-more-folder">{tab.path.split('/').slice(0, -1).join('/')}</span>
                    )}
                    {dirty(tab) && <span className="dirty-dot" />}
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      )}
      <button
        className="icon-btn tab-new"
        title="New tab"
        onClick={() => useStore.getState().openView('empty')}
      >
        <Icon name="plus" size={14} />
      </button>
      {/* Every tab at its natural width, out of sight, for measuring. */}
      <div className="tabbar-measure" ref={measureRef} aria-hidden="true">
        {pane.tabs.map((tab) => (
          <div key={tab.id} className="tab">
            <Icon name={tabIcon(tab)} size={13} className="tab-icon" />
            <span className="tab-title">{tab.title}</span>
            <span className="tab-close" />
          </div>
        ))}
      </div>
    </div>
  )
}

/** A small icon for what a tab shows. */
function tabIcon(tab: Tab): IconName {
  switch (tab.type) {
    case 'empty':
      return 'calendar'
    case 'graph':
    case 'localgraph':
      return 'graph'
    case 'canvas':
      return 'canvas'
    case 'ai':
      return 'bot'
    case 'agent':
      return 'sparkle'
    case 'drive':
      return 'cloud'
    case 'database':
      return 'list'
    case 'search':
      return 'search'
    default:
      return 'note'
  }
}

function TabActions({ pane, tab }: { pane: Pane; tab: Tab | undefined }): JSX.Element {
  const setTabMode = useStore((s) => s.setTabMode)
  const navigate = useStore((s) => s.navigate)
  const toggleZen = useStore((s) => s.toggleZen)
  const splitPane = useStore((s) => s.splitPane)
  const closePane = useStore((s) => s.closePane)
  const panes = useStore((s) => s.panes)
  const bookmarks = useStore((s) => s.bookmarks)
  const [menu, setMenu] = useState(false)

  const isMarkdown = tab?.type === 'markdown'
  const mode = tab?.mode ?? 'livePreview'

  return (
    <div className="tabbar-actions">
      <button
        className="icon-btn"
        title="Back (Alt+←)"
        disabled={!tab || tab.historyIndex <= 0}
        onClick={() => navigate(-1)}
      >
        <Icon name="chevronLeft" size={14} />
      </button>
      <button
        className="icon-btn"
        title="Forward (Alt+→)"
        disabled={!tab || tab.historyIndex >= tab.history.length - 1}
        onClick={() => navigate(1)}
      >
        <Icon name="chevronRight" size={14} />
      </button>
      {isMarkdown && (
        <button
          className={`icon-btn${mode === 'reading' ? ' is-active' : ''}`}
          title={mode === 'reading' ? 'Edit (Ctrl+E)' : 'Reading view (Ctrl+E)'}
          onClick={() => setTabMode(tab!.id, mode === 'reading' ? 'livePreview' : 'reading')}
        >
          <Icon name={mode === 'reading' ? 'edit' : 'book'} size={14} />
        </button>
      )}
      <button className="icon-btn" title="Split right (Ctrl+\)" onClick={() => splitPane()}>
        <Icon name="split" size={14} />
      </button>
      <button className="icon-btn" title="Focus this pane (Ctrl+F)" onClick={() => toggleZen(pane.id)}>
        <Icon name="maximize" size={14} />
      </button>
      <div style={{ position: 'relative' }}>
        <button className="icon-btn" title="More options" onClick={() => setMenu(!menu)}>
          <Icon name="more" size={14} />
        </button>
        {menu && (
          <>
            <div style={{ position: 'fixed', inset: 0, zIndex: 90 }} onClick={() => setMenu(false)} />
            <div
              className="context-menu"
              style={{ right: 6, top: 32, left: 'auto', position: 'absolute', zIndex: 91 }}
            >
              {isMarkdown && (
                <>
                  <button
                    onClick={() => {
                      setTabMode(tab!.id, 'livePreview')
                      setMenu(false)
                    }}
                  >
                    Live preview
                  </button>
                  <button
                    onClick={() => {
                      setTabMode(tab!.id, 'source')
                      setMenu(false)
                    }}
                  >
                    Source mode
                  </button>
                  <button
                    onClick={() => {
                      setTabMode(tab!.id, 'reading')
                      setMenu(false)
                    }}
                  >
                    Reading view
                  </button>
                  <div className="sep" />
                  <button
                    onClick={() => {
                      runCommand('graph:local')
                      setMenu(false)
                    }}
                  >
                    Open local graph
                  </button>
                  <button
                    onClick={() => {
                      runCommand('bookmark:toggle')
                      setMenu(false)
                    }}
                  >
                    {tab?.path && bookmarks.includes(tab.path) ? 'Remove bookmark' : 'Bookmark'}
                  </button>
                  <button
                    onClick={() => {
                      runCommand('file:rename')
                      setMenu(false)
                    }}
                  >
                    Rename…
                  </button>
                  <button
                    onClick={() => {
                      if (tab?.path) void window.onyx.file.reveal(tab.path)
                      setMenu(false)
                    }}
                  >
                    Show in system explorer
                  </button>
                  <div className="sep" />
                  <button
                    className="danger"
                    onClick={() => {
                      runCommand('file:delete')
                      setMenu(false)
                    }}
                  >
                    Delete note
                  </button>
                </>
              )}
              {panes.length > 1 && (
                <>
                  <div className="sep" />
                  <button
                    onClick={() => {
                      closePane(pane.id)
                      setMenu(false)
                    }}
                  >
                    Close this pane
                  </button>
                </>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  )
}

function ViewFor({ tab }: { tab: Tab }): JSX.Element {
  switch (tab.type) {
    case 'markdown':
      return <MarkdownView tab={tab} />
    case 'graph':
      return <GlobalGraph />
    case 'localgraph':
      return <LocalGraph tab={tab} />
    case 'canvas':
      return <CanvasView tab={tab} />
    case 'database':
      return <DatabaseView tab={tab} />
    case 'ai':
      return <AIView tab={tab} />
    case 'agent':
      return <AgentView tab={tab} />
    case 'drive':
      return <DriveView tab={tab} />
    case 'search':
      return (
        <div className="markdown-view">
          <div style={{ maxWidth: 820, margin: '0 auto', padding: '8px 16px' }}>
            <SearchPane initial={tab.state.initial as string | undefined} />
          </div>
        </div>
      )
    case 'image':
      return <ImageView path={tab.path!} />
    case 'pdf':
      return <PdfView path={tab.path!} />
    default:
      return <TodayView />
  }
}

/** The global graph highlights whichever note you were last reading. */
function GlobalGraph(): JSX.Element {
  const focus = useStore((s) => s.lastNotePath)
  return <GraphView focusPath={focus} local={false} />
}

/** The local graph follows the most recently focused markdown tab. */
function LocalGraph({ tab }: { tab: Tab }): JSX.Element {
  const fallback = useStore((s) => {
    for (const pane of s.panes) {
      const t = pane.tabs.find((x) => x.id === pane.activeTabId)
      if (t?.type === 'markdown' && t.path) return t.path
    }
    return s.lastNotePath
  })
  return <GraphView focusPath={tab.path ?? fallback} local />
}

function ImageView({ path }: { path: string }): JSX.Element {
  const url = assetUrl(path)
  return (
    <div className="markdown-view" style={{ display: 'grid', placeItems: 'center' }}>
      {url ? (
        <img src={url} alt={path} style={{ maxWidth: '90%', maxHeight: '90%' }} />
      ) : (
        <span className="spinner" />
      )}
    </div>
  )
}

function PdfView({ path }: { path: string }): JSX.Element {
  const url = assetUrl(path)
  return url ? (
    <iframe title={path} src={url} style={{ border: 'none', width: '100%', height: '100%' }} />
  ) : (
    <div className="view-empty">
      <span className="spinner" />
    </div>
  )
}

