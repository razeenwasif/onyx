/**
 * Full-vault content search with Obsidian/Onyx operators.
 *
 * Supported: bare terms (all must match), `"quoted phrase"`, `tag:foo`,
 * `path:sub/dir`, `file:name`, `line:N`, `-term` to exclude. Terms are
 * case-insensitive unless they contain an uppercase letter (smart case).
 */

import type { NoteMeta, SearchHit } from '../shared/types.js'
import type { Vault } from './vault.js'

export interface Query {
  terms: string[]
  excluded: string[]
  tags: string[]
  paths: string[]
  files: string[]
  line: number | null
  smartCase: boolean
}

export function parseQuery(raw: string): Query {
  const q: Query = {
    terms: [],
    excluded: [],
    tags: [],
    paths: [],
    files: [],
    line: null,
    smartCase: /[A-Z]/.test(raw),
  }
  const re = /"([^"]*)"|(\S+)/g
  for (let m = re.exec(raw); m; m = re.exec(raw)) {
    const tok = m[1] !== undefined ? m[1] : m[2]
    if (!tok) continue
    if (m[1] !== undefined) {
      q.terms.push(tok)
      continue
    }
    if (tok.startsWith('-') && tok.length > 1) {
      q.excluded.push(tok.slice(1))
    } else if (tok.startsWith('tag:') || tok.startsWith('#')) {
      q.tags.push(tok.replace(/^tag:/, '').replace(/^#/, '').toLowerCase())
    } else if (tok.startsWith('path:')) {
      q.paths.push(tok.slice(5).toLowerCase())
    } else if (tok.startsWith('file:')) {
      q.files.push(tok.slice(5).toLowerCase())
    } else if (/^line:\d+$/.test(tok)) {
      q.line = Number(tok.slice(5))
    } else {
      q.terms.push(tok)
    }
  }
  return q
}

/** True when a note satisfies the metadata-only parts of a query. */
export function matchesMeta(meta: NoteMeta, q: Query): boolean {
  for (const t of q.tags) {
    if (!meta.tags.some((x) => x.toLowerCase() === t || x.toLowerCase().startsWith(`${t}/`)))
      return false
  }
  const lowerPath = meta.path.toLowerCase()
  for (const p of q.paths) if (!lowerPath.includes(p)) return false
  const base = lowerPath.split('/').pop() ?? ''
  for (const f of q.files) if (!base.includes(f)) return false
  return true
}

export async function search(vault: Vault, raw: string, limit = 400): Promise<SearchHit[]> {
  const q = parseQuery(raw)
  const hasText = q.terms.length > 0 || q.excluded.length > 0
  const hits: SearchHit[] = []

  const fold = (s: string): string => (q.smartCase ? s : s.toLowerCase())
  const needles = q.terms.map(fold)
  const antiNeedles = q.excluded.map(fold)

  const metas = [...vault.notes.values()].sort((a, b) => b.mtime - a.mtime)
  for (const meta of metas) {
    if (!matchesMeta(meta, q)) continue
    if (!hasText) {
      hits.push({ path: meta.path, title: meta.title, matches: [], score: meta.mtime })
      if (hits.length >= limit) break
      continue
    }

    let content: string
    try {
      // Bulk scan: read through the in-memory cache, not the disk.
      content = await vault.cachedContent(meta.path)
    } catch {
      continue
    }
    const hay = fold(content)
    if (antiNeedles.some((n) => hay.includes(n))) continue
    if (!needles.every((n) => hay.includes(n))) continue

    const lines = content.split(/\r?\n/)
    const matches: SearchHit['matches'] = []
    for (let i = 0; i < lines.length && matches.length < 12; i++) {
      if (q.line !== null && i + 1 !== q.line) continue
      const lineFolded = fold(lines[i])
      for (const n of needles) {
        const at = lineFolded.indexOf(n)
        if (at >= 0) {
          matches.push({ line: i, text: lines[i], from: at, to: at + n.length })
          break
        }
      }
    }
    if (q.line !== null && matches.length === 0) continue
    if (needles.length && matches.length === 0) {
      // Terms matched the document but not any single line (e.g. across lines).
      matches.push({ line: 0, text: lines[0] ?? '', from: 0, to: 0 })
    }
    hits.push({
      path: meta.path,
      title: meta.title,
      matches,
      score: matches.length * 10 + (fold(meta.title).includes(needles[0] ?? '') ? 50 : 0),
    })
    if (hits.length >= limit) break
  }

  hits.sort((a, b) => b.score - a.score || a.path.localeCompare(b.path))
  return hits
}

/**
 * Notes that mention this note's name (or an alias) in plain text without
 * linking it — Obsidian's "Unlinked mentions".
 */
export async function unlinkedMentions(
  vault: Vault,
  rel: string,
): Promise<Array<{ path: string; title: string; contexts: Array<{ line: number; text: string }> }>> {
  const meta = vault.notes.get(rel)
  if (!meta) return []
  const base = (rel.split('/').pop() ?? rel).replace(/\.[^.]+$/, '')
  const names = [base, ...meta.aliases].filter(Boolean).map((n) => n.toLowerCase())
  if (!names.length) return []
  const linked = new Set(vault.backlinks(rel))
  const out: Array<{ path: string; title: string; contexts: Array<{ line: number; text: string }> }> = []

  for (const [other, otherMeta] of vault.notes) {
    if (other === rel) continue
    let content: string
    try {
      content = await vault.cachedContent(other)
    } catch {
      continue
    }
    const lines = content.split(/\r?\n/)
    const contexts: Array<{ line: number; text: string }> = []
    for (let i = 0; i < lines.length && contexts.length < 5; i++) {
      const lower = lines[i].toLowerCase()
      for (const n of names) {
        const at = lower.indexOf(n)
        if (at < 0) continue
        // Skip if this occurrence is already inside a wikilink.
        const before = lines[i].slice(Math.max(0, at - 2), at)
        if (before.includes('[[')) continue
        // Whole-word only.
        const prev = at > 0 ? lower[at - 1] : ' '
        const next = at + n.length < lower.length ? lower[at + n.length] : ' '
        if (/[\w-]/.test(prev) || /[\w-]/.test(next)) continue
        contexts.push({ line: i, text: lines[i].trim() })
        break
      }
    }
    if (contexts.length && !linked.has(other)) {
      out.push({ path: other, title: otherMeta.title, contexts })
    }
  }
  return out.sort((a, b) => a.path.localeCompare(b.path))
}

// ------------------------------------------------------------------ fuzzy

/**
 * Subsequence fuzzy match with bonuses for consecutive runs, word/camel
 * boundaries and start-of-string — the quick switcher / command palette scorer.
 * Returns null when `needle` isn't a subsequence of `haystack`.
 */
export function fuzzyScore(
  needle: string,
  haystack: string,
): { score: number; positions: number[] } | null {
  if (!needle) return { score: 0, positions: [] }
  const n = needle.toLowerCase()
  const h = haystack.toLowerCase()
  const positions: number[] = []
  let score = 0
  let hi = 0
  let lastMatch = -2
  for (let ni = 0; ni < n.length; ni++) {
    const c = n[ni]
    let found = -1
    for (let k = hi; k < h.length; k++) {
      if (h[k] === c) {
        found = k
        break
      }
    }
    if (found < 0) return null
    positions.push(found)
    let bonus = 1
    if (found === lastMatch + 1) bonus += 8
    if (found === 0) bonus += 10
    else {
      const prev = haystack[found - 1]
      if (/[\s/_\-.]/.test(prev)) bonus += 7
      else if (prev === prev.toLowerCase() && haystack[found] !== haystack[found].toLowerCase())
        bonus += 5
    }
    score += bonus
    lastMatch = found
    hi = found + 1
  }
  // Prefer shorter haystacks and earlier first matches.
  score -= Math.floor(haystack.length / 12)
  score -= Math.floor(positions[0] / 4)
  return { score, positions }
}
