/**
 * Scribe pages in the vault's graph and backlinks. Notes link to pages with
 * `[[scribe:<id>|…]]`; pages link to notes with `[[Note]]` typed in a text
 * box or table (Scribe's link index lists those). Kept apart from scribe.ts
 * so it can be tested without Electron.
 */

import type { BacklinkRef, GraphData, GraphLink, NoteMeta, ScribePage } from '../shared/types.js'
import { isScribeTarget, parseScribeTarget, scribeNodeId } from '../shared/scribe-link.js'

type Resolve = (target: string, from?: string) => string | null

/**
 * `graph` with the Scribe pages that link or are linked added as `scribe`
 * nodes. Pages nothing links to, and links to pages that are gone, are left
 * out: the graph shows how notes and pages connect, not the whole library.
 */
export function graphWithScribe(
  graph: GraphData,
  notes: Map<string, NoteMeta>,
  resolve: Resolve,
  pages: ScribePage[],
): GraphData {
  if (!pages.length) return graph
  const byId = new Map(pages.map((p) => [p.id, p]))
  const nodes = graph.nodes.map((n) => ({ ...n }))
  const links: GraphLink[] = [...graph.links]
  const index = new Map(nodes.map((n, i) => [n.id, i]))
  const seen = new Set(links.map((l) => `${l.source} ${l.target} ${l.kind}`))

  const pageNode = (page: ScribePage): number => {
    const id = scribeNodeId(page.id)
    const hit = index.get(id)
    if (hit !== undefined) return hit
    nodes.push({
      id,
      title: page.title,
      kind: 'scribe',
      degree: 0,
      folder: ['Scribe', page.notebook, page.section].filter(Boolean).join('/'),
      tags: [],
    })
    index.set(id, nodes.length - 1)
    return nodes.length - 1
  }
  const link = (a: number, b: number): void => {
    const key = `${a} ${b} link`
    if (a === b || seen.has(key)) return
    seen.add(key)
    links.push({ source: a, target: b, kind: 'link' })
    nodes[a].degree++
    nodes[b].degree++
  }

  for (const [rel, meta] of notes) {
    const from = index.get(rel)
    if (from === undefined) continue
    for (const raw of meta.targets) {
      const page = byId.get(parseScribeTarget(raw)?.pageId ?? '')
      if (page) link(from, pageNode(page))
    }
  }
  for (const page of pages) {
    for (const raw of page.links) {
      if (isScribeTarget(raw)) {
        const other = byId.get(parseScribeTarget(raw)?.pageId ?? '')
        if (other) link(pageNode(page), pageNode(other))
        continue
      }
      const note = resolve(raw)
      const to = note ? index.get(note) : undefined
      if (to !== undefined) link(pageNode(page), to)
    }
  }
  return { nodes, links }
}

/** The Scribe pages with a `[[…]]` typed on them that resolves to `rel`. */
export function scribeBacklinks(rel: string, resolve: Resolve, pages: ScribePage[]): BacklinkRef[] {
  return pages
    .filter((p) => p.links.some((raw) => !isScribeTarget(raw) && resolve(raw) === rel))
    .map((p) => ({ path: p.path, title: p.title, scribe: { id: p.id, notebook: p.notebook, section: p.section } }))
    .sort((a, b) => a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' }))
}
