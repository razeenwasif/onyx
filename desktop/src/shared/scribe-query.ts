/**
 * The part of a search worth sending to Scribe, or null. Scribe matches plain
 * text; Electron's search operators (`tag:`, `path:`, `file:`, `line:`, and
 * `-term` to exclude) mean nothing there, so a query using one is answered by
 * the vault alone rather than with a misleading plain-text match.
 */
export function scribeQuery(raw: string): string | null {
  const q = raw.trim().replace(/^"(.*)"$/, '$1').trim()
  if (!q) return null
  if (/(^|\s)(tag|path|file|line):/i.test(q) || /(^|\s)-\S/.test(q)) return null
  return q
}
