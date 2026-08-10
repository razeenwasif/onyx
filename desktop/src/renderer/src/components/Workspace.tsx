/** Panes, tab bars, and the view router. */

import { useState } from 'react'
import { useStore, type Pane, type Tab } from '../store'
import { Icon } from './Icon'
import { runCommand } from '../commands'
import { MarkdownView } from '../editor/MarkdownView'
import { GraphView } from '../graph/GraphView'
import { CanvasView } from '../canvas/CanvasView'
import { DatabaseView } from './DatabaseView'
import { SearchPane } from './LeftSidebar'
import { DriveView } from './DriveView'
import { AIView } from './AIView'
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
  const setActiveTab = useStore((s) => s.setActiveTab)
  const closeTab = useStore((s) => s.closeTab)
  const moveTab = useStore((s) => s.moveTab)
  const docs = useStore((s) => s.docs)
  const [dropIndex, setDropIndex] = useState<number | null>(null)

  const active = pane.tabs.find((t) => t.id === pane.activeTabId) ?? pane.tabs[0]

  return (
    <div
      className={`pane${pane.id === activePaneId ? ' is-active' : ''}${zen ? ' is-zen' : ''}`}
      onMouseDown={() => useStore.setState({ activePaneId: pane.id })}
    >
      <div className="tabbar">
        <div className="tabbar-tabs">
          {pane.tabs.map((tab, i) => (
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
                  const { pane: from, tab: id } = JSON.parse(
                    e.dataTransfer.getData('text/onyx-tab'),
                  ) as { pane: string; tab: string }
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
              <span className="tab-title">{tab.title}</span>
              {tab.path && docs.get(tab.path)?.dirty ? (
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
          ))}
          <button
            className="icon-btn"
            style={{ margin: '4px' }}
            title="New tab"
            onClick={() => useStore.getState().openView('empty')}
          >
            <Icon name="plus" size={14} />
          </button>
        </div>
        <TabActions pane={pane} tab={active} />
      </div>
      <div className="view">{active ? <ViewFor tab={active} /> : null}</div>
    </div>
  )
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
      return <EmptyView />
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

function EmptyView(): JSX.Element {
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const recent = [...notes.values()].sort((a, b) => b.mtime - a.mtime).slice(0, 5)

  return (
    <div className="view-empty">
      <div style={{ textAlign: 'center' }}>
        <div style={{ fontSize: 15, marginBottom: 4 }}>No file is open</div>
        <div className="actions">
          <button onClick={() => runCommand('file:new')}>Create new note</button>
          <button onClick={() => runCommand('switcher:open')}>Go to file…</button>
          <button onClick={() => runCommand('graph:open')}>Open graph view</button>
          <button onClick={() => runCommand('file:daily')}>Open today's daily note</button>
        </div>
        {recent.length > 0 && (
          <>
            <div style={{ marginTop: 22, fontSize: 11, textTransform: 'uppercase', letterSpacing: '.05em' }}>
              Recent
            </div>
            <div className="actions">
              {recent.map((n) => (
                <button key={n.path} onClick={() => void openFile(n.path)}>
                  {stem(n.path)}
                </button>
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  )
}
