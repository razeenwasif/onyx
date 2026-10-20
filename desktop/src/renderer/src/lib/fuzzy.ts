/**
 * Subsequence fuzzy matching for the quick switcher, the command palette and
 * the command bar: the main process's scorer (search.ts fuzzyScore), kept here
 * so lists filter locally as you type. Null when `needle` isn't a subsequence.
 */
export function fuzzy(needle: string, haystack: string): { score: number; positions: number[] } | null {
  if (!needle) return { score: 0, positions: [] }
  const n = needle.toLowerCase()
  const h = haystack.toLowerCase()
  const positions: number[] = []
  let score = 0
  let hi = 0
  let last = -2
  for (const c of n) {
    const found = h.indexOf(c, hi)
    if (found < 0) return null
    positions.push(found)
    let bonus = 1
    if (found === last + 1) bonus += 8
    if (found === 0) bonus += 10
    else if (/[\s/_\-.]/.test(haystack[found - 1])) bonus += 7
    score += bonus
    last = found
    hi = found + 1
  }
  return { score: score - Math.floor(haystack.length / 12) - Math.floor(positions[0] / 4), positions }
}
