/**
 * Canvas — the infinite whiteboard, reading and writing Obsidian's open
 * JSON Canvas format (`.canvas`) so boards are interchangeable between apps.
 *
 * Supported: text cards, file cards (a note rendered inline), link cards,
 * groups, and edges with sides, arrows and labels. Pan, zoom, marquee-free
 * multi-select, drag, resize, and connect-by-dragging-a-handle.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useStore, type Tab } from '../store'
import { Icon } from './../components/Icon'
import { renderMarkdown } from '../editor/render'
import { assetUrl } from '../lib/assets'
import { stem } from '../lib/notes'

type Side = 'top' | 'right' | 'bottom' | 'left'

interface CanvasNode {
  id: string
  type: 'text' | 'file' | 'link' | 'group'
  x: number
  y: number
  width: number
  height: number
  color?: string
  text?: string
  file?: string
  url?: string
  label?: string
}

interface CanvasEdge {
  id: string
  fromNode: string
  fromSide?: Side
  toNode: string
  toSide?: Side
  color?: string
  label?: string
  toEnd?: 'none' | 'arrow'
}

interface CanvasDoc {
  nodes: CanvasNode[]
  edges: CanvasEdge[]
}

const CANVAS_COLORS: Record<string, string> = {
  '1': '#e05561',
  '2': '#e0982c',
  '3': '#e0c85c',
  '4': '#4caf50',
  '5': '#4eb3d4',
  '6': '#a882ff',
}

const uid = (): string => Math.random().toString(36).slice(2, 18)

function anchor(node: CanvasNode, side: Side): { x: number; y: number } {
  switch (side) {
    case 'top':
      return { x: node.x + node.width / 2, y: node.y }
    case 'bottom':
      return { x: node.x + node.width / 2, y: node.y + node.height }
    case 'left':
      return { x: node.x, y: node.y + node.height / 2 }
    default:
      return { x: node.x + node.width, y: node.y + node.height / 2 }
  }
}

/** Pick the pair of sides that gives the shortest, cleanest connection. */
function bestSides(a: CanvasNode, b: CanvasNode): [Side, Side] {
  const dx = b.x + b.width / 2 - (a.x + a.width / 2)
  const dy = b.y + b.height / 2 - (a.y + a.height / 2)
  if (Math.abs(dx) > Math.abs(dy)) {
    return dx > 0 ? ['right', 'left'] : ['left', 'right']
  }
  return dy > 0 ? ['bottom', 'top'] : ['top', 'bottom']
}

export function CanvasView({ tab }: { tab: Tab }): JSX.Element {
  const path = tab.path!
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const setStatus = useStore((s) => s.setStatus)

  const [doc, setDoc] = useState<CanvasDoc>({ nodes: [], edges: [] })
  const [loaded, setLoaded] = useState(false)
  const [selection, setSelection] = useState<Set<string>>(new Set())
  const [editing, setEditing] = useState<string | null>(null)
  const [view, setView] = useState({ x: 0, y: 0, scale: 1 })
  const [linking, setLinking] = useState<{ from: string; side: Side; x: number; y: number } | null>(null)
  const [embedded, setEmbedded] = useState<Map<string, string>>(new Map())

  const hostRef = useRef<HTMLDivElement>(null)
  const dragRef = useRef<{ ids: string[]; startX: number; startY: number; origins: Map<string, { x: number; y: number }> } | null>(null)
  const resizeRef = useRef<{ id: string; startX: number; startY: number; w: number; h: number } | null>(null)
  const panRef = useRef<{ x: number; y: number; vx: number; vy: number } | null>(null)
  const dirtyRef = useRef(false)

  // ------------------------------------------------------------- load/save

  /** Center and zoom so every card is visible. */
  const fitView = useCallback((nodes: CanvasNode[]) => {
    const rect = hostRef.current?.getBoundingClientRect()
    if (!rect || !nodes.length) {
      setView({ x: 0, y: 0, scale: 1 })
      return
    }
    const minX = Math.min(...nodes.map((n) => n.x))
    const minY = Math.min(...nodes.map((n) => n.y))
    const maxX = Math.max(...nodes.map((n) => n.x + n.width))
    const maxY = Math.max(...nodes.map((n) => n.y + n.height))
    const scale = Math.min(
      1.5,
      Math.max(0.1, Math.min((rect.width - 100) / (maxX - minX), (rect.height - 100) / (maxY - minY))),
    )
    setView({
      scale,
      x: rect.width / (2 * scale) - (minX + maxX) / 2,
      y: rect.height / (2 * scale) - (minY + maxY) / 2,
    })
  }, [])

  useEffect(() => {
    void (async () => {
      let next: CanvasDoc = { nodes: [], edges: [] }
      try {
        const raw = await window.onyx.file.read(path)
        const parsed = JSON.parse(raw || '{}') as Partial<CanvasDoc>
        next = { nodes: parsed.nodes ?? [], edges: parsed.edges ?? [] }
      } catch {
        /* new or unreadable canvas */
      }
      setDoc(next)
      setLoaded(true)
      // Frame the board on open, the way Obsidian does.
      requestAnimationFrame(() => fitView(next.nodes))
    })()
  }, [path, fitView])

  const save = useCallback(
    (next: CanvasDoc) => {
      setDoc(next)
      dirtyRef.current = true
      void next
    },
    [],
  )

  useEffect(() => {
    if (!loaded || !dirtyRef.current) return
    const timer = setTimeout(() => {
      dirtyRef.current = false
      void window.onyx.file.write(path, JSON.stringify(doc, null, 2)).catch(() => setStatus("Couldn't save canvas"))
    }, 500)
    return () => clearTimeout(timer)
  }, [doc, loaded, path, setStatus])

  // Preload the bodies of file cards.
  useEffect(() => {
    const files = doc.nodes.filter((n) => n.type === 'file' && n.file).map((n) => n.file!)
    let cancelled = false
    void (async () => {
      const next = new Map(embedded)
      let changed = false
      for (const f of files) {
        if (next.has(f) || !/\.(md|markdown)$/i.test(f)) continue
        try {
          next.set(f, await window.onyx.file.read(f))
          changed = true
        } catch {
          /* missing file */
        }
      }
      if (changed && !cancelled) setEmbedded(next)
    })()
    return () => {
      cancelled = true
    }
  }, [doc.nodes])

  // -------------------------------------------------------------- geometry

  const toWorld = useCallback(
    (clientX: number, clientY: number): { x: number; y: number } => {
      const rect = hostRef.current!.getBoundingClientRect()
      return {
        x: (clientX - rect.left) / view.scale - view.x,
        y: (clientY - rect.top) / view.scale - view.y,
      }
    },
    [view],
  )

  const onWheel = (e: React.WheelEvent): void => {
    if (e.ctrlKey || e.metaKey || !e.shiftKey) {
      const rect = hostRef.current!.getBoundingClientRect()
      const mx = e.clientX - rect.left
      const my = e.clientY - rect.top
      const next = Math.max(0.1, Math.min(4, view.scale * Math.exp(-e.deltaY * 0.0015)))
      setView({
        scale: next,
        x: mx / next - (mx / view.scale - view.x),
        y: my / next - (my / view.scale - view.y),
      })
    } else {
      setView({ ...view, x: view.x - e.deltaX / view.scale, y: view.y - e.deltaY / view.scale })
    }
  }

  // ---------------------------------------------------------------- edits

  const addNode = (partial: Partial<CanvasNode>): void => {
    const rect = hostRef.current!.getBoundingClientRect()
    const center = toWorld(rect.left + rect.width / 2, rect.top + rect.height / 2)
    const node: CanvasNode = {
      id: uid(),
      type: 'text',
      x: Math.round(center.x - 130),
      y: Math.round(center.y - 70),
      width: 260,
      height: 140,
      text: '',
      ...partial,
    }
    save({ ...doc, nodes: [...doc.nodes, node] })
    setSelection(new Set([node.id]))
    if (node.type === 'text') setEditing(node.id)
  }

  const updateNode = (id: string, patch: Partial<CanvasNode>): void => {
    save({ ...doc, nodes: doc.nodes.map((n) => (n.id === id ? { ...n, ...patch } : n)) })
  }

  const deleteSelection = (): void => {
    if (!selection.size) return
    save({
      nodes: doc.nodes.filter((n) => !selection.has(n.id)),
      edges: doc.edges.filter((e) => !selection.has(e.fromNode) && !selection.has(e.toNode)),
    })
    setSelection(new Set())
  }

  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (editing) return
      const host = hostRef.current
      if (!host || !host.contains(document.activeElement) && document.activeElement !== document.body) return
      if (e.key === 'Delete' || e.key === 'Backspace') {
        if (selection.size) {
          e.preventDefault()
          deleteSelection()
        }
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [selection, editing, doc])

  // --------------------------------------------------------------- render

  const nodeById = useMemo(() => new Map(doc.nodes.map((n) => [n.id, n])), [doc.nodes])

  const edgePath = (edge: CanvasEdge): { d: string; mid: { x: number; y: number } } | null => {
    const a = nodeById.get(edge.fromNode)
    const b = nodeById.get(edge.toNode)
    if (!a || !b) return null
    const [defaultFrom, defaultTo] = bestSides(a, b)
    const p1 = anchor(a, edge.fromSide ?? defaultFrom)
    const p2 = anchor(b, edge.toSide ?? defaultTo)
    const dist = Math.max(40, Math.hypot(p2.x - p1.x, p2.y - p1.y) * 0.4)
    const c1 = offsetBy(p1, edge.fromSide ?? defaultFrom, dist)
    const c2 = offsetBy(p2, edge.toSide ?? defaultTo, dist)
    return {
      d: `M ${p1.x} ${p1.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${p2.x} ${p2.y}`,
      mid: { x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 },
    }
  }

  return (
    <div className="canvas-view" ref={hostRef} onWheel={onWheel} tabIndex={0}
      onPointerDown={(e) => {
        if (e.target !== e.currentTarget && !(e.target as HTMLElement).classList.contains('canvas-surface'))
          return
        setSelection(new Set())
        setEditing(null)
        panRef.current = { x: e.clientX, y: e.clientY, vx: view.x, vy: view.y }
      }}
      onPointerMove={(e) => {
        if (linking) {
          const w = toWorld(e.clientX, e.clientY)
          setLinking({ ...linking, x: w.x, y: w.y })
          return
        }
        if (dragRef.current) {
          const d = dragRef.current
          const dx = (e.clientX - d.startX) / view.scale
          const dy = (e.clientY - d.startY) / view.scale
          setDoc((prev) => ({
            ...prev,
            nodes: prev.nodes.map((n) => {
              const origin = d.origins.get(n.id)
              return origin ? { ...n, x: Math.round(origin.x + dx), y: Math.round(origin.y + dy) } : n
            }),
          }))
          dirtyRef.current = true
          return
        }
        if (resizeRef.current) {
          const r = resizeRef.current
          setDoc((prev) => ({
            ...prev,
            nodes: prev.nodes.map((n) =>
              n.id === r.id
                ? {
                    ...n,
                    width: Math.max(80, Math.round(r.w + (e.clientX - r.startX) / view.scale)),
                    height: Math.max(60, Math.round(r.h + (e.clientY - r.startY) / view.scale)),
                  }
                : n,
            ),
          }))
          dirtyRef.current = true
          return
        }
        if (panRef.current) {
          const p = panRef.current
          setView((v) => ({
            ...v,
            x: p.vx + (e.clientX - p.x) / v.scale,
            y: p.vy + (e.clientY - p.y) / v.scale,
          }))
        }
      }}
      onPointerUp={(e) => {
        if (linking) {
          const target = (e.target as HTMLElement).closest('[data-node-id]')
          const toId = target?.getAttribute('data-node-id')
          if (toId && toId !== linking.from) {
            save({
              ...doc,
              edges: [
                ...doc.edges,
                {
                  id: uid(),
                  fromNode: linking.from,
                  fromSide: linking.side,
                  toNode: toId,
                  toEnd: 'arrow',
                },
              ],
            })
          }
          setLinking(null)
        }
        dragRef.current = null
        resizeRef.current = null
        panRef.current = null
      }}
    >
      <div className="canvas-toolbar">
        <button className="icon-btn" title="Add card" onClick={() => addNode({ type: 'text' })}>
          <Icon name="plus" size={14} />
        </button>
        <button
          className="icon-btn"
          title="Add note card"
          onClick={() =>
            useStore.getState().setModal({
              kind: 'prompt',
              title: 'Note name to embed',
              value: '',
              onSubmit: (v) => {
                const hit =
                  [...notes.keys()].find((p) => stem(p).toLowerCase() === v.trim().toLowerCase()) ??
                  [...notes.keys()].find((p) => p.toLowerCase() === v.trim().toLowerCase())
                if (hit) addNode({ type: 'file', file: hit, width: 320, height: 260 })
                else setStatus(`No note called "${v}"`)
              },
            })
          }
        >
          <Icon name="files" size={14} />
        </button>
        <button
          className="icon-btn"
          title="Add group"
          onClick={() => addNode({ type: 'group', label: 'Group', width: 420, height: 320 })}
        >
          <Icon name="canvas" size={14} />
        </button>
        <button
          className="icon-btn"
          title="Zoom to fit"
          onClick={() => fitView(doc.nodes)}
        >
          <Icon name="target" size={14} />
        </button>
        <button className="icon-btn" title="Delete selection" onClick={deleteSelection}>
          <Icon name="trash" size={14} />
        </button>
      </div>

      <div
        className="canvas-surface"
        style={{ transform: `scale(${view.scale}) translate(${view.x}px, ${view.y}px)` }}
      >
        <svg
          style={{ position: 'absolute', overflow: 'visible', pointerEvents: 'none', left: 0, top: 0 }}
        >
          <defs>
            <marker
              id="canvas-arrow"
              viewBox="0 0 10 10"
              refX="9"
              refY="5"
              markerWidth="6"
              markerHeight="6"
              orient="auto-start-reverse"
            >
              <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--fg-dim)" />
            </marker>
          </defs>
          {doc.edges.map((edge) => {
            const geo = edgePath(edge)
            if (!geo) return null
            return (
              <g key={edge.id}>
                <path
                  d={geo.d}
                  fill="none"
                  stroke={edge.color ? (CANVAS_COLORS[edge.color] ?? edge.color) : 'var(--fg-dim)'}
                  strokeWidth={2}
                  markerEnd={edge.toEnd === 'none' ? undefined : 'url(#canvas-arrow)'}
                />
                {edge.label && (
                  <text
                    x={geo.mid.x}
                    y={geo.mid.y - 6}
                    textAnchor="middle"
                    fill="var(--fg-dim)"
                    fontSize={11}
                  >
                    {edge.label}
                  </text>
                )}
              </g>
            )
          })}
          {linking &&
            (() => {
              const from = nodeById.get(linking.from)
              if (!from) return null
              const p = anchor(from, linking.side)
              return (
                <path
                  d={`M ${p.x} ${p.y} L ${linking.x} ${linking.y}`}
                  stroke="var(--accent)"
                  strokeWidth={2}
                  strokeDasharray="4 4"
                  fill="none"
                />
              )
            })()}
        </svg>

        {doc.nodes.map((node) => {
          const selected = selection.has(node.id)
          const color = node.color ? (CANVAS_COLORS[node.color] ?? node.color) : undefined
          return (
            <div
              key={node.id}
              data-node-id={node.id}
              className={`canvas-node${selected ? ' is-selected' : ''}${node.type === 'group' ? ' is-group' : ''}`}
              style={{
                left: node.x,
                top: node.y,
                width: node.width,
                height: node.height,
                borderColor: color,
              }}
              onPointerDown={(e) => {
                e.stopPropagation()
                const next = e.shiftKey ? new Set(selection) : new Set<string>()
                next.add(node.id)
                setSelection(next)
                const origins = new Map(
                  doc.nodes.filter((n) => next.has(n.id)).map((n) => [n.id, { x: n.x, y: n.y }]),
                )
                dragRef.current = { ids: [...next], startX: e.clientX, startY: e.clientY, origins }
              }}
              onDoubleClick={() => {
                if (node.type === 'text') setEditing(node.id)
                else if (node.type === 'file' && node.file) void openFile(node.file)
                else if (node.type === 'link' && node.url) void window.onyx.url.open(node.url)
              }}
            >
              {(node.type === 'file' || node.type === 'link' || node.type === 'group') && (
                <div className="canvas-node-label">
                  {node.type === 'group' ? (node.label ?? 'Group') : (node.file ?? node.url)}
                </div>
              )}
              {node.type !== 'group' && (
                <div className="canvas-node-body">
                  {editing === node.id ? (
                    <textarea
                      autoFocus
                      defaultValue={node.text ?? ''}
                      onPointerDown={(e) => e.stopPropagation()}
                      onBlur={(e) => {
                        updateNode(node.id, { text: e.target.value })
                        setEditing(null)
                      }}
                    />
                  ) : node.type === 'text' ? (
                    <div
                      className="rendered"
                      style={{ fontSize: 13 }}
                      dangerouslySetInnerHTML={{
                        __html: renderMarkdown(node.text ?? '', {
                          path,
                          resolve: (t) =>
                            [...notes.keys()].find(
                              (p) => stem(p).toLowerCase() === t.toLowerCase(),
                            ) ?? null,
                          fileUrl: (t) => assetUrl(t),
                          embed: () => null,
                        }),
                      }}
                    />
                  ) : node.type === 'file' ? (
                    <FileCard file={node.file ?? ''} content={embedded.get(node.file ?? '')} />
                  ) : (
                    <a href={node.url} onClick={(e) => e.preventDefault()}>
                      {node.url}
                    </a>
                  )}
                </div>
              )}

              {selected && (
                <>
                  {(['top', 'right', 'bottom', 'left'] as Side[]).map((side) => (
                    <div
                      key={side}
                      className={`canvas-handle ${side[0]}`}
                      onPointerDown={(e) => {
                        e.stopPropagation()
                        const w = toWorld(e.clientX, e.clientY)
                        setLinking({ from: node.id, side, x: w.x, y: w.y })
                      }}
                    />
                  ))}
                  <div
                    className="canvas-resize"
                    onPointerDown={(e) => {
                      e.stopPropagation()
                      resizeRef.current = {
                        id: node.id,
                        startX: e.clientX,
                        startY: e.clientY,
                        w: node.width,
                        h: node.height,
                      }
                    }}
                  />
                </>
              )}
            </div>
          )
        })}
      </div>

      {!doc.nodes.length && loaded && (
        <div
          style={{
            position: 'absolute',
            inset: 0,
            display: 'grid',
            placeItems: 'center',
            color: 'var(--fg-subtle)',
            pointerEvents: 'none',
          }}
        >
          Empty canvas — use the toolbar to add a card.
        </div>
      )}
    </div>
  )
}

function FileCard({ file, content }: { file: string; content?: string }): JSX.Element {
  if (/\.(png|jpe?g|gif|webp|svg|avif)$/i.test(file)) {
    const url = assetUrl(file)
    return url ? <img src={url} alt={file} style={{ maxWidth: '100%' }} /> : <span className="spinner" />
  }
  if (content === undefined) return <span className="spinner" />
  return (
    <div
      className="rendered"
      style={{ fontSize: 12 }}
      dangerouslySetInnerHTML={{
        __html: renderMarkdown(content, {
          path: file,
          resolve: () => null,
          fileUrl: (t) => assetUrl(t),
          embed: () => null,
        }),
      }}
    />
  )
}

function offsetBy(p: { x: number; y: number }, side: Side, d: number): { x: number; y: number } {
  switch (side) {
    case 'top':
      return { x: p.x, y: p.y - d }
    case 'bottom':
      return { x: p.x, y: p.y + d }
    case 'left':
      return { x: p.x - d, y: p.y }
    default:
      return { x: p.x + d, y: p.y }
  }
}
