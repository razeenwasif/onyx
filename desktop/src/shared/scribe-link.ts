/**
 * Links from notes to Scribe pages. A page is named by its id, so the link
 * survives the page being renamed or moved: `[[scribe:<id>|Title]]`, or a
 * lassoed area of it, `[[scribe:<id>#x,y,w,h|Title]]` in page units. Scribe
 * copies these (⌥⌘L, or Link on a lasso selection). See
 * scribe/crates/scribe-core/src/links.rs for the other side.
 */

export const SCRIBE_SCHEME = 'scribe:'

export interface ScribeTarget {
  pageId: string
  /** The linked area of the page, in page units, if any. */
  area: { x: number; y: number; width: number; height: number } | null
}

export function isScribeTarget(target: string): boolean {
  return target.trim().toLowerCase().startsWith(SCRIBE_SCHEME)
}

/** Parses a wikilink target (no `|alias`), or null if it isn't a Scribe link. */
export function parseScribeTarget(target: string): ScribeTarget | null {
  const t = target.trim()
  if (!isScribeTarget(t)) return null
  const rest = t.slice(SCRIBE_SCHEME.length)
  const hash = rest.indexOf('#')
  const pageId = (hash >= 0 ? rest.slice(0, hash) : rest).trim()
  if (!pageId) return null
  let area: ScribeTarget['area'] = null
  if (hash >= 0) {
    const n = rest
      .slice(hash + 1)
      .split(',')
      .map((s) => Number(s.trim()))
    if (n.length === 4 && n.every(Number.isFinite) && n[2] > 0 && n[3] > 0) {
      area = { x: n[0], y: n[1], width: n[2], height: n[3] }
    }
  }
  return { pageId, area }
}

/** The whole wikilink for a page, shown as `title` where the note is read. */
export function scribeLink(pageId: string, title: string): string {
  const shown = title.replace(/\|/g, '-').replace(/\[/g, '(').replace(/\]/g, ')').trim() || 'Untitled'
  return `[[${SCRIBE_SCHEME}${pageId}|${shown}]]`
}

/** The graph node id for a Scribe page. */
export function scribeNodeId(pageId: string): string {
  return `${SCRIBE_SCHEME}${pageId}`
}
