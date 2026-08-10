/**
 * Extract wikilinks, markdown links, tags and frontmatter from raw markdown.
 *
 * A faithful TypeScript port of `src/markdown/parse.rs` so the desktop app and
 * the TUI agree on what a link, a tag, and a property are. Lives in `shared/`
 * because the renderer needs the same rules for autocomplete and live preview.
 *
 * Wikilinks: `[[Target]]`, `[[Target|Alias]]`, `[[Target#Heading]]`,
 *            `[[Target#Heading|Alias]]`, `[[Target^block]]`.
 * Tags: `#tag`, `#nested/tag`. Skipped inside code spans and fenced code blocks.
 */

export interface WikiLinkMatch {
  target: string
  alias: string | null
  start: number
  end: number
  /** True for `![[embed]]`. */
  embed: boolean
}

const WIKILINK_RE = /(!?)\[\[([^[\]\n]+?)\]\]/g
const MDLINK_RE = /(!?)\[[^\]\n]*\]\(([^)\n]+)\)/g
const TAG_RE = /(^|[^\w&])#([A-Za-z][\w/-]*)/g
const FENCE_RE = /^(?:```|~~~).*$/gm

/** The note name of a wikilink target (no `#heading` / `^block` suffix). */
export function noteName(target: string): string {
  const hash = target.indexOf('#')
  const caret = target.indexOf('^')
  let cut = -1
  if (hash >= 0 && caret >= 0) cut = Math.min(hash, caret)
  else if (hash >= 0) cut = hash
  else if (caret >= 0) cut = caret
  return cut >= 0 ? target.slice(0, cut) : target
}

/** The heading/block anchor of a wikilink target, or null. */
export function linkAnchor(target: string): { kind: 'heading' | 'block'; value: string } | null {
  const hash = target.indexOf('#')
  if (hash >= 0) {
    const rest = target.slice(hash + 1)
    if (rest.startsWith('^')) return { kind: 'block', value: rest.slice(1) }
    return { kind: 'heading', value: rest }
  }
  const caret = target.indexOf('^')
  if (caret >= 0) return { kind: 'block', value: target.slice(caret + 1) }
  return null
}

/**
 * Character ranges of `source` that link/tag scanning must ignore: fenced code
 * blocks and inline code spans.
 */
export function excludedRanges(source: string): Array<[number, number]> {
  const ranges: Array<[number, number]> = []

  // Fenced code blocks: pair up ``` / ~~~ lines.
  const fences: Array<[number, number]> = []
  FENCE_RE.lastIndex = 0
  for (let m = FENCE_RE.exec(source); m; m = FENCE_RE.exec(source)) {
    fences.push([m.index, m.index + m[0].length])
  }
  for (let i = 0; i + 1 < fences.length; i += 2) {
    ranges.push([fences[i][0], fences[i + 1][1]])
  }
  if (fences.length % 2 === 1) {
    ranges.push([fences[fences.length - 1][0], source.length])
  }

  // Inline code spans: balanced backticks on a single line.
  for (let i = 0; i < source.length; i++) {
    if (source[i] !== '`' || inRange(i, ranges)) continue
    const rest = source.slice(i + 1)
    const rel = rest.indexOf('`')
    if (rel < 0) continue
    if (rest.slice(0, rel).includes('\n')) continue
    const end = i + 1 + rel + 1
    ranges.push([i, end])
    i = end - 1
  }

  ranges.sort((a, b) => a[0] - b[0])
  return ranges
}

export function inRange(pos: number, ranges: Array<[number, number]>): boolean {
  for (const [a, b] of ranges) {
    if (pos >= a && pos < b) return true
    if (a > pos) break
  }
  return false
}

export function extractLinks(source: string): WikiLinkMatch[] {
  const excluded = excludedRanges(source)
  const out: WikiLinkMatch[] = []
  WIKILINK_RE.lastIndex = 0
  for (let m = WIKILINK_RE.exec(source); m; m = WIKILINK_RE.exec(source)) {
    if (inRange(m.index, excluded)) continue
    const inner = m[2]
    const bar = inner.indexOf('|')
    const target = (bar >= 0 ? inner.slice(0, bar) : inner).trim()
    const alias = bar >= 0 ? inner.slice(bar + 1).trim() : null
    if (!target) continue
    out.push({ target, alias, start: m.index, end: m.index + m[0].length, embed: m[1] === '!' })
  }
  return out
}

/**
 * Inline `[text](dest)` targets that point at local notes, normalized to a
 * resolvable note target (percent-decoded, `.md` stripped, anchor removed).
 * Web URLs, mailto:, and pure anchors are skipped, as are links inside code.
 */
export function extractMdLinks(source: string): string[] {
  const excluded = excludedRanges(source)
  const out: string[] = []
  MDLINK_RE.lastIndex = 0
  for (let m = MDLINK_RE.exec(source); m; m = MDLINK_RE.exec(source)) {
    if (inRange(m.index, excluded)) continue
    const target = normalizeMdDest(m[2].trim())
    if (target) out.push(target)
  }
  return out
}

/** Raw markdown link destination → resolvable note target, or null. */
export function normalizeMdDest(raw: string): string | null {
  let dest = raw.split(/\s+/)[0] ?? raw
  dest = dest.replace(/^</, '').replace(/>$/, '')
  if (!dest) return null
  if (dest.startsWith('#')) return null
  if (hasUriScheme(dest)) return null
  dest = dest.split('#')[0].split('^')[0]
  dest = percentDecode(dest).trim()
  if (!dest) return null
  const lower = dest.toLowerCase()
  let stem: string | null = null
  for (const ext of ['.md', '.markdown', '.mdx']) {
    if (lower.endsWith(ext)) {
      stem = dest.slice(0, dest.length - ext.length)
      break
    }
  }
  if (!stem) return null
  return stem || null
}

/** True if `s` begins with a real URI scheme (not a `C:` drive letter). */
export function hasUriScheme(s: string): boolean {
  const idx = s.indexOf(':')
  if (idx < 0) return false
  const scheme = s.slice(0, idx)
  if (scheme.length <= 1) return false
  if (!/^[A-Za-z][A-Za-z0-9+\-.]*$/.test(scheme)) return false
  return true
}

/** Minimal percent-decoding; malformed escapes are left as-is. */
export function percentDecode(s: string): string {
  return s.replace(/%[0-9A-Fa-f]{2}/g, (m) => {
    try {
      return decodeURIComponent(m)
    } catch {
      return m
    }
  })
}

/** Inline `#tags` in the body (frontmatter tags are handled separately). */
export function extractInlineTags(source: string): string[] {
  const excluded = excludedRanges(source)
  const out: string[] = []
  TAG_RE.lastIndex = 0
  for (let m = TAG_RE.exec(source); m; m = TAG_RE.exec(source)) {
    const at = m.index + m[1].length
    if (inRange(at, excluded)) continue
    out.push(m[2])
  }
  return out
}

/** Inline tags with their source offsets — used by the editor decorations. */
export function extractInlineTagSpans(
  source: string,
): Array<{ tag: string; start: number; end: number }> {
  const excluded = excludedRanges(source)
  const out: Array<{ tag: string; start: number; end: number }> = []
  TAG_RE.lastIndex = 0
  for (let m = TAG_RE.exec(source); m; m = TAG_RE.exec(source)) {
    const at = m.index + m[1].length
    if (inRange(at, excluded)) continue
    out.push({ tag: m[2], start: at, end: at + 1 + m[2].length })
  }
  return out
}

// ------------------------------------------------------------ frontmatter

/** The raw frontmatter body lines, or null when there is no frontmatter. */
function frontmatterLines(source: string): string[] | null {
  const src = source.startsWith('﻿') ? source.slice(1) : source
  const lines = src.split(/\r?\n/)
  if (lines.length === 0 || lines[0].trim() !== '---') return null
  const fm: string[] = []
  for (let i = 1; i < lines.length; i++) {
    const t = lines[i].trim()
    if (t === '---' || t === '...') return fm
    fm.push(lines[i])
  }
  return null // unterminated
}

/** A leading UTF-8 BOM, which Notion exports (and Windows editors) write. */
const BOM = '﻿'

/**
 * Character length of the frontmatter block including both fences, or 0.
 *
 * The result is an offset into `source` exactly as passed in, so the BOM has to
 * be added back on: the match runs against the stripped string, and returning
 * an offset into *that* is one character short on every BOM-prefixed note —
 * enough to leave the caller pointing at the closing `---` instead of the body,
 * which makes Live Preview show raw YAML instead of the properties table.
 */
export function frontmatterLength(source: string): number {
  const bom = source.startsWith(BOM) ? BOM.length : 0
  const src = bom ? source.slice(bom) : source
  if (!/^---\r?\n/.test(src)) return 0
  const m = /\r?\n(?:---|\.\.\.)[ \t]*(\r?\n|$)/.exec(src)
  if (!m) return 0
  return bom + m.index + m[0].length
}

/** Body with any leading frontmatter block removed. */
export function stripFrontmatter(source: string): string {
  const n = frontmatterLength(source)
  return n > 0 ? source.slice(n) : source
}

function cleanScalar(s: string): string {
  let t = s.trim()
  if (t.length >= 2) {
    const a = t[0]
    const b = t[t.length - 1]
    if ((a === '"' && b === '"') || (a === "'" && b === "'")) t = t.slice(1, -1)
  }
  return t.trim()
}

function cleanTag(s: string): string {
  return cleanScalar(s).replace(/^#+/, '').trim()
}

/** Tags declared in frontmatter (`tags:`/`tag:`, inline or block list). */
export function extractFrontmatterTags(source: string): string[] {
  const fm = frontmatterLines(source)
  if (!fm) return []
  const out: string[] = []
  let i = 0
  while (i < fm.length) {
    const trimmed = fm[i].replace(/^\s+/, '')
    const lower = trimmed.toLowerCase()
    if (lower.startsWith('tags:') || lower.startsWith('tag:')) {
      const colon = trimmed.indexOf(':')
      const value = trimmed.slice(colon + 1).trim()
      if (value) {
        const cleaned = value.replace(/^\[/, '').replace(/\]$/, '')
        for (const part of cleaned.split(',')) {
          const t = cleanTag(part)
          if (t) out.push(t)
        }
      } else {
        let j = i + 1
        while (j < fm.length) {
          const lt = fm[j].replace(/^\s+/, '')
          if (!lt.startsWith('-')) break
          const t = cleanTag(lt.slice(1))
          if (t) out.push(t)
          j++
        }
        i = j
        continue
      }
    }
    i++
  }
  return [...new Set(out)].sort()
}

/** Aliases declared in frontmatter (`aliases:`/`alias:`). */
export function extractFrontmatterAliases(source: string): string[] {
  const fm = frontmatterLines(source)
  if (!fm) return []
  const out: string[] = []
  let i = 0
  while (i < fm.length) {
    const trimmed = fm[i].replace(/^\s+/, '')
    const lower = trimmed.toLowerCase()
    if (lower.startsWith('aliases:') || lower.startsWith('alias:')) {
      const colon = trimmed.indexOf(':')
      const value = trimmed.slice(colon + 1).trim()
      if (value) {
        const cleaned = value.replace(/^\[/, '').replace(/\]$/, '')
        for (const part of cleaned.split(',')) {
          const v = cleanScalar(part)
          if (v) out.push(v)
        }
      } else {
        let j = i + 1
        while (j < fm.length) {
          const lt = fm[j].replace(/^\s+/, '')
          if (!lt.startsWith('-')) break
          const v = cleanScalar(lt.slice(1))
          if (v) out.push(v)
          j++
        }
        i = j
        continue
      }
    }
    i++
  }
  return [...new Set(out)]
}

/**
 * All top-level frontmatter keys as ordered `[key, values]` pairs. A scalar
 * becomes a single-element array; `[a, b]` and indented `- item` lists become
 * multi-element. Scalars are never comma-split.
 */
export function extractFrontmatterProperties(source: string): Array<[string, string[]]> {
  const fm = frontmatterLines(source)
  if (!fm) return []
  const out: Array<[string, string[]]> = []
  let i = 0
  while (i < fm.length) {
    const raw = fm[i]
    const trimmed = raw.replace(/^\s+/, '')
    const indent = raw.length - trimmed.length
    if (indent > 0 || !trimmed || trimmed.startsWith('#')) {
      i++
      continue
    }
    const colon = trimmed.indexOf(':')
    if (colon < 0) {
      i++
      continue
    }
    const key = trimmed.slice(0, colon).trim()
    if (!key) {
      i++
      continue
    }
    const value = trimmed.slice(colon + 1).trim()
    const vals: string[] = []
    if (!value) {
      let j = i + 1
      while (j < fm.length) {
        const lt = fm[j].replace(/^\s+/, '')
        if (!lt.startsWith('-')) break
        const v = cleanScalar(lt.slice(1))
        if (v) vals.push(v)
        j++
      }
      out.push([key, vals])
      i = j
      continue
    } else if (value.startsWith('[') && value.endsWith(']')) {
      for (const part of value.slice(1, -1).split(',')) {
        const v = cleanScalar(part)
        if (v) vals.push(v)
      }
    } else {
      const v = cleanScalar(value)
      if (v) vals.push(v)
    }
    out.push([key, vals])
    i++
  }
  return out
}

/** Frontmatter tags plus inline body tags, deduped and sorted. */
export function extractAllTags(source: string): string[] {
  const set = new Set<string>(extractFrontmatterTags(source))
  for (const t of extractInlineTags(stripFrontmatter(source))) set.add(t)
  return [...set].sort()
}

/** First `# H1` in the body, else null. */
export function firstHeading(source: string): string | null {
  const body = stripFrontmatter(source)
  const m = /^#[ \t]+(.+)$/m.exec(body)
  return m ? m[1].trim() : null
}

/** Every ATX heading with its 0-based line number (fenced code skipped). */
export function extractHeadings(source: string): Array<{ level: number; text: string; line: number }> {
  const out: Array<{ level: number; text: string; line: number }> = []
  const lines = source.split(/\r?\n/)
  let inFence = false
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (/^\s*(?:```|~~~)/.test(line)) {
      inFence = !inFence
      continue
    }
    if (inFence) continue
    const m = /^(#{1,6})[ \t]+(.*)$/.exec(line)
    if (m) out.push({ level: m[1].length, text: m[2].trim(), line: i })
  }
  return out
}

/** `- [ ]` / `- [x]` checkboxes with their line numbers. */
export function extractTasks(
  source: string,
): Array<{ line: number; done: boolean; text: string; indent: number }> {
  const out: Array<{ line: number; done: boolean; text: string; indent: number }> = []
  const lines = source.split(/\r?\n/)
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\s*)[-*+]\s+\[([ xX])\]\s?(.*)$/.exec(lines[i])
    if (m) out.push({ line: i, indent: m[1].length, done: m[2] !== ' ', text: m[3] })
  }
  return out
}

/** Words in the body, frontmatter excluded. */
export function wordCount(source: string): number {
  const body = stripFrontmatter(source).trim()
  if (!body) return 0
  return body.split(/\s+/).length
}

/** Obsidian-style heading slug used to resolve `[[Note#Heading]]`. */
export function headingSlug(text: string): string {
  return text.trim().toLowerCase().replace(/\s+/g, ' ')
}
