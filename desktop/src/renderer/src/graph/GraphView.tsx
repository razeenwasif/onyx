/**
 * Graph view and local graph — Obsidian's, feature for feature.
 *
 * Filters / Groups / Display / Forces panels with the same controls and the
 * same semantics; hover highlights a node and its neighbours and dims the rest;
 * dragging pins a node while you hold it; the wheel zooms about the pointer;
 * labels fade out as you zoom away. Rendering is WebGL2 (`renderer.ts`), layout
 * runs in a worker (`physics.worker.ts`), and everything in between — filtering,
 * grouping, hit-testing — happens here.
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { GraphData, GraphSettings, LocalGraphSettings } from '@shared/types'
import { useStore } from '../store'
import { hexToRgb, themeById } from '../themes'
import { Icon } from '../components/Icon'
import { DEFAULT_GRAPH, DEFAULT_LOCAL_GRAPH } from '@shared/graph-defaults'
import { primaryTag, tagColor, tagFamily } from './tag-colors'
import { GraphRenderer, makeFrameData, type Camera, type FrameData } from './renderer'
import PhysicsWorker from './physics.worker?worker'

const GROUP_COLORS = ['#e06c75', '#e5c07b', '#98c379', '#56b6c2', '#61afef', '#c678dd', '#d19a66']

interface Props {
  /** null = global graph; a path = local graph centred on that note. */
  focusPath: string | null
  local: boolean
  /** Docked in a sidebar: no control panel, smaller toolbar. */
  compact?: boolean
}

interface Sub {
  /** Indices into the full graph. */
  nodes: number[]
  /** Position of a full-graph index inside `nodes`, or -1. */
  reverse: Int32Array
  /** Pairs of sub-indices. */
  edges: Int32Array
  /** Per-sub-node adjacency (sub-indices). */
  adjacency: number[][]
}

/** Depth of every node from `root`, following the requested link directions. */
function bfsDepths(
  data: GraphData,
  root: number,
  depth: number,
  incoming: boolean,
  outgoing: boolean,
): Map<number, number> {
  const out = new Map<number, number>([[root, 0]])
  let frontier = [root]
  for (let d = 1; d <= depth; d++) {
    const next: number[] = []
    for (const i of frontier) {
      for (const l of data.links) {
        let other = -1
        if (outgoing && l.source === i) other = l.target
        else if (incoming && l.target === i) other = l.source
        if (other >= 0 && !out.has(other)) {
          out.set(other, d)
          next.push(other)
        }
      }
    }
    frontier = next
    if (!frontier.length) break
  }
  return out
}

/**
 * The docked pane is a minimap: a layout sized for a full tab is sub-pixel in a
 * 260px-wide pane on a large vault, so shorten the springs there. Everything
 * else — forces, filters, colours — is the tab's own configuration.
 */
const COMPACT_DISTANCE_SCALE = 0.35

/** Node radius bounds in world units, before the Node size slider. */
const NODE_BASE = 8
const NODE_MAX = 30

/**
 * Time constants (ms) for the eased parts of the view: hover highlight fading
 * in and out, and wheel / button zoom gliding to its target. Obsidian animates
 * both; snapping reads as a different, cheaper widget.
 */
const HIGHLIGHT_TAU = 90
const ZOOM_TAU = 65

const MIN_SCALE = 0.0008
const MAX_SCALE = 12

/** A hover reveals its neighbours' labels too, unless it's a hub with a crowd. */
const NEIGHBOUR_LABEL_LIMIT = 40

const LABEL_FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'

/** The control panel's open state outlives the tab, like Obsidian's. */
let panelRemembered = false

export function GraphView({ focusPath, local, compact = false }: Props): JSX.Element {
  const graph = useStore((s) => s.graph)
  const settingsAll = useStore((s) => s.settings)
  const setSettings = useStore((s) => s.setSettings)
  const openFile = useStore((s) => s.openFile)
  const openView = useStore((s) => s.openView)
  const notes = useStore((s) => s.notes)

  const cfg: LocalGraphSettings | GraphSettings = local
    ? (settingsAll?.localGraph ?? ({} as LocalGraphSettings))
    : (settingsAll?.graph ?? ({} as GraphSettings))
  const localCfg = cfg as LocalGraphSettings
  const palette = themeById(settingsAll?.theme ?? 'onyx-dark')

  const hostRef = useRef<HTMLDivElement>(null)
  const glCanvasRef = useRef<HTMLCanvasElement>(null)
  const labelCanvasRef = useRef<HTMLCanvasElement>(null)
  const rendererRef = useRef<GraphRenderer | null>(null)
  const workerRef = useRef<Worker | null>(null)
  const frameRef = useRef<FrameData>(makeFrameData(0, 0))
  const posRef = useRef<Float32Array>(new Float32Array(0))
  const cameraRef = useRef<Camera>({ x: 0, y: 0, scale: 1 })
  const hoverRef = useRef<number>(-1)
  const dragRef = useRef<{ node: number; moved: boolean } | null>(null)
  const panRef = useRef<{ x: number; y: number; camX: number; camY: number } | null>(null)
  /**
   * The camera tracks the layout while it settles, then stops. "Settled" comes
   * from the simulation's own cooling `alpha`, not a timer: a 46-node graph
   * settles in a second and a 1500-node one takes far longer, and a fixed
   * window would leave the big one framed on its first, tiny frame. Any pan,
   * zoom or drag hands control straight to the user, as Obsidian does.
   */
  const autoFitRef = useRef(true)
  const alphaRef = useRef(1)
  /** Extent of the layout last frame, and how long it's held steady. */
  const lastExtentRef = useRef(0)
  const steadyFramesRef = useRef(0)
  const rafRef = useRef(0)
  /**
   * Eased highlight state, per sub-node / sub-link, stepped every frame
   * toward what the hover asks for. `emph` 1 = full strength, 0 = faded into
   * the background; `hot` 1 = the hovered node itself; `linkHot` 1 = a link
   * touching it, drawn in the accent colour.
   */
  const emphRef = useRef<Float32Array>(new Float32Array(0))
  const hotRef = useRef<Float32Array>(new Float32Array(0))
  const linkEmphRef = useRef<Float32Array>(new Float32Array(0))
  const linkHotRef = useRef<Float32Array>(new Float32Array(0))
  /** 1 = a neighbour of the hovered node whose label is being shown. */
  const revealRef = useRef<Float32Array>(new Float32Array(0))
  /** A zoom in flight: target scale, anchored at a point relative to the view centre (CSS px). */
  const zoomAnimRef = useRef<{ target: number; ax: number; ay: number } | null>(null)
  /** Frames left of an eased "zoom to fit". */
  const fitAnimRef = useRef(0)

  const [panelOpen, setPanelOpenState] = useState(!compact && panelRemembered)
  const setPanelOpen = (open: boolean): void => {
    panelRemembered = open
    setPanelOpenState(open)
  }
  const [menu, setMenu] = useState<{ x: number; y: number; id: string } | null>(null)
  /** Paths matched by the filter query and by each group query (content search). */
  const [queryHits, setQueryHits] = useState<Map<string, Set<string>>>(new Map())
  const [glError, setGlError] = useState<string | null>(null)

  const patch = useCallback(
    (p: Partial<LocalGraphSettings>) => {
      void setSettings(local ? { localGraph: { ...localCfg, ...p } } : { graph: { ...cfg, ...p } as GraphSettings })
    },
    [cfg, local, localCfg, setSettings],
  )

  // ------------------------------------------------- resolve search queries

  const allQueries = useMemo(() => {
    const qs = new Set<string>()
    if (cfg.searchQuery?.trim()) qs.add(cfg.searchQuery.trim())
    for (const g of cfg.groups ?? []) if (g.query.trim()) qs.add(g.query.trim())
    return [...qs]
  }, [cfg.searchQuery, cfg.groups])

  useEffect(() => {
    let cancelled = false
    const timer = setTimeout(async () => {
      const next = new Map<string, Set<string>>()
      for (const q of allQueries) {
        try {
          const hits = await window.onyx.search.query(q)
          next.set(q, new Set(hits.map((h) => h.path)))
        } catch {
          next.set(q, new Set())
        }
      }
      if (!cancelled) setQueryHits(next)
    }, 220)
    return () => {
      cancelled = true
      clearTimeout(timer)
    }
  }, [allQueries.join(' ')])

  /** Does node `i` satisfy `query`? Falls back to title/path/tag matching. */
  const matches = useCallback(
    (i: number, query: string): boolean => {
      if (!graph) return false
      const q = query.trim()
      if (!q) return true
      const node = graph.nodes[i]
      const hits = queryHits.get(q)
      if (hits && node.kind === 'note' && hits.has(node.id)) return true
      const lower = q.toLowerCase()
      if (lower.startsWith('tag:') || lower.startsWith('#')) {
        const t = lower.replace(/^tag:/, '').replace(/^#/, '')
        return node.tags.some((x) => x.toLowerCase() === t || x.toLowerCase().startsWith(`${t}/`))
      }
      if (lower.startsWith('path:')) return node.id.toLowerCase().includes(lower.slice(5))
      if (lower.startsWith('file:')) return node.title.toLowerCase().includes(lower.slice(5))
      return (
        node.title.toLowerCase().includes(lower) ||
        node.id.toLowerCase().includes(lower) ||
        (hits ? hits.has(node.id) : false)
      )
    },
    [graph, queryHits],
  )

  // ------------------------------------------------------ build the subgraph

  const sub: Sub = useMemo(() => {
    const empty: Sub = { nodes: [], reverse: new Int32Array(0), edges: new Int32Array(0), adjacency: [] }
    if (!graph) return empty

    const keep = new Set<number>()
    const focusIndex = focusPath ? graph.nodes.findIndex((n) => n.id === focusPath) : -1

    // Local graph: BFS to the requested depth first, then apply the filters.
    let allowed: Set<number> | null = null
    if (local) {
      if (focusIndex < 0) return empty
      const depths = bfsDepths(
        graph,
        focusIndex,
        Math.max(1, localCfg.depth ?? 1),
        localCfg.incoming !== false,
        localCfg.outgoing !== false,
      )
      allowed = new Set(depths.keys())
    }

    for (let i = 0; i < graph.nodes.length; i++) {
      if (allowed && !allowed.has(i)) continue
      const node = graph.nodes[i]
      if (node.kind === 'tag' && !cfg.showTags) continue
      if (node.kind === 'attachment' && !cfg.showAttachments) continue
      if (node.kind === 'unresolved' && cfg.existingOnly) continue
      if (cfg.searchQuery?.trim() && !(local && i === focusIndex) && !matches(i, cfg.searchQuery))
        continue
      keep.add(i)
    }

    // Orphans: notes with no surviving edge at all.
    if (!cfg.showOrphans) {
      const connected = new Set<number>()
      for (const l of graph.links) {
        if (keep.has(l.source) && keep.has(l.target)) {
          connected.add(l.source)
          connected.add(l.target)
        }
      }
      for (const i of [...keep]) {
        if (!connected.has(i) && !(local && i === focusIndex)) keep.delete(i)
      }
    }

    const nodes: number[] = [...keep].sort((a, b) => a - b)
    const reverse = new Int32Array(graph.nodes.length).fill(-1)
    nodes.forEach((full, subIdx) => {
      reverse[full] = subIdx
    })

    /** Edges among a given node set, honouring the edge-kind filters. */
    const buildEdges = (
      list: number[],
      lookup: Int32Array,
    ): { pairs: number[]; adjacency: number[][] } => {
      const pairs: number[] = []
      const adjacency: number[][] = list.map(() => [])
      for (const l of graph.links) {
        // A nested-tag hierarchy edge only exists when the option is on.
        if (l.kind === 'tagParent' && !cfg.linkNestedTags) continue
        const s = lookup[l.source]
        const t = lookup[l.target]
        if (s < 0 || t < 0) continue
        // Local graph without neighbour links: only edges touching the focus.
        if (local && localCfg.neighborLinks === false) {
          const f = lookup[focusIndex]
          if (s !== f && t !== f) continue
        }
        pairs.push(s, t)
        adjacency[s].push(t)
        adjacency[t].push(s)
      }
      return { pairs, adjacency }
    }

    let built = buildEdges(nodes, reverse)

    // Ancestor tag nodes are emitted for every nested tag, so with the
    // hierarchy edges switched off some of them have nothing attached. A tag
    // node with no surviving edge isn't a real part of the graph — drop it
    // rather than leave a stray dot floating (the Orphans filter is about
    // notes, not tags).
    const strandedTag = (i: number): boolean =>
      graph.nodes[nodes[i]].kind === 'tag' && built.adjacency[i].length === 0
    if (nodes.some((_, i) => strandedTag(i))) {
      const kept = nodes.filter((_, i) => !strandedTag(i))
      reverse.fill(-1)
      kept.forEach((full, subIdx) => {
        reverse[full] = subIdx
      })
      nodes.length = 0
      nodes.push(...kept)
      built = buildEdges(nodes, reverse)
    }

    return {
      nodes,
      reverse,
      edges: new Int32Array(built.pairs),
      adjacency: built.adjacency,
    }
  }, [graph, cfg, cfg.linkNestedTags, local, localCfg.depth, localCfg.incoming, localCfg.outgoing, localCfg.neighborLinks, focusPath, matches])

  /**
   * Tag color per sub-node, as RGB, or null when the node has no tags or the
   * option is off. Tag nodes color themselves; notes take their primary tag.
   */
  const tagRgb = useMemo(() => {
    const out: Array<number[] | null> = sub.nodes.map(() => null)
    if (!cfg.colorByTag || !graph) return out
    sub.nodes.forEach((full, i) => {
      const node = graph.nodes[full]
      const tag = node.kind === 'tag' ? node.tags[0] : primaryTag(node.tags)
      if (tag) out[i] = hexToRgb(tagColor(tag, palette.dark))
    })
    return out
  }, [sub, graph, cfg.colorByTag, palette.dark])

  /** Tags present in the visible graph, most used first — drives the legend. */
  const tagLegend = useMemo(() => {
    if (!cfg.colorByTag || !graph) return []
    const counts = new Map<string, number>()
    for (const full of sub.nodes) {
      const node = graph.nodes[full]
      const tag = node.kind === 'tag' ? node.tags[0] : primaryTag(node.tags)
      if (!tag) continue
      const family = tagFamily(tag)
      counts.set(family, (counts.get(family) ?? 0) + 1)
    }
    return [...counts.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .map(([tag, count]) => ({ tag, count, color: tagColor(tag, palette.dark) }))
  }, [sub, graph, cfg.colorByTag, palette.dark])

  /** Group color per sub-node (index into `sub.nodes`), or null. */
  const groupColors = useMemo(() => {
    const out: Array<string | null> = sub.nodes.map(() => null)
    for (const g of cfg.groups ?? []) {
      if (!g.query.trim()) continue
      sub.nodes.forEach((full, i) => {
        // Last matching group wins, like Obsidian.
        if (matches(full, g.query)) out[i] = g.color
      })
    }
    return out
  }, [sub, cfg.groups, matches])

  // ------------------------------------------------------------ the worker

  useEffect(() => {
    const worker = new PhysicsWorker()
    workerRef.current = worker
    worker.onmessage = (e: MessageEvent<{ type: string; positions: Float32Array; alpha: number }>) => {
      if (e.data.type !== 'positions') return
      const incoming = e.data.positions
      alphaRef.current = e.data.alpha ?? 0
      const prev = posRef.current
      posRef.current = incoming
      // Hand the old buffer back so the worker can refill it next tick.
      if (prev.length === incoming.length && prev.buffer.byteLength) {
        worker.postMessage({ type: 'buffer', buffer: prev.buffer }, [prev.buffer])
      }
    }
    return () => {
      worker.postMessage({ type: 'stop' })
      worker.terminate()
      workerRef.current = null
    }
  }, [])

  // Re-seed the simulation whenever the visible subgraph changes, carrying over
  // positions for nodes that survived so the layout doesn't jump.
  const prevIdsRef = useRef<string[]>([])
  useEffect(() => {
    const worker = workerRef.current
    if (!worker || !graph) return

    const ids = sub.nodes.map((i) => graph.nodes[i].id)
    const oldPos = posRef.current
    const oldIds = prevIdsRef.current
    const oldIndex = new Map(oldIds.map((id, i) => [id, i]))
    const seedPositions = new Float32Array(ids.length * 2)
    let carried = 0
    ids.forEach((id, i) => {
      const prev = oldIndex.get(id)
      if (prev !== undefined && oldPos.length >= (prev + 1) * 2) {
        seedPositions[i * 2] = oldPos[prev * 2]
        seedPositions[i * 2 + 1] = oldPos[prev * 2 + 1]
        carried++
      } else {
        seedPositions[i * 2] = NaN
      }
    })
    prevIdsRef.current = ids
    posRef.current = new Float32Array(ids.length * 2)

    const focusSub = focusPath
      ? sub.nodes.findIndex((i) => graph.nodes[i].id === focusPath)
      : -1

    worker.postMessage({
      type: 'init',
      count: ids.length,
      edges: sub.edges,
      positions: carried > 0 ? seedPositions : undefined,
      pinned: local && focusSub >= 0 ? [focusSub] : [],
      params: {
        centerForce: cfg.centerForce,
        repelForce: cfg.repelForce,
        linkForce: cfg.linkForce,
        linkDistance: cfg.linkDistance * (compact ? COMPACT_DISTANCE_SCALE : 1),
        // The docked pane freezes once it settles instead of drifting forever
        // — a background sim over a thousand nodes isn't worth the CPU.
        alive: !compact,
      },
    })
    // A layout built from scratch gets framed automatically; one that carried
    // positions over (a filter toggle) keeps the camera where the user left it.
    if (carried === 0) {
      autoFitRef.current = true
      alphaRef.current = 1
      lastExtentRef.current = 0
      steadyFramesRef.current = 0
    }

    frameRef.current = makeFrameData(ids.length, sub.edges.length / 2)
  }, [sub, graph, local, focusPath, compact])

  // Force sliders push through without rebuilding the graph.
  useEffect(() => {
    workerRef.current?.postMessage({
      type: 'params',
      params: {
        centerForce: cfg.centerForce,
        repelForce: cfg.repelForce,
        linkForce: cfg.linkForce,
        linkDistance: cfg.linkDistance * (compact ? COMPACT_DISTANCE_SCALE : 1),
        // The docked pane freezes once it settles instead of drifting forever
        // — a background sim over a thousand nodes isn't worth the CPU.
        alive: !compact,
      },
    })
  }, [cfg.centerForce, cfg.repelForce, cfg.linkForce, cfg.linkDistance])

  // ----------------------------------------------------------- render loop

  useLayoutEffect(() => {
    const canvas = glCanvasRef.current
    if (!canvas) return
    try {
      rendererRef.current = new GraphRenderer(canvas)
      setGlError(null)
    } catch (err) {
      setGlError((err as Error).message)
      return
    }
    return () => {
      rendererRef.current?.dispose()
      rendererRef.current = null
    }
  }, [])

  // Obsidian's sizing: every node starts at the same size and only real hubs
  // grow (with the square root of their link count), up to a cap — so a
  // 500-link tag reads as a hub without swallowing its neighbourhood.
  const nodeRadius = useCallback(
    (degree: number) =>
      (cfg.nodeSize || 1) *
      (compact ? COMPACT_DISTANCE_SCALE : 1) *
      Math.max(NODE_BASE, Math.min(3 * Math.sqrt(degree + 1), NODE_MAX)),
    [cfg.nodeSize, compact],
  )

  useEffect(() => {
    const host = hostRef.current
    const renderer = rendererRef.current
    const labelCanvas = labelCanvasRef.current
    if (!host || !renderer || !labelCanvas || !graph) return

    const ctx = labelCanvas.getContext('2d')!
    const bg = hexToRgb(palette.bg).map((c) => c / 255) as [number, number, number]
    const nodeBase = hexToRgb(palette.fgDim)
    const nodeUnresolved = hexToRgb(palette.fgSubtle)
    const nodeTag = hexToRgb(palette.tag)
    const nodeAttachment = hexToRgb(palette.accentAlt)
    const nodeFocus = hexToRgb(palette.accent)
    const linkBase = hexToRgb(palette.border)
    const labelColor = palette.fgDim
    let lastTime = performance.now()

    const loop = (now: number): void => {
      rafRef.current = requestAnimationFrame(loop)
      // Clamp so a tab that was in the background doesn't jump a whole second.
      const dt = Math.min(64, Math.max(0, now - lastTime))
      lastTime = now
      const ease = (tau: number): number => 1 - Math.exp(-dt / tau)
      const { width, height, dpr } = renderer.resize()
      if (labelCanvas.width !== width || labelCanvas.height !== height) {
        labelCanvas.width = width
        labelCanvas.height = height
      }

      const pos = posRef.current
      const frame = frameRef.current
      const n = sub.nodes.length
      if (pos.length < n * 2) {
        renderer.clear([bg[0], bg[1], bg[2], 1])
        ctx.clearRect(0, 0, width, height)
        return
      }

      // Track the layout while it settles, easing so the camera glides rather
      // than snapping, then leave the view where the user put it.
      if (n > 0 && autoFitRef.current) {
        // "Settled" can't come from `alpha`: the sim keeps a floor so the graph
        // stays gently alive, and alpha crosses any sensible threshold within a
        // second — long before a 1500-node layout has finished expanding. Watch
        // the bounding box instead and stop once it holds still.
        const extent = fitToContent(pos, n, width / dpr, height / dpr, cameraRef.current, 0.1)
        const previous = lastExtentRef.current
        const change = previous > 0 ? Math.abs(extent - previous) / previous : 1
        steadyFramesRef.current = change < 0.002 ? steadyFramesRef.current + 1 : 0
        lastExtentRef.current = extent
        if (steadyFramesRef.current > 45) {
          fitToContent(pos, n, width / dpr, height / dpr, cameraRef.current, 1)
          autoFitRef.current = false
        }
      } else if (fitAnimRef.current > 0) {
        fitAnimRef.current--
        fitToContent(pos, n, width / dpr, height / dpr, cameraRef.current, ease(ZOOM_TAU * 1.6))
      }

      const cam = cameraRef.current

      // Glide toward the wheel's target zoom, keeping the anchor point still.
      const zoom = zoomAnimRef.current
      if (zoom) {
        const wx = zoom.ax / cam.scale + cam.x
        const wy = zoom.ay / cam.scale + cam.y
        let next = cam.scale * Math.pow(zoom.target / cam.scale, ease(ZOOM_TAU))
        if (Math.abs(Math.log(zoom.target / next)) < 0.002) {
          next = zoom.target
          zoomAnimRef.current = null
        }
        cam.x = wx - zoom.ax / next
        cam.y = wy - zoom.ay / next
        cam.scale = next
      }

      const hover = hoverRef.current
      const neighbours = hover >= 0 ? new Set(sub.adjacency[hover] ?? []) : null
      const dimming = hover >= 0

      // ---- eased highlight state
      const m = sub.edges.length / 2
      if (emphRef.current.length !== n) {
        emphRef.current = new Float32Array(n).fill(1)
        hotRef.current = new Float32Array(n)
      }
      if (linkEmphRef.current.length !== m) {
        linkEmphRef.current = new Float32Array(m).fill(1)
        linkHotRef.current = new Float32Array(m)
      }
      const emph = emphRef.current
      const hot = hotRef.current
      const linkEmph = linkEmphRef.current
      const linkHot = linkHotRef.current
      const k = ease(HIGHLIGHT_TAU)
      for (let i = 0; i < n; i++) {
        const active = !dimming || i === hover || neighbours!.has(i)
        emph[i] += ((active ? 1 : 0) - emph[i]) * k
        hot[i] += ((i === hover ? 1 : 0) - hot[i]) * k
      }

      // ---- links
      let lc = 0
      const edges = sub.edges
      const thickness = (cfg.linkThickness || 1) * 1.4
      for (let e = 0; e < edges.length; e += 2) {
        const s = edges[e]
        const t = edges[e + 1]
        const touches = s === hover || t === hover
        linkEmph[lc] += ((!dimming || touches ? 1 : 0) - linkEmph[lc]) * k
        linkHot[lc] += ((dimming && touches ? 1 : 0) - linkHot[lc]) * k
        const h = linkHot[lc]
        const alpha = 0.06 + (0.42 + 0.43 * h - 0.06) * linkEmph[lc]
        frame.linkFrom[lc * 2] = pos[s * 2]
        frame.linkFrom[lc * 2 + 1] = pos[s * 2 + 1]
        frame.linkTo[lc * 2] = pos[t * 2]
        frame.linkTo[lc * 2 + 1] = pos[t * 2 + 1]
        frame.linkWidth[lc] = thickness * dpr * (1 + 0.4 * h)
        frame.linkColor[lc * 4] = mix(linkBase[0], nodeFocus[0], h) / 255
        frame.linkColor[lc * 4 + 1] = mix(linkBase[1], nodeFocus[1], h) / 255
        frame.linkColor[lc * 4 + 2] = mix(linkBase[2], nodeFocus[2], h) / 255
        frame.linkColor[lc * 4 + 3] = alpha
        frame.linkInset[lc] =
          nodeRadius(graph.nodes[sub.nodes[t]].degree) * cam.scale * dpr + 2 * dpr
        lc++
      }
      frame.linkCount = lc
      frame.arrows = cfg.arrows
      frame.arrowSize = 4.5 * (cfg.linkThickness || 1)

      // ---- nodes
      for (let i = 0; i < n; i++) {
        const node = graph.nodes[sub.nodes[i]]
        const r = nodeRadius(node.degree)
        frame.nodeXY[i * 2] = pos[i * 2]
        frame.nodeXY[i * 2 + 1] = pos[i * 2 + 1]
        frame.nodeRadius[i] = r

        // Precedence: an explicit group, then the focused note, then the
        // node's tag color, then the per-kind default.
        let rgb: number[]
        const group = groupColors[i]
        const byTag = tagRgb[i]
        if (group) rgb = hexToRgb(group)
        else if (node.id === focusPath) rgb = nodeFocus
        else if (byTag) rgb = byTag
        else if (node.kind === 'tag') rgb = nodeTag
        else if (node.kind === 'attachment') rgb = nodeAttachment
        else if (node.kind === 'unresolved') rgb = nodeUnresolved
        else rgb = nodeBase

        // The hovered node fills with the accent colour, as in Obsidian.
        const h = hot[i]
        frame.nodeColor[i * 4] = mix(rgb[0], nodeFocus[0], h) / 255
        frame.nodeColor[i * 4 + 1] = mix(rgb[1], nodeFocus[1], h) / 255
        frame.nodeColor[i * 4 + 2] = mix(rgb[2], nodeFocus[2], h) / 255
        frame.nodeColor[i * 4 + 3] = Math.max(
          h,
          node.kind === 'unresolved' ? mix(0.1, 0.55, emph[i]) : mix(0.12, 1, emph[i]),
        )
        frame.nodeRing[i] = 0
      }
      frame.nodeCount = n

      renderer.clear([bg[0], bg[1], bg[2], 1])
      renderer.draw(frame, cam, dpr)

      // ---- labels (2D overlay)
      ctx.clearRect(0, 0, width, height)
      // Labels fade with how big a node actually is on screen, not with raw
      // zoom, so the threshold behaves the same on a 40-note and a 4000-note
      // vault. Sliding "Text fade threshold" right makes them fade sooner.
      // The docked minimap packs nodes far closer together, so labels need a
      // higher bar before they're worth drawing — otherwise they overlap into
      // an unreadable smear.
      //
      // Hovering overrides the fade: the hovered node's name always shows,
      // a little larger, and so do its neighbours' unless there's a crowd.
      const fade = Math.max(0.05, (cfg.textFadeThreshold ?? 1.1) * (compact ? 3 : 1))
      const onScreen = cam.scale * NODE_BASE * (cfg.nodeSize || 1)
      const labelAlpha = Math.max(0, Math.min(1, onScreen / (fade * 4) - 0.25))
      if (revealRef.current.length !== n) revealRef.current = new Float32Array(n)
      const reveal = revealRef.current
      const revealNeighbours = dimming && neighbours!.size <= NEIGHBOUR_LABEL_LIMIT
      let revealing = false
      for (let i = 0; i < n; i++) {
        const target = revealNeighbours && neighbours!.has(i) ? 1 : 0
        reveal[i] += (target - reveal[i]) * k
        if (reveal[i] > 0.01 || hot[i] > 0.01) revealing = true
      }
      if (labelAlpha > 0.01 || revealing) {
        const font = (px: number): string => `${px * dpr}px ${LABEL_FONT}`
        ctx.font = font(12)
        ctx.textAlign = 'center'
        ctx.textBaseline = 'top'
        const halfW = width / 2
        const halfH = height / 2
        for (let i = 0; i < n; i++) {
          const h = hot[i]
          const a = Math.max(labelAlpha * mix(0.12, 1, emph[i]) * 0.9, h, reveal[i] * 0.85)
          if (a < 0.02) continue
          const sx = (pos[i * 2] - cam.x) * cam.scale * dpr + halfW
          const sy = (pos[i * 2 + 1] - cam.y) * cam.scale * dpr + halfH
          if (sx < -140 || sx > width + 140 || sy < -40 || sy > height + 40) continue
          const node = graph.nodes[sub.nodes[i]]
          ctx.globalAlpha = a
          ctx.fillStyle = h > 0.5 ? palette.fg : labelColor
          if (h > 0.01) ctx.font = font(12 + 2 * h)
          const r = nodeRadius(node.degree) * cam.scale * dpr
          ctx.fillText(truncate(node.title, h > 0.5 ? 60 : 28), sx, sy + r + (3 + 2 * h) * dpr)
          if (h > 0.01) ctx.font = font(12)
        }
        ctx.globalAlpha = 1
      }
    }

    rafRef.current = requestAnimationFrame(loop)
    return () => cancelAnimationFrame(rafRef.current)
  }, [graph, sub, cfg, palette, groupColors, tagRgb, focusPath, nodeRadius])

  // ------------------------------------------------------------ interaction

  const pickNode = useCallback(
    (clientX: number, clientY: number): number => {
      const host = hostRef.current
      if (!host || !graph) return -1
      const rect = host.getBoundingClientRect()
      const cam = cameraRef.current
      const wx = (clientX - rect.left - rect.width / 2) / cam.scale + cam.x
      const wy = (clientY - rect.top - rect.height / 2) / cam.scale + cam.y
      const pos = posRef.current
      let best = -1
      let bestD = Infinity
      for (let i = 0; i < sub.nodes.length; i++) {
        const dx = pos[i * 2] - wx
        const dy = pos[i * 2 + 1] - wy
        const d2 = dx * dx + dy * dy
        const r = nodeRadius(graph.nodes[sub.nodes[i]].degree) + 4 / cam.scale
        if (d2 <= r * r && d2 < bestD) {
          bestD = d2
          best = i
        }
      }
      return best
    },
    [graph, sub, nodeRadius],
  )

  const toWorld = useCallback((clientX: number, clientY: number): [number, number] => {
    const rect = hostRef.current!.getBoundingClientRect()
    const cam = cameraRef.current
    return [
      (clientX - rect.left - rect.width / 2) / cam.scale + cam.x,
      (clientY - rect.top - rect.height / 2) / cam.scale + cam.y,
    ]
  }, [])

  /** Events over the settings panel or a menu belong to them, not the graph. */
  const onCanvas = (e: React.SyntheticEvent): boolean => e.target instanceof HTMLCanvasElement

  const onPointerDown = (e: React.PointerEvent): void => {
    setMenu(null)
    if (!onCanvas(e)) return
    autoFitRef.current = false // the user is driving now
    zoomAnimRef.current = null
    fitAnimRef.current = 0
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    const hit = pickNode(e.clientX, e.clientY)
    if (e.button === 2) return
    if (hit >= 0) {
      dragRef.current = { node: hit, moved: false }
      const [wx, wy] = toWorld(e.clientX, e.clientY)
      workerRef.current?.postMessage({ type: 'drag', index: hit, x: wx, y: wy })
    } else {
      const cam = cameraRef.current
      panRef.current = { x: e.clientX, y: e.clientY, camX: cam.x, camY: cam.y }
    }
  }

  const onPointerMove = (e: React.PointerEvent): void => {
    const drag = dragRef.current
    if (drag) {
      drag.moved = true
      const [wx, wy] = toWorld(e.clientX, e.clientY)
      workerRef.current?.postMessage({ type: 'drag', index: drag.node, x: wx, y: wy })
      return
    }
    const pan = panRef.current
    if (pan) {
      const cam = cameraRef.current
      cam.x = pan.camX - (e.clientX - pan.x) / cam.scale
      cam.y = pan.camY - (e.clientY - pan.y) / cam.scale
      return
    }
    // The hovered node's name is drawn on the canvas under it (see the render
    // loop), so there's no tooltip to position — just the highlight to set.
    const hit = onCanvas(e) ? pickNode(e.clientX, e.clientY) : -1
    if (hit !== hoverRef.current) {
      hoverRef.current = hit
      hostRef.current!.style.cursor = hit >= 0 ? 'pointer' : ''
    }
  }

  const onPointerUp = (e: React.PointerEvent): void => {
    const drag = dragRef.current
    if (drag) {
      workerRef.current?.postMessage({ type: 'release', index: drag.node })
      if (!drag.moved && graph) {
        const node = graph.nodes[sub.nodes[drag.node]]
        if (node.kind === 'note' || node.kind === 'attachment') {
          void openFile(node.id, { newTab: e.ctrlKey || e.metaKey })
        } else if (node.kind === 'tag') {
          useStore.setState({
            modal: { kind: 'search', initial: `tag:${node.tags[0] ?? node.title.slice(1)}` },
          })
        }
      }
      dragRef.current = null
    }
    panRef.current = null
  }

  const onContextMenu = (e: React.MouseEvent): void => {
    e.preventDefault()
    const hit = pickNode(e.clientX, e.clientY)
    if (hit < 0 || !graph) return
    const rect = hostRef.current!.getBoundingClientRect()
    setMenu({ x: e.clientX - rect.left, y: e.clientY - rect.top, id: graph.nodes[sub.nodes[hit]].id })
  }

  /**
   * Zoom toward a target scale, anchored at a point given relative to the view
   * centre. The render loop glides there; repeated wheel ticks compound on the
   * target rather than the current scale, so a fast flick still lands where
   * the ticks add up to.
   */
  const zoomTo = (factor: number, ax: number, ay: number): void => {
    autoFitRef.current = false
    fitAnimRef.current = 0
    const from = zoomAnimRef.current?.target ?? cameraRef.current.scale
    const target = Math.max(MIN_SCALE, Math.min(MAX_SCALE, from * factor))
    zoomAnimRef.current = { target, ax, ay }
  }

  const onWheel = (e: React.WheelEvent): void => {
    if (!onCanvas(e)) return
    const rect = hostRef.current!.getBoundingClientRect()
    // Keep the world point under the cursor pinned while zooming.
    zoomTo(
      Math.exp(-e.deltaY * 0.0016),
      e.clientX - rect.left - rect.width / 2,
      e.clientY - rect.top - rect.height / 2,
    )
  }

  const zoomBy = (factor: number): void => zoomTo(factor, 0, 0)

  const resetView = (): void => {
    autoFitRef.current = false
    zoomAnimRef.current = null
    fitAnimRef.current = 40
  }

  const onDoubleClick = (e: React.MouseEvent): void => {
    if (onCanvas(e) && pickNode(e.clientX, e.clientY) < 0) resetView()
  }

  // Keyboard: +/- zoom, arrows pan (shift = faster), like Obsidian.
  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    const onKey = (e: KeyboardEvent): void => {
      const step = (e.shiftKey ? 120 : 40) / cameraRef.current.scale
      switch (e.key) {
        case '+':
        case '=':
          zoomBy(1.2)
          break
        case '-':
        case '_':
          zoomBy(1 / 1.2)
          break
        case 'ArrowLeft':
          cameraRef.current.x -= step
          break
        case 'ArrowRight':
          cameraRef.current.x += step
          break
        case 'ArrowUp':
          cameraRef.current.y -= step
          break
        case 'ArrowDown':
          cameraRef.current.y += step
          break
        default:
          return
      }
      e.preventDefault()
    }
    host.addEventListener('keydown', onKey)
    return () => host.removeEventListener('keydown', onKey)
  }, [])

  const stats = `${sub.nodes.length} node${sub.nodes.length === 1 ? '' : 's'} · ${sub.edges.length / 2} link${sub.edges.length / 2 === 1 ? '' : 's'}`

  return (
    <div
      className="graph-view"
      ref={hostRef}
      tabIndex={0}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerLeave={() => {
        hoverRef.current = -1
      }}
      onContextMenu={onContextMenu}
      onWheel={onWheel}
      onDoubleClick={onDoubleClick}
    >
      <canvas className="graph-canvas" ref={glCanvasRef} />
      <canvas className="graph-canvas graph-overlay" ref={labelCanvasRef} />

      {glError && (
        <div
          style={{
            position: 'absolute',
            inset: 0,
            display: 'grid',
            placeItems: 'center',
            padding: 40,
            textAlign: 'center',
            color: 'var(--fg-dim)',
          }}
        >
          <div>
            <div style={{ marginBottom: 8 }}>The graph needs WebGL2, which this system didn't provide.</div>
            <div style={{ fontSize: 12, color: 'var(--fg-subtle)' }}>
              {glError}
              <br />
              On a VM or WSL, launching with <code>--enable-unsafe-swiftshader</code> renders it in
              software.
            </div>
          </div>
        </div>
      )}

      {/* Obsidian's arrangement: the canvas gets the whole view, and the
          settings live behind a cog in the top-right corner. Zooming is the
          wheel, +/- or a double-click on empty space to fit. */}
      {!compact &&
        (panelOpen ? (
          <GraphControls
            cfg={cfg}
            local={local}
            patch={patch}
            legend={tagLegend}
            onClose={() => setPanelOpen(false)}
            onFit={resetView}
            onRelayout={() => {
              autoFitRef.current = true
              zoomAnimRef.current = null
              alphaRef.current = 1
              lastExtentRef.current = 0
              steadyFramesRef.current = 0
              workerRef.current?.postMessage({ type: 'reheat', alpha: 1 })
            }}
            onOpenLocal={
              local
                ? undefined
                : () =>
                    openView('localgraph', { path: useStore.getState().activeTab()?.path ?? null })
            }
            onReset={() =>
              patch(
                local
                  ? { ...DEFAULT_LOCAL_GRAPH }
                  : ({ ...DEFAULT_GRAPH } as Partial<LocalGraphSettings>),
              )
            }
          />
        ) : (
          <button
            className="graph-controls-toggle icon-btn"
            onClick={() => setPanelOpen(true)}
            title="Open graph settings"
          >
            <Icon name="settings" />
          </button>
        ))}

      {menu && (
        <div
          className="context-menu"
          style={{ left: menu.x, top: menu.y, position: 'absolute' }}
          onPointerDown={(e) => e.stopPropagation()}
        >
          <button
            onClick={() => {
              void openFile(menu.id)
              setMenu(null)
            }}
          >
            Open
          </button>
          <button
            onClick={() => {
              void openFile(menu.id, { newTab: true })
              setMenu(null)
            }}
          >
            Open in new tab
          </button>
          <button
            onClick={() => {
              openView('localgraph', { path: menu.id, title: `Local graph: ${menu.id}` })
              setMenu(null)
            }}
          >
            Open local graph
          </button>
          <div className="sep" />
          <button
            onClick={() => {
              patch({ searchQuery: `path:${menu.id.split('/').slice(0, -1).join('/')}` })
              setMenu(null)
            }}
          >
            Filter to this folder
          </button>
        </div>
      )}

      {!compact && (
        <div
          style={{
            position: 'absolute',
            right: 12,
            bottom: 10,
            fontSize: 11,
            color: 'var(--fg-subtle)',
            pointerEvents: 'none',
          }}
        >
          {stats}
          {notes.size === 0 && ' · empty vault'}
        </div>
      )}
    </div>
  )
}

// ------------------------------------------------------------------ panel

function GraphControls({
  cfg,
  local,
  patch,
  legend,
  onClose,
  onFit,
  onRelayout,
  onOpenLocal,
  onReset,
}: {
  cfg: GraphSettings | LocalGraphSettings
  local: boolean
  patch: (p: Partial<LocalGraphSettings>) => void
  legend: Array<{ tag: string; count: number; color: string }>
  onClose: () => void
  onFit: () => void
  onRelayout: () => void
  onOpenLocal?: () => void
  onReset: () => void
}): JSX.Element {
  const [open, setOpen] = useState<Record<string, boolean>>({
    filters: true,
    // Open by default: this is where the tag-color legend lives.
    groups: true,
    display: true,
    forces: true,
  })
  const localCfg = cfg as LocalGraphSettings
  const section = (key: string, title: string, body: JSX.Element): JSX.Element => (
    <div className={`graph-section${open[key] ? '' : ' is-collapsed'}`}>
      <div className="graph-section-head" onClick={() => setOpen({ ...open, [key]: !open[key] })}>
        <Icon name="chevronDown" size={13} className="chev" />
        {title}
      </div>
      <div className="graph-section-body">{body}</div>
    </div>
  )

  return (
    <div className="graph-controls">
      <div className="graph-controls-head">
        <button className="icon-btn" onClick={onFit} title="Zoom to fit (double-click the graph)">
          <Icon name="maximize" size={13} />
        </button>
        <button className="icon-btn" onClick={onRelayout} title="Re-run layout">
          <Icon name="history" size={13} />
        </button>
        {onOpenLocal && (
          <button className="icon-btn" onClick={onOpenLocal} title="Open local graph">
            <Icon name="target" size={13} />
          </button>
        )}
        <span className="graph-controls-spacer" />
        <button className="icon-btn" onClick={onClose} title="Close">
          <Icon name="close" size={13} />
        </button>
      </div>

      {section(
        'filters',
        'Filters',
        <>
          <input
            className="graph-search"
            placeholder="Search files"
            value={cfg.searchQuery}
            onChange={(e) => patch({ searchQuery: e.target.value })}
          />
          <Toggle label="Tags" on={cfg.showTags} onChange={(v) => patch({ showTags: v })} />
          {cfg.showTags && (
            <Toggle
              label="Link nested tags"
              on={cfg.linkNestedTags === true}
              onChange={(v) => patch({ linkNestedTags: v })}
            />
          )}
          <Toggle
            label="Attachments"
            on={cfg.showAttachments}
            onChange={(v) => patch({ showAttachments: v })}
          />
          <Toggle
            label="Existing files only"
            on={cfg.existingOnly}
            onChange={(v) => patch({ existingOnly: v })}
          />
          <Toggle label="Orphans" on={cfg.showOrphans} onChange={(v) => patch({ showOrphans: v })} />
          {local && (
            <>
              <Slider
                label="Depth"
                min={1}
                max={5}
                step={1}
                value={localCfg.depth ?? 1}
                onChange={(v) => patch({ depth: v })}
              />
              <Toggle
                label="Incoming links"
                on={localCfg.incoming !== false}
                onChange={(v) => patch({ incoming: v })}
              />
              <Toggle
                label="Outgoing links"
                on={localCfg.outgoing !== false}
                onChange={(v) => patch({ outgoing: v })}
              />
              <Toggle
                label="Neighbor links"
                on={localCfg.neighborLinks !== false}
                onChange={(v) => patch({ neighborLinks: v })}
              />
            </>
          )}
        </>,
      )}

      {section(
        'groups',
        'Groups',
        <>
          <Toggle
            label="Color by tag"
            on={cfg.colorByTag !== false}
            onChange={(v) => patch({ colorByTag: v })}
          />
          {cfg.colorByTag !== false && legend.length > 0 && (
            <div className="graph-legend">
              {legend.slice(0, 14).map((entry) => (
                <button
                  key={entry.tag}
                  className="graph-legend-row"
                  title={`Filter to #${entry.tag}`}
                  onClick={() => patch({ searchQuery: `tag:${entry.tag}` })}
                >
                  <span className="swatch" style={{ background: entry.color }} />
                  <span className="label">#{entry.tag}</span>
                  <span className="count">{entry.count}</span>
                </button>
              ))}
              {legend.length > 14 && (
                <div className="graph-legend-more">+{legend.length - 14} more</div>
              )}
            </div>
          )}
          {(cfg.groups ?? []).map((g, i) => (
            <div className="graph-group" key={i}>
              <input
                type="text"
                value={g.query}
                placeholder="Search query"
                onChange={(e) => {
                  const groups = [...cfg.groups]
                  groups[i] = { ...g, query: e.target.value }
                  patch({ groups })
                }}
              />
              <input
                type="color"
                value={g.color}
                onChange={(e) => {
                  const groups = [...cfg.groups]
                  groups[i] = { ...g, color: e.target.value }
                  patch({ groups })
                }}
              />
              <button
                className="icon-btn"
                style={{ width: 20, height: 20 }}
                onClick={() => patch({ groups: cfg.groups.filter((_, k) => k !== i) })}
                title="Remove group"
              >
                <Icon name="close" size={12} />
              </button>
            </div>
          ))}
          <button
            className="graph-add-group"
            onClick={() =>
              patch({
                groups: [
                  ...(cfg.groups ?? []),
                  { query: '', color: GROUP_COLORS[(cfg.groups?.length ?? 0) % GROUP_COLORS.length] },
                ],
              })
            }
          >
            + New group
          </button>
        </>,
      )}

      {section(
        'display',
        'Display',
        <>
          <Toggle label="Arrows" on={cfg.arrows} onChange={(v) => patch({ arrows: v })} />
          <Slider
            label="Text fade threshold"
            min={0}
            max={3}
            step={0.05}
            value={cfg.textFadeThreshold}
            onChange={(v) => patch({ textFadeThreshold: v })}
          />
          <Slider
            label="Node size"
            min={0.1}
            max={5}
            step={0.1}
            value={cfg.nodeSize}
            onChange={(v) => patch({ nodeSize: v })}
          />
          <Slider
            label="Link thickness"
            min={0.1}
            max={5}
            step={0.1}
            value={cfg.linkThickness}
            onChange={(v) => patch({ linkThickness: v })}
          />
        </>,
      )}

      {section(
        'forces',
        'Forces',
        <>
          <Slider
            label="Center force"
            min={0}
            max={1}
            step={0.01}
            value={cfg.centerForce}
            onChange={(v) => patch({ centerForce: v })}
          />
          <Slider
            label="Repel force"
            min={0}
            max={20}
            step={0.1}
            value={cfg.repelForce}
            onChange={(v) => patch({ repelForce: v })}
          />
          <Slider
            label="Link force"
            min={0}
            max={1}
            step={0.01}
            value={cfg.linkForce}
            onChange={(v) => patch({ linkForce: v })}
          />
          <Slider
            label="Link distance"
            min={30}
            max={500}
            step={5}
            value={cfg.linkDistance}
            onChange={(v) => patch({ linkDistance: v })}
          />
        </>,
      )}

      <button className="graph-reset" onClick={onReset}>
        Restore default settings
      </button>
    </div>
  )
}

function Toggle({
  label,
  on,
  onChange,
}: {
  label: string
  on: boolean
  onChange: (v: boolean) => void
}): JSX.Element {
  return (
    <div className="graph-row">
      <label onClick={() => onChange(!on)}>{label}</label>
      <div className={`toggle${on ? ' is-on' : ''}`} onClick={() => onChange(!on)} role="switch" />
    </div>
  )
}

function Slider({
  label,
  min,
  max,
  step,
  value,
  onChange,
}: {
  label: string
  min: number
  max: number
  step: number
  value: number
  onChange: (v: number) => void
}): JSX.Element {
  return (
    <div className="graph-row">
      <label title={String(value)}>{label}</label>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
      />
    </div>
  )
}

// ------------------------------------------------------------------ utils

function mix(a: number, b: number, t: number): number {
  return a + (b - a) * t
}

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s
}

/**
 * Center and zoom the camera so the whole layout fits with a margin.
 * `ease` < 1 blends toward the target instead of snapping, which is what the
 * settle-tracking loop wants.
 */
function fitToContent(
  pos: Float32Array,
  n: number,
  width: number,
  height: number,
  cam: Camera,
  ease = 1,
): number {
  if (!n || pos.length < n * 2) return 0
  let minX = Infinity
  let maxX = -Infinity
  let minY = Infinity
  let maxY = -Infinity
  for (let i = 0; i < n; i++) {
    const x = pos[i * 2]
    const y = pos[i * 2 + 1]
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue
    if (x < minX) minX = x
    if (x > maxX) maxX = x
    if (y < minY) minY = y
    if (y > maxY) maxY = y
  }
  if (!Number.isFinite(minX)) return 0
  const w = Math.max(maxX - minX, 1)
  const h = Math.max(maxY - minY, 1)
  const targetX = (minX + maxX) / 2
  const targetY = (minY + maxY) / 2
  // The floor has to be low enough to frame a whole large vault: a 1500-node
  // graph at the default link distance spans tens of thousands of world units.
  const targetScale = Math.max(
    0.0008,
    Math.min(4, Math.min((width * 0.82) / w, (height * 0.82) / h)),
  )
  cam.x += (targetX - cam.x) * ease
  cam.y += (targetY - cam.y) * ease
  // Ease the zoom geometrically so the motion reads as constant-speed.
  cam.scale *= Math.pow(targetScale / cam.scale, ease)
  return Math.max(w, h)
}
