/**
 * Force-directed layout, off the main thread.
 *
 * The model is d3-force's (which is what Obsidian uses): a Barnes-Hut
 * many-body charge, a link spring toward a target distance, a weak pull toward
 * the origin, and Verlet integration with a cooling `alpha`. The four sliders
 * in the Forces panel map one-to-one onto those forces.
 *
 * Positions ping-pong between here and the renderer on a transferable
 * Float32Array so a 10k-node graph costs no per-frame allocation.
 */

export interface InitMessage {
  type: 'init'
  count: number
  /** Flat [sourceIndex, targetIndex, …]. */
  edges: Int32Array
  /** Per-node initial positions (or empty for a fresh spiral seed). */
  positions?: Float32Array
  /** Indices pinned to the origin (the focused note in a local graph). */
  pinned: number[]
  params: Params
}

export interface Params {
  centerForce: number
  repelForce: number
  linkForce: number
  linkDistance: number
  /** Keep simulating forever with a floor on alpha (Obsidian's gentle drift). */
  alive: boolean
}

type Message =
  | InitMessage
  | { type: 'params'; params: Params }
  | { type: 'drag'; index: number; x: number; y: number }
  | { type: 'release'; index: number }
  | { type: 'reheat'; alpha?: number }
  | { type: 'buffer'; buffer: ArrayBuffer }
  | { type: 'stop' }

const ALPHA_MIN = 0.001
const ALPHA_DECAY = 1 - Math.pow(ALPHA_MIN, 1 / 300)
const ALPHA_TARGET_ALIVE = 0.012
const VELOCITY_DECAY = 0.4
/** Scales the Center force slider (0–1) into a per-tick pull toward the origin. */
const CENTER_GAIN = 0.02
const THETA2 = 0.81 // Barnes-Hut opening angle squared (θ = 0.9)
const JIGGLE = 1e-6

let n = 0
let x = new Float32Array(0)
let y = new Float32Array(0)
let vx = new Float32Array(0)
let vy = new Float32Array(0)
let degree = new Int32Array(0)
let fixed = new Uint8Array(0)
let edgeSrc = new Int32Array(0)
let edgeDst = new Int32Array(0)
/** Per-link bias, d3's `1 / min(deg(source), deg(target))`. */
let bias = new Float32Array(0)
let linkStrength = new Float32Array(0)

let params: Params = {
  centerForce: 0.3,
  repelForce: 10,
  linkForce: 1,
  linkDistance: 250,
  alive: true,
}

let alpha = 1
let running = false
let spare: Float32Array | null = null
let rngState = 0x9e3779b9

/** xorshift32 → [-0.5, 0.5), for breaking exact coincidences. */
function rand(): number {
  rngState ^= rngState << 13
  rngState ^= rngState >>> 17
  rngState ^= rngState << 5
  return (rngState >>> 0) / 4294967296 - 0.5
}

function jiggle(): number {
  return (rand() * 2 - 0) * JIGGLE + JIGGLE
}

// ------------------------------------------------------------- quadtree

/**
 * Flat Barnes-Hut quadtree. Each cell is 9 numbers in `qt`:
 * [cx, cy, half, comX, comY, mass, body, firstChild, nextSibling] — an arena
 * of typed arrays, rebuilt every tick without allocating.
 */
let qtCx = new Float32Array(0)
let qtCy = new Float32Array(0)
let qtHalf = new Float32Array(0)
let qtSumX = new Float32Array(0)
let qtSumY = new Float32Array(0)
let qtMass = new Float32Array(0)
let qtBody = new Int32Array(0)
let qtChild = new Int32Array(0) // 4 per cell
let qtCount = 0

function qtEnsure(cap: number): void {
  if (qtCx.length >= cap) return
  const size = Math.max(cap, 64)
  qtCx = new Float32Array(size)
  qtCy = new Float32Array(size)
  qtHalf = new Float32Array(size)
  qtSumX = new Float32Array(size)
  qtSumY = new Float32Array(size)
  qtMass = new Float32Array(size)
  qtBody = new Int32Array(size)
  qtChild = new Int32Array(size * 4)
}

function qtNew(cx: number, cy: number, half: number): number {
  const i = qtCount++
  qtCx[i] = cx
  qtCy[i] = cy
  qtHalf[i] = half
  qtSumX[i] = 0
  qtSumY[i] = 0
  qtMass[i] = 0
  qtBody[i] = -1
  qtChild[i * 4] = -1
  qtChild[i * 4 + 1] = -1
  qtChild[i * 4 + 2] = -1
  qtChild[i * 4 + 3] = -1
  return i
}

function qtInsert(root: number, b: number): void {
  let cell = root
  for (let depth = 0; depth < 48; depth++) {
    qtSumX[cell] += x[b]
    qtSumY[cell] += y[b]
    qtMass[cell] += 1

    if (qtMass[cell] === 1) {
      qtBody[cell] = b
      return
    }
    // Degenerate cell (coincident points): keep it as a cluster.
    if (qtHalf[cell] < 1e-3) {
      qtBody[cell] = -1
      return
    }
    const existing = qtBody[cell]
    if (existing >= 0) {
      qtBody[cell] = -1
      pushDown(cell, existing)
    }
    const q = quadrant(cell, x[b], y[b])
    let child = qtChild[cell * 4 + q]
    if (child < 0) {
      child = makeChild(cell, q)
    }
    cell = child
  }
}

function quadrant(cell: number, px: number, py: number): number {
  return (py >= qtCy[cell] ? 2 : 0) + (px >= qtCx[cell] ? 1 : 0)
}

function makeChild(cell: number, q: number): number {
  const hh = qtHalf[cell] / 2
  const ncx = q & 1 ? qtCx[cell] + hh : qtCx[cell] - hh
  const ncy = q & 2 ? qtCy[cell] + hh : qtCy[cell] - hh
  qtEnsure(qtCount + 1)
  const c = qtNew(ncx, ncy, hh)
  qtChild[cell * 4 + q] = c
  return c
}

/** Re-insert a body that was sitting in a cell that just subdivided. */
function pushDown(cell: number, b: number): void {
  let cur = cell
  for (let depth = 0; depth < 48; depth++) {
    if (qtHalf[cur] < 1e-3) {
      return
    }
    const q = quadrant(cur, x[b], y[b])
    let child = qtChild[cur * 4 + q]
    if (child < 0) child = makeChild(cur, q)
    qtSumX[child] += x[b]
    qtSumY[child] += y[b]
    qtMass[child] += 1
    if (qtMass[child] === 1) {
      qtBody[child] = b
      return
    }
    const other = qtBody[child]
    if (other >= 0) {
      qtBody[child] = -1
      cur = child
      // Continue the loop for `b`, but first sink `other` one more level.
      sinkOne(child, other)
      continue
    }
    cur = child
  }
}

function sinkOne(cell: number, b: number): void {
  if (qtHalf[cell] < 1e-3) return
  const q = quadrant(cell, x[b], y[b])
  let child = qtChild[cell * 4 + q]
  if (child < 0) child = makeChild(cell, q)
  qtSumX[child] += x[b]
  qtSumY[child] += y[b]
  qtMass[child] += 1
  if (qtMass[child] === 1) {
    qtBody[child] = b
    return
  }
  const other = qtBody[child]
  if (other >= 0) {
    qtBody[child] = -1
    sinkOne(child, other)
  }
  sinkOne(child, b)
}

function buildTree(): number {
  qtCount = 0
  if (!n) return -1
  let minX = x[0]
  let maxX = x[0]
  let minY = y[0]
  let maxY = y[0]
  for (let i = 1; i < n; i++) {
    if (x[i] < minX) minX = x[i]
    else if (x[i] > maxX) maxX = x[i]
    if (y[i] < minY) minY = y[i]
    else if (y[i] > maxY) maxY = y[i]
  }
  const cx = (minX + maxX) / 2
  const cy = (minY + maxY) / 2
  const half = Math.max((maxX - minX) / 2, (maxY - minY) / 2, 1) * 1.05

  // Worst case a quadtree over n bodies needs a few cells per body.
  qtEnsure(Math.max(64, n * 4))
  const root = qtNew(cx, cy, half)
  for (let i = 0; i < n; i++) qtInsert(root, i)
  return root
}

// ---------------------------------------------------------------- forces

const stack = new Int32Array(4096)

function applyCharge(strength: number, a: number): void {
  const root = buildTree()
  if (root < 0) return
  for (let i = 0; i < n; i++) {
    let sp = 0
    stack[sp++] = root
    let fx = 0
    let fy = 0
    while (sp > 0) {
      const cell = stack[--sp]
      const mass = qtMass[cell]
      if (mass === 0) continue
      const body = qtBody[cell]
      if (body === i && mass === 1) continue

      const comX = qtSumX[cell] / mass
      const comY = qtSumY[cell] / mass
      let dx = comX - x[i]
      let dy = comY - y[i]
      let d2 = dx * dx + dy * dy
      if (d2 === 0) {
        dx = jiggle()
        dy = jiggle()
        d2 = dx * dx + dy * dy
      }
      const w = qtHalf[cell] * 2

      if (body >= 0 || (w * w) / d2 < THETA2) {
        // Leaf, or far enough away to treat as a single body.
        if (body === i) continue
        const k = (strength * mass * a) / d2
        fx += dx * k
        fy += dy * k
      } else {
        const base = cell * 4
        for (let q = 0; q < 4; q++) {
          const c = qtChild[base + q]
          if (c >= 0 && sp < stack.length) stack[sp++] = c
        }
      }
    }
    vx[i] += fx
    vy[i] += fy
  }
}

function applyLinks(a: number): void {
  const m = edgeSrc.length
  const dist = params.linkDistance
  for (let k = 0; k < m; k++) {
    const s = edgeSrc[k]
    const t = edgeDst[k]
    let dx = x[t] + vx[t] - x[s] - vx[s]
    let dy = y[t] + vy[t] - y[s] - vy[s]
    let l = Math.sqrt(dx * dx + dy * dy)
    if (l === 0) {
      dx = jiggle()
      dy = jiggle()
      l = Math.sqrt(dx * dx + dy * dy)
    }
    l = ((l - dist) / l) * a * linkStrength[k]
    dx *= l
    dy *= l
    const b = bias[k]
    vx[t] -= dx * b
    vy[t] -= dy * b
    vx[s] += dx * (1 - b)
    vy[s] += dy * (1 - b)
  }
}

function applyCenter(a: number): void {
  // A gentle radial pull, not d3's centroid translation: it has to be weak
  // enough that the link springs, not the centering, set the graph's size.
  const k = params.centerForce * a * CENTER_GAIN
  if (k <= 0) return
  for (let i = 0; i < n; i++) {
    vx[i] -= x[i] * k
    vy[i] -= y[i] * k
  }
}

/**
 * Charge strength for the current sliders.
 *
 * Repulsion has to scale with the square of the link distance, or the two
 * forces stop being comparable and the graph either collapses into a ball or
 * explodes when the distance slider moves. Balancing a single spring against a
 * single charge at equilibrium `d ≈ 1.1 × linkDistance` gives
 * `|S| ≈ 0.11 × linkDistance²`, which is where the constant comes from; the
 * Repel force slider then scales around that (10 = neutral).
 */
function chargeStrength(): number {
  return -params.repelForce * params.linkDistance * params.linkDistance * 0.011
}

function tick(): void {
  const target = params.alive ? ALPHA_TARGET_ALIVE : 0
  alpha += (target - alpha) * ALPHA_DECAY

  applyCharge(chargeStrength(), alpha)
  applyLinks(alpha)
  applyCenter(alpha)

  const decay = 1 - VELOCITY_DECAY
  for (let i = 0; i < n; i++) {
    if (fixed[i]) {
      vx[i] = 0
      vy[i] = 0
      continue
    }
    vx[i] *= decay
    vy[i] *= decay
    x[i] += vx[i]
    y[i] += vy[i]
  }
}

// ------------------------------------------------------------------ loop

function post(): void {
  const buf = spare && spare.length === n * 2 ? spare : new Float32Array(n * 2)
  spare = null
  for (let i = 0; i < n; i++) {
    buf[i * 2] = x[i]
    buf[i * 2 + 1] = y[i]
  }
  ;(self as unknown as Worker).postMessage({ type: 'positions', positions: buf, alpha }, [
    buf.buffer,
  ])
}

let timer: ReturnType<typeof setInterval> | null = null

function start(): void {
  if (timer) return
  running = true
  timer = setInterval(() => {
    if (!running) return
    // Two integration steps per post keeps the layout snappy without doubling
    // the message rate.
    tick()
    tick()
    post()
  }, 1000 / 60)
}

function stop(): void {
  running = false
  if (timer) clearInterval(timer)
  timer = null
}

function seed(count: number, existing?: Float32Array): void {
  n = count
  x = new Float32Array(n)
  y = new Float32Array(n)
  vx = new Float32Array(n)
  vy = new Float32Array(n)
  fixed = new Uint8Array(n)
  for (let i = 0; i < n; i++) {
    if (existing && existing.length >= (i + 1) * 2 && Number.isFinite(existing[i * 2])) {
      x[i] = existing[i * 2]
      y[i] = existing[i * 2 + 1]
      continue
    }
    // Phyllotaxis seed — spreads the first frame evenly instead of a thin ring,
    // at roughly the scale the link springs will settle at.
    const t = i
    const radius = params.linkDistance * 0.4 * Math.sqrt(t + 0.5)
    const angle = t * 2.399963229728653
    x[i] = radius * Math.cos(angle)
    y[i] = radius * Math.sin(angle)
  }
}

self.onmessage = (e: MessageEvent<Message>): void => {
  const msg = e.data
  switch (msg.type) {
    case 'init': {
      stop()
      params = msg.params
      seed(msg.count, msg.positions)
      const m = msg.edges.length / 2
      edgeSrc = new Int32Array(m)
      edgeDst = new Int32Array(m)
      degree = new Int32Array(n)
      for (let k = 0; k < m; k++) {
        const s = msg.edges[k * 2]
        const t = msg.edges[k * 2 + 1]
        edgeSrc[k] = s
        edgeDst[k] = t
        degree[s]++
        degree[t]++
      }
      bias = new Float32Array(m)
      linkStrength = new Float32Array(m)
      for (let k = 0; k < m; k++) {
        const ds = degree[edgeSrc[k]]
        const dt = degree[edgeDst[k]]
        bias[k] = ds / (ds + dt || 1)
        linkStrength[k] = (params.linkForce * 1) / Math.min(ds || 1, dt || 1)
      }
      for (const i of msg.pinned) {
        if (i >= 0 && i < n) {
          fixed[i] = 1
          x[i] = 0
          y[i] = 0
        }
      }
      alpha = 1
      start()
      break
    }
    case 'params': {
      const prevLink = params.linkForce
      params = msg.params
      if (prevLink !== params.linkForce) {
        for (let k = 0; k < linkStrength.length; k++) {
          const ds = degree[edgeSrc[k]]
          const dt = degree[edgeDst[k]]
          linkStrength[k] = (params.linkForce * 1) / Math.min(ds || 1, dt || 1)
        }
      }
      alpha = Math.max(alpha, 0.35)
      if (params.alive) start()
      break
    }
    case 'drag': {
      if (msg.index >= 0 && msg.index < n) {
        fixed[msg.index] = 1
        x[msg.index] = msg.x
        y[msg.index] = msg.y
        vx[msg.index] = 0
        vy[msg.index] = 0
      }
      alpha = Math.max(alpha, 0.3)
      break
    }
    case 'release': {
      if (msg.index >= 0 && msg.index < n) fixed[msg.index] = 0
      alpha = Math.max(alpha, 0.3)
      break
    }
    case 'reheat': {
      alpha = msg.alpha ?? 1
      start()
      break
    }
    case 'buffer': {
      spare = new Float32Array(msg.buffer)
      break
    }
    case 'stop':
      stop()
      break
  }
}
